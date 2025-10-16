import 'dart:math' as math;

import 'autocorrelation.dart' show PitchEstimate; // reuse shared PitchEstimate type

/// YIN fundamental frequency estimation (de Cheveigné & Kawahara, 2002).
/// - Computes the normalized difference function (NDF)
/// - Uses cumulative mean normalized difference (CMND)
/// - Picks the first minimum below [threshold]
/// - Refines period with parabolic interpolation
/// Returns null if no voiced candidate is found.
PitchEstimate? estimatePitchYin(
  List<double> samples,
  int sampleRate, {
  double minHz = 50,
  double maxHz = 1500,
  double threshold = 0.1, // typical YIN trough threshold
}) {
  final n = samples.length;
  if (n < 3 || sampleRate <= 0) return null;

  // Window to reduce spectral leakage (Hann)
  final win = List<double>.generate(n, (i) => 0.5 * (1 - math.cos(2 * math.pi * i / (n - 1))));
  final x = List<double>.generate(n, (i) => samples[i] * win[i]);

  // Lag search bounds
  final minTau = math.max(2, (sampleRate / maxHz).floor());
  final maxTau = math.min(n - 2, (sampleRate / minHz).ceil());
  if (maxTau <= minTau) return null;

  // Step 1: Difference function d(tau)
  final d = List<double>.filled(maxTau + 1, 0.0);
  for (int tau = 1; tau <= maxTau; tau++) {
    double sum = 0.0;
    for (int i = 0; i < n - tau; i++) {
      final diff = x[i] - x[i + tau];
      sum += diff * diff;
    }
    d[tau] = sum;
  }

  // Step 2: Cumulative mean normalized difference function (CMND)
  final cmnd = List<double>.filled(maxTau + 1, 1.0);
  double runningSum = 0.0;
  for (int tau = 1; tau <= maxTau; tau++) {
    runningSum += d[tau];
    cmnd[tau] = (runningSum > 0) ? d[tau] * tau / runningSum : 1.0;
  }

  // Step 3: Find first minimum below threshold within search range
  int tauCandidate = -1;
  for (int tau = minTau; tau <= maxTau; tau++) {
    if (cmnd[tau] < threshold) {
      // Local minimum search: choose the minimum in a small neighborhood
      while (tau + 1 <= maxTau && cmnd[tau + 1] < cmnd[tau]) {
        tau++;
      }
      tauCandidate = tau;
      break;
    }
  }

  // If none under threshold, take global minimum in range
  if (tauCandidate == -1) {
    double minVal = double.infinity;
    for (int tau = minTau; tau <= maxTau; tau++) {
      if (cmnd[tau] < minVal) {
        minVal = cmnd[tau];
        tauCandidate = tau;
      }
    }
  }

  if (tauCandidate < minTau || tauCandidate > maxTau) return null;

  // Step 4: Parabolic interpolation around tauCandidate for sub-sample accuracy
  final tau = _parabolicInterp(cmnd, tauCandidate);
  if (tau <= 0) return null;
  final freq = sampleRate / tau;
  if (freq.isNaN || freq.isInfinite || freq < minHz || freq > maxHz) return null;

  // Confidence proxy: 1 - CMND at tau (clamp to 0..1)
  final rawConf = 1.0 - cmnd[tauCandidate];
  final conf = rawConf.clamp(0.0, 1.0);
  return PitchEstimate(freq, conf);
}

double _parabolicInterp(List<double> f, int x) {
  final n = f.length;
  if (x <= 0 || x >= n - 1) return x.toDouble();
  final f0 = f[x - 1];
  final f1 = f[x];
  final f2 = f[x + 1];
  final denom = (f0 - 2 * f1 + f2);
  if (denom.abs() < 1e-12) return x.toDouble();
  final delta = 0.5 * (f0 - f2) / denom;
  return x + delta;
}
