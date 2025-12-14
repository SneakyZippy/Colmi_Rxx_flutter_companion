import 'dart:async';
import 'dart:io';
import 'dart:math'; // For Point

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'packet_factory.dart';

class BleService extends ChangeNotifier {
  static final BleService _instance = BleService._internal();
  factory BleService() => _instance;
  BleService._internal();

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? _notifyChar;
  BluetoothCharacteristic? _notifyCharV2;

  StreamSubscription<List<int>>? _notifySubscription;
  StreamSubscription<List<int>>? _notifySubscriptionV2;
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

  int _hrv = 0; // New HRV Metric
  int get hrv => _hrv;

  bool _isMeasuringStress = false;
  bool get isMeasuringStress => _isMeasuringStress;

  bool _isMeasuringHrv = false; // New Split
  bool get isMeasuringHrv => _isMeasuringHrv;

  Timer? _hrvDataTimer; // Auto-stop timer for HRV

  String _status = "Disconnected";
  String get status => _status;

  String _lastLog = "No data received";
  String get lastLog => _lastLog;

  final List<String> _protocolLog = [];
  List<String> get protocolLog => List.unmodifiable(_protocolLog);

  void _log(String message) {
    debugPrint("[${DateTime.now().toString().substring(11, 19)}] $message");
  }

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

    // Load paired devices
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

  List<ScanResult> _scanResults = [];
  List<ScanResult> get scanResults => _scanResults;

  List<BluetoothDevice> _bondedDevices = [];
  List<BluetoothDevice> get bondedDevices => _bondedDevices;

  Future<void> loadBondedDevices() async {
    try {
      final devices = await FlutterBluePlus.bondedDevices;
      _bondedDevices = devices.where((d) {
        String name = d
            .platformName; // Note: platformName might be empty if not connected?
        // Actually bonded devices usually have a name cached by OS.
        return _targetDeviceNames.any((target) => name.contains(target));
      }).toList();
      notifyListeners();
    } catch (e) {
      debugPrint("Error loading bonded devices: $e");
    }
  }

  Future<void> startScan() async {
    if (_isScanning) return;

    // Refresh paired devices
    await loadBondedDevices();

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

      // Android Bonding (Crucial for some rings)
      if (Platform.isAndroid) {
        try {
          debugPrint("Attempting to bond...");
          await device.createBond();
        } catch (e) {
          debugPrint("Bonding failed (might be already bonded): $e");
        }
      }

      await _discoverServices(device);

      // Delay initialization (match Gadgetbridge's 2s delay for ring to settle)
      debugPrint("Waiting 2s for ring to settle...");
      await Future.delayed(const Duration(seconds: 2));

      // Gadgetbridge Protocol:
      // 1. Set Name (04)
      // 2. Set Time (01)
      // 3. User Profile (0A)
      // 4. Get Battery (03)
      // 5. Read Settings (16, 2C, 36, 21)

      debugPrint("Performing Startup Handshake (GB Mode)...");

      if (_writeChar != null) {
        // 1. Send Phone Name (0x04)
        await _writeChar!.write(PacketFactory.createSetPhoneNamePacket());
        addToProtocolLog("TX: 04 ... (Set Name)", isTx: true);
        await Future.delayed(const Duration(milliseconds: 200));

        // 2. Send Time (0x01)
        await _writeChar!.write(PacketFactory.createSetTimePacket());
        addToProtocolLog("TX: 01 ... (Set Time)", isTx: true);
        await Future.delayed(const Duration(milliseconds: 200));

        // 3. Send User Profile (0x0A) - Modern R02/R06 Standard
        await _writeChar!.write(PacketFactory.createUserProfilePacket());
        addToProtocolLog("TX: 0A ... (Set User Profile)", isTx: true);
        await Future.delayed(const Duration(milliseconds: 200));

        // 4. Request Battery (0x03)
        await _writeChar!.write(PacketFactory.getBatteryPacket());
        addToProtocolLog("TX: 03 (Get Battery)", isTx: true);
        await Future.delayed(const Duration(milliseconds: 100));

        // 5. Request Settings
        debugPrint("Reading Device Settings...");
        // HR Auto (16 01)
        await _writeChar!
            .write(PacketFactory.createPacket(command: 0x16, data: [0x01]));
        await Future.delayed(const Duration(milliseconds: 100));
        // SpO2 Auto (2C 01)
        await _writeChar!
            .write(PacketFactory.createPacket(command: 0x2C, data: [0x01]));
        await Future.delayed(const Duration(milliseconds: 100));
        // Stress Auto (36 01)
        await _writeChar!
            .write(PacketFactory.createPacket(command: 0x36, data: [0x01]));
        await Future.delayed(const Duration(milliseconds: 100));
        // Goals (21 01)
        await _writeChar!
            .write(PacketFactory.createPacket(command: 0x21, data: [0x01]));
        await Future.delayed(const Duration(milliseconds: 100));

        // Restore/Sync Persisted App Settings (SpO2, HRV, etc.)
        await syncSettingsToRing();

        // NO EXPLICIT BIND (0x48) - Gadgetbridge does not use it.
        // NO 0x39 05 - Gadgetbridge does not use it.
      }

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

  // Colmi V2 Service UUIDs (for Big Data / Real Time)
  static const String _serviceUuidV2 = "de5bf728-d711-4e47-af26-65e3012a5dc7";
  static const String _notifyCharUuidV2 =
      "de5bf729-d711-4e47-af26-65e3012a5dc7";

  Future<void> _discoverServices(BluetoothDevice device) async {
    List<BluetoothService> services = await device.discoverServices();

    // Find the Nordic UART service
    try {
      var service = services.firstWhere(
        (s) => s.uuid.toString().toUpperCase() == _serviceUuid,
      );
      for (var c in service.characteristics) {
        if (c.uuid.toString().toUpperCase() == _writeCharUuid) {
          _writeChar = c;
        }
        if (c.uuid.toString().toUpperCase() == _notifyCharUuid) {
          _notifyChar = c;
        }
      }
    } catch (e) {
      debugPrint("Nordic UART service not found: $e");
    }

    // Find V2 Service
    try {
      var serviceV2 = services.firstWhere(
        (s) => s.uuid.toString().toLowerCase() == _serviceUuidV2.toLowerCase(),
      );
      for (var c in serviceV2.characteristics) {
        if (c.uuid.toString().toLowerCase() ==
            _notifyCharUuidV2.toLowerCase()) {
          _notifyCharV2 = c;
          debugPrint("Found V2 Notify Characteristic!");
        }
      }
    } catch (e) {
      debugPrint("Colmi V2 Service not found (Device might be V1-only)");
    }

    // Fallback logic
    if (_writeChar == null) {
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

    // Subscribe V1
    if (_notifyChar != null) {
      try {
        await _notifySubscription?.cancel();
        _notifySubscription = null;
        await _notifyChar!.setNotifyValue(true);
        _notifySubscription = _notifyChar!.lastValueStream.listen(
          _onDataReceived,
        );
      } catch (e) {
        debugPrint("Error subscribing to V1 Notify: $e");
      }
    }

    // Subscribe V2
    if (_notifyCharV2 != null) {
      try {
        await _notifySubscriptionV2?.cancel();
        _notifySubscriptionV2 = null;
        await _notifyCharV2!.setNotifyValue(true);
        _notifySubscriptionV2 = _notifyCharV2!.lastValueStream.listen(
          _onDataReceived,
        );
        debugPrint("Subscribed to V2 Notify Stream");
      } catch (e) {
        debugPrint("Error subscribing to V2 Notify: $e");
      }
    }
  }

  bool _isMeasuringHeartRate = false;
  bool get isMeasuringHeartRate => _isMeasuringHeartRate;

  bool _isMeasuringSpo2 = false;
  bool get isMeasuringSpo2 => _isMeasuringSpo2;

  // Auto-Monitor State (Synced with Ring)
  bool _hrAutoEnabled = false;
  bool get hrAutoEnabled => _hrAutoEnabled;
  int _hrInterval = 5;
  int get hrInterval => _hrInterval;

  bool _spo2AutoEnabled = false;
  bool get spo2AutoEnabled => _spo2AutoEnabled;

  bool _stressAutoEnabled = false;
  bool get stressAutoEnabled => _stressAutoEnabled;

  bool _hrvAutoEnabled = false;
  bool get hrvAutoEnabled => _hrvAutoEnabled;

  bool _isMeasuringRawPPG = false;
  bool get isMeasuringRawPPG => _isMeasuringRawPPG;

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

  Future<void> _onDataReceived(List<int> data) async {
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

      // Auth Challenge / Proprietary Handshake (0x2F)
      if (cmd == 0x2F) {
        String msg = "RX Challenge: $hexData";
        debugPrint(msg);
        addToProtocolLog(msg);

        // Protocol Analysis: Gadgetbridge does NOT echo 0x2F. It just logs it.
        // Echoing might disrupt the sequence, so we ignore it now.
        // if (_writeChar != null) {
        //   debugPrint("Echoing Challenge (0x2F)...");
        //   _writeChar!.write(data);
        //   addToProtocolLog("TX Echo: $hexData", isTx: true);
        // }
        return;
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
        } else if (subType == 0x08) {
          // Stress Real-Time (69 08) - Corrected from SpO2
          if (data.length > dataOffset + 2) {
            int val = data[dataOffset + 2];
            if (val > 0) {
              _stress = val;
              notifyListeners();
              debugPrint("Stress (RT) Received: $val");

              // Auto-Reset Timer for Stress
              if (_isMeasuringStress) {
                _stressDataTimer?.cancel();
                _stressDataTimer = Timer(const Duration(seconds: 3), () {
                  if (_isMeasuringStress) {
                    debugPrint("Stress Silence Detected - Resetting State");
                    stopStressTest();
                  }
                });
              }
            }
          }
          _lastLog = "Stress (RT) RX: $hexData";
          // HRV Real-Time (69 0A)
          if (data.length > dataOffset + 2) {
            int val = data[dataOffset + 2];
            if (val > 0) {
              _hrv = val; // RAW HRV
              notifyListeners();
              debugPrint("HRV (RT) Received: $val");

              // Auto-Reset Timer (Like HR/SpO2)
              if (_isMeasuringHrv) {
                _hrvDataTimer?.cancel();
                _hrvDataTimer = Timer(const Duration(seconds: 3), () {
                  if (_isMeasuringHrv) {
                    debugPrint("HRV Silence Detected - Resetting State");
                    stopRealTimeHrv();
                  }
                });
              }
            }
          }
          _lastLog = "HRV (RT) RX: $hexData";
        }
        return;
      }

      // Notification / Data (0x73) - Moved below to unified block

      // HR History (0x15) - Added based on Gadgetbridge Logic
      if (cmd == 0x15) {
        if (data.length < 2) return;
        int packetNr = data[1];
        if (packetNr == 0xFF) {
          debugPrint("HR History Sync Complete/Empty");
          return;
        }

        // Gadgetbridge Logic for 0x15:
        // Packet 1 starts at index 6 (bytes 2-5 are timestamp)
        // Others start at index 2
        // Interval is 5 mins
        int startIndex = (packetNr == 1) ? 6 : 2;
        int minutesOffset = 0;
        if (packetNr > 1) {
          minutesOffset = 9 * 5; // Packet 1 has 9 values (indices 6..14)
          minutesOffset +=
              (packetNr - 2) * 13 * 5; // Others have 13 values (indices 2..14)
        }

        _log("HR History Packet $packetNr (StartIdx: $startIndex)");

        for (int i = startIndex; i < data.length - 1; i++) {
          int val = data[i];
          if (val > 0) {
            int minuteOfDay = minutesOffset + (i - startIndex) * 5;
            int h = minuteOfDay ~/ 60;
            int m = minuteOfDay % 60;
            _log("HR History: $h:$m = $val");

            // Add to History List for Graph
            // Note: This overrides simple list logic, might need deduplication
            _hrHistory.add(Point(minuteOfDay, val));
          }
        }
        // Notify UI to update graph
        notifyListeners();
        return;
      }

      // Activity Control ACK (0x77)
      if (cmd == 0x77) {
        debugPrint("Activity Control ACK (0x77): $hexData");
        /* 
            Response might be: 77 01 [Type] [Status?]
            Just logging strictly for now is enough.
         */
        return;
      }

      // Goals ACK (0x21)
      if (cmd == 0x21) {
        debugPrint("Goals Setting ACK (0x21)");
        return;
      }

      // HRV Auto Config ACK (0x38)
      if (cmd == 0x38) {
        debugPrint("HRV Auto Config ACK (0x38): $hexData");
        return;
      }

      // Stress Measurement (0x36) & History (0x37)
      if (cmd == 0x36 || cmd == 0x73 || cmd == PacketFactory.cmdSyncStress) {
        // If 0x36: Start/Stop ACKs
        // If 0x36: Start/Stop ACKs
        // If 0x36: Config Read Response OR Start/Stop ACKs
        if (cmd == 0x36) {
          if (data.length > 2 && data[1] == 0x01) {
            // Read Response: 36 01 [Enable]
            int enabledVal = data[2];
            debugPrint("RX Auto Stress Config: $enabledVal");
            _stressAutoEnabled = (enabledVal != 0);
            notifyListeners();
            return;
          }
          if (data.length > 1 && data[1] == 0x02) {
            debugPrint("Stress Op ACK (Start/Stop)");
            return;
          }
          debugPrint("Stress Unknown 0x36 Packet: $hexData");
          return;
        }

        // If 0x73: Real-time Data Packet
        // ... (Keep existing 0x73 logic) ...

        if (cmd == 0x73 && data.length > 2) {
          int val = data[1];
          // Handle specific notification subtypes
          String timestamp = DateTime.now().toIso8601String().substring(11, 19);

          if (val == 0x01) {
            String log =
                "[$timestamp] 🔔 RX Notify: New HR Data Available (0x73 01)";
            debugPrint(log);
            addToProtocolLog(log);
            debugPrint(
                "[$timestamp] 🔄 Triggering Auto-Sync for Heart Rate...");
            syncHeartRateHistory();
            return;
          }
          // SpO2 or Generic Data Notification (0x03 or 0x2C)
          // Note: User observed Green LED (HR) flashing before 0x73 2C arrived.
          // This implies 0x2C might be a "Measurement Cycle Complete" signal.
          // Safest strategy: Sync EVERYTHING when this arrives.
          if (val == 0x03 || val == 0x2C) {
            String log =
                "[$timestamp] 🔔 RX Notify: New Data Available (0x73 ${val.toRadixString(16).padLeft(2, '0')})";
            debugPrint(log);
            debugPrint(
                "[$timestamp] 🔄 Triggering AGGRESSIVE Auto-Sync (HR + SpO2 + Stress)...");
            addToProtocolLog(log);

            // 1. Sync HR (Green Light matches this)
            await syncHeartRateHistory();
            await Future.delayed(const Duration(milliseconds: 500));

            // 2. Sync SpO2 (Notification Code matches this)
            await syncSpo2History();
            await Future.delayed(const Duration(milliseconds: 500));

            // 3. Sync Stress (Just in case)
            await syncStressHistory();
            return;
          }

          if (val == 0x12) {
            // Steps (0x12) - Already handled or can be ignored here if handled above
            debugPrint("[$timestamp] 🔔 RX Notify: Steps (0x73 12)");
            // syncHistory(); // Handled by big sync?
            return;
          }

          if (val == 0x0C) {
            debugPrint("[$timestamp] 🔋 Battery Update");
            return;
          }

          // Legacy/Measurement Stress (if it comes as 0x73 with value)
          if (data.length > 4 && val == 0) val = data[4];
          if (val > 0) {
            _stress = val;
            notifyListeners();
            // ... existing stress logic ...
          }
        }

        // If 0x37: History Data
        if (cmd == PacketFactory.cmdSyncStress) {
          if (data.length < 2) return;
          int packetNr = data[1];
          if (packetNr == 0xFF) {
            debugPrint("Stress History Sync Complete/Empty");
            return;
          }

          // Gadgetbridge Logic:
          // Packet 0 is Header (Total Packets = data[2])
          if (packetNr == 0) {
            int totalPackets = data.length > 2 ? data[2] : 0;
            debugPrint("Stress History Header: Total Packets = $totalPackets");
            return;
          }

          // Packet 1 starts at index 3, others at index 2
          // Interval is 30 mins
          int startIndex = (packetNr == 1) ? 3 : 2;
          int minutesOffset = 0;
          if (packetNr > 1) {
            minutesOffset = 12 * 30; // Packet 1 has ~12 values?
            minutesOffset += (packetNr - 2) * 13 * 30; // Others ~13?
          }

          debugPrint("Stress History Packet $packetNr (StartIdx: $startIndex)");

          // We won't strictly parse history into a graph yet (no Store),
          // but we'll log the values to prove it works.
          for (int i = startIndex; i < data.length - 1; i++) {
            int val = data[i];
            if (val > 0) {
              int minuteOfDay = minutesOffset + (i - startIndex) * 30;
              int h = minuteOfDay ~/ 60;
              int m = minuteOfDay % 60;
              debugPrint("Stress History: $h:$m = $val");
              _stressHistory.add(Point(minuteOfDay, val));
            }
          }
          return;
        }
      }

      // Big Data Support (0xBC)
      if (cmd == 0xBC) {
        if (data.length > 2) {
          // Need at least subtype and length?
          // Based on diff:
          // CMD=0xBC
          // Subtype=data[1]
          // Length=data[2,3] (uint16)
          // Header is 6 bytes total? Diff says `value.length < packetLength + 6`

          int sub = data[1];
          if (sub == 0xEE) {
            debugPrint("Big Data (0xBC) Complete/Empty (0xEE)");
            return;
          }

          // We need to implement proper re-assembly if packets are split,
          // but for now let's assume small packets or handle single chunks.
          // GB does `bigDataPacket` concatenation.
          // Let's try to parse SpO2 (0x2A) assuming it fits or we just take what we have.

          if (sub == 0x2A) {
            // SpO2 History
            // Index 6 starts data?
            // GB: `int index = 6;`
            // `int spo2_days_ago = value[index];`
            int idx = 6;
            if (data.length > idx) {
              int daysAgo = data[idx];
              // If daysAgo is valid?
              // GB loop: `while (spo2_days_ago != 0 && index - 6 < length)`...
              // Note: `spo2_days_ago` seems to be acting as a terminator if 0? Or just value?
              // "spo2_days_ago = value[index]" then "syncingDay.add(DAY, 0 - daysAgo)".
              // Then "index++". "for (hour=0; hour<=23; hour++)".
              // "min = value[index++], max = value[index++]".
              // So header is 1 byte (daysAgo) followed by 48 bytes (24 * 2)?
              // Total 49 bytes?
              // Let's try to parse.

              DateTime syncingDay =
                  DateTime.now().subtract(Duration(days: daysAgo));
              // Reset to midnight? GB does: `set(MINUTE, 0), set(SECOND, 0)` and iterates hours.
              // So it creates timestamps for each hour?
              // Yes: "Received SpO2 data from {} days ago at {}:00"

              idx++;
              for (int hour = 0; hour < 24; hour++) {
                if (idx + 1 >= data.length) break;
                int minVal = data[idx++];
                int maxVal = data[idx++];
                if (minVal > 0 && maxVal > 0) {
                  int avg = (minVal + maxVal) ~/ 2;
                  DateTime entryTime = DateTime(syncingDay.year,
                      syncingDay.month, syncingDay.day, hour, 0);

                  // Add to history
                  bool isSameDay = entryTime.year == _selectedDate.year &&
                      entryTime.month == _selectedDate.month &&
                      entryTime.day == _selectedDate.day;

                  if (isSameDay) {
                    int minutesFromMidnight = hour * 60;
                    debugPrint(
                        "Adding SpO2 Point (BigData): $entryTime = $avg %");
                    _spo2History.add(Point(minutesFromMidnight, avg));
                  }
                }
              }
              notifyListeners();
            }
          } else if (sub == 0x27) {
            debugPrint("Sleep Data Packet (0xBC 27) - Ignored");
          } else {
            debugPrint(
                "Big Data (0xBC) Unknown Subtype: ${sub.toRadixString(16)}");
          }
        }
        return; // Handled
      }

      // SpO2 Auto Config ACK (0x2C)
      if (cmd == 0x2C) {
        if (data.length > 2 && data[1] == 0x01) {
          // Read Response: 2C 01 [Enable]
          int enabledVal = data[2];
          String rawHex =
              data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
          debugPrint("RX Auto SpO2 Config: $enabledVal (RAW: $rawHex)");
          _spo2AutoEnabled = (enabledVal != 0);
          notifyListeners();
        } else {
          debugPrint("SpO2 Auto Config ACK (0x2C)");
        }
        return;
      }

      // HRV Auto Config ACK (0x38)
      if (cmd == 0x38) {
        if (data.length > 2 && data[1] == 0x01) {
          // Read Response: 38 01 [Enable]
          int enabledVal = data[2];
          debugPrint("RX Auto HRV Config: $enabledVal");
          _hrvAutoEnabled = (enabledVal != 0);
          notifyListeners();
        } else {
          debugPrint("HRV Auto Config ACK (0x38): $hexData");
        }
        return;
      }

      // Stress Config Response (0x36) needs to be inside the 0x36 block or separate?
      // 0x36 is shared with Data.
      // Top of function handles 0x36. Let's check there.

      // SpO2 Log (0x16) or HR Auto Config (0x16)
      if (cmd == PacketFactory.cmdGetSpo2Log) {
        if (data.length < 2) return;
        int subType = data[dataOffset];

        // HR Auto Config ACK usually has subType 0x02 (Config)
        if (subType == 0x02) {
          debugPrint("HR Auto Config ACK (0x16 0x02)");
          return;
        }

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
          // Subtype 1: Could be SpO2 Log Timestamp OR HR Auto Config Read Response
          // Packet: 16 01 [B0] [B1] [B2] [B3] ...
          // HR Config: [Enable] [Interval] (and 00 padding)
          // SpO2 Log: [Time0] [Time1] [Time2] [Time3] (Epoch)

          bool isConfig = false;
          int t0 = data[dataOffset + 1];
          int t1 = data[dataOffset + 2];
          int t2 = data[dataOffset + 3];
          int t3 = data[dataOffset + 4];
          int potentialTimestamp = t0 | (t1 << 8) | (t2 << 16) | (t3 << 24);

          // Timestamp Check: If < 1,000,000,000 (Year 2001), it's likely Config
          if (potentialTimestamp < 1000000000) {
            isConfig = true;
          }

          if (isConfig) {
            int enabledVal = data[dataOffset + 1];
            int interval = data[dataOffset + 2];

            String rawHex =
                data.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
            debugPrint(
                "RX Auto HR Config: Enabled=$enabledVal, Interval=$interval (RAW: $rawHex)");
            // Polyfill: Update State
            _hrAutoEnabled = (enabledVal != 0);
            if (interval > 0) _hrInterval = interval;
            notifyListeners();
          } else {
            // Timestamp Packet for SpO2 Log
            _spo2LogBaseTime = potentialTimestamp;
            _spo2LogCount = 0;
            debugPrint("SpO2 Log TimeBlock: $_spo2LogBaseTime");

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
        return; // Handled 0x16
      }

      // Steps History (0x43)
      if (cmd == PacketFactory.cmdGetSteps) {
        if (data.length < 13)
          return; // 13 bytes min for 1 entry? Check lengths.
        int byte1 = data[dataOffset];
        if (byte1 == 0xF0) {
          debugPrint("Steps Log Start");
          _stepsHistory.clear();
        } else if (byte1 != 0xFF) {
          // Parse Explicit Date from packet (Bytes 1, 2, 3)
          // 43 [Year] [Month] [Day] [Quarter] [PacketIdx] [Total] [CalL] [CalH] [StepL] [StepH] [DistL] [DistH] ...
          // Offsets based on dataOffset (1):
          // [0] = 43 (Cmd) - handled outside or by offset
          // [dataOffset] = Year

          int y = int.tryParse(data[dataOffset].toRadixString(16)) ?? 0;
          int year = 2000 + y;
          int mVal = data[dataOffset + 1];
          int month = int.tryParse(mVal.toRadixString(16)) ?? 1;
          int dVal = data[dataOffset + 2];
          int day = int.tryParse(dVal.toRadixString(16)) ?? 1;
          int quarterIndex = data[dataOffset + 3];

          // Data starts at offset + 7?
          // dataOffset=1.
          // 1: Yr, 2: Mo, 3: Day, 4: Qtr, 5: Idx, 6: Total.
          // 7,8: Calories.
          // 9,10: Steps.
          // 11,12: Distance.

          if (data.length > dataOffset + 9) {
            int stepsIdx = dataOffset + 8; // Index 9
            int stepsVal = data[stepsIdx] | (data[stepsIdx + 1] << 8);

            if (stepsVal > 0) {
              DateTime entryDate = DateTime(year, month, day);
              int totalMinutes = quarterIndex * 15;
              DateTime finalTime =
                  entryDate.add(Duration(minutes: totalMinutes));

              bool isSameDay = finalTime.year == _selectedDate.year &&
                  finalTime.month == _selectedDate.month &&
                  finalTime.day == _selectedDate.day;

              if (isSameDay) {
                // Add point. x = quarterIndex (0-95)
                // Use existing point if present?
                _stepsHistory.removeWhere((p) => p.x == quarterIndex);
                _stepsHistory.add(Point(quarterIndex, stepsVal));
                _steps =
                    _stepsHistory.fold<int>(0, (sum, p) => sum + p.y.toInt());
              }
            }
          }
          notifyListeners();
        }
        return; // Handled 0x43
      }

      // Init Responses (0x01, 0x04, 0x0A)
      if (cmd == 0x01) {
        debugPrint("Time Set Response: ${data.sublist(1)}");
        return;
      }
      if (cmd == 0x04) {
        debugPrint("Phone Name Set Response: ${data.sublist(1)}");
        return;
      }
      if (cmd == 0x0A) {
        debugPrint("User Preferences Set Response: ${data.sublist(1)}");
        return;
      }

      // Battery Level (0x03)
      if (cmd == PacketFactory.cmdGetBattery) {
        int levelIndex = 1 + (dataOffset - 1);
        if (data.length > levelIndex) {
          _batteryLevel = data[levelIndex];
          notifyListeners();
        }
        return; // Handled 0x03 (Battery)
      }

      // Binding Response (0x48)
      if (cmd == PacketFactory.cmdBind) {
        debugPrint("Received Bind Response (0x48): $hexData");
        // Analyze if success (usually index 2 is 0x01)
        // Data: 48 00 01 C8 ...
        if (data.length > 2) {
          int status = data[2];
          if (status == 0x01) {
            debugPrint("Binding SUCCESS (0x01)");
          } else {
            debugPrint("Binding Status: $status");
          }
        }
        return;
      }

      // Config/Init Response (0x39)
      if (cmd == PacketFactory.cmdConfig) {
        debugPrint("Received Config Response (0x39): $hexData");
        return;
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

    // Trust the Timestamp!
    // But we still need to decide if we show it on the CURRENT graph (which is filtered by _selectedDate).
    // If we want to show everything, the UI needs to handle range.
    // For now, we still filter by _selectedDate to keep the graph clean,
    // BUT we trust 'dt' is correct and don't assume "Future" means "Yesterday".
    // If the ring sends a future timestamp, `_hrLogBaseTime` might be wrong or ring clock is wrong.
    // SyncTime should fix the ring clock.

    bool isSameDay = dt.year == _selectedDate.year &&
        dt.month == _selectedDate.month &&
        dt.day == _selectedDate.day;

    debugPrint(
        "[DEBUG] HR LOG CANDIDATE: $dt = $hrValue BPM (Selected: $_selectedDate)");

    if (isSameDay) {
      int minutesFromMidnight = dt.hour * 60 + dt.minute;
      debugPrint("Adding HR Point: $dt = $hrValue BPM");
      _hrHistory.add(Point(minutesFromMidnight, hrValue));
    } else {
      // Just log it, don't error
      debugPrint("[DEBUG] DROPPED HR Point (Diff Day): $dt vs $_selectedDate");
    }
  }

  void _addSpo2Point(int val) {
    // Determine timestamp
    // If _spo2LogBaseTime is set (0x16 protocol), use it.
    // If not, we might be calling this from 0xBC (Big Data).
    // Actually 0xBC handler should calculate DT and add manual point?
    // Let's keep this helper for 0x16 but clean it up.

    if (_spo2LogBaseTime == 0) return;
    int pointTimeSeconds =
        _spo2LogBaseTime + (_spo2LogCount * _spo2LogInterval * 60);
    DateTime dt = DateTime.fromMillisecondsSinceEpoch(pointTimeSeconds * 1000);

    bool isSameDay = dt.year == _selectedDate.year &&
        dt.month == _selectedDate.month &&
        dt.day == _selectedDate.day;

    debugPrint(
        "[DEBUG] SpO2 LOG CANDIDATE: $dt = $val % (Selected: $_selectedDate)");

    if (isSameDay) {
      int minutesFromMidnight = dt.hour * 60 + dt.minute;
      debugPrint("Adding SpO2 Point: $dt = $val %");
      _spo2History.add(Point(minutesFromMidnight, val));
    } else {
      debugPrint(
          "[DEBUG] DROPPED SpO2 Point (Diff Day): $dt vs $_selectedDate");
    }
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
      // 1. Stop Real-time Measurement (0x6A 0x01 0x00)
      // Do NOT send 0x16 0x02 0x00 (disableHeartRate) as it kills the Auto HR schedule!

      List<int> p2 = PacketFactory.stopHeartRate();
      final hex2 = p2.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      addToProtocolLog(hex2 + " (Stop Real-time HR)", isTx: true);
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

      // 2. Disable Periodic (Old Method) -- REMOVED
      // Sending 0x2C 0x02 0x00 disables Auto SpO2 background monitoring!
      // We rely on 0x6A 0x03 0x00 (RealTime Stop) above.

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

  Future<void> startRawPPG() async {
    if (_writeChar == null) return;
    try {
      _isMeasuringRawPPG = true;
      notifyListeners();

      List<int> packet = PacketFactory.startRawPPG();
      addToProtocolLog(
          "TX: " +
              packet.map((b) => b.toRadixString(16).padLeft(2, '0')).join(" ") +
              " (Start PPG)",
          isTx: true);
      await _writeChar!.write(packet);
    } catch (e) {
      debugPrint("Error starting PPG: $e");
      _isMeasuringRawPPG = false;
      notifyListeners();
    }
  }

  Future<void> stopRawPPG() async {
    _isMeasuringRawPPG = false;
    notifyListeners();
    if (_writeChar == null) return;
    try {
      List<int> packet = PacketFactory.stopRawPPG();
      addToProtocolLog(
          "TX: " +
              packet.map((b) => b.toRadixString(16).padLeft(2, '0')).join(" ") +
              " (Stop PPG)",
          isTx: true);
      await _writeChar!.write(packet);
    } catch (e) {
      debugPrint("Error stopping PPG: $e");
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
      String hex =
          packet.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
      addToProtocolLog("TX: $hex (Set Time)", isTx: true);
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
    _stressHistory.clear();
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

      // Explicitly chain other syncs to ensure they run even if one returns empty/early
      await Future.delayed(const Duration(seconds: 2));
      await syncHeartRateHistory();

      await Future.delayed(const Duration(seconds: 2));
      await syncSpo2History();

      await Future.delayed(const Duration(seconds: 2));
      await syncStressHistory();
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

  // Stress History as Points (Time, Value)
  final List<Point> _stressHistory = [];
  List<Point> get stressHistory => _stressHistory;

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

      // Use New Protocol (0xBC) matching Gadgetbridge (and Notification 0x2C)
      await Future.delayed(const Duration(milliseconds: 500));
      debugPrint("Requesting SpO2 History (New Protocol 0xBC)...");
      await _writeChar!.write(PacketFactory.getSpo2LogPacketNew());
    } catch (e) {
      debugPrint("Error syncing SpO2 history: $e");
    }
  }

  Future<void> syncStressHistory() async {
    if (_writeChar == null) return;
    try {
      debugPrint("Requesting Stress History (0x37)...");
      await _writeChar!.write(PacketFactory.getStressHistoryPacket());
    } catch (e) {
      debugPrint("Error syncing Stress History: $e");
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
      // Command 0x08 is Reboot/Power
      // 0x01 = Shutdown, 0x05 = Reboot (from Logs)
      await _writeChar!
          .write(PacketFactory.createPacket(command: 0x08, data: [0x05]));
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
    // REMOVED: await syncTime();
    // Sending SetTime (0x01) on every sync might reset the internal 5-minute timer on the ring,
    // preventing it from ever taking a measurement if the user syncs frequently.

    await getBatteryLevel();

    // Ensure settings are applied (in case they were lost or disabled)
    await syncSettingsToRing();
    await Future.delayed(const Duration(seconds: 1));

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
    _notifyCharV2 = null;
    _notifySubscription?.cancel();
    _notifySubscriptionV2?.cancel();
    _connectionStateSubscription?.cancel();
    _heartRate = 0;
    _batteryLevel = 0;
    _hrHistory.clear();
    _stressHistory.clear();
  }

  // --- Unified Monitoring & Feature Controls ---

  /// Heart Rate: Prefer Auto-Mode (0x16) for background monitoring.
  /// Set [minutes] to 0 to disable.
  Future<void> setHeartRateMonitoring(bool enabled) async {
    // For legacy compatibility, map true -> 5 mins, false -> 0.
    // If you want manual real-time, use startRealTimeHeartRate().
    await setAutoHrInterval(enabled ? 5 : 0);
  }

  /// SpO2: Uses periodic config 0x2C.
  Future<void> setSpo2Monitoring(bool enabled) async {
    await setAutoSpo2(enabled);
  }

  /// Stress: Uses periodic config 0x36.
  Future<void> setStressMonitoring(bool enabled) async {
    await setAutoStress(enabled);
  }

  /// Factory Reset (0xFF 66 66)
  /// WARNING: Clears all data.
  Future<void> factoryReset() async {
    if (_writeChar == null) return;
    debugPrint("Sending Factory Reset Command...");
    try {
      await _writeChar!
          .write(PacketFactory.createPacket(command: 0xFF, data: [0x66, 0x66]));
      debugPrint("Factory Reset Sent.");
    } catch (e) {
      debugPrint("Error Factory Reset: $e");
    }
  }

  /// Activity Tracking (0x77)
  /// Types: 0x04 (Walk), 0x07 (Run)
  /// Ops: 0x01 (Start), 0x02 (Pause), 0x03 (Resume), 0x04 (End)
  Future<void> setActivityState(int type, int op) async {
    if (_writeChar == null) return;
    try {
      // cmd was [0x77, op, type] -> command 0x77, data [op, type]
      String opName = ["", "Start", "Pause", "Resume", "End"][op];
      String typeName = (type == 0x04)
          ? "Walk"
          : (type == 0x07)
              ? "Run"
              : "Unknown($type)";

      addToProtocolLog(
          "TX: 77 ${op.toRadixString(16)} ${type.toRadixString(16)} ($opName $typeName)",
          isTx: true);
      await _writeChar!
          .write(PacketFactory.createPacket(command: 0x77, data: [op, type]));
    } catch (e) {
      debugPrint("Error setting activity state: $e");
    }
  }

  Future<void> startRealTimeHeartRate() async {
    if (_writeChar == null) return;
    // Manual Start: 69 01
    addToProtocolLog("TX: 69 01 (Start Manual HR)", isTx: true);
    await _writeChar!.write(PacketFactory.startHeartRate());
    _isMeasuringHeartRate = true;
    notifyListeners();
  }

  Future<void> stopRealTimeHeartRate() async {
    if (_writeChar == null) return;
    // Manual Stop: 6A 01
    addToProtocolLog("TX: 6A 01 (Stop Manual HR)", isTx: true);
    await _writeChar!.write(PacketFactory.stopHeartRate());
    _isMeasuringHeartRate = false;
    notifyListeners();
  }

  Future<void> startRealTimeSpo2() async {
    if (_writeChar == null) return;
    // Manual Start: 69 03 00 (08, 02 = Green/HR. Trying 03)
    addToProtocolLog("TX: 69 03 00 (Start Real-Time SpO2)", isTx: true);
    await _writeChar!
        .write(PacketFactory.createPacket(command: 0x69, data: [0x03, 0x00]));
    _isMeasuringSpo2 = true;
    notifyListeners();
  }

  Future<void> stopRealTimeSpo2() async {
    if (_writeChar == null) return;
    // Manual Stop: 6A 03 00
    addToProtocolLog("TX: 6A 03 00 (Stop Real-Time SpO2)", isTx: true);
    await _writeChar!
        .write(PacketFactory.createPacket(command: 0x6A, data: [0x03, 0x00]));
    _isMeasuringSpo2 = false;
    notifyListeners();
  }

  Future<void> startRealTimeHrv() async {
    if (_writeChar == null) return;
    // Manual Start: 69 0A 00
    addToProtocolLog("TX: 69 0A 00 (Start Real-Time HRV)", isTx: true);
    await _writeChar!
        .write(PacketFactory.createPacket(command: 0x69, data: [0x0A, 0x00]));
    _isMeasuringHrv = true;
    notifyListeners();
  }

  Future<void> stopRealTimeHrv() async {
    if (_writeChar == null) return;
    // Manual Stop: 6A 0A 00
    addToProtocolLog("TX: 6A 0A 00 (Stop Real-Time HRV)", isTx: true);
    await _writeChar!
        .write(PacketFactory.createPacket(command: 0x6A, data: [0x0A, 0x00]));
    _isMeasuringHrv = false;
    _hrvDataTimer?.cancel(); // Cancel timer
    notifyListeners();
  }

  // Stress (Real-Time Mode via 0x69 08)
  Future<void> startStressTest() async {
    if (_writeChar == null) return;
    // Real-Time Start Stress: 69 08 00
    addToProtocolLog("TX: 69 08 00 (Start Stress RT)", isTx: true);
    await _writeChar!
        .write(PacketFactory.createPacket(command: 0x69, data: [0x08, 0x00]));
    _isMeasuringStress = true;
    notifyListeners();
  }

  Future<void> stopStressTest() async {
    if (_writeChar == null) return;
    // Real-Time Stop Stress: 6A 08 00
    addToProtocolLog("TX: 6A 08 00 (Stop Stress RT)", isTx: true);
    await _writeChar!
        .write(PacketFactory.createPacket(command: 0x6A, data: [0x08, 0x00]));
    _isMeasuringStress = false;
    _stressDataTimer?.cancel(); // Cancel timer
    notifyListeners();
  }

  Future<void> startPairing() async {
    if (_writeChar == null) return;
    try {
      debugPrint("Starting Pairing Sequence (Gadgetbridge Logic)...");

      // 1. Set Phone Name (0x04 ...)
      debugPrint("Sending Set Phone Name (04 ...)...");
      await _writeChar!.write(PacketFactory.createSetPhoneNamePacket());
      await Future.delayed(const Duration(milliseconds: 200));

      // 2. Set Time (0x01 ...) - Validates connection & sets timestamp
      debugPrint("Sending Set Time (01 ...)...");
      await _writeChar!.write(PacketFactory.createSetTimePacket());
      await Future.delayed(const Duration(milliseconds: 200));

      // 3. Set User Preferences (0x0A ...) - Replaces old 0x39 config
      debugPrint("Sending User Preferences (0A ...)...");
      await _writeChar!.write(PacketFactory.createUserProfilePacket());
      await Future.delayed(const Duration(milliseconds: 200));

      // 4. Request Battery (0x03) - confirm communication
      debugPrint("Requesting Battery Info (03)...");
      await _writeChar!.write(PacketFactory.getBatteryPacket());
      await Future.delayed(const Duration(milliseconds: 200));

      // 5. Trigger Android Bonding (System Dialog)
      // Gadgetbridge relies on passive bonding or earlier triggers, but we'll be explicit.
      debugPrint("Requesting Android System Bond...");
      try {
        await _connectedDevice?.createBond();
      } catch (e) {
        debugPrint("Bonding request skipped/failed: $e");
      }

      // 6. Optional: Check Bind Status (0x48 00) for debugging
      // Even if Gadgetbridge doesn't use it, it helps us know if the ring thinks it's bound.
      await Future.delayed(const Duration(seconds: 2));
      debugPrint("Checking Bind Status (48 00)...");
      await _writeChar!.write(PacketFactory.createBindRequest());

      debugPrint("Pairing Sequence Complete.");
    } catch (e) {
      debugPrint("Error pairing: $e");
    }
  }

  Future<void> unpairRing() async {
    if (_connectedDevice == null) return;
    try {
      debugPrint("Attempting to remove bond (Unpair)...");
      await _connectedDevice!.removeBond();
      debugPrint("Bond removed by System.");
    } catch (e) {
      debugPrint("Error removing bond: $e");
    }
  }

  // --- Automatic Monitoring Actions ---

  Future<void> setAutoHrInterval(int minutes) async {
    // Optimistic Update
    _hrAutoEnabled = (minutes > 0);
    if (minutes > 0) _hrInterval = minutes;
    notifyListeners();

    if (_writeChar == null) return;

    // Use PacketFactory to create the proper 16-byte valid packet
    // CMD: 0x16, Sub: 0x02, Enabled: 0x01/0x00, Interval
    Uint8List packet =
        PacketFactory.enableHeartRate(interval: minutes > 0 ? minutes : 5);

    // Note: If minutes == 0, we might want to disable it.
    // PacketFactory.enableHeartRate currently assumes Enabled=0x01.
    // Let's modify PacketFactory if needed, but for now assuming we only call this with > 0 for enable.
    // To disable, minutes=0. PacketFactory sends enabled=0x01 always in current implementation??
    // Let's check PacketFactory implementation again.
    // It takes `interval` but sends `0x02, 0x01, interval`. Always Enabled=1.
    // We should fix PacketFactory or build manually with CHECKSUM here.
    // Let's build manually using PacketFactory.createPacket for flexibility.

    int enabledVal = minutes > 0 ? 0x01 : 0x00;
    int intervalVal = minutes > 0 ? minutes : 0;

    packet = PacketFactory.createPacket(
        command: 0x16, data: [0x02, enabledVal, intervalVal]);

    // Save to Prefs
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('hrInterval', minutes);

    final hex =
        packet.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    // Log as TX
    addToProtocolLog(hex + " (Set Auto HR: $minutes min)", isTx: true);

    try {
      await _writeChar!.write(packet);
      debugPrint("Sent Auto HR Config: $minutes min");
    } catch (e) {
      debugPrint("Error setting Auto HR: $e");
    }
  }

  Future<void> setAutoSpo2(bool enabled) async {
    // Optimistic Update
    _spo2AutoEnabled = enabled;
    notifyListeners();

    if (_writeChar == null) return;
    int val = enabled ? 0x01 : 0x00;
    // CMD: 0x2C
    Uint8List packet =
        PacketFactory.createPacket(command: 0x2C, data: [0x02, val]);

    final hex =
        packet.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    addToProtocolLog(hex + " (Set Auto SpO2: $enabled)", isTx: true);

    try {
      await _writeChar!.write(packet);
      debugPrint("Sent Auto SpO2 Config: $enabled");
      // Save to Prefs
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('spo2Enabled', enabled);
    } catch (e) {
      debugPrint("Error setting Auto SpO2: $e");
    }
  }

  Future<void> setAutoStress(bool enabled) async {
    // Optimistic Update
    _stressAutoEnabled = enabled;
    notifyListeners();

    if (_writeChar == null) return;
    int val = enabled ? 0x01 : 0x00;
    // CMD: 0x36
    Uint8List packet =
        PacketFactory.createPacket(command: 0x36, data: [0x02, val]);

    final hex =
        packet.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    addToProtocolLog(hex + " (Set Auto Stress: $enabled)", isTx: true);

    try {
      await _writeChar!.write(packet);
      debugPrint("Sent Auto Stress Config: $enabled");
      // Save to Prefs
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('stressEnabled', enabled);
    } catch (e) {
      debugPrint("Error setting Auto Stress: $e");
    }
  }

  Future<void> readAutoSettings() async {
    if (_writeChar == null) return;
    _log("Reading Auto Settings...");
    // 16 01: Read HR
    _log("Requesting Auto HR Settings...");
    await _writeChar!.write([0x16, 0x01]);
    await Future.delayed(const Duration(milliseconds: 300));
    // 2C 01: Read SpO2
    _log("Requesting Auto SpO2 Settings...");
    await _writeChar!.write([0x2C, 0x01]);
    await Future.delayed(const Duration(milliseconds: 300));
    // 36 01: Read Stress
    _log("Requesting Auto Stress Settings...");
    await _writeChar!.write([0x36, 0x01]);
    await Future.delayed(const Duration(milliseconds: 300));
    // 38 01: Read HRV
    _log("Requesting Auto HRV Settings...");
    await _writeChar!.write([0x38, 0x01]);
  }

  Future<void> setAutoHrv(bool enabled) async {
    // Optimistic Update
    _hrvAutoEnabled = enabled;
    notifyListeners();

    if (_writeChar == null) return;
    int val = enabled ? 0x01 : 0x00;
    // CMD: 0x38
    Uint8List packet =
        PacketFactory.createPacket(command: 0x38, data: [0x02, val]);

    final hex =
        packet.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    addToProtocolLog(hex + " (Set Auto HRV: $enabled)", isTx: true);

    try {
      await _writeChar!.write(packet);
      debugPrint("Sent Auto HRV Config: $enabled");
      // Save to Prefs
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('hrvEnabled', enabled);
    } catch (e) {
      debugPrint("Error setting Auto HRV: $e");
    }
  }

  /// Restores settings from SharedPreferences and applies them to the ring.
  Future<void> syncSettingsToRing() async {
    _log("🔄 Syncing Settings from App to Ring...");
    final prefs = await SharedPreferences.getInstance();

    // 1. HR
    int? hrInterval = prefs.getInt('hrInterval');
    if (hrInterval != null) {
      _log("Restoring HR Interval: $hrInterval mins");
      await setAutoHrInterval(hrInterval);
      await Future.delayed(const Duration(milliseconds: 300));
    }

    // 2. SpO2
    bool? spo2Obj = prefs.getBool('spo2Enabled');
    if (spo2Obj != null) {
      _log("Restoring SpO2: $spo2Obj");
      await setAutoSpo2(spo2Obj);
      await Future.delayed(const Duration(milliseconds: 300));
    }

    // 3. Stress
    bool? stressObj = prefs.getBool('stressEnabled');
    if (stressObj != null) {
      _log("Restoring Stress: $stressObj");
      await setAutoStress(stressObj);
      await Future.delayed(const Duration(milliseconds: 300));
    }

    // 4. HRV
    bool? hrvObj = prefs.getBool('hrvEnabled');
    if (hrvObj != null) {
      _log("Restoring HRV: $hrvObj");
      await setAutoHrv(hrvObj);
      await Future.delayed(const Duration(milliseconds: 300));
    }
    _log("✅ Settings Sync Complete");
  }
} // End Class BleService
