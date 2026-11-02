import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../models/device.dart';

class DiscoveryService {
  DiscoveryService({DeviceInfoPlugin? deviceInfo, Dio? dio, Uuid? uuid})
    : _deviceInfo = deviceInfo ?? DeviceInfoPlugin(),
      _dio = dio ?? Dio(),
      _uuid = uuid ?? const Uuid();

  final DeviceInfoPlugin _deviceInfo;
  final Dio _dio;
  final Uuid _uuid;
  static const _knownIpsKey = 'known_device_ips';
  static const _scanTimeout = Duration(milliseconds: 1500);

  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _discoverySubscription;
  String? _deviceId;
  Device? _localDevice;
  String? _localIp;

  Device? get localDevice => _localDevice;
  String? get localIp => _localIp;

  Future<void> start({
    required void Function(Device device) onDeviceFound,
    required void Function(String deviceId) onDeviceLost,
  }) async {
    if (_broadcast != null || _discovery != null) {
      return;
    }

    final localDevice = await _createLocalDevice();
    _localDevice = localDevice;
    _deviceId = localDevice.id;

    final localIps = await _activeLocalIpv4Addresses();
    final localIp = localIps.isEmpty ? null : localIps.first;
    _localIp = localIp;
    final service = BonsoirService(
      name: localDevice.alias,
      type: NetworkConstants.serviceType,
      hostAddresses: localIps,
      port: localDevice.port,
      attributes: localDevice.toJson().map(
        (key, value) => MapEntry(key, value.toString()),
      ),
    );

    final broadcast = BonsoirBroadcast(service: service);
    final discovery = BonsoirDiscovery(type: NetworkConstants.serviceType);
    await broadcast.initialize();
    await discovery.initialize();

    _broadcast = broadcast;
    _discovery = discovery;
    _discoverySubscription = discovery.eventStream?.listen((event) {
      final discoveredService = event.service;
      if (discoveredService == null) {
        return;
      }

      if (event is BonsoirDiscoveryServiceLostEvent) {
        final lostDeviceId = discoveredService.attributes['id'];
        if (lostDeviceId != null && lostDeviceId != _deviceId) {
          onDeviceLost(lostDeviceId);
        }
        return;
      }

      if (event is! BonsoirDiscoveryServiceResolvedEvent &&
          event is! BonsoirDiscoveryServiceUpdatedEvent) {
        return;
      }

      final device = _deviceFromService(discoveredService);
      if (device != null && device.id != _deviceId) {
        onDeviceFound(device);
      }
    });

    await broadcast.start();
    await discovery.start();
    unawaited(_scanKnownAndSubnet(onDeviceFound));
  }

  Future<Device> fetchDevice(String ip) async {
    final localDevice = _localDevice;
    final senderIp = _localIp;
    final queryParameters = <String, String>{
      'senderPort': NetworkConstants.defaultPort.toString(),
    };
    if (senderIp != null) queryParameters['senderIp'] = senderIp;
    if (localDevice != null) {
      queryParameters['senderAlias'] = localDevice.alias;
      queryParameters['senderId'] = localDevice.id;
    }
    final response = await _dio.get<Map<String, dynamic>>(
      'http://$ip:${NetworkConstants.defaultPort}/api/v1/info',
      queryParameters: queryParameters,
      options: Options(
        sendTimeout: _scanTimeout,
        receiveTimeout: _scanTimeout,
        connectTimeout: _scanTimeout,
      ),
    );
    final data = response.data;
    if (response.statusCode != HttpStatus.ok || data == null) {
      throw StateError('Cihaz bilgileri alınamadı.');
    }

    final device = Device.fromJson({
      ...data,
      'address': ip,
      'port': data['port'] ?? NetworkConstants.defaultPort,
    }, fallbackIp: ip);
    await _rememberIp(ip);
    return device;
  }

  Future<void> scan(void Function(Device device) onDeviceFound) async {
    await _scanKnownAndSubnet(onDeviceFound);
  }

  Future<void> stop() async {
    await _discoverySubscription?.cancel();
    _discoverySubscription = null;

    final discovery = _discovery;
    final broadcast = _broadcast;
    _discovery = null;
    _broadcast = null;

    if (discovery != null) {
      await discovery.stop();
    }
    if (broadcast != null) {
      await broadcast.stop();
    }
  }

  Future<Device> _createLocalDevice() async {
    final deviceType = Platform.isIOS
        ? DeviceOperatingSystem.ipados
        : DeviceOperatingSystem.windows;
    var alias = 'PCDrop Device';
    var deviceModel = 'Unknown';

    if (Platform.isWindows) {
      final info = await _deviceInfo.windowsInfo;
      alias = info.computerName;
      deviceModel = info.productName;
    } else if (Platform.isIOS) {
      final info = await _deviceInfo.iosInfo;
      alias = info.name;
      deviceModel = info.modelName;
    }

    return Device(
      id: _uuid.v4(),
      alias: alias,
      deviceModel: deviceModel,
      os: deviceType,
      port: NetworkConstants.defaultPort,
      version: NetworkConstants.protocolVersion,
    );
  }

  Future<List<String>> _activeLocalIpv4Addresses() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    return [
      for (final interface in interfaces)
        if (!_isVirtualInterface(interface.name))
          for (final address in interface.addresses)
            if (address.type == InternetAddressType.IPv4 &&
                !address.isLoopback &&
                !address.isLinkLocal)
              address.address,
    ];
  }

  Future<void> _scanKnownAndSubnet(
    void Function(Device device) onDeviceFound,
  ) async {
    final preferences = await SharedPreferences.getInstance();
    final knownIps = preferences.getStringList(_knownIpsKey) ?? const [];
    for (final ip in knownIps) {
      try {
        final device = await fetchDevice(ip);
        if (device.id != _deviceId) onDeviceFound(device);
      } on DioException {
        // A cached host may be offline.
      } on SocketException {
        // A cached host may be offline.
      }
    }

    final localIps = await _activeLocalIpv4Addresses();
    final subnetIps = <String>{
      for (final ip in localIps) ..._subnetAddresses(ip),
    };
    for (final ip in localIps) {
      final octets = ip.split('.');
      final subnet = '${octets[0]}.${octets[1]}.${octets[2]}';
      debugPrint('Taranan alt ağ: $subnet.1-254 (Kendi IP: $ip)');
    }
    subnetIps.removeAll(localIps);
    subnetIps.removeAll(knownIps);
    await _scanOpenPorts(subnetIps.toList(growable: false), onDeviceFound);
  }

  Future<void> _scanOpenPorts(
    List<String> ips,
    void Function(Device device) onDeviceFound,
  ) async {
    for (var start = 0; start < ips.length; start += 25) {
      final batch = ips.skip(start).take(25).toList(growable: false);
      final openIps = await Future.wait([
        for (final ip in batch) _isPortOpen(ip),
      ]);
      await Future.wait([
        for (var index = 0; index < openIps.length; index++)
          if (openIps[index]) _probe(batch.elementAt(index), onDeviceFound),
      ]);
    }
  }

  Future<bool> _isPortOpen(String ip) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        ip,
        NetworkConstants.defaultPort,
        timeout: const Duration(milliseconds: 600),
      );
      return true;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  Future<void> _probe(
    String ip,
    void Function(Device device) onDeviceFound,
  ) async {
    try {
      final device = await fetchDevice(ip);
      if (device.id != _deviceId) {
        onDeviceFound(device);
      }
    } on DioException {
      // Unreachable addresses are expected during a subnet scan.
    } on SocketException {
      // Unreachable addresses are expected during a subnet scan.
    } on TimeoutException {
      // Unreachable addresses are expected during a subnet scan.
    }
  }

  Future<void> _rememberIp(String ip) async {
    final preferences = await SharedPreferences.getInstance();
    final knownIps = preferences.getStringList(_knownIpsKey) ?? [];
    if (!knownIps.contains(ip)) {
      await preferences.setStringList(_knownIpsKey, [...knownIps, ip]);
    }
  }

  bool _isVirtualInterface(String name) {
    final normalized = name.toLowerCase();
    return normalized.contains('vethernet') ||
        normalized.contains('wsl') ||
        normalized.contains('loopback') ||
        normalized.contains('vmware') ||
        normalized.contains('virtualbox');
  }

  Iterable<String> _subnetAddresses(String ip) sync* {
    final octets = ip.split('.');
    final prefix = '${octets[0]}.${octets[1]}.${octets[2]}';
    for (var host = 1; host <= 254; host++) {
      yield '$prefix.$host';
    }
  }

  Device? _deviceFromService(BonsoirService service) {
    try {
      final attributes = <String, dynamic>{
        ...service.attributes,
        'port': service.port.toString(),
        'address': service.hostAddress,
      };
      return Device.fromJson(attributes);
    } on FormatException catch (error) {
      debugPrint('Ignoring invalid PCDrop service "${service.name}": $error');
      return null;
    }
  }
}

final discoveryServiceProvider = Provider<DiscoveryService>((ref) {
  final service = DiscoveryService();
  ref.onDispose(service.stop);
  return service;
});

final discoveryProvider =
    AsyncNotifierProvider<DiscoveryNotifier, List<Device>>(
      DiscoveryNotifier.new,
    );

class DiscoveryNotifier extends AsyncNotifier<List<Device>> {
  DiscoveryService? _service;
  final Map<String, Device> _devices = {};

  @override
  Future<List<Device>> build() async {
    _service = ref.read(discoveryServiceProvider);
    await _service!.start(
      onDeviceFound: (device) {
        _devices[device.id] = device;
        state = AsyncData(List.unmodifiable(_devices.values));
      },
      onDeviceLost: (deviceId) {
        _devices.remove(deviceId);
        state = AsyncData(List.unmodifiable(_devices.values));
      },
    );
    ref.onDispose(_service!.stop);
    return List.unmodifiable(_devices.values);
  }

  Future<void> stop() async {
    await _service?.stop();
    _devices.clear();
    state = const AsyncData([]);
  }

  Future<Device> addManualDevice(String ip) async {
    final device = await _service!.fetchDevice(ip);
    _devices[device.id] = device;
    state = AsyncData(List.unmodifiable(_devices.values));
    return device;
  }

  Future<void> rescan() async {
    await _service?.scan((device) {
      _devices[device.id] = device;
      state = AsyncData(List.unmodifiable(_devices.values));
    });
  }

  void addAnnouncedDevice(Device device) {
    if (device.id == _service?.localDevice?.id) return;
    _devices[device.id] = device;
    state = AsyncData(List.unmodifiable(_devices.values));
  }
}
