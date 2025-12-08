import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'packet_factory.dart';

class BleService extends ChangeNotifier {
  static final BleService _instance = BleService._internal();
  factory BleService() => _instance;
  BleService._internal();

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? _notifyChar;

  StreamSubscription<List<int>>? _notifySubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;

  // State
  bool _isScanning = false;
  bool get isScanning => _isScanning;

  bool get isConnected => _connectedDevice != null && _writeChar != null;

  int _heartRate = 0;
  int get heartRate => _heartRate;

  String _status = "Disconnected";
  String get status => _status;

  String _lastLog = "No data received";
  String get lastLog => _lastLog;

  int _steps = 0;
  int get steps => _steps;

  // Device Name Filters
  static const List<String> _targetDeviceNames = [
    "R12",
    "R10",
    "R06",
    "R02",
    "Ring",
    "Yawell",
  ];

  Future<void> init() async {
    // Check permissions
    await _requestPermissions();

    // Listen to scan results if needed, but we'll trigger scans manually
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

  List<ScanResult> _scanResults = [];
  List<ScanResult> get scanResults => _scanResults;

  Future<void> startScan() async {
    if (_isScanning) return;

    // Reset
    _status = "Scanning...";
    _scanResults.clear();
    notifyListeners();

    try {
      await FlutterBluePlus.startScan(
        withServices: [], // Scan all
        timeout: const Duration(seconds: 10),
      );
      _isScanning = true;
      notifyListeners();

      FlutterBluePlus.scanResults.listen((results) {
        // Filter results based on target names
        _scanResults = results.where((r) {
          String name = r.device.platformName;
          if (name.isEmpty) name = r.advertisementData.localName;
          return _targetDeviceNames.any((target) => name.contains(target));
        }).toList();
        notifyListeners();
      });

      // Stop scanning after timeout automatically handled by FBP,
      // but we should listen to isScanning stream if we want exact state
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

  Future<void> connectToDevice(BluetoothDevice device) async {
    await _connect(device);
  }

  Future<void> _connect(BluetoothDevice device) async {
    _status = "Connecting to ${device.platformName}...";
    notifyListeners();

    try {
      await device.connect();
      _connectedDevice = device;

      _connectionStateSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _cleanup();
          _status = "Disconnected";
          notifyListeners();
        }
      });

      // MTU Logic
      if (Platform.isAndroid) {
        // Request MTU 512
        try {
          await device.requestMtu(512);
        } catch (e) {
          debugPrint("MTU Request Failed: $e");
        }
      }

      await _discoverServices(device);

      // Sync Time
      await syncTime();

      _status = "Connected to ${device.platformName}";
      notifyListeners();
    } catch (e) {
      _status = "Connection Failed: $e";
      _cleanup();
      notifyListeners();
    }
  }

  // Nordic UART Service UUIDs
  static const String _serviceUuid = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
  static const String _writeCharUuid = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";
  static const String _notifyCharUuid = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";

  Future<void> _discoverServices(BluetoothDevice device) async {
    List<BluetoothService> services = await device.discoverServices();

    // Find the Nordic UART service
    BluetoothService? targetService;
    try {
      targetService = services.firstWhere(
        (s) => s.uuid.toString().toUpperCase() == _serviceUuid,
      );
    } catch (e) {
      debugPrint(
        "Nordic UART service not found by exact UUID, scanning all...",
      );
    }

    if (targetService != null) {
      for (var c in targetService.characteristics) {
        if (c.uuid.toString().toUpperCase() == _writeCharUuid) {
          _writeChar = c;
        }
        if (c.uuid.toString().toUpperCase() == _notifyCharUuid) {
          _notifyChar = c;
        }
      }
    } else {
      // Fallback logic for safety, but try to avoid system services
      for (var s in services) {
        if (s.uuid.toString().startsWith("000018"))
          continue; // Skip standard GATT services

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

    if (_notifyChar != null) {
      try {
        await _notifyChar!.setNotifyValue(true);
        _notifySubscription = _notifyChar!.lastValueStream.listen(
          _onDataReceived,
        );
      } catch (e) {
        debugPrint("Failed to subscribe to notify char: $e");
      }
    } else {
      debugPrint("No Notification Characteristic Found");
    }
  }

  void _onDataReceived(List<int> data) {
    if (data.isEmpty) return;

    // Log raw data for debugging
    _lastLog = data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    notifyListeners();

    // Parse data
    // Example: Heart Rate is usually in a specific packet.
    // If we sent 0x69, we expect a response.
    // Often 0x69 response: Header (0xA1?) + 0x69 + HR_Value + ...

    // Simple heuristic for HR for now:
    // If the packet corresponds to HR measurement.
    // Let's interpret user requirement: "Real-time Heart Rate value (updates via Notify stream)"
    // We assume the device sends packets. We need to identify them.
    // For now, let's look for the command 0x69 or similar in the response.
    // Or if it's a standard HR service (0x180D), but this uses a custom protocol.

    // Warning: without the exact response protocol, this is a guess.
    // I'll assume byte 1 is the command echo?
    // If we sent 0x69, we expect a response.
    // Response has Command at byte 0.
    if (data.length > 1) {
      int cmd = data[0];
      int dataOffset = 1;

      // Heuristic: If index 0 is 0xA1 (Header), look at index 1 for command
      // This handles cases where response includes header but request does not.
      if (cmd == 0xA1 && data.length > 2) {
        cmd = data[1];
        dataOffset = 2;
      }

      // Live Heart Rate (0x69)
      if (cmd == PacketFactory.CMD_HEART_RATE_MEASUREMENT) {
        // Debug Log showed: 69 00 00 00 00 00 6c 03 ...
        // Index 6 seems to be the value.
        // Corrected Request [1, 1] -> Expect value at index 3
        int valueIndex = 3 + (dataOffset - 1);

        if (data.length > valueIndex) {
          _heartRate = data[valueIndex];
          notifyListeners();
        }
      }

      // Steps History (0x43)
      if (cmd == PacketFactory.CMD_GET_STEPS) {
        // Protocol based on colmi_r02_client SportDetailParser
        // Packet[1] might be sub-type or year BCD?
        // Header: packet[1] == 0xF0 (240)

        if (data.length < 13) return;

        int byte1 = data[dataOffset];
        if (byte1 == 0xF0) {
          // Header / Start
          debugPrint("Steps Log Start: Packet[3]=${data[dataOffset + 2]}");
          _stepsHistory.clear();
          // Optional: Reset total steps if we are summing them up
        } else if (byte1 != 0xFF) {
          // 0xFF is error
          // Data Packet
          // byte1 = Year BCD (ignored)
          // byte2 = Month BCD
          // byte3 = Day BCD
          int timeIndex = data[dataOffset + 3]; // Index 4 in raw packet

          // Steps at index 9, 10 (relative to 0) -> DataOffset + 8, +9
          int stepsVal = data[dataOffset + 8] | (data[dataOffset + 9] << 8);

          if (stepsVal > 0) {
            // Store in map or list
            _stepsHistory.add(Point(timeIndex, stepsVal));
            notifyListeners();
          }
        }
      }

      // Battery Level (0x03)
      if (cmd == PacketFactory.CMD_GET_BATTERY) {
        // Assuming Battery Level is at index 1 (standard) or index 2 (if header)
        // Payload usually: [Level] ...
        int levelIndex = 1 + (dataOffset - 1);
        if (data.length > levelIndex) {
          _batteryLevel = data[levelIndex];
          notifyListeners();
        }
      }

      // Heart Rate Log (0x15)
      if (cmd == PacketFactory.CMD_GET_HEART_RATE_LOG) {
        if (data.length < 2) return;
        int subType = data[dataOffset];

        if (subType == 0) {
          // Start Packet: Reset history
          debugPrint(
            "HR Log Start: Size=${data[dataOffset + 1]}, Interval=${data[dataOffset + 2]}",
          );
          _hrHistory.clear();
        } else if (subType == 1) {
          // Timestamp Packet (Contains data too)
          int startData = dataOffset + 5;
          for (
            int i = startData;
            i < data.length - 1 && i < startData + 9;
            i++
          ) {
            int val = data[i];
            if (val != 0 && val != 255) {
              _hrHistory.add(val);
            }
          }
        } else {
          // Data Packet
          int startData = dataOffset + 1;
          for (
            int i = startData;
            i < data.length - 1 && i < startData + 13;
            i++
          ) {
            int val = data[i];
            if (val != 0 && val != 255) {
              _hrHistory.add(val);
            }
          }
          notifyListeners();
        }
      }
    }
  }

  bool _isMeasuringHeartRate = false;
  bool get isMeasuringHeartRate => _isMeasuringHeartRate;
  Timer? _hrMeasurementTimer;

  Future<void> startHeartRate() async {
    if (_writeChar == null) return;

    _isMeasuringHeartRate = true;
    notifyListeners();

    // Function to send the start command
    Future<void> sendStartCmd() async {
      try {
        if (!_isMeasuringHeartRate) return;
        List<int> packet = PacketFactory.startHeartRate();
        await _writeChar!.write(packet);
        debugPrint("Sent Heartbeat Start HR Command");
      } catch (e) {
        debugPrint("Error sending start HR: $e");
        _isMeasuringHeartRate = false;
        _hrMeasurementTimer?.cancel();
        notifyListeners();
      }
    }

    // Send immediately
    await sendStartCmd();

    // Schedule periodic resend every 2 seconds (aggressive) or 5-10s
    // If the ring stops automatically after a few seconds, we need to restart it.
    // Let's try every 2 seconds to keep it "live".
    _hrMeasurementTimer?.cancel();
    _hrMeasurementTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      sendStartCmd();
    });
  }

  Future<void> stopHeartRate() async {
    if (_writeChar == null) return;

    _isMeasuringHeartRate = false;
    _hrMeasurementTimer?.cancel(); // Stop the loop
    notifyListeners();

    try {
      List<int> packet = PacketFactory.stopHeartRate();
      await _writeChar!.write(packet);
    } catch (e) {
      debugPrint("Error sending stop HR: $e");
    }
  }

  int _intToBcd(int b) {
    return ((b ~/ 10) << 4) | (b % 10);
  }

  Future<void> syncTime() async {
    if (_writeChar == null) return;

    final now = DateTime.now();
    // Protocol based on colmi_r02_client:
    // CMD 0x01
    // Data: Year%2000, Month, Day, Hour, Min, Sec (All BCD encoded)
    // Byte 6: 1 (Language: English)

    List<int> timeData = [
      _intToBcd(now.year % 2000),
      _intToBcd(now.month),
      _intToBcd(now.day),
      _intToBcd(now.hour),
      _intToBcd(now.minute),
      _intToBcd(now.second),
      1, // Language 1=English
    ];

    try {
      List<int> packet = PacketFactory.createPacket(
        command: PacketFactory.CMD_SET_TIME,
        data: timeData,
      );
      await _writeChar!.write(packet);
    } catch (e) {
      debugPrint("Error syncing time: $e");
    }
  }

  Future<void> syncHistory() async {
    if (_writeChar == null) return;

    try {
      // Request Steps for today (Offset 0)
      List<int> packet = PacketFactory.getStepsPacket(dayOffset: 0);
      await _writeChar!.write(packet);
    } catch (e) {
      debugPrint("Error syncing history: $e");
    }
  }

  int _batteryLevel = 0;
  int get batteryLevel => _batteryLevel;

  List<int> _hrHistory = [];
  List<int> get hrHistory => _hrHistory;

  // Using a simple Point class for steps (TimeIndex, Steps)
  List<Point> _stepsHistory = [];
  List<Point> get stepsHistory => _stepsHistory;

  Future<void> getBatteryLevel() async {
    if (_writeChar == null) return;
    try {
      await _writeChar!.write(PacketFactory.getBatteryPacket());
    } catch (e) {
      debugPrint("Error getting battery: $e");
    }
  }

  Future<void> syncHeartRateHistory() async {
    if (_writeChar == null) return;
    try {
      // Request for today
      // For simplicity, just requesting today's log
      // In a real app, we might iterate over days
      await _writeChar!.write(
        PacketFactory.getHeartRateLogPacket(DateTime.now()),
      );
    } catch (e) {
      debugPrint("Error syncing HR history: $e");
    }
  }

  void _cleanup() {
    _connectedDevice = null;
    _writeChar = null;
    _notifyChar = null;
    _notifySubscription?.cancel();
    _connectionStateSubscription?.cancel();
    _heartRate = 0;
    _batteryLevel = 0;
    _hrHistory.clear();
  }
}

class Point {
  final int x;
  final int y;
  Point(this.x, this.y);
}
