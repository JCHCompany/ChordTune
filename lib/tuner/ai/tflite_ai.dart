import 'dart:math' as math;

import 'package:tflite_flutter/tflite_flutter.dart' as tfl;

import 'ai_pitch_base.dart';

/// Generic TFLite f0 model wrapper.
///
/// Expects a single-frame inference where input is a mono PCM float array
/// of length N (40–64 ms at the given sample rate). Output is assumed to be
/// a probability vector over pitch bins. We map the argmax bin to Hz using a
/// linear mapping between [fMinHz] and [fMaxHz] unless a custom mapper is
/// provided.
class TfliteAIPitchModel implements AIPitchModel {
  TfliteAIPitchModel({
    this.assetPath = 'assets/models/crepe-lite.tflite',
    this.fMinHz = 55.0,
    this.fMaxHz = 1100.0,
  });

  final String assetPath;
  final double fMinHz;
  final double fMaxHz;

  tfl.Interpreter? _interp;
  List<int>? _inShape;
  List<int>? _outShape;
  bool _ready = false;

  @override
  Future<void> load() async {
    try {
      final opts = tfl.InterpreterOptions();
      // Delegates (NNAPI/GPU) may be added here conditionally if available.
      final interpreter =
          await tfl.Interpreter.fromAsset(assetPath, options: opts);
      _interp = interpreter;
      _inShape = interpreter.getInputTensor(0).shape;
      _outShape = interpreter.getOutputTensor(0).shape;
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  @override
  Future<AIPitchResult> infer(
      {required List<double> frame, required int sampleRate}) async {
    if (!_ready || _interp == null) {
      return const AIPitchResult(f0: null, confidence: 0.0);
    }
    final interpreter = _interp!;

    // Prepare input shape [1, N]
    final n = _inShape?[1] ?? frame.length;
    final input = List.generate(1, (_) => List<double>.filled(n, 0.0));
    // Resize or pad/trim frame to N samples (simple copy).
    if (frame.length >= n) {
      for (var i = 0; i < n; i++) input[0][i] = frame[i];
    } else {
      for (var i = 0; i < frame.length; i++) input[0][i] = frame[i];
    }

    // Run inference
    final outLen = _outShape?[1] ?? 360;
    final output = List.generate(1, (_) => List<double>.filled(outLen, 0.0));
    try {
      interpreter.run(input, output);
    } catch (_) {
      return const AIPitchResult(f0: null, confidence: 0.0);
    }

    // Postprocess: argmax and softmax confidence
    final probs = output[0];
    var bestIdx = 0;
    var bestVal = probs[0];
    double sumExp = 0.0;
    for (var i = 0; i < probs.length; i++) {
      if (probs[i] > bestVal) {
        bestVal = probs[i];
        bestIdx = i;
      }
    }
    // Softmax over logits or scores
    for (var i = 0; i < probs.length; i++) {
      sumExp += math.exp(probs[i] - bestVal);
    }
    final conf = (sumExp <= 0) ? 0.0 : (1.0 / sumExp).clamp(0.0, 1.0);

    // Map bin index to frequency (linear mapping fallback)
    final f0 = _mapBinToHz(bestIdx, probs.length);
    return AIPitchResult(f0: f0, confidence: conf);
  }

  double _mapBinToHz(int idx, int total) {
    if (total <= 1) return (fMinHz + fMaxHz) * 0.5;
    final t = idx / (total - 1);
    // Log-scale mapping is often better for pitch; use log interpolation.
    final logMin = math.log(fMinHz);
    final logMax = math.log(fMaxHz);
    final f = math.exp(logMin + t * (logMax - logMin));
    return f.clamp(fMinHz, fMaxHz);
  }

  @override
  void dispose() {
    try {
      _interp?.close();
    } catch (_) {}
    _interp = null;
    _ready = false;
  }
}
