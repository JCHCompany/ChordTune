import 'dart:typed_data';

class YinResult {
  final double f0;
  final double confidence; // 0..1
  const YinResult(this.f0, this.confidence);
}

/// Real-time YIN implementation with reusable buffers (difference + CMND).
class YinDetector {
  final int sampleRate;
  final int windowSize;
  final int hopSize;
  final double threshold; // CMND threshold (e.g., 0.15)
  late final Float64List _buffer; // working difference / CMND
  late final Float64List _cumsum;

  YinDetector({
    required this.sampleRate,
    required this.windowSize,
    required this.hopSize,
    required this.threshold,
  }) {
    _buffer = Float64List(windowSize ~/ 2 + 2);
    _cumsum = Float64List(windowSize ~/ 2 + 2);
  }

  /// Process a frame; frame length must be >= windowSize.
  YinResult process(Float32List frame) {
    if (frame.length < windowSize) {
      return const YinResult(0.0, 0.0);
    }
    final half = windowSize ~/ 2;
    // Difference function d(tau)
    for (int tau = 0; tau <= half; tau++) {
      double sum = 0.0;
      for (int i = 0; i < half; i++) {
        final diff = frame[i] - frame[i + tau];
        sum += diff * diff;
      }
      _buffer[tau] = sum;
    }
    // Cumulative mean normalized difference
    _buffer[0] = 1.0;
    double running = 0.0;
    for (int tau = 1; tau <= half; tau++) {
      running += _buffer[tau];
      final cmnd = _buffer[tau] * tau / (running == 0 ? 1 : running);
      _cumsum[tau] = cmnd;
    }
    int tauCandidate = -1;
    for (int tau = 2; tau <= half; tau++) {
      if (_cumsum[tau] < threshold) {
        while (tau + 1 <= half && _cumsum[tau + 1] < _cumsum[tau]) {
          tau++;
        }
        tauCandidate = tau;
        break;
      }
    }
    if (tauCandidate == -1) {
      return const YinResult(0.0, 0.0);
    }
    // Parabolic interpolation
    final tau = tauCandidate;
    double betterTau = tau.toDouble();
    if (tau > 1 && tau + 1 <= half) {
      final s0 = _cumsum[tau - 1];
      final s1 = _cumsum[tau];
      final s2 = _cumsum[tau + 1];
      final denom = (2 * s1 - s2 - s0);
      if (denom.abs() > 1e-12) {
        betterTau = tau + (s2 - s0) / (2 * denom);
      }
    }
    final f0 = sampleRate / betterTau;
    // Confidence: 1 - CMND at tau
    final conf = (1.0 - _cumsum[tauCandidate]).clamp(0.0, 1.0);
    return YinResult(f0.isFinite ? f0 : 0.0, conf);
  }
}
