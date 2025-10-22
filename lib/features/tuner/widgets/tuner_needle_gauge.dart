import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../app/app_theme.dart';

/// Semicircle tuner gauge with a pointed needle.
/// - Thin arc with ticks and -50 / +50 labels
/// - Needle always gold
/// - Cents value displayed at bottom (fixed position)
/// - When no pitch, shows mic with three-dot listening animation
class TunerNeedleGauge extends StatefulWidget {
  final double? cents; // null means no pitch
  final double size; // square size
  final bool showHalo; // subtle halo around labels/arc

  const TunerNeedleGauge({
    super.key,
    required this.cents,
    this.size = 240,
    this.showHalo = true,
  });

  @override
  State<TunerNeedleGauge> createState() => _TunerNeedleGaugeState();
}

class _TunerNeedleGaugeState extends State<TunerNeedleGauge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dotsCtrl;

  @override
  void initState() {
    super.initState();
    _dotsCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _dotsCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tunerTheme = Theme.of(context).extension<TunerTheme>();
    final gold = tunerTheme?.gold ?? Theme.of(context).colorScheme.secondary;
    final green = tunerTheme?.green ?? Colors.green;
    final red = tunerTheme?.red ?? Colors.red;
    final haloOpacity = tunerTheme?.haloOpacity ?? 0.12;

    final hasPitch = widget.cents != null;
    final cents = (widget.cents ?? 0).clamp(-50.0, 50.0);

    // Needle always stays gold
    final needleColor = gold;

    return SizedBox(
      width: widget.size,
      height: widget.size * 0.75, // more space for mic+dots at bottom
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(widget.size, widget.size * 0.75),
            painter: _GaugePainter(
              gold: gold,
              green: green,
              red: red,
              haloOpacity: haloOpacity,
              showHalo: widget.showHalo,
              showNeedle: hasPitch,
              cents: cents.toDouble(),
              needleColor: needleColor,
              showCentsValue: hasPitch,
            ),
          ),
          // Cents value at bottom - always reserve space to prevent layout shift
          Positioned(
            bottom: 20,
            child: SizedBox(
              height: 60,
              child: hasPitch
                  ? Text(
                      '${cents >= 0 ? '+' : ''}${cents.toInt()}¢',
                      style: TextStyle(
                        fontSize: 42,
                        fontWeight: FontWeight.bold,
                        color: gold,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
          // Mic + dots when no pitch (behind cents value)
          if (!hasPitch)
            Positioned(
              bottom: 20,
              child: _ListeningOverlay(
                color: gold,
                controller: _dotsCtrl,
              ),
            ),
        ],
      ),
    );
  }
}

class _ListeningOverlay extends StatelessWidget {
  final Color color;
  final AnimationController controller;
  const _ListeningOverlay({required this.color, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final phase = controller.value; // 0..1
        // Three dots animate scale in sequence
        double dotScale(int i) {
          final t = (phase + i / 3.0) % 1.0;
          return 0.6 + 0.4 * math.sin(t * math.pi);
        }

        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.mic_rounded, color: color, size: 28),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3.0),
                  child: Transform.scale(
                    scale: dotScale(i),
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: color.withOpacity(0.85),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                );
              }),
            ),
          ],
        );
      },
    );
  }
}

class _GaugePainter extends CustomPainter {
  final Color gold;
  final Color green;
  final Color red;
  final double haloOpacity;
  final bool showHalo;
  final bool showNeedle;
  final double cents; // -50..+50
  final Color needleColor;
  final bool showCentsValue;

  _GaugePainter({
    required this.gold,
    required this.green,
    required this.red,
    required this.haloOpacity,
    required this.showHalo,
    required this.showNeedle,
    required this.cents,
    required this.needleColor,
    required this.showCentsValue,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final cy = h * 0.7; // adjusted for mic+dots at bottom
    final radius = math.min(w * 0.45, h * 0.7);

    final arcRect = Rect.fromCircle(center: Offset(cx, cy), radius: radius);
    const startAngle = math.pi; // 180°
    const sweepAngle = math.pi; // 180°

    final bgPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = gold.withOpacity(0.8);

    // Arc base
    canvas.drawArc(arcRect, startAngle, sweepAngle, false, bgPaint);

    // Ticks every 10 cents, stronger at 0 and ±50
    for (int c = -50; c <= 50; c += 10) {
      final t = (c + 50) / 100.0; // 0..1
      final angle = startAngle + sweepAngle * t;
      final inner = Offset(
        cx + (radius - (c % 50 == 0 ? 12 : 8)) * math.cos(angle),
        cy + (radius - (c % 50 == 0 ? 12 : 8)) * math.sin(angle),
      );
      final outer = Offset(
        cx + radius * math.cos(angle),
        cy + radius * math.sin(angle),
      );
      final tp = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = (c % 50 == 0) ? 2.5 : 1.5
        ..color = gold.withOpacity((c % 50 == 0) ? 0.95 : 0.85);
      canvas.drawLine(inner, outer, tp);
    }

    // Labels: -50 and +50 next to the arc ends (no 0 label)
    final textPainter =
        (String text, Offset pos, {double align = 0.5, double fontSize = 14}) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: gold,
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            shadows: [
              Shadow(color: gold.withOpacity(haloOpacity), blurRadius: 1.5),
            ],
          ),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(minWidth: 0, maxWidth: 200);
      final dx = pos.dx - tp.width * align;
      final dy = pos.dy - tp.height / 2;
      tp.paint(canvas, Offset(dx, dy));
    };

    // Place -50 just left of the left endpoint, +50 just right of the right endpoint
    final leftEnd = Offset(cx - radius, cy);
    final rightEnd = Offset(cx + radius, cy);
    textPainter('-50', leftEnd.translate(-10, 0), align: 1.0);
    textPainter('+50', rightEnd.translate(10, 0), align: 0.0);

    // Needle
    if (showNeedle) {
      // Map cents to 180° arc: -50 -> 180°, 0 -> 90°, +50 -> 0°
      final t = (cents + 50) / 100.0; // 0..1
      final angle = startAngle + sweepAngle * t;

      // Needle geometry as a slightly tapered triangle, no tail beyond hub.
      final tipLen = radius * 0.88; // keep just shy of arc
      final baseWidth = 8.0; // slightly wider at base
      final tipWidth = 1.5; // slightly pointier tip

      final dir = Offset(math.cos(angle), math.sin(angle));
      final nrm = Offset(-math.sin(angle), math.cos(angle)); // left normal

      final center = Offset(cx, cy);
      final tip = center + dir * tipLen;
      final baseLeft = center + nrm * (baseWidth / 2);
      final baseRight = center - nrm * (baseWidth / 2);
      final tipLeft = tip + nrm * (tipWidth / 2);
      final tipRight = tip - nrm * (tipWidth / 2);

      final needlePath = Path()
        ..moveTo(baseLeft.dx, baseLeft.dy)
        ..lineTo(tipLeft.dx, tipLeft.dy)
        ..lineTo(tipRight.dx, tipRight.dy)
        ..lineTo(baseRight.dx, baseRight.dy)
        ..close();

      final needlePaint = Paint()
        ..style = PaintingStyle.fill
        ..color = needleColor.withOpacity(0.95);
      canvas.drawPath(needlePath, needlePaint);

      // Hub circle remains center; needle does not extend behind it
      final hubFill = Paint()
        ..style = PaintingStyle.fill
        ..color = needleColor.withOpacity(0.9);
      final hubHalo = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.0
        ..color = needleColor.withOpacity(0.2);
      canvas.drawCircle(center, 6.0, hubFill);
      canvas.drawCircle(center, 10.0, hubHalo);
    }
  }

  @override
  bool shouldRepaint(covariant _GaugePainter oldDelegate) {
    return oldDelegate.cents != cents ||
        oldDelegate.needleColor != needleColor ||
        oldDelegate.showNeedle != showNeedle ||
        oldDelegate.gold != gold ||
        oldDelegate.green != green ||
        oldDelegate.red != red ||
        oldDelegate.showHalo != showHalo ||
        oldDelegate.haloOpacity != haloOpacity ||
        oldDelegate.showCentsValue != showCentsValue;
  }
}
