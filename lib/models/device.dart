enum DeviceOperatingSystem {
  windows('windows'),
  ipados('ipados');

  const DeviceOperatingSystem(this.value);

  final String value;

  static DeviceOperatingSystem fromValue(String value) {
    return DeviceOperatingSystem.values.firstWhere(
      (operatingSystem) => operatingSystem.value == value,
      orElse: () => throw FormatException('Unsupported device OS: $value'),
    );
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

  factory Device.fromJson(Map<String, dynamic> json) {
    final portValue = json['port'];
    final port = portValue is num
        ? portValue.toInt()
        : int.tryParse(portValue as String? ?? '');

    if (port == null) {
      throw const FormatException('Device port must be an integer');
    }

    return Device(
      id: _requiredString(json, 'id'),
      alias: _requiredString(json, 'alias'),
      deviceModel: _requiredString(json, 'deviceModel'),
      os: DeviceOperatingSystem.fromValue(_requiredString(json, 'os')),
      port: port,
      version: json['version'] as String? ?? '1.0',
      address: json['address'] as String?,
    );
  }

  factory Device.fromSenderJson(Map<String, dynamic> json) {
    return Device(
      id: _requiredString(json, 'id'),
      alias: _requiredString(json, 'alias'),
      deviceModel: json['deviceModel'] as String? ?? '',
      os: DeviceOperatingSystem.fromValue(_requiredString(json, 'os')),
      port: _optionalPort(json['port']),
      version: json['version'] as String? ?? '1.0',
      address: json['address'] as String?,
    );
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

  static int _optionalPort(Object? value) {
    if (value == null) {
      return 0;
    }
    final port = value is num ? value.toInt() : int.tryParse(value.toString());
    if (port == null) {
      throw const FormatException('Device port must be an integer');
    }
    return port;
  }

  static String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String || value.isEmpty) {
      throw FormatException('Device field "$key" must be a non-empty string');
    }
    return value;
  }
}
