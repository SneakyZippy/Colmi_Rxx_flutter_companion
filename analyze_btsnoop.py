import struct
import sys
import os

def parse_btsnoop(filepath):
    print(f"--- Analyzing {os.path.basename(filepath)} ---")
    try:
        with open(filepath, "rb") as f:
            header = f.read(16)
            if len(header) < 16:
                print("File too short for header")
                return

            magic = header[:8]
            if magic != b'btsnoop\0':
                print(f"Invalid magic: {magic}")
                # It might be in pcap format instead of btsnoop?
                # Some androids use pcap. Magic for pcap is different.
                # standard pcap: a1 b2 c3 d4 (big endian) or d4 c3 b2 a1 (little)
                # Let's check for "btsnoop"
                return

            version, datalink = struct.unpack(">II", header[8:16])
            print(f"Version: {version}, DataLink: {datalink}")

            packet_count = 0
            while True:
                # Record Header: 24 bytes
                rec_header = f.read(24)
                if len(rec_header) < 24:
                    break

                orig_len, inc_len, flags, drops, time_hi, time_lo = struct.unpack(">IIIIII", rec_header)
                
                # Read Data
                packet_data = f.read(inc_len)
                if len(packet_data) < inc_len:
                    break

                packet_count += 1
                
                # HCI Packet Type (1 byte) is usually the first byte of packet_data for UART (H0) encapsulation
                # Types: 0x01=Cmd, 0x02=ACL Data, 0x03=SCO, 0x04=Event
                # We care about ACL Data (0x02) for ATT payload
                
                # If DataLink is 1002 (HCI UART), first byte is packet type.
                # If DataLink is 1001 (HCI), there is no packet type byte? (Depends on implementation, usually not)
                # Android usually uses H4 (UART) or similar.
                
                hci_type = packet_data[0]
                
                # We want ACL Data (0x02)
                if hci_type == 0x02:
                    # ACL Data Header: Handle (12 bits) + PB (2 bits) + BC (2 bits) | Total Len (2 bytes)
                    # Total 4 bytes usually (excluding type)
                    # packet_data[1] and [2] has Handle info
                    if len(packet_data) < 5: 
                        continue
                        
                    handle_flags = struct.unpack("<H", packet_data[1:3])[0]
                    conn_handle = handle_flags & 0x0FFF
                    
                    # L2CAP Header follows ACL Header
                    # Length (2 bytes) + CID (2 bytes)
                    l2cap_offset = 5 # 1(Type) + 4(ACL Header)
                    if len(packet_data) < l2cap_offset + 4:
                        continue
                        
                    l2cap_len, l2cap_cid = struct.unpack("<HH", packet_data[l2cap_offset:l2cap_offset+4])
                    
                    # Check for ATT (CID = 0x0004)
                    if l2cap_cid == 0x0004:
                        att_offset = l2cap_offset + 4
                        att_data = packet_data[att_offset:]
                        
                        if len(att_data) > 0:
                            opcode = att_data[0]
                            # ATT Opcodes of interest:
                            # 0x12: Write Request
                            # 0x52: Write Command
                            # 0x1B: Handle Value Notification
                            # 0x1D: Handle Value Indication
                            
                            opcode_name = ""
                            is_relevant = False
                            
                            if opcode == 0x12: 
                                opcode_name = "Write Req"
                                is_relevant = True
                            elif opcode == 0x52: 
                                opcode_name = "Write Cmd"
                                is_relevant = True
                            elif opcode == 0x1B: 
                                opcode_name = "Notification"
                                is_relevant = True
                            
                            if is_relevant:
                                # Extract Handle (2 bytes)
                                if len(att_data) >= 3:
                                    att_handle = struct.unpack("<H", att_data[1:3])[0]
                                    value = att_data[3:]
                                    if len(value) > 0:
                                        hex_val = value.hex().upper()
                                        print(f"#{packet_count} {opcode_name} [Handle: 0x{att_handle:04X}]: {hex_val}")

    except Exception as e:
        print(f"Error parsing: {e}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python analyze_btsnoop.py <file1> [file2...]")
    else:
        for f in sys.argv[1:]:
            if os.path.exists(f):
                parse_btsnoop(f)
            else:
                print(f"File not found: {f}")
