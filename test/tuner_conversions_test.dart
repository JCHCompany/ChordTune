import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tuner/features/tuner/core/conversions.dart';

void main() {
  group('PitchConversions', () {
    test('A4 midi 69 ↔ 440Hz', () {
      expect(PitchConversions.midiToHz(69), closeTo(440.0, 1e-9));
      expect(PitchConversions.hzToMidi(440), closeTo(69.0, 1e-9));
    });

    test('Cents between two freqs', () {
      // 100 cents equals one semitone up: 440 -> 466.1637615
      final up100 = 440.0 * math.pow(2, 100 / 1200);
      expect(PitchConversions.centsBetween(up100, 440.0), closeTo(100.0, 1e-6));
    });
  });
}

