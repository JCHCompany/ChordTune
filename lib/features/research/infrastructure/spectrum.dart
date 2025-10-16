import 'dart:math' as math;
import 'dart:typed_data';

class SpectrumUtils {
  static void fftInPlace(Float32List re, Float32List im) {
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

  static Float32List magnitude(Float32List x) {
    // zero-pad to next power of two
    int n = 1;
    while (n < x.length) {
      n <<= 1;
    }
    final re = Float32List(n);
    final im = Float32List(n);
    for (int i = 0; i < x.length; i++) {
      re[i] = x[i];
    }
    // Hann window
    for (int i = 0; i < x.length; i++) {
      final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (x.length - 1));
      re[i] *= w;
    }
    fftInPlace(re, im);
    final m = Float32List(n ~/ 2);
    for (int i = 0; i < m.length; i++) {
      m[i] = math.sqrt(re[i] * re[i] + im[i] * im[i]);
    }
    return m;
  }

  static Float32List whiten(Float32List mag, {int smoothBins = 15}) {
    final out = Float32List(mag.length);
    double env = mag[0];
    final alpha = 1.0 / smoothBins;
    for (int i = 0; i < mag.length; i++) {
      env = (1 - alpha) * env + alpha * mag[i];
      out[i] = env > 1e-6 ? mag[i] / env : 0.0;
    }
    return out;
  }

  static double harmonicEnergy(Float32List mag, double f0, int fs, {int h = 1}) {
    final binHz = fs / (2 * mag.length);
    final f = f0 * h;
    if (f <= 0) return 0.0;
    final bin = (f / binHz).round();
    double sum = 0.0;
    for (int i = bin - 2; i <= bin + 2; i++) {
      if (i >= 0 && i < mag.length) sum += mag[i];
    }
    return sum / 5.0;
  }
}