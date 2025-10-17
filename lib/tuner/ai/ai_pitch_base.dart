class AIPitchResult {
  const AIPitchResult({required this.f0, required this.confidence});
  final double? f0; // Hz or null if no confident pitch
  final double confidence; // 0..1
}

abstract class AIPitchModel {
  Future<void> load();
  Future<AIPitchResult> infer(
      {required List<double> frame, required int sampleRate});
  void dispose() {}
}

/// Default DSP-only implementation (no AI): always returns no candidate.
class NoOpAIPitchModel implements AIPitchModel {
  @override
  Future<void> load() async {}

  @override
  Future<AIPitchResult> infer(
      {required List<double> frame, required int sampleRate}) async {
    return const AIPitchResult(f0: null, confidence: 0.0);
  }

  @override
  void dispose() {}
}
