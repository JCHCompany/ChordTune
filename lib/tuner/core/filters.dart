import 'dart:math' as math;

/// Simple DC blocker: y[n] = x[n] - x[n-1] + R * y[n-1]
/// R close to 1.0 (e.g., 0.995) gives ~20 Hz cutoff at 48 kHz.
class DcBlocker {
  DcBlocker({double r = 0.995}) : _r = r;
  final double _r;
  double _x1 = 0.0;
  double _y1 = 0.0;

  void reset() {
    _x1 = 0.0;
    _y1 = 0.0;
  }

  double process(double x) {
    final y = x - _x1 + _r * _y1;
    _x1 = x;
    _y1 = y;
    return y;
  }

  void processInPlace(List<double> buffer) {
    for (var i = 0; i < buffer.length; i++) {
      buffer[i] = process(buffer[i]);
    }
  }
}

/// Single IIR notch at 50/60 Hz with given Q.
class NotchIir {
  NotchIir({required double fs, required double f0, double q = 30})
      : assert(fs > 0 && f0 > 0),
        _fs = fs,
        _f0 = f0,
        _q = q {
    _design();
  }

  final double _fs;
  final double _f0;
  final double _q;

  // biquad Direct Form I
  double _b0 = 1, _b1 = 0, _b2 = 1;
  double _a0 = 1, _a1 = 0, _a2 = 1;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  void _design() {
    final w0 = 2 * math.pi * _f0 / _fs;
    final alpha = math.sin(w0) / (2 * _q);
    final cosw0 = math.cos(w0);
    _b0 = 1;
    _b1 = -2 * cosw0;
    _b2 = 1;
    _a0 = 1 + alpha;
    _a1 = -2 * cosw0;
    _a2 = 1 - alpha;
  }

  void reset() {
    _x1 = _x2 = _y1 = _y2 = 0.0;
  }

  double process(double x) {
    final y = (_b0 / _a0) * x +
        (_b1 / _a0) * _x1 +
        (_b2 / _a0) * _x2 -
        (_a1 / _a0) * _y1 -
        (_a2 / _a0) * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }

  void processInPlace(List<double> buffer) {
    for (var i = 0; i < buffer.length; i++) {
      buffer[i] = process(buffer[i]);
    }
  }
}

/// Hann window utilities.
class HannWindow {
  static List<double> generate(int n) {
    final w = List<double>.filled(n, 0.0);
    for (var i = 0; i < n; i++) {
      w[i] = 0.5 * (1 - math.cos(2 * math.pi * i / (n - 1)));
    }
    return w;
  }

  /// Equivalent noise bandwidth correction factor for Hann (~1.5 bins). See docs.
  static double enbwBins = 1.5;
}

/// Exponential moving average in linear power domain.
class Ema {
  Ema(double tauMs, double fs, int fftSize)
      : _alpha = _computeAlpha(tauMs: tauMs, frameSamples: fftSize ~/ 2) {
    _state = <double>[];
  }

  static double _computeAlpha(
      {required double tauMs, required int frameSamples}) {
    // For simplicity, tie smoothing step to frame length.
    final tau = math.max(1.0, tauMs);
    final k = 1.0 / (tau / 10.0 + 1.0); // bounded alpha in (0,1]
    return k.clamp(0.001, 1.0);
  }

  late final double _alpha;
  late List<double> _state;

  List<double> apply(List<double> power) {
    if (_state.isEmpty) {
      _state = List<double>.from(power);
      return _state;
    }
    final out = List<double>.filled(power.length, 0.0);
    for (var i = 0; i < power.length; i++) {
      _state[i] = _alpha * power[i] + (1 - _alpha) * _state[i];
      out[i] = _state[i];
    }
    return out;
  }
}
