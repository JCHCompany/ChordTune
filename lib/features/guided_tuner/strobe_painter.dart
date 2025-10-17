import 'dart:math' as math;
import 'package:flutter/material.dart';

class StrobePainter extends CustomPainter {
  final double? centOffset; // signed cents vs target (null means idle)
  final Color color;

  StrobePainter({required this.centOffset, this.color = Colors.greenAccent});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) * 0.45;
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..color = color.withOpacity(0.2)
      ..strokeWidth = 6;
    canvas.drawCircle(center, radius, ringPaint);

    // If no signal, draw faint idle ring
    if (centOffset == null) {
      return;
    }

    // Map cents to angular velocity; e.g., 100 cents = one full rotation/sec
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final revPerSec = (centOffset!.clamp(-100.0, 100.0)) / 100.0;
    final angle = 2 * math.pi * revPerSec * now;

    // Draw moving bright segment
    final segPaint = Paint()
      ..style = PaintingStyle.stroke
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 8;
    final sweep = math.pi / 10; // 18 degrees segment
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawArc(rect, angle, sweep, false, segPaint);
  }

  @override
  bool shouldRepaint(covariant StrobePainter oldDelegate) => oldDelegate.centOffset != centOffset || oldDelegate.color != color;
}
