import 'package:flutter/material.dart';
import '../../../app/app_theme.dart';

/// Horizontal tuning bar with ticks every 2 cents from -50 to +50
/// - Shows a colored marker at current cents position
/// - Uses TunerTheme colors for green/red; amber via Colors.amber
class TunerFlatBar extends StatelessWidget {
  final double? cents; // null = no lock
  final double width;
  final double height;

  const TunerFlatBar({
    super.key,
    required this.cents,
    required this.width,
    this.height = 80,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tTheme = theme.extension<TunerTheme>();
    final trackColor = theme.colorScheme.onSurface.withOpacity(0.2);

    return SizedBox(
      width: width,
      height: height,
      child: CustomPaint(
        painter: _FlatBarPainter(
          cents: cents,
          trackColor: trackColor,
          green: tTheme?.green ?? Colors.green,
          red: tTheme?.red ?? Colors.red,
        ),
      ),
    );
  }
}

class _FlatBarPainter extends CustomPainter {
  final double? cents;
  final Color trackColor;
  final Color green;
  final Color red;
  _FlatBarPainter({
    required this.cents,
    required this.trackColor,
    required this.green,
    required this.red,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final centerY = h * 0.5;

    // Draw base track
    final trackPaint = Paint()
      ..color = trackColor
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 8.0;
    canvas.drawLine(Offset(0, centerY), Offset(w, centerY), trackPaint);

    // Draw tick marks every 2 cents, larger at 10, largest at 0
    final tickPaint = Paint()
      ..color = trackColor.withOpacity(0.9)
      ..strokeWidth = 2.0;
    const minC = -50;
    const maxC = 50;
    final totalSpan = (maxC - minC).toDouble();
    for (int c = minC; c <= maxC; c += 2) {
      final x = ((c - minC) / totalSpan) * w;
      double tickH = 10;
      if (c % 10 == 0) tickH = 16;
      if (c == 0) tickH = 22;
      canvas.drawLine(
        Offset(x, centerY - tickH / 2),
        Offset(x, centerY + tickH / 2),
        tickPaint,
      );
    }

    // Zone overlays (optional subtle highlight): green around ±5, amber ±5..10
    final greenPaint = Paint()
      ..color = green.withOpacity(0.14)
      ..style = PaintingStyle.fill;
    final amberPaint = Paint()
      ..color = Colors.amber.withOpacity(0.10)
      ..style = PaintingStyle.fill;
    final barHeight = 12.0;
    final rectY = centerY - barHeight / 2;
    double xFromC(double c) => ((c - minC) / totalSpan) * w;
    // Amber band ±10
    canvas.drawRect(
      Rect.fromLTWH(xFromC(-10), rectY, xFromC(10) - xFromC(-10), barHeight),
      amberPaint,
    );
    // Green band ±5
    canvas.drawRect(
      Rect.fromLTWH(xFromC(-5), rectY, xFromC(5) - xFromC(-5), barHeight),
      greenPaint,
    );

    // Draw marker
    if (cents != null) {
      final cClamped = cents!.clamp(minC.toDouble(), maxC.toDouble());
      final x = ((cClamped - minC) / totalSpan) * w;

      // Choose marker color by zone
      Color markerColor;
      final absC = cClamped.abs();
      if (absC <= 5.0) {
        markerColor = green;
      } else if (absC <= 10.0) {
        markerColor = Colors.amber.shade700;
      } else {
        markerColor = red;
      }

      final markerPaint = Paint()
        ..color = markerColor
        ..strokeWidth = 4.0
        ..strokeCap = StrokeCap.round;
      // Vertical marker
      canvas.drawLine(
        Offset(x, centerY - 26),
        Offset(x, centerY + 26),
        markerPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _FlatBarPainter old) {
    return old.cents != cents;
  }
}
