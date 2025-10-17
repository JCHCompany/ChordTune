import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../research/spectroid/windows_fft.dart' show makeWindow, fftInPlace;
import '../research/spectroid/spectroid_config.dart' show DcFilterType, NotchFilter, LowFreqHighPass, SpectroidWindow;
import '../research/spectroid/audio_dsp.dart';
import '../../dsp/yin.dart' as yin_dsp;

import 'guided_tuner_config.dart';

class GuidedTunerEngine {
  final AudioRecorder _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  Timer? _timer;

  // Analysis
  Float32List? _window;
  late Float32List _ring;
  int _writeIdx = 0;
  bool _filled = false;
  int _effectiveFs = 48000;
  // No decimator used in isolated pipeline to keep latency low
  AudioDSP? _audioDsp;

  // Gating state
  // prev RMS not needed beyond gating threshold calculation
  Float32List? _prevPsd; // for spectral flux

  // YIN backup
  // Optional YIN backup (declared but only used locally when needed)

  // α-β tracker state
  double _posCents = 0.0;
  double _velCentsPerS = 0.0;
  // Tracking timers/state
  int _lockTimer = 0;
  int _unlockTimer = 0;
  GuidedTrackerState _state = GuidedTrackerState.search;

  // Helpers
  static double _hzToCents(double f, double fref) => 1200.0 * (math.log(f / fref) / math.ln2);
  // static double _centsToHz(double cents, double fref) => fref * math.pow(2.0, cents / 1200.0);

  Future<void> start({
    required GuidedTunerConfig cfg,
    required void Function(GuidedTunerFrame) onFrame,
    DcFilterType dcFilter = DcFilterType.iir,
    NotchFilter notch = NotchFilter.none,
    LowFreqHighPass hpf = LowFreqHighPass.hz1,
  }) async {
    if (await _rec.isRecording()) {
      await _rec.stop();
    }

    // Setup DSP
    _window = makeWindow(cfg.fftSize, _toWindow(cfg.window));
    _audioDsp = AudioDSP(sampleRate: cfg.sampleRate.toDouble(), dcFilterType: dcFilter, notchFilter: notch);
    _effectiveFs = cfg.sampleRate;
    _ring = Float32List(_effectiveFs * 2);
    _writeIdx = 0; _filled = false;

  final yin = yin_dsp.YinDetector(sampleRate: _effectiveFs, windowSize: math.min(384, cfg.fftSize), hopSize: 48, threshold: 0.10);

    // Audio stream
    final stream = await _rec.startStream(RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      numChannels: 1,
      sampleRate: cfg.sampleRate,
      echoCancel: false, noiseSuppress: false, autoGain: false,
    ));

    _sub = stream.listen((bytes) {
      for (int i = 0; i + 1 < bytes.length; i += 2) {
        final lo = bytes[i];
        final hi = bytes[i + 1];
        int s = (hi << 8) | lo; if (s & 0x8000 != 0) s -= 0x10000;
        double x = s / 32768.0;
        if (_audioDsp != null) x = _audioDsp!.process(x);
        // No decimation applied here (kept isolated)
        _ring[_writeIdx++] = x;
        if (_writeIdx >= _ring.length) { _writeIdx = 0; _filled = true; }
      }
    });

    final hop = (cfg.fftSize * (1 - cfg.overlap)).clamp(1, cfg.fftSize).toInt();
    final hopMs = (1000 * hop / _effectiveFs).clamp(5, 100).toInt();
    _timer?.cancel();
    _timer = Timer.periodic(Duration(milliseconds: hopMs), (_) {
      if (_window == null) return;
      if (!_filled && _writeIdx < cfg.fftSize) return;

  final frame = _copyLatest(cfg.fftSize);
      final rmsDb = _rmsDbfs(frame);
      final psd = _psdPerHz(frame, _window!, _effectiveFs);

      final flux = _spectralFlux(psd);
      final flat = _spectralFlatness(psd);

      // Gating: only estimate if passing all gates
      final gated = rmsDb >= cfg.gatingRmsDbfs && flux <= cfg.maxSpectralFlux && flat <= cfg.maxSpectralFlatness;

      final targets = cfg.stringTargetsHz();
      double f0 = gated ? _estimateF0(psd, _effectiveFs, targets, cfg) : 0.0;
      // Optional YIN validation/backup if gated and HSS fails
      if (gated && (f0 <= 0.0 || !f0.isFinite)) {
        final yr = yin.process(frame);
        if (yr.f0.isFinite && yr.f0 > 15 && yr.f0 < 4000) {
          f0 = yr.f0;
        }
      }

      final frameOut = _trackAndBuildFrame(f0, targets, cfg, rmsDb, flux, flat);
      onFrame(frameOut);
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _sub?.cancel();
    _sub = null;
    if (await _rec.isRecording()) {
      await _rec.stop();
    }
  }

  // ===== Helpers =====
  Float32List _copyLatest(int n) {
    final out = Float32List(n);
    int start = _writeIdx - n; if (start < 0) start += _ring.length;
    for (int i = 0; i < n; i++) {
      int idx = start + i; if (idx >= _ring.length) idx -= _ring.length;
      out[i] = _ring[idx];
    }
    return out;
  }

  double _rmsDbfs(Float32List x) {
    double acc = 0.0; for (final v in x) acc += v * v; final rms = math.sqrt(acc / x.length);
    return 20 * math.log(rms + 1e-12) / math.ln10;
  }

  Float32List _psdPerHz(Float32List frame, Float32List window, int fs) {
    final n = frame.length;
    final re = Float32List(n), im = Float32List(n);
  double sumW2 = 0.0;
  for (int i = 0; i < n; i++) { final w = window[i]; sumW2 += w * w; re[i] = frame[i] * w; }
  final U = sumW2 / n;
    fftInPlace(re, im);
    final out = Float32List(n >> 1);
    final invDen = (fs * n * U) > 0 ? 1.0 / (fs * n * U) : 0.0;
    for (int k = 0; k < out.length; k++) {
      final mag2 = re[k] * re[k] + im[k] * im[k];
      final factor = (k == 0) ? 1.0 : 2.0; // one-sided
      out[k] = (factor * mag2 * invDen).toDouble();
    }
    return out;
  }

  double _spectralFlux(Float32List cur) {
    if (_prevPsd == null || _prevPsd!.length != cur.length) {
      _prevPsd = Float32List.fromList(cur);
      return 0.0;
    }
    double flux = 0.0;
    for (int i = 0; i < cur.length; i++) {
      final d = cur[i] - _prevPsd![i];
      if (d > 0) flux += d;
    }
    _prevPsd = Float32List.fromList(cur);
    return flux / cur.length;
  }

  double _spectralFlatness(Float32List psd) {
    double sumLog = 0.0, sumLin = 0.0; const eps = 1e-20;
    for (final v in psd) { final x = v + eps; sumLog += math.log(x); sumLin += x; }
    final geo = math.exp(sumLog / psd.length);
    final ari = sumLin / psd.length;
    return (ari > 0) ? (geo / ari) : 1.0; // 0 tonal → 1 bruit
  }

  double _estimateF0(Float32List psd, int fs, List<double> targets, GuidedTunerConfig cfg) {
    final binHz = fs / (psd.length * 2);

    // Find peaks (simple local maxima)
    final peaks = <int>[];
    for (int i = 2; i < psd.length - 2; i++) {
      final v = psd[i];
      if (v > psd[i - 1] && v > psd[i + 1] && v > psd[i - 2] && v > psd[i + 2]) {
        peaks.add(i);
      }
    }

    double bestF0 = 0.0;
    double bestScore = -1e9;

    // Candidate set guided by tuning
    for (int s = 0; s < targets.length; s++) {
      final target = targets[s];
      final lo = target / math.pow(2.0, cfg.candidateWindowCents / 1200.0);
      final hi = target * math.pow(2.0, cfg.candidateWindowCents / 1200.0);

      // Evaluate comb gain around candidate target
      for (final pk in peaks) {
        final f = pk * binHz;
        if (f < lo || f > hi) continue;

        final (comb, snrDb) = _combGainAndSnr(psd, f, binHz, cfg);
        // Fundamental rescue: check f/2 if 2f dominates
        final (comb2, snrDb2) = _combGainAndSnr(psd, f * 0.5, binHz, cfg);
        final score = math.max(comb, comb2) * math.max(snrDb, snrDb2);
        if (score > bestScore) { bestScore = score; bestF0 = (comb2 > comb) ? f * 0.5 : f; }
      }
    }
    return bestF0;
  }

  (double,double) _combGainAndSnr(Float32List psd, double f0, double binHz, GuidedTunerConfig cfg) {
    if (!(f0.isFinite) || f0 <= 0) return (0.0, -120.0);
    double gain = 0.0;
    double peakDb = -1e9;
    final eps = 1e-20;
    for (int h = 1; h <= cfg.maxHarmonics; h++) {
      final fh = h * f0;
      final idx = (fh / binHz).round();
      if (idx <= 0 || idx >= psd.length) break;
      // tolerance window in bins
      final tolHz = cfg.tolCents * (fh / 1200.0) * math.log(2) / math.ln10; // approx, simple
      final span = math.max(1, (tolHz / binHz).round());
      double best = 0.0;
      for (int k = math.max(1, idx - span); k <= math.min(psd.length - 1, idx + span); k++) {
        if (psd[k] > best) best = psd[k];
      }
      final w = math.pow(cfg.weightDecay, (h - 1)).toDouble();
      gain += w * best;
      peakDb = math.max(peakDb, 10 * math.log(best + eps) / math.ln10);
    }

    // local noise: median in ±8 bins excluding ±2 around f0
    final center = (f0 / binHz).round();
    final vals = <double>[];
    for (int k = math.max(1, center - 8); k <= math.min(psd.length - 2, center + 8); k++) {
      if ((k - center).abs() <= 2) continue;
      vals.add(psd[k]);
    }
    double noiseDb = -120.0;
    if (vals.isNotEmpty) {
      vals.sort();
      final med = vals[vals.length ~/ 2];
      noiseDb = 10 * math.log(med + 1e-20) / math.ln10;
    }
    final snrDb = peakDb - noiseDb;
    return (gain, snrDb);
  }

  GuidedTunerFrame _trackAndBuildFrame(double f0, List<double> targets, GuidedTunerConfig cfg, double rmsDb, double flux, double flat) {
    final dtMs = (1000 * cfg.fftSize * (1 - cfg.overlap) / _effectiveFs).toInt();

    // Decision and tracking
    if (f0 > 0) {
      // α-β update: measure in cents relative to closest target
      final (closestIdx, closestF, centsErr) = _closestTarget(f0, targets);
      _alphaBetaUpdate(centsErr.toDouble(), dtMs);

      // Hysteresis by SNR is embedded in estimation; here we do time-based lock
      if (_state == GuidedTrackerState.search) {
        _lockTimer += dtMs;
        _unlockTimer = 0;
        if (_lockTimer >= cfg.holdInMs) {
          _state = GuidedTrackerState.locked;
        }
      } else {
        _unlockTimer = 0;
        _lockTimer += dtMs; // maintain
      }

      return GuidedTunerFrame(
        f0Hz: f0,
        state: _state,
        stringIndex: closestIdx,
        noteName: _noteName(closestF),
        targetFreqHz: closestF,
        centOffset: centsErr,
        rmsDbfs: rmsDb,
        spectralFlux: flux,
        spectralFlatness: flat,
      );
    } else {
      // No estimate → progress unlock timer
      _lockTimer = 0;
      if (_state == GuidedTrackerState.locked) {
        _unlockTimer += dtMs;
        if (_unlockTimer >= cfg.holdOutMs) {
          _state = GuidedTrackerState.search;
        }
      }
      return GuidedTunerFrame(
        f0Hz: 0.0,
        state: _state,
        stringIndex: null,
        noteName: null,
        targetFreqHz: null,
        centOffset: null,
        rmsDbfs: rmsDb,
        spectralFlux: flux,
        spectralFlatness: flat,
      );
    }
  }

  void _alphaBetaUpdate(double measuredCents, int dtMs) {
    final dt = math.max(1e-3, dtMs / 1000.0);
    final predicted = _posCents + _velCentsPerS * dt;
    final residual = measuredCents - predicted;
    const alpha = 0.5; // position gain
    const beta = 0.3;  // velocity gain
    _posCents = predicted + alpha * residual;
    _velCentsPerS = _velCentsPerS + (beta * residual) / dt;
  }

  (int,double,double) _closestTarget(double f0, List<double> targets) {
    int idx = 0; double bestF = targets[0]; double bestC = double.infinity;
    for (int i = 0; i < targets.length; i++) {
      final c = _hzToCents(f0, targets[i]).abs();
      if (c < bestC) { bestC = c; bestF = targets[i]; idx = i; }
    }
    final signedCents = _hzToCents(f0, bestF);
    return (idx, bestF, signedCents);
  }

  String _noteName(double f) {
    // A4 = 440 Hz reference
    final n = (12 * (math.log(f / 440.0) / math.ln2)).round();
    const names = ['C','C#','D','D#','E','F','F#','G','G#','A','A#','B'];
    int note = (n + 9) % 12; // because 440=A
    int octave = 4 + ((n + 9) / 12).floor();
    return '${names[note]}$octave';
  }

  static SpectroidWindow _toWindow(GuidedWindow w) {
    switch (w) { case GuidedWindow.hann: return SpectroidWindow.hann; }
  }
}
