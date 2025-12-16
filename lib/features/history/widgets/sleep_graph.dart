import 'package:flutter/material.dart';
import '../../../services/ble_constants.dart';
import '../../../models/sleep_data.dart';

class SleepGraph extends StatelessWidget {
  final List<SleepData> data;

  const SleepGraph({Key? key, required this.data}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 200,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Sleep Stages",
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: data.isEmpty
                ? const Center(child: Text("No sleep data for this day"))
                : CustomPaint(
                    painter: _SleepGraphPainter(data),
                    size: Size.infinite,
                  ),
          ),
          const SizedBox(height: 8),
          // Legend
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildLegendItem(Colors.blue[200]!, "Light"),
              const SizedBox(width: 12),
              _buildLegendItem(Colors.indigo, "Deep"),
              const SizedBox(width: 12),
              _buildLegendItem(Colors.orange[300]!, "Awake"),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLegendItem(Color color, String label) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }
}

class _SleepGraphPainter extends CustomPainter {
  final List<SleepData> data;

  _SleepGraphPainter(this.data);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.isEmpty) return;

    final paint = Paint()
      ..strokeWidth = 2.0
      ..style = PaintingStyle.fill;

    // Time on X axis (00:00 to 24:00)
    // Stages on Y axis: (Top) Awake -> Light -> Deep (Bottom)

    double widthPerMin = size.width / (24 * 60);
    double height = size.height;

    // Y-Positions
    double yAwake = 0;
    double yLight = height * 0.5;
    double yDeep = height;

    // We draw rectangles for each block (15 mins)
    // Assuming data is sorted by time.

    for (int i = 0; i < data.length; i++) {
      final point = data[i];

      // Calculate X position
      int minutes = point.timestamp.hour * 60 + point.timestamp.minute;
      double x = minutes * widthPerMin;

      double blockWidth = point.durationMinutes * widthPerMin;
      // Fallback if Duration is 0 (shouldn't happen with new logic)
      if (blockWidth <= 0) blockWidth = 15 * widthPerMin;

      // Determine Color and Y Height
      Color color;
      double yTop;
      double yBottom; // We can draw bars from bottom or floating

      // Gadgetbridge: Light=2, Deep=3, Awake=5
      if (point.stage == BleConstants.sleepAwake) {
        // Awake
        color = Colors.orange[300]!;
        yTop = yAwake;
        yBottom = height * 0.3;
      } else if (point.stage == BleConstants.sleepLight) {
        // Light
        color = Colors.blue[200]!;
        yTop = yAwake;
        yBottom = yLight;
      } else if (point.stage == BleConstants.sleepDeep) {
        // Deep
        color = Colors.indigo;
        yTop = yAwake;
        yBottom = yDeep;
      } else {
        // Unknown
        color = Colors.grey;
        yTop = yAwake;
        yBottom = height * 0.1;
      }

      // Rect
      paint.color = color;
      // Rect from X to X+Width
      // Rect from Top to Bottom?
      // Let's draw "Bars" representing depth. Deep = Full height, Light = Half, Awake = Small.
      canvas.drawRect(Rect.fromLTWH(x, 0, blockWidth, yBottom), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
