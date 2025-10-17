import 'dart:math' as math;

class ComplexArray {
  ComplexArray(int n)
      : re = List<double>.filled(n, 0.0),
        im = List<double>.filled(n, 0.0);
  final List<double> re;
  final List<double> im;
  int get length => re.length;
}

/// In-place Radix-2 Cooley–Tukey FFT. `sign`= -1 for forward, +1 for inverse.
void fftRadix2(ComplexArray a, {int sign = -1}) {
  final n = a.length;
  assert(n > 0 && (n & (n - 1)) == 0, 'FFT size must be power of 2');
  // Bit-reversal permutation
  var j = 0;
  for (var i = 1; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j &= ~bit;
    }
    j |= bit;
    if (i < j) {
      final tr = a.re[i];
      final ti = a.im[i];
      a.re[i] = a.re[j];
      a.im[i] = a.im[j];
      a.re[j] = tr;
      a.im[j] = ti;
    }
  }
  // Danielson–Lanczos
  for (var len = 2; len <= n; len <<= 1) {
    final ang = 2 * math.pi / len * sign;
    final wlenRe = math.cos(ang);
    final wlenIm = math.sin(ang);
    for (var i = 0; i < n; i += len) {
      var wRe = 1.0;
      var wIm = 0.0;
      for (var j2 = 0; j2 < len ~/ 2; j2++) {
        final uRe = a.re[i + j2];
        final uIm = a.im[i + j2];
        final vRe =
            a.re[i + j2 + len ~/ 2] * wRe - a.im[i + j2 + len ~/ 2] * wIm;
        final vIm =
            a.re[i + j2 + len ~/ 2] * wIm + a.im[i + j2 + len ~/ 2] * wRe;
        a.re[i + j2] = uRe + vRe;
        a.im[i + j2] = uIm + vIm;
        a.re[i + j2 + len ~/ 2] = uRe - vRe;
        a.im[i + j2 + len ~/ 2] = uIm - vIm;
        // w *= wlen
        final nwRe = wRe * wlenRe - wIm * wlenIm;
        final nwIm = wRe * wlenIm + wIm * wlenRe;
        wRe = nwRe;
        wIm = nwIm;
      }
    }
  }
  // Scale for inverse
  if (sign == 1) {
    for (var i = 0; i < n; i++) {
      a.re[i] /= n;
      a.im[i] /= n;
    }
  }
}

class PsdResult {
  PsdResult(
      {required this.freqsHz, required this.dbPerHz, required this.power});
  final List<double> freqsHz; // bin center frequencies
  final List<double> dbPerHz; // 10*log10(power_density)
  final List<double> power; // linear power per bin (for further processing)
}

/// Compute single-sided PSD from a real frame with Hann window.
PsdResult computePsd({
  required List<double> frame,
  required List<double> hann,
  required double fs,
}) {
  final n = frame.length;
  final ca = ComplexArray(n);
  for (var i = 0; i < n; i++) {
    ca.re[i] = frame[i] * hann[i];
  }
  fftRadix2(ca, sign: -1);

  final half = n ~/ 2;
  final binHz = fs / n;

  // Power spectrum magnitude^2, single-sided.
  final power = List<double>.filled(half + 1, 0.0);
  for (var k = 0; k <= half; k++) {
    final re = ca.re[k];
    final im = ca.im[k];
    var p = (re * re + im * im) / (n * n); // normalize by N^2 for FFT scaling
    if (k != 0 && k != half) {
      p *= 2; // double for single-sided except DC/Nyquist
    }
    power[k] = p;
  }

  // Correct for window power and ENBW.
  double winPower = 0.0;
  for (final w in hann) {
    winPower += w * w;
  }
  final enbwBins = 1.5; // Hann approx
  final enbwHz = enbwBins * binHz;

  final db = List<double>.filled(half + 1, 0.0);
  final freqs = List<double>.filled(half + 1, 0.0);
  for (var k = 0; k <= half; k++) {
    final density = power[k] / (winPower / n) / enbwHz; // W/Hz like density
    final v = density <= 0 ? -300.0 : 10 * math.log(density) / math.log(10);
    db[k] = v;
    freqs[k] = k * binHz;
  }

  return PsdResult(freqsHz: freqs, dbPerHz: db, power: power);
}
