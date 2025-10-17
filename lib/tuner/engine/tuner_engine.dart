import 'dart:async';
import 'dart:math' as math;

import '../core/decimator.dart';
import '../core/fft.dart';
import '../core/filters.dart';
import '../core/ring_buffer.dart';
import '../pitch/detectors.dart';
import '../pitch/tracker.dart';
import 'audio_capture.dart';
import '../ai/ai_pitch_base.dart';
import '../ai/tflite_ai.dart';

class TunerSettings {
  const TunerSettings({
    this.decimationLevels = 2, // Back to 2 for performance (fs_eff = 12kHz)
    this.fftSize = 2048, // Reduced for mobile performance
    this.hann = true,
    this.dcBlockEnabled = true,
    this.notchEnabled = false,
    this.notchFreq = 50.0,
    this.emaMs = 100.0, // Faster smoothing for responsiveness
    // YIN
    this.yinWindow = 2048, // Match FFT size
    this.fMin = 55.0,
    this.fMax = 1100.0,
    this.yinThreshold = 0.10, // Lower for better sensitivity
    // Harmonic
    this.harmonics = 5, // More harmonics for better fundamental detection
    this.toleranceCents = 25, // More tolerant
    // Fusion
    this.wYin = 0.25, // Increase YIN weight (no AI model loaded)
    this.wHarm = 0.60, // Increase Harmonic weight (main detector)
    // AI
    this.aiEnabled = false,
    this.aiAssetPath = 'assets/models/crepe-lite.tflite',
    // Tracker/Shield
    this.tracker = const TrackerConfig(),
  });

  final int decimationLevels; // 0..9
  final int fftSize; // power of 2
  final bool hann;
  final bool dcBlockEnabled;
  final bool notchEnabled;
  final double notchFreq; // 50 or 60
  final double emaMs;
  final int yinWindow;
  final double fMin;
  final double fMax;
  final double yinThreshold;
  final int harmonics;
  final double toleranceCents;
  final double wYin;
  final double wHarm;
  final bool aiEnabled;
  final String aiAssetPath;
  final TrackerConfig tracker;

  TunerSettings copyWith({
    int? decimationLevels,
    int? fftSize,
    bool? hann,
    bool? dcBlockEnabled,
    bool? notchEnabled,
    double? notchFreq,
    double? emaMs,
    int? yinWindow,
    double? fMin,
    double? fMax,
    double? yinThreshold,
    int? harmonics,
    double? toleranceCents,
    double? wYin,
    double? wHarm,
    bool? aiEnabled,
    String? aiAssetPath,
    TrackerConfig? tracker,
  }) {
    return TunerSettings(
      decimationLevels: decimationLevels ?? this.decimationLevels,
      fftSize: fftSize ?? this.fftSize,
      hann: hann ?? this.hann,
      dcBlockEnabled: dcBlockEnabled ?? this.dcBlockEnabled,
      notchEnabled: notchEnabled ?? this.notchEnabled,
      notchFreq: notchFreq ?? this.notchFreq,
      emaMs: emaMs ?? this.emaMs,
      yinWindow: yinWindow ?? this.yinWindow,
      fMin: fMin ?? this.fMin,
      fMax: fMax ?? this.fMax,
      yinThreshold: yinThreshold ?? this.yinThreshold,
      harmonics: harmonics ?? this.harmonics,
      toleranceCents: toleranceCents ?? this.toleranceCents,
      wYin: wYin ?? this.wYin,
      wHarm: wHarm ?? this.wHarm,
      aiEnabled: aiEnabled ?? this.aiEnabled,
      aiAssetPath: aiAssetPath ?? this.aiAssetPath,
      tracker: tracker ?? this.tracker,
    );
  }
}

class TunerState {
  const TunerState({
    required this.f0,
    required this.state,
    required this.cents,
    required this.snrDb,
    required this.spectralFlux,
    required this.spectralFlatnessDb,
    required this.yinConfidence,
    required this.harmScore,
    required this.psd,
    required this.freqs,
    required this.isTransient,
  });
  final double? f0;
  final TrackState state;
  final double cents;
  final double snrDb;
  final double spectralFlux;
  final double spectralFlatnessDb;
  final double yinConfidence;
  final double harmScore;
  final List<double> psd; // dB/Hz
  final List<double> freqs;
  final bool isTransient;
}

class TunerEngine {
  TunerEngine(
      {required this.capture,
      required TunerSettings settings,
      AIPitchModel? ai})
      : _settings = settings,
        _ring = FloatRingBuffer(1 << 16),
        _tracker = PitchTracker(settings.tracker),
        _ai = ai ?? NoOpAIPitchModel() {
    _hann = settings.hann
        ? HannWindow.generate(settings.fftSize)
        : List<double>.filled(settings.fftSize, 1.0);
    _ema = Ema(settings.emaMs, _fs.toDouble(), settings.fftSize);
    _decimator = MultiRateDecimator(levels: settings.decimationLevels);
    _dc = DcBlocker();
    _notch = NotchIir(fs: _fs.toDouble(), f0: settings.notchFreq);
  }

  final AudioCaptureService capture;
  TunerSettings _settings;
  final FloatRingBuffer _ring;
  late final List<double> _hann;
  late final Ema _ema;
  late final MultiRateDecimator _decimator;
  late final DcBlocker _dc;
  late final NotchIir _notch;
  final PitchTracker _tracker;
  late AIPitchModel _ai;
  final _controller = StreamController<TunerState>.broadcast();
  int _fs = 48000;
  double? _prevF0;
  final List<double> _lastCents = [];
  int _samplesSinceLastHop = 0;
  int get _hopSamples =>
      (_fs * 0.010).round(); // 10ms hop at current sample rate

  Stream<TunerState> get stream => _controller.stream;
  TunerSettings get settings => _settings;

  Future<void> start() async {
    // Initialize AI according to settings
    _ai = _settings.aiEnabled
        ? TfliteAIPitchModel(assetPath: _settings.aiAssetPath)
        : NoOpAIPitchModel();
    await _ai.load();
    await capture.start((samples, sampleRate) {
      _fs = sampleRate;
      // Pre-filtering
      if (_settings.dcBlockEnabled) _dc.processInPlace(samples);
      if (_settings.notchEnabled) _notch.processInPlace(samples);
      _ring.writeSamples(samples);

      // Track samples for hop-based processing
      _samplesSinceLastHop += samples.length;
      if (_samplesSinceLastHop >= _hopSamples) {
        _processIfReady();
        _samplesSinceLastHop = 0;
      }
    });
  }

  Future<void> stop() async {
    await capture.stop();
    await _controller.close();
  }

  void updateSettings(TunerSettings next) {
    _settings = next;
    _hann = next.hann
        ? HannWindow.generate(next.fftSize)
        : List<double>.filled(next.fftSize, 1.0);
    _ema = Ema(next.emaMs, _fs.toDouble(), next.fftSize);
    _decimator = MultiRateDecimator(levels: next.decimationLevels);
    _notch = NotchIir(fs: _fs.toDouble(), f0: next.notchFreq);
    // AI toggle can change at runtime; reinitialize model lazily on next start or now if desired.
    // For simplicity, we re-create the model immediately.
    _ai.dispose();
    _ai = next.aiEnabled
        ? TfliteAIPitchModel(assetPath: next.aiAssetPath)
        : NoOpAIPitchModel();
    _ai.load();
  }

  Future<void> _processIfReady() async {
    // No more time-based throttling; rely on hop-based scheduling from capture callback
    final n = _settings.fftSize;
    final frame = List<double>.filled(n, 0.0);
    _ring.readLast(n, frame);
    // Decimation multi-rate
    final (decimated, factor) = _decimator.process(frame);
    final fsEff = _fs ~/ factor;
    final frameUse =
        decimated.length >= n ? decimated.sublist(0, n) : _pad(decimated, n);

    // PSD
    final psd = computePsd(frame: frameUse, hann: _hann, fs: fsEff.toDouble());
    final powerSmoothed = _ema.apply(psd.power);
    final dbHz = <double>[];
    for (final p in powerSmoothed) {
      final v = p <= 0 ? -300.0 : 10 * math.log(p) / math.log(10);
      dbHz.add(v);
    }

    // Features: SNR, spectral flux, flatness, harmonicity proxy.
    final snr = _estimateSnr(psd.power);
    final flux = _spectralFlux(psd.power);
    final flat = _spectralFlatnessDb(psd.power);

    // YIN on time-domain decimated frame
    final yinRes = yinDetect(
        frameUse,
        fsEff.toDouble(),
        YinConfig(
          windowSize: math.min(_settings.yinWindow, frameUse.length),
          fMin: _settings.fMin,
          fMax: _settings.fMax,
          threshold: _settings.yinThreshold,
        ));
    final harmRes = harmonicDetect(
      freqs: psd.freqsHz,
      power: powerSmoothed,
      cfg: HarmonicConfig(
        harmonics: _settings.harmonics,
        toleranceCents: _settings.toleranceCents,
        fMin: _settings.fMin,
        fMax: _settings.fMax,
      ),
    );
    // AI candidate (if available) + advanced fusion with SNR/octave penalties
    final aiRes = await _maybeAI(frameUse, fsEff);
    final fusion = fusePitchAdvanced(
      yin: yinRes,
      harm: harmRes,
      cfg: FusionConfig(wYin: _settings.wYin, wHarm: _settings.wHarm),
      snrDb: snr,
      f0Ai: aiRes.f0,
      aiConf: aiRes.confidence,
      f0Prev: _prevF0,
    );

    // Median-of-3 smoothing in cents before tracking to damp small jitter
    final f0ForTrack = _median3Smoothed(fusion.f0);

    final tr = _tracker.update(
      dtMs: 1000.0 * n / fsEff,
      f0Candidate: f0ForTrack,
      fusionScore: fusion.score,
      snrDb: snr,
      harmonicity: _harmonicity(powerSmoothed),
      rmsDb: _rmsDb(frameUse),
      spectralFlux: flux,
      spectralFlatnessDb: flat,
    );

    _controller.add(TunerState(
      f0: tr.f0,
      state: tr.state,
      cents: tr.centsError,
      snrDb: snr,
      spectralFlux: flux,
      spectralFlatnessDb: flat,
      yinConfidence: yinRes.confidence,
      harmScore: harmRes.score,
      psd: dbHz,
      freqs: psd.freqsHz,
      isTransient: tr.isTransient,
    ));
    if (tr.f0 != null) {
      _prevF0 = tr.f0;
    }
  }

  Future<AIPitchResult> _maybeAI(List<double> frame, int fs) async {
    try {
      return _ai.infer(frame: frame, sampleRate: fs);
    } catch (_) {
      return const AIPitchResult(f0: null, confidence: 0.0);
    }
  }

  static List<double> _pad(List<double> x, int n) {
    final out = List<double>.filled(n, 0.0);
    for (var i = 0; i < x.length && i < n; i++) {
      out[i] = x[i];
    }
    return out;
  }

  static double _rmsDb(List<double> x) {
    double s2 = 0.0;
    for (final v in x) {
      s2 += v * v;
    }
    final rms = math.sqrt(s2 / math.max(1, x.length));
    return 20 * math.log(rms + 1e-12) / math.log(10);
  }

  static double _estimateSnr(List<double> power) {
    // crude: peak vs median
    double peak = -1e12;
    final tmp = <double>[];
    for (final p in power) {
      peak = math.max(peak, p);
      if (p > 0) tmp.add(p);
    }
    tmp.sort();
    final med = tmp.isEmpty ? 1e-12 : tmp[tmp.length ~/ 2];
    final snr = 10 * math.log((peak + 1e-12) / (med + 1e-12)) / math.log(10);
    return snr;
  }

  static double _spectralFlux(List<double> power) {
    // Difference with one-frame memory.
    _prev ??= List<double>.from(power);
    double sum = 0.0;
    for (var i = 0; i < power.length; i++) {
      final d = (power[i] - _prev![i]);
      if (d > 0) {
        sum += d;
      }
      _prev![i] = power[i];
    }
    return sum; // unnormalized, relative measure
  }

  static List<double>? _prev;

  double? _median3Smoothed(double? f0) {
    if (f0 == null) return null;
    // Convert to cents relative to A4=440 for numerical stability
    final cents = 1200.0 * (math.log(f0 / 440.0) / math.ln2);
    _lastCents.add(cents);
    if (_lastCents.length > 3) _lastCents.removeAt(0);
    final sorted = List<double>.from(_lastCents)..sort();
    final median = sorted[sorted.length ~/ 2];
    // Convert back to Hz
    return 440.0 * math.exp((median / 1200.0) * math.ln2);
  }

  static double _spectralFlatnessDb(List<double> power) {
    double gmeanLog = 0.0;
    double asum = 0.0;
    var count = 0;
    for (final p in power) {
      if (p <= 0) continue;
      gmeanLog += math.log(p);
      asum += p;
      count++;
    }
    if (count == 0) return 0.0;
    gmeanLog /= count;
    final gmean = math.exp(gmeanLog);
    final amean = asum / count;
    return 10 * math.log((gmean + 1e-12) / (amean + 1e-12)) / math.log(10);
  }

  static double _harmonicity(List<double> power) {
    // Ratio of sum of top K peaks to total energy as a simple proxy.
    const k = 5;
    final sorted = List<double>.from(power)..sort((a, b) => b.compareTo(a));
    double top = 0.0;
    for (var i = 0; i < sorted.length && i < k; i++) {
      top += sorted[i];
    }
    double total = 0.0;
    for (final p in power) {
      total += p;
    }
    if (total <= 0) return 0.0;
    return (top / total).clamp(0.0, 1.0);
  }
}
