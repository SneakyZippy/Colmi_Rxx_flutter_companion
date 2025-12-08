import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'ble_service.dart';
import 'history_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Colmi R12 Monitor')),
      body: Consumer<BleService>(
        builder: (context, ble, child) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'Status: ${ble.status}',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                if (!ble.isConnected) ...[
                  ElevatedButton(
                    onPressed: ble.isScanning ? null : () => ble.startScan(),
                    child: Text(
                      ble.isScanning ? 'Scanning...' : 'Scan Devices',
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: ble.scanResults.length,
                      itemBuilder: (context, index) {
                        final result = ble.scanResults[index];
                        String name = result.device.platformName;
                        if (name.isEmpty)
                          name = result.advertisementData.localName;
                        if (name.isEmpty) name = "Unknown Device";

                        return ListTile(
                          title: Text(name),
                          subtitle: Text(result.device.remoteId.toString()),
                          trailing: const Icon(Icons.bluetooth),
                          onTap: () {
                            ble.connectToDevice(result.device);
                          },
                        );
                      },
                    ),
                  ),
                ],
                if (ble.isConnected) ...[
                  const SizedBox(height: 20),
                  Text(
                    'Heart Rate',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  Text(
                    '${ble.heartRate} BPM',
                    style: Theme.of(context).textTheme.displayLarge?.copyWith(
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Steps: ${ble.steps}',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    onPressed: () {
                      if (ble.isMeasuringHeartRate) {
                        ble.stopHeartRate();
                      } else {
                        ble.startHeartRate();
                      }
                    },
                    icon: Icon(
                      ble.isMeasuringHeartRate ? Icons.stop : Icons.favorite,
                    ),
                    label: Text(
                      ble.isMeasuringHeartRate
                          ? 'Stop Live HR'
                          : 'Start Live HR',
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ble.isMeasuringHeartRate
                          ? Colors.red.shade100
                          : null,
                    ),
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton.icon(
                    onPressed: () {
                      ble.syncAllData();
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Syncing all data...')),
                      );
                    },
                    icon: const Icon(Icons.sync),
                    label: const Text('Sync All Data'),
                  ),
                  const SizedBox(height: 20),
                  const SizedBox(height: 20),
                  const Divider(),

                  // Battery Section
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.battery_std),
                      const SizedBox(width: 8),
                      Text(
                        'Battery: ${ble.batteryLevel}%',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(width: 10),
                      IconButton(
                        icon: const Icon(Icons.refresh),
                        onPressed: () => ble.getBatteryLevel(),
                        tooltip: "Refresh Battery",
                      ),
                    ],
                  ),

                  const SizedBox(height: 10),
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const HistoryScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.show_chart),
                    label: const Text('View History Graphs'),
                  ),

                  const SizedBox(height: 20),
                  const Divider(),
                  const Text("Debug Log (Last Packet):"),
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Text(
                      ble.lastLog,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
