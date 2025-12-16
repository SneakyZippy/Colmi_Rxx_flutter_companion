import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/ble_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  void initState() {
    super.initState();
    // Fetch latest settings from ring on open
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Provider.of<BleService>(context, listen: false).readAutoSettings();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Listen to changes
    final bleService = Provider.of<BleService>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              bleService.readAutoSettings();
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Reading Ring Settings...")));
            },
          )
        ],
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
          Column(
            children: [
              SwitchListTile(
                title: const Text("Heart Rate Monitoring"),
                subtitle: const Text("Enable automatic periodic measurement."),
                value: bleService.hrAutoEnabled,
                onChanged: (bool value) {
                  bleService
                      .setAutoHrInterval(value ? bleService.hrInterval : 0);
                },
              ),
              if (bleService.hrAutoEnabled)
                ListTile(
                  title: const Text("Measurement Interval"),
                  subtitle:
                      Text("Measure every ${bleService.hrInterval} minutes"),
                  trailing: DropdownButton<int>(
                    value: bleService.hrInterval,
                    items: [5, 10, 15, 30, 45, 60].map((int value) {
                      return DropdownMenuItem<int>(
                        value: value,
                        child: Text("$value min"),
                      );
                    }).toList(),
                    onChanged: (int? newValue) {
                      if (newValue != null) {
                        bleService.setAutoHrInterval(newValue);
                      }
                    },
                  ),
                ),
            ],
          ),
          const Divider(),
          SwitchListTile(
            title: const Text("SpO2 Monitoring"),
            subtitle: const Text("Automatically measures SpO2 periodically."),
            value: bleService.spo2AutoEnabled,
            onChanged: (bool value) {
              bleService.setAutoSpo2(value);
            },
          ),
          const Divider(),
          SwitchListTile(
            title: const Text("Stress Monitoring"),
            subtitle: const Text("Starts periodic stress measurement."),
            value: bleService.stressAutoEnabled,
            onChanged: (bool value) {
              bleService.setAutoStress(value);
            },
          ),
          const Divider(),
          SwitchListTile(
            title: const Text("HRV Monitoring (Experimental)"),
            subtitle: const Text("Enables Scheduled HRV (0x38)."),
            value: bleService.hrvAutoEnabled,
            onChanged: (bool value) {
              bleService.setAutoHrv(value);
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
          ListTile(
            title: const Text("Factory Reset"),
            subtitle: const Text("Resets ring to factory defaults (FF 66 66)."),
            leading: const Icon(Icons.restore),
            onTap: () async {
              bool confirm = await showDialog(
                      context: context,
                      builder: (c) => AlertDialog(
                              title: const Text("Confirm Reset"),
                              content: const Text(
                                  "This will reboot the ring and wipe settings. Continue?"),
                              actions: [
                                TextButton(
                                    onPressed: () => Navigator.pop(c, false),
                                    child: const Text("Cancel")),
                                TextButton(
                                    onPressed: () => Navigator.pop(c, true),
                                    child: const Text("Reset")),
                              ])) ??
                  false;

              if (confirm) {
                await bleService.factoryReset();
              }
            },
          ),
          ListTile(
            title: const Text("Reboot Ring"),
            subtitle:
                const Text("Restarts the ring (0x08). Fixes stuck sensors."),
            leading: const Icon(Icons.restart_alt),
            onTap: () async {
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Rebooting Ring...")));
              await bleService.rebootRing();
            },
          ),
          ListTile(
            title: const Text("Find Ring"),
            subtitle: const Text("Make the ring vibrate."),
            leading: const Icon(Icons.vibration),
            onTap: () async {
              ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("Sending Find command...")));
              await bleService.findDevice();
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
