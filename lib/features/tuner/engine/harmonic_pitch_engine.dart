import 'dart:async';
import 'dart:math' as math;
import 'package:record/record.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart' as onnx;
import 'package:flutter/foundation.dart';

import 'pitch_engine_interface.dart';
import '../core/dsp/autocorrelation.dart' show PitchEstimate;

/// Modes expérimentaux pour le pipeline harmonique
enum HarmonicExperimentMode { optionA, optionB }

class HarmonicPitchEngine implements PitchEngine {
  final int sampleRate;
  final int frameSize;
  final int hopSize;
  final String? modelAsset;
  final HarmonicExperimentMode mode;
  final bool debug;

  final _controller = StreamController<PitchFrame>.broadcast();
  StreamSubscription<Uint8List>? _sub;
  final AudioRecorder _recorder = AudioRecorder();
  bool _running = false;
  dynamic _onnxSession;

  // Buffer pour accumulation des échantillons
  final List<int> _pcmBuffer = <int>[];

  // Mémoire pour Option A (octave protection)
  double? _prevF0;
  double _prevConf = 0.0;
  int _octaveBlockCount = 0;
  double _prevRms = 0.0;

  HarmonicPitchEngine({
    this.sampleRate = 16000,
    this.frameSize = 2560,
    this.hopSize = 1280,
    this.modelAsset,
    this.mode = HarmonicExperimentMode.optionA,
    this.debug = true,
  });

  @override
  Stream<PitchFrame> get frames => _controller.stream;

  @override
  bool get isRunning => _running;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    await _initBackend();
    if (debug) {
      debugPrint('HarmonicPitchEngine START: mode=$mode, modelAsset=${modelAsset ?? "<none>"}, onnxSession=${_onnxSession != null}');
    }
    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        numChannels: 1,
        sampleRate: sampleRate,
        bitRate: 128000,
        // Disable platform voice processing where supported
        echoCancel: false,
        noiseSuppress: false,
        autoGain: false,
      ),
    );
    _sub = stream.listen((chunk) async {
      if (!_running) return;
      
      // Accumulation des échantillons PCM pour former des frames complètes
      _pcmBuffer.addAll(chunk);
      final bytesPerSample = 2;
      final needBytes = frameSize * bytesPerSample;
      final hopBytes = hopSize * bytesPerSample;
      
      if (debug && DateTime.now().millisecondsSinceEpoch % 2000 < 100) {
        debugPrint('HarmonicPitchEngine: buffer=${_pcmBuffer.length} bytes, need=$needBytes, chunk=${chunk.length}');
      }
      
      while (_pcmBuffer.length >= needBytes) {
        final frameBytes = _pcmBuffer.sublist(0, needBytes);
        _pcmBuffer.removeRange(0, hopBytes > _pcmBuffer.length ? _pcmBuffer.length : hopBytes);
        
        var samples = _i16LeToDoubles(frameBytes);
        samples = _preprocess(samples);
        
        if (mode == HarmonicExperimentMode.optionB) {
          samples = await _harmonicWeighting(samples);
        }
        
        if (debug) {
          debugPrint('HarmonicPitchEngine: Processing frame with ${samples.length} samples, session=${_onnxSession != null}');
        }
        
        final est = await _infer(samples);
        PitchEstimate? finalEst = est;
        
        if (mode == HarmonicExperimentMode.optionA && est != null) {
          finalEst = await _harmonicVerification(samples, est);
        }
        
        // Toujours émettre une frame (même si confidence faible) pour éviter l'état "Listening..."
        final outputF0 = (finalEst != null && finalEst.frequencyHz > 40.0 && finalEst.frequencyHz < 2000.0) 
            ? finalEst.frequencyHz : 0.0;
        final outputConf = (finalEst != null && finalEst.confidence > 0.3) 
            ? finalEst.confidence : 0.0;
        
        if (debug) {
          debugPrint('HarmonicPitchEngine FINAL: f0=${outputF0.toStringAsFixed(2)} conf=${outputConf.toStringAsFixed(3)} mode=$mode');
        }
        
        _controller.add(PitchFrame(
          frequencyHz: outputF0,
          confidence: outputConf,
          timestamp: DateTime.now(),
        ));
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
    if (debug) debugPrint('HarmonicPitchEngine: _initBackend() called, modelAsset=$modelAsset');
    if (modelAsset == null) {
      if (debug) debugPrint('HarmonicPitchEngine: No model asset specified, skipping ONNX init');
      return;
    }
    try {
      if (debug) debugPrint('HarmonicPitchEngine: Loading asset bytes from $modelAsset');
      final bytes = await _loadAssetBytes(modelAsset!);
      if (debug) debugPrint('HarmonicPitchEngine: Asset loaded, ${bytes.length} bytes');
      final env = onnx.OrtEnv.instance;
      final opts = onnx.OrtSessionOptions();
      _onnxSession = (onnx.OrtSession as dynamic).fromBytes(env, bytes, opts);
      if (_onnxSession is Future) {
        _onnxSession = await _onnxSession;
      }
      if (debug) debugPrint('HarmonicPitchEngine: ONNX session created successfully');
    } catch (e) {
      debugPrint('HarmonicPitchEngine: ONNX init failed: $e');
      _onnxSession = null;
    }
  }

  Future<PitchEstimate?> _infer(List<double> samples) async {
    if (_onnxSession == null) {
      // Fallback: basic pitch detection using autocorrelation when ONNX fails
      if (debug) debugPrint('HarmonicPitchEngine: Using fallback pitch detection (no ONNX)');
      return _fallbackPitchDetection(samples);
    }
    try {
      final input = Float32List.fromList(samples);
      final shape = [1, input.length];
      final tensorCreator = (onnx.OrtValueTensor as dynamic);
      final inputTensor = tensorCreator.createTensorFloat(input, shape);
      final inputs = { 'input_audio': inputTensor };
      final outputs = await (_onnxSession as dynamic).run(inputs);
      final pitch = _tensorToFloatList(outputs['pitch_hz']);
      final conf = _tensorToFloatList(outputs['confidence']);
      if (pitch.isEmpty || conf.isEmpty) return null;
      // Median
      final f0 = pitch[pitch.length ~/ 2];
      final c0 = conf[conf.length ~/ 2];
      if (debug) debugPrint('HarmonicPitchEngine ONNX OUT: f0=$f0 conf=$c0');
      return PitchEstimate(f0, c0);
    } catch (e) {
      debugPrint('HarmonicPitchEngine: ONNX infer error: $e');
      return null;
    }
  }

  // Option A: post-ONNX harmonic verification
  Future<PitchEstimate?> _harmonicVerification(List<double> samples, PitchEstimate est) async {
    final f0 = est.frequencyHz;
    final conf = est.confidence;
    final stft = _stft(samples, 4096);
    final harmonics = _harmonicEnergies(stft, f0, 5);
    final rms = _rms(samples);
    // Lissage
    final eF0 = _smoothedEnergy(harmonics, 1);
    final e2F0 = _smoothedEnergy(harmonics, 2);
    // Condition octave block
    final rmsDrop = (_prevRms > 0.0) ? (20 * math.log(rms / _prevRms) / math.ln10) : 0.0;
    final octaveDominant = (e2F0 > eF0 + 3.0);
    if (octaveDominant && rmsDrop < -6.0) {
      _octaveBlockCount++;
    } else {
      _octaveBlockCount = 0;
    }
    bool block = _octaveBlockCount >= 3 && _prevF0 != null && (conf > 0.6);
    if (block && (math.log(f0 / _prevF0!).abs() < math.log(2) * 50 / 1200)) {
      if (debug) debugPrint('octave protection active: f0=$f0 prev=$_prevF0 e2F0=$e2F0 eF0=$eF0 rmsDrop=$rmsDrop');
      _prevRms = rms;
      return PitchEstimate(_prevF0!, _prevConf);
    }
    _prevF0 = f0;
    _prevConf = conf;
    _prevRms = rms;
    return est;
  }

  // Option B: pre-ONNX harmonic weighting
  Future<List<double>> _harmonicWeighting(List<double> samples) async {
    final stft = _stft(samples, 4096);
    final f0 = await _estimateF0(stft);
    if (f0 == null) return samples;
    final harmonics = _harmonicEnergies(stft, f0, 5);
    final eF0 = _smoothedEnergy(harmonics, 1);
    final weighted = List<double>.from(samples);
    for (int k = 2; k <= 5; k++) {
      final ek = _smoothedEnergy(harmonics, k);
      if (ek > eF0 + 3.0) {
        _applyFreqWeight(weighted, f0 * k, 0.7, 0.04);
      }
    }
    return weighted;
  }

  // Utilitaires
  List<double> _i16LeToDoubles(List<int> bytes) {
    final bd = ByteData.sublistView(Uint8List.fromList(bytes));
    final out = List<double>.filled(bytes.length ~/ 2, 0);
    for (int i = 0; i < out.length; i++) {
      final s = bd.getInt16(i * 2, Endian.little);
      out[i] = s / 32768.0;
    }
    return out;
  }

  List<double> _preprocess(List<double> x) {
    // HPF 40Hz, LPF 3kHz
    final out = List<double>.from(x);
    double hpPrevY = 0.0, hpPrevX = 0.0, lpPrevY = 0.0;
    final hpAlpha = _firstOrderHpAlpha(40.0, sampleRate);
    final lpBeta = _firstOrderLpBeta(3000.0, sampleRate);
    for (int i = 0; i < out.length; i++) {
      final xi = out[i];
      final yhp = hpAlpha * (hpPrevY + xi - hpPrevX);
      hpPrevY = yhp;
      hpPrevX = xi;
      lpPrevY = lpPrevY + lpBeta * (yhp - lpPrevY);
      out[i] = lpPrevY;
    }
    return out;
  }

  double _firstOrderHpAlpha(double cutoff, int fs) {
    final rc = 1.0 / (2 * math.pi * cutoff);
    final dt = 1.0 / fs;
    return rc / (rc + dt);
  }

  double _firstOrderLpBeta(double cutoff, int fs) {
    final rc = 1.0 / (2 * math.pi * cutoff);
    final dt = 1.0 / fs;
    return dt / (rc + dt);
  }

  Future<Uint8List> _loadAssetBytes(String asset) async {
    final data = await rootBundle.load(asset);
    return data.buffer.asUint8List();
  }

  List<double> _tensorToFloatList(dynamic tensor) {
    if (tensor == null) return const [];
    final v = (tensor is Float32List || tensor is Float64List)
        ? tensor
        : (tensor as dynamic).value ?? (tensor as dynamic).data ?? tensor;
    if (v is Float32List) return v.toList();
    if (v is Float64List) return v.map((e) => e.toDouble()).toList();
    if (v is List) return v.map((e) => (e as num).toDouble()).toList();
    return const [];
  }

  // STFT simplifié (magnitude)
  List<double> _stft(List<double> x, int winSize) {
    // Fenêtre Hann
    final win = List<double>.generate(winSize, (i) => 0.5 - 0.5 * math.cos(2 * math.pi * i / winSize));
    final buf = List<double>.filled(winSize, 0.0);
    for (int i = 0; i < math.min(x.length, winSize); i++) {
      buf[i] = x[i] * win[i];
    }
    // FFT naïve (pas optimisée)
    final re = List<double>.from(buf);
    final im = List<double>.filled(winSize, 0.0);
    _fft(re, im);
    final mag = List<double>.generate(winSize ~/ 2, (i) => math.sqrt(re[i] * re[i] + im[i] * im[i]));
    return mag;
  }

  // FFT naïve (Cooley-Tukey, radix-2)
  void _fft(List<double> re, List<double> im) {
    final n = re.length;
    if (n <= 1) return;
  // final levels = (math.log(n) / math.ln2).floor(); // unused
    final cosTable = List<double>.generate(n ~/ 2, (i) => math.cos(2 * math.pi * i / n));
    final sinTable = List<double>.generate(n ~/ 2, (i) => math.sin(2 * math.pi * i / n));
    // Bit-reversal
    for (int i = 0, j = 0; i < n; i++) {
      if (i < j) {
        final tmpRe = re[i];
        final tmpIm = im[i];
        re[i] = re[j];
        im[i] = im[j];
        re[j] = tmpRe;
        im[j] = tmpIm;
      }
      int k = n >> 1;
      while (k > 0 && j >= k) {
        j -= k;
        k >>= 1;
      }
      j += k;
    }
    // FFT
    for (int size = 2; size <= n; size <<= 1) {
      final halfsize = size >> 1;
      final tablestep = n ~/ size;
      for (int i = 0; i < n; i += size) {
        for (int j = i, k = 0; j < i + halfsize; j++, k += tablestep) {
          final tpre =  re[j + halfsize] * cosTable[k] + im[j + halfsize] * sinTable[k];
          final tpim = -re[j + halfsize] * sinTable[k] + im[j + halfsize] * cosTable[k];
          re[j + halfsize] = re[j] - tpre;
          im[j + halfsize] = im[j] - tpim;
          re[j] += tpre;
          im[j] += tpim;
        }
      }
    }
  }

  // Calcul des énergies harmoniques
  List<double> _harmonicEnergies(List<double> mag, double f0, int nHarm) {
    final binHz = sampleRate / (2 * mag.length);
    final energies = <double>[];
    for (int k = 1; k <= nHarm; k++) {
      final freq = f0 * k;
      final bin = (freq / binHz).round();
      double sum = 0.0;
      int count = 0;
      for (int i = bin - 2; i <= bin + 2; i++) {
        if (i >= 0 && i < mag.length) {
          sum += mag[i];
          count++;
        }
      }
      energies.add(count > 0 ? sum / count : 0.0);
    }
    return energies;
  }

  double _smoothedEnergy(List<double> energies, int k) {
    final idx = k - 1;
    double sum = 0.0;
    int count = 0;
    for (int i = idx - 1; i <= idx + 1; i++) {
      if (i >= 0 && i < energies.length) {
        sum += energies[i];
        count++;
      }
    }
    return count > 0 ? sum / count : 0.0;
  }

  double _rms(List<double> x) {
    double sum = 0.0;
    for (final v in x) {
      sum += v * v;
    }
    return math.sqrt(sum / x.length);
  }

  Future<double?> _estimateF0(List<double> mag) async {
    // Simple peak search (could be replaced by YIN or autocorr)
    int maxIdx = 0;
    double maxVal = -1.0;
    for (int i = 10; i < mag.length; i++) {
      if (mag[i] > maxVal) {
        maxVal = mag[i];
        maxIdx = i;
      }
    }
    final binHz = sampleRate / (2 * mag.length);
    final f0 = maxIdx * binHz;
    return f0 > 40.0 && f0 < 1500.0 ? f0 : null;
  }

  void _applyFreqWeight(List<double> x, double freq, double weight, double relWidth) {
    final n = x.length;
    final binHz = sampleRate / n;
    final center = (freq / binHz).round();
    final width = (relWidth * freq / binHz).round();
    for (int i = center - width; i <= center + width; i++) {
      if (i >= 0 && i < n) {
        x[i] *= weight;
      }
    }
  }

  // Détection de pitch de base par autocorrélation quand ONNX n'est pas disponible
  PitchEstimate? _fallbackPitchDetection(List<double> samples) {
    // Autocorrélation améliorée avec détection anti-sous-octave
    final minLag = (sampleRate / 800.0).round(); // ~800Hz max
    final maxLag = (sampleRate / 80.0).round();  // ~80Hz min
    
    // Calculer le spectre pour validation harmonique
    final spectrum = _stft(samples, 4096);
    
    final candidates = <_PitchCandidate>[];
    
    for (int lag = minLag; lag <= maxLag && lag < samples.length ~/ 2; lag++) {
      double sum = 0.0;
      double norm1 = 0.0, norm2 = 0.0;
      
      for (int i = 0; i < samples.length - lag; i++) {
        sum += samples[i] * samples[i + lag];
        norm1 += samples[i] * samples[i];
        norm2 += samples[i + lag] * samples[i + lag];
      }
      
      final corr = (norm1 * norm2 > 0) ? sum / math.sqrt(norm1 * norm2) : 0.0;
      
      if (corr > 0.2) { // Seuil plus bas pour collecter les candidats
        final f0 = sampleRate / lag;
        // Score pondéré : corrélation + bonus pour fréquences plus hautes + validation harmonique
        final freqBonus = f0 > 200 ? 0.1 : 0.0; // Favoriser E4 vs E2/A2
        final harmonicScore = _validateHarmonics(spectrum, f0);
        final totalScore = corr + freqBonus + harmonicScore;
        
        candidates.add(_PitchCandidate(f0, corr, totalScore));
      }
    }
    
    if (candidates.isEmpty) return null;
    
    // Trier par score total décroissant
    candidates.sort((a, b) => b.totalScore.compareTo(a.totalScore));
    
    final best = candidates.first;
    
    // Post-traitement anti-sous-octave : vérifier si 2×f0 ou 3×f0 est plus fort
    final f0 = best.frequency;
    final doubleF0Score = _validateHarmonics(spectrum, f0 * 2);
    final tripleF0Score = _validateHarmonics(spectrum, f0 * 3);
    
    double finalF0 = f0;
    double finalConf = best.correlation;
    
    // Si 2×f0 est significativement plus fort, c'est probablement la vraie fondamentale
    if (doubleF0Score > best.totalScore + 0.15 && f0 * 2 < 600) {
      finalF0 = f0 * 2;
      finalConf = math.min(best.correlation + 0.1, 1.0);
      if (debug) debugPrint('HarmonicPitchEngine FALLBACK: Octave correction applied ${f0.toStringAsFixed(1)} -> ${finalF0.toStringAsFixed(1)}');
    }
    // Si 3×f0 est plus fort (cas A2->E4)
    else if (tripleF0Score > best.totalScore + 0.2 && f0 * 3 < 600) {
      finalF0 = f0 * 3;
      finalConf = math.min(best.correlation + 0.05, 1.0);
      if (debug) debugPrint('HarmonicPitchEngine FALLBACK: Triple correction applied ${f0.toStringAsFixed(1)} -> ${finalF0.toStringAsFixed(1)}');
    }
    
    if (finalConf < 0.3) return null;
    
    if (debug) debugPrint('HarmonicPitchEngine FALLBACK: f0=${finalF0.toStringAsFixed(2)} conf=${finalConf.toStringAsFixed(3)} (${candidates.length} candidates)');
    
    return PitchEstimate(finalF0, finalConf);
  }
  
  double _validateHarmonics(List<double> spectrum, double f0) {
    final binHz = sampleRate / (2 * spectrum.length);
    double score = 0.0;
    
    // Vérifier la présence des harmoniques 1, 2, 3
    for (int h = 1; h <= 3; h++) {
      final freq = f0 * h;
      if (freq > sampleRate / 2) break;
      
      final bin = (freq / binHz).round();
      if (bin >= 0 && bin < spectrum.length) {
        final energy = spectrum[bin];
        // Pondération décroissante pour les harmoniques supérieures
        final weight = 1.0 / h;
        score += energy * weight;
      }
    }
    
    return score / 100.0; // Normaliser
  }
}

class _PitchCandidate {
  final double frequency;
  final double correlation;
  final double totalScore;
  
  _PitchCandidate(this.frequency, this.correlation, this.totalScore);
}
