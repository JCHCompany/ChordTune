import 'dart:math' as math;

/// Instrument types supported by the guided tuner
enum InstrumentType {
  guitar6,
  bass4,
}

/// Common tuning presets per instrument
enum TuningPreset {
  standard, // Guitar: E2 A2 D3 G3 B3 E4 ; Bass: E1 A1 D2 G2
  dropD,    // Guitar: D2 A2 D3 G3 B3 E4
}

/// Window type for spectral analysis
enum GuidedWindow { hann }

/// State of the guided tracker
enum GuidedTrackerState { search, locked }

/// Runtime configuration for the guided tuner pipeline
class GuidedTunerConfig {
  // Audio capture
  final int sampleRate;        // requested capture sample rate (e.g., 48000)
  final int fftSize;           // analysis FFT size (power of two)
  final double overlap;        // 0..1
  final GuidedWindow window;

  // Gating (anti-noise, anti-transient)
  final double gatingRmsDbfs;  // do not estimate if RMS below this (e.g., -60 dBFS)
  final double maxSpectralFlux; // transient gating threshold (relative units)
  final double maxSpectralFlatness; // tonal vs noise (0=tonal, 1=noise) e.g., 0.7

  // Tuning guidance
  final InstrumentType instrument;
  final TuningPreset preset;
  final int capoFret;          // 0..12
  final double candidateWindowCents; // ± cents around string targets (e.g., 50)

  // Harmonic comb parameters (HSS)
  final int maxHarmonics;      // number of harmonics to sum
  final double tolCents;       // tolerance per harmonic alignment
  final double weightDecay;    // decay factor per harmonic (0..1)

  // Decision thresholds
  final double lockSnrDb;      // need at least this SNR to lock
  final double unlockSnrDb;    // unlock below this SNR (hysteresis)
  final int holdInMs;          // stable time to lock
  final int holdOutMs;         // time below criteria to unlock

  const GuidedTunerConfig({
    this.sampleRate = 48000,
    this.fftSize = 1024,
    this.overlap = 0.5,
    this.window = GuidedWindow.hann,
    this.gatingRmsDbfs = -60.0,
    this.maxSpectralFlux = 0.06,
    this.maxSpectralFlatness = 0.7,
    this.instrument = InstrumentType.guitar6,
    this.preset = TuningPreset.standard,
    this.capoFret = 0,
    this.candidateWindowCents = 50.0,
    this.maxHarmonics = 6,
    this.tolCents = 40.0,
    this.weightDecay = 0.6,
    this.lockSnrDb = 6.0,
    this.unlockSnrDb = 3.0,
    this.holdInMs = 150,
    this.holdOutMs = 150,
  });

  /// Compute string target frequencies (Hz) given instrument, preset, and capo.
  List<double> stringTargetsHz() {
    List<double> base;
    switch (instrument) {
      case InstrumentType.guitar6:
        switch (preset) {
          case TuningPreset.standard:
            base = [82.4069, 110.0000, 146.8324, 196.0000, 246.9417, 329.6276];
            break;
          case TuningPreset.dropD:
            base = [73.4162, 110.0000, 146.8324, 196.0000, 246.9417, 329.6276];
            break;
        }
        break;
      case InstrumentType.bass4:
        base = [41.2034, 55.0000, 73.4162, 97.9989]; // E1 A1 D2 G2
        break;
    }
    if (capoFret > 0) {
      final factor = math.pow(2.0, capoFret / 12.0);
      base = base.map((f) => f * factor).toList();
    }
    return base;
  }
}

class GuidedTunerFrame {
  final double f0Hz;
  final GuidedTrackerState state;
  final int? stringIndex;          // 0-based string index if matched
  final String? noteName;          // e.g., E4
  final double? targetFreqHz;      // chosen string frequency
  final double? centOffset;        // cents vs. target
  // Gating metrics (diagnostic)
  final double rmsDbfs;
  final double spectralFlux;
  final double spectralFlatness;

  const GuidedTunerFrame({
    required this.f0Hz,
    required this.state,
    this.stringIndex,
    this.noteName,
    this.targetFreqHz,
    this.centOffset,
    required this.rmsDbfs,
    required this.spectralFlux,
    required this.spectralFlatness,
  });
}
