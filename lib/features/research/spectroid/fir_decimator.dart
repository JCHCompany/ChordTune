import 'dart:math' as math;
import 'dart:typed_data';

class DecimatorFIR {
  final int M; // decimation factor 1,2,4,8
  final int taps;
  final double cutoff; // normalized to Nyquist (0..1)
  final double beta; // Kaiser beta
  late final Float64List h; // filter coefficients
  late final Float64List _buf;
  int _idx = 0;
  int _phase = 0;

  DecimatorFIR({required this.M, this.taps = 129, double? cutoff, this.beta = 8.6})
      : cutoff = cutoff ?? (0.45 / M) {
    h = _designLowpassKaiser(taps, this.cutoff, beta);
    _buf = Float64List(taps);
  }

  // Process one sample; returns a decimated output when available, otherwise null
  double? processSample(double x) {
    _buf[_idx] = x;
    _idx = (_idx + 1) % taps;
    _phase++;
    if (_phase % M != 0) return null;

    // Convolution centered at current index (circular buffer)
    double acc = 0.0;
    int bi = _idx; // points to the oldest sample
    for (int i = 0; i < taps; i++) {
      if (--bi < 0) bi = taps - 1;
      acc += h[i] * _buf[bi];
    }
    return acc;
  }

  // Design a lowpass using windowed-sinc with Kaiser window
  static Float64List _designLowpassKaiser(int N, double fc, double beta) {
    final h = Float64List(N);
    final m = (N - 1) / 2.0;
    final denom = _besseli0(beta);
    for (int n = 0; n < N; n++) {
      final k = n - m;
      final w = _besseli0(beta * math.sqrt(1 - math.pow((n - m) / m, 2))) / denom;
      final sinc = (k == 0)
          ? 2 * fc
          : math.sin(2 * math.pi * fc * k) / (math.pi * k);
      h[n] = w * sinc;
    }
    // Normalize DC gain to 1
    double sum = 0.0;
  for (final v in h) { sum += v; }
  for (int i = 0; i < N; i++) { h[i] /= sum; }
    return h;
  }

  static double _besseli0(double x) {
    final ax = x.abs();
    if (ax < 3.75) {
      final y = (x / 3.75) * (x / 3.75);
      return 1.0 + y * (3.5156229 + y * (3.0899424 + y * (1.2067492 + y * (0.2659732 + y * (0.0360768 + y * 0.0045813)))));
    } else {
      final y = 3.75 / ax;
      final p = [
        0.39894228,
        0.01328592,
        0.00225319,
        -0.00157565,
        0.00916281,
        -0.02057706,
        0.02635537,
        -0.01647633,
        0.00392377,
      ];
      double poly = p.last;
      for (int i = p.length - 2; i >= 0; i--) {
        poly = p[i] + y * poly;
      }
      return (math.exp(ax) / math.sqrt(ax)) * poly;
    }
  }
}
