import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'ble_service.dart';
import 'data_debug_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Consumer<BleService>(
            builder: (context, ble, child) {
              final dateStr =
                  "${ble.selectedDate.year}-${ble.selectedDate.month}-${ble.selectedDate.day}";
              return GestureDetector(
                onTap: () async {
                  final DateTime? picked = await showDatePicker(
                    context: context,
                    initialDate: ble.selectedDate,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now(),
                  );
                  if (picked != null && picked != ble.selectedDate) {
                    ble.setSelectedDate(picked);
                  }
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text("History: $dateStr"),
                    const SizedBox(width: 8),
                    const Icon(Icons.calendar_today, size: 20),
                  ],
                ),
              );
            },
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.list),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const DataDebugScreen(),
                  ),
                );
              },
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Steps'),
              Tab(text: 'Heart Rate'),
              Tab(text: 'SpO2'),
            ],
          ),
        ),
        body: Consumer<BleService>(
          builder: (context, ble, child) {
            return TabBarView(
              physics:
                  const NeverScrollableScrollPhysics(), // Disable tab swipe to avoid conflict with zoom
              children: [
                _StepsChartPage(ble: ble),
                _HrChartPage(ble: ble),
                _Spo2ChartPage(ble: ble),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _StepsChartPage extends StatefulWidget {
  final BleService ble;
  const _StepsChartPage({required this.ble});

  @override
  State<_StepsChartPage> createState() => _StepsChartPageState();
}

class _StepsChartPageState extends State<_StepsChartPage> {
  // Steps are 0-96 (15 min intervals)
  double _minX = 0;
  double _maxX = 96;
  bool _initializedZoom = false; // Add this
  double? _touchX; // 0.0 to 1.0 relative position

  void _onViewChange(double minX, double maxX) {
    setState(() {
      _minX = minX;
      _maxX = maxX;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ble = widget.ble;
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
              onPressed: () => ble.syncHistory(),
              child: const Text("Sync Steps History"),
            ),
          ],
        ),
      );
    }

    // Sort and calculate cumulative steps
    List<Point> sortedSteps = List.from(ble.stepsHistory);
    sortedSteps.sort((a, b) => a.x.compareTo(b.x));

    // Auto-Zoom Steps
    if (!_initializedZoom && sortedSteps.isNotEmpty) {
      double first = sortedSteps.first.x.toDouble();
      double last = sortedSteps.last.x.toDouble();
      // Relaxed Zoom: +/- 2 hours (8 units)
      _minX = (first - 8).clamp(0, 96);
      _maxX = (last + 8).clamp(0, 96);

      // Ensure at least 6 hours (24 units) visible if possible, centered
      if (_maxX - _minX < 24) {
        double center = (first + last) / 2;
        _minX = (center - 12).clamp(0, 96);
        _maxX = (center + 12).clamp(0, 96);
      }
      _initializedZoom = true;
    }

    List<FlSpot> spots = [];
    int currentTotal = 0;
    for (int i = 0; i < sortedSteps.length; i++) {
      final point = sortedSteps[i];
      currentTotal += point.y;
      spots.add(FlSpot(point.x.toDouble(), currentTotal.toDouble()));
    }

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Total Steps: ${ble.steps}",
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: "Reset Zoom",
                onPressed: () {
                  setState(() {
                    _minX = 0;
                    _maxX = 96;
                  });
                },
              ),
            ],
          ),
          Expanded(
            child: LayoutBuilder(builder: (context, constraints) {
              double chartHeight = constraints.maxHeight - 22;
              return Stack(
                children: [
                  _ZoomableChart(
                    minX: _minX,
                    maxX: _maxX,
                    maxLimit: 96,
                    onViewChange: _onViewChange,
                    onTouchUpdate: (relX) {
                      setState(() {
                        _touchX = relX;
                      });
                    },
                    onTouchEnd: () {
                      setState(() {
                        _touchX = null;
                      });
                    },
                    child: LineChart(
                      LineChartData(
                        minX: _minX,
                        maxX: _maxX,
                        minY: 0,
                        maxY: currentTotal.toDouble() * 1.1 + 100, // headroom
                        lineTouchData: LineTouchData(enabled: false),
                        lineBarsData: [
                          LineChartBarData(
                            spots: spots,
                            isCurved: true,
                            color: Colors
                                .blue, // Keep Blue for Steps to distinguish from HR? Or User said "same way"? "Show the same way" usually implies style. I'll stick to Blue consistency but Line style.
                            dotData: const FlDotData(show: false),
                            belowBarData: BarAreaData(
                              show: true,
                              color: Colors.blue.withValues(alpha: 0.3),
                            ),
                          ),
                        ],
                        titlesData: FlTitlesData(
                          leftTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
                          rightTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
                          topTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              interval: (_maxX - _minX) / 5, // Less labels
                              getTitlesWidget: (value, meta) {
                                int index = value.toInt();
                                if (index < _minX || index > _maxX)
                                  return Container();
                                int totalMinutes = index * 15;
                                int h = totalMinutes ~/ 60;
                                int m = totalMinutes % 60;
                                if (h >= 24) h = h % 24;
                                String text =
                                    "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}";
                                return Padding(
                                  padding: const EdgeInsets.only(top: 8.0),
                                  child: Text(text,
                                      style: const TextStyle(fontSize: 10)),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_touchX != null && spots.isNotEmpty)
                    Builder(
                      builder: (context) {
                        // 1. Calculations
                        double chartWidth = _maxX - _minX;
                        double touchValue = _minX + (_touchX! * chartWidth);

                        // Find nearest SPOT (Cumulative)
                        FlSpot nearestSpot = spots.first;
                        double minDist = 999999;
                        for (var spot in spots) {
                          double d = (spot.x - touchValue).abs();
                          if (d < minDist) {
                            minDist = d;
                            nearestSpot = spot;
                          }
                        }

                        // 2. Visual Dot Position
                        double maxY = currentTotal.toDouble() * 1.1 + 100;
                        double relativeY = nearestSpot.y / maxY;
                        double dotTop = (1.0 - relativeY) * chartHeight;

                        // Snap X to Nearest Spot
                        double relativeSpotX =
                            (nearestSpot.x - _minX) / (_maxX - _minX);
                        double dotLeft = relativeSpotX * constraints.maxWidth;

                        // Hide if out of bounds (zoomed in too far)
                        if (dotLeft < 0 || dotLeft > constraints.maxWidth) {
                          return const SizedBox();
                        }

                        int index = nearestSpot.x.toInt();
                        int totalMinutes = index * 15;
                        int h = totalMinutes ~/ 60;
                        int m = totalMinutes % 60;
                        String timeStr =
                            "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}";

                        return Stack(
                          children: [
                            // The Dot
                            Positioned(
                              left: dotLeft - 6,
                              top: dotTop - 6,
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: Colors.blue, width: 3),
                                    boxShadow: const [
                                      BoxShadow(
                                          blurRadius: 4, color: Colors.black26)
                                    ]),
                              ),
                            ),
                            // The Tooltip
                            Positioned(
                              left: dotLeft - 32,
                              top: 10,
                              child: IgnorePointer(
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.black87,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    "$timeStr\n${nearestSpot.y.toInt()} steps", // Shows cumulative
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 12),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                ],
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _HrChartPage extends StatefulWidget {
  final BleService ble;
  const _HrChartPage({required this.ble});

  @override
  State<_HrChartPage> createState() => _HrChartPageState();
}

class _HrChartPageState extends State<_HrChartPage> {
  // HR is 0-1440 (Minutes)
  double _minX = 0;
  double _maxX = 1440;
  bool _initializedZoom = false; // Add this
  double? _touchX;

  void _onViewChange(double minX, double maxX) {
    setState(() {
      _minX = minX;
      _maxX = maxX;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ble = widget.ble;
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

    List<FlSpot> spots = [];
    for (int i = 0; i < ble.hrHistory.length; i++) {
      final point = ble.hrHistory[i];
      spots.add(FlSpot(point.x.toDouble(), point.y.toDouble()));
    }
    spots.sort((a, b) => a.x.compareTo(b.x));

    // Auto-Zoom HR
    if (!_initializedZoom && spots.isNotEmpty) {
      double minX = spots.first.x;
      double maxX = spots.last.x;
      // Relaxed Zoom: +/- 2 hours (120 min)
      _minX = (minX - 120).clamp(0, 1440);
      _maxX = (maxX + 120).clamp(0, 1440);

      // Ensure at least 4 hours (240 min) visible
      if (_maxX - _minX < 240) {
        double center = (minX + maxX) / 2;
        _minX = (center - 120).clamp(0, 1440);
        _maxX = (center + 120).clamp(0, 1440);
      }
      _initializedZoom = true;
    }

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Heart Rate (BPM)",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: "Reset Zoom",
                onPressed: () {
                  setState(() {
                    _minX = 0;
                    _maxX = 1440;
                  });
                },
              ),
            ],
          ),
          Expanded(
            child: LayoutBuilder(builder: (context, constraints) {
              double chartHeight = constraints.maxHeight - 22;

              return Stack(
                children: [
                  _ZoomableChart(
                    minX: _minX,
                    maxX: _maxX,
                    maxLimit: 1440,
                    onViewChange: _onViewChange,
                    onTouchUpdate: (relX) {
                      setState(() {
                        _touchX = relX;
                      });
                    },
                    onTouchEnd: () {
                      setState(() {
                        _touchX = null;
                      });
                    },
                    child: LineChart(
                      LineChartData(
                        lineTouchData: LineTouchData(
                            enabled: false), // Disable to allow pure zoom
                        lineBarsData: [
                          LineChartBarData(
                            spots: spots,
                            isCurved: true,
                            color: Colors.red,
                            dotData: const FlDotData(show: false),
                            belowBarData: BarAreaData(
                              show: true,
                              color: Colors.red.withValues(alpha: 0.3),
                            ),
                          ),
                        ],
                        titlesData: FlTitlesData(
                          leftTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
                          rightTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
                          topTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 22,
                              interval: (_maxX - _minX) / 6,
                              getTitlesWidget: (value, meta) {
                                int minutesFromMidnight = value.toInt();
                                if (minutesFromMidnight < 0 ||
                                    minutesFromMidnight >= 1440) {
                                  return const Text('');
                                }
                                int h = minutesFromMidnight ~/ 60;
                                int m = minutesFromMidnight % 60;
                                String text =
                                    "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}";
                                return Padding(
                                  padding: const EdgeInsets.only(top: 8.0),
                                  child: Text(text,
                                      style: const TextStyle(fontSize: 10)),
                                );
                              },
                            ),
                          ),
                        ),
                        minX: _minX,
                        maxX: _maxX,
                        minY: 0,
                        maxY: 200,
                      ),
                    ),
                  ),
                  if (_touchX != null && spots.isNotEmpty) ...[
                    Builder(builder: (context) {
                      // 1. Calculations
                      double chartWidth = _maxX - _minX;
                      double touchValue = _minX + (_touchX! * chartWidth);

                      // Find nearest Point
                      FlSpot nearestSpot = spots.first;
                      double minDist = 999999;
                      for (var spot in spots) {
                        double d = (spot.x - touchValue).abs();
                        if (d < minDist) {
                          minDist = d;
                          nearestSpot = spot;
                        }
                      }

                      // 2. Visual Dot Position
                      // Y Ratio = (Y - MinY) / (MaxY - MinY)
                      // MinY = 0, MaxY = 200 (Hardcoded in LineChartData)
                      double relativeY = nearestSpot.y / 200.0;
                      if (relativeY > 1.0) relativeY = 1.0;
                      if (relativeY < 0.0) relativeY = 0.0;

                      double dotTop = (1.0 - relativeY) * chartHeight;

                      // Snap X to Nearest Spot
                      // Normalized X = (SpotX - MinX) / (MaxX - MinX)
                      double relativeSpotX =
                          (nearestSpot.x - _minX) / (_maxX - _minX);
                      double dotLeft = relativeSpotX * constraints.maxWidth;

                      // Hide if out of bounds
                      if (dotLeft < 0 || dotLeft > constraints.maxWidth) {
                        return const SizedBox();
                      }

                      int totalMinutes = nearestSpot.x.toInt();
                      int h = totalMinutes ~/ 60;
                      int m = totalMinutes % 60;
                      String timeStr =
                          "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}";

                      return Stack(
                        children: [
                          // The Dot
                          Positioned(
                            left: dotLeft - 6,
                            top: dotTop - 6,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  border:
                                      Border.all(color: Colors.red, width: 3),
                                  boxShadow: const [
                                    BoxShadow(
                                        blurRadius: 4, color: Colors.black26)
                                  ]),
                            ),
                          ),
                          // Tooltip
                          Positioned(
                            left: dotLeft - 32,
                            top: 10,
                            child: IgnorePointer(
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.black87,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  "$timeStr\n${nearestSpot.y.toInt()} bpm", // Shows cumulative
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 12),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    }),
                  ],
                ],
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _ZoomableChart extends StatefulWidget {
  final Widget child;
  final double minX;
  final double maxX;
  final double maxLimit;
  final Function(double, double) onViewChange;
  final Function(double)? onTouchUpdate;
  final Function()? onTouchEnd;

  const _ZoomableChart({
    required this.child,
    required this.minX,
    required this.maxX,
    required this.maxLimit,
    required this.onViewChange,
    this.onTouchUpdate,
    this.onTouchEnd,
  });

  @override
  State<_ZoomableChart> createState() => _ZoomableChartState();
}

class _ZoomableChartState extends State<_ZoomableChart> {
  // Snapshot of view state at start of gesture
  double? _startMinX;
  double? _startMaxX;

  // Normalized position of finger (0.0 to 1.0) on chart width
  double? _startNormFocalX;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onScaleStart: (details) {
        _startMinX = widget.minX;
        _startMaxX = widget.maxX;

        // Calculate normalized X position of the focal point (0.0 left, 1.0 right)
        final box = context.findRenderObject() as RenderBox;
        final localPoint = box.globalToLocal(details.focalPoint);
        _startNormFocalX = localPoint.dx / box.size.width;
      },
      onScaleUpdate: (ScaleUpdateDetails details) {
        final box = context.findRenderObject() as RenderBox;
        final localPoint = box.globalToLocal(details.focalPoint);
        final currentNormFocalX = localPoint.dx / box.size.width;

        // MODE 1: Inspection (1 Finger)
        // User wants to see value under finger without moving graph
        if (details.pointerCount == 1) {
          widget.onTouchUpdate?.call(currentNormFocalX);
          return; // Stop here, do not zoom/pan
        }

        // MODE 2: Navigation (2+ Fingers)
        // User wants to zoom/pan. Hide overlay.
        widget.onTouchEnd?.call();

        if (_startMinX == null ||
            _startMaxX == null ||
            _startNormFocalX == null) return;

        // 1. Calculate Target Range based on Scale
        // Scale > 1 means zooming IN (range gets smaller)
        double startRange = _startMaxX! - _startMinX!;
        double newRange = startRange / details.scale;

        // Clamp Range (Zoom Limits)
        if (newRange < widget.maxLimit * 0.05)
          newRange = widget.maxLimit * 0.05; // Max Zoom In
        if (newRange > widget.maxLimit)
          newRange = widget.maxLimit; // Max Zoom Out

        // 2. Calculate Shift based on Focal Point
        // The Data Point under the finger at start MUST remain under the finger now.
        // DataPoint = _startMinX + startRange * _startNormFocalX
        // NewMin = DataPoint - (newRange * currentNormFocalX)

        double dataPointAtFocal =
            _startMinX! + (startRange * _startNormFocalX!);
        double newMin = dataPointAtFocal - (newRange * currentNormFocalX);
        double newMax = newMin + newRange;

        // 3. Clamp Bounds (don't scroll past edges)
        if (newMin < 0) {
          newMin = 0;
          newMax = newRange;
        }
        if (newMax > widget.maxLimit) {
          newMax = widget.maxLimit;
          newMin = widget.maxLimit - newRange;
        }

        if (newMax > widget.maxLimit) {
          newMax = widget.maxLimit;
          newMin = widget.maxLimit - newRange;
        }

        widget.onViewChange(newMin, newMax);
      },
      onScaleEnd: (details) {
        widget.onTouchEnd?.call();
      },
      child: widget.child,
    );
  }
}

class _Spo2ChartPage extends StatefulWidget {
  final BleService ble;
  const _Spo2ChartPage({required this.ble});

  @override
  State<_Spo2ChartPage> createState() => _Spo2ChartPageState();
}

class _Spo2ChartPageState extends State<_Spo2ChartPage> {
  // SpO2 is 0-1440 (Minutes)
  double _minX = 0;
  double _maxX = 1440;
  bool _initializedZoom = false; // Add this
  double? _touchX;

  void _onViewChange(double minX, double maxX) {
    setState(() {
      _minX = minX;
      _maxX = maxX;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ble = widget.ble;
    if (ble.spo2History.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text("No SpO2 History Data"),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: () => ble.syncSpo2History(),
              child: const Text("Sync SpO2 History"),
            ),
            const Padding(
              padding: EdgeInsets.all(8.0),
              child: Text("Note: Experimental (0x16)"),
            ),
          ],
        ),
      );
    }

    List<FlSpot> spots = [];
    for (int i = 0; i < ble.spo2History.length; i++) {
      final point = ble.spo2History[i];
      spots.add(FlSpot(point.x.toDouble(), point.y.toDouble()));
    }
    spots.sort((a, b) => a.x.compareTo(b.x));

    // Auto-Zoom SpO2
    if (!_initializedZoom && spots.isNotEmpty) {
      double minX = spots.first.x;
      double maxX = spots.last.x;
      // Relaxed Zoom: +/- 2 hours (120 min)
      _minX = (minX - 120).clamp(0, 1440);
      _maxX = (maxX + 120).clamp(0, 1440);

      // Ensure at least 4 hours (240 min) visible
      if (_maxX - _minX < 240) {
        double center = (minX + maxX) / 2;
        _minX = (center - 120).clamp(0, 1440);
        _maxX = (center + 120).clamp(0, 1440);
      }
      _initializedZoom = true;
    }

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Blood Oxygen (%)",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: "Reset Zoom",
                onPressed: () {
                  setState(() {
                    _minX = 0;
                    _maxX = 1440;
                  });
                },
              ),
            ],
          ),
          Expanded(
            child: LayoutBuilder(builder: (context, constraints) {
              double chartHeight = constraints.maxHeight - 22;

              return Stack(
                children: [
                  _ZoomableChart(
                    minX: _minX,
                    maxX: _maxX,
                    maxLimit: 1440,
                    onViewChange: _onViewChange,
                    onTouchUpdate: (relX) {
                      setState(() {
                        _touchX = relX;
                      });
                    },
                    onTouchEnd: () {
                      setState(() {
                        _touchX = null;
                      });
                    },
                    child: LineChart(
                      LineChartData(
                        lineTouchData: LineTouchData(
                            enabled: false), // Disable to allow pure zoom
                        lineBarsData: [
                          LineChartBarData(
                            spots: spots,
                            isCurved: true,
                            color: Colors.cyan,
                            dotData: const FlDotData(show: false),
                            belowBarData: BarAreaData(
                              show: true,
                              color: Colors.cyan.withValues(alpha: 0.3),
                            ),
                          ),
                        ],
                        titlesData: FlTitlesData(
                          leftTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
                          rightTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
                          topTitles: const AxisTitles(
                              sideTitles: SideTitles(showTitles: false)),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 22,
                              interval: (_maxX - _minX) / 6,
                              getTitlesWidget: (value, meta) {
                                int minutesFromMidnight = value.toInt();
                                if (minutesFromMidnight < 0 ||
                                    minutesFromMidnight >= 1440) {
                                  return const Text('');
                                }
                                int h = minutesFromMidnight ~/ 60;
                                int m = minutesFromMidnight % 60;
                                String text =
                                    "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}";
                                return Padding(
                                  padding: const EdgeInsets.only(top: 8.0),
                                  child: Text(text,
                                      style: const TextStyle(fontSize: 10)),
                                );
                              },
                            ),
                          ),
                        ),
                        minX: _minX,
                        maxX: _maxX,
                        minY: 70, // SpO2 usually doesn't go below 70 alive
                        maxY: 105,
                      ),
                    ),
                  ),
                  if (_touchX != null && spots.isNotEmpty) ...[
                    Builder(builder: (context) {
                      // 1. Calculations
                      double chartWidth = _maxX - _minX;
                      double touchValue = _minX + (_touchX! * chartWidth);

                      // Find nearest Point
                      FlSpot nearestSpot = spots.first;
                      double minDist = 999999;
                      for (var spot in spots) {
                        double d = (spot.x - touchValue).abs();
                        if (d < minDist) {
                          minDist = d;
                          nearestSpot = spot;
                        }
                      }

                      // 2. Visual Dot Position
                      // Y Ratio = (Y - MinY) / (MaxY - MinY)
                      // MinY = 70, MaxY = 105
                      double relativeY = (nearestSpot.y - 70) / (105 - 70);
                      if (relativeY > 1.0) relativeY = 1.0;
                      if (relativeY < 0.0) relativeY = 0.0;

                      double dotTop = (1.0 - relativeY) * chartHeight;

                      // Snap X to Nearest Spot
                      // Normalized X = (SpotX - MinX) / (MaxX - MinX)
                      double relativeSpotX =
                          (nearestSpot.x - _minX) / (_maxX - _minX);
                      double dotLeft = relativeSpotX * constraints.maxWidth;

                      // Hide if out of bounds
                      if (dotLeft < 0 || dotLeft > constraints.maxWidth) {
                        return const SizedBox();
                      }

                      int totalMinutes = nearestSpot.x.toInt();
                      int h = totalMinutes ~/ 60;
                      int m = totalMinutes % 60;
                      String timeStr =
                          "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}";

                      return Stack(
                        children: [
                          // The Dot
                          Positioned(
                            left: dotLeft - 6,
                            top: dotTop - 6,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  border:
                                      Border.all(color: Colors.cyan, width: 3),
                                  boxShadow: const [
                                    BoxShadow(
                                        blurRadius: 4, color: Colors.black26)
                                  ]),
                            ),
                          ),
                          // Tooltip
                          Positioned(
                            left: dotLeft - 32,
                            top: 10,
                            child: IgnorePointer(
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.black87,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  "$timeStr\n${nearestSpot.y.toInt()}%", // Shows cumulative
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 12),
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    }),
                  ],
                ],
              );
            }),
          ),
        ],
      ),
    );
  }
}
