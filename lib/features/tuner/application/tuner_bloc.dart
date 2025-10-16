import 'dart:async';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../core/note_utils.dart';
import '../engine/pitch_engine_interface.dart';
import '../core/pipeline/processor.dart';
import '../core/pipeline/lock_tracker.dart';
import '../core/tuning/tuning_manager.dart';
import '../core/tuning/tuning_preset.dart';
import '../infrastructure/tuning_persistence.dart';

part 'tuner_event.dart';
part 'tuner_state.dart';

abstract class PermissionRepository {
  Future<bool> hasMicPermission();
  Future<bool> requestMicPermission();
  Future<bool> isMicPermanentlyDenied();
  Future<bool> openAppSettings();
}

class MockPermissionRepository implements PermissionRepository {
  bool granted;
  bool permanentlyDenied;
  MockPermissionRepository({this.granted = false, this.permanentlyDenied = false});
  @override
  Future<bool> hasMicPermission() async => granted;
  @override
  Future<bool> requestMicPermission() async => granted;
  @override
  Future<bool> isMicPermanentlyDenied() async => permanentlyDenied;
  @override
  Future<bool> openAppSettings() async => true;
}

class TunerBloc extends Bloc<TunerEvent, TunerState> {
  final PermissionRepository permissions;
  final PitchEngine engine;
  final PitchPostProcessor _processor = PitchPostProcessor();
  final LockTracker _lockTracker = LockTracker(
    centsTolerance: 8.0, // more tolerant for high notes (G3+ ~196Hz)
    stableCountRequired: 2, // faster lock for responsiveness
    acquireConfidence: 0.75, // lower threshold for high notes
    releaseConfidence: 0.55, // more permissive to maintain lock longer
    lockCorridorCents: 80.0, // narrower base corridor; bass still widened in LockTracker
    lockCountRequired: 4, // fast auto-lock establishment
    unlockCountRequired: 12, // slightly easier to adapt when truly off
  );
  // Separate display gate: even more permissive show conditions
  final LockTracker _displayGate = LockTracker(
    centsTolerance: 30.0, // a bit tighter to reduce "compressed" feel near 0–1 cent
    stableCountRequired: 2, // fast display
    acquireConfidence: 0.58, // slightly lower threshold; helps E2/A2 initial view
    releaseConfidence: 0.48, // keep showing even with lower confidence
  );
  // Warm-up accumulation of consistent frames before first display
  int _warmCount = 0;
  final int _warmRequired = 1; // ~80ms with our hop - snappier initial reveal
  // Hold-time of last stable note to hide brief dropouts
  int _holdCountdown = 0;
  final int _holdMaxFrames = 2; // ~160ms at 80ms hop
  TunerState? _lastReady;
  // Hysteresis for confidence thresholds to prevent saccades
  bool _wasAboveThreshold = false;
  final TuningManager _tuning = TuningManager();
  final TuningPersistence _persistence = TuningPersistence();
  
  // Electric guitar stability improvements
  // Removed unused histories/aggregates; keep logic concise
  StreamSubscription<PitchFrame>? _sub;
  
  // Sticky-string: remember current string and require evidence to switch
  int? _currentStringIdx; // null until first stable detection
  int _stickFrames = 0; // counts frames reinforcing current string
  int _switchProbeFrames = 0; // counts frames suggesting a different string
  int _farFromCurrentFrames = 0; // counts frames far from current target
  // Removed unused _minStickFramesForLock; we already use _stickFrames in decisions
  static const int _minFramesToSwitch = 3; // require multiple consecutive frames to switch
  static const double _nearCentsStick = 35.0; // keep current when within this range
  static const double _candidateImprovesByCents = 15.0; // candidate must be that much closer than current
  static const int _farResetFrames = 2; // frames far from current before dropping it

  TunerBloc({required this.permissions, required this.engine}) : super(const TunerState.initial()) {
    void debugLog(String msg) {
      assert(() {
  // ignore: avoid_print
  // print(msg); // Bloc log désactivé
        return true;
      }());
    }
    on<TunerStarted>((event, emit) async {
      // For debug: start engine regardless of microphone permission so ONNX logs are visible
      final ok = await permissions.hasMicPermission();
      if (!ok) {
        // Start engine anyway for debugging logs (do not await blocking UI flows)
        // Log engine instance id when available
        try {
          final id = (engine as dynamic).instanceId;
          debugPrint('TunerBloc: starting engine instance $id (permission missing)');
        } catch (_) {}
        unawaited(engine.start());
        final permDenied = await permissions.isMicPermanentlyDenied();
        emit(permDenied ? const TunerState.permissionPermanentlyDenied() : const TunerState.permissionDenied());
        return;
      }
      emit(const TunerState.warmUp());
      // Start engine and listen to frames
      try {
        final id = (engine as dynamic).instanceId;
        debugPrint('TunerBloc: starting engine instance $id');
      } catch (_) {}
      await engine.start();
      await _sub?.cancel();
      _sub = engine.frames.listen((frame) {
        add(TunerFrame(frame));
      });
      // Restore tuning in background after UI shows warm-up
      // Intentionally not awaited to avoid blocking initial UI/tests
      unawaited(_restoreTuning());
    });
    on<TunerRequestPermission>((event, emit) async {
      final ok = await permissions.requestMicPermission();
      if (ok) {
        emit(const TunerState.warmUp());
        await engine.start();
        await _sub?.cancel();
        _sub = engine.frames.listen((frame) {
          add(TunerFrame(frame));
        });
        unawaited(_restoreTuning());
      } else {
        final permDenied = await permissions.isMicPermanentlyDenied();
        emit(permDenied ? const TunerState.permissionPermanentlyDenied() : const TunerState.permissionDenied());
      }
    });
    on<TunerOpenSettings>((event, emit) async {
      await permissions.openAppSettings();
    });

    on<TunerFrame>((event, emit) {
      // Debug: log incoming frames
      // Throttle logs to avoid flooding
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs % 1500 < 100) {
        debugLog('Bloc: frame f=${event.frame.frequencyHz.toStringAsFixed(1)} Hz, c=${event.frame.confidence.toStringAsFixed(3)}');
      }
      
      
      // Adaptive confidence threshold with hysteresis to prevent saccades
      double baseConfThreshold = 0.7; // Default for mid-high strings
      if (event.frame.frequencyHz > 0 && event.frame.frequencyHz < 95) {
        baseConfThreshold = 0.58; // More permissive for E2 (~82Hz)
      } else if (event.frame.frequencyHz < 135) {
        baseConfThreshold = 0.64; // Slightly more permissive for A2 (~110Hz)
      }
      
      // Apply hysteresis: once above threshold, easier to stay above
      double confThreshold = _wasAboveThreshold 
          ? baseConfThreshold - 0.05  // 5% hysteresis window
          : baseConfThreshold;
      
      // Unvoiced or low confidence → show no note and no lock
      if (event.frame.confidence < confThreshold || event.frame.frequencyHz <= 0) {
        _lockTracker.update(1000, 0); // force unlock
        _displayGate.update(1000, 0);
        _warmCount = 0; // reset warm-up when unvoiced
        _wasAboveThreshold = false; // reset hysteresis
        // Hold last ready state briefly to avoid visual drops
        if (_lastReady != null && _holdCountdown > 0) {
          _holdCountdown--;
          emit(_lastReady!);
        } else {
          debugLog('Bloc: warmUp (unvoiced/low-conf) c=${event.frame.confidence.toStringAsFixed(3)} f=${event.frame.frequencyHz.toStringAsFixed(1)}');
          emit(const TunerState.warmUp());
        }
        return;
      }
      
      // Update hysteresis state
      _wasAboveThreshold = event.frame.confidence >= baseConfThreshold;
  final smoothed = _processor.process(event.frame.frequencyHz);
  // Evaluate vs active tuning (nearest string)
  // Option B: Validate frequency against current string expectations
  var correctedHz = smoothed;
  if (_currentStringIdx != null) {
    final targetNote = _tuning.active.notes[_currentStringIdx!];
    correctedHz = _validateFrequencyForString(smoothed, targetNote);
  }
  
  // Evaluate nearest string and (if set) the current string explicitly
  final evalNearest = _tuning.evaluate(correctedHz);
  TuningEvaluation? evalCurrent = _currentStringIdx != null
      ? _tuning.evaluateForIndex(correctedHz, _currentStringIdx!)
      : null;
  var eval = evalNearest; // default to nearest; may be replaced by current after decision
  var displayHz = smoothed;
  // Tuning-aware octave check: covers both high and low frequencies
  // High frequencies (E4+ harmonics)
  if (smoothed > 250) {
    final evalHalf = _tuning.evaluate(smoothed / 2.0);
    // E4-specific easing: high E string often flips to E5 harmonic (~659 Hz)
    final isE4 = eval.stringLabel == 'E4' || _tuning.active.notes.last == 'E4';
    final strongImprovement = eval.cents.abs() - evalHalf.cents.abs() > 30;
    final e4Improvement = isE4 && smoothed > 500 && (eval.cents.abs() - evalHalf.cents.abs() > 10);
    if (strongImprovement || e4Improvement) {
      eval = evalHalf;
      displayHz = smoothed / 2.0;
    }
  }
  // Low frequencies (E2/A2 sub-harmonics)  
  else if (smoothed < 100) {
    final evalDouble = _tuning.evaluate(smoothed * 2.0);
    // Bass-specific correction: E1→E2, A1→A2 when it dramatically improves fit
    final isBassString = eval.stringLabel == 'E2' || eval.stringLabel == 'A2';
    final bassImprovement = isBassString && smoothed < 70 && (eval.cents.abs() - evalDouble.cents.abs() > 50);
    final strongBassImprovement = eval.cents.abs() - evalDouble.cents.abs() > 100;
    if (bassImprovement || strongBassImprovement) {
      eval = evalDouble;
      displayHz = smoothed * 2.0;
    }
  }
  // Decide whether to keep or switch current string based on evidence (comparative)
  if (_currentStringIdx == null) {
    _currentStringIdx = evalNearest.stringIndex;
    _stickFrames = 0;
    _switchProbeFrames = 0;
    eval = evalNearest;
  } else {
    // We have a current string; compare candidate vs current
    final cur = evalCurrent ?? _tuning.evaluateForIndex(smoothed, _currentStringIdx!);
    final cand = evalNearest;
    
    // If close to current target, stick to it
    if (cur.cents.abs() <= _nearCentsStick) {
      eval = cur;
      _stickFrames = (_stickFrames + 1).clamp(0, 1000);
      _switchProbeFrames = 0;
      _farFromCurrentFrames = 0;
    } else {
      // Far from current; consider switching if candidate is clearly better
      final improves = (cur.cents.abs() - cand.cents.abs()) >= _candidateImprovesByCents;
      if (cand.stringIndex != _currentStringIdx && improves && event.frame.confidence >= 0.72) {
        _switchProbeFrames++;
        if (_switchProbeFrames >= _minFramesToSwitch) {
          _currentStringIdx = cand.stringIndex;
          eval = cand;
          _stickFrames = 0;
          _switchProbeFrames = 0;
          _farFromCurrentFrames = 0;
        } else {
          // Not enough persistence yet; still display current to avoid flicker
          eval = cur;
        }
      } else {
        // Candidate not clearly better; keep current
        eval = cur;
        _switchProbeFrames = 0;
      }
      // Track far-from-current frames to allow reset if totally wrong
      _farFromCurrentFrames = cur.cents.abs() > 140 ? (_farFromCurrentFrames + 1) : 0;
      if (_farFromCurrentFrames >= _farResetFrames) {
        // Drop current to allow quick re-acquisition
        _currentStringIdx = null;
        _farFromCurrentFrames = 0;
      }
    }
  }

  // Option D: Reject frames with impossible cents (coherence filter)
  if (eval.cents.abs() > 600) {
    // Skip this frame - cents too extreme, likely octave detection error
    // Hold last ready state or show warm-up
    if (_lastReady != null && _holdCountdown > 0) {
      _holdCountdown--;
      emit(_lastReady!);
    } else {
      emit(const TunerState.warmUp());
    }
    return;
  }
  
  final info = analyzeFrequency(displayHz);
  // Override cents with tuning-based cents to target+offset
  final centsForLock = eval.cents;
  // Enhanced auto-lock
  final locked = _lockTracker.updateWithAutoLock(centsForLock, event.frame.confidence, smoothed, info.display);

      // Warm-up: require a few consistent frames before first display
      final displayReady = _displayGate.update(info.cents, event.frame.confidence);
      // Also advance warm-up on any solid frame (adaptive threshold), even if display gate isn't stable yet
      final warmTick = (event.frame.confidence >= confThreshold && event.frame.frequencyHz > 0) || displayReady;
      if (!warmTick || _warmCount < _warmRequired) {
        _warmCount = warmTick ? (_warmCount + 1) : 0;
  debugLog('Bloc: warmUp gating displayReady=$displayReady warmTick=$warmTick warmCount=$_warmCount conf=${event.frame.confidence.toStringAsFixed(2)} cents=${info.cents.toStringAsFixed(1)}');
        emit(const TunerState.warmUp());
        return;
      }

      // Learn per-string offset if stable - DISABLED: was causing cents compression
      // The auto-learning was constantly adjusting target frequencies toward measured values,
      // making it appear like strings were always near 0 cents when locked
      // if (locked) {
      //   _tuning.learnOffset(eval.stringIndex, smoothed);
      //   // Persist offsets occasionally (could throttle in future)
      //   _persistence.saveOffsets(_tuning.offsets);
      // }
      final capo = _tuning.detectCapo();
      final nextState = TunerState.ready(
        note: info.display,
        cents: eval.cents,
        frequency: displayHz,
        locked: locked,
        tuningName: _tuning.active.name,
        stringLabel: eval.stringLabel,
        capo: capo,
      );
  debugLog('Bloc: READY note=${nextState.note} freq=${nextState.frequency?.toStringAsFixed(1)} cents=${nextState.cents?.toStringAsFixed(1)} locked=${nextState.locked}');
      emit(nextState);
      _lastReady = nextState;
      _holdCountdown = _holdMaxFrames; // refresh hold after valid frame
    });

    on<TunerChangePreset>((event, emit) async {
      final preset = _presetByName(event.presetName);
      _tuning.setActive(preset);
      await _persistence.savePresetName(preset.name);
      await _persistence.saveOffsets(_tuning.offsets);
      // Reset warm-up briefly to hide transitions
      _warmCount = 0;
      emit(const TunerState.warmUp());
    });
  }

  @override
  Future<void> close() async {
    await _sub?.cancel();
    await engine.stop();
    return super.close();
  }

  Future<void> _restoreTuning() async {
    final name = await _persistence.loadPresetName();
    if (name != null) {
      _tuning.setActive(_presetByName(name));
    }
    final offs = await _persistence.loadOffsets();
    if (offs != null) {
      _tuning.setOffsets(offs);
    }
  }

  TuningPreset _presetByName(String name) {
    // Try built-ins and capo pattern
    final built = BuiltInTunings.all();
    final found = built.firstWhere(
      (p) => p.name == name,
      orElse: () => _tryCapoName(name) ?? BuiltInTunings.standard,
    );
    return found;
  }

  TuningPreset? _tryCapoName(String name) {
    final m = RegExp(r'^Capo\s+(\d+)$').firstMatch(name);
    if (m == null) return null;
    final k = int.tryParse(m.group(1)!);
    if (k == null) return null;
    return BuiltInTunings.capo(k);
  }

  // Option B: Validate frequency against string expectations (anti-octave for sticky strings)
  double _validateFrequencyForString(double hz, String targetNote) {
    // Define expected frequency ranges for each string
    final expectedRanges = {
      'E2': [70.0, 95.0],   // Low E: ~82Hz
      'A2': [95.0, 125.0],  // A: ~110Hz
      'D3': [135.0, 165.0], // D: ~147Hz
      'G3': [180.0, 210.0], // G: ~196Hz
      'B3': [230.0, 260.0], // B: ~247Hz
      'E4': [310.0, 350.0], // High E: ~330Hz
    };

    final range = expectedRanges[targetNote];
    if (range == null) return hz; // Unknown string, no validation

    final minHz = range[0];
    final maxHz = range[1];
    var corrected = hz;

    // If way below range, likely sub-harmonic - double it
    if (corrected < minHz * 0.7) {
      corrected = corrected * 2.0;
    }

    // If way above range, likely harmonic - halve it
    if (corrected > maxHz * 1.4) {
      corrected = corrected / 2.0;
    }

    // Apply range again after correction
    if (corrected < minHz * 0.7) {
      corrected = corrected * 2.0;
    }

    return corrected;
  }
}
