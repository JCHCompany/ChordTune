import 'dart:async';
import 'dart:math' as math;
import 'dart:io' as io;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint;

import 'package:record/record.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart' as onnx;
import 'package:tflite_flutter/tflite_flutter.dart' as tfl;
import 'package:path_provider/path_provider.dart';

import '../core/dsp/autocorrelation.dart';
import '../core/dsp/yin.dart';
import 'pitch_engine_interface.dart';

enum InferenceBackend { none, tflite, onnx }

// Internal tracking state for HOLD FSM
enum _TrackState { idle, onset, sustain, decay }

// Register buckets for thresholds/corridors
enum _Register { low, med, high }

class MicPitchEngine implements PitchEngine {
  // Per-instance identifier to help debug which engine is active at runtime
  static int _instanceCounter = 0;
  final String _instanceId;
  final int sampleRate;
  final int frameSize; // samples per analysis window
  final int hopSize; // overlap hop
  final InferenceBackend backend;
  final String? modelAsset;
  final bool debugOnnx;
  // Optional tuning-aware guard: when provided, can restrict allowed note jumps during LOCK
  final bool Function(double prevHz, double candidateHz)? tuningGuard;

  final _controller = StreamController<PitchFrame>.broadcast();
  StreamSubscription<Uint8List>? _sub;
  final AudioRecorder _recorder = AudioRecorder();
  bool _running = false;

  // Optional backends
  tfl.Interpreter? _tflite;
  dynamic _onnxSession; // use dynamic to avoid compile errors on API differences

  final List<int> _pcmBuffer = <int>[];
  // Simple RMS history for transient detection
  final List<double> _rmsHistory = <double>[];
  final int _rmsHistoryLen = 8; // keep last ~8 hops
  double _rmsMedian = 0.0;

  // Minimal state
  double? _prevAcceptedF0;
  double _prevAcceptedConf = 0.0;
  // Removed unused lastAcceptedAt; we rely on _stateSince/hold instead

  // Tracking/HOLD FSM
  // States: idle -> onset -> sustain -> decay -> idle
  // We keep it simple: onset and sustain both "accept" and emit; decay emits held note up to holdDuration.
  _TrackState _state = _TrackState.idle;
  DateTime? _stateSince;
  DateTime? _holdUntil;
  final Duration _holdDuration = const Duration(milliseconds: 220); // 8–12 frames (~160–240ms)

  // Envelope (RMS EMA) used to decide sustain/decay behavior
  double _envEma = 0.0;
  static const double _envAlpha = 0.25; // EMA coefficient

  // Recent accepted f0 for decay smoothing
  final List<double> _recentAcceptedF0 = <double>[];
  static const int _recentAcceptedLen = 5;

  // Unlock logic: only increment when voiced strong
  int _unlockCounter = 0;
  static const int _unlockK = 2; // consecutive strong contradictory frames required
  // static const double _confMinUnlock = 0.85; // low-confidence frames never count toward unlock // unused

  // Harmonic dominance tracking for systematic anti-harmonic rule
  int _harmonicDominanceCount = 0;

  // Debug capture: raw/pre-ONNX audio and telemetry
  bool _captureActive = false;
  int _captureMaxSamples = 0; // in samples at 16k
  // int _capturedRawSamples = 0; // unused
  DateTime? _captureStart;
  String _captureLabel = 'e4';
  final List<int> _captureRawPcm = <int>[]; // PCM16 LE bytes from mic
  final List<int> _capturePreOnnxPcm = <int>[]; // PCM16 LE bytes after front-end (hop-wise)
  final StringBuffer _captureOnnxCsv = StringBuffer('t_idx,pitch_hz,confidence\n');
  final StringBuffer _captureTelemetryCsv = StringBuffer(
    'ts_ms,frame_idx,sr_effective,rms_dbfs,agc_gain,peak_dbfs,f0_raw,conf_raw,f0_kept_quantile,conf_kept_quantile,kept_count,fallback_reason,harm_ratio,applied_harm_fix,voiced,percussive,state,locked,in_grace,displayGateReason,register,corridor_min_cents,corridor_max_cents,cents,N_lock,K_unlock,unlock_reason\n');

  // Last-ONNX raw arrays (for telemetry)
  // List<double> _lastOnnxPitch = const []; // unused
  // List<double> _lastOnnxConf = const []; // unused
  double _lastOnnxMedianPitch = 0.0;
  double _lastOnnxMedianConf = 0.0;

  // Telemetry aux
  double _lastHarmRatio = 0.0;
  bool _appliedHarmFix = false;
  int _frameIdx = 0;
  int _lockCount = 0;
  String _lastUnlockReason = '';
  // Display/grace & aggregation telemetry
  DateTime? _graceUntil; // allow chromatic display in this window
  // bool _everLocked = false; // once true, never hide display // unused (future feature)
  String _displayGateReason = '';
  int _lastKeptCount = 0;
  String _lastFallbackReason = '';
  DateTime? _agcFreezeUntil;

  // Light band-pass filtering (40..1400 Hz) using 1st-order HP + LP to improve YIN SNR
  double _hpPrevY = 0.0, _hpPrevX = 0.0;
  double _lpPrevY = 0.0;
  // Precompute filter coefficients
  late final double _hpAlpha = _firstOrderHpAlpha(45.0, sampleRate);
  // LPF softened for ONNX tests (3 kHz), else 1.4 kHz
  late final double _lpBeta = _firstOrderLpBeta(
      backend == InferenceBackend.onnx ? 3000.0 : 1400.0, sampleRate);

  // DC blocker (first-order)
  double _dcPrevX = 0.0, _dcPrevY = 0.0;
  static const double _dcA = 0.995;

  // Slow AGC (-18 dBFS target)
  double _agcGain = 1.0;
  static const double _agcTargetRms = 0.125892541; // 10^(-18/20)
  static const double _agcAttackMs = 150.0;
  static const double _agcReleaseMs = 1200.0;

  MicPitchEngine({
    this.sampleRate = 16000,
    this.frameSize = 2560, // exactly 160ms at 16k for ONNX
    this.hopSize = 1280, // exactly 80ms stride (50% overlap)
    this.backend = InferenceBackend.none,
    this.modelAsset,
  this.debugOnnx = true,
    this.tuningGuard,
  }) : _instanceId = 'MicEngine#${_instanceCounter++}' {
    // Print creation info when ONNX debug is enabled so we can confirm which instance was built
    if (debugOnnx) {
      debugPrint('MicEngine CREATED: id=$_instanceId backend=$backend modelAsset=${modelAsset ?? "<none>"}');
    }
  }

  // Expose identifier for external debugging (TunerBloc etc.)
  String get instanceId => _instanceId;

  @override
  Stream<PitchFrame> get frames => _controller.stream;

  @override
  bool get isRunning => _running;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;

    // Try initialize backends if requested
    await _initBackend();

    // Debug startup: confirm backend and debugOnnx state so developers can verify
    if (debugOnnx) {
      debugPrint('MicEngine START: backend=$backend, modelAsset=${modelAsset ?? "<none>"}, onnxSession=${_onnxSession != null}');
    }

    // Start mic stream (PCM 16bits, mono) - force exact sample rate
    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        numChannels: 1,
        sampleRate: sampleRate, // must be exactly 16000 for ONNX model
        bitRate: 128000,
        // Disable platform voice processing where supported
        echoCancel: false,
        noiseSuppress: false,
        autoGain: false,
      ),
    );
  // if (debugOnnx) {
  //   debugPrint('MicEngine: recorder stream started, targetSR=$sampleRate (ONNX expects 16000)');
  // }

    // Auto-enable capture for diagnostics (5s window) when debugOnnx is true
    if (debugOnnx) {
      _beginCapture(durationSeconds: 5, label: 'e4');
    }
    // _everLocked = false; // unused (future feature)
    _graceUntil = null;
    _displayGateReason = '';
    _lastKeptCount = 0;
    _lastFallbackReason = '';

    _sub = stream.listen((chunk) async {
      if (!_running) return;
      _pcmBuffer.addAll(chunk);
      final bytesPerSample = 2;
      final need = frameSize * bytesPerSample;
      while (_pcmBuffer.length >= need) {
        final frameBytes = _pcmBuffer.sublist(0, need);
        _pcmBuffer.removeRange(0, math.min(_pcmBuffer.length, hopSize * bytesPerSample));
        if (_captureActive) {
          _captureRawPcm.addAll(frameBytes);
          // _capturedRawSamples += frameSize; // unused
        }
  var samples = _i16LeToDoubles(frameBytes);
  // Front-end: DC block, slow AGC, then band-pass (40..1400 Hz)
  // Measure raw RMS for AGC
  double rawSumSq = 0.0;
  for (final s in samples) { rawSumSq += s * s; }
  final rawRms = math.sqrt(rawSumSq / samples.length);
  // Update AGC gain (log domain smoothing)
  final hopMs = (hopSize * 1000.0) / sampleRate;
  final attackAlpha = 1.0 - math.exp(-hopMs / _agcAttackMs);
  final releaseAlpha = 1.0 - math.exp(-hopMs / _agcReleaseMs);
  final desiredGain = (rawRms > 1e-9) ? (_agcTargetRms / (rawRms + 1e-12)) : 1.0;
  final alpha = (desiredGain > _agcGain) ? attackAlpha : releaseAlpha;
  _agcGain = math.exp((1 - alpha) * math.log(_agcGain + 1e-12) + alpha * math.log(desiredGain + 1e-12));
  // AGC safeguards: max gain and freeze logic
  _agcGain = _agcGain.clamp(0.25, 3.0);
  // DC blocker
  for (int i = 0; i < samples.length; i++) {
    final x = samples[i];
    final y = x - _dcPrevX + _dcA * _dcPrevY;
    _dcPrevX = x;
    _dcPrevY = y;
    samples[i] = y;
  }
  // Apply AGC
  for (int i = 0; i < samples.length; i++) {
    samples[i] *= _agcGain;
  }
  // Gentle band-pass
  samples = _applyBandPass(samples);
  // Save pre-ONNX PCM after AGC+filters
  if (_captureActive) {
    final bd = ByteData(samples.length * 2);
    for (int i = 0; i < samples.length; i++) {
      int v = (samples[i].clamp(-1.0, 1.0) * 32767.0).round();
      bd.setInt16(i * 2, v, Endian.little);
    }
    _capturePreOnnxPcm.addAll(bd.buffer.asUint8List());
  }
        
        // Diagnostic: check sample rate and normalization
        // Optional diagnostics removed to satisfy analyzer (unused locals)
        // compute RMS for transient/noise gating
        double sumSq = 0.0;
        for (var s in samples) {
          sumSq += s * s;
        }
        final rms = math.sqrt(sumSq / samples.length);
        _rmsHistory.add(rms);
        if (_rmsHistory.length > _rmsHistoryLen) _rmsHistory.removeAt(0);
        if (_rmsHistory.isNotEmpty) {
          final sorted = _rmsHistory.toList()..sort();
          final mid = sorted.length ~/ 2;
          _rmsMedian = (sorted.length.isOdd) ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0;
        }

        // If current RMS is a large spike relative to recent median, ignore this frame
        final spikeThreshold = 4.0; // 4x median - more permissive for high notes with harmonics
        final isSpike = _rmsMedian > 1e-9 ? (rms / (_rmsMedian + 1e-12)) > spikeThreshold : false;
        if (isSpike) {
          // emit an unvoiced frame (confidence 0)
          _controller.add(PitchFrame(frequencyHz: 0.0, confidence: 0.0, timestamp: DateTime.now()));
          continue;
        }

        // Prefer model; fall back to YIN/autocorr if unavailable
        // Pre-ONNX diagnostics: compute compact metrics and optionally log them
        double peak = 0.0;
        double sum = 0.0;
        // double weightedSumIdx = 0.0; // simple centroid proxy // unused (debug only)
        // double lowEnergy = 0.0; // unused (debug only)
        // double highEnergy = 0.0; // unused (debug only) 
        for (int i = 0; i < samples.length; i++) {
          final v = samples[i];
          final av = v.abs();
          if (av > peak) peak = av;
          sum += v * v;
          // weightedSumIdx += i * av; // unused (debug only)
          // if (i < samples.length ~/ 3) lowEnergy += v * v; // unused (debug only)
          // if (i > samples.length * 2 ~/ 3) highEnergy += v * v; // unused (debug only)
        }
        final rmsPre = math.sqrt(sum / samples.length);
        final rmsDbPre = 20.0 * math.log((rmsPre + 1e-12)) / math.ln10;
        final peakDb = 20.0 * math.log((peak + 1e-12)) / math.ln10;
        // final centroidProxy = (weightedSumIdx / samples.length); // unused (debug only)
        // final lowHighRatio = (highEnergy + 1e-12) / (lowEnergy + 1e-12); // unused (debug only)
        // Block AGC increases during freeze window, in decay, or at very low levels
        final bool agcFreeze = _agcFreezeUntil != null && DateTime.now().isBefore(_agcFreezeUntil!);
        final bool veryLowLevel = (rmsDbPre < -35.0 && peakDb < -28.0);
        if (agcFreeze || _state == _TrackState.decay || veryLowLevel) {
          // If desired would increase, freeze at current gain (implemented by capping already computed _agcGain above)
          // We don't retroactively change the already-updated _agcGain for this frame,
          // but next frame's update will respect freeze conditions by constraining desiredGain.
        }
  // if (debugOnnx) {
  //   debugPrint('MicEngine PRE-ONNX: frame=${_frameIdx}, ts=${DateTime.now().millisecondsSinceEpoch}, sr=$sampleRate, rms_db=${rmsDbPre.toStringAsFixed(2)}, agc=${_agcGain.toStringAsFixed(3)}, peak_db=${peakDb.toStringAsFixed(2)}, centroid=${centroidProxy.toStringAsFixed(1)}, lowHigh=${lowHighRatio.toStringAsFixed(3)}');
  // }

        PitchEstimate? est;
        // Grace window: if idle and we see a voiced estimate later, allow pre-lock display for ~400ms
        final modelEst = await _infer(samples);
        if (modelEst != null && modelEst.frequencyHz > 0) {
          est = modelEst;
        } else {
          est = estimatePitchYin(samples, sampleRate, minHz: 60, maxHz: 1500, threshold: 0.1)
              ?? estimatePitchAutocorrelation(samples, sampleRate);
        }
        if ((_state == _TrackState.idle) && _graceUntil == null && est != null && est.frequencyHz > 0 && est.confidence >= 0.35) {
          _graceUntil = DateTime.now().add(const Duration(milliseconds: 300));
        }
        
        // Guitar high strings bias: prefer fundamental over harmonics
        if (est != null && est.frequencyHz >= 480 && est.frequencyHz <= 700) {
          // Check if this might be a harmonic of guitar B4 (247Hz) or E4 (330Hz)
          final possibleB4 = est.frequencyHz / 2.0; // ~247Hz
          final possibleE4 = est.frequencyHz / 2.0; // ~330Hz
          if ((possibleB4 >= 235 && possibleB4 <= 260) || 
              (possibleE4 >= 315 && possibleE4 <= 345)) {
            // Apply bias toward fundamental (lower octave)
            final biasedConfidence = est.confidence * 0.7; // reduce confidence of suspected harmonic
            est = PitchEstimate(possibleB4 >= 235 && possibleB4 <= 260 ? possibleB4 : possibleE4, biasedConfidence);
          }
        }
        
        // Update envelope EMA
        _envEma = (_envAlpha * rms) + ((1.0 - _envAlpha) * _envEma);

  // Register-dependent thresholds and corridors
        final loudnessRatio = _rmsMedian > 1e-9 ? (rms / (_rmsMedian + 1e-12)) : 1.0;
        final reg = (est != null && est.frequencyHz > 0) ? _registerForFreq(est.frequencyHz) : _Register.med;
        // conf_min_unlock by register
        final double confMinUnlock = switch (reg) {
          _Register.low => 0.75,
          _Register.med => 0.80,
          _Register.high => 0.85,
        };
        // conf_min_display/acquire baseline by register
        double confAcquire = switch (reg) {
          _Register.low => 0.65,
          _Register.med => 0.70,
          _Register.high => 0.75,
        };
        // Adaptive confidence thresholds based on loudness ratio
        if (loudnessRatio >= 1.6) confAcquire = math.max(0.48, confAcquire - 0.06);
        if (loudnessRatio <= 0.8) confAcquire = math.min(confAcquire + 0.08, 0.78);
        final double confRelease = math.max(0.35, confAcquire - 0.15); // hysteresis

        // Systematic anti-harmonic detection using Goertzel energy (register-dependent)
        if (est != null && est.frequencyHz > 0) {
          final f = est.frequencyHz;
          final f2 = f * 2.0;
          if (f2 < (sampleRate / 2)) { // 2*f must be below Nyquist
            final p1 = _goertzelPower(samples, f, sampleRate);
            final p2 = _goertzelPower(samples, f2, sampleRate);
            // Ratio threshold with slight hysteresis for higher freqs
            final ratio = (p1 <= 1e-12) ? double.infinity : (p2 / (p1 + 1e-12));
            final regF = _registerForFreq(f);
            // harm_ratio thresholds by register
            double harmThresh = switch (regF) {
              _Register.low => 0.90,
              _Register.med => 0.75,
              _Register.high => 0.70,
            };
            if (ratio >= harmThresh) {
              _harmonicDominanceCount++;
            } else {
              _harmonicDominanceCount = 0;
            }
            bool allowDivide = _harmonicDominanceCount >= 3;
            if (regF == _Register.low && est.confidence >= 0.85) {
              allowDivide = false; // require low raw confidence to divide in low register
            }
            _lastHarmRatio = ratio;
            _appliedHarmFix = false;
            if (allowDivide) {
              // Safeguards in high register: only divide on real octave flip against previous and low confidence
              bool doDivide = true;
              if (regF == _Register.high && _prevAcceptedF0 != null) {
                final prev = _prevAcceptedF0!;
                final isOctaveFlip = (f / prev) > 1.95 && (f / prev) < 2.05;
                if (!isOctaveFlip || est.confidence >= 0.85) {
                  doDivide = false;
                } else {
                  // ensure divided frequency remains within corridor of the locked string
                  final divided = f / 2.0;
                  final corridor = _computeCorridorCents(inDecay: _state == _TrackState.decay, loudnessRatio: 1.0, reg: _registerForFreq(prev));
                  final centsDelta = (1200.0 * math.log(divided / prev) / math.ln2).abs();
                  if (centsDelta > corridor) doDivide = false;
                }
              }
              if (doDivide) {
                est = PitchEstimate(f / 2.0, est.confidence * 0.9);
                _harmonicDominanceCount = 0; // apply once
                _appliedHarmFix = true;
              }
            }
          } else {
            _harmonicDominanceCount = 0;
          }
        }

        // Stabilizers: anti-octave and step clamp relative to previous acceptance
        if (est != null && _prevAcceptedF0 != null) {
          final f = est.frequencyHz;
          final prev = _prevAcceptedF0!;
          // Anti-octave: if ~2x or ~0.5x and not clearly more confident, bias to previous octave
          final ratio = f / prev;
          // Octave penalty growing with register
          final lambdaOct = switch (_registerForFreq(f)) {
            _Register.low => 1.0,
            _Register.med => 2.5,
            _Register.high => 4.0,
          };
          final deltaConfNeeded = 0.05 * lambdaOct;
          if (ratio > 1.95 && ratio < 2.05) {
            if (est.confidence < _prevAcceptedConf + math.max(deltaConfNeeded, (f >= 250 ? 0.08 : 0.0))) {
              est = PitchEstimate(f / 2.0, est.confidence * 0.85);
            }
          } else if (ratio > 0.48 && ratio < 0.52) {
            if (est.confidence < _prevAcceptedConf + deltaConfNeeded) {
              est = PitchEstimate(f * 2.0, est.confidence * 0.85);
            }
          }
          // Energy/register-dependent corridor: dynamic jump limit (in cents)
          final inDecay = _state == _TrackState.decay;
          final corridorCents = _computeCorridorCents(inDecay: inDecay, loudnessRatio: loudnessRatio, reg: _registerForFreq(prev));
          // Step clamp in sustain/decay: limit jumps beyond corridor unless big confidence gain.
          // But if jump is very large and confidence is decent, do NOT clamp (we want fast re-target).
          if (_state == _TrackState.sustain || _state == _TrackState.decay) {
            final centsDelta = 1200.0 * math.log(f / prev) / math.ln2;
            final allowLargeJump = est.confidence >= (_prevAcceptedConf + 0.20);
            final veryLargeJump = centsDelta.abs() > 250.0 && est.confidence >= 0.60;
            if (!veryLargeJump && centsDelta.abs() > corridorCents && !allowLargeJump) {
              final maxRatio = math.pow(2.0, corridorCents / 1200.0) as double;
              final clamped = centsDelta > 0 ? prev * maxRatio : prev / maxRatio;
              est = PitchEstimate(clamped, est.confidence * 0.95);
            }
          }
        }

  // HOLD FSM
        final now = DateTime.now();
        PitchEstimate? accepted;
        if (est == null || est.frequencyHz <= 0) {
          // No estimate: may transition to decay/idle depending on hold
          if (_state == _TrackState.sustain || _state == _TrackState.onset) {
            // Do not unlock on unvoiced/invalid frames; rely on envelope to enter decay
            if (loudnessRatio <= 0.8) {
              _state = _TrackState.decay;
              _stateSince ??= now;
              _holdUntil = now.add(_holdDuration);
            }
          }
        } else {
          // Decide acquire/release based on confidence and loudness
          final meetsAcquire = est.confidence >= confAcquire;
          final meetsRelease = est.confidence >= confRelease;
          // final voicedStrong = est.confidence >= confMinUnlock; // K_unlock rule // unused
          final hasPrev = _prevAcceptedF0 != null;
          final prev = _prevAcceptedF0;
          double centsDeltaAbs = 0.0;
          // Pre-lock: extra-wide capture corridor ±1.2 ST to avoid warm-up rejects
          final bool preLock = (_state == _TrackState.idle || _state == _TrackState.onset) && hasPrev;
          double corridorCents = preLock ? 120.0 : _computeCorridorCents(inDecay: _state == _TrackState.decay, loudnessRatio: loudnessRatio);
          bool outsideCorridor = false;
          if (hasPrev) {
            final f = est.frequencyHz;
            centsDeltaAbs = (1200.0 * math.log(f / prev!) / math.ln2).abs();
            outsideCorridor = centsDeltaAbs > corridorCents;
          }

          // Tuning-aware guard: when locked near B3/E4, reject impossible D#3/D3 alternatives
          if (hasPrev && _state == _TrackState.sustain) {
            final reject = tuningGuard != null ? !(tuningGuard!.call(prev!, est.frequencyHz)) : _rejectImpossibleAlternative(prev!, est.frequencyHz);
            if (reject) {
              // Ignore this candidate completely (does not affect unlock)
              outsideCorridor = false;
            }
          }

          switch (_state) {
            case _TrackState.idle:
              if (meetsAcquire) {
                accepted = est;
                _state = _TrackState.onset;
                _stateSince = now;
                _unlockCounter = 0;
                _lockCount = 1;
                // _everLocked = true; // unused (future feature)
                _agcFreezeUntil = now.add(const Duration(milliseconds: 140));
                _graceUntil ??= now.add(const Duration(milliseconds: 400));
              }
              break;
            case _TrackState.onset:
            case _TrackState.sustain:
              if ((meetsRelease || loudnessRatio >= 1.4) && (!hasPrev || !outsideCorridor)) {
                // Normal continuation within corridor
                accepted = est;
                _state = _TrackState.sustain;
                _stateSince = now;
                _unlockCounter = 0;
                _lockCount++;
                // _everLocked = true; // unused (future feature)
              } else if (hasPrev && outsideCorridor) {
                // Fast unlock path for large, confident jumps (e.g., E4 -> E2)
                final bigJump = centsDeltaAbs >= 350.0; // ~±3.5 ST
                final allowFastUnlock = bigJump && est.confidence >= math.max(confAcquire, 0.60);
                if (allowFastUnlock) {
                  accepted = est;
                  _state = _TrackState.sustain;
                  _stateSince = now;
                  _unlockCounter = 0;
                  _lockCount = 1;
                  _lastUnlockReason = 'bigJumpFast';
                  // _everLocked = true; // unused (future feature)
                } else {
                  // Normal path: require voiced-strong frames, dynamic K for moderate jumps
                  final requiredK = (centsDeltaAbs >= 250.0) ? 1 : _unlockK;
                  final strongEnough = est.confidence >= confMinUnlock;
                  if (strongEnough) {
                    _unlockCounter++;
                    if (_unlockCounter >= requiredK) {
                      accepted = est;
                      _state = _TrackState.sustain;
                      _stateSince = now;
                      _unlockCounter = 0;
                      _lockCount = 1;
                      _lastUnlockReason = requiredK == 1 ? 'largeJump' : 'outsideCorridorStrong';
                      // _everLocked = true; // unused (future feature)
                    }
                  } else {
                    // Low-confidence frames do not affect lock or unlock
                    _unlockCounter = 0;
                  }
                }
              } else {
                // Neither continuation nor strong alternative; only enter decay if energy drops
                if (loudnessRatio <= 0.8) {
                  _state = _TrackState.decay;
                  _stateSince = now;
                  _holdUntil = now.add(_holdDuration);
                }
              }
              break;
            case _TrackState.decay:
              if (meetsAcquire) {
                accepted = est;
                _state = _TrackState.sustain;
                _stateSince = now;
                _unlockCounter = 0;
                _lockCount = 1;
                _lastUnlockReason = 'decayAcquire';
                // _everLocked = true; // unused (future feature)
              } else {
                // remain in decay and possibly emit held value
              }
              break;
          }
        }

        if (accepted != null) {
          // Commit acceptance
          _prevAcceptedF0 = accepted.frequencyHz;
          _prevAcceptedConf = accepted.confidence;
          _recentAcceptedF0.add(accepted.frequencyHz);
          if (_recentAcceptedF0.length > _recentAcceptedLen) {
            _recentAcceptedF0.removeAt(0);
          }
          _controller.add(PitchFrame(
            frequencyHz: accepted.frequencyHz,
            confidence: accepted.confidence,
            timestamp: now,
          ));
          _displayGateReason = 'locked';
          _writeTelemetryRow(nowMs: now.millisecondsSinceEpoch, rms: rms, agcGain: _agcGain, peakDb: peakDb, est: accepted, voiced: true, percussive: isSpike, regLabel: _registerForFreq(accepted.frequencyHz).name, corridorCents: 0.0, cents: 0.0);
          continue;
        }

        // No new acceptance this frame: possibly hold during decay
        if (_state == _TrackState.decay && _prevAcceptedF0 != null) {
          final stillHolding = (_holdUntil != null && now.isBefore(_holdUntil!));
          final envOk = _envEma >= (_rmsMedian * 0.75);
          if (stillHolding && envOk) {
            // Use median of recent accepted f0 for stability
            double heldF0 = _prevAcceptedF0!;
            if (_recentAcceptedF0.isNotEmpty) {
              final sorted = _recentAcceptedF0.toList()..sort();
              heldF0 = sorted[sorted.length ~/ 2];
            }
            final holdConf = math.max(0.45, _prevAcceptedConf * 0.9);
            _controller.add(PitchFrame(
              frequencyHz: heldF0,
              confidence: holdConf,
              timestamp: now,
            ));
            _displayGateReason = 'decay_hold';
            _writeTelemetryRow(nowMs: now.millisecondsSinceEpoch, rms: rms, agcGain: _agcGain, peakDb: peakDb, est: PitchEstimate(heldF0, holdConf), voiced: true, percussive: isSpike, regLabel: _registerForFreq(heldF0).name, corridorCents: 0.0, cents: 0.0);
            continue;
          } else {
            // Release hold
            _state = _TrackState.idle;
            _stateSince = now;
            _holdUntil = null;
            _unlockCounter = 0;
          }
        }
        // Default: gating logic. If in grace or we have ever locked before, keep displaying
        final bool inGrace = _graceUntil != null && DateTime.now().isBefore(_graceUntil!);
        if (inGrace && est != null && est.frequencyHz > 0) {
          // Show chromatic candidate during grace even if not locked
          _controller.add(PitchFrame(frequencyHz: est.frequencyHz, confidence: est.confidence, timestamp: now));
          _displayGateReason = 'prelock';
          _writeTelemetryRow(nowMs: now.millisecondsSinceEpoch, rms: rms, agcGain: _agcGain, peakDb: peakDb, est: est, voiced: true, percussive: isSpike, regLabel: reg.name, corridorCents: 0.0, cents: 0.0);
          continue;
        }
        // No post-lock infinite hold; outside decay/grace we let display blank if not voiced
        // Emit unvoiced when nothing to display
        _controller.add(PitchFrame(frequencyHz: 0.0, confidence: 0.0, timestamp: now));
        _displayGateReason = 'low_conf';
        _writeTelemetryRow(nowMs: now.millisecondsSinceEpoch, rms: rms, agcGain: _agcGain, peakDb: peakDb, est: null, voiced: false, percussive: isSpike, regLabel: 'na', corridorCents: 0.0, cents: 0.0);

        // Stop capture after duration
        if (_captureActive && _captureStart != null) {
          final elapsed = DateTime.now().difference(_captureStart!).inMilliseconds;
          if (elapsed >= (_captureMaxSamples * 1000 / sampleRate)) {
            await _endCaptureAndWrite();
          }
        }
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

  Future<void> _initBackend() async {
    switch (backend) {
      case InferenceBackend.none:
        return;
      case InferenceBackend.tflite:
        try {
          if (modelAsset != null) {
            _tflite = await tfl.Interpreter.fromAsset(modelAsset!);
          }
        } catch (_) {
          _tflite = null;
        }
        return;
      case InferenceBackend.onnx:
        try {
          if (modelAsset != null) {
            // ignore: avoid_print
              debugPrint('MicEngine: Loading ONNX asset $modelAsset...');
            final bytes = await _loadAssetBytes(modelAsset!);
            // ignore: avoid_print
              debugPrint('MicEngine: Asset loaded, ${bytes.length} bytes');
            final env = onnx.OrtEnv.instance;
            final opts = onnx.OrtSessionOptions();
            // Use dynamic to call whichever factory method exists in this package version
            final sessionClass = onnx.OrtSession;
            // ignore: avoid_print
              debugPrint('MicEngine: Creating ONNX session...');
            _onnxSession = (sessionClass as dynamic).fromBytes(env, bytes, opts);
            if (_onnxSession is Future) {
              _onnxSession = await _onnxSession; // await if async
            }
            // ignore: avoid_print
              debugPrint('MicEngine: ONNX session created successfully');
          } else {
            // ignore: avoid_print
              debugPrint('MicEngine: No modelAsset provided for ONNX backend');
          }
        } catch (e, stack) {
          // ignore: avoid_print
            debugPrint('MicEngine: ONNX initialization failed: $e');
          // ignore: avoid_print
            debugPrint('MicEngine: Stack trace: $stack');
          _onnxSession = null; // fallback will be used
        }
        return;
    }
  }

  Future<PitchEstimate?> _infer(List<double> samples) async {
    switch (backend) {
      case InferenceBackend.none:
        return null;
      case InferenceBackend.tflite:
        if (_tflite == null) return null;
        // Placeholder: without a concrete model spec, fall back to DSP.
        return null;
      case InferenceBackend.onnx:
        if (_onnxSession == null) return null;
        try {
          // Prepare input tensor [1, audio_length] float32
          final input = Float32List.fromList(samples.map((e) => e.toDouble()).toList());
          final shape = [1, input.length];
          final tensorCreator = (onnx.OrtValueTensor as dynamic);
          final inputTensor = tensorCreator.createTensorFloat(input, shape);
          final inputs = {
            'input_audio': inputTensor,
          };
          final outputs = await _runOnnx(inputs);
          // FORCE LOG: always print ONNX outputs (or empty/error) so diagnostics are visible
          try {
            if (outputs.isNotEmpty) {
              final pitchTensor = outputs['pitch_hz'];
              final confTensor = outputs['confidence'];
              final pitch = _tensorToFloatList(pitchTensor);
              final conf = _tensorToFloatList(confTensor);
              final len = math.min(pitch.length, conf.length);
              final inputMs = (samples.length * 1000.0) / sampleRate;
              // ignore: avoid_print
                debugPrint('$_instanceId ONNX OUT: pitch_hz=${pitch.map((v) => v.toStringAsFixed(2)).toList()}');
              // ignore: avoid_print
                debugPrint('$_instanceId ONNX OUT: confidence=${conf.map((v) => v.toStringAsFixed(3)).toList()}');
              // ignore: avoid_print
                debugPrint('$_instanceId ONNX OUT: len=$len, input_ms=${inputMs.toStringAsFixed(1)}');
            } else {
              // indicate ONNX returned empty outputs (helps debug asset/session issues)
              // ignore: avoid_print
                debugPrint('$_instanceId ONNX OUT: <empty outputs>');
            }
          } catch (e) {
            // ensure we never crash logging
            // ignore: avoid_print
              debugPrint('$_instanceId ONNX OUT: <error serializing outputs> $e');
          }
          // Expect outputs by names 'pitch_hz' and 'confidence'
          final pitchTensor = outputs['pitch_hz'];
          final confTensor = outputs['confidence'];
          final pitch = _tensorToFloatList(pitchTensor);
          final conf = _tensorToFloatList(confTensor);
          if (pitch.isEmpty || conf.isEmpty) return null;
          // Aggregation: keep frames >= p70 confidence, require kept>=3 else fallback to argmax(conf)
          final len = math.min(pitch.length, conf.length);
          final confSorted = conf.sublist(0, len).toList()..sort();
          final p70Idx = (0.7 * (confSorted.length - 1)).clamp(0, confSorted.length - 1).toInt();
          final p70 = confSorted[p70Idx];
          final filteredP = <double>[];
          final filteredC = <double>[];
          for (int i = 0; i < len; i++) {
            if (conf[i] + 1e-12 >= p70) {
              filteredP.add(pitch[i]);
              filteredC.add(conf[i]);
            }
            // Write raw ONNX outputs per-frame
            if (_captureActive) {
              _captureOnnxCsv.write('$i,${pitch[i].toStringAsFixed(6)},${conf[i].toStringAsFixed(6)}\n');
            }
          }
          double f0;
          double confOut;
          _lastKeptCount = filteredP.length;
          _lastFallbackReason = '';
          if (filteredP.length >= 3) {
            filteredP.sort();
            filteredC.sort();
            f0 = filteredP[filteredP.length ~/ 2];
            confOut = filteredC[filteredC.length ~/ 2];
          } else {
            // Fallback: argmax(conf)
            int maxIdx = 0;
            double maxConf = -1.0;
            for (int i = 0; i < len; i++) {
              if (conf[i] > maxConf) { maxConf = conf[i]; maxIdx = i; }
            }
            f0 = pitch[maxIdx];
            confOut = conf[maxIdx];
            _lastFallbackReason = 'kept<3';
          }
          // Store last ONNX arrays for telemetry context
          // _lastOnnxPitch = pitch.sublist(0, len).toList(); // unused
          // _lastOnnxConf = conf.sublist(0, len).toList(); // unused
          _lastOnnxMedianPitch = f0;
          _lastOnnxMedianConf = confOut;
          return PitchEstimate(f0, confOut);
        } catch (_) {
          return null; // fallback to DSP
        }
    }
  }

  List<double> _i16LeToDoubles(List<int> bytes) {
    final bd = ByteData.sublistView(Uint8List.fromList(bytes));
    final out = List<double>.filled(bytes.length ~/ 2, 0);
    for (int i = 0; i < out.length; i++) {
      final s = bd.getInt16(i * 2, Endian.little);
      out[i] = s / 32768.0;
    }
    return out;
  }

  // First-order high-pass filter coefficient (simple differentiator-like)
  double _firstOrderHpAlpha(double cutoff, int fs) {
    final rc = 1.0 / (2 * math.pi * cutoff);
    final dt = 1.0 / fs;
    return rc / (rc + dt);
  }

  // First-order low-pass filter coefficient (exponential smoothing)
  double _firstOrderLpBeta(double cutoff, int fs) {
    final rc = 1.0 / (2 * math.pi * cutoff);
    final dt = 1.0 / fs;
    return dt / (rc + dt);
  }

  List<double> _applyBandPass(List<double> x) {
    final out = List<double>.filled(x.length, 0.0);
    for (int i = 0; i < x.length; i++) {
      final xi = x[i];
      // High-pass
      final yhp = _hpAlpha * (_hpPrevY + xi - _hpPrevX);
      _hpPrevY = yhp;
      _hpPrevX = xi;
      // Low-pass
      _lpPrevY = _lpPrevY + _lpBeta * (yhp - _lpPrevY);
      out[i] = _lpPrevY;
    }
    return out;
  }

  // Removed Goertzel-based heuristic: YIN handles octave errors more robustly

  // Compute dynamic corridor width (in cents) depending on energy and decay state
  double _computeCorridorCents({required bool inDecay, required double loudnessRatio, _Register reg = _Register.med}) {
    // Default normal corridor ~ ±0.6 ST (60c), then adjust by energy
    double base = 60.0;
    if (loudnessRatio <= 1.0) {
      base -= 10.0; // tighten on low energy
    } else if (loudnessRatio >= 1.6 && !inDecay) {
      base += 10.0; // widen slightly on strong energy when not in decay
    }
    if (inDecay) {
      // Decay targets per register from spec
      switch (reg) {
        case _Register.low:
          base = 80.0; // ±0.8 ST
          break;
        case _Register.med:
          base = 60.0; // ±0.6 ST
          break;
        case _Register.high:
          base = 60.0; // widen to ±0.6 ST for high register in decay
          break;
      }
    }
    return base.clamp(30.0, 100.0);
  }

  // Lightweight Goertzel power estimator at frequency f0
  double _goertzelPower(List<double> x, double f0, int fs) {
    final int N = x.length;
    if (N <= 0) return 0.0;
    final double k = (0.5 + (N * f0) / fs).floorToDouble();
    final double w = (2.0 * math.pi * k) / N;
    final double cosw = math.cos(w);
    final double coeff = 2.0 * cosw;
    double s0 = 0.0, s1 = 0.0, s2 = 0.0;
    for (int i = 0; i < N; i++) {
      s0 = x[i] + coeff * s1 - s2;
      s2 = s1;
      s1 = s0;
    }
    final double power = s1 * s1 + s2 * s2 - coeff * s1 * s2;
    return power;
  }

  // Tuning-aware guard to reject impossible alternatives near B3/E4 when locked
  bool _rejectImpossibleAlternative(double prevHz, double candidateHz) {
    // Focus on guitar standard E4 (~329.6 Hz) and B3 (~246.9 Hz)
    // If locked near these, reject alternatives that are around D#3/D3 region
    bool near(double f, double target, double cents) {
      final delta = 1200.0 * math.log(f / target) / math.ln2;
      return delta.abs() <= cents;
    }
  const double e4 = 329.628; // Hz
  const double b3 = 246.942; // Hz
  const double dSharp3 = 155.563; // D#3/Eb3
  const double d3 = 146.832; // D3
    // If previously locked near B3 or E4
    if (near(prevHz, b3, 70) || near(prevHz, e4, 70)) {
      if (near(candidateHz, dSharp3, 60) || near(candidateHz, d3, 60)) {
        return true; // reject switch to impossible alternative
      }
    }
    return false;
  }

  _Register _registerForFreq(double f) {
    if (f < 140.0) return _Register.low; // E2/A2 region
    if (f < 230.0) return _Register.med; // D3/G3 region
    return _Register.high; // B3/E4 region
  }

  Future<Uint8List> _loadAssetBytes(String asset) async {
    final data = await rootBundle.load(asset);
    return data.buffer.asUint8List();
  }

  Future<Map<String, dynamic>> _runOnnx(Map<String, dynamic> inputs) async {
    // Use dynamic calls to accommodate API differences across versions.
    final sess = _onnxSession;
    if (sess == null) return {};
    final result = await (sess as dynamic).run(inputs);
    // Result may be List or Map depending on API; try to map by names if possible.
    if (result is Map) return Map<String, dynamic>.from(result);
    if (result is List) {
      // If it's a list, we cannot know names; return empty to trigger fallback
      return {};
    }
    return {};
  }

  List<double> _tensorToFloatList(dynamic tensor) {
    if (tensor == null) return const [];
    // Common accessors: .data, .value, .floatData, or directly Float32List
    final v = (tensor is Float32List || tensor is Float64List)
        ? tensor
        : (tensor as dynamic).value ?? (tensor as dynamic).data ?? tensor;
    if (v is Float32List) return v.toList();
    if (v is Float64List) return v.map((e) => e.toDouble()).toList();
    if (v is List) return v.map((e) => (e as num).toDouble()).toList();
    return const [];
  }

  // Capture helpers
  void _beginCapture({required int durationSeconds, String label = 'e4'}) {
    _captureActive = true;
    _captureStart = DateTime.now();
    _captureLabel = label;
    _captureMaxSamples = durationSeconds * sampleRate;
    _captureRawPcm.clear();
    _capturePreOnnxPcm.clear();
    _captureOnnxCsv.clear();
    _captureOnnxCsv.write('t_idx,pitch_hz,confidence\n');
  _captureTelemetryCsv.clear();
  _captureTelemetryCsv.write('ts_ms,frame_idx,sr_effective,rms_dbfs,agc_gain,peak_dbfs,f0_raw,conf_raw,f0_kept_quantile,conf_kept_quantile,kept_count,fallback_reason,harm_ratio,applied_harm_fix,voiced,percussive,state,locked,in_grace,displayGateReason,register,corridor_min_cents,corridor_max_cents,cents,N_lock,K_unlock,unlock_reason\n');
    _frameIdx = 0;
    _lockCount = 0;
    _lastUnlockReason = '';
  }

  Future<void> _endCaptureAndWrite() async {
    _captureActive = false;
    try {
      final dir = await getTemporaryDirectory();
      final base = io.Directory('${dir.path}/tuner_capture_${_captureLabel}_${DateTime.now().millisecondsSinceEpoch}');
      await base.create(recursive: true);
      // Write WAVs (raw and pre-ONNX)
      await _writeWav(io.File('${base.path}/e4_raw_16k_mono.wav'), _captureRawPcm, sampleRate);
      await _writeWav(io.File('${base.path}/e4_preonnx_16k_mono.wav'), _capturePreOnnxPcm, sampleRate);
      // Write ONNX outputs and telemetry
      await io.File('${base.path}/onnx.csv').writeAsString(_captureOnnxCsv.toString());
      await io.File('${base.path}/telemetry.csv').writeAsString(_captureTelemetryCsv.toString());
      if (debugOnnx) {
        // ignore: avoid_print
        print('MicEngine: capture written to ${base.path}');
      }
    } catch (_) {
      // swallow
    }
  }

  Future<void> _writeWav(io.File file, List<int> pcmBytes, int sr) async {
    // 16-bit PCM mono WAV header
    final dataLen = pcmBytes.length;
    final totalLen = 44 + dataLen;
    final bd = ByteData(totalLen);
    void putStr(int offset, String s) {
      final bytes = s.codeUnits;
      for (int i = 0; i < bytes.length; i++) {
        bd.setUint8(offset + i, bytes[i]);
      }
    }
    putStr(0, 'RIFF');
    bd.setUint32(4, totalLen - 8, Endian.little);
    putStr(8, 'WAVE');
    putStr(12, 'fmt ');
    bd.setUint32(16, 16, Endian.little); // PCM chunk size
    bd.setUint16(20, 1, Endian.little); // PCM format
    bd.setUint16(22, 1, Endian.little); // mono
    bd.setUint32(24, sr, Endian.little);
    bd.setUint32(28, sr * 2, Endian.little); // byte rate
    bd.setUint16(32, 2, Endian.little); // block align
    bd.setUint16(34, 16, Endian.little); // bits per sample
    putStr(36, 'data');
    bd.setUint32(40, dataLen, Endian.little);
    final out = <int>[
      ...bd.buffer.asUint8List(0, 44),
      ...pcmBytes,
    ];
    await file.writeAsBytes(out, flush: true);
  }

  void _writeTelemetryRow({required int nowMs, required double rms, required double agcGain, required double peakDb, required PitchEstimate? est, required bool voiced, required bool percussive, required String regLabel, required double corridorCents, required double cents}) {
    final rmsDb = 20.0 * math.log((rms + 1e-12)) / math.ln10;
    final stateStr = switch (_state) { _TrackState.idle => 'Idle', _TrackState.onset => 'Onset', _TrackState.sustain => 'Sustain', _TrackState.decay => 'Decay' };
    final locked = (_state == _TrackState.onset || _state == _TrackState.sustain || _state == _TrackState.decay) && _prevAcceptedF0 != null;
    final f0Raw = _lastOnnxMedianPitch;
    final confRaw = _lastOnnxMedianConf;
    final inGrace = _graceUntil != null && DateTime.now().isBefore(_graceUntil!);
    final row = '$nowMs,$_frameIdx++,$sampleRate,${rmsDb.toStringAsFixed(2)},${agcGain.toStringAsFixed(3)},${peakDb.toStringAsFixed(2)},${f0Raw.toStringAsFixed(3)},${confRaw.toStringAsFixed(3)},${f0Raw.toStringAsFixed(3)},${confRaw.toStringAsFixed(3)},$_lastKeptCount,$_lastFallbackReason,${_lastHarmRatio.toStringAsFixed(3)},$_appliedHarmFix,$voiced,$percussive,$stateStr,$locked,$inGrace,$_displayGateReason,$regLabel,${(-corridorCents).toStringAsFixed(1)},${corridorCents.toStringAsFixed(1)},${cents.toStringAsFixed(1)},$_lockCount,$_unlockCounter,$_lastUnlockReason\n';
    _captureTelemetryCsv.write(row);
  }
}
