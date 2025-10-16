import 'dart:async';

import 'pitch_engine_interface.dart';

/// A deterministic mock engine producing a repeating pattern around A4 (440Hz).
class MockPitchEngine implements PitchEngine {
  final Duration interval;
  final List<double> sequenceHz;

  MockPitchEngine({this.interval = const Duration(milliseconds: 150), List<double>? sequence})
      : sequenceHz = sequence ?? const [430, 435, 440, 445, 450, 445, 440, 435];

  final _controller = StreamController<PitchFrame>.broadcast();
  Timer? _timer;
  int _idx = 0;

  @override
  Stream<PitchFrame> get frames => _controller.stream;

  @override
  bool get isRunning => _timer != null;

  @override
  Future<void> start() async {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) {
      final f = sequenceHz[_idx % sequenceHz.length];
      _idx++;
      _controller.add(PitchFrame(frequencyHz: f, confidence: 0.9, timestamp: DateTime.now()));
    });
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _controller.close();
    _timer?.cancel();
  }
}
