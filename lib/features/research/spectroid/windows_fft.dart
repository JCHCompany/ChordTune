import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'spectroid_config.dart';
// Reuse a compile-time-like flag to gate verbose logs
const bool kWindowVerboseLogs = false;

Float32List makeWindow(int n, SpectroidWindow type, {double beta = 8.0}) {
  final w = Float32List(n);
  switch (type) {
    case SpectroidWindow.hann:
      for (int i = 0; i < n; i++) {
        w[i] = (0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1))).toDouble();
      }
      break;
    case SpectroidWindow.hamming:
      for (int i = 0; i < n; i++) {
        w[i] = (0.54 - 0.46 * math.cos(2 * math.pi * i / (n - 1))).toDouble();
      }
      break;
    case SpectroidWindow.blackmanHarris:
      const a0 = 0.35875, a1 = 0.48829, a2 = 0.14128, a3 = 0.01168;
      for (int i = 0; i < n; i++) {
        final t = 2 * math.pi * i / (n - 1);
        w[i] = (a0 - a1 * math.cos(t) + a2 * math.cos(2 * t) - a3 * math.cos(3 * t)).toDouble();
      }
      break;
    case SpectroidWindow.flattop:
      // 5-term flattop
      const a0 = 1.0, a1 = 1.93, a2 = 1.29, a3 = 0.388, a4 = 0.032;
      for (int i = 0; i < n; i++) {
        final t = 2 * math.pi * i / (n - 1);
        w[i] = (a0 - a1 * math.cos(t) + a2 * math.cos(2 * t) - a3 * math.cos(3 * t) + a4 * math.cos(4 * t)).toDouble();
      }
      break;
    case SpectroidWindow.kaiser:
      final denom = _besseli0(beta);
      for (int i = 0; i < n; i++) {
        final r = 2 * i / (n - 1) - 1;
        final val = _besseli0(beta * math.sqrt(1 - r * r)) / denom;
        w[i] = val.toDouble();
      }
      break;
  }
  
  // Debug window properties
  double sumW = 0.0;
  double sumW2 = 0.0;
  for (int i = 0; i < n; i++) {
    sumW += w[i];
    sumW2 += w[i] * w[i];
  }
  final coherentGain = sumW / n; // amplitude scale for a full-scale sine at bin
  final U = sumW2 / n;           // average window power (Welch)
  final enbw = U / (coherentGain * coherentGain); // Equivalent Noise BandWidth in bins
  if (kWindowVerboseLogs) {
    debugPrint('Window ${type.name}: size=$n, sumW=${sumW.toStringAsFixed(3)}, sumW2=${sumW2.toStringAsFixed(3)}, coherentGain=${coherentGain.toStringAsFixed(6)}, ENBW_bins=${enbw.toStringAsFixed(6)}');
  }
  
  return w;
}

/// Compute window metrics needed for PSD precise normalization
class WindowMetrics {
  final double coherentGain; // sum(w)/N
  final double U;            // sum(w^2)/N
  final double enbwBins;     // U / coherentGain^2
  const WindowMetrics(this.coherentGain, this.U, this.enbwBins);
}

WindowMetrics computeWindowMetrics(Float32List w) {
  final n = w.length;
  double sumW = 0.0;
  double sumW2 = 0.0;
  for (int i = 0; i < n; i++) {
    sumW += w[i];
    sumW2 += w[i] * w[i];
  }
  final cg = n > 0 ? sumW / n : 0.0;
  final U = n > 0 ? sumW2 / n : 0.0;
  final enbw = (cg != 0.0) ? (U / (cg * cg)) : 0.0;
  return WindowMetrics(cg, U, enbw);
}

double _besseli0(double x) {
  // Approx I0 Bessel
  double ax = x.abs();
  if (ax < 3.75) {
    double y = (x / 3.75) * (x / 3.75);
    return 1.0 + y * (3.5156229 + y * (3.0899424 + y * (1.2067492 + y * (0.2659732 + y * (0.0360768 + y * 0.0045813)))));
  } else {
    double y = 3.75 / ax;
    // Use explicit polynomial to avoid parenthesis mistakes
    final p0 = 0.39894228;
    final p1 = 0.01328592;
    final p2 = 0.00225319;
    final p3 = -0.00157565;
    final p4 = 0.00916281;
    final p5 = -0.02057706;
    final p6 = 0.02635537;
    final p7 = -0.01647633;
    final p8 = 0.00392377;
  double poly = p8;
  poly = p7 + y * poly;
  poly = p6 + y * poly;
  poly = p5 + y * poly;
  poly = p4 + y * poly;
  poly = p3 + y * poly;
  poly = p2 + y * poly;
  poly = p1 + y * poly;
  poly = p0 + y * poly;
  return (math.exp(ax) / math.sqrt(ax)) * poly;
  }
}

/// Compute one-sided Power Spectral Density (PSD) in linear units (per Hz)
/// using Welch normalization:
///   U = sum(w[n]^2) / N
///   Pxx[k] = (2 / (Fs * N * U)) * |X[k]|^2 for k > 0 (when Nyquist excluded)
///   Pxx[0] = (1 / (Fs * N * U)) * |X[0]|^2 (DC not doubled)
///
/// Notes:
/// - This returns N/2 bins (one-sided, excluding Nyquist from doubling).
/// - No additional doubling is applied to non-edge bins here to match the
///   requested formula; adjust at call-site if desired.
Float32List computePsdOneSided(
  Float32List frame,
  Float32List window,
  int sampleRate,
) {
  final int n = frame.length;
  final re = Float32List(n);
  final im = Float32List(n);

  double sumW = 0.0;
  double sumW2 = 0.0;
  for (int i = 0; i < n; i++) {
    final w = window[i];
    sumW += w;
    sumW2 += w * w;
    re[i] = frame[i] * w;
  }
  // Window metrics for Welch normalization
  final double U = sumW2 / n; // average window power

  fftInPlace(re, im);

  final out = Float32List(n >> 1);
  // PSD normalization with Welch (per Hz)
  final denom = (n * sampleRate * U);
  final double invDen = denom > 0 ? 1.0 / denom : 0.0;

  for (int k = 0; k < out.length; k++) {
    final double mag2 = re[k] * re[k] + im[k] * im[k];
    // One-sided spectrum without Nyquist: double all bins except DC
    final double factor = (k == 0) ? 1.0 : 2.0;
    out[k] = (factor * mag2 * invDen).toDouble();
  }
  if (kWindowVerboseLogs) {
    debugPrint('Welch PSD: N=$n, sumW=${sumW.toStringAsFixed(3)}, sumW2=${sumW.toStringAsFixed(3)}, U=${U.toStringAsFixed(6)}');
  }
  return out;
}

/// Compute precise PSD per Hz using Welch normalization and ENBW correction.
/// Returns one-sided PSD [0..N/2-1] in linear power/Hz.
Float32List computePsdPerHzPrecise(
  Float32List frame,
  Float32List window,
  int sampleRate,
) {
  final int n = frame.length;
  final re = Float32List(n);
  final im = Float32List(n);

  // Window and metrics
  for (int i = 0; i < n; i++) {
    re[i] = frame[i] * window[i];
  }
  final wm = computeWindowMetrics(window);
  final double U = wm.U;

  fftInPlace(re, im);

  final out = Float32List(n >> 1);
  final binWidth = sampleRate / n; // Hz per FFT bin
  // Welch PSD normalization per Hz:
  // Pxx[k] = (2 / (Fs * N * U)) * |X[k]|^2, k>0 ; DC not doubled
  final double invDen = (sampleRate * n * U) > 0 ? 1.0 / (sampleRate * n * U) : 0.0;

  for (int k = 0; k < out.length; k++) {
    final double mag2 = re[k] * re[k] + im[k] * im[k];
  final double factor = (k == 0) ? 1.0 : 2.0;
  final pBin = factor * mag2 * invDen; // power per Hz already
  out[k] = pBin.toDouble();
  }

  if (kWindowVerboseLogs) {
    debugPrint('PSD precise: N=$n, Fs=$sampleRate, binWidth=${binWidth.toStringAsFixed(3)}Hz, U=${U.toStringAsExponential(3)}, ENBW_bins=${wm.enbwBins.toStringAsFixed(3)}');
  }
  return out;
}

/// Apply linear-domain exponential moving average (EMA) on power spectra
void emaLinearInPlace(Float32List target, Float32List current, double alpha) {
  assert(target.length == current.length);
  for (int i = 0; i < target.length; i++) {
    target[i] = (alpha * current[i] + (1 - alpha) * target[i]).toDouble();
  }
}

/// Compute integrated power in fixed frequency bands (Spectroid-compatible)
/// Returns power per band in dBFS, independent of FFT size N
Float32List computeIntegratedPowerBands(
  Float32List frame,
  Float32List window,
  int sampleRate,
) {
  final int n = frame.length;
  final re = Float32List(n);
  final im = Float32List(n);

  // Apply window and calculate normalization
  double sumW = 0.0;
  for (int i = 0; i < n; i++) {
    final w = window[i];
    sumW += w;
    re[i] = frame[i] * w;
  }
  final coherentGain = sumW / n;

  fftInPlace(re, im);

  // Define fixed frequency bands (independent of N)
  final List<double> bandEdges = _generateFrequencyBands(sampleRate);
  final deltaF = sampleRate / n; // Hz per bin
  final out = Float32List(bandEdges.length - 1);

  // Integrate power in each band
  for (int band = 0; band < out.length; band++) {
    final fLow = bandEdges[band];
    final fHigh = bandEdges[band + 1];
    final kLow = (fLow / deltaF).floor().clamp(0, n ~/ 2 - 1);
    final kHigh = (fHigh / deltaF).ceil().clamp(kLow + 1, n ~/ 2);
    
    double bandPower = 0.0;
    for (int k = kLow; k < kHigh; k++) {
      final mag2 = re[k] * re[k] + im[k] * im[k];
      // Spectroid-style normalization: |X|²/N² * bandwidth compensation
      final powerPerBin = mag2 / (n * n * coherentGain * coherentGain);
      bandPower += powerPerBin;
    }
    
    // Normalize by band width to get power density, then integrate back
    final bandWidth = fHigh - fLow;
    out[band] = (bandPower * bandWidth / (kHigh - kLow)).toDouble();
  }

  if (kWindowVerboseLogs) {
    debugPrint('Integrated bands: ${out.length} bands, deltaF=${deltaF.toStringAsFixed(2)}Hz, coherentGain=${coherentGain.toStringAsFixed(3)}');
  }
  return out;
}

/// Generate frequency band edges for Spectroid-compatible display
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
  
  // 1-20 kHz: 1/24 octave bands (approximately)
  double f = 1000;
  while (f < nyquist && f < 20000) {
    f *= 1.029; // ~1/24 octave step
    bands.add(f);
  }
  
  // Ensure we end at Nyquist
  if (bands.last < nyquist) {
    bands.add(nyquist);
  }
  
  return bands;
}

void fftInPlace(Float32List re, Float32List im) {
  final n = re.length;
  if (n <= 1) return;
  int j = 0;
  for (int i = 0; i < n; i++) {
    if (i < j) {
      final tr = re[i];
      final ti = im[i];
      re[i] = re[j];
      im[i] = im[j];
      re[j] = tr;
      im[j] = ti;
    }
    int m = n >> 1;
    while (m >= 1 && j >= m) {
      j -= m;
      m >>= 1;
    }
    j += m;
  }

  for (int size = 2; size <= n; size <<= 1) {
    final half = size >> 1;
    final step = (2 * math.pi) / size;
    for (int i = 0; i < n; i += size) {
      for (int k = 0; k < half; k++) {
        final angle = step * k;
        final wr = math.cos(angle);
        final wi = -math.sin(angle);
        final j = i + k;
        final l = j + half;
        final tr = wr * re[l] - wi * im[l];
        final ti = wr * im[l] + wi * re[l];
        re[l] = re[j] - tr;
        im[l] = im[j] - ti;
        re[j] += tr;
        im[j] += ti;
      }
    }
  }
}

Float32List computeMagnitude(Float32List frame, Float32List window) {
  final n = frame.length;
  final re = Float32List(n);
  final im = Float32List(n);
  
  // Calculate window gain (sum of window coefficients)
  double windowGain = 0.0;
  for (int i = 0; i < n; i++) {
    windowGain += window[i];
    re[i] = frame[i] * window[i];
  }
  
  fftInPlace(re, im);
  
  // Single-sided amplitude spectrum normalization:
  // For a full-scale sine, |FFT[k0]| ≈ sum(window)/2 at the true bin.
  // So amplitude A ≈ |FFT| * (2 / sum(window)).
  // For DC and Nyquist (if present), use 1/sum(window).
  final r = Float32List(n ~/ 2);
  final scaleGeneral = windowGain > 0 ? (2.0 / windowGain) : 0.0;
  final scaleEdge = windowGain > 0 ? (1.0 / windowGain) : 0.0;

  double maxMag = 0.0;
  double minMag = double.infinity;
  for (int i = 0; i < r.length; i++) {
    final mag = math.sqrt(re[i] * re[i] + im[i] * im[i]);
    // DC (k=0) should not be doubled; only positive frequencies get factor 2
    // Nyquist (if present at k=N/2) also should not be doubled
    final bool isDC = (i == 0);
    final bool isNyquist = (n.isEven && i == r.length - 1);
    final scaled = mag * ((isDC || isNyquist) ? scaleEdge : scaleGeneral);
    r[i] = scaled;
    if (scaled > maxMag) maxMag = scaled;
    if (scaled < minMag) minMag = scaled;
  }
  
  // Debug logging for normalization analysis
  if (kWindowVerboseLogs) {
    debugPrint('FFT: windowGain=${windowGain.toStringAsFixed(3)}, scale=2/sum=${(scaleGeneral).toStringAsExponential(3)}, minMag=${minMag.toStringAsExponential(3)}, maxMag=${maxMag.toStringAsExponential(3)}');
  }
  if (kWindowVerboseLogs && minMag > 0) {
    // Convert to power dB (10*log10) for consistency with PSD dB/Hz
    final minDb = 10 * math.log(minMag * minMag + 1e-20) / math.ln10;
    final maxDb = 10 * math.log(maxMag * maxMag + 1e-20) / math.ln10;
    debugPrint('FFT dB range: ${minDb.toStringAsFixed(1)} to ${maxDb.toStringAsFixed(1)} dB (power)');
  }
  
  return r;
}
