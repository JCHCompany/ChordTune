import 'dart:collection';
import 'dart:math' as math;

/// Simple sliding median smoothing and anti-octave correction.

class PitchPostProcessor {
  // Sliding median parameters
  final int windowSize;
  final double octaveThreshold; // how far from median to consider octave error

  // EMA smoothing: specify the hop length in ms and desired time constant
  // to compute an alpha per-frame. Default hop ~80ms (half of 160ms block).
  final double hopMs;
  final double emaTimeConstantMs;

  final Queue<double> _window = Queue<double>();
  double? _ema;
  
  // Outlier rejection/clamping
  final double maxDeviationHz; // reject frames too far from median
  final double clampBandwidthHz; // softly clamp towards median within this band

  PitchPostProcessor({
    this.windowSize = 9, // more robust median (~720ms @80ms hop)
    this.octaveThreshold = 2.0, // stricter to avoid octave flips on rich signals
    this.hopMs = 80.0,
    this.emaTimeConstantMs = 90.0, // keep EMA snappy for responsiveness
    this.maxDeviationHz = 55.0, // reject implausible jumps vs median
    this.clampBandwidthHz = 20.0, // softly pull towards median
  });

  double process(double freqHz) {
    // Maintain window
    _window.addLast(freqHz);
    if (_window.length > windowSize) {
      _window.removeFirst();
    }

    final median = _median(_window);
    var f = freqHz;
    
    // Outlier rejection: if current sample is far from median, drop it
    if (median > 0 && (freqHz - median).abs() > maxDeviationHz) {
      // Use median instead of the erratic value
      f = median;
    }
    
    // Soft clamping towards median to reduce jitter
    if (median > 0 && (f - median).abs() > clampBandwidthHz) {
      final sign = (f >= median) ? 1.0 : -1.0;
      f = median + sign * clampBandwidthHz;
    }
    // Anti-octave: fold towards the median range
    if (median > 0) {
      // Special handling for guitar bass strings (E2~82Hz, A2~110Hz)
      // These often flip to sub-harmonics (E1~41Hz, A1~55Hz)
      if (f >= 38 && f <= 50 && median >= 75 && median <= 95) {
        // Likely E1 sub-harmonic → force up to E2
        f = f * 2.0;
      } else if (f >= 50 && f <= 65 && median >= 100 && median <= 125) {
        // Likely A1 sub-harmonic → force up to A2
        f = f * 2.0;
      }
      // Special handling for guitar high strings (B4~247Hz, E4~330Hz)
      // These often flip to harmonics (B5~494Hz, E5~659Hz)
      else if (f >= 480 && f <= 520 && median >= 230 && median <= 270) {
        // Likely B5 harmonic → force back to B4
        f = f / 2.0;
      } else if (f >= 640 && f <= 680 && median >= 310 && median <= 350) {
        // Likely E5 harmonic → force back to E4  
        f = f / 2.0;
      } else {
        // Standard anti-octave logic - now bidirectional
        while (f > median * octaveThreshold) {
          f /= 2.0;
        }
        while (f < median / octaveThreshold) {
          f *= 2.0;
        }
      }
    }

    // EMA smoothing: compute alpha from time constant
    final alpha = 1 - math.exp(-hopMs / (emaTimeConstantMs + 1e-9));
    if (_ema == null) {
      _ema = f;
    } else {
      _ema = alpha * f + (1 - alpha) * _ema!;
    }
    return _ema ?? f;
  }

  static double _median(Iterable<double> values) {
    if (values.isEmpty) return 0;
    final sorted = values.toList()..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2.0;
  }
}
