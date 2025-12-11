import 'dart:io';
import 'dart:typed_data';

void main(List<String> args) async {
  if (args.isEmpty) {
    print("Usage: dart analyze_btsnoop.dart <file1> [file2...]");
    return;
  }

  for (var path in args) {
    if (await File(path).exists()) {
      await parseBtsnoop(path);
    } else {
      print("File not found: $path");
    }
  }
}

Future<void> parseBtsnoop(String path) async {
  print("--- Analyzing $path ---");
  final file = File(path);
  final bytes = await file.readAsBytes();
  final ByteData data = bytes.buffer.asByteData();
  int offset = 0;

  if (data.lengthInBytes < 16) {
    print("File too short");
    return;
  }

  // Header: 8 bytes magic ("btsnoop\0"), 4 ver, 4 datalink
  // Check Magic
  // btsnoop\0 = 62 74 73 6E 6F 6F 70 00
  if (bytes[0] != 0x62 || bytes[7] != 0x00) {
    print("Invalid Magic");
    return;
  }

  offset += 8;
  int version = data.getUint32(offset, Endian.big);
  offset += 4;
  int datalink = data.getUint32(offset, Endian.big);
  offset += 4;

  print("Version: $version, DataLink: $datalink (1002=HCI UART)");

  int packetCount = 0;

  while (offset < data.lengthInBytes) {
    if (offset + 24 > data.lengthInBytes) break;

    // Record Header
    int origLen = data.getUint32(offset, Endian.big);
    offset += 4;
    int incLen = data.getUint32(offset, Endian.big);
    offset += 4;
    int flags = data.getUint32(
        offset, Endian.big); // Bit 0: 0=Sent(Com/Evt), 1=Recv?? NO.
    // Packet Flags:
    // Bit 0: Direction (0=Sent, 1=Recv)
    // Bit 1: Command/Data (0=Data, 1=Cmd/Evt)
    offset += 4;
    int drops = data.getUint32(offset, Endian.big);
    offset += 4;
    // Time
    offset += 8;

    // Packet Data
    if (offset + incLen > data.lengthInBytes) break;

    Uint8List packetData = bytes.sublist(offset, offset + incLen);
    offset += incLen;
    packetCount++;

    if (packetData.isEmpty) continue;

    // Parsing HCI UART (H4)
    // Type (1 byte)
    // 01=Cmd, 02=ACL, 04=Event
    int type = packetData[0];

    if (type == 0x02) {
      // ACL
      // ACL Header (4 bytes): Handle(12) | PB(2) | BC(2), TotalLen(2)
      if (packetData.length < 5) continue;

      int handleFlags = packetData[1] | (packetData[2] << 8);
      int connHandle = handleFlags & 0x0FFF;

      // L2CAP Header (4 bytes): Len(2), CID(2)
      // Offset = 1(Type) + 4(ACL) = 5
      int l2capOffset = 5;
      if (packetData.length < l2capOffset + 4) continue;

      int l2capLen =
          packetData[l2capOffset] | (packetData[l2capOffset + 1] << 8);
      int l2capCid =
          packetData[l2capOffset + 2] | (packetData[l2capOffset + 3] << 8);

      if (l2capCid == 0x04) {
        // ATT
        int attOffset = l2capOffset + 4;
        if (attOffset >= packetData.length) continue;

        Uint8List attData = packetData.sublist(attOffset);
        if (attData.isEmpty) continue;

        int opcode = attData[0];
        bool relevant = false;
        String name = "";

        // 0x12 Write Req, 0x52 Write Cmd, 0x1B Notification
        if (opcode == 0x12) {
          name = "WriteReq";
          relevant = true;
        } else if (opcode == 0x52) {
          name = "WriteCmd";
          relevant = true;
        } else if (opcode == 0x1B) {
          name = "Notify";
          relevant = true;
        }

        if (relevant) {
          // Handle is next 2 bytes
          if (attData.length >= 3) {
            int attHandle = attData[1] | (attData[2] << 8);
            Uint8List val = attData.sublist(3);
            String hex = val
                .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
                .join("");

            // Filter useless/short packets if needed, or show all
            print(
                "#$packetCount $name [H:0x${attHandle.toRadixString(16)}] : $hex");
          }
        }
      }
    }
  }
}
