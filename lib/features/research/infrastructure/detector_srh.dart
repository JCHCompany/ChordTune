import 'dart:typed_data';
import '../domain/interfaces.dart';
import 'spectrum.dart';

class SrhDetector implements IPitchDetector {
  @override
  String get name => 'SRH';

  @override
  PitchFrameResearch? detect(Float32List x, int fs) {
    // Simple SRH proxy using whitened magnitude spectrum
    final mag = SpectrumUtils.magnitude(x);
    final w = SpectrumUtils.whiten(mag);
    double bestScore = 0.0;
    double bestF0 = 0.0;
    // scan in 80..800 Hz
    for (double f = 80; f <= 800; f += 2) {
      double score = 0.0;
      for (int h = 1; h <= 6; h++) {
        score += SpectrumUtils.harmonicEnergy(w, f, fs, h: h) / h;
      }
      if (score > bestScore) { bestScore = score; bestF0 = f; }
    }
    if (bestF0 <= 0) return null;
    return PitchFrameResearch(
      f0Hz: bestF0,
      confidence: (bestScore / 50.0).clamp(0.0, 1.0),
      rms: 0.0,
      snr: 0.0,
      ts: DateTime.now(),
      detector: name,
    );
  }
}