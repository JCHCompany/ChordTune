import '../conversions.dart';

class TuningPreset {
  final String name;
  final List<String> notes; // e.g. ["E2","A2","D3","G3","B3","E4"]
  const TuningPreset(this.name, this.notes);
}

class ParsedStringNote {
  final String label; // E2, A2...
  final int midi;
  final double hz;
  const ParsedStringNote(this.label, this.midi, this.hz);
}

ParsedStringNote parseNoteLabel(String label, {double a4 = 440}) {
  // label like E2, F#3, Bb2 (accepts #/b)
  final regex = RegExp(r'^([A-Ga-g])([#b]?)(-?\d+)$');
  final m = regex.firstMatch(label.trim());
  if (m == null) {
    throw ArgumentError('Invalid note label: $label');
  }
  String n = m.group(1)!.toUpperCase();
  final acc = m.group(2) ?? '';
  final oct = int.parse(m.group(3)!);
  int semitone = {
    'C': 0,
    'D': 2,
    'E': 4,
    'F': 5,
    'G': 7,
    'A': 9,
    'B': 11,
  }[n]!;
  if (acc == '#') {
    semitone += 1;
  } else if (acc == 'b') {
    semitone -= 1;
  }
  final midi = (oct + 1) * 12 + semitone;
  final hz = PitchConversions.midiToHz(midi, a4: a4);
  return ParsedStringNote(label, midi, hz);
}

class BuiltInTunings {
  static const standard = TuningPreset('Standard EADGBE', ['E2','A2','D3','G3','B3','E4']);
  static const dropD = TuningPreset('Drop D', ['D2','A2','D3','G3','B3','E4']);
  static const openG = TuningPreset('Open G', ['D2','G2','D3','G3','B3','D4']);
  static const halfStepDown = TuningPreset('Half-step down', ['D#2','G#2','C#3','F#3','A#3','D#4']);
  static TuningPreset capo(int k) {
    // Shift all strings by +k semitones from standard
    List<String> notes = ['E2','A2','D3','G3','B3','E4'];
    final shifted = notes.map((l) {
      final p = parseNoteLabel(l);
      final midi = p.midi + k;
      final name = _midiToName(midi);
      return name;
    }).toList();
    return TuningPreset('Capo $k', shifted);
  }

  static String _midiToName(int midi) {
    const names = ['C','C#','D','D#','E','F','F#','G','G#','A','A#','B'];
    final name = names[(midi % 12 + 12) % 12];
    final octave = (midi ~/ 12) - 1;
    return '$name$octave';
  }

  static List<TuningPreset> all() => [standard, dropD, openG, halfStepDown];
}
