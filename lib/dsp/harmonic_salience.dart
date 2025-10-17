import 'dart:math' as math;
import 'dart:typed_data';

class HarmonicResult {
  final double f0;
  final double confidence; // 0..1
  const HarmonicResult(this.f0, this.confidence);
}

class HarmonicSalience {
  final List<double> freqs; // log-frequency bin centers
  final int maxHarmonics;
  final double tolCents;
  final double weightDecay; // per harmonic (0..1)

  HarmonicSalience({
    required this.freqs,
    required this.maxHarmonics,
    required this.tolCents,
    required this.weightDecay,
  });

  // Precompute cents tolerance to ratio
  double get _tolRatio => math.pow(2.0, tolCents / 1200.0).toDouble();

  HarmonicResult process(Float32List logFreqPower, double fMin, double fMax) {
    if (logFreqPower.isEmpty) return const HarmonicResult(0.0, 0.0);
    final tol = _tolRatio;
    double bestScore = 0.0;
    double secondBestScore = 0.0;
    double bestFreq = 0.0;
    // Iterate candidate fundamentals within allowed range.
    for (int i = 0; i < freqs.length; i++) {
      final f = freqs[i];
      if (f < fMin || f > fMax) continue;
      double score = 0.0;
      double w = 1.0;
      // Sum harmonic contributions
      for (int h = 1; h <= maxHarmonics; h++) {
        final fh = f * h;
        if (fh > fMax) break;
        // Find closest bin
        int idx = _lowerBound(freqs, fh);
        if (idx < 0) continue;
        final binF = freqs[idx];
        final ratio = fh / binF;
        if (ratio < 1 / tol || ratio > tol) {
          w *= weightDecay; // penalize mismatch
          continue;
        }
        final p = logFreqPower[idx];
        score += w * p;
        w *= weightDecay;
      }
      if (score > bestScore) {
        // shift previous best to second best
        secondBestScore = bestScore;
        bestScore = score;
        bestFreq = f;
      } else if (score > secondBestScore) {
        secondBestScore = score;
      }
    }
    if (bestScore <= 0 || bestFreq <= 0) return const HarmonicResult(0.0, 0.0);
    // Confidence heuristic: dominance of best vs runner-up (0.5 when equal, ->1 when dominant)
    final denom = bestScore + secondBestScore + 1e-9;
    final conf = (bestScore / denom).clamp(0.0, 1.0);
    return HarmonicResult(bestFreq, conf);
  }

  int _lowerBound(List<double> a, double x) {
    int lo = 0, hi = a.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (a[mid] < x) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final idx = (lo >= a.length) ? a.length - 1 : lo;
    return idx;
  }
}
