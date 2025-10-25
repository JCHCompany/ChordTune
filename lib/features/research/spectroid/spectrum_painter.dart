import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

// Debug counter for periodic logs in painter
int spectrumPainterDebugCounter = 0;

class SpectrumPainter extends CustomPainter {
  final Float32List magLinear; // linear power data (PSD or integrated bands)
  final int fs;
  final int fMax;
  final double emaAlphaAmp;
  final double peakFreqHz;
  final bool showGrid;
  final String displayUnit; // "dBFS" or "dB/Hz"
  final bool spectroidMode;
  // Pitch overlay
  final double? f0Tracked;
  final double? overlayCentsBand;
  final String? trackerState;
  // Noise detection visualization
  final double noiseFloorMeanDb; // Niveau de référence
  final List<dynamic> excludedPeaks; // Pics exclus (cadres jaunes)
  final Float32List? noiseFloorCurve; // Courbe verte bin par bin

  SpectrumPainter({
    required this.magLinear,
    required this.fs,
    required this.fMax,
    required this.emaAlphaAmp,
    required this.peakFreqHz,
    this.showGrid = true,
    this.displayUnit = "dB/Hz",
    this.spectroidMode = false,
    this.f0Tracked,
    this.overlayCentsBand,
    this.trackerState,
    this.noiseFloorMeanDb = 0.0,
    this.excludedPeaks = const [],
    this.noiseFloorCurve,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (magLinear.isEmpty) return;

    final nyquist = fs / 2.0;
    final fHi = math.min(fMax.toDouble(), nyquist);
    // Start slightly below 10 Hz so that the 10 Hz tick appears clearly inside
    final fLo = 8.0;
    final binHz = nyquist / magLinear.length;

    // Precompute dB values and stats (PSD: use 10*log10)
    final valuesDb = Float32List(magLinear.length);
    double maxDb = -1e9;
    double minDb = 1e9;
    for (int i = 0; i < magLinear.length; i++) {
      final v = 10 * math.log(magLinear[i] + 1e-20) / math.ln10;
      valuesDb[i] = v;
      if (v > maxDb) maxDb = v;
      if (v < minDb) minDb = v;
    }

    // Debug spectrum levels occasionally
    if (++spectrumPainterDebugCounter % 180 == 0) {
      // ~every 3s at ~60fps
      debugPrint(
          'Spectrum levels (10*log10): min=${minDb.toStringAsFixed(1)}$displayUnit, max=${maxDb.toStringAsFixed(1)}$displayUnit, range=${(maxDb - minDb).toStringAsFixed(1)}dB, fs=${fs}Hz, bins=${magLinear.length}');
    }

    // Use absolute dB scale: 0 dB (top) to -140 dB (bottom)
    const dbTop = 0.0;
    const dbBottom = -140.0;
    // Map log frequency to x with compressed 0–10 Hz decade (50% of other decades)
    // Piecewise mapping:
    // - [0,10) Hz uses normalized log10(f+1) so 0 is defined; this decade width is scaled by 0.5
    // - [10, fHi] uses classic log10(f)
    double log10p1(double x) => math.log(x + 1.0) / math.ln10;
    double log10(double x) => math.log(x) / math.ln10;
    // Note: start axis mapping from 0 Hz implicitly (see freqToT)
    final double decade0Width = 0.5; // 50% width for 0–10 Hz
    // Total width in "decades" units
    final double normalDecades = (log10(fHi) - log10(10.0));
    final double totalUnits = decade0Width + normalDecades;

    double freqToT(double f) {
      if (f <= 0) return 0.0;
      if (f < 10.0) {
        // 0..10 Hz portion compressed to 0.5 units
        final u = log10p1(f) / log10p1(10.0); // in [0,1]
        return (u * decade0Width) / totalUnits;
      } else {
        // Remaining portion in normal decades
        final u = (log10(f) - log10(10.0)); // in [0, normalDecades]
        return (decade0Width + u) / totalUnits;
      }
    }

    // Choose color/style depending on mode
    final Color traceColor = spectroidMode ? Colors.greenAccent : Colors.white;

    if (spectroidMode) {
      // Draw integrated bands as lines at top level (Spectroid-like, no fill)
      final bands = _generateFrequencyBands(fs);
      // Number of drawable bands within fHi
      int maxBandIndex = 0;
      for (int i = 0; i + 1 < bands.length; i++) {
        if (bands[i + 1] <= fHi) {
          maxBandIndex = i + 1;
        } else {
          break;
        }
      }
      final int nBars = math.min(magLinear.length, math.max(0, maxBandIndex));
      final Paint linePaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = traceColor;

      // Create path for continuous line at spectrum level
      final path = Path();
      bool isFirstPoint = true;

      for (int i = 0; i < nBars; i++) {
        final f0 = bands[i];
        final f1 = bands[i + 1];
        if (f1 <= 0 || f0 >= fHi) continue;

        final fCenter = (f0 + f1) / 2.0; // Use band center for plotting
        final t = freqToT(fCenter.clamp(0.0, fHi));
        final x = (t * size.width).toDouble();
        final v = valuesDb[i].clamp(dbBottom, dbTop).toDouble();
        final y = size.height * ((dbTop - v) / (dbTop - dbBottom));

        if (isFirstPoint) {
          path.moveTo(x, y);
          isFirstPoint = false;
        } else {
          path.lineTo(x, y);
        }
      }

      canvas.drawPath(path, linePaint);
    } else {
      // Draw continuous PSD trace
      final path = Path();
      final steps = size.width.isFinite ? size.width.floor() : 300;
      for (int i = 0; i < steps; i++) {
        final t = steps == 1 ? 0.0 : i / (steps - 1);
        // invert mapping numerically: sample t uniformly then find f by solving freqToT(f)=t
        // For efficiency, approximate inverse by splitting piecewise
        double f;
        final boundary = decade0Width / totalUnits; // t at 10 Hz
        if (t <= boundary) {
          // 0..10 Hz branch
          final u = (t * totalUnits) / decade0Width; // in [0,1]
          f = math.pow(10.0, u * log10p1(10.0)).toDouble() - 1.0;
          f = f.clamp(0.0, fHi);
        } else {
          // >= 10 Hz branch
          final u = t * totalUnits - decade0Width; // in [0, normalDecades]
          f = math.pow(10.0, log10(10.0) + u).toDouble();
          f = f.clamp(10.0, fHi);
        }
        final k = (f / binHz).clamp(0, magLinear.length - 1).toInt();
        final v = valuesDb[k].clamp(dbBottom, dbTop).toDouble();
        // y: 0 dB at top, -140 dB at bottom (absolute)
        final y = size.height * ((dbTop - v) / (dbTop - dbBottom));
        final x = t * size.width;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = traceColor,
      );
    }

    if (showGrid) {
      // dB grid (absolute 0..-140 dB)
      for (int g = 0; g >= dbBottom; g -= 20) {
        // y: 0 dB at top, -140 dB at bottom
        final y = size.height * ((dbTop - g) / (dbTop - dbBottom));
        canvas.drawLine(
            Offset(0, y),
            Offset(size.width, y),
            Paint()
              ..color = Colors.white10
              ..strokeWidth = 0.8);
        final tp = TextPainter(
          text: TextSpan(
              text: '$g',
              style: const TextStyle(color: Colors.white54, fontSize: 9)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(2, y - tp.height / 2));
      }
      // Frequency grid with piecewise mapping: ticks at 0, 10, 100, 1k, 10k
      for (final fTick in [0, 10, 100, 1000, 10000]) {
        if (fTick == 0) {
          final x = 0.0;
          canvas.drawLine(
              Offset(x, 0),
              Offset(x, size.height),
              Paint()
                ..color = Colors.white30
                ..strokeWidth = 1);
          final tp = TextPainter(
              text: const TextSpan(
                  text: '0',
                  style: TextStyle(color: Colors.white54, fontSize: 10)),
              textDirection: TextDirection.ltr)
            ..layout();
          tp.paint(canvas, Offset(x + 2, size.height - tp.height - 2));
          continue;
        }
        if (fTick < fLo || fTick > fHi) continue;
        final t = freqToT(fTick.toDouble());
        final x = t * size.width;
        canvas.drawLine(
          Offset(x, 0),
          Offset(x, size.height),
          Paint()
            ..color = Colors.white30
            ..strokeWidth = 1,
        );
        final label = fTick >= 1000
            ? '${(fTick / 1000).toStringAsFixed(fTick % 1000 == 0 ? 0 : 1)}k'
            : '$fTick';
        final tp = TextPainter(
            text: TextSpan(
                text: label,
                style: const TextStyle(color: Colors.white54, fontSize: 10)),
            textDirection: TextDirection.ltr)
          ..layout();
        tp.paint(canvas, Offset(x - tp.width / 2, size.height - tp.height - 2));
      }
      final hzTp = TextPainter(
          text: const TextSpan(
              text: 'Hz',
              style: TextStyle(color: Colors.white60, fontSize: 10)),
          textDirection: TextDirection.ltr)
        ..layout();
      hzTp.paint(canvas,
          Offset(size.width - hzTp.width - 2, size.height - hzTp.height - 2));
      final dbTp = TextPainter(
          text: TextSpan(
              text: displayUnit,
              style: const TextStyle(color: Colors.white60, fontSize: 10)),
          textDirection: TextDirection.ltr)
        ..layout();
      dbTp.paint(canvas, const Offset(2, 2));
    }

    // Peak marker
    if (peakFreqHz > 0) {
      final f = peakFreqHz.clamp(0.0, fHi);
      final t = freqToT(f.toDouble());
      final x = t * size.width;
      final k = (f / binHz).clamp(0, valuesDb.length - 1).toInt();
      final v = valuesDb[k].clamp(dbBottom, dbTop).toDouble();
      final y = size.height * ((dbTop - v) / (dbTop - dbBottom));
      canvas.drawCircle(
          Offset(x, y),
          7,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = Colors.redAccent);
      final label = '${f.toStringAsFixed(1)} Hz';
      final tp = TextPainter(
          text: TextSpan(
              text: label,
              style: const TextStyle(color: Colors.redAccent, fontSize: 11)),
          textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, y - 16 - tp.height));
    }

    // Pitch tracked overlay
    if (f0Tracked != null && f0Tracked! > 0) {
      final f = f0Tracked!.clamp(0.0, fHi);
      final t = freqToT(f.toDouble());
      final x = t * size.width;
      final state = trackerState ?? 'search';
      Color col;
      switch (state) {
        case 'locked':
          col = Colors.cyanAccent;
          break;
        case 'search':
          col = Colors.orangeAccent;
          break;
        default:
          col = Colors.purpleAccent;
          break;
      }
      // Vertical line
      canvas.drawLine(
          Offset(x, 0),
          Offset(x, size.height),
          Paint()
            ..color = col.withValues(alpha: 0.6)
            ..strokeWidth = 1.2);
      // ± cents band (approx convert cents to frequency ratio bounds)
      final band = overlayCentsBand ?? 0.0;
      if (band > 0) {
        final ratio = math.pow(2.0, band / 1200.0).toDouble();
        final fLoBand = (f / ratio).clamp(0.0, fHi);
        final fHiBand = (f * ratio).clamp(0.0, fHi);
        final xLo = freqToT(fLoBand) * size.width;
        final xHi = freqToT(fHiBand) * size.width;
        canvas.drawRect(Rect.fromLTRB(xLo, 0, xHi, size.height),
            Paint()..color = col.withValues(alpha: 0.08));
      }
    }

    // NOISE DETECTION VISUALIZATION (en mode LOCKED uniquement)
    if (trackerState == 'locked' && excludedPeaks.isNotEmpty) {
      // Calculer d'abord yNoise pour l'utiliser dans les cadres
      double yNoise = size.height;
      if (noiseFloorMeanDb.isFinite && noiseFloorMeanDb > dbBottom) {
        yNoise =
            size.height * ((dbTop - noiseFloorMeanDb) / (dbTop - dbBottom));
      }

      // 1. CADRES JAUNES autour des pics exclus
      final yellowPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0 // Bords plus fins
        ..color = Colors.yellow.withValues(alpha: 0.7);

      for (final peak in excludedPeaks) {
        final peakFreq = (peak as dynamic).freq as double;
        if (peakFreq <= 0 || peakFreq > fHi) continue;

        // Largeur du cadre: ±5 bins ou ±10Hz (le plus grand)
        final binHz = (fs / 2.0) / magLinear.length;
        final halfWidthHz = math.max(10.0, binHz * 5);
        final fLo = (peakFreq - halfWidthHz).clamp(0.0, fHi);
        final fHi2 = (peakFreq + halfWidthHz).clamp(0.0, fHi);
        final xLo = freqToT(fLo) * size.width;
        final xHi2 = freqToT(fHi2) * size.width;

        // Trouver le niveau du pic dans le spectre
        final k = (peakFreq / binHz).clamp(0, valuesDb.length - 1).toInt();
        final peakDb = valuesDb[k].clamp(dbBottom, dbTop);
        final yTop = size.height * ((dbTop - peakDb) / (dbTop - dbBottom));

        // Cadre jaune du haut du pic jusqu'à la ligne verte (plancher de bruit)
        canvas.drawRect(
          Rect.fromLTRB(xLo, yTop, xHi2, yNoise),
          yellowPaint,
        );
      }

      // 2. COURBE VERTE qui suit le plancher de bruit fréquence par fréquence
      if (noiseFloorCurve != null && noiseFloorCurve!.isNotEmpty) {
        final greenPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..color = Colors.greenAccent.withValues(alpha: 0.9);

        final binHz = (fs / 2.0) / noiseFloorCurve!.length;
        final path = Path();
        bool pathStarted = false;

        for (int i = 0; i < noiseFloorCurve!.length; i++) {
          final freq = i * binHz;
          if (freq < fLo || freq > fHi) continue;

          final level = noiseFloorCurve![i];
          if (level <= 0 || !level.isFinite) continue;

          final levelDb =
              (10 * math.log(level + 1e-20) / math.ln10).clamp(dbBottom, dbTop);
          final x = freqToT(freq) * size.width;
          final y = size.height * ((dbTop - levelDb) / (dbTop - dbBottom));

          if (!pathStarted) {
            path.moveTo(x, y);
            pathStarted = true;
          } else {
            path.lineTo(x, y);
          }
        }

        canvas.drawPath(path, greenPaint);

        // Label (en haut à droite)
        final label = 'Noise Floor';
        final tp = TextPainter(
          text: TextSpan(
              text: label,
              style: const TextStyle(
                  color: Colors.greenAccent,
                  fontSize: 10,
                  fontWeight: FontWeight.bold)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(size.width - tp.width - 5, 5));
      }
    }
  }

  @override
  bool shouldRepaint(covariant SpectrumPainter oldDelegate) =>
      oldDelegate.magLinear != magLinear ||
      oldDelegate.fs != fs ||
      oldDelegate.fMax != fMax ||
      oldDelegate.peakFreqHz != peakFreqHz;
}

// Local copy of frequency band generator to align painter with engine output
List<double> _generateFrequencyBands(int sampleRate) {
  final bands = <double>[];
  final nyquist = sampleRate / 2.0;

  // 0-100 Hz: 2 Hz bands
  for (double f = 0; f <= 100; f += 2) {
    bands.add(f);
  }

  // 100-1000 Hz: 5 Hz bands
  for (double f = 105; f <= 1000; f += 5) {
    bands.add(f);
  }

  // 1-20 kHz: ~1/24 octave bands
  double f = 1000;
  while (f < nyquist && f < 20000) {
    f *= 1.029; // ~1/24 octave step
    bands.add(f);
  }

  if (bands.isEmpty || bands.last < nyquist) {
    bands.add(nyquist);
  }
  return bands;
}
