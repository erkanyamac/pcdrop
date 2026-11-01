import 'dart:async';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:uuid/uuid.dart';

import '../core/constants.dart';
import '../models/device.dart';

class DiscoveryService {
  DiscoveryService({
    DeviceInfoPlugin? deviceInfo,
    NetworkInfo? networkInfo,
    Uuid? uuid,
  }) : _deviceInfo = deviceInfo ?? DeviceInfoPlugin(),
       _networkInfo = networkInfo ?? NetworkInfo(),
       _uuid = uuid ?? const Uuid();

  final DeviceInfoPlugin _deviceInfo;
  final NetworkInfo _networkInfo;
  final Uuid _uuid;

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

    final localIp = await _networkInfo.getWifiIP();
    _localIp = localIp;
    final service = BonsoirService(
      name: localDevice.alias,
      type: NetworkConstants.serviceType,
      hostAddresses: localIp == null ? const [] : [localIp],
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
}
