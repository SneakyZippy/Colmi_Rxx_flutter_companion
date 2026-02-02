import 'dart:async';
import 'dart:io';
import 'dart:math'; // For Point

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart'; // For BluetoothDevice types
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'packet_factory.dart';
import 'ble_constants.dart';
import 'ble_data_processor.dart';
import 'package:flutter_application_1/models/sleep_data.dart';
// New Components
import 'ble_logger.dart';
import 'ble_scanner.dart';
import 'ble_sensor_controller.dart';
import 'package:flutter_application_1/services/api/api_service.dart';

import 'package:flutter/widgets.dart'; // For WidgetsBindingObserver

class BleService extends ChangeNotifier
    with WidgetsBindingObserver
    implements BleDataCallbacks {
  static final BleService _instance = BleService._internal();
  factory BleService() => _instance;

  BleService._internal() {
    _logger = BleLogger();
    _scanner = BleScanner();
    // Initialize SensorController (sendCommand will be set on connect)
    _sensorController = BleSensorController(logger: _logger);
    _processor = BleDataProcessor(this);

    // Proxy Listeners
    _scanner.addListener(notifyListeners);
    _logger.addListener(notifyListeners);
    _sensorController.addListener(notifyListeners);

    WidgetsBinding.instance.addObserver(this);
  }

  late final BleDataProcessor _processor;
  late final BleLogger _logger;
  late final BleScanner _scanner;
  late final BleSensorController _sensorController;
  final ApiService _apiService = ApiService();
  ApiService get apiService => _apiService;

  // --- Exposed Sub-Components (Facade) ---
  // Logger
  List<String> get protocolLog => _logger.protocolLog;
  String get lastLog => _logger.lastLog;
  void addToProtocolLog(String message, {bool isTx = false}) =>
      _logger.addToProtocolLog(message, isTx: isTx);
  void _log(String message) => _logger.log(message);

  // Scanner
  bool get isScanning => _scanner.isScanning;
  List<ScanResult> get scanResults => _scanner.scanResults;
  List<BluetoothDevice> get bondedDevices => _scanner.bondedDevices;
  Future<void> startScan() => _scanner.startScan();
  Future<void> stopScan() => _scanner.stopScan();
  Future<void> loadBondedDevices() => _scanner.loadBondedDevices();

  // Sensor Controller Status
  bool get isMeasuringHeartRate => _sensorController.isMeasuringHeartRate;
  bool get isMeasuringSpo2 => _sensorController.isMeasuringSpo2;
  bool get isMeasuringStress => _sensorController.isMeasuringStress;
  bool get isMeasuringHrv => _sensorController.isMeasuringHrv;
  bool get isMeasuringRawPPG => _sensorController.isMeasuringRawPPG;

  // --- Connection State ---
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _writeChar;
  BluetoothCharacteristic? _writeCharV2;
  BluetoothCharacteristic? _notifyChar;
  BluetoothCharacteristic? _notifyCharV2;

  StreamSubscription<List<int>>? _notifySubscription;
  StreamSubscription<List<int>>? _notifySubscriptionV2;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;

  String _status = "Disconnected";
  String get status => _status;

  bool get isConnected => _connectedDevice != null && _writeChar != null;
  String? get currentDeviceId => _connectedDevice?.remoteId.toString();

  // --- Measurement Data State (Kept in Service for UI) ---
  int _batteryLevel = 0;
  int get batteryLevel => _batteryLevel;

  int _heartRate = 0;
  DateTime? _lastHrTime;
  int get heartRate => _heartRate;
  String get heartRateTime => _formatTime(_lastHrTime);

  int _spo2 = 0;
  DateTime? _lastSpo2Time;
  int get spo2 => _spo2;
  String get spo2Time => _formatTime(_lastSpo2Time);

  int _stress = 0;
  DateTime? _lastStressTime;
  int get stress => _stress;
  String get stressTime => _formatTime(_lastStressTime);

  int _hrv = 0;
  DateTime? _lastHrvTime;
  int get hrv => _hrv;
  String get hrvTime => _formatTime(_lastHrvTime);

  int _steps = 0;
  DateTime? _lastStepsTime;
  int get steps => _steps;
  String get stepsTime => _formatTime(_lastStepsTime, isDaily: true);

  // History Data
  final List<Point> _hrHistory = [];
  final List<Point> _spo2History = [];
  final List<Point> _stressHistory = [];
  final List<Point> _hrvHistory = [];
  final List<Point> _stepsHistory = [];
  final List<SleepData> _sleepHistory = [];

  List<Point> get hrHistory => List.unmodifiable(_hrHistory);
  List<Point> get spo2History => List.unmodifiable(_spo2History);
  List<Point> get stressHistory => List.unmodifiable(_stressHistory);
  List<Point> get hrvHistory => List.unmodifiable(_hrvHistory);
  List<Point> get stepsHistory => List.unmodifiable(_stepsHistory);
  List<SleepData> get sleepHistory => List.unmodifiable(_sleepHistory);

  // Computed Sleep Data
  int get totalSleepMinutes => _sleepHistory.fold(0, (sum, item) {
        // Exclude 'Awake' (Stage 5) from total sleep time?
        // Usually Total Sleep = Light + Deep. Awake is excluded.
        // Stage 5 = Awake.
        return (item.stage != 5) ? sum + item.durationMinutes : sum;
      });

  String get totalSleepTimeFormatted {
    if (totalSleepMinutes == 0) return "0h 0m";
    int hours = totalSleepMinutes ~/ 60;
    int minutes = totalSleepMinutes % 60;
    return "${hours}h ${minutes}m";
  }

  // Raw Streams
  final StreamController<List<int>> _accelStreamController =
      StreamController<List<int>>.broadcast();
  Stream<List<int>> get accelStream => _accelStreamController.stream;

  final StreamController<List<int>> _ppgStreamController =
      StreamController<List<int>>.broadcast();
  Stream<List<int>> get ppgStream => _ppgStreamController.stream;

  // Auto-Monitor Config State
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

  DateTime _selectedDate = DateTime.now();
  DateTime get selectedDate => _selectedDate;

  void setSelectedDate(DateTime date) {
    if (date == _selectedDate) return;
    _selectedDate = date;

    // Clear history for the new view
    _hrHistory.clear();
    _spo2History.clear();
    _stressHistory.clear();
    _hrvHistory.clear();
    _stepsHistory.clear();
    _sleepHistory.clear();

    // Optional: Reset aggregates if they track the selected day
    _steps = 0;

    notifyListeners();
  }

  // Smart Sync State
  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;

  DateTime? _lastSyncTime;
  Timer? _periodicSyncTimer;
  final Duration _syncInterval = const Duration(minutes: 60);
  final Duration _minSyncDelay = const Duration(minutes: 15);

  // Auto-Reconnect
  String? _lastDeviceId;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _periodicSyncTimer?.cancel();
    _accelStreamController.close();
    _ppgStreamController.close();
    _scanner.removeListener(_checkAutoConnect);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      debugPrint("App Resumed - Checking Smart Sync...");
      triggerSmartSync();
    }
  }

  Future<void> init() async {
    // Check permissions
    if (Platform.isAndroid) {
      await [
        Permission.location,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();
    }
    // Load bonded devices
    await _scanner.loadBondedDevices();

    // Load last device ID for auto-reconnect
    await _loadLastDeviceId();

    // Listen for scan results using the combined check
    _scanner.addListener(_checkAutoConnect);

    // Attempt immediate connection if device is already bonded
    _checkAutoConnect();
  }

  Future<void> _loadLastDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    _lastDeviceId = prefs.getString('last_device_id');
    if (_lastDeviceId != null) {
      debugPrint("Loaded Last Device ID: $_lastDeviceId");
    }
  }

  Future<void> _saveLastDeviceId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_device_id', id);
    _lastDeviceId = id;
    debugPrint("Saved Last Device ID: $id");
  }

  void _checkAutoConnect() {
    // If already connected or connecting, or no last device, ignore
    if (isConnected ||
        _status.startsWith("Connecting") ||
        _lastDeviceId == null) {
      return;
    }

    BluetoothDevice? target;

    // 1. Check Bonded Devices (Fastest, no scan needed)
    try {
      target = _scanner.bondedDevices.firstWhere(
        (d) => d.remoteId.str == _lastDeviceId,
      );
      debugPrint("Auto-Connect: Found in Bonded Devices");
    } catch (_) {}

    // 2. Check Scan Results
    if (target == null) {
      try {
        final match = _scanner.scanResults.firstWhere(
          (r) => r.device.remoteId.str == _lastDeviceId,
        );
        target = match.device;
        debugPrint("Auto-Connect: Found in Scan Results");
        stopScan();
      } catch (_) {}
    }

    if (target != null) {
      debugPrint("Triggering Auto-Connect to: ${target.remoteId.str}");
      connectToDevice(target);
    }
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
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

      if (Platform.isAndroid) {
        try {
          await device.requestMtu(512);
        } catch (e) {
          debugPrint("MTU Request Failed: $e");
        }
        try {
          await device.createBond();
        } catch (e) {
          debugPrint("Bonding failed/skipped: $e");
        }
      }

      await _discoverServices(device);

      // Setup Sensor Controller command sender
      _sensorController.sendCommand = (data) async {
        if (_writeChar != null) {
          await _writeChar!.write(data);
        }
      };

      debugPrint("Waiting 2s for ring to settle...");
      await Future.delayed(const Duration(seconds: 2));

      await startPairing(); // Initial Handshake

      // Restore Settings
      await syncSettingsToRing();

      _status = "Connected to ${device.platformName}";

      // Save as last device for auto-reconnect
      await _saveLastDeviceId(device.remoteId.str);

      notifyListeners();

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
    _writeChar = null;
    _writeCharV2 = null;
    _notifyChar = null;
    _notifyCharV2 = null;

    // Standard Nordic UART
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

    // V2 Service
    try {
      var serviceV2 = services.firstWhere(
        (s) =>
            s.uuid.toString().toLowerCase() ==
            BleConstants.serviceUuidV2.toLowerCase(),
      );
      for (var c in serviceV2.characteristics) {
        String uuid = c.uuid.toString().toLowerCase();
        if (uuid == BleConstants.notifyCharUuidV2.toLowerCase()) {
          _notifyCharV2 = c;
        }
        if (uuid == BleConstants.writeCharUuidV2.toLowerCase()) {
          _writeCharV2 = c;
        }
      }
    } catch (e) {
      debugPrint("Colmi V2 Service not found (V1-only?)");
    }

    // Fallback
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

    // Subscribe V1
    if (_notifyChar != null) {
      await _notifySubscription?.cancel();
      await _notifyChar!.setNotifyValue(true);
      _notifySubscription = _notifyChar!.lastValueStream.listen(
        _onDataReceived,
      );
    }

    // Subscribe V2
    if (_notifyCharV2 != null) {
      await _notifySubscriptionV2?.cancel();
      await _notifyCharV2!.setNotifyValue(true);
      _notifySubscriptionV2 = _notifyCharV2!.lastValueStream.listen(
        _onDataReceived,
      );
    }
  }

  Future<void> _onDataReceived(List<int> data) async {
    await _processor.processData(data);
  }

  void _cleanup() {
    _connectedDevice = null;
    _writeChar = null;
    _notifyChar = null;
    _notifyCharV2 = null;
    _notifySubscription?.cancel();
    _notifySubscriptionV2?.cancel();
    _connectionStateSubscription?.cancel();
    _sensorController.sendCommand = null; // Disable sending
    _heartRate = 0;
    _batteryLevel = 0;
    _hrHistory.clear();
    _stressHistory.clear();
    _stopPeriodicSyncTimer();
  }

  // --- BleDataCallbacks Implementation ---

  @override
  void onProtocolLog(String message) {
    addToProtocolLog(message);
  }

  @override
  void onRawLog(String message) {
    _logger.setLastLog(message);
  }

  @override
  void onHeartRate(int bpm) {
    if (bpm > 0) {
      _heartRate = bpm;
      _lastHrTime = DateTime.now();
      notifyListeners();
      // Notify Controller to handle auto-stop logic
      _sensorController.onHeartRateReceived(bpm);
    }
  }

  @override
  void onSpo2(int percent) {
    if (percent > 0) {
      _spo2 = percent;
      _lastSpo2Time = DateTime.now();
      _logger.setLastLog("SpO2 Success: $percent");

      // Notify Controller
      _sensorController.onSpo2Received(percent);

      // Live "Polyfill" to Graph
      final now = DateTime.now();
      bool isToday = _selectedDate.year == now.year &&
          _selectedDate.month == now.month &&
          _selectedDate.day == now.day;

      if (isToday) {
        int minutes = now.hour * 60 + now.minute;
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
      _sensorController.onStressReceived(level);
    }
  }

  @override
  void onHrv(int val) {
    if (val > 0) {
      _hrv = val;
      _lastHrvTime = DateTime.now();
      _sensorController.onHrvReceived(val);

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
    }
  }

  @override
  void onBattery(int level) {
    _batteryLevel = level;
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
  void onHeartRateHistoryPoint(DateTime timestamp, int bpm) {
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
      notifyListeners(); // Potentially spammy, optimize later
    }
  }

  @override
  void onSpo2HistoryPoint(DateTime timestamp, int percent) {
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
      _spo2History.removeWhere((p) => p.x == minutes);
      _spo2History.add(Point(minutes, percent));
      notifyListeners();
    }
  }

  @override
  void onStressHistoryPoint(DateTime timestamp, int level) {
    if (level > 0) {
      if (_lastStressTime == null || timestamp.isAfter(_lastStressTime!)) {
        _stress = level;
        _lastStressTime = timestamp;
      }
    }
    int minutes = timestamp.hour * 60 + timestamp.minute;
    _stressHistory.add(Point(minutes, level));
    notifyListeners();
  }

  @override
  void onStepsHistoryPoint(DateTime timestamp, int steps, int quarterIndex) {
    bool isSameDay = timestamp.year == _selectedDate.year &&
        timestamp.month == _selectedDate.month &&
        timestamp.day == _selectedDate.day;
    if (isSameDay) {
      _stepsHistory.removeWhere((p) => p.x == quarterIndex);
      _stepsHistory.add(Point(quarterIndex, steps));
      _steps = _stepsHistory.fold<int>(0, (sum, p) => sum + p.y.toInt());
      _lastStepsTime = DateTime.now();
      notifyListeners();
    }
  }

  @override
  void onHrvHistoryPoint(DateTime timestamp, int val) {
    if (val > 0) {
      if (_lastHrvTime == null || timestamp.isAfter(_lastHrvTime!)) {
        _hrv = val;
        _lastHrvTime = timestamp;
      }
    }

    bool exists = _hrvHistory.any((p) {
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
  void onSleepHistoryPoint(DateTime timestamp, int sleepStage,
      {int durationMinutes = 0}) {
    // Remove existing entry with same timestamp to avoid duplicates
    _sleepHistory.removeWhere((item) => item.timestamp == timestamp);

    bool isSameDay = timestamp.year == _selectedDate.year &&
        timestamp.month == _selectedDate.month &&
        timestamp.day == _selectedDate.day;

    if (isSameDay) {
      _sleepHistory.add(SleepData(
        timestamp: timestamp,
        stage: sleepStage,
        durationMinutes: durationMinutes,
      ));
      _sleepHistory.sort((a, b) => a.timestamp.compareTo(b.timestamp));
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
      syncHeartRateHistory();
    } else if (type == 0x03 || type == 0x2C) {
      // Chain syncs
      Future.delayed(Duration.zero, () async {
        await syncHeartRateHistory();
        await Future.delayed(const Duration(milliseconds: 500));
        await syncSpo2History();
        await Future.delayed(const Duration(milliseconds: 500));
        await syncStressHistory();
      });
    }
  }

  @override
  void onFindDevice() {
    debugPrint("Ring requested FIND DEVICE");
    _logger.setLastLog("Ring Find Device Request");
  }

  @override
  void onGoalsRead(
      int steps, int calories, int distance, int sport, int sleep) {
    debugPrint(
        "Goals: Steps=$steps Cals=$calories Dist=$distance Sport=$sport Sleep=$sleep");
    // TODO: Expose these if needed in UI
  }

  @override
  void onMeasurementError(int type, int errorCode) {
    debugPrint("Measurement Error: Type=$type Code=$errorCode");
    _logger.setLastLog("Error: T=$type C=$errorCode");
  }

  // --- Device Management Commands ---
  Future<void> findDevice() async {
    if (_writeChar == null) return;
    await _writeChar!.write(PacketFactory.createFindDevicePacket());
  }

  // --- Sensor Commands (Delegate to Controller) ---
  // Mutual exclusion is handled here or updated in Controller.
  // We keep mutual exclusion simple here.
  Future<void> startHeartRate() async {
    if (_sensorController.isMeasuringSpo2) await _sensorController.stopSpo2();
    await _sensorController.startHeartRate();
  }

  Future<void> stopHeartRate() => _sensorController.stopHeartRate();

  Future<void> startSpo2() async {
    if (_sensorController.isMeasuringHeartRate)
      await _sensorController.stopHeartRate();
    await _sensorController.startSpo2();
  }

  Future<void> stopSpo2() => _sensorController.stopSpo2();

  Future<void> startRawPPG() => _sensorController.startRawPPG();
  Future<void> stopRawPPG() => _sensorController.stopRawPPG();

  Future<void> startStressTest() async {
    if (_sensorController.isMeasuringHeartRate)
      await _sensorController.stopHeartRate();
    if (_sensorController.isMeasuringSpo2) await _sensorController.stopSpo2();
    await _sensorController.startStressTest();
  }

  Future<void> stopStressTest() => _sensorController.stopStressTest();

  Future<void> startRealTimeHrv() => _sensorController.startRealTimeHrv();
  Future<void> stopRealTimeHrv() => _sensorController.stopRealTimeHrv();

  // --- Helper Methods & Sync ---

  String _formatTime(DateTime? dt, {bool isDaily = false}) {
    if (dt == null) return "No Data";
    if (isDaily) return "Today";
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
    } else {
      return "${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
    }
  }

  Future<void> triggerSmartSync({bool force = false}) async {
    if (!isConnected) return;
    final now = DateTime.now();
    if (!force && _lastSyncTime != null) {
      final elapsed = now.difference(_lastSyncTime!);
      if (elapsed < _minSyncDelay) {
        debugPrint(
            "Smart Sync Throttled: Last sync was ${elapsed.inMinutes} mins ago");
        return;
      }
    }
    await startFullSyncSequence();
    _lastSyncTime = DateTime.now();
  }

  Future<void> syncAllData() async {
    // Manual trigger overrides throttle
    await triggerSmartSync(force: true);
  }

  void _startPeriodicSyncTimer() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = Timer.periodic(_syncInterval, (timer) {
      triggerSmartSync();
    });
  }

  void _stopPeriodicSyncTimer() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = null;
  }

  Future<void> downloadFromCloud() async {
    if (_lastDeviceId == null) {
      debugPrint("No Last Device ID to fetch for.");
      return;
    }
    _isSyncing = true;
    notifyListeners();
    try {
      debugPrint("Downloading from Cloud for $_selectedDate...");
      final date = _selectedDate;

      // 1. Heart Rate
      final hrList = await _apiService.getHeartRate(_lastDeviceId!, date);
      _hrHistory.clear();
      for (var item in hrList) {
        final dt = DateTime.parse(item['recorded_at']);
        final val = item['bpm'] as int;
        if (dt.year == date.year &&
            dt.month == date.month &&
            dt.day == date.day) {
          int minutes = dt.hour * 60 + dt.minute;
          _hrHistory.add(Point(minutes, val));
        }
      }

      // 2. SpO2
      final spo2List = await _apiService.getSpo2(_lastDeviceId!, date);
      _spo2History.clear();
      for (var item in spo2List) {
        final dt = DateTime.parse(item['recorded_at']);
        final val = item['spo2_percent'] as int;
        if (dt.year == date.year &&
            dt.month == date.month &&
            dt.day == date.day) {
          int minutes = dt.hour * 60 + dt.minute;
          _spo2History.add(Point(minutes, val));
        }
      }

      // 3. Stress
      final stressList = await _apiService.getStress(_lastDeviceId!, date);
      _stressHistory.clear();
      for (var item in stressList) {
        final dt = DateTime.parse(item['recorded_at']);
        final val = item['stress_level'] as int;
        if (dt.year == date.year &&
            dt.month == date.month &&
            dt.day == date.day) {
          int minutes = dt.hour * 60 + dt.minute;
          _stressHistory.add(Point(minutes, val));
        }
      }

      // 4. HRV
      final hrvList = await _apiService.getHrv(_lastDeviceId!, date);
      _hrvHistory.clear();
      for (var item in hrvList) {
        final dt = DateTime.parse(item['recorded_at']);
        final val = item['hrv_val'] as int;
        if (dt.year == date.year &&
            dt.month == date.month &&
            dt.day == date.day) {
          int minutes = dt.hour * 60 + dt.minute;
          _hrvHistory.add(Point(minutes, val));
        }
      }

      // 5. Steps
      final stepsList = await _apiService.getSteps(_lastDeviceId!, date);
      _stepsHistory.clear();
      // Steps usually by quarter. Reverse mapping?
      // Point(quarterIndex, steps).
      // recorded_at is just timestamp.
      // We'll trust the time.
      for (var item in stepsList) {
        final dt = DateTime.parse(item['recorded_at']);
        final val = item['steps'] as int;
        if (dt.year == date.year &&
            dt.month == date.month &&
            dt.day == date.day) {
          // Approximate quarter index
          int minutes = dt.hour * 60 + dt.minute;
          int quarter = minutes ~/ 15;
          _stepsHistory.add(Point(quarter, val));
        }
      }
      if (_stepsHistory.isNotEmpty) {
        _steps = _stepsHistory.fold<int>(0, (sum, p) => sum + p.y.toInt());
      } else {
        _steps = 0;
      }

      // 6. Sleep
      final sleepList = await _apiService.getSleep(_lastDeviceId!, date);
      _sleepHistory.clear();
      for (var item in sleepList) {
        final dt = DateTime.parse(item['recorded_at']);
        final stage = item['sleep_stage'] as int;
        final minutes = item['duration_minutes'] as int;
        // Don't strict filter by date for sleep? Sometimes sleep crosses midnight.
        // Keeping it strictly to what server returned for "date" query.
        _sleepHistory.add(
            SleepData(timestamp: dt, stage: stage, durationMinutes: minutes));
      }
      _sleepHistory.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      debugPrint("Download Complete. Updated Histories.");
      _logger.setLastLog("Cloud DL Success");
    } catch (e) {
      debugPrint("Download Failed: $e");
      _logger.setLastLog("Cloud DL Err: $e");
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  Future<void> syncToCloud() async {
    _isSyncing = true;
    notifyListeners();
    try {
      debugPrint("Starting Cloud Sync...");

      // 1. Heart Rate
      final hrData = _hrHistory.map((p) {
        final time = DateTime(_selectedDate.year, _selectedDate.month,
            _selectedDate.day, p.x ~/ 60, p.x.toInt() % 60);
        return {
          "recorded_at": time.toIso8601String(),
          "bpm": p.y.toInt(),
          "device_id": _lastDeviceId ?? "unknown" // Add device ID for server
        };
      }).toList();
      await _apiService.saveHeartRate(hrData);

      // 2. SpO2
      final spo2Data = _spo2History.map((p) {
        final time = DateTime(_selectedDate.year, _selectedDate.month,
            _selectedDate.day, p.x ~/ 60, p.x.toInt() % 60);
        return {
          "recorded_at": time.toIso8601String(),
          "spo2_percent": p.y.toInt(),
          "device_id": _lastDeviceId ?? "unknown"
        };
      }).toList();
      await _apiService.saveSpo2(spo2Data);

      // 3. Stress
      final stressData = _stressHistory.map((p) {
        final time = DateTime(_selectedDate.year, _selectedDate.month,
            _selectedDate.day, p.x ~/ 60, p.x.toInt() % 60);
        return {
          "recorded_at": time.toIso8601String(),
          "stress_level": p.y.toInt(),
          "device_id": _lastDeviceId ?? "unknown"
        };
      }).toList();
      await _apiService.saveStress(stressData);

      // 4. HRV
      final hrvData = _hrvHistory.map((p) {
        final time = DateTime(_selectedDate.year, _selectedDate.month,
            _selectedDate.day, p.x ~/ 60, p.x.toInt() % 60);
        return {
          "recorded_at": time.toIso8601String(),
          "hrv_val": p.y.toInt(),
          "device_id": _lastDeviceId ?? "unknown"
        };
      }).toList();
      await _apiService.saveHrv(hrvData);

      // 5. Steps
      // Steps history has x=quarterIndex?
      // onStepsHistoryPoint: _stepsHistory.add(Point(quarterIndex, steps));
      // Assuming quarterIndex increments from 0 (00:00). Each step is 15 mins?
      // Standard Colmi/Gadgetbridge logic often uses 15min slots.
      // 0 = 00:00-00:15
      final stepsData = _stepsHistory.map((p) {
        // approximate time
        int totalMinutes = p.x.toInt() * 15;
        final time = _selectedDate.add(Duration(minutes: totalMinutes));
        return {
          "recorded_at": time.toIso8601String(),
          "steps": p.y.toInt(),
          "device_id": _lastDeviceId ?? "unknown"
        };
      }).toList();
      await _apiService.saveSteps(stepsData);

      // 6. Sleep
      final sleepData = _sleepHistory.map((s) {
        return {
          "recorded_at": s.timestamp.toIso8601String(),
          "sleep_stage": s.stage,
          "duration_minutes": s.durationMinutes,
          "device_id": _lastDeviceId ?? "unknown"
        };
      }).toList();
      await _apiService.saveSleep(sleepData);

      _logger.setLastLog("Cloud Sync Success");
    } catch (e) {
      debugPrint("Cloud Sync Failed: $e");
      _logger.setLastLog("Cloud Err: $e");
      // Don't rethrow to avoid crashing UI, just log
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  // --- Misc Commands ---

  Future<void> startPairing() async {
    if (_writeChar == null) return;
    addToProtocolLog("TX: 04 ... (Set Name)", isTx: true);
    await _writeChar!.write(PacketFactory.createSetPhoneNamePacket());
    await Future.delayed(const Duration(milliseconds: 200));

    addToProtocolLog("TX: 01 ... (Set Time)", isTx: true);
    await _writeChar!.write(PacketFactory.createSetTimePacket());
    await Future.delayed(const Duration(milliseconds: 200));

    addToProtocolLog("TX: 0A ... (Set User Profile)", isTx: true);
    await _writeChar!.write(PacketFactory.createUserProfilePacket());
    await Future.delayed(const Duration(milliseconds: 200));

    addToProtocolLog("TX: 03 (Battery)", isTx: true);
    await _writeChar!.write(PacketFactory.getBatteryPacket());

    // Bond
    if (Platform.isAndroid) {
      try {
        await _connectedDevice?.createBond();
      } catch (e) {}
    }
  }

  // Wrapper for consistency
  Future<void> syncTime() => normalizeTime();

  Future<void> normalizeTime() async {
    if (_writeChar == null) return;
    try {
      await _writeChar!.write(PacketFactory.createSetTimePacket());
    } catch (e) {
      debugPrint("$e");
    }
  }

  Future<void> startFullSyncSequence() async {
    if (_writeChar == null) return;

    _isSyncing = true;
    notifyListeners();

    try {
      final now = DateTime.now();
      final difference = now.difference(_selectedDate).inDays;
      int offset = difference < 0 ? 0 : difference;

      await _writeChar!.write(PacketFactory.getStepsPacket(dayOffset: offset));
      await Future.delayed(const Duration(seconds: 2));
      await syncHeartRateHistory();
      await Future.delayed(const Duration(seconds: 2));
      await syncSpo2History();
      await Future.delayed(const Duration(seconds: 4));
      await syncStressHistory();
      await Future.delayed(const Duration(seconds: 2));
      await syncHrvHistory();
      await Future.delayed(const Duration(seconds: 2));
      await syncSleepHistory();
      _logger.setLastLog("Full Sync Completed");
    } finally {
      _isSyncing = false;
      notifyListeners();
    }
  }

  Future<void> syncStepsHistory() async {
    if (_writeChar == null) return;
    final now = DateTime.now();
    final difference = now.difference(_selectedDate).inDays;
    int offset = difference < 0 ? 0 : difference;
    await _writeChar!.write(PacketFactory.getStepsPacket(dayOffset: offset));
  }

  Future<void> syncHeartRateHistory() async {
    if (_writeChar == null) return;
    final startOfDay =
        DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day);
    await _writeChar!.write(PacketFactory.getHeartRateLogPacket(startOfDay));
  }

  Future<void> syncSpo2History() async {
    if (_writeChar == null) return;
    await _writeChar!.write(PacketFactory.getSpo2LogPacketNew());
  }

  Future<void> syncStressHistory() async {
    if (_writeChar == null) return;
    await _writeChar!.write(PacketFactory.getStressHistoryPacket());
  }

  Future<void> syncHrvHistory() async {
    if (_writeChar == null) return;
    await _writeChar!.write(PacketFactory.getHrvLogPacket());
  }

  Future<void> syncSleepHistory() async {
    // 0. Ensure Bind/Auth (just in case)
    // 1. Bind Action / Prep (0x48) - Use simple request (48 00...48) matching logs
    try {
      debugPrint('Step 1: Sending Bind Request (0x48)');
      await _writeChar!.write(PacketFactory.createBindRequest());
      await Future.delayed(const Duration(milliseconds: 300));

      // 2. Set Phone Name (0x04)
      debugPrint('Step 2: Sending Set Phone Name (0x04)');
      await _writeChar!.write(PacketFactory.createSetPhoneNamePacket());
      await Future.delayed(const Duration(milliseconds: 300));

      // 3. Set Time (0x01)
      debugPrint('Step 3: Sending Set Time (0x01)');
      await _writeChar!.write(PacketFactory.createSetTimePacket());
      await Future.delayed(const Duration(milliseconds: 300));

      // 4. Set User Profile (0x0A)
      debugPrint('Step 4: Sending User Profile (0x0A)');
      await _writeChar!.write(PacketFactory.createUserProfilePacket());
      await Future.delayed(const Duration(milliseconds: 300));

      // 5. Realtime Data Config (0x43)
      debugPrint('Step 5: Sending Realtime Data Config (0x43)');
      await _writeChar!.write(PacketFactory.getRealtimeDataPacket());
      await Future.delayed(const Duration(milliseconds: 300));
    } catch (e) {
      debugPrint('Error in Prep steps: $e');
    }

    // 6. Request Sleep Data (0xBC 27)
    // Variants 4-9
    // Using Variant 4 (Standard Gadgetbridge Format: 16-byte)
    debugPrint('Step 6: Requesting Sleep Data (0xBC 27)');

    if (_writeCharV2 != null) {
      debugPrint('Using V2 Write Characteristic for Sleep Request');
      await _writeCharV2!.write(PacketFactory.createSleepRequestPacket());
    } else {
      debugPrint(
          'Using Default Write Characteristic (Fallback) for Sleep Request');
      await _writeChar!.write(PacketFactory.createSleepRequestPacket());
    }
    await Future.delayed(const Duration(milliseconds: 1000));

    // 7. Legacy 0x7A (Packet 0) as fallback
    await _writeChar!.write(PacketFactory.getSleepLogPacket(packetIndex: 0));
  }

  Future<void> getBatteryLevel() async {
    if (_writeChar == null) return;
    await _writeChar!.write(PacketFactory.getBatteryPacket());
  }

  // Auto Settings
  Future<void> setAutoHrInterval(int minutes) async {
    _hrAutoEnabled = (minutes > 0);
    if (minutes > 0) _hrInterval = minutes;
    notifyListeners();
    if (_writeChar == null) return;

    int enabledVal = minutes > 0 ? 0x01 : 0x00;
    int intervalVal = minutes > 0 ? minutes : 0;
    Uint8List packet = PacketFactory.createPacket(
        command: 0x16, data: [0x02, enabledVal, intervalVal]);

    addToProtocolLog("TX: Auto HR $minutes", isTx: true);
    await _writeChar!.write(packet);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('hrInterval', minutes);
  }

  Future<void> setAutoSpo2(bool enabled) async {
    _spo2AutoEnabled = enabled;
    notifyListeners();
    if (_writeChar == null) return;
    Uint8List packet = PacketFactory.createPacket(
        command: 0x2C, data: [0x02, enabled ? 1 : 0]);
    addToProtocolLog("TX: Auto SpO2 $enabled", isTx: true);
    await _writeChar!.write(packet);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('spo2Enabled', enabled);
  }

  Future<void> setAutoStress(bool enabled) async {
    _stressAutoEnabled = enabled;
    notifyListeners();
    if (_writeChar == null) return;
    Uint8List packet = PacketFactory.createPacket(
        command: 0x36, data: [0x02, enabled ? 1 : 0]);
    addToProtocolLog("TX: Auto Stress $enabled", isTx: true);
    await _writeChar!.write(packet);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('stressEnabled', enabled);
  }

  Future<void> setAutoHrv(bool enabled) async {
    _hrvAutoEnabled = enabled;
    notifyListeners();
    if (_writeChar == null) return;
    Uint8List packet = PacketFactory.createPacket(
        command: 0x38, data: [0x02, enabled ? 1 : 0]);
    addToProtocolLog("TX: Auto HRV $enabled", isTx: true);
    await _writeChar!.write(packet);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('hrvEnabled', enabled);
  }

  Future<void> readAutoSettings() async {
    if (_writeChar == null) return;
    await _writeChar!.write([0x16, 0x01]);
    await Future.delayed(const Duration(milliseconds: 300));
    await _writeChar!.write([0x2C, 0x01]);
    await Future.delayed(const Duration(milliseconds: 300));
    await _writeChar!.write([0x36, 0x01]);
    await Future.delayed(const Duration(milliseconds: 300));
    await _writeChar!.write([0x38, 0x01]);
  }

  Future<void> syncSettingsToRing() async {
    await normalizeTime();
    final prefs = await SharedPreferences.getInstance();
    int? hr = prefs.getInt('hrInterval');
    if (hr != null) await setAutoHrInterval(hr);
    bool? spo2 = prefs.getBool('spo2Enabled');
    if (spo2 != null) await setAutoSpo2(spo2);
    bool? stress = prefs.getBool('stressEnabled');
    if (stress != null) await setAutoStress(stress);
    bool? hrv = prefs.getBool('hrvEnabled');
    if (hrv != null) await setAutoHrv(hrv);
  }

  // Wrappers
  Future<void> setHeartRateMonitoring(bool enabled) =>
      setAutoHrInterval(enabled ? 5 : 0);
  Future<void> setSpo2Monitoring(bool enabled) => setAutoSpo2(enabled);
  Future<void> setStressMonitoring(bool enabled) => setAutoStress(enabled);

  Future<void> factoryReset() async {
    if (_writeChar == null) return;
    await _writeChar!
        .write(PacketFactory.createPacket(command: 0xFF, data: [0x66, 0x66]));
  }

  Future<void> rebootRing() async {
    if (_writeChar == null) return;
    await _writeChar!
        .write(PacketFactory.createPacket(command: 0x08, data: [0x05]));
  }

  Future<void> sendRawPacket(List<int> packet) async {
    if (_writeChar == null) return;
    addToProtocolLog("TX: Manual", isTx: true);
    await _writeChar!.write(packet);
  }

  Future<void> enableRawData() async {
    if (_writeChar == null) return;
    await _writeChar!.write(PacketFactory.enableRawDataPacket());
  }

  Future<void> disableRawData() async {
    if (_writeChar == null) return;
    await _writeChar!.write(PacketFactory.disableRawDataPacket());
  }

  Future<void> unpairRing() async {
    await _scanner.loadBondedDevices(); // Just reload
    // Logic for unpair in original was just removeBond on connected device
    if (_connectedDevice != null) {
      try {
        await _connectedDevice!.removeBond();
      } catch (e) {}
    }
  }

  // --- Aliases for compatibility ---
  Future<void> startRealTimeHeartRate() => startHeartRate();
  Future<void> stopRealTimeHeartRate() => stopHeartRate();
  Future<void> startRealTimeSpo2() => startSpo2();
  Future<void> stopRealTimeSpo2() => stopSpo2();

  Future<void> forceStopEverything() async {
    if (_writeChar == null) return;
    debugPrint("Force Stopping Everything...");
    try {
      await disableRawData();
      // Stop all sensors via controller which handles logic
      if (_sensorController.isMeasuringHeartRate)
        await _sensorController.stopHeartRate();
      if (_sensorController.isMeasuringSpo2) await _sensorController.stopSpo2();
      if (_sensorController.isMeasuringStress)
        await _sensorController.stopStressTest();
      if (_sensorController.isMeasuringHrv)
        await _sensorController.stopRealTimeHrv();
      if (_sensorController.isMeasuringRawPPG)
        await _sensorController.stopRawPPG();

      // Send manual disable packets just in case
      await _writeChar!.write(PacketFactory.disableHeartRate());
      await _writeChar!.write(PacketFactory.disableSpo2());
    } catch (e) {
      debugPrint("Error force stopping: $e");
    }
  }
}
