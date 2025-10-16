import 'dart:math' as math;

class LockTracker {
  final double centsTolerance;
  final int stableCountRequired;
  // Hysteresis: higher confidence to acquire lock, lower to keep
  final double acquireConfidence;
  final double releaseConfidence;
  // Auto-lock: once close to a note, maintain lock with wider corridor
  final double lockCorridorCents; // wider corridor to maintain lock
  final int lockCountRequired; // frames needed to establish auto-lock
  final int unlockCountRequired; // frames needed to break auto-lock

  int _stable = 0;
  bool _locked = false;
  // Auto-lock state
  String? _lockedNote; // which note we're locked to
  double? _lockedFreq; // target frequency of locked note
  int _lockStreak = 0; // consecutive frames in lock corridor
  int _unlockStreak = 0; // consecutive frames outside unlock corridor
  // Note: The combination of a narrow centsTolerance and a moderate lockCorridorCents
  // effectively penalizes large jumps (around ±1200 cents) by requiring multiple
  // frames to re-acquire, acting like a strong octave-jump penalty.

  LockTracker({
    this.centsTolerance = 5.0,
    this.stableCountRequired = 3, // faster lock acquisition
    this.acquireConfidence = 0.85, // slightly lower for high notes
    this.releaseConfidence = 0.75,
    this.lockCorridorCents = 50.0, // tighter corridor for guitar strings (±0.5 ST) 
    this.lockCountRequired = 6, // faster lock for guitar strings (less frames needed)
    this.unlockCountRequired = 8, // harder to unlock once established
  });

  bool update(double cents, double confidence) {
    final needed = _locked ? releaseConfidence : acquireConfidence;
    final within = confidence >= needed && cents.abs() <= centsTolerance;
    if (within) {
      _stable++;
    } else {
      _stable = 0;
    }
    _locked = _stable >= stableCountRequired;
    return _locked;
  }
  
  // Enhanced update with auto-lock for note stability (prevents E4↔E3 flips)
  bool updateWithAutoLock(double cents, double confidence, double frequencyHz, String noteDisplay) {
    final needed = _locked ? releaseConfidence : acquireConfidence;
    final basicWithin = confidence >= needed && cents.abs() <= centsTolerance;
    
    // Check if we're within auto-lock corridor of current locked note
    bool inLockCorridor = false;
    if (_lockedNote == noteDisplay && _lockedFreq != null) {
      final freqRatio = (frequencyHz / _lockedFreq!).abs().clamp(0.1, 10.0);
      final lockCents = 1200 * (math.log(freqRatio) / math.ln2);
      inLockCorridor = lockCents.abs() <= lockCorridorCents;
    }
    
    // Auto-lock logic
    if (_lockedNote == null || _lockedNote != noteDisplay) {
      // Not locked to this note yet
      if (basicWithin) {
        _lockStreak++;
        if (_lockStreak >= lockCountRequired) {
          // Establish auto-lock
          _lockedNote = noteDisplay;
          _lockedFreq = frequencyHz;
          _unlockStreak = 0;
        }
      } else {
        _lockStreak = 0;
      }
    } else {
      // Already locked to this note
      // Special handling for bass frequencies (E2/A2) - more persistent lock
      final isBassFreq = frequencyHz < 120;
      final effectiveUnlockCount = isBassFreq ? (unlockCountRequired * 1.5).round() : unlockCountRequired;
      final effectiveLockCorridor = isBassFreq ? lockCorridorCents * 1.5 : lockCorridorCents;
      
      // Check corridor with bass-specific adjustments
    final adjustedInCorridor = _lockedFreq != null && 
      (1200 * math.log((frequencyHz / _lockedFreq!).abs().clamp(0.1, 10.0)) / math.ln2).abs() <= effectiveLockCorridor;
      
      if ((adjustedInCorridor || inLockCorridor) && confidence >= releaseConfidence) {
        _unlockStreak = 0; // stay locked
      } else {
        _unlockStreak++;
        if (_unlockStreak >= effectiveUnlockCount) {
          // Break auto-lock
          _lockedNote = null;
          _lockedFreq = null;
          _lockStreak = 0;
        }
      }
    }
    
    // Standard lock logic
    if (basicWithin || (_lockedNote == noteDisplay && inLockCorridor && confidence >= releaseConfidence)) {
      _stable++;
    } else {
      _stable = 0;
    }
    _locked = _stable >= stableCountRequired;
    return _locked;
  }

  bool get isLocked => _locked;
}
