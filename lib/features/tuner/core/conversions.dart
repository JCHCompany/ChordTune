import 'dart:math' as math;

/// Equal temperament pitch conversions and cents helpers.
class PitchConversions {
  const PitchConversions._();

  /// MIDI note to frequency in Hz.
  static double midiToHz(num midi, {double a4 = 440.0}) {
    return a4 * math.pow(2, (midi - 69) / 12.0).toDouble();
  }

  /// Frequency in Hz to MIDI note (can be fractional).
  static double hzToMidi(num hz, {double a4 = 440.0}) {
    return 69 + 12 * (math.log(hz / a4) / math.ln2);
  }

  /// Cents difference between two frequencies.
  /// Positive when [hz] > [refHz].
  static double centsBetween(num hz, num refHz) {
    return 1200 * (math.log(hz / refHz) / math.ln2);
  }
}
