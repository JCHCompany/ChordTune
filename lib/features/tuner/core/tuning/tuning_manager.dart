import 'dart:math' as math;
import '../conversions.dart';
import 'tuning_preset.dart';

class TuningManager {
  TuningPreset _active = BuiltInTunings.standard;
  // Per-string offsets in semitones (MIDI delta), length must match preset strings
  final List<double> _offsets = List.filled(6, 0.0);

  TuningPreset get active => _active;
  List<double> get offsets => List.unmodifiable(_offsets);

  void setActive(TuningPreset preset) {
    _active = preset;
    // Reset offsets when tuning changes
    for (int i = 0; i < _offsets.length; i++) {
      _offsets[i] = 0.0;
    }
  }

  // Replace offsets from persistence (length will be clamped to available strings)
  void setOffsets(List<double> values) {
    final n = math.min(values.length, _offsets.length);
    for (int i = 0; i < n; i++) {
      _offsets[i] = values[i];
    }
  }

  // Map frequency to nearest string index and compute cents vs target+offset
  TuningEvaluation evaluate(double hz, {double a4 = 440}) {
    final parsed = _active.notes.map((n) => parseNoteLabel(n, a4: a4)).toList();
    // Find nearest target in MIDI space
    final midi = PitchConversions.hzToMidi(hz, a4: a4);
    int bestIdx = 0;
    double bestDist = double.infinity;
    for (int i = 0; i < parsed.length; i++) {
      final targetMidi = parsed[i].midi + _offsets[i];
      final dist = (midi - targetMidi).abs();
      if (dist < bestDist) {
        bestDist = dist;
        bestIdx = i;
      }
    }
    // Compute target Hz including offset
    final targetMidi = parsed[bestIdx].midi + _offsets[bestIdx];
    final targetHz = PitchConversions.midiToHz(targetMidi, a4: a4);
    final cents = PitchConversions.centsBetween(hz, targetHz);
    return TuningEvaluation(
      stringIndex: bestIdx,
      stringLabel: parsed[bestIdx].label,
      targetHz: targetHz,
      cents: cents,
      midiTarget: targetMidi,
    );
  }

  // Evaluate frequency against a specific string index (without nearest selection)
  TuningEvaluation evaluateForIndex(double hz, int index, {double a4 = 440}) {
    final parsed = _active.notes.map((n) => parseNoteLabel(n, a4: a4)).toList();
    final idx = index.clamp(0, parsed.length - 1);
    final targetMidi = parsed[idx].midi + _offsets[idx];
    final targetHz = PitchConversions.midiToHz(targetMidi, a4: a4);
    final cents = PitchConversions.centsBetween(hz, targetHz);
    return TuningEvaluation(
      stringIndex: idx,
      stringLabel: parsed[idx].label,
      targetHz: targetHz,
      cents: cents,
      midiTarget: targetMidi,
    );
  }

  // Learn per-string offset (EMA in semitones) using measured midi
  void learnOffset(int stringIndex, double measuredHz, {double a4 = 440, double alpha = 0.1}) {
    final targetMidi = parseNoteLabel(_active.notes[stringIndex], a4: a4).midi.toDouble();
    final measuredMidi = PitchConversions.hzToMidi(measuredHz, a4: a4);
    final delta = measuredMidi - targetMidi; // positive-> sharp vs target
    _offsets[stringIndex] = 0.9 * _offsets[stringIndex] + 0.1 * delta;
  }

  // Auto-capo detection: if all offsets ≈ k ± 0.3 ST → Capo k
  int? detectCapo({double tolerance = 0.3}) {
    if (_offsets.isEmpty) return null;
    // Round to nearest semitone and check cohesion
    final rounded = _offsets.map((d) => d.round()).toList();
    final k = rounded[0];
    for (final r in rounded) {
      if ((r - k).abs() > tolerance) {
        return null;
      }
    }
    return k;
  }
}

class TuningEvaluation {
  final int stringIndex;
  final String stringLabel;
  final double targetHz;
  final double cents;
  final double midiTarget;
  const TuningEvaluation({
    required this.stringIndex,
    required this.stringLabel,
    required this.targetHz,
    required this.cents,
    required this.midiTarget,
  });
}
