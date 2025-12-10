import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'ble_service.dart';

class DataDebugScreen extends StatelessWidget {
  const DataDebugScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Data Debugger"),
          bottom: const TabBar(
            isScrollable: true,
            tabs: [
              Tab(text: "Protocol Log"),
              Tab(text: "Steps Raw"),
              Tab(text: "HR Raw"),
              Tab(text: "SpO2 Raw"),
            ],
          ),
        ),
        body: Consumer<BleService>(
          builder: (context, ble, child) {
            return TabBarView(
              children: [
                _buildProtocolLog(ble, context),
                _buildStepsList(ble),
                _buildHrList(ble),
                _buildSpo2List(ble),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildStepsList(BleService ble) {
    if (ble.stepsHistory.isEmpty) {
      return const Center(child: Text("No steps data"));
    }
    return ListView.builder(
      itemCount: ble.stepsHistory.length,
      itemBuilder: (context, index) {
        final point = ble.stepsHistory[index];
        // Steps x is index (0-96)
        int totalMinutes = point.x.toInt() * 15;
        int h = totalMinutes ~/ 60;
        int m = totalMinutes % 60;
        String timeStr =
            "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}";

        return ListTile(
          dense: true,
          title: Text("Index: ${point.x} ($timeStr)"),
          trailing: Text("Steps: ${point.y}",
              style: const TextStyle(fontWeight: FontWeight.bold)),
        );
      },
    );
  }

  Widget _buildHrList(BleService ble) {
    if (ble.hrHistory.isEmpty) {
      return const Center(child: Text("No HR data"));
    }
    // Sort by time?
    List<dynamic> points = List.from(ble.hrHistory);
    // points is List<Point>

    return ListView.builder(
      itemCount: points.length,
      itemBuilder: (context, index) {
        final point = points[index];
        // HR x is minutes from midnight
        int totalMinutes = point.x.toInt();
        int h = totalMinutes ~/ 60;
        int m = totalMinutes % 60;
        String timeStr =
            "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}";

        return ListTile(
          dense: true,
          title: Text("Time: $timeStr (Min: ${point.x})"),
          trailing: Text("${point.y} BPM",
              style: const TextStyle(
                  color: Colors.red, fontWeight: FontWeight.bold)),
        );
      },
    );
  }

  Widget _buildSpo2List(BleService ble) {
    if (ble.spo2History.isEmpty) {
      return const Center(child: Text("No SpO2 data"));
    }
    List<dynamic> points = List.from(ble.spo2History);

    return ListView.builder(
      itemCount: points.length,
      itemBuilder: (context, index) {
        final point = points[index];
        // SpO2 x is minutes from midnight
        int totalMinutes = point.x.toInt();
        int h = totalMinutes ~/ 60;
        int m = totalMinutes % 60;
        String timeStr =
            "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}";

        return ListTile(
          dense: true,
          title: Text("Time: $timeStr (Min: ${point.x})"),
          trailing: Text("${point.y}%",
              style: const TextStyle(
                  color: Colors.blue, fontWeight: FontWeight.bold)),
        );
      },
    );
  }

  Widget _buildProtocolLog(BleService ble, BuildContext context) {
    if (ble.protocolLog.isEmpty) {
      return const Center(child: Text("No protocol logs yet"));
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: ElevatedButton.icon(
            onPressed: () {
              final text = ble.protocolLog.join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Logs copied to clipboard!")),
              );
            },
            icon: const Icon(Icons.copy),
            label: const Text("Copy Logs to Clipboard"),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: ble.protocolLog.length,
            itemBuilder: (context, index) {
              final entry = ble.protocolLog[ble.protocolLog.length - 1 - index];
              final isTx = entry.contains("TX:");
              return ListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                title: Text(
                  entry,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: isTx ? Colors.blue[800] : Colors.green[800],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
