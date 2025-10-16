import 'dart:typed_data';

class PitchFrameResearch {
  final double f0Hz;
  final double confidence;
  final double rms;
  final double snr;
  final DateTime ts;
  final String detector;
  const PitchFrameResearch({
    required this.f0Hz,
    required this.confidence,
    required this.rms,
    required this.snr,
    required this.ts,
    required this.detector,
  });
}

abstract class IAudioPreproc {
  Float32List process(Float32List x, int sampleRate);
}

abstract class IPitchDetector {
  // Returns f0Hz, confidence and optional details
  PitchFrameResearch? detect(Float32List x, int sampleRate);
  String get name;
}

abstract class IConfidenceEstimator {
  double voicedConfidence({required double hnr, required double peakProminence});
}

abstract class ITracker {
  // Update with new f0/conf and return smoothed f0 (Hz) and final conf
  (double f0Hz, double conf) update(double? f0Hz, double conf);
}

abstract class IMetricsSink {
  void onFrame(PitchFrameResearch frame);
  Future<void> flush();
}

abstract class IAntiOctave {
  double correct(double f0, Float32List spectrum, int sampleRate);
}

abstract class IDetectorSelector {
  PitchFrameResearch? select(List<PitchFrameResearch?> candidates);
}