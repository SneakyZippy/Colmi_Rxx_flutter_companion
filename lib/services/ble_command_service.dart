import 'package:flutter/foundation.dart';
import 'packet_factory.dart';

typedef DataSender = Future<void> Function(List<int> data);
typedef Logger = void Function(String message);

class BleCommandService {
  final DataSender _sender;
  final Logger? _logger;

  BleCommandService(this._sender, {Logger? logger}) : _logger = logger;

  Future<void> send(List<int> data, {String? logMessage}) async {
    if (logMessage != null && _logger != null) {
      _logger!(logMessage);
    }
    await _sender(data);
  }

  // --- Handshake / Setup ---

  Future<void> setPhoneName() async {
    await send(PacketFactory.createSetPhoneNamePacket(),
        logMessage: "TX: 04 ... (Set Name)");
  }

  Future<void> setTime() async {
    await send(PacketFactory.createSetTimePacket(),
        logMessage: "TX: 01 ... (Set Time)");
  }

  Future<void> setUserProfile() async {
    await send(PacketFactory.createUserProfilePacket(),
        logMessage: "TX: 0A ... (Set User Profile)");
  }

  Future<void> requestBattery() async {
    await send(PacketFactory.getBatteryPacket(),
        logMessage: "TX: 03 (Get Battery)");
  }

  Future<void> requestSettings(int command) async {
    // 0x16, 0x2C, 0x36, 0x21
    await send(PacketFactory.createPacket(command: command, data: [0x01]),
        logMessage:
            "TX: ${command.toRadixString(16).toUpperCase()} 01 (Request Setting)");
  }

  // --- Configuration ---

  Future<void> setAutoHeartRate(bool enabled, {int interval = 5}) async {
    if (enabled) {
      await send(PacketFactory.enableHeartRate(interval: interval),
          logMessage: "TX: 16 ... (Enable Auto HR: $interval min)");
    } else {
      await send(PacketFactory.disableHeartRate(),
          logMessage: "TX: 16 ... (Disable Auto HR)");
    }
  }

  Future<void> setAutoSpo2(bool enabled) async {
    if (enabled) {
      await send(PacketFactory.enableSpo2(),
          logMessage: "TX: 2C ... (Enable Auto SpO2)");
    } else {
      await send(PacketFactory.disableSpo2(),
          logMessage: "TX: 2C ... (Disable Auto SpO2)");
    }
  }

  Future<void> setAutoStress(bool enabled) async {
    await send(
        PacketFactory.createPacket(
            command: 0x36, data: [0x02, enabled ? 0x01 : 0x00]),
        logMessage: "TX: 36 ... (Set Auto Stress: $enabled)");
  }

  // --- Real-Time Measurement ---

  Future<void> startHeartRate() async {
    await send(PacketFactory.startHeartRate(),
        logMessage: "TX: 69 01 (Start Manual HR)");
  }

  Future<void> stopHeartRate() async {
    await send(PacketFactory.stopHeartRate(),
        logMessage: "TX: 6A 01 (Stop Manual HR)");
  }

  Future<void> startSpo2() async {
    // 69 03 00
    await send(PacketFactory.createPacket(command: 0x69, data: [0x03, 0x00]),
        logMessage: "TX: 69 03 00 (Start Real-Time SpO2)");
  }

  Future<void> stopSpo2() async {
    await send(PacketFactory.createPacket(command: 0x6A, data: [0x03, 0x00]),
        logMessage: "TX: 6A 03 00 (Stop Real-Time SpO2)");
  }

  Future<void> startHrv() async {
    await send(PacketFactory.createPacket(command: 0x69, data: [0x0A, 0x00]),
        logMessage: "TX: 69 0A 00 (Start Real-Time HRV)");
  }

  Future<void> stopHrv() async {
    await send(PacketFactory.createPacket(command: 0x6A, data: [0x0A, 0x00]),
        logMessage: "TX: 6A 0A 00 (Stop Real-Time HRV)");
  }

  Future<void> startStress() async {
    // 69 08 00
    await send(PacketFactory.createPacket(command: 0x69, data: [0x08, 0x00]),
        logMessage: "TX: 69 08 00 (Start Real-Time Stress)");
  }

  Future<void> stopStress() async {
    await send(PacketFactory.createPacket(command: 0x6A, data: [0x08, 0x00]),
        logMessage: "TX: 6A 08 00 (Stop Real-Time Stress)");
  }

  // --- Historical Data Sync ---

  // syncHistory removed as it is not used and PacketFactory.createSyncRequest is undefined.

  // --- Other ---

  Future<void> factoryReset() async {
    await send(PacketFactory.createPacket(command: 0xFF, data: [0x66, 0x66]),
        logMessage: "TX: Factory Reset");
  }

  Future<void> setActivityState(int type, int op) async {
    String opName = ["", "Start", "Pause", "Resume", "End"][op];
    String typeName = (type == 0x04)
        ? "Walk"
        : (type == 0x07)
            ? "Run"
            : "Unknown($type)";
    await send(PacketFactory.createPacket(command: 0x77, data: [op, type]),
        logMessage:
            "TX: 77 ${op.toRadixString(16)} ${type.toRadixString(16)} ($opName $typeName)");
  }

  // --- New Feature Methods ---

  Future<void> findDevice() async {
    await send(PacketFactory.createFindDevicePacket(),
        logMessage: "TX: 50 55 AA (Find Device)");
  }

  Future<void> requestGoals() async {
    await send(PacketFactory.requestGoals(),
        logMessage: "TX: 21 01 (Request Goals)");
  }

  // --- History Sync Wrappers ---

  Future<void> fetchActivityHistory() async {
    // 0x43 00 0F 00 60 00 (Today's steps)
    // Note: PacketFactory.getStepsPacket defaults to dayOffset=0
    await send(PacketFactory.getStepsPacket(),
        logMessage: "TX: 43 ... (Fetch Steps)");
  }

  Future<void> fetchHeartRateHistory() async {
    final now = DateTime.now();
    await send(PacketFactory.getHeartRateLogPacket(now),
        logMessage: "TX: 15 ... (Fetch HR)");
  }

  Future<void> fetchSpo2History() async {
    // Uses 0xBC 2A
    await send(PacketFactory.getSpo2LogPacketNew(),
        logMessage: "TX: BC 2A ... (Fetch SpO2 BigData)");
  }

  Future<void> fetchStressHistory() async {
    // 0x37
    await send(PacketFactory.getStressHistoryPacket(),
        logMessage: "TX: 37 ... (Fetch Stress)");
  }

  Future<void> fetchSleepHistory() async {
    // Uses 0xBC 27
    await send(PacketFactory.getSleepLogPacketNew(),
        logMessage: "TX: BC 27 ... (Fetch Sleep BigData)");
  }

  Future<void> fetchHrvHistory() async {
    await send(PacketFactory.getHrvLogPacket(packetIndex: 0),
        logMessage: "TX: 39 00 ... (Fetch HRV)");
  }
}
