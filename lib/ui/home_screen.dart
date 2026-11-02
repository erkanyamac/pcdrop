import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:uuid/uuid.dart';

import '../models/device.dart';
import '../models/transfer_session.dart';
import '../services/discovery_service.dart';
import '../services/transfer_service.dart';
import 'widgets/transfer_dialog.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _serverRunning = false;
  bool _manualAddInProgress = false;
  String? _activeSessionId;
  String? _activeToken;
  Device? _activeTarget;
  String? _sharedFilePath;
  bool _sharedFileSending = false;
  Device? _selectedTarget;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    const MethodChannel('pcdrop/share')
        .setMethodCallHandler(_handleShareMethod);
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeServices());
  }

  @override
  void dispose() {
    const MethodChannel('pcdrop/share').setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _handleShareMethod(MethodCall call) async {
    if (call.method != 'sharedFile' || call.arguments is! String) return;
    final path = call.arguments as String;
    if (!mounted) return;
    setState(() => _sharedFilePath = path);
    final devices = ref.read(discoveryProvider).asData?.value ?? const [];
    if (devices.length == 1) {
      await _sendSharedFile(devices.single);
    }
  }

  Future<void> _initializeServices() async {
    final transfer = ref.read(transferServiceProvider);
    transfer.setUploadApprovalCallback(_requestApproval);
    try {
      await ref.read(discoveryProvider.future);
      final localDevice = ref.read(discoveryServiceProvider).localDevice;
      await transfer.startReceiver(
        device: localDevice,
        onDeviceAnnouncement: (device) {
          ref.read(discoveryProvider.notifier).addAnnouncedDevice(device);
        },
      );
      if (mounted) setState(() => _serverRunning = true);
    } catch (error) {
      if (mounted) {
        _showMessage('Alıcı sunucusu başlatılamadı: $error');
      }
    }
  }

  Future<void> _addDeviceByIp() async {
    final controller = TextEditingController();
    final ip = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('IP ile Manuel Ekle / Bağlan'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Karşı cihazın IPv4 adresi',
            hintText: '192.168.1.25',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Bağlan'),
          ),
        ],
      ),
    );
    controller.dispose();
    final parsedIp = ip == null ? null : InternetAddress.tryParse(ip);
    if (ip == null ||
        ip.isEmpty ||
        parsedIp == null ||
        parsedIp.type != InternetAddressType.IPv4) {
      if (ip != null && mounted) {
        _showMessage('Geçerli bir IPv4 adresi girin.');
      }
      return;
    }

    setState(() => _manualAddInProgress = true);
    try {
      await ref.read(discoveryProvider.notifier).addManualDevice(ip);
      if (mounted) _showMessage('Cihaz eklendi. Dosya göndermeye hazır.');
    } catch (error) {
      if (mounted) _showMessage('Cihaza bağlanılamadı: $error');
    } finally {
      if (mounted) setState(() => _manualAddInProgress = false);
    }
  }

  Future<bool> _requestApproval(TransferSession session) async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => TransferDialog(
        session: session,
        onApprove: () => Navigator.of(context).pop(true),
        onReject: () => Navigator.of(context).pop(false),
      ),
    );
    return result ?? false;
  }

  Future<void> _selectAndSend(
    Device target, {
    String? sharedPath,
    List<DropItem>? droppedFiles,
  }) async {
    final files = sharedPath == null
        ? droppedFiles == null
              ? await FilePicker.pickFiles()
              : null
        : null;
    if (sharedPath == null &&
        droppedFiles == null &&
        (files == null || files.isEmpty)) {
      return;
    }
    if (sharedPath != null && !await File(sharedPath).exists()) {
      _sharedFileSending = false;
      if (mounted) {
        _showMessage('Paylaşılan dosyaya erişilemedi.');
      }
      return;
    }
    final address = target.address;
    final localDevice = ref.read(discoveryServiceProvider).localDevice;
    if (address == null || localDevice == null) {
      _showMessage('Cihaz adresi veya yerel cihaz bilgisi bulunamadı.');
      return;
    }

    final selected = <({File source, TransferFile metadata})>[];
    final paths = sharedPath == null && droppedFiles != null
        ? [
            for (final item in droppedFiles)
              if (item.path.isNotEmpty) (item.path, item.name),
          ]
        : sharedPath == null
        ? [
            for (final picked in files!)
              if (picked.path != null) (picked.path!, picked.name),
          ]
        : [(sharedPath, sharedPath.split(Platform.pathSeparator).last)];
    for (final (path, name) in paths) {
      final source = File(path);
      selected.add((
        source: source,
        metadata: TransferFile(
          fileId: const Uuid().v4(),
          fileName: name,
          size: await source.length(),
          mimeType: 'application/octet-stream',
        ),
      ));
    }
    if (selected.isEmpty) {
      _showMessage('Seçilen dosyaların yerel yolu bulunamadı.');
      return;
    }

    final service = ref.read(transferServiceProvider);
    try {
      _activeTarget = target;
      var failedFiles = 0;
      for (final item in selected) {
        final session = TransferSession(
          sessionId: const Uuid().v4(),
          sender: localDevice,
          files: [item.metadata],
        );
        try {
          final authorization = jsonDecode(
            await service.prepareUpload(
              targetIp: address,
              session: session,
              targetPort: target.port,
            ),
          ) as Map<String, dynamic>;
          _activeSessionId = authorization['sessionId'] as String;
          _activeToken = authorization['uploadToken'] as String;
          await service.uploadFile(
            targetIp: address,
            targetPort: target.port,
            sessionId: _activeSessionId!,
            uploadToken: _activeToken!,
            file: item.metadata,
            source: item.source,
          );
          if (mounted) {
            _showMessage('${item.metadata.fileName} aktarımı tamamlandı.');
          }
        } on DioException catch (error) {
          failedFiles++;
          final message = service.userFriendlyNetworkError(error);
          if (mounted) _showMessage(message);
        } catch (error) {
          failedFiles++;
          if (mounted) _showMessage(service.userFriendlyNetworkError(error));
        } finally {
          _activeSessionId = null;
          _activeToken = null;
        }
      }
      if (failedFiles == 0 && mounted) {
        _showMessage('Aktarım kuyruğu tamamlandı.');
      }
    } catch (error) {
      if (mounted) _showMessage(service.userFriendlyNetworkError(error));
    } finally {
      if (sharedPath != null && mounted) {
        setState(() {
          _sharedFilePath = null;
          _sharedFileSending = false;
        });
      }
      _activeSessionId = null;
      _activeToken = null;
      _activeTarget = null;
    }
  }

  Future<void> _sendSharedFile(Device device) async {
    final path = _sharedFilePath;
    if (path == null || _sharedFileSending) return;
    _sharedFileSending = true;
    await _selectAndSend(device, sharedPath: path);
  }

  Device? get _effectiveTarget {
    final devices = ref.read(discoveryProvider).asData?.value ?? const [];
    return _selectedTarget ?? (devices.length == 1 ? devices.single : null);
  }

  Future<void> _cancelTransfer() async {
    final sessionId = _activeSessionId;
    final token = _activeToken;
    if (sessionId == null || token == null) return;
    await ref
        .read(transferServiceProvider)
        .cancelUpload(
          sessionId: sessionId,
          uploadToken: token,
          targetIp: _activeTarget?.address,
          targetPort: _activeTarget?.port ?? 53317,
        );
    if (mounted) _showMessage('Aktarım iptal edildi.');
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(discoveryProvider);
    ref.listen(discoveryProvider, (_, next) {
      final found = next.asData?.value ?? const <Device>[];
      if (_sharedFilePath != null && found.length == 1) {
        unawaited(_sendSharedFile(found.single));
      }
    });
    final progress = ref.watch(transferProgressProvider);
    final completedTransfers = ref.watch(completedTransfersProvider);
    final discoveryService = ref.read(discoveryServiceProvider);
    final deviceList = devices.asData?.value ?? const <Device>[];
    final localDevice = discoveryService.localDevice;
    final localIp = discoveryService.localIp;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          localDevice?.alias ?? 'PCDrop',
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          Center(
            child: Text(
              '${localIp ?? 'IP aranıyor'} • '
              '${_serverRunning ? 'Sunucu aktif' : 'Sunucu kapalı'}',
            ),
          ),
          IconButton(
            tooltip: 'Yeniden Tara',
            onPressed: () => ref.read(discoveryProvider.notifier).rescan(),
            icon: const Icon(Icons.refresh),
          ),
          const SizedBox(width: 12),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: OutlinedButton.icon(
              onPressed: _manualAddInProgress ? null : _addDeviceByIp,
              icon: _manualAddInProgress
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.link),
              label: const Text(
                'IP ile Ekle / Bağlan',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final transfers = [
              if (progress.fileId != null || progress.error != null) progress,
              ...completedTransfers.where(
                (item) => item.fileId != progress.fileId,
              ),
            ];
            final devicesPanel = _DevicesPanel(
              devices: deviceList,
              selectedDevice:
                  _selectedTarget ??
                  (deviceList.length == 1 ? deviceList.single : null),
              onDeviceTap: (device) {
                final sharedPath = _sharedFilePath;
                if (sharedPath != null) {
                  unawaited(_sendSharedFile(device));
                } else {
                  setState(() => _selectedTarget = device);
                }
              },
              onDeviceDrop: (device, files) =>
                  _selectAndSend(device, droppedFiles: files),
            );
            final transfersPanel = _TransfersPanel(
              transfers: transfers,
              onCancel: _cancelTransfer,
            );
            return Column(
              children: [
                if (_sharedFilePath != null && deviceList.length != 1)
                  MaterialBanner(
                    content: Text(
                      'Paylaşıma Hazır: '
                      '${_sharedFilePath!.split(Platform.pathSeparator).last} '
                      '(Göndermek için cihaza dokunun)',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => setState(() => _sharedFilePath = null),
                        child: const Text('Kapat'),
                      ),
                    ],
                  ),
                const _CompactScanIndicator(),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: constraints.maxWidth >= 700
                        ? Row(
                            children: [
                              Expanded(child: devicesPanel),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  children: [
                                    Expanded(
                                      child: _Dropzone(
                                        active: _isDragging,
                                        onEntered: () =>
                                            setState(() => _isDragging = true),
                                        onExited: () =>
                                            setState(() => _isDragging = false),
                                        onDropped: _handleDroppedFiles,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Expanded(child: transfersPanel),
                                  ],
                                ),
                              ),
                            ],
                          )
                        : Column(
                            children: [
                              Expanded(child: devicesPanel),
                              const SizedBox(height: 8),
                              Expanded(
                                child: Column(
                                  children: [
                                    Expanded(
                                      child: _Dropzone(
                                        active: _isDragging,
                                        onEntered: () =>
                                            setState(() => _isDragging = true),
                                        onExited: () =>
                                            setState(() => _isDragging = false),
                                        onDropped: _handleDroppedFiles,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Expanded(child: transfersPanel),
                                  ],
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
                _BottomActionBar(
                  enabled: _effectiveTarget != null,
                  onPressed: _effectiveTarget == null
                      ? null
                      : () => _selectAndSend(_effectiveTarget!),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Future<void> _handleDroppedFiles(List<DropItem> files) async {
    setState(() => _isDragging = false);
    final target = _effectiveTarget;
    if (target == null) {
      _showMessage('Önce bir hedef cihaz seçin.');
      return;
    }
    await _selectAndSend(target, droppedFiles: files);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _CompactScanIndicator extends StatelessWidget {
  const _CompactScanIndicator();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 32,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(width: 100, child: LinearProgressIndicator(minHeight: 3)),
          SizedBox(width: 8),
          Text('Cihazlar taranıyor...'),
        ],
      ),
    );
  }
}

class _Dropzone extends StatelessWidget {
  const _Dropzone({
    required this.active,
    required this.onEntered,
    required this.onExited,
    required this.onDropped,
  });

  final bool active;
  final VoidCallback onEntered;
  final VoidCallback onExited;
  final ValueChanged<List<DropItem>> onDropped;

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragEntered: (_) => onEntered(),
      onDragExited: (_) => onExited(),
      onDragDone: (details) => onDropped(details.files),
      child: InkWell(
        onTap: () {
          final target = context
              .findAncestorStateOfType<_HomeScreenState>()
              ?._effectiveTarget;
          if (target != null) {
            unawaited(
              context
                  .findAncestorStateOfType<_HomeScreenState>()
                  ?._selectAndSend(target),
            );
          }
        },
        child: CustomPaint(
          foregroundPainter: _DashedBorderPainter(
            color: active
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outline,
          ),
          child: Container(
            width: double.infinity,
            decoration: BoxDecoration(
              color: active
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Text(
                active
                    ? 'Dosyaları Bırakın ve Gönderin'
                    : 'Dosyaları Buraya Sürükleyin veya Seçmek İçin Tıklayın\n'
                          '(Çoklu seçim desteklenir)',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)),
      );
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final metric in path.computeMetrics()) {
      for (var distance = 0.0; distance < metric.length; distance += 12) {
        canvas.drawPath(
          metric.extractPath(distance, math.min(distance + 6, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _DevicesPanel extends StatelessWidget {
  const _DevicesPanel({
    required this.devices,
    required this.selectedDevice,
    required this.onDeviceTap,
    required this.onDeviceDrop,
  });

  final List<Device> devices;
  final Device? selectedDevice;
  final ValueChanged<Device> onDeviceTap;
  final void Function(Device device, List<DropItem> files) onDeviceDrop;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Bulunan Cihazlar',
      child: devices.isEmpty
          ? const Center(child: Text('Yakındaki cihaz aranıyor...'))
          : ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: devices.length,
              itemBuilder: (context, index) {
                final device = devices[index];
                return DropTarget(
                  onDragDone: (details) => onDeviceDrop(device, details.files),
                  child: Card(
                    color: selectedDevice?.id == device.id
                        ? Theme.of(context).colorScheme.secondaryContainer
                        : null,
                    child: ListTile(
                      dense: true,
                      leading: Icon(
                        device.os == DeviceOperatingSystem.windows
                            ? Icons.desktop_windows
                            : Icons.tablet_mac,
                      ),
                      title: Text(
                        device.alias,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(device.address ?? 'Adres bilinmiyor'),
                      trailing: const Icon(Icons.touch_app, size: 18),
                      onTap: () => onDeviceTap(device),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _TransfersPanel extends StatelessWidget {
  const _TransfersPanel({required this.transfers, required this.onCancel});

  final List<TransferProgress> transfers;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      title: 'Aktif ve Tamamlanan Transferler',
      child: transfers.isEmpty
          ? const Center(child: Text('Henüz transfer yok'))
          : ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: transfers.length,
              itemBuilder: (context, index) => _TransferProgressCard(
                progress: transfers[index],
                onCancel: onCancel,
              ),
            ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const Divider(height: 12),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _BottomActionBar extends StatelessWidget {
  const _BottomActionBar({required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 4,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: enabled ? onPressed : null,
              icon: const Icon(Icons.upload_file),
              label: const Text('Dosya Seç ve Gönder'),
            ),
          ),
        ),
      ),
    );
  }
}

class _TransferProgressCard extends StatelessWidget {
  const _TransferProgressCard({required this.progress, required this.onCancel});

  final TransferProgress progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    if (progress.error != null) {
      final rejected = progress.status == TransferStatus.rejected;
      return Card(
        child: ListTile(
          leading: Icon(rejected ? Icons.cancel_outlined : Icons.error_outline),
          title: Text(rejected ? 'Reddedildi ✕' : 'Aktarım hatası'),
          subtitle: Text(progress.error!),
        ),
      );
    }
    final value = (progress.percentage / 100).clamp(0, 1).toDouble();
    return Card(
      margin: const EdgeInsets.only(top: 20),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(progress.fileName ?? 'Aktarım'),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: value),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('${progress.percentage.toStringAsFixed(0)}%'),
                const SizedBox(width: 12),
                Text(
                  '${(progress.bytesPerSecond / (1024 * 1024)).toStringAsFixed(2)} MB/s',
                ),
                const Spacer(),
                Text(_formatDuration(progress.remaining)),
                if (progress.isComplete)
                  const Text(
                    'Tamamlandı ✓',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  )
                else
                  TextButton(
                    onPressed: onCancel,
                    child: const Text('İptal Et'),
                  ),
              ],
            ),
            if (progress.isComplete && progress.filePath != null) ...[
              const SizedBox(height: 8),
              Text(
                progress.filePath!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => OpenFilex.open(progress.filePath!),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Dosyayı Aç'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _formatDuration(Duration duration) {
    if (duration == Duration.zero) return '--:--';
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${duration.inHours > 0 ? '${duration.inHours}:' : ''}$minutes:$seconds';
  }
}
