import 'dart:math' as math;
import 'dart:typed_data';
import 'debug_logger.dart';

enum DominantTrackerState { search, locked }

class PeakInfo {
  final double freq;
  final double dbLevel;
  final double snr;
  final double prominence;
  final double harmonicScore;
  final double totalScore;
  final double
      spectralWidthHz; // Largeur spectrale en Hz (pic étroit vs bruit large)

  const PeakInfo({
    required this.freq,
    required this.dbLevel,
    required this.snr,
    required this.prominence,
    required this.harmonicScore,
    required this.totalScore,
    this.spectralWidthHz = 0.0,
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
  // Optional: local noise floor for debug
  final double localNoiseFloorDb;

  const DominantPitchResult({
    required this.f0,
    required this.confidence,
    required this.state,
    required this.debugPeaks,
    required this.predictedF0,
    required this.lockReason,
    required this.currentWindow,
    this.localNoiseFloorDb = 0.0,
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
  // Competitor margin control
  double competitorMarginBaseDb = 8.0; // default equivalent to legacy
  double competitorMarginAdaptiveSlope = 0.2; // dB per dB SNR shortfall
  // Spectral width discrimination (narrow tonal vs wide noise)
  double narrowPeakWidthHz = 20.0; // Threshold for narrow peaks (Hz)
  double widePeakWidthHz = 50.0; // Threshold for wide peaks (Hz)
  double narrowPeakMarginDb = 3.0; // Low margin for narrow peaks (fast unlock)
  double widePeakMarginDb = 12.0; // High margin for wide peaks (tolerated)
  // Locked-state persistence: do not unlock until SNR is below this relative floor
  double lockedSnrFloorDb = -128.0;
  // Last known local noise floor (for debug propagation)
  double _lastLocalNoiseFloorDb = 0.0;

  // Transient guard (broadband clap/tap protection)
  double transientThresholdDb = 6.0; // average band dB jump to trigger freeze
  int transientFreezeDurationMs = 250; // freeze unlock for this duration
  int _transientGuardMs = 0; // remaining freeze time
  double _lastBandAvgDb = -120.0; // last average dB over band

  // Averaged f0 anchor (decide unlock using ~0.5s average)
  double _avgF0Hz = 0.0;
  double avgF0TimeConstantS = 0.5; // ~0.5s EMA
  double anchorWindowCents = 90.0; // consider near-anchor within this band

  // Alpha-beta filter parameters - BEAUCOUP plus agressif pour vitesse
  final double alphaPos = 0.9; // Convergence très rapide
  final double betaVel = 0.7; // Velocity tracking rapide

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

  // Logger pour le debug
  final DebugLogger _logger = DebugLogger.instance;
  bool _loggerInitialized = false;

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

  // Helper method pour logger les messages de debug
  void _log(String message) {
    // Initialise le logger au premier appel
    if (!_loggerInitialized) {
      _logger.init();
      _loggerInitialized = true;
    }
    // Utilise logSync pour éviter les problèmes async dans le pipeline audio
    _logger.logSync(message);
  }

  DominantPitchResult update({
    required Float32List spectrumDb,
    required double binWidth,
    required int frameDurationMs,
    double? yinHint, // Indice de YIN pour éviter octave errors
    double? harmonicHint, // Indice d'harmonic salience
    double? localNoiseFloorDb, // Optional: local noise floor around band
  }) {
    final deltaTimeS = frameDurationMs / 1000.0;
    if (localNoiseFloorDb != null) {
      _lastLocalNoiseFloorDb = localNoiseFloorDb;
    }

    // Compute average dB over analysis band to detect broadband transients
    final bandAvgDb = _computeBandAvgDb(spectrumDb, binWidth);
    if (_lastBandAvgDb > -200.0) {
      final jump = bandAvgDb - _lastBandAvgDb;
      if (jump >= transientThresholdDb) {
        _transientGuardMs = transientFreezeDurationMs; // activate freeze
      } else {
        _transientGuardMs = math.max(0, _transientGuardMs - frameDurationMs);
      }
    }
    _lastBandAvgDb = bandAvgDb;

    // Vérification de cohérence d'état au démarrage
    if (_currentF0 <= 0.0 && _state == DominantTrackerState.locked) {
      _state = DominantTrackerState.search; // Force reset si incohérent
      _lockTimer = 0;
      _unlockTimer = 0;
      _velocityCentsPerS = 0.0;
      _lastLockReason = "State reset: locked with f0=0";
    }

    // Find peaks with prominence, bias vers hints YIN/Harmonic
    final peaks =
        _findProminentPeaks(spectrumDb, binWidth, yinHint, harmonicHint);

    // DIAGNOSTIC: Log current state
    _log(
        '[TRACKER STATE] ${_state.name.toUpperCase()}, currentF0=${_currentF0.toStringAsFixed(1)}Hz, lockTimer=$_lockTimer, unlockTimer=$_unlockTimer');

    if (_state == DominantTrackerState.search) {
      _log('[DISPATCH] Calling _processSearchState');
      return _processSearchState(peaks, deltaTimeS, frameDurationMs);
    } else {
      _log('[DISPATCH] Calling _processLockedState');
      return _processLockedState(peaks, deltaTimeS, frameDurationMs, spectrumDb,
          binWidth, yinHint, harmonicHint);
    }
  }

  List<PeakInfo> _findProminentPeaks(Float32List spectrumDb, double binWidth,
      double? yinHint, double? harmonicHint) {
    final peaks = <PeakInfo>[];
    final minBin = (fMin / binWidth).round().clamp(1, spectrumDb.length - 2);
    final maxBin =
        (fMax / binWidth).round().clamp(minBin, spectrumDb.length - 2);

    for (int i = minBin; i <= maxBin; i++) {
      final dbLevel = spectrumDb[i];

      // Check if it's a local maximum
      if (dbLevel <= spectrumDb[i - 1] || dbLevel <= spectrumDb[i + 1])
        continue;

      // Calculate local median for prominence
      final medianStart = math.max(0, i - neighborSpanBins);
      final medianEnd = math.min(spectrumDb.length - 1, i + neighborSpanBins);
      final localValues = <double>[];
      for (int j = medianStart; j <= medianEnd; j++) {
        if ((j - i).abs() > 2)
          localValues.add(spectrumDb[j]); // exclude peak itself
      }
      localValues.sort();
      final medianDb = localValues.isNotEmpty
          ? localValues[localValues.length ~/ 2]
          : -120.0;

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
            effectiveProminence =
                peakProminenceDb * 0.25; // 1.0dB pour fréquence trackée
          }
        }
      }

      if (prominence < effectiveProminence) continue;

      // Parabolic interpolation for sub-bin precision (with safety bounds)
      final y1 = spectrumDb[i - 1];
      final y2 = spectrumDb[i];
      final y3 = spectrumDb[i + 1];
      final a = (y1 - 2 * y2 + y3) / 2;
      final b = (y3 - y1) / 2;
      // Safety check: avoid division by very small numbers that cause overflow
      final xOffset = (a.abs() > 1e-6) ? (-b / (2 * a)).clamp(-0.5, 0.5) : 0.0;
      final interpFreq = (i + xOffset) * binWidth;
      // Safety bounds: ensure frequency is reasonable (20 Hz to 8000 Hz)
      if (interpFreq < 20.0 || interpFreq > 8000.0) continue;
      final interpDb = y2 + a * xOffset * xOffset + b * xOffset;

      // SNR calculation
      final snr = interpDb - medianDb;

      // Harmonic bonus scoring
      final harmonicScore =
          _calculateHarmonicScore(spectrumDb, binWidth, interpFreq);

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
          hintBias -=
              1.0; // PÉNALITÉ très réduite si triple harmonique (was 4.0)
        } else if (harmRatio > 3.8 && harmRatio < 4.2) {
          hintBias -= 1.0; // PÉNALITÉ très réduite si 4e harmonique (was 5.0)
        }
      }

      // FUNDAMENTAL CONSENSUS BIAS: Si YIN et Fusion s'accordent sur le fondamental,
      // donner un énorme bonus au pic correspondant pour surpasser les harmoniques
      if (yinHint != null &&
          yinHint > 0 &&
          harmonicHint != null &&
          harmonicHint > 0) {
        // Vérifier que YIN et HarmonicSalience s'accordent (< 50 cents)
        final hintDeltaCents =
            1200.0 * (math.log(yinHint / harmonicHint) / math.ln2).abs();
        if (hintDeltaCents < 50.0) {
          // Consensus détecté, calculer la moyenne
          final consensusF0 = (yinHint + harmonicHint) / 2.0;
          final consensusRatio = interpFreq / consensusF0;

          // Si ce pic correspond au consensus (±15%)
          if (consensusRatio > 0.85 && consensusRatio < 1.15) {
            // ÉNORME BONUS pour forcer la sélection du fondamental
            hintBias += 15.0; // +15 dB équivalent surpasse tout harmonique
          }
          // Si ce pic est un harmonique du consensus, pénalité forte
          else if (consensusRatio > 1.85 && consensusRatio < 2.15) {
            hintBias -= 8.0; // Forte pénalité pour 2x harmonique
          } else if (consensusRatio > 2.85 && consensusRatio < 3.15) {
            hintBias -= 10.0; // Très forte pénalité pour 3x harmonique
          }
        }
      }

      // Total score avec bias anti-octave
      final totalScore = snr + harmonicScore + hintBias;

      // Calcul de la largeur spectrale (FWHM-like: bins at -3dB from peak)
      final spectralWidth =
          _calculateSpectralWidth(spectrumDb, i, interpDb, binWidth);

      peaks.add(PeakInfo(
        freq: interpFreq,
        dbLevel: interpDb,
        snr: snr,
        prominence: prominence,
        harmonicScore: harmonicScore,
        totalScore: totalScore,
        spectralWidthHz: spectralWidth,
      ));
    }

    // NOUVEAU: Comparateur fondamental intelligent
    _applyFundamentalComparator(peaks, spectrumDb, binWidth);

    // Debug: afficher tous les pics AVANT tri
    if (peaks.isNotEmpty) {
      _log('[BEFORE SORT] ${peaks.length} peaks:');
      for (final p in peaks) {
        // FIX: width==0.0 should be classified as NARROW (perfect tonal peak)
        final isNarrow =
            p.spectralWidthHz == 0.0 || p.spectralWidthHz < narrowPeakWidthHz;
        _log(
            '  ${p.freq.toStringAsFixed(1)}Hz: score=${p.totalScore.toStringAsFixed(2)}, snr=${p.snr.toStringAsFixed(1)}, prom=${p.prominence.toStringAsFixed(1)}, width=${p.spectralWidthHz.toStringAsFixed(1)}Hz ${isNarrow ? '(NARROW)' : '(wide)'}');
      }
    }

    // Sort by total score with tie-breaking: prefer lower frequency for narrow peaks
    peaks.sort((a, b) {
      final scoreDiff = b.totalScore - a.totalScore;

      // CRITICAL FIX: Reduced threshold from 2.0 to 0.5 dB
      // AND: width=0 means PERFECT peak (ultra-narrow), not wide!
      if (scoreDiff.abs() < 0.5) {
        // Classify as narrow: width=0 (perfect) OR width < 20Hz
        final aIsNarrow = (a.spectralWidthHz == 0.0) ||
            (a.spectralWidthHz > 0 && a.spectralWidthHz < narrowPeakWidthHz);
        final bIsNarrow = (b.spectralWidthHz == 0.0) ||
            (b.spectralWidthHz > 0 && b.spectralWidthHz < narrowPeakWidthHz);

        if (aIsNarrow && bIsNarrow) {
          // Both are narrow tonal peaks with similar scores
          // → FAVOR LOWER FREQUENCY (probable fundamental)
          if (a.freq != b.freq) {
            _log(
                '[TIE-BREAK] ${a.freq.toStringAsFixed(1)}Hz (w=${a.spectralWidthHz.toStringAsFixed(1)}, s=${a.totalScore.toStringAsFixed(1)}) vs ${b.freq.toStringAsFixed(1)}Hz (w=${b.spectralWidthHz.toStringAsFixed(1)}, s=${b.totalScore.toStringAsFixed(1)}) → choosing ${a.freq < b.freq ? a.freq.toStringAsFixed(1) : b.freq.toStringAsFixed(1)}Hz (lower)');
          }
          return a.freq.compareTo(b.freq); // ascending frequency order
        }
      }

      // Otherwise, standard sort by descending score
      if (scoreDiff.abs() < 0.001) return 0; // Exactly equal
      return scoreDiff > 0 ? 1 : -1;
    });

    // Log du résultat final du tri (top 3)
    if (peaks.isNotEmpty) {
      final top3 = peaks.take(3).toList();
      _log(
          '[PEAK SORT] Top 3: ${top3.map((p) => '${p.freq.toStringAsFixed(1)}Hz(s=${p.totalScore.toStringAsFixed(1)}, w=${p.spectralWidthHz.toStringAsFixed(1)})').join(', ')}');
    }

    return peaks.take(5).toList();
  }

  /// Calcule la largeur spectrale d'un pic (en Hz) en mesurant l'étalement d'énergie
  /// Méthode: FWHM (Full Width at Half Maximum) approximée à -3dB du pic
  double _calculateSpectralWidth(
      Float32List spectrumDb, int peakBin, double peakDb, double binWidth) {
    final threshold = peakDb - 3.0; // -3dB threshold

    // Chercher à gauche jusqu'au threshold
    int leftBin = peakBin;
    while (leftBin > 0 && spectrumDb[leftBin] > threshold) {
      leftBin--;
    }

    // Chercher à droite jusqu'au threshold
    int rightBin = peakBin;
    while (
        rightBin < spectrumDb.length - 1 && spectrumDb[rightBin] > threshold) {
      rightBin++;
    }

    // Largeur en bins, convertie en Hz
    final widthBins = (rightBin - leftBin).toDouble();
    return widthBins * binWidth;
  }

  double _calculateHarmonicScore(
      Float32List spectrumDb, double binWidth, double f0) {
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

  DominantPitchResult _processSearchState(
      List<PeakInfo> peaks, double deltaTimeS, int frameDurationMs) {
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
        localNoiseFloorDb: _lastLocalNoiseFloorDb,
      );
    }

    // peaks are sorted by totalScore (SNR + harmonicScore + hintBias)
    // However, during SEARCH we want to prioritize clear energy evidence.
    // If the top-by-score is low-SNR (often a hypothesized fundamental),
    // fall back to the highest-SNR candidate to avoid missing obvious peaks.
    final bestByScore = peaks.first;
    final bestBySnr = peaks.reduce((a, b) => a.snr >= b.snr ? a : b);
    PeakInfo bestPeak = bestByScore;

    // Validation adaptative avant tentative de lock
    double effectiveProminenceForLock = peakProminenceDb;
    // En mode search, rester un peu strict mais pas trop
    if (peaks.length > 1) {
      // S'il y a beaucoup de pics faibles, être plus tolérant
      final avgProminence =
          peaks.take(3).map((p) => p.prominence).reduce((a, b) => a + b) / 3;
      if (avgProminence < peakProminenceDb) {
        effectiveProminenceForLock =
            peakProminenceDb * 0.75; // 1.5dB au lieu de 2.0dB
      }
    }

    bool isPeakValid = bestPeak.snr >= lockThresholdDb &&
        bestPeak.freq >= fMin &&
        bestPeak.freq <= fMax &&
        bestPeak.prominence >= effectiveProminenceForLock;

    // Debug validation
    _log(
        '[PEAK VALIDATION] bestByScore: ${bestByScore.freq.toStringAsFixed(1)}Hz (snr=${bestByScore.snr.toStringAsFixed(1)}, prom=${bestByScore.prominence.toStringAsFixed(1)}, score=${bestByScore.totalScore.toStringAsFixed(1)})');
    _log(
        '[PEAK VALIDATION] bestBySnr: ${bestBySnr.freq.toStringAsFixed(1)}Hz (snr=${bestBySnr.snr.toStringAsFixed(1)}, prom=${bestBySnr.prominence.toStringAsFixed(1)}, score=${bestBySnr.totalScore.toStringAsFixed(1)})');
    _log(
        '[PEAK VALIDATION] thresholds: lockSnr=$lockThresholdDb, prominence=$effectiveProminenceForLock');
    _log(
        '[PEAK VALIDATION] bestPeak (${bestPeak.freq.toStringAsFixed(1)}Hz) valid? $isPeakValid (snr=${bestPeak.snr.toStringAsFixed(1)}>=$lockThresholdDb, prom=${bestPeak.prominence.toStringAsFixed(1)}>=$effectiveProminenceForLock)');

    // If the top-by-score fails only because of SNR, try the highest-SNR candidate
    if (!isPeakValid) {
      final scoreFailsSNR = bestPeak.snr < lockThresholdDb;
      final snrCandidateValid = bestBySnr.snr >= lockThresholdDb &&
          bestBySnr.freq >= fMin &&
          bestBySnr.freq <= fMax &&
          bestBySnr.prominence >= effectiveProminenceForLock;
      if (scoreFailsSNR && snrCandidateValid) {
        bestPeak = bestBySnr;
        isPeakValid = true;
        _lastLockReason =
            "SEARCH: switched to highest-SNR candidate ${bestPeak.freq.toStringAsFixed(1)} Hz (SNR ${bestPeak.snr.toStringAsFixed(1)} dB)";
        _log('[PEAK SWITCH] Switched from bestByScore to bestBySnr!');
      }
    }

    if (isPeakValid) {
      // Vérification de consistance : si le pic change trop, restart
      if (_lockTimer > 0 && _currentF0 > 0) {
        final deltaCents =
            1200.0 * math.log(bestPeak.freq / _currentF0).abs() / math.ln2;
        if (deltaCents > 200.0) {
          // Plus de 200 cents de changement = restart
          _lockTimer = frameDurationMs; // Restart le timer
          _lastLockReason =
              "Peak inconsistent: ${deltaCents.toStringAsFixed(0)} cents jump, restarting lock timer";
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
        _lastLockReason =
            "SNR ${bestPeak.snr.toStringAsFixed(1)} dB >= $lockThresholdDb dB for $_lockTimer ms";

        // Update adaptive window
        if (adaptiveWindow) {
          _currentWindow = windowMaxCents; // Start wide in lock
        } else {
          _currentWindow = lockWindowCents;
        }
      } else {
        _lastLockReason =
            "Building lock: $_lockTimer/$holdInMs ms, SNR ${bestPeak.snr.toStringAsFixed(1)} dB";
      }
    } else {
      _lockTimer = 0;
      _currentF0 = 0.0; // Réinitialiser si pas de pic valide
      _lastLockReason =
          "No valid peak: SNR ${bestPeak.snr.toStringAsFixed(1)} dB < $lockThresholdDb dB or prominence ${bestPeak.prominence.toStringAsFixed(1)} < $effectiveProminenceForLock dB";
    }

    return DominantPitchResult(
      f0: _currentF0, // Utiliser _currentF0 (0 si pas de pic valide)
      confidence:
          isPeakValid ? (bestPeak.snr / lockThresholdDb).clamp(0.0, 1.0) : 0.0,
      state: _state,
      debugPeaks: peaks,
      predictedF0: _currentF0,
      lockReason: _lastLockReason,
      currentWindow: _currentWindow,
      localNoiseFloorDb: _lastLocalNoiseFloorDb,
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
    _log(
        '[LOCKED STATE ENTRY] currentF0=${_currentF0.toStringAsFixed(1)}Hz, yinHint=${yinHint?.toStringAsFixed(1)}Hz, harmonicHint=${harmonicHint?.toStringAsFixed(1)}Hz');

    // Update averaged f0 anchor (EMA ~0.5s)
    if (_currentF0 > 0) {
      final k = (deltaTimeS / avgF0TimeConstantS).clamp(0.0, 1.0);
      _avgF0Hz = (_avgF0Hz == 0.0)
          ? _currentF0
          : _avgF0Hz + (_currentF0 - _avgF0Hz) * k;
    }

    // NOUVELLE LOGIQUE: Vérifier si les hints YIN/Harmonic suggèrent une correction d'octave
    if (yinHint != null &&
        yinHint > 0 &&
        harmonicHint != null &&
        harmonicHint > 0) {
      final avgHint = (yinHint + harmonicHint) / 2.0;
      final currentRatio = _currentF0 / avgHint;
      _log(
          '[OCTAVE CHECK] currentF0=${_currentF0.toStringAsFixed(1)}, avgHint=${avgHint.toStringAsFixed(1)}, ratio=${currentRatio.toStringAsFixed(2)}');

      _log(
          '[OCTAVE CHECK] currentF0=${_currentF0.toStringAsFixed(1)}, avgHint=${avgHint.toStringAsFixed(1)}, ratio=${currentRatio.toStringAsFixed(2)}');

      // Si on est locké sur une octave supérieure (×1.8 à ×2.2) et les hints convergent vers fondamental
      if (currentRatio > 1.8 && currentRatio < 2.2) {
        // Vérifier que les hints sont cohérents entre eux (moins de 50 cents d'écart)
        final hintDeltaCents =
            1200.0 * (math.log(yinHint / harmonicHint) / math.ln2).abs();
        _log(
            '[OCTAVE CORRECTION CHECK] hintDeltaCents=${hintDeltaCents.toStringAsFixed(1)} (threshold=50.0)');
        if (hintDeltaCents < 50.0) {
          // Force unlock pour permettre correction vers le fondamental
          _state = DominantTrackerState.search;
          _unlockTimer = 0;
          _lockTimer = 0;
          _jumpTimer = 0;
          _currentF0 = 0.0;
          _velocityCentsPerS = 0.0;
          _lastLockReason =
              "OCTAVE CORRECTION: Unlocked from ${_currentF0.toStringAsFixed(1)}Hz, hints suggest ${avgHint.toStringAsFixed(1)}Hz (ratio=${currentRatio.toStringAsFixed(2)})";
          _log('[OCTAVE CORRECTION APPLIED] Force unlock to SEARCH mode!');
          return DominantPitchResult(
            f0: 0.0,
            confidence: 0.0,
            state: _state,
            debugPeaks: peaks,
            predictedF0: 0.0,
            lockReason: _lastLockReason,
            currentWindow: _currentWindow,
            localNoiseFloorDb: 0.0,
          );
        }
      }
    }

    // Conservative prediction: use current frequency with small velocity correction
    // Clamp velocity to prevent runaway prediction
    _velocityCentsPerS =
        _velocityCentsPerS.clamp(-100.0, 100.0); // ±100 cents/s max

    // Predict with damped velocity (don't trust velocity too much)
    final velocityContribution =
        _velocityCentsPerS * deltaTimeS * _currentF0 / 1200.0;
    _predictedF0 = _currentF0 +
        velocityContribution * 0.3; // Only 30% of velocity prediction

    // Safety bounds: prevent prediction from going outside reasonable range
    _predictedF0 = _predictedF0.clamp(
        math.max(20.0, _currentF0 * 0.5), math.min(8000.0, _currentF0 * 2.0));

    // FENÊTRE ADAPTATIVE: Plus large si pas de hints YIN/Harm (tracker autonome)
    double effectiveWindow = _currentWindow;
    if ((yinHint == null || yinHint <= 0) &&
        (harmonicHint == null || harmonicHint <= 0)) {
      effectiveWindow =
          _currentWindow * 2.0; // Fenêtre 2x plus large sans hints
    }

    final windowRatio = math.pow(2.0, effectiveWindow / 1200.0);
    final fLow = _predictedF0 / windowRatio;
    final fHigh = _predictedF0 * windowRatio;

    final candidates =
        peaks.where((peak) => peak.freq >= fLow && peak.freq <= fHigh).toList();

    // NOUVELLE LOGIQUE: Compétition par niveau absolu avec discrimination spectrale
    // Si un pic HORS fenêtre est significativement plus fort que tout pic DANS la fenêtre,
    // forcer un unlock immédiat pour permettre le switch
    final outsideCandidates =
        peaks.where((p) => p.freq < fLow || p.freq > fHigh).toList();

    _log(
        '[LOCKED WINDOW] fLow=${fLow.toStringAsFixed(1)}, fHigh=${fHigh.toStringAsFixed(1)}, inside=${candidates.length}, outside=${outsideCandidates.length}');

    if (outsideCandidates.isNotEmpty && candidates.isNotEmpty) {
      final strongestOutside =
          outsideCandidates.reduce((a, b) => a.dbLevel > b.dbLevel ? a : b);
      final strongestInside =
          candidates.reduce((a, b) => a.dbLevel > b.dbLevel ? a : b);

      final levelDiff = strongestOutside.dbLevel - strongestInside.dbLevel;

      // MODIFICATION CRITIQUE: Comparer SCORE (qui inclut consensus bias) au lieu de SNR brut
      // Car le SNR brut ne reflète pas le bonus de consensus fondamental
      final scoreDiff =
          strongestOutside.totalScore - strongestInside.totalScore;
      final snrDiff = strongestOutside.snr - strongestInside.snr;

      _log(
          '[COMPETITOR CHECK] Outside: ${strongestOutside.freq.toStringAsFixed(1)}Hz (score=${strongestOutside.totalScore.toStringAsFixed(1)}, snr=${strongestOutside.snr.toStringAsFixed(1)}, width=${strongestOutside.spectralWidthHz.toStringAsFixed(1)}Hz)');
      _log(
          '[COMPETITOR CHECK] Inside: ${strongestInside.freq.toStringAsFixed(1)}Hz (score=${strongestInside.totalScore.toStringAsFixed(1)}, snr=${strongestInside.snr.toStringAsFixed(1)}, width=${strongestInside.spectralWidthHz.toStringAsFixed(1)}Hz)');
      _log(
          '[COMPETITOR CHECK] levelDiff=${levelDiff.toStringAsFixed(1)}dB, snrDiff=${snrDiff.toStringAsFixed(1)}dB, scoreDiff=${scoreDiff.toStringAsFixed(1)}dB (positive=outside better)');

      // Calculer la marge requise en fonction de la largeur spectrale du compétiteur
      double requiredMargin = narrowPeakMarginDb; // Default pour pics étroits

      if (strongestOutside.spectralWidthHz > 0) {
        if (strongestOutside.spectralWidthHz < narrowPeakWidthHz) {
          // Pic étroit (note tonale) → marge faible = unlock rapide
          requiredMargin = narrowPeakMarginDb;
        } else if (strongestOutside.spectralWidthHz > widePeakWidthHz) {
          // Pic large (bruit) → marge haute = très toléré, pas d'unlock
          requiredMargin = widePeakMarginDb;
        } else {
          // Interpolation linéaire entre narrow et wide
          final ratio = (strongestOutside.spectralWidthHz - narrowPeakWidthHz) /
              (widePeakWidthHz - narrowPeakWidthHz);
          requiredMargin = narrowPeakMarginDb +
              ratio * (widePeakMarginDb - narrowPeakMarginDb);
        }
      }

      _log(
          '[COMPETITOR CHECK] requiredMargin=${requiredMargin.toStringAsFixed(1)}dB');

      // UTILISER SCORE DIFF (qui inclut consensus bias) au lieu de SNR brut
      // Car le consensus bias favorise la fondamentale dans le score
      if (scoreDiff > requiredMargin) {
        _state = DominantTrackerState.search;
        _unlockTimer = 0;
        _lockTimer = 0;
        _jumpTimer = 0;
        _lastLockReason =
            "FORCE UNLOCK: Outside peak ${strongestOutside.freq.toStringAsFixed(1)}Hz has ${scoreDiff.toStringAsFixed(1)}dB better SCORE (snr diff=${snrDiff.toStringAsFixed(1)}dB, width=${strongestOutside.spectralWidthHz.toStringAsFixed(1)}Hz, margin=${requiredMargin.toStringAsFixed(1)}dB)";
        _log('[FORCE UNLOCK] ${_lastLockReason}');
        return DominantPitchResult(
          f0: 0.0,
          confidence: 0.0,
          state: _state,
          debugPeaks: peaks,
          predictedF0: _predictedF0,
          lockReason: _lastLockReason,
          currentWindow: _currentWindow,
          localNoiseFloorDb: 0.0,
        );
      }
    }

    PeakInfo? selectedPeak;
    double bestCost = double.infinity;

    // Find best candidate using cost function
    for (final candidate in candidates) {
      final deltaCents =
          1200.0 * (math.log(candidate.freq / _predictedF0) / math.ln2).abs();
      final velocityTerm = (_velocityCentsPerS * deltaTimeS).abs();
      final velocityError = (deltaCents - velocityTerm).abs();

      final cost = 0.6 * deltaCents +
          0.3 * velocityError -
          0.1 * candidate.snr -
          0.05 * candidate.harmonicScore;

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
      final deltaCentsFromCurrent =
          1200.0 * (math.log(measuredF0 / _currentF0) / math.ln2).abs();

      // NOUVELLE LOGIQUE: Seuil de saut adaptatif basé sur la largeur spectrale
      // Si le compétiteur est un pic étroit (note tonale), on unlock plus vite
      // Si c'est un pic large (bruit), on tolère davantage
      double effectiveJumpThreshold = 100.0; // Default 100 cents
      double effectiveJumpDelayMs = 200.0; // Default 200 ms

      if (selectedPeak.spectralWidthHz > 0) {
        if (selectedPeak.spectralWidthHz < narrowPeakWidthHz) {
          // Pic étroit = note tonale précise → unlock rapide
          effectiveJumpThreshold = 80.0; // 80 cents (plus sensible)
          effectiveJumpDelayMs = 100.0; // 100 ms (2x plus rapide)
        } else if (selectedPeak.spectralWidthHz > widePeakWidthHz) {
          // Pic large = bruit → tolérer plus longtemps
          effectiveJumpThreshold = 150.0; // 150 cents (moins sensible)
          effectiveJumpDelayMs = 400.0; // 400 ms (2x plus lent)
        }
        // Entre narrowPeak et widePeak: valeurs par défaut (interpolation possible)
      }

      // Si saut > seuil adaptatif ET que ça dure > délai adaptatif → FORCE UNLOCK
      if (deltaCentsFromCurrent > effectiveJumpThreshold) {
        _jumpTimer += frameDurationMs;
        if (_jumpTimer > effectiveJumpDelayMs) {
          // Saut prolongé selon critères adaptatifs
          _state = DominantTrackerState.search;
          _unlockTimer = 0;
          _lockTimer = 0;
          _jumpTimer = 0;
          final widthInfo = selectedPeak.spectralWidthHz > 0
              ? " (width=${selectedPeak.spectralWidthHz.toStringAsFixed(1)}Hz)"
              : "";
          _lastLockReason =
              "FORCE UNLOCK: Jump ${deltaCentsFromCurrent.toStringAsFixed(0)} cents for ${_jumpTimer}ms$widthInfo";
          return DominantPitchResult(
            f0: 0.0,
            confidence: 0.0,
            state: _state,
            debugPeaks: peaks,
            predictedF0: _predictedF0,
            lockReason: _lastLockReason,
            currentWindow: _currentWindow,
            localNoiseFloorDb: 0.0,
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
        _velocityCentsPerS = _velocityCentsPerS * 0.5 +
            velocityCents * 0.5; // BEAUCOUP plus rapide
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
      _lastLockReason =
          "LOCKED: f0=${_currentF0.toStringAsFixed(1)} Hz, SNR=${selectedPeak.snr.toStringAsFixed(1)} dB";
    } else {
      // No valid candidate found - MAIS tracker autonome plus tenace
      // Ne pas incrémenter unlock timer si on n'a juste pas de hints YIN/Harm
      // Anchor guard: if we are still near the averaged f0, slow or freeze unlock
      bool nearAnchor = false;
      if (_avgF0Hz > 0) {
        for (final p in peaks) {
          final deltaCents =
              1200.0 * (math.log(p.freq / _avgF0Hz) / math.ln2).abs();
          if (deltaCents <= anchorWindowCents) {
            nearAnchor = true;
            break;
          }
        }
      }

      if (_transientGuardMs > 0) {
        // Freeze unlock during transient guard
        // Do not increment unlock timer
        _lastLockReason =
            "Transient guard active (${_transientGuardMs} ms left)";
      } else if (nearAnchor) {
        // Still seeing energy near the long-term f0 -> increment very slowly
        _unlockTimer += (frameDurationMs * 0.25).round(); // 4x slower
      } else if ((yinHint != null && yinHint > 0) ||
          (harmonicHint != null && harmonicHint > 0)) {
        _unlockTimer += frameDurationMs; // Normal unlock si hints actifs
      } else {
        // Tracker autonome: unlock plus lent sans hints
        _unlockTimer +=
            (frameDurationMs * 0.5).round(); // 2x plus lent à unlock
      }

      // Force unlock if current frequency becomes invalid
      if (_currentF0 <= 0 || !_currentF0.isFinite || _currentF0 > 8000.0) {
        _state = DominantTrackerState.search;
        _lockTimer = 0;
        _currentF0 = 0.0;
        _velocityCentsPerS = 0.0;
        _lastLockReason =
            "Force unlock: invalid f0 (${_currentF0.toStringAsFixed(1)} Hz)";
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
      final outsideCompetitors =
          peaks.where((peak) => peak.freq < fLow || peak.freq > fHigh);

      bool strongCompetitor = false;
      if (outsideCompetitors.isNotEmpty) {
        final strongestOutside = outsideCompetitors
            .reduce((a, b) => a.totalScore > b.totalScore ? a : b);
        // Adaptive competitor margin: base + slope * SNR shortfall
        // Estimate current inside-window SNR (best or 0 if none)
        final insideSnr = candidates.isNotEmpty
            ? candidates.map((p) => p.snr).reduce(math.max)
            : 0.0;
        final snrShortfall = math.max(0.0, lockThresholdDb - insideSnr);
        final effectiveMargin = competitorMarginBaseDb +
            competitorMarginAdaptiveSlope * snrShortfall;
        if (_transientGuardMs == 0 &&
            strongestOutside.snr > lockThresholdDb + effectiveMargin) {
          strongCompetitor = true;
          _lastLockReason =
              "Strong competitor (margin ${effectiveMargin.toStringAsFixed(1)} dB) at ${strongestOutside.freq.toStringAsFixed(1)} Hz (${strongestOutside.snr.toStringAsFixed(1)} dB)";
        }
      }

      // Check unlock conditions - logique normale basée sur les pics détectés
      final bestAvailableSnr =
          peaks.isNotEmpty ? peaks.map((p) => p.snr).reduce(math.max) : -120.0;
      // If a local noise floor is provided, adjust SNR guardrail to lock persistence floor
      double adjustedUnlockThreshold = unlockThresholdDb;
      if (_lastLocalNoiseFloorDb != 0.0) {
        // Interpret bestAvailableSnr as peakDb - localNoiseDb (already SNR),
        // but we enforce a minimum allowed SNR floor while locked.
        adjustedUnlockThreshold = math.min(unlockThresholdDb, lockedSnrFloorDb);
      }

      // CONDITIONS D'UNLOCK RESTAURÉES: Équilibre responsivité/stabilité
      final shouldUnlock = (_transientGuardMs == 0) &&
          ((bestAvailableSnr < adjustedUnlockThreshold &&
                  _unlockTimer >= holdOutMs) || // Guarded by SNR floor
              (strongCompetitor &&
                  _unlockTimer >= 100) || // Rapide pour concurrent
              (_unlockTimer >= holdOutMs * 2)); // Force unlock raisonnable

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
          unlockReason =
              "Unlocked: SNR ${bestAvailableSnr.toStringAsFixed(1)} dB < ${adjustedUnlockThreshold.toStringAsFixed(1)} dB for $_unlockTimer ms";
        }
        _lastLockReason = unlockReason;
      } else {
        final autonomousMode = (yinHint == null || yinHint <= 0) &&
            (harmonicHint == null || harmonicHint <= 0);
        final modeStr = autonomousMode ? "AUTONOMOUS MODE" : "WITH HINTS";
        _lastLockReason =
            "Hold-out ($modeStr): $_unlockTimer/$holdOutMs ms, best SNR ${bestAvailableSnr.toStringAsFixed(1)} dB";
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
      localNoiseFloorDb: _lastLocalNoiseFloorDb,
    );
  }

  PeakInfo? _attemptFundamentalRescue(
      List<PeakInfo> peaks, Float32List spectrumDb, double binWidth) {
    for (final peak in peaks) {
      // Test f = peak/2
      final f2 = peak.freq / 2.0;
      if (f2 >= fMin && f2 <= fMax) {
        final combGain =
            _calculateCombGain(spectrumDb, binWidth, f2, [2.0, 3.0, 4.0]);
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
        final combGain =
            _calculateCombGain(spectrumDb, binWidth, f3, [2.0, 3.0, 4.0]);
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
  void _applyFundamentalComparator(
      List<PeakInfo> peaks, Float32List spectrumDb, double binWidth) {
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

        if (ratio > 1.9 && ratio < 2.1) {
          // 2ème harmonique
          isHarmonicRelation = true;
          harmonicPenalty = 2.0; // Pénalité modérée
        } else if (ratio > 2.9 && ratio < 3.1) {
          // 3ème harmonique
          isHarmonicRelation = true;
          harmonicPenalty = 3.0; // Pénalité plus forte
        } else if (ratio > 3.9 && ratio < 4.1) {
          // 4ème harmonique
          isHarmonicRelation = true;
          harmonicPenalty = 4.0; // Pénalité forte
        } else if (ratio > 4.9 && ratio < 5.1) {
          // 5ème harmonique
          isHarmonicRelation = true;
          harmonicPenalty = 5.0; // Pénalité très forte
        } else if (ratio > 5.9 && ratio < 6.1) {
          // 6ème harmonique
          isHarmonicRelation = true;
          harmonicPenalty = 6.0; // Pénalité maximale
        }

        if (isHarmonicRelation) {
          // Vérifier la cohérence harmonique : le candidat devrait avoir ses harmoniques présentes
          final harmonicSupport = _calculateCombGain(
              spectrumDb, binWidth, candidate.freq, [2.0, 3.0, 4.0]);

          // PROTECTION CONTRE SOUS-HARMONIQUES ARTIFICIELLES
          // 1. Le candidat doit avoir un SNR minimum (éviter bruit de fond)
          final minSnrForFundamental = 8.0;
          // 2. Le candidat ne doit pas être trop faible comparé à l'harmonique
          final levelDifference = peak.dbLevel - candidate.dbLevel;
          final maxLevelDiff =
              15.0; // L'harmonique ne devrait pas être >15dB plus fort que fondamental
          // 3. Support harmonique suffisant
          final minHarmonicSupport = 3.0;

          // Appliquer toutes les protections
          bool isValidFundamental = candidate.snr >= minSnrForFundamental &&
              levelDifference <= maxLevelDiff &&
              harmonicSupport >= minHarmonicSupport;

          if (isValidFundamental) {
            // Booster le score du candidat (fondamental potentiel)
            final fundamentalBonus =
                8.0 + harmonicSupport - (harmonicPenalty * 0.5);
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

  double _calculateCombGain(Float32List spectrumDb, double binWidth, double f0,
      List<double> harmonics) {
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

  // Compute average dB over [fMin, fMax] band to detect broadband transients
  double _computeBandAvgDb(Float32List spectrumDb, double binWidth) {
    final minBin = (fMin / binWidth).floor().clamp(0, spectrumDb.length - 1);
    final maxBin =
        (fMax / binWidth).floor().clamp(minBin, spectrumDb.length - 1);
    if (maxBin <= minBin) return -120.0;
    double sum = 0.0;
    int count = 0;
    for (int i = minBin; i <= maxBin; i++) {
      final v = spectrumDb[i];
      if (v.isFinite) {
        sum += v;
        count++;
      }
    }
    if (count == 0) return -120.0;
    return sum / count;
  }
}
