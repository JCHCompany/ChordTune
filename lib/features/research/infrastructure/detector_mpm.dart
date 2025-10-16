import 'dart:math' as math;
import 'dart:typed_data';
import '../domain/interfaces.dart';

class MpmDetector implements IPitchDetector {
  @override
  String get name => 'MPM';

  @override
  PitchFrameResearch? detect(Float32List x, int fs) {
    // NSDF
    final n = x.length;
    final nsdf = Float32List(n);
    // double m0 = 0; // unused
    // for (final v in x) {
    //   m0 += v * v;
    // }
    for (int tau = 0; tau < n; tau++) {
      double ac = 0, mTau = 0;
      for (int i = 0; i < n - tau; i++) {
        final a = x[i];
        final b = x[i + tau];
        ac += a * b;
        mTau += a * a + b * b;
      }
      nsdf[tau] = mTau > 1e-9 ? 2 * ac / mTau : 0.0;
    }

    // Peak picking beyond minimum period - étendu pour guitare
    final minF = 65.0, maxF = 1200.0; // E2 = 82.4 Hz, mais on prend plus large
    final minTau = (fs / maxF).floor();
    final maxTau = math.min((fs / minF).ceil(), n - 1);

    int bestTau = -1;
    double bestVal = 0.0;
    for (int tau = minTau + 1; tau < maxTau - 1; tau++) {
      final v = nsdf[tau];
      if (v > 0.3 && v > nsdf[tau - 1] && v > nsdf[tau + 1]) { // Seuil plus bas
        // Parabolic interpolation
        final y1 = nsdf[tau - 1], y2 = v, y3 = nsdf[tau + 1];
        final denom = (y1 - 2 * y2 + y3);
        final delta = denom.abs() > 1e-9 ? 0.5 * (y1 - y3) / denom : 0.0;
        final peakTau = tau + delta;
        final peakVal = y2 - 0.25 * (y1 - y3) * delta;
        if (peakVal > bestVal) {
          bestVal = peakVal;
          bestTau = peakTau.round();
        }
      }
    }

    if (bestTau <= 0) return null;
    final f0 = fs / bestTau;

    // Simple HNR proxy and RMS
    double rms = 0.0;
    for (final v in x) {
      rms += v * v;
    }
    rms = math.sqrt(rms / x.length);

    final conf = bestVal.clamp(0.0, 1.0);
    return PitchFrameResearch(
      f0Hz: f0,
      confidence: conf,
      rms: rms,
      snr: conf, // placeholder
      ts: DateTime.now(),
      detector: name,
    );
  }
}