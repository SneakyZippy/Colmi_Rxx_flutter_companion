import struct
import sys
import os
import datetime

# Bluetooth Base UUID: 0000xxxx-0000-1000-8000-00805F9B34FB
def uuid16_to_uuid128(uuid16):
    return f"0000{uuid16:04X}-0000-1000-8000-00805F9B34FB"

def parse_events(txt_filepath):
    events = []
    print(f"--- parsing timeline from {os.path.basename(txt_filepath)} ---")
    try:
        with open(txt_filepath, 'r') as f:
            for line in f:
                line = line.strip()
                if not line: continue
                # format: HH:MM:SS description
                parts = line.split(' ', 1)
                if len(parts) == 2:
                    time_str, desc = parts
                    try:
                        # Parse time to get hours/min/sec. Date will be synthesized.
                        t = datetime.datetime.strptime(time_str, "%H:%M:%S")
                        events.append({"time": t, "desc": desc, "original": line})
                    except ValueError:
                        print(f"Skipping malformed line: {line}")
    except Exception as e:
        print(f"Error reading txt file: {e}")
    return events

def parse_btsnoop(log_filepath, events):
    print(f"--- Analyzing {os.path.basename(log_filepath)} ---")
    
    # BTSnoop starts at 2000-01-01 00:00:00 UTC
    BTSNOOP_EPOCH = datetime.datetime(2000, 1, 1, 0, 0, 0, tzinfo=datetime.timezone.utc)
    
    try:
        with open(log_filepath, "rb") as f:
            header = f.read(16)
            if len(header) < 16 or header[:8] != b'btsnoop\0':
                print("Invalid or missing btsnoop header")
                return

            version, datalink = struct.unpack(">II", header[8:16])
            print(f"Version: {version}, DataLink: {datalink}")

            packet_count = 0
            
            # We want to match events (which are just times) to the log.
            # The log has full timestamps. The txt only has HH:MM:SS.
            # We assume the log and txt resemble the same day.
            
            current_event_idx = 0
            
            while True:
                rec_header = f.read(24)
                if len(rec_header) < 24: break

                orig_len, inc_len, flags, drops, time_hi, time_lo = struct.unpack(">IIIIII", rec_header)
                
                packet_data = f.read(inc_len)
                if len(packet_data) < inc_len: break

                packet_count += 1
                
                # Calculate time
                # time is in microseconds since 2000-01-01
                ts_usec = (time_hi << 32) | time_lo
                # adjust for some weird btsnoop offset (0x00E03AB44A676000 is often subtracted in tools like wireshark to get to unix epoch, 
                # but standard btsnoop is just offset from 2000AD).
                # Actually, effectively it is microseconds from 2000-01-01 AD.
                
                dt = BTSNOOP_EPOCH + datetime.timedelta(microseconds=ts_usec)
                # Convert to local time (naive, but matching the user's probably local text file)
                # For simplicity, we just look at HH:MM:SS matching
                
                # To match correctly, we need to know the date of the log or assume it matches.
                # Let's just create a naive time from the log timestamp to compare
                
                # Local time adjustment (approximate, hardcoded +1 for CET or similar if needed, but let's just print UTC and see)
                # Actually user is in UTC+1 (CET).
                dt_local = dt.astimezone(datetime.timezone(datetime.timedelta(hours=1)))
                
                ts_str = dt_local.strftime("%H:%M:%S.%f")[:-3]
                
                # Check for events
                if current_event_idx < len(events):
                    ev = events[current_event_idx]
                    # We compare time components. 
                    # ev['time'] is a datetime object with dummy date (1900-01-01)
                    
                    log_hwh = dt_local.hour
                    log_min = dt_local.minute
                    log_sec = dt_local.second
                    
                    ev_hwh = ev['time'].hour
                    ev_min = ev['time'].minute
                    ev_sec = ev['time'].second
                    
                    # If log time >= event time (ignoring date), print event
                    curr_seconds = log_hwh*3600 + log_min*60 + log_sec
                    ev_seconds = ev_hwh*3600 + ev_min*60 + ev_sec
                    
                    if curr_seconds >= ev_seconds:
                        print(f"\n>>> EVENT: {ev['original']} <<<\n")
                        current_event_idx += 1

                # Filter for ATT logic similar to previous script
                # DataLink 1002 (HCI UART) -> Byte 0 is type
                hci_type = packet_data[0]
                
                if hci_type == 0x02: # ACL Data
                    # simple parsing
                    if len(packet_data) < 9: continue # Header(4) + L2CAP(4) + min 1
                    
                    l2cap_offset = 5
                    l2cap_len, l2cap_cid = struct.unpack("<HH", packet_data[l2cap_offset:l2cap_offset+4])
                    
                    if l2cap_cid == 0x0004: # ATT
                        att_data = packet_data[l2cap_offset+4:]
                        if not att_data: continue
                        
                        opcode = att_data[0]
                        opcode_name = ""
                        # 0x12: Write Req, 0x52: Write Cmd, 0x1B: Notify, 0x1D: Indicate, 0x0B: Read Resp
                        
                        if opcode == 0x12: opcode_name = "WR_REQ"
                        elif opcode == 0x52: opcode_name = "WR_CMD"
                        elif opcode == 0x1B: opcode_name = "NOTIFY"
                        elif opcode == 0x1D: opcode_name = "INDICATE"
                        elif opcode == 0x0B: opcode_name = "RD_RSP"
                        elif opcode == 0x01: opcode_name = "ERR_RSP"
                        elif opcode == 0x08: opcode_name = "RD_TYPE_RSP" # often UUIDs
                        elif opcode == 0x09: opcode_name = "RD_TYPE_REQ"
                        
                        if opcode_name:
                            handle = 0
                            val_hex = ""
                            extra_info = ""

                            if len(att_data) >= 3:
                                # For Read Type Req (0x09) -> Start Handle, End Handle, UUID
                                if opcode == 0x09:
                                    s_h, e_h = struct.unpack("<HH", att_data[1:5])
                                    uuid_part = att_data[5:]
                                    extra_info = f"Range: 0x{s_h:04X}-0x{e_h:04X} UUID: {uuid_part.hex()}"
                                
                                # Normal Handle based
                                elif opcode in [0x12, 0x52, 0x1B, 0x1D, 0x0B]:
                                    handle = struct.unpack("<H", att_data[1:3])[0]
                                    value = att_data[3:]
                                    val_hex = value.hex().upper()
                                    extra_info = f"Handle: 0x{handle:04X} Data: {val_hex}"
                                    
                                else:
                                    extra_info = att_data.hex()
                            
                            print(f"[{ts_str}] {opcode_name:<10} {extra_info}")

    except Exception as e:
        print(f"Error parsing log: {e}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python analyze_btSnifferSyncProcess.py <txt_file> <log_file>")
    else:
        events = parse_events(sys.argv[1])
        parse_btsnoop(sys.argv[2], events)
