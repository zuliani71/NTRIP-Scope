import 'dart:math';
import 'package:flutter/material.dart';
import 'rtcm.dart';

const signalColors = [
  Colors.blue,
  Colors.orange,
  Colors.green,
  Colors.purple,
  Colors.red,
  Colors.teal,
  Colors.indigo,
];

class CnrChart extends StatelessWidget {
  const CnrChart({super.key, required this.rows});
  final List<Observation> rows;
  @override
  Widget build(BuildContext context) {
    final signals = rows.map((r) => r.signal).toSet().toList()..sort();
    if (!rows.any((r) => r.cnr != null))
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'No C/N₀ measurements in this frame. Use an MSM4–MSM7 message.',
        ),
      );
    return Column(
      children: [
        const Text(
          'Carrier-to-noise density · per satellite and signal',
          textAlign: TextAlign.center,
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final slots = rows.map((r) => r.slot).toSet().length;
            final width = max(constraints.maxWidth, slots * 34.0 + 44);
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                height: 250,
                width: width,
                child: Semantics(
                  label: 'Signal C/N₀ by satellite in dB-Hz',
                  child: CustomPaint(painter: _CnrPainter(rows)),
                ),
              ),
            );
          },
        ),
        Wrap(
          spacing: 12,
          children: [
            for (var i = 0; i < signals.length; i++)
              Text(
                '● ${signals[i]}',
                style: TextStyle(color: signalColors[i % signalColors.length]),
              ),
          ],
        ),
      ],
    );
  }
}

class _CnrPainter extends CustomPainter {
  _CnrPainter(this.rows);
  final List<Observation> rows;
  void text(Canvas c, String value, Offset position, Color color) {
    final p = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(fontSize: 10, color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    p.paint(c, position);
  }

  @override
  void paint(Canvas c, Size size) {
    final slots = rows.map((r) => r.slot).toSet().toList()..sort();
    final signals = rows.map((r) => r.signal).toSet().toList()..sort();
    const left = 32.0, top = 22.0;
    final bottom = size.height - 25, width = size.width - left - 12;
    text(c, 'C/N₀ (dB-Hz)', const Offset(32, 2), Colors.black87);
    for (var level = 0; level <= 60; level += 10) {
      final y = bottom - level / 65 * (bottom - top);
      c.drawLine(
        Offset(left, y),
        Offset(size.width - 8, y),
        Paint()..color = Colors.grey.shade300,
      );
      text(c, '$level', Offset(4, y - 5), Colors.black87);
    }
    for (var i = 0; i < slots.length; i++) {
      final x = left + (i + 0.5) * width / slots.length;
      text(c, '${slots[i]}', Offset(x - 5, bottom + 6), Colors.black87);
    }
    for (final row in rows) {
      if (row.cnr == null) continue;
      final x =
          left +
          (slots.indexOf(row.slot) + 0.5) * width / slots.length +
          (signals.indexOf(row.signal) - (signals.length - 1) / 2) *
              min(3.0, 16 / max(1, signals.length));
      final y = bottom - row.cnr!.clamp(0, 65) / 65 * (bottom - top);
      c.drawCircle(
        Offset(x, y),
        3.5,
        Paint()
          ..color =
              signalColors[signals.indexOf(row.signal) % signalColors.length],
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CnrPainter old) => true;
}
