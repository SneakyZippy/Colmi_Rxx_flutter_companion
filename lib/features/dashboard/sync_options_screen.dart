import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/ble_service.dart';

class SyncOptionsScreen extends StatelessWidget {
  const SyncOptionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Sync Options"),
      ),
      body: Consumer<BleService>(
        builder: (context, ble, child) {
          return ListView(
            padding: const EdgeInsets.all(16.0),
            children: [
              const Text(
                "Select data to sync individually:",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              _buildSyncButton(
                context,
                "Sync Steps",
                Icons.directions_walk,
                Colors.orange,
                () {
                  ble.syncStepsHistory();
                  _showSnackBar(context, "Syncing Steps...");
                },
                ble.isConnected,
              ),
              const SizedBox(height: 10),
              _buildSyncButton(
                context,
                "Sync Heart Rate",
                Icons.favorite,
                Colors.red,
                () {
                  ble.syncHeartRateHistory();
                  _showSnackBar(context, "Syncing Heart Rate...");
                },
                ble.isConnected,
              ),
              const SizedBox(height: 10),
              _buildSyncButton(
                context,
                "Sync SpO2",
                Icons.water_drop,
                Colors.blue,
                () {
                  ble.syncSpo2History();
                  _showSnackBar(context, "Syncing SpO2...");
                },
                ble.isConnected,
              ),
              const SizedBox(height: 10),
              _buildSyncButton(
                context,
                "Sync Sleep",
                Icons.bedtime,
                Colors.indigo,
                () {
                  ble.syncSleepHistory();
                  _showSnackBar(context, "Syncing Sleep...");
                },
                ble.isConnected,
              ),
              const SizedBox(height: 10),
              _buildSyncButton(
                context,
                "Sync Stress",
                Icons.psychology,
                Colors.purple,
                () {
                  ble.syncStressHistory();
                  _showSnackBar(context, "Syncing Stress...");
                },
                ble.isConnected,
              ),
              const SizedBox(height: 10),
              _buildSyncButton(
                context,
                "Sync HRV (Exp)",
                Icons.monitor_heart,
                Colors.deepPurple,
                () {
                  ble.syncHrvHistory();
                  _showSnackBar(context, "Syncing HRV...");
                },
                ble.isConnected,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSyncButton(BuildContext context, String label, IconData icon,
      Color color, VoidCallback onPressed, bool isConnected) {
    return SizedBox(
      height: 60,
      child: ElevatedButton.icon(
        onPressed: isConnected ? onPressed : null,
        icon: Icon(icon, color: Colors.white),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  void _showSnackBar(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
