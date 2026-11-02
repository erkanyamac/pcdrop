import '../core/constants.dart';

enum DeviceOperatingSystem {
  windows('windows'),
  ipados('ipados'),
  unknown('unknown');

  const DeviceOperatingSystem(this.value);

  final String value;

  static DeviceOperatingSystem fromValue(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'windows') {
      return DeviceOperatingSystem.windows;
    }
    if (normalized == 'ios' ||
        normalized == 'ipados' ||
        normalized == 'ipad' ||
        normalized == 'apple') {
      return DeviceOperatingSystem.ipados;
    }
    return DeviceOperatingSystem.unknown;
  }
}

class Device {
  const Device({
    required this.id,
    required this.alias,
    required this.deviceModel,
    required this.os,
    required this.port,
    this.version = '1.0',
    this.address,
  });

  final String id;
  final String alias;
  final String deviceModel;
  final DeviceOperatingSystem os;
  final int port;
  final String version;
  final String? address;

  factory Device.fromJson(Map<String, dynamic> json, {String? fallbackIp}) {
    final ip = _firstNonEmptyString(json, const ['ip', 'host']) ?? fallbackIp;
    final alias =
        _firstNonEmptyString(json, const [
          'alias',
          'name',
          'deviceName',
          'model',
        ]) ??
        'PCDrop Cihazı (${fallbackIp ?? 'bilinmeyen adres'})';
    final id =
        _firstNonEmptyString(json, const [
          'id',
          'deviceId',
          'fingerprint',
          'uuid',
        ]) ??
        fallbackIp ??
        'unknown-device';
    final platform = _firstNonEmptyString(json, const [
      'platform',
      'deviceType',
      'os',
    ]);

    return Device(
      id: id,
      alias: alias,
      deviceModel:
          _firstNonEmptyString(json, const ['deviceModel', 'model']) ?? alias,
      os: DeviceOperatingSystem.fromValue(platform ?? 'unknown'),
      port:
          int.tryParse(json['port']?.toString() ?? '') ??
          NetworkConstants.defaultPort,
      version: _firstNonEmptyString(json, const ['version']) ?? '1.0',
      address:
          _firstNonEmptyString(json, const ['address', 'ip', 'host']) ?? ip,
    );
  }

  factory Device.fromSenderJson(Map<String, dynamic> json) {
    return Device.fromJson(json);
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'alias': alias,
      'deviceModel': deviceModel,
      'os': os.value,
      'port': port.toString(),
      'version': version,
    };
  }

  Map<String, dynamic> toSenderJson() {
    return {'id': id, 'alias': alias, 'os': os.value};
  }

  static String? _firstNonEmptyString(
    Map<String, dynamic> json,
    List<String> keys,
  ) {
    for (final key in keys) {
      final value = json[key];
      if (value is String && value.trim().isNotEmpty) {
        return value;
      }
    }
    return null;
  }
}
