import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tuner/features/tuner/core/pipeline/processor.dart';
import 'package:flutter_tuner/features/tuner/core/pipeline/lock_tracker.dart';
import 'package:flutter_tuner/features/tuner/core/note_utils.dart';

void main() {
  group('PitchPostProcessor', () {
    test('median smoothing and anti-octave folding', () {
      final p = PitchPostProcessor(windowSize: 5, octaveThreshold: 1.6);
      // Feed values around 440 with an octave jump to 880 and back
      final seq = [438.0, 441.0, 440.5, 880.0, 439.5, 440.0];
      final out = seq.map(p.process).toList();
      // The 880 should get folded near 440 region
      expect(out[3], lessThan(600));
    });
  });

  group('LockTracker', () {
    test('locks after stable frames within tolerance', () {
      final t = LockTracker(centsTolerance: 5, stableCountRequired: 3);
      final centsSeq = [12.0, 7.0, 4.0, 3.0, 2.0, 10.0];
      final conf = [0.9, 0.9, 0.9, 0.9, 0.9, 0.9];
      final res = <bool>[];
      for (var i = 0; i < centsSeq.length; i++) {
        res.add(t.update(centsSeq[i], conf[i]));
      }
      expect(res[2], isFalse); // first within-tolerance frame
      expect(res[3], isFalse); // second within-tolerance frame
      expect(res[4], isTrue);  // third stable frame -> lock
      // It should unlock when out of tolerance
      final unlocked = t.update(10.0, 0.9);
      expect(unlocked, isFalse);
      expect(t.isLocked, isFalse);
    });
  });

  test('note_utils analyzeFrequency maps to nearest note', () {
    final info = analyzeFrequency(440.0);
    expect(info.name, equals('A'));
    expect(info.octave, equals(4));
    expect(info.cents.abs(), lessThan(1e-6));
  });
}
