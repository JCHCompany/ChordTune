import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tuner/features/tuner/core/dsp/autocorrelation.dart';

List<double> _sine(double freq, int sr, int n) {
  return List<double>.generate(n, (i) => math.sin(2 * math.pi * freq * i / sr));
}

void main() {
  test('autocorrelation estimates A4 ~440Hz', () {
    final sr = 48000;
    final x = _sine(440.0, sr, 4096);
    final est = estimatePitchAutocorrelation(x, sr, minHz: 50, maxHz: 1000);
    expect(est, isNotNull);
    expect(est!.frequencyHz, closeTo(440.0, 2.0));
    expect(est.confidence, greaterThan(0.8));
  });

  test('autocorrelation rejects silence', () {
    final sr = 44100;
    final x = List<double>.filled(4096, 0.0);
    final est = estimatePitchAutocorrelation(x, sr);
    expect(est, isNull);
  });
}
