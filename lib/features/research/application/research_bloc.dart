import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import '../domain/interfaces.dart';
import '../infrastructure/spectrum.dart';
import '../infrastructure/noise_gate.dart';

part 'research_event.dart';
part 'research_state.dart';

class ResearchBloc extends Bloc<ResearchEvent, ResearchState> {
  final IAudioPreproc preproc;
  final List<IPitchDetector> detectors;
  final IDetectorSelector selector;
  final IAntiOctave antiOctave;
  final ITracker tracker;
  final IMetricsSink? metrics;
  final int sampleRate;
  double tauConfLow = 0.6;
  double tauConfHigh = 0.7;
  PitchFrameResearch? _lastOut;
  // Hysteresis state
  DateTime? _belowSince;

  final _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  // persistent PCM buffer (bytes)
  final List<int> _byteBuffer = <int>[];
  final MinStatsNoiseGate _ng = MinStatsNoiseGate(alpha: 0.8, rise: 0.003, windowSec: 1.5);

  ResearchBloc({
    required this.preproc,
    required this.detectors,
    required this.selector,
    required this.antiOctave,
    required this.tracker,
    this.metrics,
    this.sampleRate = 48000,
    double? tauLow,
    double? tauHigh,
  }) : super(const ResearchState()) {
    // Seuils plus permissifs pour guitare
    tauConfLow = tauLow ?? 0.3;  // Plus permissif
    tauConfHigh = tauHigh ?? 0.5;
    on<ResearchStart>(_onStart);
    on<ResearchStop>(_onStop);
    on<ResearchSelectDetector>((e, emit) => emit(state.copyWith(selectedDetector: e.detector)));
    on<ResearchExportLogs>(_onExport);
    on<ResearchAudioChunk>(_onAudioChunk);
  }

  Future<void> _onStart(ResearchStart e, Emitter<ResearchState> emit) async {
    emit(state.copyWith(status: ResearchStatus.warmup));
    var micStatus = await Permission.microphone.status;
    if (!micStatus.isGranted) {
      micStatus = await Permission.microphone.request();
    }
    if (!micStatus.isGranted) {
      emit(state.copyWith(status: ResearchStatus.permissionDenied));
      return;
    }
    // Safety: ensure any previous recording is stopped
    if (await _rec.isRecording()) {
      await _rec.stop();
    }
    final stream = await _rec.startStream(RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      numChannels: 1,
      sampleRate: sampleRate,
      // Disable platform processing where supported
      echoCancel: false,
      noiseSuppress: false,
      autoGain: false,
    ));
    _sub = stream.listen((chunk) => add(ResearchAudioChunk(chunk)));
  }

  int _chooseFrameSize(double? f0) {
    // Frames plus petits pour réduire la latence
    if (f0 == null || f0 <= 0) return (sampleRate * 0.03).round(); // 30ms
    if (f0 < 110.0) return (sampleRate * 0.06).round(); // 60ms pour basses
    if (f0 < 220.0) return (sampleRate * 0.04).round(); // 40ms
    return (sampleRate * 0.025).round(); // 25ms pour aigus
  }

  Future<void> _onExport(ResearchExportLogs e, Emitter<ResearchState> emit) async {
    await metrics?.flush();
  }

  Future<void> _onStop(ResearchStop e, Emitter<ResearchState> emit) async {
    await _sub?.cancel();
    _sub = null;
    if (await _rec.isRecording()) await _rec.stop();
    emit(state.copyWith(status: ResearchStatus.stopped));
  }

  @override
  Future<void> close() async {
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    try {
      if (await _rec.isRecording()) {
        await _rec.stop();
      }
    } catch (_) {}
    return super.close();
  }

  Future<void> _onAudioChunk(ResearchAudioChunk e, Emitter<ResearchState> emit) async {
    // Overlap-add buffering and frame processing
    const bytesPerSample = 2;
    _byteBuffer.addAll(e.data);
    while (true) {
      int frameSize = _chooseFrameSize(_lastOut?.f0Hz);
      int hopSize = (frameSize * 0.25).round(); // Hop plus large = moins de calculs
      final needBytes = frameSize * bytesPerSample;
      final hopBytes = hopSize * bytesPerSample;
      if (_byteBuffer.length < needBytes) break;
      final frameBytes = _byteBuffer.sublist(0, needBytes);
      final removeCount = _byteBuffer.length < hopBytes ? _byteBuffer.length : hopBytes;
      _byteBuffer.removeRange(0, removeCount);

      final bd = ByteData.sublistView(Uint8List.fromList(frameBytes));
      final f = Float32List(frameSize);
      for (int i = 0; i < f.length; i++) {
        f[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
      }
  final x = preproc.process(f, sampleRate);

      double rms = 0.0;
      for (final v in x) {
        rms += v * v;
      }
      rms = math.sqrt(rms / x.length);
      final rmsDb = 20 * math.log(rms + 1e-12) / math.ln10;
      // Seuil RMS plus bas pour capturer les cordes de guitare
      if (rmsDb < -50) {
        // Deep silence: hold and do not display
        if (!emit.isDone) emit(state.copyWith(status: ResearchStatus.ready, holding: true, lastWave: x.toList()));
        continue;
      }

      final selected = state.selectedDetector;
      final active = (selected == 'auto')
          ? detectors
          : detectors.where((d) => d.name.toLowerCase() == selected.toLowerCase());
      final results = active.map((d) => d.detect(x, sampleRate)).toList();
      final chosen = selector.select(results);
  if (chosen == null) continue;

  final mag = SpectrumUtils.magnitude(x);
      // Noise gate score for voicing
      final binHz = sampleRate / (2 * mag.length);
      final voiceScore = _ng.updateAndScore(mag, binHz, fLo: 60, fHi: 3000);
      // Optional: anti-low-frequency in silence
      if (rmsDb < -35 && chosen.f0Hz < 65) {
        // treat as unvoiced
        if (!emit.isDone) emit(state.copyWith(status: ResearchStatus.ready, holding: true, lastWave: x.toList(), lastSpectrum: mag.toList()));
        continue;
      }
      final correctedF0 = antiOctave.correct(chosen.f0Hz, mag, sampleRate);
      final snrProxy = (20 * math.log(rms + 1e-9) / math.ln10 + 60) / 60.0;
      final combinedConf = (0.7 * chosen.confidence + 0.3 * snrProxy).clamp(0.0, 1.0);
      // Voicing gate for display and F0 (add voiceScore)
      if (!(combinedConf >= 0.85 && rmsDb >= -38 && voiceScore >= 0.6)) {
        // start/keep hysteresis timer
        final now = DateTime.now();
        _belowSince ??= now;
        final underMs = now.difference(_belowSince!).inMilliseconds;
        final dropConf = combinedConf < 0.70 || rmsDb < -45;
        if (dropConf && underMs >= 150) {
          // go idle
          _belowSince = null;
          if (!emit.isDone) {
            emit(state.copyWith(status: ResearchStatus.ready, holding: true, lastWave: x.toList(), lastSpectrum: mag.toList(), last: null));
          }
        } else {
          if (!emit.isDone) emit(state.copyWith(status: ResearchStatus.ready, holding: true, lastWave: x.toList(), lastSpectrum: mag.toList()));
        }
        continue;
      } else {
        _belowSince = null; // reset hysteresis
      }
      final (f0Final, confFinal) = tracker.update(correctedF0, combinedConf);
      final framed = PitchFrameResearch(
        f0Hz: f0Final,
        confidence: confFinal,
        rms: chosen.rms,
        snr: chosen.snr,
        ts: DateTime.now(),
        detector: chosen.detector,
      );
      metrics?.onFrame(framed);
      if (!emit.isDone) {
        emit(state.copyWith(status: ResearchStatus.ready, last: framed, holding: false, lastWave: x.toList(), lastSpectrum: mag.toList()));
      }
      _lastOut = framed;
    }
  }
}