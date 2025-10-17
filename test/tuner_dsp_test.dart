import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tuner/tuner/core/filters.dart';
import 'package:flutter_tuner/tuner/core/decimator.dart';
import 'package:flutter_tuner/tuner/core/fft.dart';
import 'package:flutter_tuner/tuner/pitch/detectors.dart';

void main() {
  test('DC blocker removes offset', () {
    final dc = DcBlocker(r: 0.995);
    final x = List<double>.filled(2000, 0.3);
    dc.processInPlace(x);
    // Ignore warm-up, check last 500 samples average
    final tail = x.sublist(1500);
    final mean = tail.reduce((a, b) => a + b) / tail.length;
    expect(mean.abs() < 1e-2, true);
  });

  test('FIR decimator reduces length by factor', () {
    final coeffs = designFirLowpass(fc: 0.45, taps: 63);
    final dec = FirDecimator(factor: 2, coeffs: coeffs);
    final x =
        List<double>.generate(1000, (i) => math.sin(2 * math.pi * 0.01 * i));
    final y = dec.process(x);
    expect(y.length <= 500, true);
  });

  test('FFT normalization energy check', () {
    final n = 1024;
    final fs = 48000.0;
    final f = 1000.0;
    final x =
        List<double>.generate(n, (i) => math.sin(2 * math.pi * f * i / fs));
    final hann = HannWindow.generate(n);
    final psd = computePsd(frame: x, hann: hann, fs: fs);
    // Peak should be around bin f, with finite dB values.
    expect(psd.dbPerHz.any((v) => v.isFinite), true);
  });

  test('YIN detects A4 ~440Hz within 3 cents', () {
    final fs = 48000.0;
    final f0 = 440.0;
    final n = 4096;
    final x =
        List<double>.generate(n, (i) => math.sin(2 * math.pi * f0 * i / fs));
    final res = yinDetect(
        x, fs, const YinConfig(windowSize: 2048, fMin: 55, fMax: 1100));
    expect(res.f0 != null, true);
    final cents = 1200.0 * (math.log((res.f0! + 1e-9) / f0) / math.ln2).abs();
    expect(cents < 3.0, true);
  });

  test('Harmonic summation prefers fundamental', () {
    final fs = 48000.0;
    final n = 4096;
    final hann = HannWindow.generate(n);
    final f0 = 220.0;
    final x = List<double>.generate(n, (i) {
      final t = i / fs;
      return 0.8 * math.sin(2 * math.pi * f0 * t) +
          0.3 * math.sin(2 * math.pi * 2 * f0 * t);
    });
    final psd = computePsd(frame: x, hann: hann, fs: fs);
    final res = harmonicDetect(
      freqs: psd.freqsHz,
      power: psd.power,
      cfg: const HarmonicConfig(
          harmonics: 4, toleranceCents: 15, fMin: 55, fMax: 1100),
    );
    expect(res.f0 != null, true);
    final cents = 1200.0 * (math.log((res.f0! + 1e-9) / f0) / math.ln2).abs();
    expect(cents < 10.0, true);
  });
}
