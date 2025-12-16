import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'ble_constants.dart';

class BleConnectionManager extends ChangeNotifier {
  // Singleton pattern not strictly necessary if managed by BleService/Provider,
  // but keeping it simple for now or just a regular class.
  // Since BleService is a singleton, this can be a member.

  BluetoothDevice? _connectedDevice;
  BluetoothDevice? get connectedDevice => _connectedDevice;
  bool get isConnected => _connectedDevice != null;

  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? get writeChar => _writeChar;

  // ignore: unused_field
  BluetoothCharacteristic? _notifyChar;
  // ignore: unused_field
  BluetoothCharacteristic? _notifyCharV2;

  StreamSubscription<List<int>>? _notifySubscription;
  StreamSubscription<List<int>>? _notifySubscriptionV2;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;

  // Scanning State
  bool _isScanning = false;
  bool get isScanning => _isScanning;

  List<ScanResult> _scanResults = [];
  List<ScanResult> get scanResults => _scanResults;

  List<BluetoothDevice> _bondedDevices = [];
  List<BluetoothDevice> get bondedDevices => _bondedDevices;

  // Connection Status String (for UI feedback)
  String _status = "Disconnected";
  String get status => _status;

  // Data Stream for consumers (e.g. BleService -> BleDataProcessor)
  final StreamController<List<int>> _dataStreamController =
      StreamController<List<int>>.broadcast();
  Stream<List<int>> get dataStream => _dataStreamController.stream;

  // Helper stream for connection state changes if needed beyond notifyListeners
  // or just use notifyListeners()

  Future<void> init() async {
    await _requestPermissions();
    await loadBondedDevices();
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await [
        Permission.location,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();
    }
  }

  Future<void> loadBondedDevices() async {
    try {
      final devices = await FlutterBluePlus.bondedDevices;
      _bondedDevices = devices.where((d) {
        String name = d.platformName;
        return BleConstants.targetDeviceNames
            .any((target) => name.contains(target));
      }).toList();
      notifyListeners();
    } catch (e) {
      debugPrint("Error loading bonded devices: $e");
    }
  }

  Future<void> startScan() async {
    if (_isScanning) return;

    await loadBondedDevices();

    _status = "Scanning...";
    _scanResults.clear();
    notifyListeners();

    try {
      await FlutterBluePlus.startScan(
        withServices: [],
        timeout: const Duration(seconds: 10),
      );
      _isScanning = true;
      notifyListeners();

      FlutterBluePlus.scanResults.listen((results) {
        _scanResults = results.where((r) {
          String name = r.device.platformName;
          if (name.isEmpty) name = r.advertisementData.advName;
          return BleConstants.targetDeviceNames
              .any((target) => name.contains(target));
        }).toList();
        notifyListeners();
      });

      FlutterBluePlus.isScanning.listen((scanning) {
        _isScanning = scanning;
        if (!scanning && _scanResults.isEmpty) {
          _status = "No devices found";
        } else if (!scanning && _scanResults.isNotEmpty) {
          _status = "Select a device";
        }
        notifyListeners();
      });
    } catch (e) {
      _status = "Scan Error: $e";
      notifyListeners();
    }
  }

  Future<void> stopScan() async {
    if (_isScanning) {
      await FlutterBluePlus.stopScan();
      _isScanning = false;
      notifyListeners();
    }
  }

  Future<void> connect(BluetoothDevice device, {Function? onConnected}) async {
    _status = "Connecting to ${device.platformName}...";
    notifyListeners();

    try {
      await device.connect();
      _connectedDevice = device;

      _connectionStateSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          disconnect(); // Cleanup
        }
      });

      // Android specific setup
      if (Platform.isAndroid) {
        try {
          await device.requestMtu(512);
        } catch (e) {
          debugPrint("MTU Request Failed: $e");
        }
        try {
          // ignore: deprecated_member_use
          await device.createBond();
        } catch (e) {
          debugPrint("Bonding failed (might be already bonded): $e");
        }
      }

      await _discoverServices(device);

      // Notify success (or let caller handle handshake)
      _status = "Connected to ${device.platformName}";

      if (onConnected != null) {
        await onConnected();
      }

      notifyListeners();
    } catch (e) {
      _status = "Connection Failed: $e";
      disconnect();
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    _status = "Disconnected";

    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;

    _notifySubscription?.cancel();
    _notifySubscription = null;

    _notifySubscriptionV2?.cancel();
    _notifySubscriptionV2 = null;

    if (_connectedDevice != null) {
      await _connectedDevice!.disconnect();
      _connectedDevice = null;
    }

    _writeChar = null;
    _notifyChar = null;
    _notifyCharV2 = null;

    notifyListeners();
  }

  Future<void> _discoverServices(BluetoothDevice device) async {
    List<BluetoothService> services = await device.discoverServices();

    // Reset
    _writeChar = null;
    _notifyChar = null;
    _notifyCharV2 = null;

    // 1. Look for Nordic UART
    try {
      var service = services.firstWhere(
        (s) => s.uuid.toString().toUpperCase() == BleConstants.serviceUuid,
      );
      for (var c in service.characteristics) {
        if (c.uuid.toString().toUpperCase() == BleConstants.writeCharUuid) {
          _writeChar = c;
        }
        if (c.uuid.toString().toUpperCase() == BleConstants.notifyCharUuid) {
          _notifyChar = c;
        }
      }
    } catch (e) {
      debugPrint("Nordic UART service not found: $e");
    }

    // 2. Look for V2 Service
    try {
      var serviceV2 = services.firstWhere(
        (s) =>
            s.uuid.toString().toLowerCase() ==
            BleConstants.serviceUuidV2.toLowerCase(),
      );
      for (var c in serviceV2.characteristics) {
        if (c.uuid.toString().toLowerCase() ==
            BleConstants.notifyCharUuidV2.toLowerCase()) {
          _notifyCharV2 = c;
          debugPrint("Found V2 Notify Characteristic!");
        }
      }
    } catch (e) {
      // expected for V1 devices
    }

    // 3. Fallback
    if (_writeChar == null) {
      for (var s in services) {
        if (s.uuid.toString().startsWith("000018")) continue;
        for (var c in s.characteristics) {
          if (_writeChar == null &&
              (c.properties.write || c.properties.writeWithoutResponse)) {
            _writeChar = c;
          }
          if (_notifyChar == null && c.properties.notify) {
            _notifyChar = c;
          }
        }
      }
    }

    // Subscribe
    if (_notifyChar != null) {
      try {
        await _notifyChar!.setNotifyValue(true);
        _notifySubscription = _notifyChar!.lastValueStream.listen((data) {
          _dataStreamController.add(data);
        });
      } catch (e) {
        debugPrint("Error subscribing to V1 Notify: $e");
      }
    }

    if (_notifyCharV2 != null) {
      try {
        await _notifyCharV2!.setNotifyValue(true);
        _notifySubscriptionV2 = _notifyCharV2!.lastValueStream.listen((data) {
          _dataStreamController.add(data);
        });
      } catch (e) {
        debugPrint("Error subscribing to V2 Notify: $e");
      }
    }
  }

  // Helper for Command Service to send data
  Future<void> writeData(List<int> data) async {
    if (_writeChar != null) {
      await _writeChar!.write(data);
    } else {
      throw Exception("Write Characteristic is null (Not connected?)");
    }
  }
}
