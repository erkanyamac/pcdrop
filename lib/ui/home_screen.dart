import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/device.dart';
import '../models/transfer_session.dart';
import '../services/discovery_service.dart';
import '../services/transfer_service.dart';
import 'widgets/radar_view.dart';
import 'widgets/transfer_dialog.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _serverRunning = false;
  String? _activeSessionId;
  String? _activeToken;
  Device? _activeTarget;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeServices());
  }

  Future<void> _initializeServices() async {
    final transfer = ref.read(transferServiceProvider);
    transfer.setUploadApprovalCallback(_requestApproval);
    try {
      await transfer.startReceiver();
      if (mounted) setState(() => _serverRunning = true);
    } catch (error) {
      if (mounted) {
        _showMessage('Alıcı sunucusu başlatılamadı: $error');
      }
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

  Future<void> _selectAndSend(Device target) async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return;
    final address = target.address;
    final localDevice = ref.read(discoveryServiceProvider).localDevice;
    if (address == null || localDevice == null) {
      _showMessage('Cihaz adresi veya yerel cihaz bilgisi bulunamadı.');
      return;
    }

    final selected =
        <({PlatformFile file, File source, TransferFile metadata})>[];
    for (final picked in files) {
      final path = picked.path;
      if (path == null) continue;
      final source = File(path);
      selected.add((
        file: picked,
        source: source,
        metadata: TransferFile(
          fileId: const Uuid().v4(),
          fileName: picked.name,
          size: await source.length(),
          mimeType: 'application/octet-stream',
        ),
      ));
    }
    if (selected.isEmpty) {
      _showMessage('Seçilen dosyaların yerel yolu bulunamadı.');
      return;
    }

    final session = TransferSession(
      sessionId: const Uuid().v4(),
      sender: localDevice,
      files: selected.map((item) => item.metadata).toList(growable: false),
    );
    final service = ref.read(transferServiceProvider);
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
      _activeTarget = target;
      for (final item in selected) {
        await service.uploadFile(
          targetIp: address,
          targetPort: target.port,
          sessionId: _activeSessionId!,
          uploadToken: _activeToken!,
          file: item.metadata,
          source: item.source,
        );
      }
      if (mounted) _showMessage('Aktarım tamamlandı.');
    } catch (error) {
      if (mounted) _showMessage('Aktarım başarısız: $error');
    } finally {
      _activeSessionId = null;
      _activeToken = null;
      _activeTarget = null;
    }
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
    final progress = ref.watch(transferProgressProvider);
    final discoveryService = ref.read(discoveryServiceProvider);
    final deviceList = devices.asData?.value ?? const <Device>[];
    final localDevice = discoveryService.localDevice;
    final localIp = discoveryService.localIp;

    return Scaffold(
      appBar: AppBar(
        title: const Text('PCDrop'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: Text(_serverRunning ? 'Sunucu aktif' : 'Sunucu kapalı'),
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: Column(
                children: [
                  ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.devices)),
                    title: Text(localDevice?.alias ?? 'Cihaz hazırlanıyor...'),
                    subtitle: Text('${localIp ?? 'IP aranıyor'} • Port 53317'),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: mathMin(constraints.maxWidth - 48, 620),
                    child: RadarView(
                      devices: deviceList,
                      onDeviceTap: _selectAndSend,
                    ),
                  ),
                  if (deviceList.isEmpty)
                    const Text('Yakındaki PCDrop cihazları aranıyor...'),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: deviceList.isEmpty
                        ? null
                        : () => _selectAndSend(deviceList.first),
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Dosya seç ve gönder'),
                  ),
                  if (progress.fileId != null || progress.error != null)
                    _TransferProgressCard(
                      progress: progress,
                      onCancel: _cancelTransfer,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  double mathMin(double a, double b) => a < b ? a : b;
}

class _TransferProgressCard extends StatelessWidget {
  const _TransferProgressCard({required this.progress, required this.onCancel});

  final TransferProgress progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    if (progress.error != null) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.error_outline),
          title: const Text('Aktarım hatası'),
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
                TextButton(onPressed: onCancel, child: const Text('İptal Et')),
              ],
            ),
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
