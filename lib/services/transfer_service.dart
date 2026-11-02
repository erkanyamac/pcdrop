import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../models/device.dart';
import '../models/transfer_session.dart';

typedef UploadApprovalCallback = Future<bool> Function(TransferSession session);

class TransferProgress {
  const TransferProgress({
    this.fileId,
    this.fileName,
    this.transferredBytes = 0,
    this.totalBytes = 0,
    this.bytesPerSecond = 0,
    this.remaining = Duration.zero,
    this.isComplete = false,
    this.filePath,
    this.error,
  });

  final String? fileId;
  final String? fileName;
  final int transferredBytes;
  final int totalBytes;
  final double bytesPerSecond;
  final Duration remaining;
  final bool isComplete;
  final String? filePath;
  final String? error;

  double get percentage =>
      totalBytes <= 0 ? 0 : transferredBytes / totalBytes * 100;
}

class TransferProgressNotifier extends Notifier<TransferProgress> {
  final List<TransferProgress> _completedTransfers = [];

  @override
  TransferProgress build() => const TransferProgress();

  List<TransferProgress> get completedTransfers =>
      List.unmodifiable(_completedTransfers);

  void update({
    required String fileId,
    required String fileName,
    required int transferredBytes,
    required int totalBytes,
    required double bytesPerSecond,
    required Duration remaining,
    bool isComplete = false,
    String? filePath,
  }) {
    final next = TransferProgress(
      fileId: fileId,
      fileName: fileName,
      transferredBytes: transferredBytes,
      totalBytes: totalBytes,
      bytesPerSecond: bytesPerSecond,
      remaining: remaining,
      isComplete: isComplete,
      filePath: filePath,
    );
    state = next;
    if (isComplete) {
      _completedTransfers.removeWhere((item) => item.fileId == fileId);
      _completedTransfers.insert(0, next);
    }
  }

  void fail(Object error) {
    state = TransferProgress(error: error.toString());
  }
}

final transferProgressProvider =
    NotifierProvider<TransferProgressNotifier, TransferProgress>(
      TransferProgressNotifier.new,
    );

final completedTransfersProvider = Provider<List<TransferProgress>>((ref) {
  ref.watch(transferProgressProvider);
  return ref.read(transferProgressProvider.notifier).completedTransfers;
});

class TransferService {
  TransferService({this.onUploadApproval, Dio? dio, this.onProgress})
    : _dio = dio ?? Dio();

  UploadApprovalCallback? onUploadApproval;
  final Dio _dio;
  final void Function(TransferProgress progress)? onProgress;
  final Map<String, _UploadGrant> _grants = {};
  final Random _random = Random.secure();
  final String _serverDeviceId = const Uuid().v4();
  HttpServer? _server;
  Device? _device;

  void setUploadApprovalCallback(UploadApprovalCallback callback) {
    onUploadApproval = callback;
  }

  Future<void> startReceiver({
    int port = NetworkConstants.defaultPort,
    SecurityContext? securityContext,
    Device? device,
  }) async {
    if (_server != null) {
      return;
    }
    _device = device;

    final router = Router()
      ..get('/api/v1/info', (request) => _info(request))
      ..post('/api/v1/prepare-upload', (request) => _prepareUpload(request))
      ..post('/api/v1/upload', (request) => _upload(request))
      ..post('/api/v1/cancel', (request) => _cancel(request));

    _server = await shelf_io.serve(
      router.call,
      InternetAddress.anyIPv4,
      port,
      securityContext: securityContext,
    );
  }

  Future<void> stopReceiver() async {
    final server = _server;
    _server = null;
    _device = null;
    _grants.clear();
    await server?.close(force: true);
  }

  Future<shelf.Response> _info(shelf.Request request) async {
    return _jsonResponse({
      'service': 'PCDrop',
      'version': NetworkConstants.protocolVersion,
      'port': _server?.port ?? NetworkConstants.defaultPort,
      'serviceType': NetworkConstants.serviceType,
      'id': _device?.id ?? _serverDeviceId,
      ...?_device?.toJson(),
    });
  }

  Future<shelf.Response> _prepareUpload(shelf.Request request) async {
    try {
      final payload = await _decodeJsonObject(request);
      final session = TransferSession.fromJson(payload);
      final approval = onUploadApproval;
      if (approval == null) {
        return _jsonResponse({
          'status': 'REJECTED',
          'reason': 'User approval is unavailable',
        }, statusCode: HttpStatus.forbidden);
      }

      if (!await approval(session)) {
        return _jsonResponse({
          'status': 'REJECTED',
        }, statusCode: HttpStatus.forbidden);
      }

      final sessionId = _secureToken(24);
      final uploadToken = _secureToken(32);
      _grants[uploadToken] = _UploadGrant(
        sessionId: sessionId,
        fileIds: session.files.map((file) => file.fileId).toSet(),
      );

      return _jsonResponse({
        'status': 'ACCEPTED',
        'sessionId': sessionId,
        'uploadToken': uploadToken,
        'acceptedFileIds': session.files.map((file) => file.fileId).toList(),
      });
    } on FormatException catch (error) {
      return _jsonResponse({
        'status': 'REJECTED',
        'reason': error.message,
      }, statusCode: HttpStatus.badRequest);
    }
  }

  Future<shelf.Response> _upload(shelf.Request request) async {
    final sessionId = request.url.queryParameters['sessionId'];
    final fileId = request.url.queryParameters['fileId'];
    final token = request.url.queryParameters['token'];
    final grant = token == null ? null : _grants[token];

    if (sessionId == null ||
        fileId == null ||
        token == null ||
        grant == null ||
        grant.sessionId != sessionId ||
        !grant.fileIds.contains(fileId)) {
      return _jsonResponse({
        'status': 'REJECTED',
        'reason': 'Invalid or expired upload token',
      }, statusCode: HttpStatus.forbidden);
    }

    final encodedName = request.headers['x-file-name'];
    if (encodedName == null) {
      return _jsonResponse({
        'status': 'REJECTED',
        'reason': 'Missing x-file-name header',
      }, statusCode: HttpStatus.badRequest);
    }

    final fileName = _safeFileName(Uri.decodeComponent(encodedName));
    if (fileName == null) {
      return _jsonResponse({
        'status': 'REJECTED',
        'reason': 'Invalid file name',
      }, statusCode: HttpStatus.badRequest);
    }

    final expectedLength = request.headers['content-length'];
    final totalBytes = int.tryParse(expectedLength ?? '') ?? 0;
    final destination = await _uniqueDestination(fileName);
    final sink = destination.openWrite();
    Digest? digest;
    final digestSink = _DigestSink((value) => digest = value);
    final digestInput = sha256.startChunkedConversion(digestSink);
    var transferredBytes = 0;
    final stopwatch = Stopwatch()..start();

    try {
      await for (final chunk in request.read()) {
        sink.add(chunk);
        digestInput.add(chunk);
        transferredBytes += chunk.length;
        _publishProgress(
          fileId: fileId,
          fileName: fileName,
          transferredBytes: transferredBytes,
          totalBytes: totalBytes,
          stopwatch: stopwatch,
        );
      }
      digestInput.close();
      await sink.flush();
      await sink.close();
      if (!destination.existsSync() || destination.lengthSync() <= 0) {
        return _jsonResponse({
          'status': 'FAILED',
          'reason': 'Kaydedilen dosya boş veya bulunamadı',
        }, statusCode: HttpStatus.internalServerError);
      }
      final digestValue = digest.toString();
      final expectedDigest = request.headers['x-sha256'];
      if (expectedDigest != null &&
          !_constantTimeEquals(expectedDigest, digestValue)) {
        await destination.delete();
        return _jsonResponse({
          'status': 'FAILED',
          'reason': 'SHA-256 checksum mismatch',
        }, statusCode: HttpStatus.badRequest);
      }
      await OpenFilex.open(destination.path);
      grant.fileIds.remove(fileId);
      if (grant.fileIds.isEmpty) {
        _grants.remove(token);
      }
      _publishProgress(
        fileId: fileId,
        fileName: fileName,
        transferredBytes: transferredBytes,
        totalBytes: totalBytes,
        stopwatch: stopwatch,
        isComplete: true,
        filePath: destination.path,
      );
      return _jsonResponse({
        'status': 'COMPLETED',
        'fileName': destination.uri.pathSegments.last,
        'filePath': destination.path,
        'sha256': digestValue,
      }, statusCode: HttpStatus.ok);
    } on Object catch (error) {
      await sink.close();
      try {
        await destination.delete();
      } on FileSystemException {
        // The partial file is best-effort cleanup after a failed transfer.
      }
      return _jsonResponse({
        'status': 'FAILED',
        'reason': error.toString(),
      }, statusCode: HttpStatus.internalServerError);
    } finally {
      stopwatch.stop();
    }
  }

  Future<shelf.Response> _cancel(shelf.Request request) async {
    final token = request.url.queryParameters['token'];
    if (token == null || _grants.remove(token) == null) {
      return _jsonResponse({
        'status': 'NOT_FOUND',
      }, statusCode: HttpStatus.notFound);
    }
    return _jsonResponse({'status': 'CANCELLED'});
  }

  Future<String> prepareUpload({
    required String targetIp,
    required TransferSession session,
    int targetPort = NetworkConstants.defaultPort,
  }) async {
    final response = await _dio.post<Map<String, dynamic>>(
      'http://$targetIp:$targetPort${NetworkConstants.prepareUploadPath}',
      data: session.toJson(),
      options: Options(contentType: NetworkConstants.contentTypeJson),
    );
    final data = response.data;
    if (response.statusCode != HttpStatus.ok ||
        data?['status'] != 'ACCEPTED' ||
        data?['sessionId'] is! String ||
        data?['uploadToken'] is! String) {
      throw StateError('Upload request was rejected by the receiver');
    }
    return jsonEncode({
      'sessionId': data!['sessionId'],
      'uploadToken': data['uploadToken'],
      'acceptedFileIds': data['acceptedFileIds'],
    });
  }

  Future<void> uploadFile({
    required String targetIp,
    required int targetPort,
    required String sessionId,
    required String uploadToken,
    required TransferFile file,
    required File source,
  }) async {
    final totalBytes = await source.length();
    final checksum = file.sha256 ?? await _sha256File(source);
    final stopwatch = Stopwatch()..start();
    try {
      final response = await _dio.post<void>(
        'http://$targetIp:$targetPort${NetworkConstants.uploadPath}',
        queryParameters: {
          'sessionId': sessionId,
          'fileId': file.fileId,
          'token': uploadToken,
        },
        data: source.openRead(),
        options: Options(
          contentType: NetworkConstants.contentTypeOctetStream,
          headers: {
            Headers.contentLengthHeader: totalBytes,
            'x-file-name': Uri.encodeComponent(file.fileName),
            'x-sha256': checksum,
          },
        ),
        onSendProgress: (sent, total) {
          _publishProgress(
            fileId: file.fileId,
            fileName: file.fileName,
            transferredBytes: sent,
            totalBytes: total > 0 ? total : totalBytes,
            stopwatch: stopwatch,
          );
        },
      );
      if (response.statusCode != HttpStatus.ok) {
        throw StateError(
          'Dosya aktarımı HTTP ${response.statusCode ?? 'bilinmeyen'} yanıtıyla tamamlanamadı',
        );
      }
      _publishProgress(
        fileId: file.fileId,
        fileName: file.fileName,
        transferredBytes: totalBytes,
        totalBytes: totalBytes,
        stopwatch: stopwatch,
        isComplete: true,
        filePath: source.path,
      );
    } catch (error) {
      onProgress?.call(TransferProgress(error: error.toString()));
      rethrow;
    } finally {
      stopwatch.stop();
    }
  }

  Future<void> cancelUpload({
    required String sessionId,
    required String uploadToken,
    String? targetIp,
    int targetPort = NetworkConstants.defaultPort,
  }) async {
    if (targetIp == null) {
      _grants.remove(uploadToken);
      return;
    }
    await _dio.post<void>(
      'http://$targetIp:$targetPort${NetworkConstants.uploadPath.replaceFirst('/upload', '/cancel')}',
      queryParameters: {'sessionId': sessionId, 'token': uploadToken},
    );
  }

  Future<Map<String, dynamic>> _decodeJsonObject(shelf.Request request) async {
    final decoded = jsonDecode(await request.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Request body must be a JSON object');
    }
    return decoded;
  }

  shelf.Response _jsonResponse(
    Map<String, dynamic> body, {
    int statusCode = HttpStatus.ok,
  }) {
    return shelf.Response(
      statusCode,
      body: jsonEncode(body),
      headers: {'content-type': NetworkConstants.contentTypeJson},
    );
  }

  Future<File> _uniqueDestination(String fileName) async {
    final baseDirectory = await _storageDirectory();
    await baseDirectory.create(recursive: true);
    var candidate = File(
      '${baseDirectory.path}${Platform.pathSeparator}$fileName',
    );
    var suffix = 1;
    while (await candidate.exists()) {
      final dot = fileName.lastIndexOf('.');
      final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
      final extension = dot > 0 ? fileName.substring(dot) : '';
      candidate = File(
        '${baseDirectory.path}${Platform.pathSeparator}$stem ($suffix)$extension',
      );
      suffix++;
    }
    return candidate;
  }

  Future<Directory> _storageDirectory() async {
    if (Platform.isWindows) {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        return Directory('${downloads.path}${Platform.pathSeparator}PCDrop');
      }
    }
    return getApplicationDocumentsDirectory();
  }

  Future<String> _sha256File(File file) async {
    Digest? digest;
    final digestSink = _DigestSink((value) => digest = value);
    final digestInput = sha256.startChunkedConversion(digestSink);
    await for (final chunk in file.openRead()) {
      digestInput.add(chunk);
    }
    digestInput.close();
    return digest.toString();
  }

  String? _safeFileName(String fileName) {
    if (fileName.isEmpty ||
        fileName == '.' ||
        fileName == '..' ||
        fileName.contains('/') ||
        fileName.contains('\\') ||
        fileName.contains(':') ||
        fileName.contains('\u0000')) {
      return null;
    }
    return fileName;
  }

  String _secureToken(int byteLength) {
    final bytes = List<int>.generate(
      byteLength,
      (_) => _random.nextInt(256),
      growable: false,
    );
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  bool _constantTimeEquals(String left, String right) {
    if (left.length != right.length) {
      return false;
    }
    var difference = 0;
    for (var index = 0; index < left.length; index++) {
      difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
    }
    return difference == 0;
  }

  void _publishProgress({
    required String fileId,
    required String fileName,
    required int transferredBytes,
    required int totalBytes,
    required Stopwatch stopwatch,
    bool isComplete = false,
    String? filePath,
  }) {
    final elapsedSeconds = stopwatch.elapsedMilliseconds / 1000;
    final bytesPerSecond = elapsedSeconds <= 0
        ? 0
        : transferredBytes / elapsedSeconds;
    final remainingBytes = max(totalBytes - transferredBytes, 0);
    final remaining = bytesPerSecond <= 0
        ? Duration.zero
        : Duration(seconds: (remainingBytes / bytesPerSecond).ceil());
    onProgress?.call(
      TransferProgress(
        fileId: fileId,
        fileName: fileName,
        transferredBytes: transferredBytes,
        totalBytes: totalBytes,
        bytesPerSecond: bytesPerSecond.toDouble(),
        remaining: remaining,
        isComplete: isComplete,
        filePath: filePath,
      ),
    );
  }
}

class _UploadGrant {
  _UploadGrant({required this.sessionId, required Set<String> fileIds})
    : fileIds = {...fileIds};

  final String sessionId;
  final Set<String> fileIds;
}

final transferServiceProvider = Provider<TransferService>((ref) {
  final progress = ref.read(transferProgressProvider.notifier);
  final service = TransferService(
    onProgress: (value) {
      if (value.error != null) {
        progress.fail(value.error!);
        return;
      }
      progress.update(
        fileId: value.fileId!,
        fileName: value.fileName!,
        transferredBytes: value.transferredBytes,
        totalBytes: value.totalBytes,
        bytesPerSecond: value.bytesPerSecond,
        remaining: value.remaining,
        isComplete: value.isComplete,
        filePath: value.filePath,
      );
    },
  );
  ref.onDispose(() async {
    await service.stopReceiver();
  });
  return service;
});

class _DigestSink implements Sink<Digest> {
  _DigestSink(this._onDigest);

  final void Function(Digest digest) _onDigest;

  @override
  void add(Digest digest) => _onDigest(digest);

  @override
  void close() {}
}
