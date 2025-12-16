import 'dart:async';
import 'dart:io';
import 'dart:math'; // For Point

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'packet_factory.dart';
import 'ble_constants.dart';
import 'ble_data_processor.dart';
import '../features/model/sleep_data.dart';

import 'package:flutter/widgets.dart'; // For WidgetsBindingObserver

class BleService extends ChangeNotifier
    with WidgetsBindingObserver
    implements BleDataCallbacks {
  static final BleService _instance = BleService._internal();
  factory BleService() => _instance;
  BleService._internal() {
    _processor = BleDataProcessor(this);
    // Observe App Lifecycle
    WidgetsBinding.instance.addObserver(this);
  }

  late final BleDataProcessor _processor;

  // Timers
  Timer? _hrTimer;
  Timer? _hrDataTimer;
  Timer? _spo2Timer;
  Timer? _spo2DataTimer;
  Timer? _stressTimer;
  Timer? _stressDataTimer;

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
  DateTime? _lastHrTime;
  int get heartRate => _heartRate;
  String get heartRateTime => _formatTime(_lastHrTime);

  int _spo2 = 0;
  DateTime? _lastSpo2Time;
  int get spo2 => _spo2;
  String get spo2Time => _formatTime(_lastSpo2Time);

  // History Data (Session only for HRV)
  final List<Point> _hrHistory = [];
  final List<Point> _spo2History = [];
  final List<Point> _stressHistory = [];
  final List<Point> _hrvHistory = []; // Session-based history
  final List<Point> _stepsHistory = [];
  final List<SleepData> _sleepHistory = [];

  List<Point> get hrHistory => List.unmodifiable(_hrHistory);
  List<Point> get spo2History => List.unmodifiable(_spo2History);
  List<Point> get stressHistory => List.unmodifiable(_stressHistory);
  List<Point> get hrvHistory => List.unmodifiable(_hrvHistory);
  List<Point> get stepsHistory => List.unmodifiable(_stepsHistory);
  List<SleepData> get sleepHistory => List.unmodifiable(_sleepHistory);

  DateTime _selectedDate = DateTime.now();
  DateTime get selectedDate => _selectedDate;

  void setSelectedDate(DateTime date) {
    _selectedDate = date;
    notifyListeners();
    // Trigger data reload for that date?
    // For now, we only have today's session or synced data.
    // If we had a database, we would query it here.
  }

  int _stress = 0;
  DateTime? _lastStressTime;
  int get stress => _stress;
  String get stressTime => _formatTime(_lastStressTime);

  int _hrv = 0; // New HRV Metric
  DateTime? _lastHrvTime;
  int get hrv => _hrv;
  String get hrvTime => _formatTime(_lastHrvTime);

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
  DateTime? _lastStepsTime;
  int get steps => _steps;
  String get stepsTime => _formatTime(_lastStepsTime, isDaily: true);

  // --- Smart Sync State ---
  DateTime? _lastSyncTime;
  Timer? _periodicSyncTimer;
  final Duration _syncInterval = const Duration(minutes: 60);
  final Duration _minSyncDelay = const Duration(minutes: 15);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _periodicSyncTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint("App Resumed - Checking Smart Sync...");
      triggerSmartSync();
    }
  }

  /// Triggers a sync if conditions are met (Interval elapsed or manual override)
  /// [force] : By-pass throttle logic (e.g. Pull-to-Refresh)
  Future<void> triggerSmartSync({bool force = false}) async {
    if (!isConnected) {
      debugPrint("Smart Sync Ignored: Disconnected");
      return;
    }

    final now = DateTime.now();
    if (!force && _lastSyncTime != null) {
      final elapsed = now.difference(_lastSyncTime!);
      if (elapsed < _minSyncDelay) {
        debugPrint(
            "Smart Sync Throttled: Last sync was ${elapsed.inMinutes} mins ago (Min: ${_minSyncDelay.inMinutes})");
        return;
      }
    }

    debugPrint("Triggering Smart Sync...");
    await startFullSyncSequence();
    _lastSyncTime = DateTime.now();
  }

  void _startPeriodicSyncTimer() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = Timer.periodic(_syncInterval, (timer) {
      debugPrint("Periodic Sync Triggered");
      triggerSmartSync();
    });
  }

  void _stopPeriodicSyncTimer() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = null;
  }

  String _formatTime(DateTime? dt, {bool isDaily = false}) {
    if (dt == null) return "No Data";
    if (isDaily) return "Today"; // Steps are usually cumulative for the day
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
    } else {
      return "${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
    }
  }

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
          return BleConstants.targetDeviceNames
              .any((target) => name.contains(target));
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

      // Start Smart Sync
      _startPeriodicSyncTimer();
      triggerSmartSync();
    } catch (e) {
      _status = "Connection Failed: $e";
      _cleanup();
      notifyListeners();
    }
  }

  Future<void> _discoverServices(BluetoothDevice device) async {
    List<BluetoothService> services = await device.discoverServices();

    // Find the Nordic UART service
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

    // Find V2 Service
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

  // Track if we received ANY SpO2 data during a 0xBC sync

  // Sensor Streams
  final StreamController<List<int>> _accelStreamController =
      StreamController<List<int>>.broadcast();
  Stream<List<int>> get accelStream => _accelStreamController.stream;

  final StreamController<List<int>> _ppgStreamController =
      StreamController<List<int>>.broadcast();
  Stream<List<int>> get ppgStream => _ppgStreamController.stream;

  Future<void> _onDataReceived(List<int> data) async {
    await _processor.processData(data);
  }

  // --- BleDataCallbacks Implementation ---

  @override
  void onProtocolLog(String message) {
    addToProtocolLog(message);
  }

  @override
  void onRawLog(String message) {
    debugPrint(message); // Enable console log for debugging
    _lastLog = message;
    // notifyListeners(); // Optional?
  }

  @override
  void onHeartRate(int bpm) {
    if (bpm > 0) {
      _heartRate = bpm;
      _lastHrTime = DateTime.now();
      notifyListeners();

      if (_isMeasuringHeartRate) {
        debugPrint("HR Received ($bpm) - Resetting Silence Timer");
        _hrDataTimer?.cancel();
        _hrDataTimer = Timer(const Duration(seconds: 3), () {
          if (_isMeasuringHeartRate) {
            debugPrint("HR Silence Detected - Resetting State");
            stopHeartRate();
          }
        });
      }
    }
  }

  @override
  void onSpo2(int percent) {
    if (percent > 0) {
      _spo2 = percent;
      _lastSpo2Time = DateTime.now();
      _lastLog = "SpO2 Success: $percent";
      // Auto-stop logic from old code
      if (_isMeasuringSpo2) {
        stopSpo2();
      }

      // Live "Polyfill" to Graph
      final now = DateTime.now();
      int minutes = now.hour * 60 + now.minute;
      // Filter?
      // Only if selected date is today
      bool isToday = _selectedDate.year == now.year &&
          _selectedDate.month == now.month &&
          _selectedDate.day == now.day;

      if (isToday) {
        _spo2History.removeWhere((p) => p.x == minutes);
        _spo2History.add(Point(minutes, percent));
        _spo2History.sort((a, b) => a.x.compareTo(b.x));
      }
      notifyListeners();
    }
  }

  @override
  void onStress(int level) {
    if (level > 0) {
      _stress = level;
      _lastStressTime = DateTime.now();
      notifyListeners();

      if (_isMeasuringStress) {
        _stressDataTimer?.cancel();
        _stressDataTimer = Timer(const Duration(seconds: 3), () {
          if (_isMeasuringStress) {
            stopStressTest();
          }
        });
      }
    }
  }

  @override
  void onHrv(int val) {
    if (val > 0) {
      _hrv = val;
      _lastHrvTime = DateTime.now();

      // Live Polyfill for History Graph
      final now = DateTime.now();
      bool isToday = _selectedDate.year == now.year &&
          _selectedDate.month == now.month &&
          _selectedDate.day == now.day;

      if (isToday) {
        int minutes = now.hour * 60 + now.minute;
        _hrvHistory.removeWhere((p) => p.x == minutes);
        _hrvHistory.add(Point(minutes, val));
        _hrvHistory.sort((a, b) => a.x.compareTo(b.x));
      }
      notifyListeners();

      if (_isMeasuringHrv) {
        _hrvDataTimer?.cancel();
        _hrvDataTimer = Timer(const Duration(seconds: 3), () {
          if (_isMeasuringHrv) stopRealTimeHrv();
        });
      }
    }
  }

  @override
  void onBattery(int level) {
    _batteryLevel = level;
    notifyListeners();
  }

  @override
  void onHeartRateHistoryPoint(DateTime timestamp, int bpm) {
    // Logic for Dashboard: Use LATEST value
    if (bpm > 0) {
      if (_lastHrTime == null || timestamp.isAfter(_lastHrTime!)) {
        _heartRate = bpm;
        _lastHrTime = timestamp;
      }
    }

    bool isSameDay = timestamp.year == _selectedDate.year &&
        timestamp.month == _selectedDate.month &&
        timestamp.day == _selectedDate.day;

    if (isSameDay) {
      int minutes = timestamp.hour * 60 + timestamp.minute;
      _hrHistory.add(Point(minutes, bpm));
      // Notify? Maybe batch notify?
      // Since this is called in tight loop, maybe we should suppress notify?
      // But _onDataReceived is async but loop in processor.
      // We'll notify at end of batch?
      // Existing code notified per packet.
      // We can rely on 'notifyListeners' at end of 'syncHeartRateHistory'??
      // No, data comes in chunks.
      // Let's notify listeners here? It might be spammy.
      // Ideally processor emits "Batch Complete".
      // But for now, we leave it or notify periodically?
      // Original code notified per PACKET (which had multiple points).
      // Here we notify per POINT.
      // Optimization: Notify outside?
      // Let's just notify. Flutter batch updates often handle it.
      // Or we can rely on UI refresh timer if we had one.
      notifyListeners();
    }
  }

  @override
  void onSpo2HistoryPoint(DateTime timestamp, int percent) {
    // Logic for Dashboard: Use LATEST value
    if (percent > 0) {
      if (_lastSpo2Time == null || timestamp.isAfter(_lastSpo2Time!)) {
        _spo2 = percent;
        _lastSpo2Time = timestamp;
      }
    }

    bool isSameDay = timestamp.year == _selectedDate.year &&
        timestamp.month == _selectedDate.month &&
        timestamp.day == _selectedDate.day;

    if (isSameDay) {
      int minutes = timestamp.hour * 60 + timestamp.minute;
      _spo2History.removeWhere((p) => p.x == minutes); // Dedupe
      _spo2History.add(Point(minutes, percent));
      notifyListeners();
    }
  }

  @override
  void onStressHistoryPoint(DateTime timestamp, int level) {
    // Logic for Dashboard: Use LATEST value
    if (level > 0) {
      if (_lastStressTime == null || timestamp.isAfter(_lastStressTime!)) {
        _stress = level;
        _lastStressTime = timestamp;
      }
    }

    // Stress history didn't have timestamp in packet, implementing " Today" logic in Processor.
    // But here we check if selected date matches?
    // For now, just add it.
    int minutes = timestamp.hour * 60 + timestamp.minute;
    _stressHistory.add(Point(minutes, level));
    notifyListeners();
  }

  @override
  void onStepsHistoryPoint(DateTime timestamp, int steps, int quarterIndex) {
    // Steps are cumulative daily.
    // _steps logic below handles total daily logic.
    // But onStepsHistoryPoint is for graphs.

    bool isSameDay = timestamp.year == _selectedDate.year &&
        timestamp.month == _selectedDate.month &&
        timestamp.day == _selectedDate.day;

    if (isSameDay) {
      _stepsHistory.removeWhere((p) => p.x == quarterIndex);
      _stepsHistory.add(Point(quarterIndex, steps));

      // Calculate total steps
      _steps = _stepsHistory.fold<int>(0, (sum, p) => sum + p.y.toInt());
      _lastStepsTime = DateTime.now(); // Updated today
      notifyListeners();
    }
  }

  @override
  void onSleepHistoryPoint(DateTime timestamp, int stage,
      {int durationMinutes = 0}) {
    bool isSameDay = timestamp.year == _selectedDate.year &&
        timestamp.month == _selectedDate.month &&
        timestamp.day == _selectedDate.day;

    // TODO: Handle multi-day spanning if needed. For now, filter by selected date view.
    // Or just store everything and filter in UI?
    // Storing everything is safer.

    // Remove existing for same time (dedupe)
    _sleepHistory.removeWhere((s) => s.timestamp == timestamp);
    _sleepHistory.add(SleepData(
        timestamp: timestamp, stage: stage, durationMinutes: durationMinutes));
    _sleepHistory.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    notifyListeners();
  }

  @override
  void onRawAccel(List<int> data) {
    _accelStreamController.add(data);
  }

  @override
  void onRawPPG(List<int> data) {
    _ppgStreamController.add(data);
  }

  @override
  void onHrvHistoryPoint(DateTime timestamp, int val) {
    // Check if duplicate?
    bool exists = _hrvHistory.any((p) {
      // Simple check: Same time?
      // Note: Graph uses minute-of-day (0-1440) for X.
      int minutes = timestamp.hour * 60 + timestamp.minute;
      return p.x == minutes && p.y == val;
    });

    if (!exists) {
      int minutes = timestamp.hour * 60 + timestamp.minute;
      _hrvHistory.add(Point(minutes, val));
      _hrvHistory.sort((a, b) => a.x.compareTo(b.x));
      notifyListeners();
    }
  }

  @override
  void onAutoConfigRead(String type, bool enabled) {
    if (type == "HR") {
      _hrAutoEnabled = enabled;
    } else if (type == "SpO2") {
      _spo2AutoEnabled = enabled;
    } else if (type == "Stress") {
      _stressAutoEnabled = enabled;
    } else if (type == "HRV") {
      _hrvAutoEnabled = enabled;
    }
    notifyListeners();
  }

  @override
  void onNotification(int type) {
    debugPrint("Notification Type: ${type.toRadixString(16)}");
    if (type == 0x01) {
      debugPrint("Auto Sync Trigger: HR");
      syncHeartRateHistory();
    } else if (type == 0x03 || type == 0x2C) {
      debugPrint("Auto Sync Trigger: All (SpO2/Data)");
      // Chain syncs
      Future.delayed(Duration.zero, () async {
        await syncHeartRateHistory();
        await Future.delayed(const Duration(milliseconds: 500));
        await syncSpo2History();
        await Future.delayed(const Duration(milliseconds: 500));
        await syncStressHistory();
        await Future.delayed(const Duration(milliseconds: 500));
        await syncSleepHistory();
      });
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

  Future<void> startFullSyncSequence() async {
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
      // Allow extra time for potential 0xBC -> 0x16 fallback
      await Future.delayed(const Duration(seconds: 4));

      await syncStressHistory();
      await Future.delayed(const Duration(seconds: 2));

      await syncHrvHistory();

      _lastLog = "Full Sync Completed";

      // NOTE: HRV History is not yet supported by protocol

      _lastLog = "Full Sync Completed";
      notifyListeners();
    } catch (e) {
      debugPrint("Error syncing history: $e");
    }
  }

  int _batteryLevel = 0;
  int get batteryLevel => _batteryLevel;

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
      debugPrint("Syncing SpO2 History (Key 0x01)...");
      // Single Request (Proven working in logs to trigger response)
      await _writeChar!.write(PacketFactory.getSpo2LogPacketNew());
    } catch (e) {
      debugPrint("Error syncing SpO2 history: $e");
    }
  }

  Future<void> syncStressHistory() async {
    if (_writeChar == null) return;
    try {
      debugPrint("Requesting Stress History (0x37)...");
      await _writeChar!
          .write(PacketFactory.getStressHistoryPacket(packetIndex: 0));
    } catch (e) {
      debugPrint("Error syncing Stress history: $e");
    }
  }

  Future<void> syncHrvHistory() async {
    if (_writeChar == null) return;
    try {
      debugPrint("Requesting HRV History (0x39 Experimental)...");
      await _writeChar!.write(PacketFactory.getHrvLogPacket(packetIndex: 0));
    } catch (e) {
      debugPrint("Error syncing HRV history: $e");
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
    // Manual trigger overrides throttle
    await triggerSmartSync(force: true);
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
    _stopPeriodicSyncTimer();
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
    addToProtocolLog("$hex (Set Auto HR: $minutes min)", isTx: true);

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

      // Force read back to verify
      await Future.delayed(const Duration(milliseconds: 200));
      debugPrint("Verifying SpO2 Config...");
      await _writeChar!.write([0x2C, 0x01]);

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

  /// Syncs the current phone time to the ring.
  Future<void> normalizeTime() async {
    if (_writeChar == null) return;
    try {
      debugPrint("Sending Time Sync (0x01)...");
      await _writeChar!.write(PacketFactory.createSetTimePacket());
    } catch (e) {
      debugPrint("Error syncing time: $e");
    }
  }

  /// Restores settings from SharedPreferences and applies them to the ring.
  Future<void> syncSettingsToRing() async {
    _log("🔄 Syncing Settings from App to Ring...");
    // 0. Sync Time (Redundant/Safety)
    await normalizeTime();
    await Future.delayed(const Duration(milliseconds: 200));

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

  Future<void> syncSleepHistory() async {
    if (_writeChar == null) return;
    _sleepHistory.clear();
    notifyListeners();
    addToProtocolLog("TX: 7A (Sync Sleep History)", isTx: true);
    // Request Index 01 (based on log observation 0x7A 01)
    await _writeChar!.write(PacketFactory.getSleepLogPacket(packetIndex: 0x01));
  }
} // End Class BleService
