import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'ble_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Local state for toggles.
  // Ideally, we'd read this from the device or persistent storage.
  // For now, default to false or try to infer?
  // Let's default to false as safe initial state.
  bool _hrAutoEnabled = false;
  bool _spo2AutoEnabled = false;
  bool _stressAutoEnabled = false;

  @override
  Widget build(BuildContext context) {
    final bleService = Provider.of<BleService>(context, listen: false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              "Automatic Health Monitoring",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          SwitchListTile(
            title: const Text("Heart Rate Monitoring"),
            subtitle: const Text("Automatically measures HR periodically."),
            value: _hrAutoEnabled,
            onChanged: (bool value) {
              setState(() {
                _hrAutoEnabled = value;
              });
              bleService.setHeartRateMonitoring(value);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                      "Heart Rate Monitoring ${value ? 'Enabled' : 'Disabled'}"),
                  duration: const Duration(milliseconds: 1000),
                ),
              );
            },
          ),
          const Divider(),
          SwitchListTile(
            title: const Text("SpO2 Monitoring"),
            subtitle: const Text("Automatically measures SpO2 periodically."),
            value: _spo2AutoEnabled,
            onChanged: (bool value) {
              setState(() {
                _spo2AutoEnabled = value;
              });
              bleService.setSpo2Monitoring(value);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content:
                      Text("SpO2 Monitoring ${value ? 'Enabled' : 'Disabled'}"),
                  duration: const Duration(milliseconds: 1000),
                ),
              );
            },
          ),
          const Divider(),
          SwitchListTile(
            title: const Text("Stress Monitoring"),
            subtitle: const Text("Starts periodic stress measurement."),
            value: _stressAutoEnabled,
            onChanged: (bool value) {
              setState(() {
                _stressAutoEnabled = value;
              });
              bleService.setStressMonitoring(value);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                      "Stress Monitoring ${value ? 'Enabled' : 'Disabled'}"),
                  duration: const Duration(milliseconds: 1000),
                ),
              );
            },
          ),
          const Divider(),
          ListTile(
            title: const Text("Pair Ring"),
            subtitle: const Text(
                "Sends Config & Bind commands to mirror original app pairing."),
            leading: const Icon(Icons.link),
            onTap: () async {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Starting Pairing Sequence...")),
              );
              await bleService.startPairing();
            },
          ),
          ListTile(
            title: const Text("Unpair Ring"),
            subtitle: const Text("Removes system bonding (forget device)."),
            leading: const Icon(Icons.link_off),
            onTap: () async {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Removing Bond...")),
              );
              await bleService.unpairRing();
            },
          ),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              "Note: Altering these settings sends commands directly to the ring. "
              "Changes might not persist after ring reboot.",
              style: TextStyle(color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}
