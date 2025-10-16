import 'dart:typed_data';

/// Placeholder for a bank of constant-Q resonators alternative to CQT.
/// Currently acts as a pass-through wrapper reusing the CQT mapping externally.
class ResonatorsQ {
  final int length;
  ResonatorsQ({required this.length});
  Float32List process(Float32List logFreqPower) => logFreqPower; // no-op
}
