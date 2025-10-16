import 'dart:async';

/// Basic representation of a pitch analysis frame.
class PitchFrame {
  final double frequencyHz;
  final double confidence; // 0..1
  final DateTime timestamp;

  const PitchFrame({required this.frequencyHz, required this.confidence, required this.timestamp});
}

/// Contract for a pitch detection engine.
abstract class PitchEngine {
  Stream<PitchFrame> get frames;
  Future<void> start();
  Future<void> stop();
  bool get isRunning;
}
