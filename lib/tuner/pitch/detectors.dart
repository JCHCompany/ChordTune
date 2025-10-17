import 'dart:math' as math;

class YinConfig {
  const YinConfig({
    required this.windowSize,
    required this.fMin,
    required this.fMax,
    this.threshold = 0.1,
  });
  final int windowSize;
  final double fMin;
  final double fMax;
  final double threshold; // lower is stricter
}

class YinResult {
  const YinResult({required this.f0, required this.confidence});
  final double? f0;
  final double confidence; // 0..1
}

/// YIN difference function with cumulative mean normalized difference.
YinResult yinDetect(List<double> x, double fs, YinConfig cfg) {
  final n = math.min(cfg.windowSize, x.length);
  if (n < 4) return const YinResult(f0: null, confidence: 0.0);
  final tauMax = (fs / cfg.fMin).floor().clamp(1, n - 2);
  final tauMin = (fs / cfg.fMax).floor().clamp(1, tauMax);
  final d = List<double>.filled(tauMax + 1, 0.0);
  // Difference function
  for (var tau = 1; tau <= tauMax; tau++) {
    double sum = 0.0;
    for (var i = 0; i < n - tau; i++) {
      final diff = x[i] - x[i + tau];
      sum += diff * diff;
    }
    d[tau] = sum;
  }
  // Cumulative mean normalized difference
  final cmnd = List<double>.filled(tauMax + 1, 1.0);
  double runningSum = 0.0;
  for (var tau = 1; tau <= tauMax; tau++) {
    runningSum += d[tau];
    cmnd[tau] = d[tau] * tau / (runningSum == 0 ? 1e-12 : runningSum);
  }
  // Absolute threshold
  var tauEstimate = -1;
  for (var tau = tauMin; tau <= tauMax; tau++) {
    if (cmnd[tau] < cfg.threshold) {
      while (tau + 1 <= tauMax && cmnd[tau + 1] < cmnd[tau]) {
        tau++;
      }
      tauEstimate = tau;
      break;
    }
  }
  if (tauEstimate == -1) {
    // pick global minimum in range
    var bestTau = tauMin;
    var bestVal = cmnd[tauMin];
    for (var tau = tauMin + 1; tau <= tauMax; tau++) {
      if (cmnd[tau] < bestVal) {
        bestVal = cmnd[tau];
        bestTau = tau;
      }
    }
    tauEstimate = bestTau;
  }
  // Parabolic interpolation around tauEstimate to refine
  final tau = tauEstimate;
  final prev = tau > 1 ? cmnd[tau - 1] : cmnd[tau];
  final next = tau + 1 <= tauMax ? cmnd[tau + 1] : cmnd[tau];
  final a = prev + next - 2 * cmnd[tau];
  final b = (next - prev) / 2.0;
  var tauRefined = tau.toDouble();
  if (a.abs() > 1e-12) {
    tauRefined = tau - b / (2 * a);
  }
  final f0 = fs / tauRefined;
  final confidence = (1.0 - cmnd[tau].clamp(0.0, 1.0));
  if (f0.isNaN || f0.isInfinite) {
    return const YinResult(f0: null, confidence: 0.0);
  }
  return YinResult(f0: f0, confidence: confidence);
}

class HarmonicConfig {
  const HarmonicConfig({
    this.harmonics = 4,
    this.toleranceCents = 15,
    required this.fMin,
    required this.fMax,
  });
  final int harmonics; // 2..6 typical
  final double toleranceCents;
  final double fMin;
  final double fMax;
}

class HarmonicResult {
  const HarmonicResult({required this.f0, required this.score});
  final double? f0;
  final double score;
}

/// Harmonic summation over PSD power bins with HPS-style weighting and rescue.
HarmonicResult harmonicDetect({
  required List<double> freqs,
  required List<double> power,
  required HarmonicConfig cfg,
}) {
  // Candidate fundamentals from fMin..fMax sampled on a log grid ~ 1 cent.
  final cPerOct = 1200.0;
  final fCandidates = <double>[];
  final start = cfg.fMin;
  final stop = cfg.fMax;
  var f = start;
  while (f <= stop) {
    fCandidates.add(f);
    f *= math.pow(2, 1 / cPerOct) as double; // step 1 cent
  }

  double bestScore = 0.0;
  double? bestF0;
  final tolRatio = math.pow(2, cfg.toleranceCents / 1200.0) as double;

  // HPS-style weights: decreasing for higher harmonics
  final weights = [1.0, 0.8, 0.6, 0.4];

  for (final fc in fCandidates) {
    double score = 0.0;
    for (var h = 1; h <= cfg.harmonics; h++) {
      final target = fc * h;
      // Find nearest bin within tolerance.
      double bestBinPower = 0.0;
      for (var i = 0; i < freqs.length; i++) {
        final fbin = freqs[i];
        if (fbin < target / tolRatio || fbin > target * tolRatio) continue;
        final pw = power[i];
        if (pw > bestBinPower) bestBinPower = pw;
      }
      final w = (h - 1) < weights.length ? weights[h - 1] : (1.0 / h);
      score += bestBinPower * w;
    }
    if (score > bestScore) {
      bestScore = score;
      bestF0 = fc;
    }
  }

  // Rescue fundamental: if a strong peak at 2f0 or 3f0 dominates, test f0/2 or f0/3
  if (bestF0 != null && bestScore > 0) {
    final candidates = [bestF0 / 2.0, bestF0 / 3.0];
    for (final rescueF0 in candidates) {
      if (rescueF0 < cfg.fMin || rescueF0 > cfg.fMax) continue;

      double rescueScore = 0.0;
      for (var h = 1; h <= cfg.harmonics; h++) {
        final target = rescueF0 * h;
        double bestBinPower = 0.0;
        for (var i = 0; i < freqs.length; i++) {
          final fbin = freqs[i];
          if (fbin < target / tolRatio || fbin > target * tolRatio) continue;
          final pw = power[i];
          if (pw > bestBinPower) bestBinPower = pw;
        }
        final w = (h - 1) < weights.length ? weights[h - 1] : (1.0 / h);
        rescueScore += bestBinPower * w;
      }

      // Accept rescue if gain ≥ 4-6 dB (factor ~2.5x)
      if (rescueScore > bestScore * 2.5) {
        bestScore = rescueScore;
        bestF0 = rescueF0;
      }
    }
  }

  return HarmonicResult(f0: bestF0, score: bestScore);
}

class FusionConfig {
  const FusionConfig({
    this.wYin = 0.05,
    this.wHarm = 0.35,
    this.wAi = 0.45,
    this.wSnr = 0.15,
    this.penaltyOctaveStrong = 1200.0,
    this.penaltyMediumLow = 700.0,
    this.penaltyMediumHigh = 900.0,
  });
  final double wYin;
  final double wHarm;
  final double wAi;
  final double wSnr;
  final double penaltyOctaveStrong;
  final double penaltyMediumLow;
  final double penaltyMediumHigh;
}

class FusionResult {
  const FusionResult({required this.f0, required this.score});
  final double? f0;
  final double score; // 0..1 normalized
}

FusionResult fusePitch({
  required YinResult yin,
  required HarmonicResult harm,
  required FusionConfig cfg,
  required double fs,
}) {
  // Normalize scores: YIN confidence in 0..1; Harm score relative to its max via logistic.
  final sY = yin.confidence.clamp(0.0, 1.0);
  final sH = harm.score > 0 ? 1 - 1 / (1 + harm.score) : 0.0; // squashing
  final wSum = (cfg.wYin + cfg.wHarm);
  final wY = cfg.wYin / wSum;
  final wH = cfg.wHarm / wSum;
  // Candidate f0: pick the one with better weighted score.
  double? f0;
  if ((sY * wY) >= (sH * wH)) {
    f0 = yin.f0;
  } else {
    f0 = harm.f0;
  }
  final score = (sY * wY + sH * wH).clamp(0.0, 1.0);
  return FusionResult(f0: f0, score: score);
}

/// AI-aware fusion with SNR and octave penalties. If [f0Prev] provided,
/// apply penalties to candidates far (~±1200c) or medium (±700–900c) from previous.
FusionResult fusePitchAdvanced({
  required YinResult yin,
  required HarmonicResult harm,
  required FusionConfig cfg,
  required double snrDb,
  double? f0Ai,
  double aiConf = 0.0,
  double? f0Prev,
}) {
  final norm = (double x, double lo, double hi) =>
      ((x - lo) / (hi - lo)).clamp(0.0, 1.0);
  final sY = yin.confidence.clamp(0.0, 1.0);
  final sH = harm.score > 0 ? 1 - 1 / (1 + harm.score) : 0.0;
  final sA = aiConf.clamp(0.0, 1.0);
  final sS = norm(snrDb, 0, 30); // normalize SNR 0..30 dB

  // Compose scores per candidate
  final candidates = <double?>[yin.f0, harm.f0, f0Ai];
  final scores = <double>[sY * cfg.wYin, sH * cfg.wHarm, sA * cfg.wAi];
  // Add SNR to all candidates equally
  for (var i = 0; i < scores.length; i++) {
    scores[i] += sS * cfg.wSnr;
  }
  // Apply octave penalties based on previous f0
  if (f0Prev != null) {
    for (var i = 0; i < candidates.length; i++) {
      final f = candidates[i];
      if (f == null) continue;
      final cents = 1200.0 * (math.log(f / f0Prev) / math.ln2).abs();
      if ((cents - cfg.penaltyOctaveStrong).abs() < 80) {
        scores[i] *= 0.5; // strong penalty near ±1200c
      } else if (cents > cfg.penaltyMediumLow &&
          cents < cfg.penaltyMediumHigh) {
        scores[i] *= 0.8; // medium penalty
      }
    }
  }
  // Pick best
  var bestIdx = 0;
  var bestScore = -1.0;
  for (var i = 0; i < candidates.length; i++) {
    if (candidates[i] != null && scores[i] > bestScore) {
      bestScore = scores[i];
      bestIdx = i;
    }
  }
  return FusionResult(
      f0: candidates[bestIdx], score: bestScore.clamp(0.0, 1.0));
}
