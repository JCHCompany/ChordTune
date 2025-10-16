import 'package:flutter/material.dart';
import 'dart:math' as math;

class Waveform extends StatelessWidget {
  final List<double> x;
  const Waveform({super.key, required this.x});
  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(double.infinity, 120),
      painter: _WavePainter(x),
    );
  }
}

class _WavePainter extends CustomPainter {
  final List<double> x;
  _WavePainter(this.x);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.cyan
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;
    final path = Path();
    if (x.isEmpty) return;
    final n = x.length;
    for (int i = 0; i < n; i++) {
      final t = i / (n - 1);
      final y = size.height / 2 - x[i] * (size.height / 2 - 2);
      final xPos = t * size.width;
      if (i == 0) {
        path.moveTo(xPos, y);
      } else {
        path.lineTo(xPos, y);
      }
    }
    canvas.drawPath(path, p);
  }
  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) => oldDelegate.x != x;
}

class NoteCents extends StatelessWidget {
  final double f0;
  const NoteCents({super.key, required this.f0});
  @override
  Widget build(BuildContext context) {
    if (f0 <= 0) return const Text('—');
    final a4 = 440.0;
    final n = (12 * (math.log(f0 / a4) / math.ln2)).round();
    final noteIndex = (n + 69) % 12; // C=0, C#=1 ... B=11 (relative mapping)
    const names = ['C','C#','D','D#','E','F','F#','G','G#','A','A#','B'];
    final note = names[(noteIndex + 12) % 12];
    final nearest = a4 * math.pow(2, n / 12);
    final cents = 1200 * (math.log(f0 / nearest) / math.ln2);
    return Text('$note  ${cents.toStringAsFixed(1)} cents');
  }
}

class SpectrumView extends StatelessWidget {
  final List<double> mag;
  final int fs; // sample rate in Hz
  final double fMin; // minimum frequency to display
  final double? fMax; // maximum frequency (defaults to Nyquist)
  final bool useDb; // display in dB for vertical scaling
  
  const SpectrumView({
    super.key,
    required this.mag,
    required this.fs,
    this.fMin = 10, // Commencer à 10 Hz pour une vue conventionnelle
    this.fMax,
    this.useDb = true,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(double.infinity, 120),
      painter: _SpectrumPainter(mag, fs, fMin, fMax, useDb),
    );
  }
}

class _SpectrumPainter extends CustomPainter {
  final List<double> m;
  final int fs;
  final double fMin;
  final double? fMax;
  final bool useDb;
  _SpectrumPainter(this.m, this.fs, this.fMin, this.fMax, this.useDb);
  @override
  void paint(Canvas canvas, Size size) {
    if (m.isEmpty) return;
    final p = Paint()
      ..color = Colors.amber
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final path = Path();

    // Determine frequency mapping and sampling density
    final nyquist = fs / 2.0;
    final fHi = (fMax == null || fMax!.isNaN || fMax! <= 0) ? nyquist : math.min(fMax!, nyquist);
    final fLo = math.max(5.0, math.min(fMin, fHi - 1)); // Commencer à 5 Hz pour une vue plus large
  final binHz = nyquist / m.length;
  // Log-frequency mapping bounds (base-10)
  final logMin = math.log(fLo) / math.ln10;
  final logMax = math.log(fHi) / math.ln10;

    // Sample one point per pixel column (clamped)
    int steps = size.width.isFinite ? size.width.floor() : 300;
    steps = steps.clamp(64, 2048);

    // Mapping log amélioré avec meilleure répartition
    final values = List<double>.filled(steps, 0.0);
    double maxVal = -1e30;
    
    for (int i = 0; i < steps; i++) {
      final t = steps == 1 ? 0.0 : i / (steps - 1);
      
      // Échelle log-log pour mieux étaler les fréquences guitare
      // Donne plus d'espace aux harmoniques des cordes graves
      final f = math.pow(10, logMin + t * (logMax - logMin));
      
      // Moyennage sur plusieurs bins pour lisser
      final centerBin = (f / binHz).round();
      final startBin = math.max(0, centerBin - 1);
      final endBin = math.min(m.length - 1, centerBin + 1);
      
      double v = 0.0;
      int count = 0;
      for (int bin = startBin; bin <= endBin; bin++) {
        v += m[bin];
        count++;
      }
      v = count > 0 ? v / count : 0.0;
      
      if (useDb) {
        v = 20 * math.log(v + 1e-12) / math.ln10;
      }
      values[i] = v;
      if (v > maxVal) maxVal = v;
    }

    // Determine floor and normalize
    double minVal;
    double denom;
    if (useDb) {
      // Fixed dynamic range: show from 0 dB (top) down to -120 dB (bottom)
      final floor = maxVal - 120.0;
      minVal = floor;
      for (int i = 0; i < steps; i++) {
        if (values[i] < floor) values[i] = floor;
      }
      denom = 120.0; // fixed dB span
    } else {
      minVal = 0.0;
      denom = (maxVal - minVal).abs() < 1e-9 ? 1.0 : (maxVal - minVal);
    }

    for (int i = 0; i < steps; i++) {
      final xPix = steps == 1 ? 0.0 : i / (steps - 1) * size.width;
      final norm = ((values[i] - minVal) / denom).clamp(0.0, 1.0);
      final yPix = size.height - norm * (size.height - 2);
      if (i == 0) {
        path.moveTo(xPix, yPix);
      } else {
        path.lineTo(xPix, yPix);
      }
    }
    canvas.drawPath(path, p);

    // Axe vertical (amplitude) en dB: grille horizontale et étiquettes conventionnelles
    if (useDb) {
      // Grid at 0, -20, -40, ..., -120 dB relative to the current peak
      const yGridRel = <int>[0, -20, -40, -60, -80, -100, -120];
      for (final relDb in yGridRel) {
        final yVal = maxVal + relDb; // relDb <= 0
        if (yVal < minVal || yVal > maxVal) continue;
        final norm = ((yVal - minVal) / 120.0).clamp(0.0, 1.0);
        final y = size.height - norm * (size.height - 2);

        // Ligne horizontale de grille
        canvas.drawLine(
          Offset(0, y),
          Offset(size.width, y),
          Paint()..color = Colors.white10..strokeWidth = 0.8,
        );

        // Étiquette dB sur le côté gauche
        final label = relDb.toString();
        final textSpan = TextSpan(
          text: label,
          style: const TextStyle(color: Colors.white54, fontSize: 9),
        );
        final tp = TextPainter(text: textSpan, textDirection: TextDirection.ltr);
        tp.layout();
        tp.paint(canvas, Offset(2, y - tp.height / 2));
      }

      // Label "dB" en haut à gauche
      const dbLabel = TextSpan(
        text: 'dB',
        style: TextStyle(color: Colors.white60, fontSize: 10, fontWeight: FontWeight.w500),
      );
      final dbPainter = TextPainter(text: dbLabel, textDirection: TextDirection.ltr);
      dbPainter.layout();
      dbPainter.paint(canvas, const Offset(2, 2));
    }
    
    // Graduations fréquentielles conventionnelles (échelle log: 10, 100, 1k, 10k Hz)
    const textStyle = TextStyle(color: Colors.white54, fontSize: 10);
    final majorTicks = <int>[10, 100, 1000, 10000]; // ticks majeurs conventionnels
    final minorTicks = <int>[20, 30, 50, 200, 300, 500, 2000, 3000, 5000]; // ticks mineurs
    final frequencies = <int>{...majorTicks, ...minorTicks}.toList()..sort();
    
    for (final freq in frequencies) {
      if (freq >= fLo && freq <= fHi) {
        final t = (math.log(freq) / math.ln10 - logMin) / (logMax - logMin);
        final x = t * size.width;
        
        // Trait vertical (majeurs: ligne complète, mineurs: petits traits)
        final isMajor = majorTicks.contains(freq);
        final tickPaint = Paint()
          ..color = isMajor ? Colors.white30 : Colors.white12
          ..strokeWidth = isMajor ? 1.0 : 0.5;
        
        if (isMajor) {
          // Ligne complète pour les ticks majeurs
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), tickPaint);
        } else {
          // Petit trait en bas pour les ticks mineurs
          canvas.drawLine(Offset(x, size.height - 8), Offset(x, size.height), tickPaint);
        }
        
        // Label fréquence (seulement pour les ticks majeurs ou significatifs)
        if (isMajor || freq == 10 || freq == 50 || freq == 500) {
          String label;
          if (freq >= 10000) {
            label = '${(freq/1000).toStringAsFixed(0)}k';
          } else if (freq >= 1000) {
            label = '${(freq/1000).toStringAsFixed(freq % 1000 == 0 ? 0 : 1)}k';
          } else {
            label = freq.toString();
          }
          
          final textSpan = TextSpan(text: label, style: textStyle);
          final textPainter = TextPainter(text: textSpan, textDirection: TextDirection.ltr);
          textPainter.layout();
          
          // Positionner le label en bas, centré sur le tick
          final labelX = (x - textPainter.width / 2).clamp(0.0, size.width - textPainter.width);
          textPainter.paint(canvas, Offset(labelX, size.height - textPainter.height - 2));
        }
      }
    }
    
    // Label "Hz" en bas à droite pour l'axe des fréquences
    const hzLabel = TextSpan(
      text: 'Hz', 
      style: TextStyle(color: Colors.white60, fontSize: 10, fontWeight: FontWeight.w500)
    );
    final hzPainter = TextPainter(text: hzLabel, textDirection: TextDirection.ltr);
    hzPainter.layout();
    hzPainter.paint(canvas, Offset(size.width - hzPainter.width - 2, size.height - hzPainter.height - 2));
  }
  @override
  bool shouldRepaint(covariant _SpectrumPainter oldDelegate) {
    return oldDelegate.m != m || oldDelegate.fs != fs || oldDelegate.fMin != fMin || oldDelegate.fMax != fMax || oldDelegate.useDb != useDb;
  }
}