import 'conversions.dart';

class NoteInfo {
  final String name;
  final int octave;
  final double targetHz;
  final double cents; // positive if above target

  const NoteInfo({required this.name, required this.octave, required this.targetHz, required this.cents});

  String get display => '$name$octave';
}

const _noteNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

NoteInfo analyzeFrequency(double hz, {double a4 = 440.0}) {
  final midiFloat = PitchConversions.hzToMidi(hz, a4: a4);
  final midiNearest = midiFloat.round();
  final noteIndex = (midiNearest % 12 + 12) % 12;
  final octave = (midiNearest ~/ 12) - 1; // MIDI 69 -> A4 -> (69/12) - 1 = 4
  final targetHz = PitchConversions.midiToHz(midiNearest, a4: a4);
  final cents = PitchConversions.centsBetween(hz, targetHz);
  return NoteInfo(name: _noteNames[noteIndex], octave: octave, targetHz: targetHz, cents: cents);
}
