import 'dart:math' as math;
import 'dart:typed_data';
import '../domain/interfaces.dart';

class YinDetector implements IPitchDetector {
  @override
  String get name => 'YIN';

  @override
  PitchFrameResearch? detect(Float32List x, int fs) {
    // Basic YIN (difference function + cmndf)
    final n = x.length;
    final diff = Float32List(n);
    for (int tau = 1; tau < n; tau++) {
      double s = 0.0;
      for (int i = 0; i < n - tau; i++) {
        final d = x[i] - x[i + tau];
        s += d * d;
      }
      diff[tau] = s;
    }
    final cmndf = Float32List(n);
    double running = 0.0;
    cmndf[0] = 1.0;
    for (int tau = 1; tau < n; tau++) {
      running += diff[tau];
      cmndf[tau] = running > 0 ? diff[tau] / (running / (tau + 1)) : 1.0;
    }

    // Threshold plus permissif pour guitare
    const thresh = 0.25;
    int tau = 2;
    while (tau < n - 1 && cmndf[tau] > thresh) {
      tau++;
    }
    if (tau >= n - 1) return null;

    // Parabolic interpolation around minimum
    final y1 = cmndf[tau - 1];
    final y2 = cmndf[tau];
    final y3 = cmndf[tau + 1];
    final denom = (y1 - 2 * y2 + y3);
    final delta = denom.abs() > 1e-9 ? 0.5 * (y1 - y3) / denom : 0.0;
    final peakTau = tau + delta;

    if (peakTau <= 0) return null;
    final f0 = fs / peakTau;

    // Confidence proxy from cmndf score
    final conf = (1.0 - y2).clamp(0.0, 1.0);
    double rms = 0.0;
    for (final v in x) {
      rms += v * v;
    }
    rms = math.sqrt(rms / x.length);

    return PitchFrameResearch(
      f0Hz: f0,
      confidence: conf,
      rms: rms,
      snr: conf,
      ts: DateTime.now(),
      detector: name,
    );
  }
}