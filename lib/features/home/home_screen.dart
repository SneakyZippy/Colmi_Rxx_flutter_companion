import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/ble_service.dart';
import '../history/history_screen.dart';
import '../sensor/sensor_screen.dart';
import '../debug/debug_screen.dart';
import '../settings/settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    // Listen for connection changes to kick user to dashboard if disconnected
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ble = Provider.of<BleService>(context, listen: false);
      ble.addListener(_handleConnectionChange);
    });
  }

  @override
  void dispose() {
    final ble = Provider.of<BleService>(context, listen: false);
    ble.removeListener(_handleConnectionChange);
    super.dispose();
  }

  void _handleConnectionChange() {
    final ble = Provider.of<BleService>(context, listen: false);
    // If we lose connection and are not on the dashboard, kick back to dashboard
    if (!ble.isConnected && _selectedIndex != 0) {
      if (mounted) {
        setState(() {
          _selectedIndex = 0;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text("Connection lost. Returning to Dashboard.")),
        );
      }
    }
  }

  // Pages for Navigation
  // 0: Dashboard
  // 1: Measure
  // 2: History
  // 3: Debug
  // 4: Settings

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Pages List (Lazy load or keep alive?)
    // Keeping it simple with indexed stack or just switching widgets
    final List<Widget> pages = [
      const DashboardView(),
      const SensorScreen(),
      const HistoryScreen(),
      const DebugScreen(),
      const SettingsScreen(),
    ];

    return Scaffold(
      body: pages[_selectedIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: _onItemTapped,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.sensors),
            label: 'Measure',
          ),
          NavigationDestination(
            icon: Icon(Icons.history),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.bug_report),
            label: 'Debug',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class DashboardView extends StatelessWidget {
  const DashboardView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ringularity V0.0.4 Dashboard')),
      body: Consumer<BleService>(
        builder: (context, ble, child) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 1. Connection Header
                Card(
                  color: ble.isConnected ? Colors.green[100] : Colors.red[100],
                  child: ListTile(
                    leading: Icon(
                        ble.isConnected
                            ? Icons.bluetooth_connected
                            : Icons.bluetooth_disabled,
                        color: ble.isConnected
                            ? Colors.green[800]
                            : Colors.red[800]),
                    title: Text(ble.isConnected ? "Connected" : "Disconnected"),
                    subtitle: Text(ble.isConnected
                        ? "Battery: ${ble.batteryLevel}%"
                        : ble.status),
                    trailing: ble.isConnected
                        ? IconButton(
                            icon: const Icon(Icons.refresh),
                            onPressed: ble.getBatteryLevel)
                        : ElevatedButton(
                            onPressed: ble.isScanning ? null : ble.startScan,
                            child: Text(
                                ble.isScanning ? "Scanning..." : "Connect"),
                          ),
                  ),
                ),

                // Paired Devices
                if (!ble.isConnected && ble.bondedDevices.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  const Text("Paired Devices:",
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  Container(
                    height: 120, // Smaller height for paired
                    decoration: BoxDecoration(
                        border: Border.all(color: Colors.blueAccent),
                        borderRadius: BorderRadius.circular(8)),
                    child: ListView.builder(
                        itemCount: ble.bondedDevices.length,
                        itemBuilder: (ctx, i) {
                          final d = ble.bondedDevices[i];
                          return ListTile(
                            leading: const Icon(Icons.link, color: Colors.blue),
                            title: Text(d.platformName.isNotEmpty
                                ? d.platformName
                                : "Unknown Device"),
                            subtitle: Text(d.remoteId.toString()),
                            onTap: () => ble.connectToDevice(d),
                          );
                        }),
                  ),
                  const SizedBox(height: 10),
                ],

                // Scan Results (if not connected)
                if (!ble.isConnected && ble.scanResults.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  const Text("Devices Found:",
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  Container(
                    height: 150,
                    decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey),
                        borderRadius: BorderRadius.circular(8)),
                    child: ListView.builder(
                        itemCount: ble.scanResults.length,
                        itemBuilder: (ctx, i) {
                          final r = ble.scanResults[i];
                          String name = r.device.platformName.isNotEmpty
                              ? r.device.platformName
                              : r.advertisementData.advName;
                          if (name.isEmpty) name = "Unknown";
                          return ListTile(
                            title: Text(name),
                            subtitle: Text(r.device.remoteId.toString()),
                            onTap: () => ble.connectToDevice(r.device),
                          );
                        }),
                  )
                ],

                const SizedBox(height: 20),

                // 2. Metrics Grid
                if (ble.isConnected) ...[
                  GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 1.3,
                    children: [
                      _MetricCard(
                        title: "Heart Rate",
                        value: "${ble.heartRate}",
                        unit: "BPM",
                        icon: Icons.favorite,
                        color: Colors.red,
                        time: ble.heartRateTime,
                      ),
                      _MetricCard(
                        title: "SpO2",
                        value: "${ble.spo2}",
                        unit: "%",
                        icon: Icons.water_drop,
                        color: Colors.blue,
                        time: ble.spo2Time,
                      ),
                      _MetricCard(
                        title: "Stress",
                        value: "${ble.stress}",
                        unit: "Score", // 0-100
                        icon: Icons.psychology,
                        color: Colors.purple,
                        time: ble.stressTime,
                      ),
                      _MetricCard(
                        title: "HRV",
                        value: "${ble.hrv}",
                        unit: "ms",
                        icon: Icons.monitor_heart,
                        color: Colors.deepPurple,
                        time: ble.hrvTime,
                      ),
                      _MetricCard(
                        title: "Steps",
                        value: "${ble.steps}",
                        unit: "steps",
                        icon: Icons.directions_walk,
                        color: Colors.orange,
                        time: ble.stepsTime,
                      ),
                    ],
                  ),

                  const SizedBox(height: 20),

                  // 4. Main Action
                  SizedBox(
                    height: 50,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        ble.syncAllData();
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text("Syncing all data...")));
                      },
                      icon: const Icon(Icons.sync),
                      label: const Text("SYNC ALL DATA"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blueAccent,
                        foregroundColor: Colors.white,
                        textStyle: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
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

class _MetricCard extends StatelessWidget {
  final String title;
  final String value;
  final String unit;
  final IconData icon;
  final Color color;
  final String time;

  const _MetricCard({
    required this.title,
    required this.value,
    required this.unit,
    required this.icon,
    required this.color,
    required this.time,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Icon(icon, color: color),
                Text(time,
                    style: const TextStyle(fontSize: 10, color: Colors.grey)),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value,
                    style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        color: color)),
                Text("$title ($unit)",
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            )
          ],
        ),
      ),
    );
  }
}
