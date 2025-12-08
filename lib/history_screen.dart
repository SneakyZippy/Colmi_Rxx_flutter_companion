import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'ble_service.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('History Graphs'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Steps'),
              Tab(text: 'Heart Rate'),
            ],
          ),
        ),
        body: Consumer<BleService>(
          builder: (context, ble, child) {
            return TabBarView(
              children: [_buildStepsChart(ble), _buildHrChart(ble)],
            );
          },
        ),
      ),
    );
  }

  Widget _buildStepsChart(BleService ble) {
    if (ble.stepsHistory.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              "Steps Today: ${ble.steps}",
              style: const TextStyle(fontSize: 20),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: () => ble.syncHistory(), // This requests steps
              child: const Text("Sync Steps History"),
            ),
          ],
        ),
      );
    }

    // Create spots
    List<BarChartGroupData> barGroups = [];
    for (int i = 0; i < ble.stepsHistory.length; i++) {
      final point = ble.stepsHistory[i];
      barGroups.add(
        BarChartGroupData(
          x: point.x,
          barRods: [
            BarChartRodData(toY: point.y.toDouble(), color: Colors.blue),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Text(
            "Total Steps: ${ble.steps}",
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          Expanded(
            child: BarChart(
              BarChartData(
                barGroups: barGroups,
                titlesData: FlTitlesData(
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: 5,
                      getTitlesWidget: (value, meta) {
                        // Heuristic: Assuming Steps Index represents 15-minute slots?
                        // If user sees 68, likely range is 0-96 (~24h / 15m)
                        int index = value.toInt();
                        int totalMinutes =
                            index * 15; // Trying 15 minute interval

                        int h = totalMinutes ~/ 60;
                        int m = totalMinutes % 60;

                        // Limit to 24h just in case
                        if (h >= 24) h = h % 24;

                        String text =
                            "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}";
                        return Padding(
                          padding: const EdgeInsets.only(top: 8.0),
                          child: Text(
                            text,
                            style: const TextStyle(fontSize: 10),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHrChart(BleService ble) {
    if (ble.hrHistory.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text("No HR History Data"),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: () => ble.syncHeartRateHistory(),
              child: const Text("Sync HR History"),
            ),
            const Padding(
              padding: EdgeInsets.all(8.0),
              child: Text("Note: Check Debug Log for packet confirmation"),
            ),
          ],
        ),
      );
    }

    // Create spots
    List<FlSpot> spots = [];
    for (int i = 0; i < ble.hrHistory.length; i++) {
      spots.add(FlSpot(i.toDouble(), ble.hrHistory[i].toDouble()));
    }

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: LineChart(
        LineChartData(
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: true,
              color: Colors.red,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: Colors.red.withOpacity(0.3),
              ),
            ),
          ],
          titlesData: FlTitlesData(
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: 12, // Show label every 1 hour (12 * 5min = 60min)
                getTitlesWidget: (value, meta) {
                  int index = value.toInt();
                  if (index < 0 || index >= 288) return const Text('');

                  int totalMinutes = index * 5;
                  int h = totalMinutes ~/ 60;
                  int m = totalMinutes % 60;
                  String text =
                      "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}";
                  return Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(text, style: const TextStyle(fontSize: 10)),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
