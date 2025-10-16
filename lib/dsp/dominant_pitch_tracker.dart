import 'dart:math' as math;
import 'dart:typed_data';

enum DominantTrackerState { search, locked }

class PeakInfo {
  final double freq;
  final double dbLevel;
  final double snr;
  final double prominence;
  final double harmonicScore;
  final double totalScore;
  
  const PeakInfo({
    required this.freq,
    required this.dbLevel,
    required this.snr,
    required this.prominence,
    required this.harmonicScore,
    required this.totalScore,
  });
}

class DominantPitchResult {
  final double f0;
  final double confidence;
  final DominantTrackerState state;
  final List<PeakInfo> debugPeaks; // top-5 peaks for debug overlay
  final double predictedF0;
  final String lockReason; // why locked/unlocked
  final double currentWindow; // current lock window in cents
  
  const DominantPitchResult({
    required this.f0,
    required this.confidence,
    required this.state,
    required this.debugPeaks,
    required this.predictedF0,
    required this.lockReason,
    required this.currentWindow,
  });
}

class DominantPitchTracker {
  // Configuration parameters
  final double sampleRate;
  final double fMin;
  final double fMax;
  final double lockThresholdDb;
  final double unlockThresholdDb;
  final int holdInMs;
  final int holdOutMs;
  final double lockWindowCents;
  final bool adaptiveWindow;
  final double windowMinCents;
  final double windowMaxCents;
  final double maxJumpCentsPerS;
  final bool rescueEnabled;
  final double peakProminenceDb;
  final int neighborSpanBins;
  
  // Alpha-beta filter parameters - BEAUCOUP plus agressif pour vitesse
  final double alphaPos = 0.9;  // Convergence très rapide
  final double betaVel = 0.7;   // Velocity tracking rapide
  
  // Internal state
  DominantTrackerState _state = DominantTrackerState.search;
  double _currentF0 = 0.0;
  double _predictedF0 = 0.0;
  double _velocityCentsPerS = 0.0;
  double _currentWindow = 60.0;
  int _lockTimer = 0;
  int _unlockTimer = 0;
  int _jumpTimer = 0; // Timer pour détecter les sauts prolongés
  String _lastLockReason = "Initial state";
  
  DominantPitchTracker({
    required this.sampleRate,
    this.fMin = 40.0,
    this.fMax = 4000.0,
    this.lockThresholdDb = 8.0,
    this.unlockThresholdDb = 3.0,
    this.holdInMs = 150,
    this.holdOutMs = 300,
    this.lockWindowCents = 60.0,
    this.adaptiveWindow = true,
    this.windowMinCents = 30.0,
    this.windowMaxCents = 80.0,
    this.maxJumpCentsPerS = 80.0,
    this.rescueEnabled = true,
    this.peakProminenceDb = 4.0,
    this.neighborSpanBins = 20,
  });
  
  DominantPitchResult update({
    required Float32List spectrumDb,
    required double binWidth,
    required int frameDurationMs,
    double? yinHint,     // Indice de YIN pour éviter octave errors
    double? harmonicHint, // Indice d'harmonic salience
  }) {
    final deltaTimeS = frameDurationMs / 1000.0;
    
    // Vérification de cohérence d'état au démarrage
    if (_currentF0 <= 0.0 && _state == DominantTrackerState.locked) {
      _state = DominantTrackerState.search; // Force reset si incohérent
      _lockTimer = 0;
      _unlockTimer = 0;
      _velocityCentsPerS = 0.0;
      _lastLockReason = "State reset: locked with f0=0";
    }
    
    // Find peaks with prominence, bias vers hints YIN/Harmonic
    final peaks = _findProminentPeaks(spectrumDb, binWidth, yinHint, harmonicHint);
    
    if (_state == DominantTrackerState.search) {
      return _processSearchState(peaks, deltaTimeS, frameDurationMs);
    } else {
      return _processLockedState(peaks, deltaTimeS, frameDurationMs, spectrumDb, binWidth, yinHint, harmonicHint);
    }
  }
  
  List<PeakInfo> _findProminentPeaks(Float32List spectrumDb, double binWidth, double? yinHint, double? harmonicHint) {
    final peaks = <PeakInfo>[];
    final minBin = (fMin / binWidth).round().clamp(1, spectrumDb.length - 2);
    final maxBin = (fMax / binWidth).round().clamp(minBin, spectrumDb.length - 2);
    
    for (int i = minBin; i <= maxBin; i++) {
      final dbLevel = spectrumDb[i];
      
      // Check if it's a local maximum
      if (dbLevel <= spectrumDb[i-1] || dbLevel <= spectrumDb[i+1]) continue;
      
      // Calculate local median for prominence
      final medianStart = math.max(0, i - neighborSpanBins);
      final medianEnd = math.min(spectrumDb.length - 1, i + neighborSpanBins);
      final localValues = <double>[];
      for (int j = medianStart; j <= medianEnd; j++) {
        if ((j - i).abs() > 2) localValues.add(spectrumDb[j]); // exclude peak itself
      }
      localValues.sort();
      final medianDb = localValues.isNotEmpty ? localValues[localValues.length ~/ 2] : -120.0;
      
      final prominence = dbLevel - medianDb;
      
      // ADAPTIVE PROMINENCE: Plus tolérant en mode locked pour maintenir le track
      double effectiveProminence = peakProminenceDb;
      if (_state == DominantTrackerState.locked) {
        // En mode locked, accepter des pics plus faibles pour maintenir le suivi
        effectiveProminence = peakProminenceDb * 0.5; // 2.0dB au lieu de 4.0dB
        // Si c'est proche de la fréquence trackée, encore plus tolérant
        if (_currentF0 > 0) {
          final freqHere = i * binWidth;
          final ratioToCurrent = freqHere / _currentF0;
          if (ratioToCurrent > 0.9 && ratioToCurrent < 1.1) {
            effectiveProminence = peakProminenceDb * 0.25; // 1.0dB pour fréquence trackée
          }
        }
      }
      
      if (prominence < effectiveProminence) continue;
      
      // Parabolic interpolation for sub-bin precision (with safety bounds)
      final y1 = spectrumDb[i-1];
      final y2 = spectrumDb[i];
      final y3 = spectrumDb[i+1];
      final a = (y1 - 2*y2 + y3) / 2;
      final b = (y3 - y1) / 2;
      // Safety check: avoid division by very small numbers that cause overflow
      final xOffset = (a.abs() > 1e-6) ? (-b / (2*a)).clamp(-0.5, 0.5) : 0.0;
      final interpFreq = (i + xOffset) * binWidth;
      // Safety bounds: ensure frequency is reasonable (20 Hz to 8000 Hz)
      if (interpFreq < 20.0 || interpFreq > 8000.0) continue;
      final interpDb = y2 + a * xOffset * xOffset + b * xOffset;
      
      // SNR calculation
      final snr = interpDb - medianDb;
      
      // Harmonic bonus scoring
      final harmonicScore = _calculateHarmonicScore(spectrumDb, binWidth, interpFreq);
      
      // HINTS OPTIONNELS: Bonus seulement si hints disponibles, pas de pénalité sinon
      double hintBias = 0.0;
      
      if (yinHint != null && yinHint > 0) {
        final yinRatio = interpFreq / yinHint;
        if (yinRatio > 0.8 && yinRatio < 1.25) {
          hintBias += 4.0; // BONUS modéré si proche de YIN (was 8.0)
        } else if (yinRatio > 1.8 && yinRatio < 2.2) {
          hintBias -= 2.0; // PÉNALITÉ réduite si octave de YIN (was 5.0)
        } else if (yinRatio > 2.8 && yinRatio < 3.2) {
          hintBias -= 2.0; // PÉNALITÉ réduite si triple harmonique (was 6.0)
        } else if (yinRatio > 3.8 && yinRatio < 4.2) {
          hintBias -= 2.0; // PÉNALITÉ réduite si 4e harmonique (was 7.0) 
        }
      }
      if (harmonicHint != null && harmonicHint > 0) {
        final harmRatio = interpFreq / harmonicHint;
        if (harmRatio > 0.8 && harmRatio < 1.25) {
          hintBias += 3.0; // BONUS modéré si proche d'Harmonic (was 6.0)
        } else if (harmRatio > 1.8 && harmRatio < 2.2) {
          hintBias -= 1.0; // PÉNALITÉ très réduite si octave (was 3.0)
        } else if (harmRatio > 2.8 && harmRatio < 3.2) {
          hintBias -= 1.0; // PÉNALITÉ très réduite si triple harmonique (was 4.0)
        } else if (harmRatio > 3.8 && harmRatio < 4.2) {
          hintBias -= 1.0; // PÉNALITÉ très réduite si 4e harmonique (was 5.0)
        }
      }
      
      // Total score avec bias anti-octave
      final totalScore = snr + harmonicScore + hintBias;
      
      peaks.add(PeakInfo(
        freq: interpFreq,
        dbLevel: interpDb,
        snr: snr,
        prominence: prominence,
        harmonicScore: harmonicScore,
        totalScore: totalScore,
      ));
    }
    
    // NOUVEAU: Comparateur fondamental intelligent
    _applyFundamentalComparator(peaks, spectrumDb, binWidth);
    
    // Sort by total score and return top candidates
    peaks.sort((a, b) => b.totalScore.compareTo(a.totalScore));
    return peaks.take(5).toList();
  }
  
  double _calculateHarmonicScore(Float32List spectrumDb, double binWidth, double f0) {
    double score = 0.0;
    final harmonics = [2.0, 3.0]; // Check 2f and 3f
    
    for (final harmRatio in harmonics) {
      final harmFreq = f0 * harmRatio;
      final harmBin = harmFreq / binWidth;
      final binLo = harmBin.floor();
      final binHi = harmBin.ceil();
      
      if (binLo >= 0 && binHi < spectrumDb.length) {
        // Check within ±0.4 bin tolerance
        double maxHarmDb = -120.0;
        for (int b = binLo; b <= binHi; b++) {
          if ((b - harmBin).abs() <= 0.4) {
            maxHarmDb = math.max(maxHarmDb, spectrumDb[b]);
          }
        }
        if (maxHarmDb > -100.0) score += 1.0; // +1 dB equivalent bonus
      }
    }
    
    return score;
  }
  
  DominantPitchResult _processSearchState(List<PeakInfo> peaks, double deltaTimeS, int frameDurationMs) {
    if (peaks.isEmpty) {
      _lockTimer = 0;
      _lastLockReason = "No peaks found";
      return DominantPitchResult(
        f0: 0.0,
        confidence: 0.0,
        state: _state,
        debugPeaks: peaks,
        predictedF0: 0.0,
        lockReason: _lastLockReason,
        currentWindow: _currentWindow,
      );
    }
    
    final bestPeak = peaks.first;
    
    // Validation adaptative avant tentative de lock
    double effectiveProminenceForLock = peakProminenceDb;
    // En mode search, rester un peu strict mais pas trop
    if (peaks.length > 1) {
      // S'il y a beaucoup de pics faibles, être plus tolérant
      final avgProminence = peaks.take(3).map((p) => p.prominence).reduce((a, b) => a + b) / 3;
      if (avgProminence < peakProminenceDb) {
        effectiveProminenceForLock = peakProminenceDb * 0.75; // 1.5dB au lieu de 2.0dB
      }
    }
    
    final isPeakValid = bestPeak.snr >= lockThresholdDb && 
                       bestPeak.freq >= fMin && 
                       bestPeak.freq <= fMax &&
                       bestPeak.prominence >= effectiveProminenceForLock;
    
    if (isPeakValid) {
      // Vérification de consistance : si le pic change trop, restart
      if (_lockTimer > 0 && _currentF0 > 0) {
        final deltaCents = 1200.0 * math.log(bestPeak.freq / _currentF0).abs() / math.ln2;
        if (deltaCents > 200.0) { // Plus de 200 cents de changement = restart
          _lockTimer = frameDurationMs; // Restart le timer
          _lastLockReason = "Peak inconsistent: ${deltaCents.toStringAsFixed(0)} cents jump, restarting lock timer";
        } else {
          _lockTimer += frameDurationMs;
        }
      } else {
        _lockTimer += frameDurationMs;
      }
      
      _currentF0 = bestPeak.freq; // Track le candidat même en search
      
      if (_lockTimer >= holdInMs) {
        // Lock achieved après validation complète
        _state = DominantTrackerState.locked;
        _predictedF0 = bestPeak.freq;
        _velocityCentsPerS = 0.0;
        _unlockTimer = 0;
        _lastLockReason = "SNR ${bestPeak.snr.toStringAsFixed(1)} dB >= $lockThresholdDb dB for $_lockTimer ms";
        
        // Update adaptive window
        if (adaptiveWindow) {
          _currentWindow = windowMaxCents; // Start wide in lock
        } else {
          _currentWindow = lockWindowCents;
        }
      } else {
        _lastLockReason = "Building lock: $_lockTimer/$holdInMs ms, SNR ${bestPeak.snr.toStringAsFixed(1)} dB";
      }
    } else {
      _lockTimer = 0;
      _currentF0 = 0.0; // Réinitialiser si pas de pic valide
      _lastLockReason = "No valid peak: SNR ${bestPeak.snr.toStringAsFixed(1)} dB < $lockThresholdDb dB or prominence ${bestPeak.prominence.toStringAsFixed(1)} < $effectiveProminenceForLock dB";
    }
    
    return DominantPitchResult(
      f0: _currentF0, // Utiliser _currentF0 (0 si pas de pic valide)
      confidence: isPeakValid ? (bestPeak.snr / lockThresholdDb).clamp(0.0, 1.0) : 0.0,
      state: _state,
      debugPeaks: peaks,
      predictedF0: _currentF0,
      lockReason: _lastLockReason,
      currentWindow: _currentWindow,
    );
  }
  
  DominantPitchResult _processLockedState(
    List<PeakInfo> peaks, 
    double deltaTimeS, 
    int frameDurationMs,
    Float32List spectrumDb,
    double binWidth,
    double? yinHint,
    double? harmonicHint,
  ) {
    // NOUVELLE LOGIQUE: Vérifier si les hints YIN/Harmonic suggèrent une correction d'octave
    if (yinHint != null && yinHint > 0 && harmonicHint != null && harmonicHint > 0) {
      final avgHint = (yinHint + harmonicHint) / 2.0;
      final currentRatio = _currentF0 / avgHint;
      
      // Si on est locké sur une octave supérieure (×1.8 à ×2.2) et les hints convergent vers fondamental
      if (currentRatio > 1.8 && currentRatio < 2.2) {
        // Vérifier que les hints sont cohérents entre eux (moins de 50 cents d'écart)
        final hintDeltaCents = 1200.0 * (math.log(yinHint / harmonicHint) / math.ln2).abs();
        if (hintDeltaCents < 50.0) {
          // Force unlock pour permettre correction vers le fondamental
          _state = DominantTrackerState.search;
          _unlockTimer = 0;
          _lockTimer = 0;
          _jumpTimer = 0;
          _currentF0 = 0.0;
          _velocityCentsPerS = 0.0;
          _lastLockReason = "OCTAVE CORRECTION: Unlocked from ${_currentF0.toStringAsFixed(1)}Hz, hints suggest ${avgHint.toStringAsFixed(1)}Hz (ratio=${currentRatio.toStringAsFixed(2)})";
          return DominantPitchResult(
            f0: 0.0,
            confidence: 0.0,
            state: _state,
            debugPeaks: peaks,
            predictedF0: 0.0,
            lockReason: _lastLockReason,
            currentWindow: _currentWindow,
          );
        }
      }
    }
    
    // Conservative prediction: use current frequency with small velocity correction
    // Clamp velocity to prevent runaway prediction
    _velocityCentsPerS = _velocityCentsPerS.clamp(-100.0, 100.0); // ±100 cents/s max
    
    // Predict with damped velocity (don't trust velocity too much)
    final velocityContribution = _velocityCentsPerS * deltaTimeS * _currentF0 / 1200.0;
    _predictedF0 = _currentF0 + velocityContribution * 0.3; // Only 30% of velocity prediction
    
    // Safety bounds: prevent prediction from going outside reasonable range  
    _predictedF0 = _predictedF0.clamp(math.max(20.0, _currentF0 * 0.5), math.min(8000.0, _currentF0 * 2.0));
    
    // FENÊTRE ADAPTATIVE: Plus large si pas de hints YIN/Harm (tracker autonome)
    double effectiveWindow = _currentWindow;
    if ((yinHint == null || yinHint <= 0) && (harmonicHint == null || harmonicHint <= 0)) {
      effectiveWindow = _currentWindow * 2.0; // Fenêtre 2x plus large sans hints
    }
    
    final windowRatio = math.pow(2.0, effectiveWindow / 1200.0);
    final fLow = _predictedF0 / windowRatio;
    final fHigh = _predictedF0 * windowRatio;
    
    final candidates = peaks.where((peak) => 
      peak.freq >= fLow && peak.freq <= fHigh
    ).toList();
    
    PeakInfo? selectedPeak;
    double bestCost = double.infinity;
    
    // Find best candidate using cost function
    for (final candidate in candidates) {
      final deltaCents = 1200.0 * (math.log(candidate.freq / _predictedF0) / math.ln2).abs();
      final velocityTerm = (_velocityCentsPerS * deltaTimeS).abs();
      final velocityError = (deltaCents - velocityTerm).abs();
      
      final cost = 0.6 * deltaCents + 0.3 * velocityError - 0.1 * candidate.snr - 0.05 * candidate.harmonicScore;
      
      if (cost < bestCost) {
        bestCost = cost;
        selectedPeak = candidate;
      }
    }
    
    // Missing fundamental rescue
    if (selectedPeak == null && rescueEnabled) {
      selectedPeak = _attemptFundamentalRescue(peaks, spectrumDb, binWidth);
      if (selectedPeak != null) {
        _lastLockReason = "Missing fundamental rescue: f/2 or f/3 detected";
      }
    }
    
    if (selectedPeak != null) {
      // Update with alpha-beta filter - use MEASURED frequency, not predicted
      final measuredF0 = selectedPeak.freq;
      
      // PROTECTION ANTI-SAUT : Vérifier les gros changements même en mode LOCKED
      final deltaCentsFromCurrent = 1200.0 * (math.log(measuredF0 / _currentF0) / math.ln2).abs();
      
      // Si saut > 150 cents ET que ça dure > 200ms → FORCE UNLOCK
      if (deltaCentsFromCurrent > 150.0) {
        _jumpTimer += frameDurationMs;
        if (_jumpTimer > 200) { // Plus de 200ms de saut
          _state = DominantTrackerState.search;
          _unlockTimer = 0;
          _lockTimer = 0;
          _jumpTimer = 0;
          _lastLockReason = "FORCE UNLOCK: Jump ${deltaCentsFromCurrent.toStringAsFixed(0)} cents for ${_jumpTimer}ms";
          return DominantPitchResult(
            f0: 0.0,
            confidence: 0.0,
            state: _state,
            debugPeaks: peaks,
            predictedF0: _predictedF0,
            lockReason: _lastLockReason,
            currentWindow: _currentWindow,
          );
        }
      } else {
        _jumpTimer = 0; // Reset si pas de saut
      }
      
      // Calculate error from current position (not prediction!)
      final error = measuredF0 - _currentF0;
      
      // Limit jump rate to prevent runaway
      final maxJumpHz = maxJumpCentsPerS * deltaTimeS * _currentF0 / 1200.0;
      final limitedError = error.clamp(-maxJumpHz, maxJumpHz);
      
      // Alpha-beta update with measured frequency
      _currentF0 += alphaPos * limitedError;
      
      // Velocity update in Hz/s, then convert to cents/s for consistency
      if (deltaTimeS > 1e-6 && _currentF0 > 1e-6) {
        final velocityHz = betaVel * limitedError / deltaTimeS;
        final velocityCents = 1200.0 * velocityHz / _currentF0;
        _velocityCentsPerS = _velocityCentsPerS * 0.5 + velocityCents * 0.5; // BEAUCOUP plus rapide
        // Clamp velocity to reasonable range
        _velocityCentsPerS = _velocityCentsPerS.clamp(-200.0, 200.0);
      }
      
      // Adaptive window adjustment
      if (adaptiveWindow) {
        final stability = selectedPeak.snr / lockThresholdDb;
        final targetWindow = stability > 2.0 ? windowMinCents : windowMaxCents;
        _currentWindow += (targetWindow - _currentWindow) * 0.1;
      }

      // Reset unlock timer si on trouve un pic valide
      _unlockTimer = 0;
      _lastLockReason = "LOCKED: f0=${_currentF0.toStringAsFixed(1)} Hz, SNR=${selectedPeak.snr.toStringAsFixed(1)} dB";
    } else {
      // No valid candidate found - MAIS tracker autonome plus tenace
      // Ne pas incrémenter unlock timer si on n'a juste pas de hints YIN/Harm
      if ((yinHint != null && yinHint > 0) || (harmonicHint != null && harmonicHint > 0)) {
        _unlockTimer += frameDurationMs; // Normal unlock si hints actifs
      } else {
        // Tracker autonome: unlock plus lent sans hints
        _unlockTimer += (frameDurationMs * 0.5).round(); // 2x plus lent à unlock
      }
      
      // Force unlock if current frequency becomes invalid
      if (_currentF0 <= 0 || !_currentF0.isFinite || _currentF0 > 8000.0) {
        _state = DominantTrackerState.search;
        _lockTimer = 0;
        _currentF0 = 0.0;
        _velocityCentsPerS = 0.0;
        _lastLockReason = "Force unlock: invalid f0 (${_currentF0.toStringAsFixed(1)} Hz)";
        return DominantPitchResult(
          f0: 0.0,
          state: _state,
          confidence: 0.0,
          debugPeaks: peaks.take(5).toList(),
          predictedF0: 0.0,
          lockReason: _lastLockReason,
          currentWindow: _currentWindow,
        );
      }
      
      // Check for strong competitor outside window
      final outsideCompetitors = peaks.where((peak) => 
        peak.freq < fLow || peak.freq > fHigh
      );
      
      bool strongCompetitor = false;
      if (outsideCompetitors.isNotEmpty) {
        final strongestOutside = outsideCompetitors.reduce((a, b) => 
          a.totalScore > b.totalScore ? a : b
        );
        // RESTAURÉ: Concurrent avec marge raisonnable
        if (strongestOutside.snr > lockThresholdDb + 8.0) { // 14dB seuil raisonnable
          strongCompetitor = true;
          _lastLockReason = "Strong competitor at ${strongestOutside.freq.toStringAsFixed(1)} Hz (${strongestOutside.snr.toStringAsFixed(1)} dB)";
        }
      }
      
      // Check unlock conditions - logique normale basée sur les pics détectés
      final bestAvailableSnr = peaks.isNotEmpty ? 
        peaks.map((p) => p.snr).reduce(math.max) : -120.0;
      
      // CONDITIONS D'UNLOCK RESTAURÉES: Équilibre responsivité/stabilité
      final shouldUnlock = (bestAvailableSnr < unlockThresholdDb && _unlockTimer >= holdOutMs) || // Normal
                          (strongCompetitor && _unlockTimer >= 100) || // Rapide pour concurrent
                          (_unlockTimer >= holdOutMs * 2); // Force unlock raisonnable
      
      if (shouldUnlock) {
        _state = DominantTrackerState.search;
        _lockTimer = 0;
        _currentF0 = 0.0;
        _velocityCentsPerS = 0.0;
        
        String unlockReason;
        if (strongCompetitor) {
          unlockReason = "Unlocked: strong competitor";
        } else if (_unlockTimer >= holdOutMs * 2) {
          unlockReason = "Unlocked: timeout ${_unlockTimer}ms (force unlock)";
        } else {
          unlockReason = "Unlocked: SNR ${bestAvailableSnr.toStringAsFixed(1)} dB < $unlockThresholdDb dB for $_unlockTimer ms";
        }
        _lastLockReason = unlockReason;
      } else {
        final autonomousMode = (yinHint == null || yinHint <= 0) && (harmonicHint == null || harmonicHint <= 0);
        final modeStr = autonomousMode ? "AUTONOMOUS MODE" : "WITH HINTS";
        _lastLockReason = "Hold-out ($modeStr): $_unlockTimer/$holdOutMs ms, best SNR ${bestAvailableSnr.toStringAsFixed(1)} dB";
        // Decay velocity when no peak found to prevent accumulation
        _velocityCentsPerS *= 0.8; // 20% decay per frame without measurement
      }
    }
    
    return DominantPitchResult(
      f0: _currentF0,
      confidence: _state == DominantTrackerState.locked ? 0.95 : 0.5,
      state: _state,
      debugPeaks: peaks,
      predictedF0: _predictedF0,
      lockReason: _lastLockReason,
      currentWindow: _currentWindow,
    );
  }
  
  PeakInfo? _attemptFundamentalRescue(List<PeakInfo> peaks, Float32List spectrumDb, double binWidth) {
    for (final peak in peaks) {
      // Test f = peak/2
      final f2 = peak.freq / 2.0;
      if (f2 >= fMin && f2 <= fMax) {
        final combGain = _calculateCombGain(spectrumDb, binWidth, f2, [2.0, 3.0, 4.0]);
        if (combGain >= 4.0) {
          return PeakInfo(
            freq: f2,
            dbLevel: peak.dbLevel - 6.0, // Penalty for subharmonic
            snr: peak.snr - 3.0,
            prominence: peak.prominence,
            harmonicScore: combGain,
            totalScore: peak.snr - 3.0 + combGain,
          );
        }
      }
      
      // Test f = peak/3
      final f3 = peak.freq / 3.0;
      if (f3 >= fMin && f3 <= fMax) {
        final combGain = _calculateCombGain(spectrumDb, binWidth, f3, [2.0, 3.0, 4.0]);
        if (combGain >= 4.0) {
          return PeakInfo(
            freq: f3,
            dbLevel: peak.dbLevel - 9.0, // Penalty for sub-subharmonic
            snr: peak.snr - 5.0,
            prominence: peak.prominence,
            harmonicScore: combGain,
            totalScore: peak.snr - 5.0 + combGain,
          );
        }
      }
    }
    
    return null;
  }
  
  /// Comparateur fondamental intelligent : favorise les fréquences plus graves 
  /// qui peuvent être les fondamentales de pics plus aigus
  void _applyFundamentalComparator(List<PeakInfo> peaks, Float32List spectrumDb, double binWidth) {
    for (int i = 0; i < peaks.length; i++) {
      final peak = peaks[i];
      
      // Chercher un pic plus grave qui pourrait être le fondamental
      for (int j = 0; j < peaks.length; j++) {
        if (i == j) continue;
        final candidate = peaks[j];
        
        // Le candidat doit être plus grave que le pic actuel
        if (candidate.freq >= peak.freq) continue;
        
        // Calculer le ratio harmonique
        final ratio = peak.freq / candidate.freq;
        
        // Vérifier si c'est une relation harmonique valide (2, 3, 4, 5, 6)
        bool isHarmonicRelation = false;
        double harmonicPenalty = 0.0;
        
        if (ratio > 1.9 && ratio < 2.1) { // 2ème harmonique
          isHarmonicRelation = true;
          harmonicPenalty = 2.0; // Pénalité modérée
        } else if (ratio > 2.9 && ratio < 3.1) { // 3ème harmonique  
          isHarmonicRelation = true;
          harmonicPenalty = 3.0; // Pénalité plus forte
        } else if (ratio > 3.9 && ratio < 4.1) { // 4ème harmonique
          isHarmonicRelation = true;
          harmonicPenalty = 4.0; // Pénalité forte
        } else if (ratio > 4.9 && ratio < 5.1) { // 5ème harmonique
          isHarmonicRelation = true;
          harmonicPenalty = 5.0; // Pénalité très forte
        } else if (ratio > 5.9 && ratio < 6.1) { // 6ème harmonique
          isHarmonicRelation = true;
          harmonicPenalty = 6.0; // Pénalité maximale
        }
        
        if (isHarmonicRelation) {
          // Vérifier la cohérence harmonique : le candidat devrait avoir ses harmoniques présentes
          final harmonicSupport = _calculateCombGain(spectrumDb, binWidth, candidate.freq, [2.0, 3.0, 4.0]);
          
          // PROTECTION CONTRE SOUS-HARMONIQUES ARTIFICIELLES
          // 1. Le candidat doit avoir un SNR minimum (éviter bruit de fond)
          final minSnrForFundamental = 8.0;
          // 2. Le candidat ne doit pas être trop faible comparé à l'harmonique
          final levelDifference = peak.dbLevel - candidate.dbLevel;
          final maxLevelDiff = 15.0; // L'harmonique ne devrait pas être >15dB plus fort que fondamental
          // 3. Support harmonique suffisant
          final minHarmonicSupport = 3.0;
          
          // Appliquer toutes les protections
          bool isValidFundamental = candidate.snr >= minSnrForFundamental && 
                                   levelDifference <= maxLevelDiff &&
                                   harmonicSupport >= minHarmonicSupport;
          
          if (isValidFundamental) {
            // Booster le score du candidat (fondamental potentiel)
            final fundamentalBonus = 8.0 + harmonicSupport - (harmonicPenalty * 0.5);
            peaks[j] = PeakInfo(
              freq: candidate.freq,
              dbLevel: candidate.dbLevel,
              snr: candidate.snr,
              prominence: candidate.prominence,
              harmonicScore: candidate.harmonicScore + harmonicSupport,
              totalScore: candidate.totalScore + fundamentalBonus,
            );
            
            // Pénaliser légèrement l'harmonique
            peaks[i] = PeakInfo(
              freq: peak.freq,
              dbLevel: peak.dbLevel,
              snr: peak.snr,
              prominence: peak.prominence,
              harmonicScore: peak.harmonicScore,
              totalScore: peak.totalScore - harmonicPenalty,
            );
          }
        }
      }
    }
  }

  double _calculateCombGain(Float32List spectrumDb, double binWidth, double f0, List<double> harmonics) {
    double totalGain = 0.0;
    int validHarmonics = 0;
    
    for (final harmRatio in harmonics) {
      final harmFreq = f0 * harmRatio;
      final harmBin = (harmFreq / binWidth).round();
      
      if (harmBin >= 0 && harmBin < spectrumDb.length) {
        totalGain += spectrumDb[harmBin];
        validHarmonics++;
      }
    }
    
    if (validHarmonics == 0) return 0.0;
    
    // Calculate baseline (average of nearby non-harmonic bins)
    double baselineSum = 0.0;
    int baselineCount = 0;
    for (int i = 1; i < spectrumDb.length; i++) {
      final freq = i * binWidth;
      bool isHarmonic = false;
      for (final harmRatio in harmonics) {
        if ((freq - f0 * harmRatio).abs() < binWidth * 0.5) {
          isHarmonic = true;
          break;
        }
      }
      if (!isHarmonic && freq >= fMin && freq <= fMax) {
        baselineSum += spectrumDb[i];
        baselineCount++;
      }
    }
    
    final baseline = baselineCount > 0 ? baselineSum / baselineCount : -120.0;
    final combLevel = totalGain / validHarmonics;
    
    return combLevel - baseline;
  }
}