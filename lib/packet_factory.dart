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
    // 0x69 is CMD_START_REAL_TIME
    // Payload: [ReadingType.HEART_RATE (1), Action.STOP (0)]
    return createPacket(
      command: cmdHeartRateMeasurement,
      data: [0x01, 0x00],
    );
  }

  static const int cmdGetSteps = 0x43; // 67 decimal

  /// Creates packet to request steps for a specific day offset
  static Uint8List getStepsPacket({int dayOffset = 0}) {
    List<int> data = [dayOffset, 0x0f, 0x00, 0x5f, 0x01];
    return createPacket(command: cmdGetSteps, data: data);
  }

  // New Commands
  static const int cmdGetBattery = 0x03;
  static const int cmdGetHeartRateLog = 0x15; // 21 decimal

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
}
