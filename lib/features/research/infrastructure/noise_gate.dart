import 'dart:typed_data';
import 'dart:math' as math;

class MinStatsNoiseGate {
  final double alpha; // gate strength (e.g., 0.8)
  final double rise;  // slow rise factor towards higher noise floor
  final double windowSec; // conceptual window for comments only

  Float32List? _noise;

  MinStatsNoiseGate({this.alpha = 0.8, this.rise = 0.005, this.windowSec = 1.5});

  // Update noise estimate and return a simple voice score in [0,1]
  double updateAndScore(Float32List mag, double binHz, {double fLo = 60, double fHi = 3000}) {
    if (_noise == null || _noise!.length != mag.length) {
      _noise = Float32List(mag.length);
      for (int i = 0; i < mag.length; i++) {
        _noise![i] = mag[i];
      }
    }
    // Update noise estimate with biased min + slow rise
    for (int i = 0; i < mag.length; i++) {
      final n = _noise![i];
      final x = mag[i];
      if (x < n) {
        _noise![i] = x; // drop quickly
      } else {
        _noise![i] = n + rise * (x - n); // rise slowly
      }
    }
    // Compute per-bin gate and aggregate score over band
    final eps = 1e-12;
    int iLo = math.max(0, (fLo / binHz).floor());
    int iHi = math.min(mag.length - 1, (fHi / binHz).ceil());
    double sum = 0.0;
    int count = 0;
    for (int i = iLo; i <= iHi; i++) {
      final g = math.max(1.0 - alpha * (_noise![i] / (mag[i] + eps)), 0.0);
      sum += g;
      count++;
    }
    return count > 0 ? (sum / count) : 0.0;
  }
}
