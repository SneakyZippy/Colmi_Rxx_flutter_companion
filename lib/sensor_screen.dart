import 'dart:async';
import 'dart:math';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'ble_service.dart';

class SensorScreen extends StatefulWidget {
  const SensorScreen({super.key});

  @override
  State<SensorScreen> createState() => _SensorScreenState();
}

class _SensorScreenState extends State<SensorScreen> {
  final BleService _ble = BleService();
  StreamSubscription? _accelSub;
  StreamSubscription? _ppgSub;

  // Accelerometer Data
  int _accelX = 0;
  int _accelY = 0;
  int _accelZ = 0;

  // PPG/SpO2 Raw Data
  int _ppgRaw = 0;

  bool _isStreaming = false;

  // Gesture State
  double _netGforce = 0.0;
  double _scrollAngle = 0.0;
  String _gestureStatus = "Idle";
  Timer? _gestureResetTimer;

  // Graph Data
  final List<FlSpot> _spotsX = [];
  final List<FlSpot> _spotsY = [];
  final List<FlSpot> _spotsZ = [];
  double _timeCounter = 0;
  final int _maxDataPoints = 100;

  @override
  void initState() {
    super.initState();
    // Auto-start listening if you want, or wait for button.
    // Let's wait for button for safety.
  }

  void _startListening() {
    _accelSub = _ble.accelStream.listen((data) {
      if (data.length < 8) return;
      try {
        int idx = 2;

        // Parse 12-bit signed values
        int rawY = ((data[idx] << 4) | (data[idx + 1] & 0xf));
        if (rawY > 2047) rawY -= 4096;

        int rawZ = ((data[idx + 2] << 4) | (data[idx + 3] & 0xf));
        if (rawZ > 2047) rawZ -= 4096;

        int rawX = ((data[idx + 4] << 4) | (data[idx + 5] & 0xf));
        if (rawX > 2047) rawX -= 4096;

        // Gesture Logic (Ported from Colmi source)
        // netGforce = (sqrt(x^2 + y^2 + z^2) / 512 - 1.0).abs()
        double normX = rawX.toDouble();
        double normY = rawY.toDouble();
        double normZ = rawZ.toDouble();
        double magnitude = sqrt(normX * normX + normY * normY + normZ * normZ);
        double gForce = (magnitude / 512.0 - 1.0).abs();

        String status = _gestureStatus;
        double angle = _scrollAngle;

        if (gForce < 0.1) {
          // Stable / Rotation
          // Range -pi .. pi
          angle = atan2(normY, normX);
        } else if (gForce > 0.5) {
          // Impact / Tap (Threshold 0.2 might be too sensitive, tried 0.5)
          status = "Tap Detected!";
          _resetGestureLater();
        }

        if (mounted) {
          setState(() {
            _accelX = rawX;
            _accelY = rawY;
            _accelZ = rawZ;
            _netGforce = gForce;
            _scrollAngle = angle;
            _gestureStatus = status;

            // Update Graph
            _timeCounter++;
            _spotsX.add(FlSpot(_timeCounter, rawX.toDouble()));
            _spotsY.add(FlSpot(_timeCounter, rawY.toDouble()));
            _spotsZ.add(FlSpot(_timeCounter, rawZ.toDouble()));

            if (_spotsX.length > _maxDataPoints) {
              _spotsX.removeAt(0);
              _spotsY.removeAt(0);
              _spotsZ.removeAt(0);
            }
          });
        }
      } catch (e) {
        debugPrint("Error parsing accel: $e");
      }
    });

    _ppgSub = _ble.ppgStream.listen((data) {
      if (data.isEmpty) return;

      // Case 1: Raw Stream (0xA1 0x01 / 0xA1 0x02) - Old
      if (data[0] == 0xA1) {
        if (data.length < 4) return;
        int val = (data[2] << 8) | data[3];
        if (mounted) setState(() => _ppgRaw = val);
      }
      // Case 2: Green PPG Stream (0x69 0x08) - New Golden
      else if (data[0] == 0x69) {
        // Log Packet: 69 08 00 00 00 00 [10 03] ...
        // Index 6/7 seems to be the first sample.
        if (data.length >= 8) {
          int val = data[6] | (data[7] << 8); // Little Endian
          if (mounted) setState(() => _ppgRaw = val);
        }
      }
    });
  }

  void _stopListening() {
    _accelSub?.cancel();
    _ppgSub?.cancel();
    _accelSub = null;
    _ppgSub = null;
  }

  void _resetGestureLater() {
    _gestureResetTimer?.cancel();
    _gestureResetTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) {
        setState(() {
          _gestureStatus = "Idle";
        });
      }
    });
  }

  @override
  void dispose() {
    _stopListening();
    // Critical: Stop the ring from streaming (Fixes "lights won't stop")
    if (_isStreaming) {
      _ble.forceStopEverything();
    }
    _gestureResetTimer?.cancel();
    super.dispose();
  }

  void _toggleStream() {
    setState(() {
      _isStreaming = !_isStreaming;
    });
    if (_isStreaming) {
      _startListening();
      _ble.enableRawData();
    } else {
      _stopListening();
      _ble.disableRawData();
    }
  }

  Widget _buildTile({
    required String title,
    required IconData icon,
    required bool isActive,
    required Color activeColor,
    required VoidCallback onTap,
  }) {
    final color = isActive ? activeColor.withOpacity(0.1) : Colors.transparent;
    final borderColor = isActive ? activeColor : Colors.grey.withOpacity(0.3);
    final contentColor = isActive ? activeColor : Colors.grey;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor, width: 2),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 40, color: contentColor),
              const SizedBox(height: 10),
              Text(
                title,
                style:
                    TextStyle(fontWeight: FontWeight.bold, color: contentColor),
              ),
              if (isActive) ...[
                const SizedBox(height: 5),
                const Text("ACTIVE",
                    style: TextStyle(fontSize: 10, letterSpacing: 1.0))
              ]
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Wear Detection Heuristic
    bool onFinger =
        _ppgRaw > 2000; // Threshold can be tuned (Reference says 10k-13k?)

    return Scaffold(
      appBar: AppBar(title: const Text("Sensor Stream")),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton.icon(
              onPressed: _toggleStream,
              icon: Icon(_isStreaming ? Icons.stop : Icons.play_arrow),
              label: Text(_isStreaming ? "Stop Stream" : "Start Stream"),
              style: ElevatedButton.styleFrom(
                backgroundColor: _isStreaming ? Colors.redAccent : Colors.green,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 10),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      _ble.forceStopEverything();
                      if (_isStreaming) {
                        setState(() => _isStreaming = false);
                        _stopListening();
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange[800],
                      foregroundColor: Colors.white,
                    ),
                    child: const Text("STOP LIGHTS"),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      _ble.rebootRing();
                      // Also stop streaming to be safe
                      if (_isStreaming) {
                        setState(() => _isStreaming = false);
                        _stopListening();
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red[900],
                      foregroundColor: Colors.white,
                    ),
                    child: const Text("REBOOT"),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // Verified Sensors Header
            const Text("Verified Sensors (Golden)",
                style: TextStyle(fontWeight: FontWeight.bold)),
            const Divider(),

            // Live Metrics for feedback
            Consumer<BleService>(builder: (context, ble, child) {
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _MiniMetric(
                      label: "Stress",
                      value: "${ble.stress}",
                      color: Colors.purple),
                  _MiniMetric(
                      label: "SpO2", value: "${ble.spo2}%", color: Colors.blue),
                  _MiniMetric(
                      label: "HR",
                      value: "${ble.heartRate}",
                      color: Colors.red),
                  _MiniMetric(
                      label: "HRV", value: "${ble.hrv} ms", color: Colors.teal),
                ],
              );
            }),
            const SizedBox(height: 10),

            // New Controls (Golden)
            const Text("Verified Sensors (Golden)",
                style: TextStyle(fontWeight: FontWeight.bold)),
            const Divider(),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
              childAspectRatio: 1.3,
              children: [
                Consumer<BleService>(builder: (context, ble, child) {
                  return _buildTile(
                    title: "Live HR",
                    icon: Icons.favorite,
                    isActive: ble.isMeasuringHeartRate,
                    activeColor: Colors.red,
                    onTap: () {
                      if (!ble.isConnected) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text("Not connected to Ring")));
                        return;
                      }
                      if (ble.isMeasuringHeartRate)
                        ble.stopRealTimeHeartRate();
                      else
                        ble.startRealTimeHeartRate();
                    },
                  );
                }),
                Consumer<BleService>(builder: (context, ble, child) {
                  return _buildTile(
                    title: "Live SpO2",
                    icon: Icons.water_drop,
                    isActive: ble.isMeasuringSpo2,
                    activeColor: Colors.blue,
                    onTap: () {
                      if (!ble.isConnected) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text("Not connected to Ring")));
                        return;
                      }
                      if (ble.isMeasuringSpo2)
                        ble.stopRealTimeSpo2();
                      else
                        ble.startRealTimeSpo2();
                    },
                  );
                }),
                Consumer<BleService>(builder: (context, ble, child) {
                  return _buildTile(
                    title: "Live HRV",
                    icon: Icons.monitor_heart, // Different heart icon
                    isActive: ble.isMeasuringHrv,
                    activeColor: Colors.deepPurple,
                    onTap: () {
                      if (!ble.isConnected) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text("Not connected to Ring")));
                        return;
                      }
                      if (ble.isMeasuringHrv)
                        ble.stopRealTimeHrv();
                      else
                        ble.startRealTimeHrv();
                    },
                  );
                }),
                Consumer<BleService>(builder: (context, ble, child) {
                  return _buildTile(
                    title: "Stress Test",
                    icon: Icons.psychology,
                    isActive: ble.isMeasuringStress,
                    activeColor: Colors.purple,
                    onTap: () {
                      if (!ble.isConnected) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text("Not connected to Ring")));
                        return;
                      }
                      if (ble.isMeasuringStress)
                        ble.stopStressTest();
                      else
                        ble.startStressTest();
                    },
                  );
                }),
              ],
            ),
            const SizedBox(height: 10),
            const Text("Activity Controls (0x77)",
                style: TextStyle(fontWeight: FontWeight.bold)),
            const Divider(),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                Consumer<BleService>(builder: (context, ble, child) {
                  return ElevatedButton.icon(
                    onPressed: () =>
                        ble.setActivityState(0x04, 0x01), // Walk Start
                    icon: const Icon(Icons.directions_walk),
                    label: const Text("Start Walk"),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange),
                  );
                }),
                Consumer<BleService>(builder: (context, ble, child) {
                  return ElevatedButton.icon(
                    onPressed: () =>
                        ble.setActivityState(0x07, 0x01), // Run Start
                    icon: const Icon(Icons.directions_run),
                    label: const Text("Start Run"),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange),
                  );
                }),
                Consumer<BleService>(builder: (context, ble, child) {
                  return ElevatedButton.icon(
                    onPressed: () => ble.setActivityState(
                        0x04, 0x04), // End (Type 04 generic)
                    icon: const Icon(Icons.stop),
                    label: const Text("End Activity"),
                    style:
                        ElevatedButton.styleFrom(backgroundColor: Colors.grey),
                  );
                }),
              ],
            ),
            const SizedBox(height: 20),
            const SizedBox(height: 20),

            // Status Card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Column(
                      children: [
                        const Text("Wear Status",
                            style: TextStyle(color: Colors.grey)),
                        const SizedBox(height: 5),
                        Icon(onFinger ? Icons.fingerprint : Icons.back_hand,
                            color: onFinger ? Colors.green : Colors.orange,
                            size: 32),
                        const SizedBox(height: 5),
                        Text(onFinger ? "ON FINGER" : "OFF FINGER",
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color:
                                    onFinger ? Colors.green : Colors.orange)),
                        Text("PPG: $_ppgRaw",
                            style: const TextStyle(
                                fontSize: 10, color: Colors.grey)),
                      ],
                    ),
                    Column(
                      children: [
                        const Text("Rotation",
                            style: TextStyle(color: Colors.grey)),
                        const SizedBox(height: 5),
                        Container(
                          height: 50,
                          width: 50,
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.blueAccent),
                            shape: BoxShape.circle,
                          ),
                          child: Transform.rotate(
                            angle: _scrollAngle,
                            child: const Icon(Icons.navigation,
                                color: Colors.blueAccent),
                          ),
                        ),
                        Text(
                            "${(_scrollAngle * 180 / pi).toStringAsFixed(0)}°"),
                      ],
                    )
                  ],
                ),
              ),
            ),

            const SizedBox(height: 10),

            // Gesture Text
            Center(
              child: Text(
                _gestureStatus,
                style:
                    const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
            ),

            const Divider(),

            // Accel Graph
            SizedBox(
              height: 200,
              child: LineChart(
                LineChartData(
                  gridData: const FlGridData(show: false),
                  titlesData: const FlTitlesData(show: false),
                  borderData: FlBorderData(
                      show: true, border: Border.all(color: Colors.grey)),
                  minY: -2048,
                  maxY: 2048,
                  lineBarsData: [
                    LineChartBarData(
                        spots: _spotsX,
                        color: Colors.red,
                        dotData: const FlDotData(show: false),
                        barWidth: 2),
                    LineChartBarData(
                        spots: _spotsY,
                        color: Colors.green,
                        dotData: const FlDotData(show: false),
                        barWidth: 2),
                    LineChartBarData(
                        spots: _spotsZ,
                        color: Colors.blue,
                        dotData: const FlDotData(show: false),
                        barWidth: 2),
                  ],
                ),
              ),
            ),
            const Center(
                child: Text("X (Red), Y (Green), Z (Blue)",
                    style: TextStyle(color: Colors.grey))),

            const SizedBox(height: 20),
            _buildCard("Raw Values", [
              _buildRow("Accel X", _accelX),
              _buildRow("Accel Y", _accelY),
              _buildRow("Accel Z", _accelZ),
              _buildRow("G-Force", (_netGforce * 1000).toInt()),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(String title, List<Widget> children) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(title,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Divider(),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _buildRow(String label, int value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 16)),
          Text("$value",
              style: const TextStyle(fontSize: 18, fontFamily: 'Monospace')),
        ],
      ),
    );
  }
}

class _MiniMetric extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _MiniMetric(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold, color: color)),
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
      ],
    );
  }
}
