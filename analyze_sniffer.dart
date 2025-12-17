import 'dart:io';
import 'dart:convert';

void main() async {
  var file = File(
      r"c:\FlutterProjects\Ringularity\Colmi_Rxx_flutter_companion\btSnifferLogsAndTimestamps\btSnifferSyncProcessAsText3.txt");
  if (!await file.exists()) {
    print("File not found: ${file.path}");
    return;
  }

  print("Analyzing ${file.path}...");
  var lines = await file.readAsLines();

  var pattern = RegExp(r"Value:\s*([0-9a-fA-F]+)");

  List<String> foundBc = [];
  List<String> found7a = [];
  List<String> foundAny = [];

  for (int i = 0; i < lines.length; i++) {
    var match = pattern.firstMatch(lines[i]);
    if (match != null) {
      String hexVal = match.group(1)!.toLowerCase();
      String entry = "Line ${i + 1}: $hexVal";
      foundAny.add(entry);

      if (hexVal.startsWith('bc27') ||
          (hexVal.startsWith('bc') && hexVal.length > 2)) {
        foundBc.add(entry);
      } else if (hexVal.startsWith('7a')) {
        found7a.add(entry);
      }
    }
  }

  print("Total 'Value:' lines found: ${foundAny.length}");

  print("\n--- BC Matches (BigData) ---");
  for (var line in foundBc.take(20)) {
    print(line);
  }

  print("\n--- 7A Matches (Legacy Sleep) ---");
  for (var line in found7a.take(20)) {
    print(line);
  }

  if (foundBc.isEmpty && found7a.isEmpty) {
    print("\n--- Sample of other Values ---");
    for (var line in foundAny.take(20)) {
      print(line);
    }
  }
}
