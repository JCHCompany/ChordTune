import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'spectroid_config.dart';
import 'spectroid_engine.dart';
import 'audio_dsp.dart';
import '../../../dsp/dominant_pitch_tracker.dart';

class SpectroidState extends Equatable {
  final SpectroidConfig config;
  final List<int> supportedSampleRates;
  final int effectiveSampleRate;
  final Float32List? spectrum; // linear magnitude (not dB)
  final double peakFreqHz;
  final double peakDb;
  final bool capturing;
  final AudioEffectStatus audioStatus;
  // Pitch detection outputs
  final double f0Yin;
  final double confYin;
  final double f0Harm;
  final double confHarm;
  final double f0Fused;
  final double confFused;
  final double f0Tracked;
  final String trackerState;
  // New dominant tracker debug fields
  final List<PeakInfo> debugPeaks;
  final double predictedF0;
  final String lockReason;
  final double currentWindow;

  const SpectroidState({
    required this.config,
    this.supportedSampleRates = const [44100, 48000],
    this.effectiveSampleRate = 48000,
    this.spectrum,
    this.peakFreqHz = 0.0,
    this.peakDb = double.negativeInfinity,
    this.capturing = false,
    AudioEffectStatus? audioStatus,
    this.f0Yin = 0.0,
    this.confYin = 0.0,
    this.f0Harm = 0.0,
    this.confHarm = 0.0,
    this.f0Fused = 0.0,
    this.confFused = 0.0,
    this.f0Tracked = 0.0,
    this.trackerState = 'nopitch',
    this.debugPeaks = const [],
    this.predictedF0 = 0.0,
    this.lockReason = '',
    this.currentWindow = 60.0,
  }) : audioStatus = audioStatus ?? const AudioEffectStatus();

  SpectroidState copyWith({
    SpectroidConfig? config,
    List<int>? supportedSampleRates,
    int? effectiveSampleRate,
    Float32List? spectrum,
    double? peakFreqHz,
    double? peakDb,
    bool? capturing,
    AudioEffectStatus? audioStatus,
    double? f0Yin,
    double? confYin,
    double? f0Harm,
    double? confHarm,
    double? f0Fused,
    double? confFused,
    double? f0Tracked,
    String? trackerState,
    List<PeakInfo>? debugPeaks,
    double? predictedF0,
    String? lockReason,
    double? currentWindow,
  }) =>
      SpectroidState(
        config: config ?? this.config,
        supportedSampleRates: supportedSampleRates ?? this.supportedSampleRates,
        effectiveSampleRate: effectiveSampleRate ?? this.effectiveSampleRate,
        spectrum: spectrum ?? this.spectrum,
        peakFreqHz: peakFreqHz ?? this.peakFreqHz,
        peakDb: peakDb ?? this.peakDb,
        capturing: capturing ?? this.capturing,
        audioStatus: audioStatus ?? this.audioStatus,
        f0Yin: f0Yin ?? this.f0Yin,
        confYin: confYin ?? this.confYin,
        f0Harm: f0Harm ?? this.f0Harm,
        confHarm: confHarm ?? this.confHarm,
        f0Fused: f0Fused ?? this.f0Fused,
        confFused: confFused ?? this.confFused,
        f0Tracked: f0Tracked ?? this.f0Tracked,
        trackerState: trackerState ?? this.trackerState,
        debugPeaks: debugPeaks ?? this.debugPeaks,
        predictedF0: predictedF0 ?? this.predictedF0,
        lockReason: lockReason ?? this.lockReason,
        currentWindow: currentWindow ?? this.currentWindow,
      );

  @override
  List<Object?> get props => [
        config,
        supportedSampleRates,
        effectiveSampleRate,
        spectrum,
        peakFreqHz,
        peakDb,
        capturing,
        audioStatus,
        f0Yin,
        confYin,
        f0Harm,
        confHarm,
        f0Fused,
        confFused,
        f0Tracked,
        trackerState,
        debugPeaks,
        predictedF0,
        lockReason,
        currentWindow
      ];
}

class SpectroidCubit extends Cubit<SpectroidState> {
  Timer? _timer; // legacy demo timer
  SpectroidEngine? _engine;
  // Sticky-lock removed for maximum reactivity

  // Can't be const because presetSpectre() is a factory method.
  SpectroidCubit()
      : super(SpectroidState(config: SpectroidConfig.presetSpectre()));

  Future<void> start() async {
    _timer?.cancel();
    _engine ??= SpectroidEngine();
    emit(state.copyWith(capturing: true));
    await _engine!.start(
      cfg: state.config,
      onFrame: (f) {
        // Use raw tracker output for maximum reactivity - no sticky grace
        emit(state.copyWith(
          spectrum: f.magLinear,
          peakFreqHz: f.peakHz,
          peakDb: f.peakDb,
          effectiveSampleRate: f.effectiveSampleRate,
          audioStatus: f.audioStatus,
          f0Yin: f.f0Yin,
          confYin: f.confYin,
          f0Harm: f.f0Harm,
          confHarm: f.confHarm,
          f0Fused: f.f0Fused,
          confFused: f.confFused,
          f0Tracked: f.f0Tracked, // Raw output
          trackerState: f.trackerState, // Raw output
          debugPeaks: f.debugPeaks,
          predictedF0: f.predictedF0,
          lockReason: f.lockReason, // Raw output
          currentWindow: f.currentWindow,
        ));
      },
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _engine?.stop();
    emit(state.copyWith(capturing: false));
  }

  Future<void> reconfigure(SpectroidConfig cfg) async {
    debugPrint(
        'SpectroidCubit: Reconfiguring (spectre default), spectroidMode=${cfg.spectroidMode}, audioSource=${cfg.audioSource.name}');

    // Apply new configuration; restart engine if running
    final wasCapturing = state.capturing;

    // Always stop the engine first to ensure clean reconfiguration
    if (wasCapturing) {
      await _engine?.stop();
    }

    // Update state with new config
    emit(state.copyWith(config: cfg, capturing: false));

    // Restart engine with new configuration if it was running
    if (wasCapturing) {
      await _engine?.start(
        cfg: cfg,
        onFrame: (f) {
          // Use raw tracker output for maximum reactivity
          emit(state.copyWith(
            spectrum: f.magLinear,
            peakFreqHz: f.peakHz,
            peakDb: f.peakDb,
            effectiveSampleRate: f.effectiveSampleRate,
            audioStatus: f.audioStatus,
            f0Yin: f.f0Yin,
            confYin: f.confYin,
            f0Harm: f.f0Harm,
            confHarm: f.confHarm,
            f0Fused: f.f0Fused,
            confFused: f.confFused,
            f0Tracked: f.f0Tracked, // Raw output
            trackerState: f.trackerState, // Raw output
            debugPeaks: f.debugPeaks,
            predictedF0: f.predictedF0,
            lockReason: f.lockReason, // Raw output
            currentWindow: f.currentWindow,
            capturing: true,
          ));
        },
      );
    }
  }

  Future<void> setPreset(SpectroidPreset p) async {
    // Presets removed; keep spectre as the only option
    await reconfigure(SpectroidConfig.presetSpectre());
  }

  Future<void> setDisplayBandMax(int hz) async =>
      await reconfigure(state.config.copyWith(displayBandMax: hz));
}
