import 'dart:math' as math;

enum TrackState { search, locked, frozen }

class TrackerConfig {
  const TrackerConfig({
    this.lockWindowCents = 25, // More tolerance for lock
    this.holdInMs = 150, // Faster lock confirmation
    this.holdOutMs = 800, // Much longer before unlock (0.8s of bad signal)
    this.snrEnterDb = 6, // Lower threshold to lock easier
    this.snrExitDb = 3, // Lower threshold to stay locked longer
    this.maxJumpSearchCents = 200,
    this.maxJumpLockedCents = 80, // More tolerance when locked
    this.alpha = 0.7, // More responsive
    this.beta = 0.3,
    this.shieldEnabled = true,
    this.shieldMs = 150,
    this.energyJumpDb = 15, // Less sensitive to transients
    this.sfmThresh = -1.5,
    this.harmonicityDrop = 0.20,
  });

  final double lockWindowCents;
  final int holdInMs;
  final int holdOutMs;
  final double snrEnterDb;
  final double snrExitDb;
  final double maxJumpSearchCents;
  final double maxJumpLockedCents;
  final double alpha;
  final double beta;
  final bool shieldEnabled;
  final int shieldMs;
  final double energyJumpDb;
  final double sfmThresh; // spectral flatness (log domain), lower is tonal
  final double harmonicityDrop; // drop threshold for declaring transient
}

class TrackerState {
  TrackerState({
    required this.state,
    required this.f0,
    required this.centsError,
    required this.snrDb,
    required this.isTransient,
  });
  final TrackState state;
  final double? f0;
  final double centsError; // vs tempered nearest
  final double snrDb;
  final bool isTransient;
}

class PitchTracker {
  PitchTracker(this._cfg);

  final TrackerConfig _cfg;
  TrackState _state = TrackState.search;
  double? _f0Pred; // predicted by alpha-beta
  double _v = 0.0; // velocity in cents/frame
  int _stateTimerMs = 0;
  int _shieldTimerMs = 0;
  double? _prevRmsDb;

  void reset() {
    _state = TrackState.search;
    _f0Pred = null;
    _v = 0.0;
    _stateTimerMs = 0;
    _shieldTimerMs = 0;
  }

  static double _hzToCents(double f) => 1200.0 * math.log(f / 440.0) / math.ln2;
  static double _centsToHz(double c) =>
      440.0 * math.exp((c / 1200.0) * math.ln2);

  TrackerState update({
    required double dtMs,
    required double? f0Candidate,
    required double fusionScore,
    required double snrDb,
    required double harmonicity,
    required double rmsDb,
    required double spectralFlux,
    required double spectralFlatnessDb,
  }) {
    // Transient detection
    bool isTransient = false;
    if (_cfg.shieldEnabled) {
      final energyJump = _prevRmsDb == null ? 0.0 : (rmsDb - _prevRmsDb!);
      _prevRmsDb = rmsDb;
      if (energyJump > _cfg.energyJumpDb ||
          spectralFlatnessDb > _cfg.sfmThresh ||
          harmonicity < _cfg.harmonicityDrop) {
        isTransient = true;
      }
      if (isTransient) {
        _state = TrackState.frozen;
        _shieldTimerMs = _cfg.shieldMs;
      }
      if (_state == TrackState.frozen) {
        _shieldTimerMs -= dtMs.toInt();
        if (_shieldTimerMs <= 0) {
          _state = TrackState.search; // recover
        }
      }
    }

    // Alpha-beta filter on cents when we have a candidate.
    if (f0Candidate != null && !f0Candidate.isNaN && f0Candidate > 0) {
      final z = _hzToCents(f0Candidate);
      if (_f0Pred == null) {
        _f0Pred = z;
        _v = 0.0;
      } else {
        final pred = _f0Pred! + _v;
        final r = z - pred; // residual
        _f0Pred = pred + _cfg.alpha * r;
        _v = _v + _cfg.beta * r;
      }
    }

    // State machine with SNR and lock window.
    if (_state != TrackState.frozen) {
      if (_state == TrackState.search) {
        if (snrDb >= _cfg.snrEnterDb &&
            _f0Pred != null &&
            f0Candidate != null) {
          final err = (1200.0 *
                  (math.log(f0Candidate / _centsToHz(_f0Pred!)) / math.ln2))
              .abs();
          if (err <= _cfg.lockWindowCents) {
            // Good candidate: accumulate time
            _stateTimerMs += dtMs.toInt();
            if (_stateTimerMs > _cfg.holdInMs) {
              // Lock after sustained good signal
              _state = TrackState.locked;
              _stateTimerMs = 0;
            }
          } else {
            // Candidate outside window: reset timer
            _stateTimerMs = 0;
          }
        } else {
          // No candidate or poor SNR: reset timer
          _stateTimerMs = 0;
        }
      } else if (_state == TrackState.locked) {
        // CORRECTED LOGIC: Stay locked unless bad signal persists for holdOutMs
        if (snrDb < _cfg.snrExitDb) {
          // Bad signal: accumulate time
          _stateTimerMs += dtMs.toInt();
          if (_stateTimerMs > _cfg.holdOutMs) {
            // Only unlock after sustained bad signal
            _state = TrackState.search;
            _stateTimerMs = 0;
          }
        } else {
          // Good signal: reset timer (stay locked)
          _stateTimerMs = 0;
        }
      }
    }

    // Rescue fundamental when octave error suspected (2x/3x) in SEARCH.
    double? outF0;
    if (_state == TrackState.locked && _f0Pred != null) {
      outF0 = _centsToHz(_f0Pred!);
    } else if (_state == TrackState.search && f0Candidate != null) {
      // Heuristic: prefer lower plausible f0 if within harmonic relation.
      outF0 = f0Candidate;
      if (fusionScore > 0.5) {
        final f2 = f0Candidate / 2.0;
        final f3 = f0Candidate / 3.0;
        if (f2 >= 55 && f2 <= 1100) outF0 = f2;
        if (f3 >= 55 && f3 <= 1100) outF0 = f3;
      }
    }

    final centsErr = outF0 == null || _f0Pred == null
        ? 0.0
        : (1200.0 * (math.log(outF0 / _centsToHz(_f0Pred!)) / math.ln2));

    return TrackerState(
      state: _state,
      f0: outF0,
      centsError: centsErr,
      snrDb: snrDb,
      isTransient: isTransient || _state == TrackState.frozen,
    );
  }
}
