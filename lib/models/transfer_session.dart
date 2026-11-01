import 'device.dart';

class TransferFile {
  const TransferFile({
    required this.fileId,
    required this.fileName,
    required this.size,
    required this.mimeType,
    this.sha256,
  });

  final String fileId;
  final String fileName;
  final int size;
  final String mimeType;
  final String? sha256;

  factory TransferFile.fromJson(Map<String, dynamic> json) {
    final size = json['size'];
    if (size is! num) {
      throw const FormatException('Transfer file size must be a number');
    }

    return TransferFile(
      fileId: _requiredString(json, 'fileId'),
      fileName: _requiredString(json, 'fileName'),
      size: size.toInt(),
      mimeType: _requiredString(json, 'mimeType'),
      sha256: json['sha256'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'fileId': fileId,
      'fileName': fileName,
      'size': size,
      'mimeType': mimeType,
      'sha256': sha256,
    };
  }

  static String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw FormatException(
        'Transfer file field "$key" must be a non-empty string',
      );
    }
    return value;
  }
}

class TransferSession {
  const TransferSession({
    required this.sessionId,
    required this.sender,
    required this.files,
  });

  final String sessionId;
  final Device sender;
  final List<TransferFile> files;

  factory TransferSession.fromJson(Map<String, dynamic> json) {
    final sender = json['sender'];
    final files = json['files'];
    if (sender is! Map<String, dynamic> || files is! List) {
      throw const FormatException(
        'Transfer session must contain sender and files',
      );
    }

    return TransferSession(
      sessionId: _requiredString(json, 'sessionId'),
      sender: Device.fromSenderJson(sender),
      files: files
          .map((file) {
            if (file is! Map<String, dynamic>) {
              throw const FormatException(
                'Transfer file must be a JSON object',
              );
            }
            return TransferFile.fromJson(file);
          })
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'sessionId': sessionId,
      'sender': sender.toSenderJson(),
      'files': files.map((file) => file.toJson()).toList(growable: false),
    };
  }

  static String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw FormatException(
        'Transfer session field "$key" must be a non-empty string',
      );
    }
    return value;
  }
}
