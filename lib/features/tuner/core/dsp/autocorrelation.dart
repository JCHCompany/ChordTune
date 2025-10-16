import 'dart:math' as math;

class PitchEstimate {
  final double frequencyHz;
  final double confidence; // 0..1 normalized correlation at peak
  const PitchEstimate(this.frequencyHz, this.confidence);
}

/// Estimate pitch using a normalized autocorrelation method.
/// Returns null if no reliable pitch found.
PitchEstimate? estimatePitchAutocorrelation(
  List<double> samples,
  int sampleRate, {
  double minHz = 50,
  double maxHz = 1500, // extend range for higher notes
}) {
  if (samples.isEmpty || sampleRate <= 0) return null;
  final n = samples.length;
  // Apply a Hann window to reduce spectral leakage.
  final win = List<double>.generate(n, (i) => 0.5 * (1 - math.cos(2 * math.pi * i / (n - 1))));
  final x = List<double>.generate(n, (i) => samples[i] * win[i]);

  final minLag = (sampleRate / maxHz).floor();
  final maxLag = math.min((sampleRate / minHz).ceil(), n - 1);
  if (maxLag <= minLag) return null;

  double bestCorr = 0;
  int bestLag = 0;

  // Precompute energy for normalization.
  final energy0 = _dot(x, x);
  if (energy0 <= 1e-12) return null;

  for (int lag = minLag; lag <= maxLag; lag++) {
    double corr = 0;
    double energyLag = 0;
    for (int i = 0; i < n - lag; i++) {
      final a = x[i];
      final b = x[i + lag];
      corr += a * b;
      energyLag += b * b;
    }
    if (energyLag <= 1e-12) continue;
    final normCorr = corr / math.sqrt(energy0 * energyLag);
    if (normCorr > bestCorr) {
      bestCorr = normCorr;
      bestLag = lag;
    }
  }

  if (bestLag == 0) return null;
  final freq = sampleRate / bestLag;
  return PitchEstimate(freq, bestCorr.clamp(0, 1));
}

double _dot(List<double> a, List<double> b) {
  final n = math.min(a.length, b.length);
  double s = 0;
  for (int i = 0; i < n; i++) {
    s += a[i] * b[i];
  }
  return s;
}
