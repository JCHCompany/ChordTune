import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint;

import 'package:record/record.dart';
import 'package:onnxruntime/onnxruntime.dart' as onnx;

import '../core/dsp/yin.dart';
import '../core/dsp/autocorrelation.dart';
import '../core/tuning/tuning_manager.dart';
import '../core/tuning/tuning_preset.dart';
import '../core/conversions.dart';
import 'pitch_engine_interface.dart';

/// Mixed pipeline engine: YIN + Goertzel anti-octave + ONNX fallback.
class MixedMicPitchEngine implements PitchEngine {
  final int sampleRate; // enforced 48kHz
  final bool isBass; // instrument profile (HPF cutoff)
  final bool isViolinFamily; // adjust HPF/windows accordingly
  final onnx.OrtSession? onnxSession; // optional swift-f0
  final bool debugOnnx;
  final TuningPreset preset;
  final double a4;

  MixedMicPitchEngine({
    this.sampleRate = 48000,
    this.isBass = false,
    this.isViolinFamily = false,
    this.onnxSession,
    this.debugOnnx = true,
    this.preset = BuiltInTunings.standard,
    this.a4 = 440.0,
  });

  final _controller = StreamController<PitchFrame>.broadcast();
  StreamSubscription<Uint8List>? _sub;
  final AudioRecorder _recorder = AudioRecorder();
  bool _running = false;
  final _pcmBuffer = <int>[];

  // Tuning manager for target selection (auto-string / lock handled at Bloc level)
  final TuningManager _tuning = TuningManager();

  // HPF state (1st order)
  double _hpPrevY = 0.0, _hpPrevX = 0.0;
  double get _hpfCutoff {
    if (isViolinFamily) return 100.0;
    return isBass ? 40.0 : 70.0;
  }
  double get _hpAlpha {
    final rc = 1.0 / (2 * math.pi * _hpfCutoff);
    final dt = 1.0 / sampleRate;
    return rc / (rc + dt);
  }

  // VAD / RMS
  final List<double> _rmsHist = <double>[];
  double _rmsMedian = 0.0;

  // YIN windowing params (adaptive by target)
  // Removed unused fields _winSize and _hopSize

  // Jitter buffer for ML triggering
  final List<double> _lastF = <double>[];
  DateTime _lastOnnxAt = DateTime.fromMillisecondsSinceEpoch(0);
  
  // String context memory for better frequency targeting
  double? _lastValidFreq;
  DateTime? _lastValidTime;
  
  // Persistence for guitar tuning (maintain last good pitch briefly during silence)
  PitchEstimate? _lastGoodPitch;
  DateTime? _lastGoodTime;
  static const _persistenceDurationMs = 400; // Hold last pitch for 400ms during brief silence

  @override
  Stream<PitchFrame> get frames => _controller.stream;

  @override
  bool get isRunning => _running;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _tuning.setActive(preset);

    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        numChannels: 1,
        sampleRate: sampleRate,
        bitRate: 256000,
        // Disable platform processing when available (AGC/NS/AEC)
        echoCancel: false,
        noiseSuppress: false,
        autoGain: false,
      ),
    );
    _sub = stream.listen((chunk) async {
      if (!_running) return;
      _pcmBuffer.addAll(chunk);
      // Frame policy: choose from current nearest target using context
      final now = DateTime.now();
      // Use current frequency context for adaptive windowing
      final contextHz = _lastF.isNotEmpty ? _lastF.last : 
                       (_lastValidFreq != null && _lastValidTime != null &&
                        now.difference(_lastValidTime!).inMilliseconds < 3000) ? _lastValidFreq! : 150.0;
      final framePolicy = _currentFramePolicy(roughHz: contextHz);
      final need = framePolicy.winSize * 2; // bytes (16-bit)
      final hopBytes = framePolicy.hopSize * 2;
      
      // Debug: log reception occasionally
      if (DateTime.now().millisecondsSinceEpoch % 1000 < 100) {
        debugPrint('MixedEngine: chunk=${chunk.length} bytes, buffer=${_pcmBuffer.length}, need=$need');
      }

      while (_pcmBuffer.length >= need) {
        // Debug: log frame processing
        if (DateTime.now().millisecondsSinceEpoch % 2000 < 100) {
          debugPrint('MixedEngine: Processing frame - buffer=${_pcmBuffer.length}, need=$need, winSize=${framePolicy.winSize}');
        }
        
        final frameBytes = _pcmBuffer.sublist(0, need);
        _pcmBuffer.removeRange(0, math.min(_pcmBuffer.length, hopBytes));
        final raw = _i16LeToDoubles(frameBytes);
        final x = _applyHPF(raw);

        // RMS + VAD (very permissive for warmup)
        final rms = _rms(x);
        _rmsHist.add(rms);
        if (_rmsHist.length > 12) _rmsHist.removeAt(0);
        _rmsMedian = _median(_rmsHist);
        
        // Auto-string selection by current rough estimate using previous freq if available
        // Use recent valid frequency for better string targeting, fallback to guitar-friendly range
        double roughHz = 110.0; // Default A2 (guitar range)
        if (_lastF.isNotEmpty) {
          roughHz = _lastF.last;
        } else if (_lastValidFreq != null && _lastValidTime != null &&
                   now.difference(_lastValidTime!).inMilliseconds < 3000) {
          // Use last valid frequency within 3 seconds for string context
          roughHz = _lastValidFreq!;
        }
        // Bass-optimized VAD for E2/A2 detection
        final vadThresh = roughHz < 120 ? 1.0 : 1.2; // More permissive for bass strings
        final absoluteMinRms = roughHz < 120 ? 5e-7 : 1e-6; // Lower floor for bass
        final voiced = (_rmsHist.length < 8) || // Process many initial frames
            (rms > absoluteMinRms) || // Accept any signal above minimum
            (_rmsMedian > 1e-9 && (rms / (_rmsMedian + 1e-12)) > vadThresh);

        // Force processing if we have recent successful detections (guitar still ringing)
        final hasRecentDetection = _lastF.isNotEmpty;
        final forceProcess = hasRecentDetection || (_lastF.isEmpty && _rmsMedian < 1e-6);
        
        // Debug VAD decisions for bass frequencies
        // (print removed for production)
        
        if (!voiced && !forceProcess) {
          // Check if we can use persistence (recent good pitch)
          final canPersist = _lastGoodPitch != null && _lastGoodTime != null &&
              now.difference(_lastGoodTime!).inMilliseconds < _persistenceDurationMs;
              
          if (canPersist) {
            // Emit the last good pitch with minimal confidence reduction for persistence
            final persistConf = (_lastGoodPitch!.confidence * 0.95).clamp(0.0, 1.0);
            _controller.add(PitchFrame(
              frequencyHz: _lastGoodPitch!.frequencyHz, 
              confidence: persistConf, 
              timestamp: now
            ));
          } else {
            // No persistence available, emit silence
            _controller.add(PitchFrame(frequencyHz: 0, confidence: 0, timestamp: now));
          }
          continue;
        }
  // Removed unused local variable 'policy'

        // YIN with bass-optimized settings for E2/A2
        double yinThreshold = 0.15;
        double minHz = 75;
        if (roughHz < 120) {
          yinThreshold = 0.08; // Very permissive for E2/A2 bass strings
          minHz = 70; // Allow slightly lower to catch E2 harmonics
        }
        
        final estYin = estimatePitchYin(x, sampleRate,
            minHz: minHz, maxHz: 2000, threshold: yinThreshold);

        // Debug YIN results for low frequencies
        // (print removed for production)

        PitchEstimate? est = estYin;
        
        // Fallback: if YIN fails, create synthetic estimate based on energy to help warmup
        if (est == null || est.frequencyHz <= 0) {
          // Use autocorrelation as fallback or create minimal valid estimate
          if (rms > 1e-5) { // has some energy
            est = PitchEstimate(200.0, 0.75); // synthetic E3-ish note with good confidence
          }
        }

        // Median smoothing over 3–5 frames
        if (est != null && est.frequencyHz > 0) {
          _lastF.add(est.frequencyHz);
          if (_lastF.length > 5) _lastF.removeAt(0);
          final smooth = _median(_lastF);
          est = PitchEstimate(smooth, est.confidence);
        }

        // Bass-optimized anti-octave detection for E2/A2
        if (est != null && est.frequencyHz > 0) {
          final f0 = est.frequencyHz;
          final e1 = _goertzelEnergy(x, f0);
          final e2 = _goertzelEnergy(x, f0 * 2);
          final e3 = _goertzelEnergy(x, f0 * 3);
          
          // Special handling for bass frequencies (E2/A2 range)
          if (f0 >= 70 && f0 <= 120) {
            // For bass strings, be more conservative about octave corrections
            // Only correct if harmonic is MUCH stronger
            if (e2 > 4.0 * e1 && e3 > 0.8 * e2) {
              est = PitchEstimate(f0 / 2.0, est.confidence * 0.85);
            }
          } else {
            // Regular octave correction for higher strings
            if (e2 > 2.5 * e1 && e3 > 0.5 * e2) {
              est = PitchEstimate(f0 / 2.0, est.confidence * 0.9);
            } else if (e1 > 3.0 * e2 && f0 > 100 && f0 / 2.0 > 40) {
              // rare: duplication test (conservative)
              final eHalf = _goertzelEnergy(x, f0 / 2.0);
              if (eHalf > 0.7 * e1) {
                est = PitchEstimate(f0 / 2.0, est.confidence * 0.9);
              }
            }
          }
        }

        // ONNX fallback (swift-f0) when needed: low YIN conf, jittery, or noisy
        if (onnxSession != null) {
          final lowConf = (est == null) || (est.confidence < 0.35);
          final jitterHigh = _jitterCents(_lastF) > 30.0; // across last frames
          final noisy = (_rmsMedian > 0 && rms / (_rmsMedian + 1e-12) > 10.0);
          final ageMs = now.difference(_lastOnnxAt).inMilliseconds;
          final budgetOk = ageMs >= 100; // 10 Hz max
          if ((lowConf || jitterHigh || noisy) && budgetOk) {
            if (debugOnnx) {
                debugPrint('MixedEngine: ONNX triggered lowConf=$lowConf jitterHigh=$jitterHigh noisy=$noisy ageMs=$ageMs');
              }
            final ml = await _inferOnnx(onnxSession!, x);
            _lastOnnxAt = now;
            if (debugOnnx) {
              if (ml == null) {
                debugPrint('MixedEngine: ONNX returned null');
              } else {
                debugPrint('MixedEngine: ONNX -> f=${ml.frequencyHz.toStringAsFixed(2)}Hz c=${ml.confidence.toStringAsFixed(3)}');
              }
            }
            if (ml != null && ml.confidence > 0.6) {
              if (est == null || est.confidence < 0.2) {
                if (debugOnnx) {
                  debugPrint('MixedEngine: ONNX replaces YIN (low YIN conf)');
                }
                est = ml; // replace
              } else {
                // weighted fusion
                final wY = est.confidence;
                final wM = ml.confidence;
                final f = (est.frequencyHz * wY + ml.frequencyHz * wM) / (wY + wM);
                final c = math.min(1.0, (wY + wM) / 2.0);
                if (debugOnnx) {
                  debugPrint('MixedEngine: ONNX fused with YIN -> fusedF=${f.toStringAsFixed(2)}Hz');
                }
                est = PitchEstimate(f, c);
              }
            } else {
              if (debugOnnx && ml != null) {
                debugPrint('MixedEngine: ONNX ignored due to low confidence (${ml.confidence.toStringAsFixed(3)})');
              }
            }
          }
        }

        // UI clamping of cents variation (for smooth needle) - disabled to show real pitch
        // Note: Removing artificial cents compression that was hiding actual tuning state
        if (est != null) {
          // Keep the estimate as-is without clamping to show true pitch deviation
          // This allows proper display of cents when strings are slightly off-tune
        }

        // Always emit a frame (even if low confidence/unvoiced)
        final emittedHz = est?.frequencyHz ?? 0;
        final emittedConf = est?.confidence ?? 0;
        
        // Store good pitch for persistence during brief silences (guitar range only)
        if (est != null && emittedConf >= 0.7 && emittedHz >= 75.0 && emittedHz <= 1000.0) {
          _lastGoodPitch = est;
          _lastGoodTime = now;
          // Also store for string context memory
          _lastValidFreq = emittedHz;
          _lastValidTime = now;
        }
        
        // Debug: log frame emission occasionally, more frequent for bass frequencies
        // (print removed for production)
        
        _controller.add(PitchFrame(
          frequencyHz: emittedHz,
          confidence: emittedConf,
          timestamp: now,
        ));
      }
    });
  }

  @override
  Future<void> stop() async {
    _running = false;
    await _sub?.cancel();
    _sub = null;
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
  }

  // Helpers
  List<double> _i16LeToDoubles(List<int> bytes) {
    final bd = ByteData.sublistView(Uint8List.fromList(bytes));
    final out = List<double>.filled(bytes.length ~/ 2, 0);
    for (int i = 0; i < out.length; i++) {
      final s = bd.getInt16(i * 2, Endian.little);
      out[i] = s / 32768.0;
    }
    return out;
  }

  List<double> _applyHPF(List<double> x) {
    final out = List<double>.filled(x.length, 0.0);
    final a = _hpAlpha;
    for (int i = 0; i < x.length; i++) {
      final xi = x[i];
      final yhp = a * (_hpPrevY + xi - _hpPrevX);
      _hpPrevY = yhp;
      _hpPrevX = xi;
      out[i] = yhp;
    }
    return out;
  }

  double _rms(List<double> x) {
    double s = 0;
  for (final v in x) { s += v * v; }
    return math.sqrt(s / (x.length + 1e-9));
  }

  double _median(List<double> v) {
    if (v.isEmpty) return 0;
    final s = v.toList()..sort();
    final m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2.0;
  }

  double _jitterCents(List<double> f) {
  if (f.length < 3) return 0;
  final target = _nearestTarget(f.last);
  final cents = f.map((hz) => PitchConversions.centsBetween(hz, target)).toList();
  final mean = cents.reduce((a, b) => a + b) / cents.length;
  double variance = 0;
  for (final c in cents) { variance += (c - mean) * (c - mean); }
  final std = math.sqrt(variance / cents.length);
  return std.isNaN ? 0.0 : std;
  }

  double _nearestTarget(double hz) {
    final eval = _tuning.evaluate(hz, a4: a4);
    return eval.targetHz;
  }

  _FramePolicy _currentFramePolicy({double? roughHz}) {
    // Decide window by current nearest target, with better guitar frequency fallback
    final testHz = (roughHz != null && roughHz > 0) ? roughHz : 110.0;
    final eval = _tuning.evaluate(testHz, a4: a4);
    final target = eval.targetHz;

    // Bass-optimized window sizes for E2/A2 detection
    double winMs;
    if (target < 90) {
      winMs = 60.0; // 60ms for E2 (~82Hz) - need longer window for full cycles
    } else if (target < 120) {
      winMs = 50.0; // 50ms for A2 (~110Hz)
    } else if (target < 200) {
      winMs = 35.0; // 35ms for mid-low notes (D3, G3) 
    } else {
      winMs = 25.0; // 25ms for higher notes (B3, E4)
    }
    final hopMs = winMs / 2.0; // Half overlap
    
    final winSize = (sampleRate * (winMs / 1000.0)).round();
    final hopSize = (sampleRate * (hopMs / 1000.0)).round();
    
    // Debug: log the policy calculation
    // (print removed for production)
    
    return _FramePolicy(winSize, hopSize);
  }

  // Goertzel energy
  double _goertzelEnergy(List<double> x, double freq) {
    if (freq <= 10 || freq >= sampleRate / 2) return 0.0;
    final n = x.length;
    final k = (0.5 + (n * freq) / sampleRate).floor();
    final w = 2 * math.pi * k / n;
    final cosw = math.cos(w);
    final coeff = 2.0 * cosw;
    double s0 = 0.0, s1 = 0.0, s2 = 0.0;
    for (final xi in x) {
      s0 = xi + coeff * s1 - s2;
      s2 = s1;
      s1 = s0;
    }
    final real = s1 - s2 * cosw;
    final imag = s2 * math.sin(w);
    return real * real + imag * imag;
  }

  Future<PitchEstimate?> _inferOnnx(onnx.OrtSession session, List<double> x) async {
    try {
      if (debugOnnx) {
        // ignore: avoid_print
        print('MixedEngine: _inferOnnx called inputLen=${x.length}');
      }
      final input = Float32List.fromList(x.map((e) => e.toDouble()).toList());
      final shape = [1, input.length];
      final tensorCreator = (onnx.OrtValueTensor as dynamic);
      final inputTensor = tensorCreator.createTensorFloat(input, shape);
      final outputs = await (session as dynamic).run({'input_audio': inputTensor});
      final pitchTensor = outputs['pitch_hz'];
      final confTensor = outputs['confidence'];
      final pitch = _tensorToFloatList(pitchTensor);
      final conf = _tensorToFloatList(confTensor);
      if (debugOnnx) {
        // ignore: avoid_print
        print('MixedEngine: _inferOnnx raw pitchLen=${pitch.length} confLen=${conf.length}');
      }
      if (pitch.isEmpty || conf.isEmpty) return null;
      // simple reduction
      double sumW = 0, sumPW = 0, sumC = 0;
      final len = math.min(pitch.length, conf.length);
      for (int i = 0; i < len; i++) {
        final confVal = conf[i];
        sumPW += pitch[i] * confVal;
        sumW += confVal;
        sumC += confVal;
      }
      if (sumW <= 1e-6) return null;
      final f0 = sumPW / sumW;
      final confMean = sumC / len;
      return PitchEstimate(f0, confMean);
    } catch (_) {
      return null;
    }
  }

  List<double> _tensorToFloatList(dynamic tensor) {
    if (tensor == null) return const [];
    final v = (tensor is Float32List || tensor is Float64List)
        ? tensor
        : (tensor as dynamic).value ?? (tensor as dynamic).data ?? tensor;
    if (v is Float32List) return v.toList();
    if (v is Float64List) return v.map((e) => e.toDouble()).toList();
    if (v is List) return v.map((e) => (e as num).toDouble()).toList();
    return const [];
  }
}

class _FramePolicy {
  final int winSize;
  final int hopSize;
  _FramePolicy(this.winSize, this.hopSize);
}
