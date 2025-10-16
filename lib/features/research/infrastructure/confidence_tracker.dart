import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';
import '../domain/interfaces.dart';
import 'spectrum.dart';
import 'package:path_provider/path_provider.dart';

class SimpleConfidence implements IConfidenceEstimator {
  @override
  double voicedConfidence({required double hnr, required double peakProminence}) {
    // Weighted sum clipped
    return (0.6 * hnr + 0.4 * peakProminence).clamp(0.0, 1.0);
  }
}

class AntiOctaveHarmonic implements IAntiOctave {
  @override
  double correct(double f0, Float32List spectrum, int fs) {
    if (f0 <= 0) return f0;
    double scoreAt(double f) {
      if (f <= 0 || f > fs / 2) return 0.0;
      double s = 0.0;
      for (int h = 1; h <= 6; h++) {
        s += SpectrumUtils.harmonicEnergy(spectrum, f, fs, h: h) / h;
      }
      return s;
    }
    final fHalf = f0 / 2;
    final fBase = f0;
    final fDouble = f0 * 2;
    final sHalf = scoreAt(fHalf);
    final sBase = scoreAt(fBase);
    final sDouble = scoreAt(fDouble);

    double bestF = fBase;
    double bestS = sBase;
    if (sHalf > bestS * 1.15 && fHalf > 50) { bestF = fHalf; bestS = sHalf; }
    if (sDouble > bestS * 1.15 && fDouble < 1200) { bestF = fDouble; bestS = sDouble; }
    return bestF;
  }
}

class EmaHysteresisTracker implements ITracker {
  final double alpha;
  final int kLock;
  final int kUnlock;

  double? _cents;
  // int _lockCount = 0; // unused
  // int _unlockCount = 0; // unused

  EmaHysteresisTracker({this.alpha = 0.25, this.kLock = 4, int? kUnlock})
      : kUnlock = kUnlock ?? (4 * 2);

  @override
  (double f0Hz, double conf) update(double? f0Hz, double conf) {
    if (f0Hz == null || conf < 0.6) {
      // hold
      return (_cents != null) ? (_hzFromCents(_cents!), conf) : (0.0, conf);
    }
    final cents = _centsFromHz(f0Hz);
    _cents = (_cents == null) ? cents : alpha * _cents! + (1 - alpha) * cents;

    // simple lock/unlock based on delta cents
    final delta = (_cents! - cents).abs();
    if (delta < 5) {
      // _lockCount++; // unused
      // _unlockCount = 0; // unused
    } else if (delta > 10) {
      // _unlockCount++; // unused
    }
    return (_hzFromCents(_cents!), conf);
  }

  double _centsFromHz(double f) => 1200 * (math.log(f / 440.0) / math.ln2) + 6900; // A4=440 at 6900 cents
  double _hzFromCents(double c) => 440.0 * math.pow(2, (c - 6900) / 1200.0).toDouble();
}

class CsvMetricsSink implements IMetricsSink {
  final StringBuffer _buf = StringBuffer('ts,f0,conf,rms,snr,detector\n');
  @override
  void onFrame(PitchFrameResearch frame) {
    _buf.writeln('${frame.ts.toIso8601String()},${frame.f0Hz.toStringAsFixed(3)},${frame.confidence.toStringAsFixed(3)},${frame.rms.toStringAsFixed(3)},${frame.snr.toStringAsFixed(3)},${frame.detector}');
  }

  @override
  Future<void> flush() async {
    final dir = await getApplicationDocumentsDirectory();
    final ts = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name = 'research_logs_${ts.year}${two(ts.month)}${two(ts.day)}_${two(ts.hour)}${two(ts.minute)}${two(ts.second)}.csv';
    final file = File('${dir.path}/$name');
    await file.writeAsString(_buf.toString());
  }
}

class SimpleSelector implements IDetectorSelector {
  final double lowThresh;
  SimpleSelector({this.lowThresh = 0.2}); // Seuil plus bas
  @override
  PitchFrameResearch? select(List<PitchFrameResearch?> candidates) {
    PitchFrameResearch? best;
    for (final c in candidates) {
      if (c == null || c.confidence < lowThresh) continue;
      if (best == null || c.confidence > best.confidence) best = c;
    }
    return best;
  }
}