
import re

file_path = r"c:\FlutterProjects\Ringularity\Colmi_Rxx_flutter_companion\btSnifferLogsAndTimestamps\btSnifferSyncProcessAsText3.txt"

def analyze():
    print(f"Analyzing {file_path}...")
    try:
        with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()
    except Exception as e:
        print(f"Error reading file: {e}")
        return

    pattern = re.compile(r"Value:\s*([0-9a-fA-F]+)")
    
    found_bc = []
    found_7a = []
    found_any = []

    for i, line in enumerate(lines):
        match = pattern.search(line)
        if match:
            hex_val = match.group(1).lower()
            found_any.append((i+1, hex_val))
            
            if hex_val.startswith('bc27') or hex_val.startswith('bc'):
                found_bc.append((i+1, hex_val))
            elif hex_val.startswith('7a'):
                found_7a.append((i+1, hex_val))

    print(f"Total 'Value:' lines found: {len(found_any)}")
    
    print("\n--- BC Matches (BigData) ---")
    for ln, val in found_bc[:20]:
         print(f"Line {ln}: {val}")
    
    print("\n--- 7A Matches (Legacy Sleep) ---")
    for ln, val in found_7a[:20]:
         print(f"Line {ln}: {val}")

    if not found_bc and not found_7a:
        print("\n--- Sample of other Values ---")
        for ln, val in found_any[:20]:
             print(f"Line {ln}: {val}")

if __name__ == "__main__":
    analyze()
