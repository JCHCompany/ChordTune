import 'dart:math' as math;

enum TrackerInternalState { search, locked, sustain, nopitch }

class PitchTrackerResult {
  final double f0;
  final double confidence;
  final TrackerInternalState state;
  final double windowCents; // current lock window
  const PitchTrackerResult(this.f0, this.confidence, this.state, this.windowCents);
}

class PitchTracker {
  // Base params
  final double lockWindowCents;
  final double maxJumpLocked;
  final double maxJumpSearch;
  final int holdInMs;
  final int holdOutMs;
  final int smoothMs;
  final double snrOn;
  final double snrOff;
  final int sampleRate;
  final double fMin;
  final double fMax;
  // Focus params
  final int lockInMs;
  final bool adaptiveWindow;
  final double windowMinCents;
  final double windowMaxCents;
  final double competitorMarginDb;
  final double gatingDbfs;
  final bool coDecayEnabled;

  // Kalman state on log2(f)
  double _x = 0.0; // [pos; vel] with pos=log2(f)
  double _v = 0.0;
  // Covariance terms (diagonal approx): position and velocity variances
  double _pp = 1.0, _pv = 1.0;
  // Noise params (tuned values)
  final double _rMeas = 0.05; // measurement noise
  final double _qPosSearch = 5e-3, _qVelSearch = 5e-3;
  final double _qPosLocked = 8e-4, _qVelLocked = 8e-4;

  // State
  double _curWindow = 60.0; // current lock window
  TrackerInternalState _state = TrackerInternalState.search;
  int _stableMs = 0; // for lock-in
  int _holdCounterOut = 0; // drop timer
  double _emaF = 0.0;
  // Buffers for stability calc
  static const int _histLen = 200; // ~> for 2s at 10ms hop
  final List<double> _hist = List.filled(_histLen, 0.0);
  int _histIdx = 0;
  bool _histFilled = false;

  // Local comb weighting
  int _harmH = 6; // 5-8
  double _gaussCents = 20.0;

  PitchTracker({
    required this.lockWindowCents,
    required this.maxJumpLocked,
    required this.maxJumpSearch,
    required this.holdInMs,
    required this.holdOutMs,
    required this.smoothMs,
    required this.snrOn,
    required this.snrOff,
    required this.sampleRate,
    required this.fMin,
    required this.fMax,
    required this.lockInMs,
    required this.adaptiveWindow,
    required this.windowMinCents,
    required this.windowMaxCents,
    required this.competitorMarginDb,
    required this.gatingDbfs,
    required this.coDecayEnabled,
  });

  void setCombParams({int? harmH, double? gaussCents}) {
    if (harmH != null) _harmH = harmH;
    if (gaussCents != null) _gaussCents = gaussCents;
  }

  PitchTrackerResult update({
    required double fusedF0,
    required double fusedConf,
    required double snrEstimate,
    required int frameDurationMs,
    required double inBandDbfs,
    required double competitorDb,
    required double spectralFluxDb,
    required double localSalience,
  }) {
    // Absolute gating: NO PITCH zone
    if (inBandDbfs < gatingDbfs) {
      // Keep sustain if previously locked
      if (_state == TrackerInternalState.locked) {
        _state = TrackerInternalState.sustain;
        // propagate Kalman prediction without measurement
        _kalmanPredict(frameDurationMs, locked: true);
        final fPred = _fFromState();
        _emaF = _emaBlend(fPred, frameDurationMs);
        return PitchTrackerResult(_emaF, fusedConf * 0.5, _state, _curWindow);
      }
      _reset(false);
      return const PitchTrackerResult(0.0, 0.0, TrackerInternalState.nopitch, 60.0);
    }

    if (fusedF0 <= 0 || fusedF0 < fMin || fusedF0 > fMax) {
      _state = TrackerInternalState.search;
      return PitchTrackerResult(0.0, 0.0, _state, _curWindow);
    }

    // Update stability history (cents around current f)
    _pushHist(fusedF0);
    final varianceCents = _varianceCents(fusedF0);

    final snrGood = snrEstimate >= snrOn;
    final confGood = fusedConf > 0.85;
    final stable = varianceCents < 15.0 && confGood;

    // Event: strong spectral change -> drop
    final strongEvent = (spectralFluxDb + competitorDb) > competitorMarginDb && frameDurationMs > 0;

    // Compute adaptive window
    if (adaptiveWindow) {
      // shrink when stable, expand when unstable
      final target = stable ? windowMinCents : windowMaxCents;
      _curWindow += (target - _curWindow) * 0.2; // smooth adaptation
    } else {
      _curWindow = lockWindowCents;
    }

    if (_state == TrackerInternalState.search || _state == TrackerInternalState.nopitch) {
      if (snrGood && stable) {
        _stableMs += frameDurationMs;
        if (_stableMs >= lockInMs) {
          _state = TrackerInternalState.locked;
          _initKalman(fusedF0);
          _emaF = fusedF0;
        }
      } else {
        _stableMs = 0;
      }
      return PitchTrackerResult(fusedF0, fusedConf * 0.6, _state, _curWindow);
    }

    // LOCKED or SUSTAIN: Kalman update with gating
    final fPred = _kalmanPredict(frameDurationMs, locked: true);
    final centsErr = 1200.0 * (math.log(fusedF0 / fPred) / math.ln2).abs();
    final inGate = centsErr <= _curWindow;

    if (strongEvent) {
      _holdCounterOut += frameDurationMs;
    } else {
      _holdCounterOut = 0;
    }
    if (_holdCounterOut >= holdOutMs) {
      _state = TrackerInternalState.search;
      _stableMs = 0;
      return PitchTrackerResult(fusedF0, fusedConf * 0.5, _state, _curWindow);
    }

    if (inGate) {
      _kalmanUpdate(fusedF0, locked: true);
    }

    // Focus score
  final w1 = 0.4, w2 = 0.25, w3 = 0.2, w4 = coDecayEnabled ? 0.1 : 0.0, w5 = 0.15;
  final stabilityScore = (15.0 / (15.0 + varianceCents)).clamp(0.0, 1.0);
  final competitorScore = (competitorDb / (competitorMarginDb + 1e-6)).clamp(0.0, 1.2);
  // incorporate comb parameters into the local salience term to use _harmH and _gaussCents
  final combAdj = (1.0 - 0.02 * (8 - _harmH).clamp(0, 8)) * (1.0 - 0.005 * (_gaussCents - 20.0).abs()).clamp(0.8, 1.2);
  final locSal = (localSalience * combAdj).clamp(0.0, 1.0);
  final focus = (w1 * locSal + w2 * _snrScore(inBandDbfs) + w3 * stabilityScore + w4 * _coDecayScore() - w5 * competitorScore).clamp(0.0, 1.0);

    // Hold-in/Drop using thresholds
    if (focus < 0.4) {
      _state = TrackerInternalState.search;
      _stableMs = 0;
      return PitchTrackerResult(fusedF0, fusedConf * 0.5, _state, _curWindow);
    }

    // Anti-octave local check
    final penalized = _antiOctavePenalty(fPred, fusedF0);

    final fOut = _fFromState();
    _emaF = _emaBlend(fOut, frameDurationMs);
    return PitchTrackerResult(_emaF, (focus * (penalized ? 0.8 : 1.0)), _state, _curWindow);
  }

  // Helpers
  void _reset(bool keepState) {
    if (!keepState) _state = TrackerInternalState.search;
  _stableMs = 0; _holdCounterOut = 0; _emaF = 0.0; _x = 0; _v = 0; _pp = 1; _pv = 1; _histIdx = 0; _histFilled = false; _curWindow = 60.0;
  }

  void _pushHist(double f) {
    _hist[_histIdx] = f;
    _histIdx = (_histIdx + 1) % _histLen;
    if (_histIdx == 0) _histFilled = true;
  }

  double _varianceCents(double fRef) {
    final n = _histFilled ? _histLen : _histIdx;
    if (n <= 1) return 1e9;
    double mean = 0.0;
    for (int i = 0; i < n; i++) { mean += 1200.0 * math.log(_hist[i] / fRef) / math.ln2; }
    mean /= n;
  double variance = 0.0;
  for (int i = 0; i < n; i++) { final d = 1200.0 * math.log(_hist[i] / fRef) / math.ln2 - mean; variance += d * d; }
  return (variance / (n - 1)).abs();
  }

  double _snrScore(double inBandDbfs) {
    // Map [-18 dBFS .. 0 dBFS] to [0..1]
    final x = ((inBandDbfs + 18.0) / 18.0).clamp(0.0, 1.0);
    return x;
  }

  double _coDecayScore() {
    // Placeholder: favor steady decreasing energy
    return 0.7;
  }

  bool _antiOctavePenalty(double fPred, double fMeas) {
    // Penalize if local energy at f/2 or 2f seems higher
    final r = fMeas / fPred;
    if (r > 1.9 && r < 2.1) return true;
    if (r > 0.48 && r < 0.52) return true;
    return false;
  }

  // Kalman filter on log2(f)
  double _kalmanPredict(int frameMs, {required bool locked}) {
    final dt = frameMs / 1000.0;
    // x = x + v*dt
    _x = _x + _v * dt;
    // P update with process noise
    final qp = locked ? _qPosLocked : _qPosSearch;
    final qv = locked ? _qVelLocked : _qVelSearch;
    _pp = _pp + qp;
    _pv = _pv + qv;
    return _fFromState();
  }

  void _kalmanUpdate(double fMeas, {required bool locked}) {
    final z = math.log(fMeas) / math.ln2; // log2
    // innovation
    final y = z - _x;
    final s = _pp + _rMeas;
    final kp = _pp / s;
    // Update state
    _x = _x + kp * y;
    // Velocity damp
    _v *= locked ? 0.9 : 0.8;
    // Update cov
    _pp = (1 - kp) * _pp;
  }

  void _initKalman(double f0) {
    _x = math.log(f0) / math.ln2;
    _v = 0.0;
    _pp = 0.1;
    _pv = 0.1;
  }

  double _fFromState() => math.pow(2.0, _x).toDouble();

  double _emaBlend(double f, int frameMs) {
    final tau = smoothMs <= 0 ? frameMs.toDouble() : smoothMs.toDouble();
    final a = (frameMs / tau).clamp(0.0, 1.0);
    return a * f + (1 - a) * (_emaF == 0.0 ? f : _emaF);
  }
}
