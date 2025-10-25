import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import '../../../dsp/yin.dart' as yin_dsp;
import '../../../dsp/harmonic_salience.dart';
import '../../../dsp/pitch_fusion.dart';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import 'spectroid_config.dart';
import 'windows_fft.dart';
import 'audio_dsp.dart';
import 'cascade_decimator.dart';
import '../../../dsp/dominant_pitch_tracker.dart';

class SpectroidFrame {
  final Float32List magLinear; // linear power data (PSD or integrated bands)
  final double peakHz;
  final double peakDb;
  final int effectiveSampleRate;
  final String displayUnit; // "dBFS" or "dB/Hz"
  final bool spectroidMode;
  final AudioEffectStatus audioStatus; // Current audio effects status
  // Legacy pitch detection outputs (kept for compatibility)
  final double f0Yin;
  final double confYin;
  final double f0Harm;
  final double confHarm;
  final double f0Fused;
  final double confFused;
  // New dominant tracker outputs
  final double f0Tracked;
  final String trackerState; // search|locked
  final List<PeakInfo> debugPeaks;
  final double predictedF0;
  final String lockReason;
  final double currentWindow;
  // Optional: local noise floor estimate around tracked band (dB)
  // Used for informing locked-state persistence behavior
  // Not displayed currently but can be wired for debug
  // This is the median of a band excluding the peak bins.
  // 0.0 means not computed.
  final double localNoiseFloorDb;

  SpectroidFrame(
    this.magLinear,
    this.peakHz,
    this.peakDb,
    this.effectiveSampleRate,
    this.displayUnit,
    this.spectroidMode,
    this.audioStatus,
    this.f0Yin,
    this.confYin,
    this.f0Harm,
    this.confHarm,
    this.f0Fused,
    this.confFused,
    this.f0Tracked,
    this.trackerState,
    this.debugPeaks,
    this.predictedF0,
    this.lockReason,
    this.currentWindow,
    this.localNoiseFloorDb,
  );
}

class SpectroidEngine {
  // Toggle to enable verbose DSP logs; disabled by default for performance
  static const bool kDspVerboseLogs = true;
  final AudioRecorder _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  Timer? _scheduler;

  // ring buffer in float samples
  late Float32List _ring;
  int _writeIdx = 0;
  bool _filled = false;

  // analysis state
  Float32List? _window;
  Float32List? _prevLinear; // linear-domain averaging buffer
  double _fcEma = 0;
  AudioDSP? _audioDsp;
  AudioEffectStatus _audioStatus = const AudioEffectStatus();
  // DecimatorFIR? _decimator; // Remplacé par cascade plus efficace
  CascadeDecimator? _cascadeDecimator;
  int _effectiveFs = 48000;
  int _decimM = 1;
  // Pitch detection - using new dominant tracker
  DominantPitchTracker? _dominantTracker;
  // Hybrid detectors (Option C): YIN + Harmonic + Fusion
  yin_dsp.YinDetector? _yin;
  PitchFusion? _fusion;
  // Tracker autonome - garde dernières valeurs valides pour hints de continuité
  double? _lastValidYin;
  double? _lastValidHarm;
  // Post-decimation HPF state (first-order IIR)
  double _hpfX1 = 0.0, _hpfY1 = 0.0;
  double _hpfAlpha = 0.0;
  
  // EMA lock delay: apply low EMA only after 1s in LOCKED state
  DateTime? _lockStartTime;
  static const _emaLockDelayMs = 1000; // 1 second delay after lock

  Future<void> start(
      {required SpectroidConfig cfg,
      required void Function(SpectroidFrame) onFrame}) async {
    if (await _rec.isRecording()) {
      await _rec.stop();
    }

    final sampleRate = cfg.fsCapture;
    // Ladder decimation: 2^k with k in [0,9]
    final k = cfg.decimLevels.clamp(0, 9);
    final ladder = 1 << k; // 2^k
    // Combine ladder with explicit FIR decimation option (max to ensure strong effect if either is high)
    final requestedM =
        {1, 2, 4, 8}.contains(cfg.firDecimation) ? cfg.firDecimation : 1;
    _decimM = math.max(ladder, requestedM);
    _effectiveFs = (sampleRate / _decimM).round();
    // Utilise CascadeDecimator pour meilleure performance
    _cascadeDecimator =
        (_decimM == 1) ? null : CascadeDecimator(totalFactor: _decimM);
    _ring = Float32List(_effectiveFs * 2); // 2s buffer at effective Fs
    _writeIdx = 0;
    _filled = false;
    _window = makeWindow(cfg.fftSize, cfg.window, beta: cfg.kaiserBeta ?? 8.0);
    _prevLinear = null;
    _fcEma = 0;

    // Initialize AudioDSP with configuration
    _audioDsp = AudioDSP(
      sampleRate: sampleRate.toDouble(),
      dcFilterType: cfg.dcFilter,
      notchFilter: cfg.notchFilter,
    );
    // Setup low-frequency HPF after decimation
    _setupPostDecimHpf(cfg.lowFreqHpf);
    // Derive effective detection range considering guidance (if any)
    double effFMin = cfg.pitchFMin;
    double effFMax = cfg.pitchFMax;
    if (cfg.guidanceEnabled && cfg.guidedTargetsHz.isNotEmpty) {
      final targets = cfg.guidedTargetsHz
          .where((f) => f.isFinite && f > 0)
          .toList()
        ..sort();
      if (targets.isNotEmpty) {
        final minT = targets.first;
        final maxT = targets.last;
        final ratio =
            math.pow(2.0, cfg.guidanceWindowCents / 1200.0).toDouble();
        effFMin = (minT / ratio).clamp(15.0, 12000.0);
        effFMax = (maxT * ratio).clamp(15.0, 12000.0);
      }
    }
    // Initialize dominant pitch tracker if enabled
    if (cfg.enablePitch) {
      _dominantTracker = DominantPitchTracker(
        sampleRate: _effectiveFs.toDouble(),
        fMin: effFMin,
        fMax: effFMax,
        lockThresholdDb: cfg.dominantLockThresholdDb,
        unlockThresholdDb: cfg.dominantUnlockThresholdDb,
        holdInMs: cfg.dominantHoldInMs,
        holdOutMs: cfg.dominantHoldOutMs,
        lockWindowCents: cfg.dominantLockWindowCents,
        adaptiveWindow: cfg.trackerAdaptiveWindow,
        windowMinCents: cfg.dominantLockWindowCents * 0.5,
        windowMaxCents: cfg.dominantLockWindowCents * 1.5,
        maxJumpCentsPerS: cfg.dominantMaxJumpCentsPerS,
        rescueEnabled: cfg.dominantRescueEnabled,
        peakProminenceDb: cfg.dominantPeakProminenceDb,
        neighborSpanBins: cfg.dominantNeighborSpanBins,
      );
      // Configure locked-state SNR floor persistence from config
      _dominantTracker!.lockedSnrFloorDb = cfg.lockedSnrFloorDb;
      // Configure competitor margin behavior
      _dominantTracker!.competitorMarginBaseDb =
          cfg.dominantCompetitorMarginBaseDb;
      _dominantTracker!.competitorMarginAdaptiveSlope =
          cfg.dominantCompetitorMarginAdaptiveSlope;
      // Configure spectral width discrimination
      _dominantTracker!.narrowPeakWidthHz = cfg.narrowPeakWidthHz;
      _dominantTracker!.widePeakWidthHz = cfg.widePeakWidthHz;
      _dominantTracker!.narrowPeakMarginDb = cfg.narrowPeakMarginDb;
      _dominantTracker!.widePeakMarginDb = cfg.widePeakMarginDb;
    } else {
      _dominantTracker = null;
    }
    // Initialize YIN + Fusion (hybrid Option C)
    if (cfg.enablePitch) {
      // YIN RESTAURÉ: Paramètres historiques équilibrés
      final yinWindow = math.min(
          384, cfg.fftSize); // RESTAURÉ: Fenêtre historique stable (was 512)
      final yinHop = math.min(
          48, (yinWindow * 0.125).toInt()); // RESTAURÉ: Hop historique (was 32)
      _yin = yin_dsp.YinDetector(
        sampleRate: _effectiveFs,
        windowSize: yinWindow, // Fenêtre optimisée réactivité/précision
        hopSize: yinHop, // Updates très fréquents pour convergence rapide
        threshold: 0.10, // RESTAURÉ: Valeur historique équilibrée (was 0.08)
      );
      if (kDspVerboseLogs) {
        debugPrint(
            "YIN SETUP HISTORIQUE RESTAURÉ: windowSize=$yinWindow, hopSize=$yinHop, threshold=0.10, fs=$_effectiveFs");
      }
      _fusion = PitchFusion(
        wYin: 0.65, // RÉDUIT: Pour compenser YIN qui lâche tôt (was 0.75)
        wHarm:
            0.35, // AUGMENTÉ: Harmonic plus d'influence pour compenser (was 0.25)
        antiOctaveEnabled: true,
        subharmThresh: 0.5, // Valeur historique stable
      );
      if (kDspVerboseLogs) {
        debugPrint(
            "FUSION SETUP AMPLITUDE RESILIENT: wYin=65%, wHarm=35% (compense YIN amplitude)");
      }
    } else {
      _yin = null;
      _fusion = null;
    }

    if (kDspVerboseLogs) {
      debugPrint(
          'Audio: requested_fs=$sampleRate, actual_fs=$_effectiveFs, decim=$_decimM, unprocessed=${_audioStatus.unprocessedAvailable}, effects=${cfg.disableAudioEffects ? 'off' : 'on'}');
    }

    // Configure audio source and effects
    AudioSource audioSource = cfg.audioSource;

    // Try UNPROCESSED first, fallback to VOICE_RECOGNITION
    if (audioSource == AudioSource.unprocessed) {
      try {
        await _configureUnprocessedAudio();
        _audioStatus = _audioStatus.copyWith(unprocessedAvailable: true);
      } catch (e) {
        if (kDspVerboseLogs) {
          debugPrint(
              'UNPROCESSED source unavailable, falling back to VOICE_RECOGNITION: $e');
        }
        audioSource = AudioSource.voiceRecognition;
        _audioStatus = _audioStatus.copyWith(unprocessedAvailable: false);
      }
    }

    // Disable audio effects if requested
    if (cfg.disableAudioEffects) {
      await _disableAudioEffects();
    }

    final stream = await _rec.startStream(RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      numChannels: 1,
      sampleRate: sampleRate,
      // Disable platform processing where supported
      echoCancel: cfg.disableAudioEffects ? false : true,
      noiseSuppress: cfg.disableAudioEffects ? false : true,
      autoGain: cfg.disableAudioEffects ? false : true,
    ));
    // Raw PCM stream
    _sub = stream.listen((frame) {
      // frame is PCM 16-bit
      final b = frame; // Uint8List
      for (int i = 0; i + 1 < b.length; i += 2) {
        final lo = b[i];
        final hi = b[i + 1];
        int sample = (hi << 8) | lo;
        if (sample & 0x8000 != 0) sample = sample - 0x10000;
        double x = sample / 32768.0;

        // Apply AudioDSP filters
        if (_audioDsp != null) {
          x = _audioDsp!.process(x);
        }
        // Cascade decimation pour performance optimisée
        if (_cascadeDecimator != null) {
          final y = _cascadeDecimator!.processSample(x);
          if (y == null) continue;
          _ring[_writeIdx++] = y;
        } else {
          _ring[_writeIdx++] = x;
        }
        if (_writeIdx >= _ring.length) {
          _writeIdx = 0;
          _filled = true;
        }
      }
    });

    // schedule analysis
    final hop = (cfg.fftSize * (1 - cfg.overlap)).clamp(1, cfg.fftSize).toInt();
    final hopMs = (1000 * hop / _effectiveFs).clamp(5, 100).toInt();
    _scheduler?.cancel();
    _scheduler = Timer.periodic(Duration(milliseconds: hopMs), (_) {
      if (_window == null) return;
      if (!_filled && _writeIdx < cfg.fftSize) return;
      // gather latest frame of size N with wrap-around
      final frame = Float32List(cfg.fftSize);
      int start = _writeIdx - cfg.fftSize;
      if (start < 0) start += _ring.length;
      for (int i = 0; i < cfg.fftSize; i++) {
        int idx = start + i;
        if (idx >= _ring.length) idx -= _ring.length;
        frame[i] = _ring[idx];
      }
      // Optional DC removal (subtract mean) before windowing
      if (cfg.dcRemove) {
        double sum = 0.0;
        for (int i = 0; i < frame.length; i++) {
          sum += frame[i];
        }
        final mean = sum / frame.length;
        for (int i = 0; i < frame.length; i++) {
          frame[i] -= mean;
        }
      }
      // Apply post-decimation HPF if enabled
      if (cfg.lowFreqHpf != LowFreqHighPass.off) {
        for (int i = 0; i < frame.length; i++) {
          final x = frame[i];
          final y = _hpfAlpha * _hpfY1 + x - _hpfX1;
          _hpfX1 = x;
          _hpfY1 = y;
          frame[i] = y;
        }
      }
      // Calculate FFT amplitude once (for peak detection & pitch harmonic salience)
      final rawMag = computeMagnitude(frame, _window!); // amplitude (linear)

      // Choose spectral calculation based on display mode
      final Float32List displayData;
      final wm = computeWindowMetrics(_window!);
      final binWidth = _effectiveFs / cfg.fftSize;
      if (cfg.spectroidMode) {
        // Spectroid-like bands (integrated)
        displayData =
            computeIntegratedPowerBands(frame, _window!, _effectiveFs);
      } else if (cfg.displayMode == DisplayMode.psdPrecise) {
        // PSD precise per Hz, Welch normalization
        displayData = computePsdPerHzPrecise(frame, _window!, _effectiveFs);
      } else if (cfg.displayMode == DisplayMode.spectroidCompat) {
        // Spectroid-compatible per-bin power (no per-Hz normalization)
        // Use PSD per Hz then convert to per-bin to include correct one-sided handling
        final pHz = computePsdPerHzPrecise(frame, _window!, _effectiveFs);
        final out = Float32List(pHz.length);
        for (int i = 0; i < pHz.length; i++) {
          out[i] = (pHz[i] * binWidth).toDouble();
        }
        displayData = out;
      } else {
        displayData = computePsdPerHzPrecise(frame, _window!, _effectiveFs);
      }

      // Debug amplitude vs display data comparison
      if (kDspVerboseLogs && rawMag.isNotEmpty && displayData.isNotEmpty) {
        final int m = math.min(10, displayData.length);
        double ampSum = 0.0, displaySum = 0.0;
        for (int i = 0; i < m; i++) {
          ampSum += rawMag[i];
          displaySum += displayData[i];
        }
        final ampAvg = ampSum / m;
        final displayAvg = displaySum / m;
        // Use power dB (10*log10) for both to maintain consistency
        final ampDb = 10 * math.log(ampAvg * ampAvg + 1e-20) / math.ln10;
        final displayDb = 10 * math.log(displayAvg + 1e-20) / math.ln10;
        final unit = cfg.displayUnit == DisplayUnit.dBFS ? 'dBFS' : 'dB/Hz';
        debugPrint(
            'FFT N=${cfg.fftSize}: Amp[0..$m]=${ampDb.toStringAsFixed(1)} dB, Display[0..$m]=${displayDb.toStringAsFixed(1)} $unit');
      }

      if (kDspVerboseLogs) {
        debugPrint(
            'FFT: N=${cfg.fftSize}, window=${cfg.window.name}, coherent_gain=${wm.coherentGain.toStringAsFixed(6)}, ENBW_bins=${wm.enbwBins.toStringAsFixed(3)}, bin_width=${binWidth.toStringAsFixed(3)}Hz');
        final modeStr = (cfg.displayMode == DisplayMode.psdPrecise)
            ? 'PSD_per_Hz'
            : 'Spectroid_per_bin';
        debugPrint(
            'Mode=$modeStr, decim=$_decimM, fs_eff=$_effectiveFs, hpf=${cfg.lowFreqHpf.name}, hz_per_bin_at_DC=${binWidth.toStringAsFixed(3)}');
      }

      // Use effective sample rate (post-decimation) for frequency bin width
      final binHz = _effectiveFs / cfg.fftSize;
      double peakFreq = 0.0;
      double peakDb = -120.0;

      // Peak detection only if enabled
      if (cfg.peakTracking) {
        final kMin =
            (cfg.peakSearchMin / binHz).clamp(0, rawMag.length - 1).toInt();
        final kMax = (cfg.peakSearchMax / binHz)
            .clamp(kMin + 1, rawMag.length - 1)
            .toInt();
        int kPeak = kMin;
        double vPeak = -1e9;
        for (int k = kMin; k <= kMax; k++) {
          if (rawMag[k] > vPeak) {
            vPeak = rawMag[k];
            kPeak = k;
          }
        }
        // Harmonic guard: if 2f dominates, halve
        if (cfg.harmonicGuard) {
          final k2 = (kPeak * 2).clamp(0, rawMag.length - 1);
          if (rawMag[k2] > rawMag[kPeak]) {
            kPeak = (kPeak / 2).floor();
            vPeak = rawMag[kPeak];
          }
        }

        final fPeakInst = kPeak * binHz;
        final a = cfg.emaAlphaFreq;
        _fcEma = a * fPeakInst + (1 - a) * _fcEma;
        peakFreq = _fcEma;
        // Convert amplitude peak to power dB for consistency (square the amplitude)
        peakDb = 10 * math.log(vPeak * vPeak + 1e-20) / math.ln10;
        if (kDspVerboseLogs) {
          debugPrint(
              'SpectroidEngine: Peak detected at ${peakFreq.toStringAsFixed(1)} Hz, ${peakDb.toStringAsFixed(1)} dB (power)');
        }
      }

      // Create a working copy for visual pipeline (decimation + smoothing)
      Float32List mag = Float32List.fromList(displayData);

      // Optional bin-group decimation for display only (operate in power domain)
      final d = cfg.decimation.clamp(0, 9);
      if (d > 1) {
        final int group = d; // group size
        final int outLen = (mag.length / group).floor();
        final dec = Float32List(outLen);
        for (int i = 0; i < outLen; i++) {
          double acc = 0.0; // accumulate power
          for (int j = 0; j < group; j++) {
            final v = mag[i * group + j];
            acc += v; // sum of power (PSD)
          }
          // Average power across group preserves PSD density (power/Hz)
          // Each grouped bin represents the same Hz bandwidth as individual bins
          dec[i] = (acc / group).toDouble();
        }
        mag = dec;
      }

      // Averaging (EMA): prefer linear domain for unbiased PSD precise measurements
      if (_prevLinear == null || _prevLinear!.length != mag.length) {
        _prevLinear = Float32List.fromList(mag);
      }
      // L'EMA sera appliqué APRÈS le pitch tracking (alpha dépend de l'état LOCKED/SEARCH)

      // Continuer avec mag pour le pitch tracking (pas encore lissé)

      // Debug: verify spectrum metrics and low-band stats (0-100 Hz)
      if (kDspVerboseLogs && mag.isNotEmpty) {
        final int m = math.min(10, mag.length);
        double s = 0.0;
        for (int i = 0; i < m; i++) {
          s += mag[i];
        }
        final avg = s / m;
        final avgDb = 10 * math.log(avg + 1e-20) / math.ln10;
        // Low-band indices
        final hiIdx = (100 / binWidth).clamp(1, mag.length).floor();
        double sumLb = 0.0;
        final tmp = <double>[];
        for (int i = 0; i < hiIdx; i++) {
          sumLb += mag[i];
          tmp.add(mag[i]);
        }
        final meanLb = sumLb / math.max(1, hiIdx);
        tmp.sort();
        final medianLb = tmp[tmp.length ~/ 2];
        double mu = meanLb;
        double variance = 0.0;
        for (final v in tmp) {
          final d = v - mu;
          variance += d * d;
        }
        final stdLb = math.sqrt(variance / math.max(1, tmp.length));
        final unitLabel =
            (cfg.displayMode == DisplayMode.psdPrecise && !cfg.spectroidMode)
                ? 'dBFS/Hz'
                : 'dBFS/bin';
        debugPrint(
            'To Painter: avg[0..$m]=${avgDb.toStringAsFixed(1)} $unitLabel, len=${mag.length}');
        final floorDb = 10 * math.log(meanLb + 1e-20) / math.ln10;
        final meanDb = floorDb;
        final medianDb = 10 * math.log(medianLb + 1e-20) / math.ln10;
        final stdDb = 10 * math.log(stdLb + 1e-20) / math.ln10;
        debugPrint(
            'Low-band [0-100 Hz]: floor=${floorDb.toStringAsFixed(1)} $unitLabel (mean=${meanDb.toStringAsFixed(1)}, median=${medianDb.toStringAsFixed(1)}, std=${stdDb.toStringAsFixed(1)})');
      }

      final frameUnit =
          (cfg.displayMode == DisplayMode.psdPrecise && !cfg.spectroidMode)
              ? 'dBFS/Hz'
              : 'dBFS/bin';

      // New dominant pitch tracking using post-processed spectrum
      double fTracked = 0.0;
      String trackerState = 'search';
      List<PeakInfo> debugPeaks = [];
      double predictedF0 = 0.0;
      String lockReason = "";
      double currentWindow = 60.0;
      double localNoiseFloorDb = 0.0;
      // Noise detection visualization

      // Hybrid Option C: YIN + Harmonic + Fusion
      double f0Yin = 0.0, confYin = 0.0;
      double f0Harm = 0.0, confHarm = 0.0;
      double f0Fused = 0.0, confFused = 0.0;

      if (cfg.enablePitch) {
        // 1) Run YIN on time-domain frame with ADAPTIVE processing for low SNR
        if (_yin != null) {
          // Pre-emphasis pour améliorer SNR avant YIN
          final preEmphasizedFrame = _applyPreEmphasis(frame);

          // Estimation noise floor pour threshold adaptatif
          final rms = _calculateRMS(preEmphasizedFrame);
          final noiseFloorDb = 20 * math.log(rms + 1e-12) / math.ln10;

          // YIN threshold adaptatif basé sur l'amplitude
          double adaptiveThreshold = 0.10; // Base
          if (noiseFloorDb < -50.0) {
            // Signal très faible : threshold plus tolérant
            adaptiveThreshold =
                math.max(0.03, 0.10 + (noiseFloorDb + 50.0) * 0.002);
          }

          // Créer instance YIN adaptative avec threshold spécialisé
          final yinAdaptive = yin_dsp.YinDetector(
            windowSize: _yin!.windowSize,
            hopSize: _yin!.hopSize,
            sampleRate: _yin!.sampleRate,
            threshold: adaptiveThreshold,
          );

          final yr = yinAdaptive.process(preEmphasizedFrame);

          // Apply safety bounds pour YIN (plus tolérant pour signaux faibles) et clamp à la bande effective
          f0Yin = (yr.f0.isFinite && yr.f0 > 15 && yr.f0 < 12000) ? yr.f0 : 0.0;
          if (f0Yin > 0 && (f0Yin < effFMin || f0Yin > effFMax)) {
            f0Yin = 0.0;
          }
          confYin = yr.confidence.clamp(0.0, 1.0);

          if (kDspVerboseLogs && noiseFloorDb < -50.0 && f0Yin > 0) {
            debugPrint(
                'YIN ADAPTIVE: noiseFloor=${noiseFloorDb.toStringAsFixed(1)}dB, threshold=${adaptiveThreshold.toStringAsFixed(3)}, f0=${f0Yin.toStringAsFixed(1)}Hz');
          }
        }

        // 2) Harmonic salience on the same spectrum as display (linear power)
        // Build frequency axis for current spectrum (pre-decimation displayData)
        final int L = displayData.length;
        final List<double> freqs =
            List<double>.generate(L, (i) => i * binWidth);
        // Paramètres adaptatifs Harmonic selon amplitude
        int adaptiveMaxHarmonics;
        double adaptiveTolCents;
        double adaptiveWeightDecay;

        if (peakDb < -55.0) {
          // Signaux faibles : plus d'harmoniques, plus tolérant
          adaptiveMaxHarmonics = 6;
          adaptiveTolCents = 55.0; // Tolérance accrue
          adaptiveWeightDecay =
              0.50; // Moins de decay = plus de poids sur harmoniques
          if (kDspVerboseLogs) {
            debugPrint(
                'HARMONIC ADAPTIVE: maxH=6, tol=55.0cents, decay=0.50 for ${peakDb.toStringAsFixed(1)}dB');
          }
        } else {
          // Signaux normaux : paramètres conservateurs
          adaptiveMaxHarmonics = 4;
          adaptiveTolCents = 45.0;
          adaptiveWeightDecay = 0.60;
        }

        final harmonic = HarmonicSalience(
          freqs: freqs,
          maxHarmonics: adaptiveMaxHarmonics,
          tolCents: adaptiveTolCents,
          weightDecay: adaptiveWeightDecay,
        );
        final hres = harmonic.process(displayData, effFMin, effFMax);
        // Apply safety bounds pour Harmonic (plus tolérant pour signaux faibles)
        f0Harm = (hres.f0.isFinite && hres.f0 > 15 && hres.f0 < 12000)
            ? hres.f0
            : 0.0;
        confHarm = hres.confidence.clamp(0.0, 1.0);

        // Filtre de silence : Harmonic a tendance à détecter des faux-positifs dans le bruit
        // RENFORCÉ: Cas spécial YIN absent + confiance modérée = probable faux-positif
        bool suppressHarmonic = false;

        // Condition 1: Signal très faible
        if (peakDb < -65.0 && confHarm < 0.80) {
          suppressHarmonic = true;
        }

        // Condition 2: YIN absent + confiance suspecte (faux-positifs 100-150Hz à 67%)
        if (f0Yin == 0.0 && confHarm > 0.60 && confHarm < 0.75) {
          suppressHarmonic = true;
        }

        if (suppressHarmonic) {
          if (kDspVerboseLogs) {
            debugPrint(
                'HARMONIC SILENCE FILTER: Suppressing Harm=${hres.f0.toStringAsFixed(1)}Hz@${(hres.confidence * 100).toStringAsFixed(0)}% (Peak=${peakDb.toStringAsFixed(1)}dB, YIN=${f0Yin.toStringAsFixed(1)}Hz)');
          }
          f0Harm = 0.0;
          confHarm = 0.0;
        }

        // 3) Fuse YIN + Harmonic to produce a robust candidate
        if (_fusion != null) {
          final fused = _fusion!.fuse(f0Yin, confYin, f0Harm, confHarm);
          // Apply safety bounds pour fusion (plus tolérant pour signaux faibles)
          f0Fused = (fused.f0.isFinite && fused.f0 > 15 && fused.f0 < 12000)
              ? fused.f0
              : 0.0;
          confFused = fused.confidence.clamp(0.0, 1.0);

          // Debug fusion logic pour comprendre l'impact des poids
          if (kDspVerboseLogs &&
              f0Yin > 0 &&
              f0Harm > 0 &&
              (f0Yin - f0Harm).abs() > 10.0) {
            final expectedWeighted =
                (f0Yin * confYin * 0.75 + f0Harm * confHarm * 0.25) /
                    (confYin * 0.75 + confHarm * 0.25 + 1e-12);
            final ratio = f0Harm / f0Yin;
            final isOctave = ratio > 1.8 && ratio < 2.2;
            final yinTrusted = confYin > 0.9;
            debugPrint(
                'FUSION DEBUG: YIN=${f0Yin.toStringAsFixed(1)}Hz (conf=${confYin.toStringAsFixed(2)}), Harm=${f0Harm.toStringAsFixed(1)}Hz (conf=${confHarm.toStringAsFixed(2)})');
            debugPrint(
                'FUSION LOGIC: Ratio=${ratio.toStringAsFixed(2)}, IsOctave=$isOctave, YinTrusted=$yinTrusted');
            debugPrint(
                'FUSION RESULT: Expected=${expectedWeighted.toStringAsFixed(1)}Hz, Actual=${f0Fused.toStringAsFixed(1)}Hz, Weights=75%YIN/25%Harm');
          }
        }
      }

      if (cfg.enablePitch && _dominantTracker != null) {
        // Convert display spectrum to dB power (10*log10) for peak analysis
        final spectrumDb = Float32List(displayData.length);
        for (int i = 0; i < displayData.length; i++) {
          // Convert to power dB: 10*log10(power + epsilon)
          spectrumDb[i] = 10 * math.log(displayData[i] + 1e-20) / math.ln10;
        }
        final frameMs = (1000 * frame.length / _effectiveFs).round();
        final binWidth = _effectiveFs / cfg.fftSize;
        // Guided tuning: apply soft bias near guided targets to assist locking
        final Float32List trackerDb;
        if (cfg.guidanceEnabled && cfg.guidedTargetsHz.isNotEmpty) {
          trackerDb = Float32List.fromList(spectrumDb);
          _applyGuidanceBias(
            trackerDb,
            binWidth: binWidth.toDouble(),
            targetsHz: cfg.guidedTargetsHz,
            windowCents: cfg.guidanceWindowCents,
            biasDb: cfg.guidanceBiasDb,
          );
        } else {
          trackerDb = spectrumDb;
        }

        // TRACKER AUTONOME: Garde la dernière fréquence comme hint si YIN/Harm s'arrêtent
        // Cela permet au tracker de maintenir le lock même sans détection externe

        // Garde les dernières valeurs valides pour hints de continuité
        if (f0Yin > 0) _lastValidYin = f0Yin;
        if (f0Harm > 0) _lastValidHarm = f0Harm;

        // Compute a local noise floor around predicted or peak f0 band in spectrumDb
        if (_dominantTracker != null) {
          // pick center around predictedF0 (if any) else the strongest peak from spectrumDb
          double centerHz;
          if (predictedF0 > 0) {
            centerHz = predictedF0;
          } else if (f0Yin > 0) {
            centerHz = f0Yin;
          } else if (f0Harm > 0) {
            centerHz = f0Harm;
          } else {
            // fallback: use display peakFreq
            centerHz =
                peakFreq > 0 ? peakFreq : (cfg.pitchFMin + cfg.pitchFMax) * 0.5;
          }
          final int centerBin =
              (centerHz / binWidth).round().clamp(1, spectrumDb.length - 2);
          final int span =
              (8).clamp(3, spectrumDb.length - 2); // ±8 bins ~ modest bandwidth
          final vals = <double>[];
          for (int b = math.max(1, centerBin - span);
              b <= math.min(spectrumDb.length - 2, centerBin + span);
              b++) {
            // Skip the immediate 3-bin neighborhood to avoid the peak
            if ((b - centerBin).abs() <= 3) continue;
            vals.add(spectrumDb[b]);
          }
          if (vals.isNotEmpty) {
            vals.sort();
            localNoiseFloorDb = vals[vals.length ~/ 2];
          }
        }

        // Anti-octave pre-correction for Harm hint based on spectrum evidence
        if (f0Harm > 0) {
          final corrected = _correctHarmonicHintOctave(
              f0Harm, spectrumDb, binWidth.toDouble());
          if ((corrected - f0Harm).abs() > 0.5) {
            if (kDspVerboseLogs) {
              debugPrint(
                  'HARM OCTAVE CORRECTION: ${f0Harm.toStringAsFixed(1)} -> ${corrected.toStringAsFixed(1)}');
            }
            f0Harm = corrected;
          }
        }

        // If guided tuning enabled, we will provide hints by biasing peaks later
        final result = _dominantTracker!.update(
          spectrumDb: trackerDb,
          binWidth: binWidth.toDouble(),
          frameDurationMs: frameMs,
          yinHint: f0Yin > 0
              ? f0Yin
              : _lastValidYin, // Utilise dernière valeur si YIN s'arrête
          harmonicHint: f0Harm > 0
              ? f0Harm
              : _lastValidHarm, // Utilise dernière valeur si Harm s'arrête
          localNoiseFloorDb: localNoiseFloorDb,
          externalTransientDetected:
              false, // Plus utilisé - EMA géré par état LOCKED
        );

        // Safety bounds pour DominantTracker (plus tolérant pour signaux faibles)
        fTracked = (result.f0.isFinite && result.f0 > 15 && result.f0 < 12000)
            ? result.f0
            : 0.0;
        trackerState = result.state.name;
        debugPeaks = result.debugPeaks;
        predictedF0 = (result.predictedF0.isFinite &&
                result.predictedF0 > 15 &&
                result.predictedF0 < 12000)
            ? result.predictedF0
            : 0.0;
        lockReason = result.lockReason;
        currentWindow = result.currentWindow;
      }

      // APPLIQUER EMA MAINTENANT
      // Stratégie avec délai: attendre 1s après LOCK avant d'appliquer EMA bas
      double adaptiveAlpha;
      if (trackerState == 'locked') {
        // Démarrer le timer si passage en LOCKED
        _lockStartTime ??= DateTime.now();
        
        // Vérifier si le délai est écoulé
        final lockDuration = DateTime.now().difference(_lockStartTime!).inMilliseconds;
        if (lockDuration >= _emaLockDelayMs) {
          // Délai écoulé → appliquer EMA bas
          adaptiveAlpha = cfg.emaAlphaLocked;
        } else {
          // Encore dans le délai → garder EMA normal (SEARCH)
          adaptiveAlpha = 0.5;
        }
      } else {
        // SEARCH ou autre → reset timer et utiliser EMA normal
        _lockStartTime = null;
        adaptiveAlpha = 0.5;
      }

      if (kDspVerboseLogs) {
        final lockTime = _lockStartTime != null 
            ? DateTime.now().difference(_lockStartTime!).inMilliseconds 
            : 0;
        debugPrint(
            '📊 EMA: α=${adaptiveAlpha.toStringAsFixed(3)} (state=$trackerState, lockTime=${lockTime}ms)');
      }

      if (_prevLinear != null && _prevLinear!.length == mag.length) {
        if (cfg.averagingDomain == AveragingDomain.linear) {
          emaLinearInPlace(_prevLinear!, mag, adaptiveAlpha);
        } else {
          final curDb = Float32List(mag.length);
          final prevDb = Float32List(mag.length);
          for (int i = 0; i < mag.length; i++) {
            curDb[i] = 10 * math.log(mag[i] + 1e-20) / math.ln10;
            prevDb[i] = 10 * math.log(_prevLinear![i] + 1e-20) / math.ln10;
          }
          for (int i = 0; i < mag.length; i++) {
            prevDb[i] =
                adaptiveAlpha * curDb[i] + (1 - adaptiveAlpha) * prevDb[i];
            _prevLinear![i] = math.pow(10, prevDb[i] / 10.0).toDouble();
          }
        }
        mag = _prevLinear!;
      }

      // Optional light FIR smoothing for visual trace
      if (cfg.firSmoothing) {
        _applyFirSmoothing(mag);
      }

      onFrame(SpectroidFrame(
        mag,
        peakFreq,
        peakDb,
        _effectiveFs,
        frameUnit,
        cfg.spectroidMode,
        _audioStatus,
        f0Yin,
        confYin,
        f0Harm,
        confHarm,
        f0Fused,
        confFused,
        fTracked,
        trackerState,
        debugPeaks,
        predictedF0,
        lockReason,
        currentWindow,
        localNoiseFloorDb,
      ));
    });
  }

  void _applyGuidanceBias(
    Float32List spectrumDb, {
    required double binWidth,
    required List<double> targetsHz,
    required double windowCents,
    required double biasDb,
  }) {
    if (targetsHz.isEmpty || biasDb <= 0) return;
    final int n = spectrumDb.length;
    for (final ft in targetsHz) {
      if (!ft.isFinite || ft <= 0) continue;
      // Convert cents window to frequency bounds
      final ratio = math.pow(2.0, windowCents / 1200.0);
      final fLow = ft / ratio;
      final fHigh = ft * ratio;
      int iLow = (fLow / binWidth).floor();
      int iHigh = (fHigh / binWidth).ceil();
      iLow = iLow.clamp(1, n - 2);
      iHigh = iHigh.clamp(1, n - 2);
      if (iHigh <= iLow) continue;
      // Apply a triangular bias peaking at ft with height biasDb
      for (int i = iLow; i <= iHigh; i++) {
        final f = i * binWidth;
        final cents = (1200.0 * (math.log(f / ft) / math.ln2)).abs();
        final w = (1.0 - (cents / windowCents)).clamp(0.0, 1.0);
        final add = biasDb * w;
        spectrumDb[i] += add.toDouble();
      }
    }
  }

  void _setupPostDecimHpf(LowFreqHighPass sel) {
    // First-order HPF: y[n] = a*y[n-1] + x[n] - x[n-1]
    // Choose pole to approximate cutoff at effective Fs
    double fc;
    switch (sel) {
      case LowFreqHighPass.off:
        _hpfAlpha = 0.0;
        _hpfX1 = 0.0;
        _hpfY1 = 0.0;
        return;
      case LowFreqHighPass.hz0p5:
        fc = 0.5;
        break;
      case LowFreqHighPass.hz1:
        fc = 1.0;
        break;
      case LowFreqHighPass.hz5:
        fc = 5.0;
        break;
      case LowFreqHighPass.hz10:
        fc = 10.0;
        break;
    }
    final dt = 1.0 / _effectiveFs;
    final rc = 1.0 / (2 * math.pi * fc);
    final alpha = rc / (rc + dt);
    _hpfAlpha = alpha;
    _hpfX1 = 0.0;
    _hpfY1 = 0.0;
  }

  /// Apply simple FIR smoothing filter (Spectroid-style)
  void _applyFirSmoothing(Float32List data) {
    // Simple 5-tap FIR filter: [0.1, 0.2, 0.4, 0.2, 0.1]
    const coeffs = [0.1, 0.2, 0.4, 0.2, 0.1];
    final filtered = Float32List(data.length);

    for (int i = 0; i < data.length; i++) {
      double sum = 0.0;
      for (int j = 0; j < coeffs.length; j++) {
        final idx = (i + j - 2).clamp(0, data.length - 1);
        sum += coeffs[j] * data[idx];
      }
      filtered[i] = sum;
    }

    // Copy back
    for (int i = 0; i < data.length; i++) {
      data[i] = filtered[i];
    }
  }

  Future<void> _configureUnprocessedAudio() async {
    // Platform-specific configuration for UNPROCESSED audio source
    // This is a placeholder - actual implementation would depend on platform channels
    if (kDspVerboseLogs) {
      debugPrint('Configuring UNPROCESSED audio source');
    }
    // Throw exception if not supported to trigger fallback
    // throw UnsupportedError('UNPROCESSED source not available on this device');
  }

  // --- Harm hint anti-octave helper logic ---
  double _correctHarmonicHintOctave(
      double f, Float32List spectrumDb, double binWidth) {
    if (!(f.isFinite) || f <= 0) return f;
    double getDbAt(double freq) {
      if (!freq.isFinite || freq <= 0) return -120.0;
      final bin = freq / binWidth;
      final lo = bin.floor();
      final hi = bin.ceil();
      if (lo < 1 || hi >= spectrumDb.length - 1) return -120.0;
      double maxDb = -120.0;
      for (int b = lo; b <= hi; b++) {
        if ((b - bin).abs() <= 0.4) {
          maxDb = math.max(maxDb, spectrumDb[b]);
        }
      }
      return maxDb;
    }

    final dbF = getDbAt(f);
    // Try /3 first (common when 3rd harmonic dominates):
    final f3 = f / 3.0;
    final dbF3 = getDbAt(f3);
    final db2F3 = getDbAt(2 * f3); // ~ 2/3 f
    // Criteria: sub at f/3 present and its 2nd harmonic (~2f/3) also present
    if (dbF3 > -110.0 && (dbF - dbF3) <= 10.0 && (dbF - db2F3) <= 12.0) {
      return f3;
    }
    // Try /2 if /3 didn't trigger
    final f2 = f / 2.0;
    final dbF2 = getDbAt(f2);
    final db3F2 = getDbAt(1.5 * f); // 3*(f/2) = 1.5f
    if (dbF2 > -110.0 && (dbF - dbF2) <= 8.0 && (dbF - db3F2) <= 14.0) {
      return f2;
    }
    return f;
  }

  Future<void> _disableAudioEffects() async {
    try {
      // Platform-specific audio effects disabling
      // This would typically use platform channels to disable:
      // - Automatic Gain Control (AGC)
      // - Noise Suppression (NS)
      // - Acoustic Echo Cancellation (AEC)

      _audioStatus = _audioStatus.copyWith(
        agcAvailable: true,
        agcEnabled: false,
        nsAvailable: true,
        nsEnabled: false,
        aecAvailable: true,
        aecEnabled: false,
        deviceInfo: 'Effects disabled via RecordConfig',
      );
      if (kDspVerboseLogs) {
        debugPrint(
            'Audio effects disabled: AGC=${_audioStatus.agcDisabled}, NS=${_audioStatus.nsDisabled}, AEC=${_audioStatus.aecDisabled}');
      }
    } catch (e) {
      if (kDspVerboseLogs) {
        debugPrint('Failed to disable audio effects: $e');
      }
      _audioStatus = _audioStatus.copyWith(
        agcEnabled: true,
        nsEnabled: true,
        aecEnabled: true,
      );
    }
  }

  /// Pre-emphasis filter pour améliorer SNR avant YIN
  Float32List _applyPreEmphasis(Float32List frame) {
    final result = Float32List(frame.length);
    result[0] = frame[0];
    const alpha = 0.97; // Coefficient de pre-emphasis

    for (int i = 1; i < frame.length; i++) {
      result[i] = frame[i] - alpha * frame[i - 1];
    }
    return result;
  }

  /// Calcul RMS pour estimation noise floor
  double _calculateRMS(Float32List frame) {
    double sum = 0.0;
    for (int i = 0; i < frame.length; i++) {
      sum += frame[i] * frame[i];
    }
    return math.sqrt(sum / frame.length);
  }

  Future<void> stop() async {
    _scheduler?.cancel();
    _scheduler = null;
    await _sub?.cancel();
    _sub = null;
    if (await _rec.isRecording()) {
      await _rec.stop();
    }
    _audioDsp = null;
    // Reset tracker autonome hints
    _lastValidYin = null;
    _lastValidHarm = null;
  }

  /// Interpoler les valeurs NaN (zones de pics) avec interpolation linéaire
}
