import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'ble_service.dart';
import 'history_screen.dart';
import 'sensor_screen.dart';
import 'command_tester_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ringularity Version 1.0.1')),
      body: Consumer<BleService>(
        builder: (context, ble, child) {
          return Center(
            child: SingleChildScrollView(
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
                    // Use a Fixed Height for ListView when inside ScrollView
                    SizedBox(
                      height: 300,
                      child: ListView.builder(
                        physics:
                            const NeverScrollableScrollPhysics(), // Let layout scroll
                        shrinkWrap: true,
                        itemCount: ble.scanResults.length,
                        itemBuilder: (context, index) {
                          final result = ble.scanResults[index];
                          String name = result.device.platformName;
                          if (name.isEmpty) {
                            name = result.advertisementData.advName;
                          }
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
                      onPressed: ble.isMeasuringHeartRate
                          ? null // Disable while measuring
                          : () => ble.startHeartRate(),
                      icon: Icon(
                        ble.isMeasuringHeartRate
                            ? Icons.favorite
                            : Icons.favorite_border,
                      ),
                      label: Text(
                        ble.isMeasuringHeartRate
                            ? 'Measuring HR...'
                            : 'Measure Heart Rate',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: ble.isMeasuringHeartRate
                            ? Colors.red.shade100
                            : null,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Blood Oxygen',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    Text(
                      '${ble.spo2}%',
                      style: Theme.of(context).textTheme.displayLarge?.copyWith(
                            color: Colors.blue,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const SizedBox(height: 10),
                    ElevatedButton.icon(
                      onPressed: ble.isMeasuringSpo2
                          ? null // Disable while measuring
                          : () => ble.startSpo2(),
                      icon: Icon(
                        ble.isMeasuringSpo2
                            ? Icons.hourglass_top
                            : Icons.water_drop,
                      ),
                      label: Text(
                        ble.isMeasuringSpo2 ? 'Measuring...' : 'Measure SpO2',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            ble.isMeasuringSpo2 ? Colors.blue.shade100 : null,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ElevatedButton.icon(
                      onPressed:
                          (ble.isMeasuringHeartRate || ble.isMeasuringSpo2)
                              ? () => ble.stopAllMeasurements()
                              : null,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('STOP ALL MEASUREMENTS'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        foregroundColor: Colors.white,
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
                    const SizedBox(height: 10),
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (context) => const SensorScreen()),
                        );
                      },
                      icon: const Icon(Icons.sensors),
                      label: const Text('Sensor Data (Raw)'),
                    ),
                    const SizedBox(height: 20),
                    const Divider(),
                    const Text("Debug Tools"),
                    ElevatedButton(
                      onPressed: () =>
                          Provider.of<BleService>(context, listen: false)
                              .forceStopEverything(),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red[900],
                          foregroundColor: Colors.white),
                      child: const Text("FORCE STOP (Lights Off)"),
                    ),
                    const SizedBox(height: 10),
                    ElevatedButton(
                      onPressed: () =>
                          Provider.of<BleService>(context, listen: false)
                              .rebootRing(),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange[800],
                          foregroundColor: Colors.white),
                      child: const Text("REBOOT RING"),
                    ),
                    const SizedBox(height: 10),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (context) =>
                                  const CommandTesterScreen()),
                        );
                      },
                      child: const Text("Command Tester (Logs)"),
                    ),
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
            ),
          );
        },
      ),
    );
  }
}
