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

  int _spo2 = 0;
  int get spo2 => _spo2;

  int _stress = 0;
  int get stress => _stress;

  String _status = "Disconnected";
  String get status => _status;

  String _lastLog = "No data received";
  String get lastLog => _lastLog;

  final List<String> _protocolLog = [];
  List<String> get protocolLog => List.unmodifiable(_protocolLog);

  void addToProtocolLog(String message, {bool isTx = false}) {
    final timestamp = DateTime.now().toIso8601String().substring(11, 19);
    final prefix = isTx ? "TX" : "RX";
    final logEntry = "[$timestamp] $prefix: $message";

    _protocolLog.add(logEntry);
    if (_protocolLog.length > 1000) {
      _protocolLog.removeAt(0);
    }
    debugPrint(logEntry);
    notifyListeners();
  }

  final int _steps = 0;
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
          if (name.isEmpty) name = r.advertisementData.advName;
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
        if (s.uuid.toString().startsWith("000018")) {
          continue; // Skip standard GATT services
        }

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

  bool _isMeasuringHeartRate = false;
  bool get isMeasuringHeartRate => _isMeasuringHeartRate;

  bool _isMeasuringSpo2 = false;
  bool get isMeasuringSpo2 => _isMeasuringSpo2;

  bool _isMeasuringStress = false;
  bool get isMeasuringStress => _isMeasuringStress;

  Timer? _hrTimer; // Safety max duration (45s)
  Timer? _hrDataTimer; // Silence detector (3s)

  Timer? _spo2Timer; // Safety max duration
  Timer? _spo2DataTimer; // Silence detector

  Timer? _stressTimer; // Safety max duration
  Timer? _stressDataTimer; // Silence detector

  // HR History Parser State
  int _hrLogInterval = 5; // Default 5 mins
  int _hrLogBaseTime = 0; // Unix Timestamp
  int _hrLogCount = 0;

  // SpO2 History Parser State
  int _spo2LogInterval = 5;
  int _spo2LogBaseTime = 0;
  int _spo2LogCount = 0;

  // Sensor Streams
  final StreamController<List<int>> _accelStreamController =
      StreamController<List<int>>.broadcast();
  Stream<List<int>> get accelStream => _accelStreamController.stream;

  final StreamController<List<int>> _ppgStreamController =
      StreamController<List<int>>.broadcast();
  Stream<List<int>> get ppgStream => _ppgStreamController.stream;

  void _onDataReceived(List<int> data) {
    if (data.isEmpty) return;

    // Log raw data
    String hexData =
        data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

    addToProtocolLog(hexData);
    _lastLog = "RX: $hexData";

    // Parse data
    if (data.length > 1) {
      int cmd = data[0];
      int dataOffset = 1;

      if (cmd == 0xA1 && data.length > 2) {
        // Raw Sensor Data
        // Subtypes: 0x03=Accel, 0x01=SpO2 Raw, 0x02=PPG Raw
        int subType = data[1];
        if (subType == 0x03) {
          // Accelerometer
          // Forward entire packet to stream for now
          _accelStreamController.add(data);
        } else if (subType == 0x01 || subType == 0x02) {
          // PPG/SpO2 Raw
          _ppgStreamController.add(data);
        }
        return; // Skip other checks
      }

      if (cmd == 0xA1 && data.length > 2) {
        cmd = data[1];
        dataOffset = 2;
      }

      // Live Heart Rate (0x69)
      if (cmd == PacketFactory.cmdHeartRateMeasurement) {
        // We need to differentiate between HR (0x01) and SpO2 (0x03)
        // Usually the response echoes the type.
        // Let's assume response structure: [Header, SubType, ... Val ...]
        // Based on Python code:
        // Response for Start/RealTime data: [0x69, reading_type, value...]

        int subType = data[dataOffset];
        // Note: dataOffset points to first data byte. Header is data[0] or data[1].
        // If cmd was 0xA1, dataOffset is 2.

        // ReadingType: 1=HR, 3=SpO2
        if (subType == 0x01) {
          // int valueIndex = subType + 2; // Removed unused variable
          // Tahnok docs: "Responses use subdata...".
          // If payload is [Type, Val], then value is at dataOffset + 1
          // If data is [0x69, 0x01, HR], value is at index 2.

          // Let's rely on observation or try generic offset
          // Let's make it more robust.
          // If data=[0x69, 0x01, 0x48, ...], HR=72.
          if (data.length > dataOffset + 2) {
            // Observed format: 69 01 00 [HR] ...
            // Index 2 (dataOffset+1) is often 0 (Status?)
            // Index 3 (dataOffset+2) contains the value
            int val = data[dataOffset + 2];

            // Fallback: Check index 2 if index 3 is 0, just in case
            if (val == 0) val = data[dataOffset + 1];

            if (val > 0) {
              _heartRate = val;
              notifyListeners();

              if (_isMeasuringHeartRate) {
                debugPrint("HR Received ($val) - Continuous Mode");

                // Reset Silence Timer
                _hrDataTimer?.cancel();
                _hrDataTimer = Timer(const Duration(seconds: 3), () {
                  if (_isMeasuringHeartRate) {
                    debugPrint("HR Silence Detected - Resetting State");
                    stopHeartRate();
                  }
                });
              }
            } else {
              debugPrint("HR ACK/Status (0) - Waiting for measurement...");
            }
          }
        } else if (subType == 0x03) {
          // SpO2
          // Debug Log for SpO2
          _lastLog = "SpO2 RX: $subType Len:${data.length}";

          int val = 0;
          if (data.length > dataOffset + 1) {
            val = data[dataOffset + 1];
          }
          // Sometimes value might be at offset+2 if offset+1 is 0x00?
          if (val == 0 && data.length > dataOffset + 2) {
            val = data[dataOffset + 2];
          }

          if (val > 0) {
            _spo2 = val;
            _isMeasuringSpo2 = false; // Auto-stop measurement state
            _lastLog = "SpO2 Success: $val";

            // Polyfill: Add to history immediately
            final now = DateTime.now();
            int minutesFromMidnight = now.hour * 60 + now.minute;
            // Avoid duplicates: remove existing for this minute?
            _spo2History.removeWhere((p) => p.x == minutesFromMidnight);
            _spo2History.add(Point(minutesFromMidnight, val));
            // Keep sorted
            _spo2History.sort((a, b) => a.x.compareTo(b.x));

            notifyListeners();

            if (_isMeasuringSpo2) {
              debugPrint("SpO2 Received ($val) - Auto-stopping");
              stopSpo2();
            }
          } else {
            _lastLog = "SpO2 Zero Val";
            notifyListeners();

            // Even if zero, if we get packets, it's alive.
            if (_isMeasuringSpo2) {
              _spo2DataTimer?.cancel();
              _spo2DataTimer = Timer(const Duration(seconds: 3), () {
                if (_isMeasuringSpo2) {
                  debugPrint("SpO2 Silence Detected - Resetting State");
                  stopSpo2();
                }
              });
            }
          }

          // Cancel timer if we got value
          if (val > 0) {
            _spo2Timer?.cancel();
            _spo2Timer = null;
          }
        }
      }

      // Stress Measurement (0x36)
      // Stress Measurement (0x36 start -> 0x73 value?)
      if (cmd == 0x36 || cmd == 0x73) {
        // If 0x36: Start/Stop ACKs
        if (cmd == 0x36) {
          if (data.length > 1 && data[1] == 0x02) {
            debugPrint("Stress Stop ACK - Ignore");
            return;
          }
          debugPrint("Stress Start ACK");
        }

        // If 0x73: Data Packet
        if (cmd == 0x73 && data.length > 2) {
          final hex =
              data.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ');
          debugPrint("Stress Raw Packet (0x73): $hex");

          // Hypothesis: Index 1 is Stress? (0x0C = 12?)
          // Or Index 4?
          int val = data[1];
          if (val == 0 && data.length > 4) val = data[4];

          // Accept 0 if it's a valid packet for debug?
          // But usually Stress > 0.
          if (val > 0) {
            _stress = val;
            notifyListeners();
            debugPrint("Stress Calculated: $val");

            if (_isMeasuringStress) {
              // Silence Timer
              _stressDataTimer?.cancel();
              _stressDataTimer = Timer(const Duration(seconds: 3), () {
                if (_isMeasuringStress) {
                  debugPrint("Stress Silence Detected - Resetting State");
                  stopStress();
                }
              });
            }
          }
        }
      }

      // SpO2 Log New (0xBC)
      // SpO2 Log New (0xBC)
      if (cmd == PacketFactory.cmdSyncSpo2HistoryNew) {
        debugPrint("Received 0xBC SpO2 Log Packet: $hexData");
        if (data.length > 1) {
          int sub = data[1];
          if (sub == 0xEE)
            debugPrint("SpO2 (0xBC) Status: EMPTY/End (0xEE)");
          else
            debugPrint("SpO2 (0xBC) Subtype: ${sub.toRadixString(16)}");
        }
      }

      // SpO2 Log (0x16)
      if (cmd == PacketFactory.cmdGetSpo2Log) {
        if (data.length < 2) return;
        int subType = data[dataOffset];

        if (subType == 0 || subType == 0xF0) {
          // Start Packet
          // Packet: [16, 00, INTERVAL, ...]
          // Interval is at offset+1 (Index 2)
          if (data.length > dataOffset + 1) {
            int interval = data[dataOffset + 1];
            if (interval > 0) _spo2LogInterval = interval;
          }
          debugPrint(
              "SpO2 Log Start: Interval=$_spo2LogInterval SubType=${subType.toRadixString(16)}");
          _spo2History.clear();
          notifyListeners();
        } else if (subType == 1) {
          // Timestamp Packet
          if (data.length >= dataOffset + 5) {
            int t0 = data[dataOffset + 1];
            int t1 = data[dataOffset + 2];
            int t2 = data[dataOffset + 3];
            int t3 = data[dataOffset + 4];
            _spo2LogBaseTime = t0 | (t1 << 8) | (t2 << 16) | (t3 << 24);
            _spo2LogCount = 0;
            debugPrint("SpO2 Log TimeBlock: $_spo2LogBaseTime");

            // Data starts at dataOffset + 5
            int startData = dataOffset + 5;
            for (int i = startData;
                i < data.length - 1 && i < startData + 9;
                i++) {
              int val = data[i];
              if (val != 0 && val != 255) {
                _addSpo2Point(val);
              }
              _spo2LogCount++;
            }
          }
        } else {
          // Data Packet
          int startData = dataOffset + 1;
          for (int i = startData;
              i < data.length - 1 && i < startData + 13;
              i++) {
            int val = data[i];
            if (val != 0 && val != 255) {
              _addSpo2Point(val);
            }
            _spo2LogCount++;
          }
          notifyListeners();
        }
      }

      // Steps History (0x43)
      if (cmd == PacketFactory.cmdGetSteps) {
        if (data.length < 13) return;
        int byte1 = data[dataOffset];
        if (byte1 == 0xF0) {
          debugPrint("Steps Log Start");
          _stepsHistory.clear();
        } else if (byte1 != 0xFF) {
          int baseTimeIndex = data[dataOffset + 3]; // e.g. 0, 4, 8...

          // Data starts at offset + 8 (index 9)
          // We assume 4 entries of 2 bytes each (Steps only) to fit in 20 bytes
          // Layout: [Idx] [Date 4b?] [S0] [S1] [S2] [S3]
          int startSteps = dataOffset + 8;
          int count = 0;

          // Read up to 4 entries, ensuring we don't read past valid data
          while (count < 4 && (startSteps + (count * 2) + 1) < data.length) {
            int idx = startSteps + (count * 2);
            int stepsVal = data[idx] | (data[idx + 1] << 8);

            if (stepsVal > 0) {
              // Only add non-zero steps? Or all?
              // Adding 0 is fine for "No steps walked", good for graph continuity
              _stepsHistory.add(Point(baseTimeIndex + count, stepsVal));
            }
            count++;
          }
          if (count > 0) notifyListeners();
        }
      }

      // Battery Level (0x03)
      if (cmd == PacketFactory.cmdGetBattery) {
        int levelIndex = 1 + (dataOffset - 1);
        if (data.length > levelIndex) {
          _batteryLevel = data[levelIndex];
          notifyListeners();
        }
      }

      // Heart Rate Log (0x15) - UPDATED with Timestamp Logic
      if (cmd == PacketFactory.cmdGetHeartRateLog) {
        if (data.length < 2) return;
        int subType = data[dataOffset];

        if (subType == 0) {
          // Start Packet
          // Packet: [15, 00, 18, 05, ...]
          // It seems HR stores INTERVAL at offset+2 (Index 3, value 05)
          // The byte at offset+1 (0x18) might be a flag or length.
          if (data.length > dataOffset + 2) {
            int interval = data[dataOffset + 2];
            if (interval > 0) _hrLogInterval = interval;
          }
          debugPrint("HR Log Start: Interval=$_hrLogInterval");
          _hrHistory.clear();
        } else if (subType == 1) {
          // Timestamp Packet
          // Timestamp at dataOffset+1 (4 bytes LE)
          if (data.length >= dataOffset + 5) {
            int t0 = data[dataOffset + 1];
            int t1 = data[dataOffset + 2];
            int t2 = data[dataOffset + 3];
            int t3 = data[dataOffset + 4];
            _hrLogBaseTime = t0 | (t1 << 8) | (t2 << 16) | (t3 << 24);
            _hrLogCount = 0; // Reset point counter for this block

            debugPrint("HR Log TimeBlock: $_hrLogBaseTime");

            // Data starts at dataOffset + 5
            int startData = dataOffset + 5;
            for (int i = startData;
                i < data.length - 1 && i < startData + 9;
                i++) {
              int val = data[i];
              if (val != 0 && val != 255) {
                _addHrPoint(val);
              }
              _hrLogCount++;
            }
          }
        } else {
          // Data Packet (Continues from previous time block)
          // Data starts at dataOffset + 1
          int startData = dataOffset + 1;
          for (int i = startData;
              i < data.length - 1 && i < startData + 13;
              i++) {
            int val = data[i];
            if (val != 0 && val != 255) {
              _addHrPoint(val);
            }
            _hrLogCount++;
          }
          notifyListeners();
        }
      } else {
        // Log Unknown Commands
        debugPrint("RX UNKNOWN ($cmd): $hexData");
      }
    }
  }

  void _addHrPoint(int hrValue) {
    if (_hrLogBaseTime == 0) return;

    // Calculate time for this point in Minutes From Midnight
    // Time = Base + (Count * Interval * 60)
    int pointTimeSeconds = _hrLogBaseTime + (_hrLogCount * _hrLogInterval * 60);
    DateTime dt = DateTime.fromMillisecondsSinceEpoch(pointTimeSeconds * 1000);

    // Filter by Selected Date
    // If dt is not on the same day as selectedDate, ignore it.
    if (dt.year != _selectedDate.year ||
        dt.month != _selectedDate.month ||
        dt.day != _selectedDate.day) {
      debugPrint(
          "Skipping HR Point: Date Mismatch - Point: $dt, Selected: $_selectedDate");
      return;
    }

    // Filter Future Data
    // Device might send garbage timestamps or "next day" init data
    if (dt.isAfter(DateTime.now())) {
      debugPrint("Skipping HR Point: Future Data - Point: $dt");
      return;
    }

    int minutesFromMidnight = dt.hour * 60 + dt.minute;
    debugPrint(
        "Adding HR Point: $dt ($minutesFromMidnight min) = $hrValue BPM");

    // Avoid duplicate X values if possible, or just add
    // List<Point> allows duplicates, Graph will plot them
    _hrHistory.add(Point(minutesFromMidnight, hrValue));
  }

  void _addSpo2Point(int val) {
    if (_spo2LogBaseTime == 0) return;
    int pointTimeSeconds =
        _spo2LogBaseTime + (_spo2LogCount * _spo2LogInterval * 60);
    DateTime dt = DateTime.fromMillisecondsSinceEpoch(pointTimeSeconds * 1000);

    if (dt.year != _selectedDate.year ||
        dt.month != _selectedDate.month ||
        dt.day != _selectedDate.day) {
      debugPrint(
          "Skipping SpO2 Point: Date Mismatch - Point: $dt, Selected: $_selectedDate");
      return;
    }
    if (dt.isAfter(DateTime.now())) {
      debugPrint("Skipping SpO2 Point: Future Data - Point: $dt");
      return;
    }

    int minutesFromMidnight = dt.hour * 60 + dt.minute;
    debugPrint("Adding SpO2 Point: $dt = $val %");
    _spo2History.add(Point(minutesFromMidnight, val));
  }

  Future<void> startHeartRate() async {
    if (_writeChar == null) return;

    // Mutual Exclusion: Stop SpO2 if running
    if (_isMeasuringSpo2) {
      debugPrint("Stopping SpO2 to start Heart Rate");
      await stopSpo2();
    }

    try {
      _isMeasuringHeartRate = true;
      notifyListeners();

      // Send Command ONCE
      List<int> packet = PacketFactory.startHeartRate();
      final hex =
          packet.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      addToProtocolLog(hex + " (Start HR)", isTx: true);
      await _writeChar!.write(packet);
      debugPrint("Sent Single HR Request");

      // Schedule Timeout Safety (Max Duration)
      _hrTimer?.cancel();
      _hrTimer = Timer(const Duration(seconds: 45), () {
        if (_isMeasuringHeartRate) {
          debugPrint("HR Timeout - Force Stopping");
          stopHeartRate();
          _lastLog = "HR Timeout";
          notifyListeners();
        }
      });
    } catch (e) {
      debugPrint("Error starting HR: $e");
      _isMeasuringHeartRate = false;
      notifyListeners();
    }
  }

  Future<void> stopHeartRate() async {
    // Immediate cleanup
    _hrTimer?.cancel();
    _hrDataTimer?.cancel();
    _isMeasuringHeartRate = false;
    notifyListeners();

    if (_writeChar == null) return;

    try {
      // 1. Disable Periodic Monitoring (Ensure LED off)
      // Note: We used to send 0x69 0x01 0x00 here, but that seems to RE-START the sensor!
      // So we ONLY send the Disable command (0x16 0x02).

      List<int> p2 = PacketFactory.disableHeartRate();
      final hex2 = p2.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      addToProtocolLog(hex2 + " (Disable HR)", isTx: true);
      await _writeChar!.write(p2);
    } catch (e) {
      debugPrint("Error sending stop HR: $e");
    }
  }

  Future<void> startSpo2() async {
    if (_writeChar == null) return;

    // Mutual Exclusion: Stop Heart Rate if running
    if (_isMeasuringHeartRate) {
      debugPrint("Stopping Heart Rate to start SpO2");
      await stopHeartRate();
    }

    try {
      _isMeasuringSpo2 = true;
      notifyListeners();

      // Send Command ONCE
      List<int> packet = PacketFactory.startSpo2();
      final hex =
          packet.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      addToProtocolLog(hex + " (Start SpO2)", isTx: true);
      await _writeChar!.write(packet);

      // Schedule Timeout Safety
      _spo2Timer?.cancel();
      _spo2Timer = Timer(const Duration(seconds: 45), () {
        if (_isMeasuringSpo2) {
          debugPrint("SpO2 Timeout - Force Stopping");
          stopSpo2();
          _lastLog = "SpO2 Timeout";
          notifyListeners();
        }
      });
    } catch (e) {
      debugPrint("Error starting SpO2: $e");
      _isMeasuringSpo2 = false;
      notifyListeners();
    }
  }

  Future<void> stopSpo2() async {
    if (_writeChar == null) return;
    _isMeasuringSpo2 = false;
    _spo2Timer?.cancel();
    _spo2DataTimer?.cancel();
    notifyListeners();
    try {
      // Send SpO2 Stop Packets
      // 1. Stop Real-Time Measurement (New Standard)
      Uint8List p1 = PacketFactory.stopRealTimeSpo2();
      addToProtocolLog(
          "${p1.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')} (Stop SpO2-RT)",
          isTx: true);
      await _writeChar!.write(p1);

      await Future.delayed(const Duration(milliseconds: 100));

      // 2. Disable Periodic (Old Method, just in case)
      List<Uint8List> packets = PacketFactory.stopSpo2();
      for (var packet in packets) {
        addToProtocolLog(
            "${packet.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')} (Disable SpO2)",
            isTx: true);
        await _writeChar!.write(packet);
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // Also send Heart Rate Stop (as a "Master Stop")
      Uint8List p2 = PacketFactory.stopHeartRate();
      addToProtocolLog(
          "${p2.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')} (Stop HR-Master)",
          isTx: true);
      await _writeChar!.write(p2);
    } catch (e) {
      debugPrint("Error stop SpO2: $e");
    }
  }

  Future<void> stopAllMeasurements() async {
    debugPrint("Stopping ALL measurements");
    if (_isMeasuringHeartRate) await stopHeartRate();
    if (_isMeasuringSpo2) await stopSpo2();
    if (_isMeasuringStress) await stopStress();
  }

  Future<void> startStress() async {
    if (_writeChar == null) return;

    // Mutual Exclusion
    if (_isMeasuringHeartRate) await stopHeartRate();
    if (_isMeasuringSpo2) await stopSpo2();

    try {
      _isMeasuringStress = true;
      notifyListeners();

      List<int> packet = PacketFactory.startStress();
      addToProtocolLog("TX: 36 01 ... (Start Stress)", isTx: true);
      await _writeChar!.write(packet);

      // Safety Timer (120s - HRV takes time)
      _stressTimer?.cancel();
      _stressTimer = Timer(const Duration(seconds: 120), () {
        if (_isMeasuringStress) {
          debugPrint("Stress Timeout - Force Stopping");
          stopStress();
        }
      });
    } catch (e) {
      debugPrint("Error starting Stress: $e");
      _isMeasuringStress = false;
      notifyListeners();
    }
  }

  Future<void> stopStress() async {
    // Immediate cleanup
    _stressTimer?.cancel();
    _stressDataTimer?.cancel();
    _isMeasuringStress = false;
    notifyListeners();

    if (_writeChar == null) return;

    try {
      await _writeChar!.write(PacketFactory.stopStress());
      addToProtocolLog("TX: 36 02 ... (Stop Stress)", isTx: true);
    } catch (e) {
      debugPrint("Error stopping Stress: $e");
    }
  }

  int _intToBcd(int b) {
    return ((b ~/ 10) << 4) | (b % 10);
  }

  Future<void> syncTime() async {
    if (_writeChar == null) return;

    final now = DateTime.now();
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
        command: PacketFactory.cmdSetTime,
        data: timeData,
      );
      await _writeChar!.write(packet);
    } catch (e) {
      debugPrint("Error syncing time: $e");
    }
  }

  DateTime _selectedDate = DateTime.now();
  DateTime get selectedDate => _selectedDate;

  void setSelectedDate(DateTime date) {
    _selectedDate = date;
    notifyListeners();
    // Auto-sync when date changes? Or let UI trigger it?
    // Let's clear current data to avoid confusion
    _hrHistory.clear();
    _stepsHistory.clear();
    _lastLog = "Date changed to $date";
    notifyListeners();
  }

  Future<void> syncHistory() async {
    if (_writeChar == null) return;

    try {
      // Calculate day offset
      // 0 = Today, 1 = Yesterday
      // Protocol likely uses "Day Offset" (0, 1, 2...)
      final now = DateTime.now();
      final difference = now.difference(_selectedDate).inDays;
      // Ensure positive or zero
      int offset = difference < 0 ? 0 : difference;

      debugPrint(
          "Requesting Steps for Offset: $offset (${_selectedDate.toString()})");

      List<int> packet = PacketFactory.getStepsPacket(dayOffset: offset);
      await _writeChar!.write(packet);
    } catch (e) {
      debugPrint("Error syncing history: $e");
    }
  }

  int _batteryLevel = 0;
  int get batteryLevel => _batteryLevel;

  // HR History as Points (Time, Value)
  final List<Point> _hrHistory = [];
  List<Point> get hrHistory => _hrHistory;

  final List<Point> _spo2History = [];
  List<Point> get spo2History => _spo2History;

  // Steps History as Points (TimeIndex, Steps)
  final List<Point> _stepsHistory = [];
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
      final startOfDay =
          DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
      debugPrint("Requesting HR for: $startOfDay");
      await _writeChar!.write(
        PacketFactory.getHeartRateLogPacket(startOfDay),
      );
    } catch (e) {
      debugPrint("Error syncing HR history: $e");
    }
  }

  Future<void> syncSpo2History() async {
    if (_writeChar == null) return;
    try {
      final startOfDay =
          DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
      debugPrint("Requesting SpO2 History for: $startOfDay");

      final now = DateTime.now();
      final difference = now.difference(_selectedDate).inDays;
      int offset = difference < 0 ? 0 : difference;

      await _writeChar!
          .write(PacketFactory.getSpo2LogPacket(dayOffset: offset));

      // Also try the new sync command (0xBC)
      await Future.delayed(const Duration(milliseconds: 500));
      debugPrint("Requesting SpO2 History (New Protocol 0xBC)...");
      await _writeChar!.write(PacketFactory.getSpo2LogPacketNew());
    } catch (e) {
      debugPrint("Error syncing SpO2 history: $e");
    }
  }

  Future<void> forceStopEverything() async {
    if (_writeChar == null) return;
    debugPrint("Force Stopping: Executing 'Hijack Strategy'...");
    try {
      // 1. BURST Disable Raw Data (0xA1 0x02)
      for (int i = 0; i < 3; i++) {
        await disableRawData();
        await Future.delayed(const Duration(milliseconds: 50));
      }

      // 2. HIJACK: Start SpO2 (0x69 0x03 0x01)
      // The user confirmed starting SpO2 stops the stuck Green Light (HR).
      // We switch context to SpO2, which we hope to control better.
      debugPrint("Hijacking with SpO2 start...");
      await _writeChar!.write(PacketFactory.startSpo2());
      await Future.delayed(
          const Duration(milliseconds: 1500)); // Wait for it to take over

      // 3. KILL SpO2 (0x2C 0x02 0x00)
      // Now we disable the SpO2 monitor we just started.
      debugPrint("Killing SpO2...");
      await _writeChar!
          .write(PacketFactory.createPacket(command: 0x2C, data: [0x02, 0x00]));
      _isMeasuringSpo2 = false;
      _spo2Timer?.cancel();
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 200));

      // 4. Disable Heart Rate Schedule (0x16 0x02 0x00)
      // Just to be sure the schedule is clear.
      await _writeChar!.write(PacketFactory.disableHeartRate());
      _isMeasuringHeartRate = false;
      _hrTimer?.cancel();
      notifyListeners();

      // 5. Disable Stress (0x36 0x02 0x00)
      await _writeChar!
          .write(PacketFactory.createPacket(command: 0x36, data: [0x02, 0x00]));

      debugPrint("Hijack Stop Completed.");
    } catch (e) {
      debugPrint("Error during Force Stop: $e");
    }
  }

  Future<void> rebootRing() async {
    if (_writeChar == null) return;
    debugPrint("Rebooting Ring...");
    try {
      // Command 0x08 is Reboot
      await _writeChar!.write(PacketFactory.createPacket(command: 0x08));
    } catch (e) {
      debugPrint("Error rebooting: $e");
    }
  }

  Future<void> sendRawPacket(List<int> packet) async {
    if (_writeChar == null) return;
    try {
      addToProtocolLog(
          "${packet.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')} (Manual)",
          isTx: true);
      await _writeChar!.write(packet);
    } catch (e) {
      debugPrint("Error sending raw packet: $e");
    }
  }

  Future<void> syncAllData() async {
    await syncTime();
    await getBatteryLevel();
    await syncHistory();
    await syncHeartRateHistory();
    await syncSpo2History();
  }

  Future<void> enableRawData() async {
    if (_writeChar == null) return;
    debugPrint("Enabling Raw Data Stream...");
    await _writeChar!.write(PacketFactory.enableRawDataPacket());
  }

  Future<void> disableRawData() async {
    if (_writeChar == null) return;
    debugPrint("Disabling Raw Data Stream...");
    await _writeChar!.write(PacketFactory.disableRawDataPacket());
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
