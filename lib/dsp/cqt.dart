import 'dart:math' as math;
import 'dart:typed_data';

/// Lightweight FFT-based logarithmic frequency projection approximating a CQT.
/// For performance and low allocation, we simply sample the existing FFT magnitude
/// at the closest bin (optionally with a 3-point parabolic refinement) rather than
/// performing full variable-Q kernels. This yields sufficient resolution for
/// harmonic salience / pitch tracking while keeping CPU low.
class CQTTransformer {
  final double fMin;
  final double fMax;
  final int binsPerOctave;
  final int fftSize;
  final int sampleRate;
  late final List<double> _freqs; // center freqs per log bin
  late final List<int> _binIndices; // nearest FFT bin index per log bin
  late final Float32List _out; // reusable output buffer (power values)

  CQTTransformer({
    required this.fMin,
    required this.fMax,
    required this.binsPerOctave,
    required this.fftSize,
    required this.sampleRate,
  }) {
    _buildMapping();
  }

  void _buildMapping() {
    final nyquist = sampleRate / 2.0;
    final maxF = math.min(fMax, nyquist - 1);
    final octaves = math.log(maxF / fMin) / math.ln2;
    final totalBins = (octaves * binsPerOctave).ceil();
    _freqs = List.generate(totalBins, (i) => fMin * math.pow(2.0, i / binsPerOctave));
    final binHz = sampleRate / fftSize;
    _binIndices = _freqs.map((f) => (f / binHz).clamp(1, (fftSize / 2 - 1)).floor()).toList();
    _out = Float32List(totalBins);
  }

  int get length => _out.length;
  List<double> get freqs => _freqs;

  /// Compute power per log-frequency bin from a linear FFT magnitude array (amplitude, not power).
  /// [fftMag] expected length N/2 (one-sided) aligned with engine's computeMagnitude output.
  Float32List computeFromFFT(Float32List fftMag) {
    final n = _out.length;
    for (int i = 0; i < n; i++) {
      final k = _binIndices[i];
      // Parabolic interpolation around bin k for refined amplitude (if possible)
      double a = fftMag[k];
      if (k > 0 && k + 1 < fftMag.length) {
        final am1 = fftMag[k - 1];
        final ap1 = fftMag[k + 1];
        final denom = (am1 - 2 * a + ap1);
        double delta = 0.0;
        if (denom.abs() > 1e-12) {
          delta = 0.5 * (am1 - ap1) / denom; // shift in bins
        }
        final refined = a - 0.25 * (am1 - ap1) * delta; // vertex amplitude approx
        a = refined;
      }
      final power = a * a; // amplitude^2 -> linear power
      _out[i] = power;
    }
    return _out;
  }
}
