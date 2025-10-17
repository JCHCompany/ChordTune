import 'dart:math' as math;

/// Simple linear-phase lowpass FIR using windowed-sinc, even length.
List<double> designFirLowpass({required double fc, required int taps}) {
  assert(fc > 0 && fc < 0.5);
  assert(taps.isOdd, 'Use odd taps for symmetric linear-phase.');
  final m = taps - 1;
  final h = List<double>.filled(taps, 0.0);
  double sum = 0.0;
  for (var n = 0; n < taps; n++) {
    final k = n - m / 2.0;
    final sinc = k == 0 ? 2 * math.pi * fc : math.sin(2 * math.pi * fc * k) / k;
    // Hann window on FIR to control sidelobes.
    final w = 0.5 * (1 - math.cos(2 * math.pi * n / m));
    h[n] = sinc * w;
    sum += h[n];
  }
  // Normalize DC gain to 1.
  for (var i = 0; i < h.length; i++) {
    h[i] /= sum;
  }
  return h;
}

class FirDecimator {
  FirDecimator({required int factor, required List<double> coeffs})
      : _factor = factor,
        _h = List<double>.from(coeffs),
        _z = List<double>.filled(coeffs.length, 0.0);

  final int _factor;
  final List<double> _h;
  final List<double> _z;

  int get factor => _factor;

  /// Process input and return decimated output.
  List<double> process(List<double> input) {
    final out = <double>[];
    for (final x in input) {
      // shift
      for (var i = _z.length - 1; i > 0; i--) {
        _z[i] = _z[i - 1];
      }
      _z[0] = x;
      // Only output every factor samples.
      if ((_produced + 1) % _factor == 0) {
        double y = 0.0;
        for (var i = 0; i < _h.length; i++) {
          y += _h[i] * _z[i];
        }
        out.add(y);
      }
      _produced++;
    }
    return out;
  }

  int _produced = 0;
}

/// Construct a chain of decimators for multi-rate processing similar to Spectroid.
class MultiRateDecimator {
  MultiRateDecimator({required int levels}) : _levels = levels.clamp(0, 9) {
    // Each stage decimates by 2 with a reasonably steep FIR.
    // For rate stability, we use 63 taps per stage and cutoff at 0.45 of Nyquist per stage.
    for (var i = 0; i < _levels; i++) {
      final coeffs = designFirLowpass(fc: 0.45, taps: 63);
      _stages.add(FirDecimator(factor: 2, coeffs: coeffs));
    }
  }

  final int _levels;
  final List<FirDecimator> _stages = [];

  /// Returns the decimated signal after all stages and the overall decimation factor.
  (List<double> y, int factor) process(List<double> x) {
    var sig = x;
    for (final s in _stages) {
      sig = s.process(sig);
    }
    final f = 1 << _levels; // 2^levels
    return (sig, f);
  }
}
