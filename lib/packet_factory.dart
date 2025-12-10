import 'dart:typed_data';

class PacketFactory {
  // Command Constants
  static const int cmdHeartRateMeasurement = 0x69; // 105 in decimal
  static const int cmdSetTime =
      0x01; // Example for Time Sync, need to confirm header/cmd structure

  // Headers
  // Protocol: Command + Data (14 bytes) + Checksum
  // Based on colmi_r02_client docs:
  // Byte 0: Command
  // Byte 1-14: Data
  // Byte 15: Checksum (Sum of 0-14 & 0xFF)

  /// Constructs a 16-byte packet.
  /// [command] - The command ID.
  /// [data] - A list of data bytes (will be padded or truncated to fit).
  static Uint8List createPacket({required int command, List<int>? data}) {
    final List<int> packet = List.filled(16, 0);

    packet[0] = command;

    if (data != null) {
      for (int i = 0; i < data.length && i < 14; i++) {
        packet[1 + i] = data[i];
      }
    }

    // Checksum: (Sum of bytes 0-14) & 0xFF
    int sum = 0;
    for (int i = 0; i < 15; i++) {
      sum += packet[i];
    }
    packet[15] = sum & 0xFF;

    return Uint8List.fromList(packet);
  }

  /// Creates sample commands based on user request
  static Uint8List startHeartRate() {
    // 0x69 is CMD_START_REAL_TIME
    // Payload: [ReadingType.HEART_RATE (1), Action.START (1)]
    // Based on tahnok/colmi_r02_client
    return createPacket(
      command: cmdHeartRateMeasurement,
      data: [0x01, 0x01],
    );
  }

  static Uint8List stopHeartRate() {
    // Reverting to 0x00
    return createPacket(
      command: cmdHeartRateMeasurement,
      data: [0x01, 0x00],
    );
  }

  static Uint8List startSpo2() {
    // 0x69 is CMD_START_REAL_TIME
    // Payload: [ReadingType.SPO2 (3), Action.START (1)]
    return createPacket(
      command: cmdHeartRateMeasurement,
      data: [0x03, 0x01],
    );
  }

  static Uint8List stopSpo2() {
    // Reverting to 0x00
    return createPacket(
      command: cmdHeartRateMeasurement,
      data: [0x03, 0x00],
    );
  }

  static const int cmdGetSteps = 0x43; // 67 decimal

  /// Creates packet to request steps for a specific day offset
  static Uint8List getStepsPacket({int dayOffset = 0}) {
    // 0x01 = Key, 0x00 = Start Index, 0x60 = Count (96 blocks of 15 min = 24h), 0x00
    // If 0x0F was used before, it might have been an offset or specific key?
    // Trying 0x01 based on common protocols, or sticking to 0x0F if it's the key.
    // Let's assume 0x0F is key, 0x00 is start, 0x60 (96) is length.
    List<int> data = [dayOffset, 0x0f, 0x00, 0x60, 0x00];
    return createPacket(command: cmdGetSteps, data: data);
  }

  // New Commands
  static const int cmdGetBattery = 0x03;
  static const int cmdGetHeartRateLog = 0x15; // 21 decimal
  static const int cmdGetSpo2Log = 0x16; // 22 decimal (Experimental)

  /// Creates packet to request battery level
  static Uint8List getBatteryPacket() {
    return createPacket(command: cmdGetBattery);
  }

  /// Creates packet to request Heart Rate Log for a specific date
  /// [date] - usually midnight of the requested day
  static Uint8List getHeartRateLogPacket(DateTime date) {
    // Structure based on colmi_r02_client:
    // Packet[0] = 0x15
    // Packet[1-4] = Timestamp (Little Endian)
    // Packet[5-15] = 0

    int timestamp = date.millisecondsSinceEpoch ~/ 1000;
    ByteData byteData = ByteData(4);
    byteData.setUint32(0, timestamp, Endian.little);

    List<int> data = List.filled(14, 0);
    for (int i = 0; i < 4; i++) {
      data[i] = byteData.getUint8(i);
    }

    return createPacket(command: cmdGetHeartRateLog, data: data);
  }

  /// Creates packet to request SpO2 Log
  /// [dayOffset] - 0 for today. Structure same as Steps (0x43).
  static Uint8List getSpo2LogPacket({int dayOffset = 0}) {
    // Structure assumed same as Steps (0x43) since response starts with 0xF0
    // [DayOffset, Key?, Start?, Count?, ?]
    // Steps uses: [Offset, 0x0f, 0x00, 0x60, 0x00]
    // We try the same structure for SpO2. Count 0x60 (96) covers 24h of 15-min blocks.
    // If SpO2 is sparse, this might just request "a day's buffer".
    List<int> data = [dayOffset, 0x0f, 0x00, 0x60, 0x00];
    return createPacket(command: cmdGetSpo2Log, data: data);
  }
}
