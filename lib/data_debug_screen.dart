import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'ble_service.dart';

class DataDebugScreen extends StatelessWidget {
  const DataDebugScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text("Data Debugger"),
          bottom: const TabBar(
            tabs: [
              Tab(text: "Steps Raw"),
              Tab(text: "HR Raw"),
            ],
          ),
        ),
        body: Consumer<BleService>(
          builder: (context, ble, child) {
            return TabBarView(
              children: [
                _buildStepsList(ble),
                _buildHrList(ble),
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
}
