import 'package:equatable/equatable.dart';

enum SpectroidPreset { spectre, accordeur, voix, analyse, spectroid }

enum SpectroidWindow { hann, hamming, blackmanHarris, kaiser, flattop }

enum AAMode { auto, on, off }

enum DisplayUnit { dBFS, dBHz }

enum AudioSource { auto, unprocessed, voiceRecognition }

enum DcFilterType { none, iir, dcBlocker }

enum NotchFilter { none, hz50, hz60 }

enum DisplayMode { psdPrecise, spectroidCompat }

enum AveragingDomain { linear, log }

enum LowFreqHighPass { off, hz0p5, hz1, hz5, hz10 }

enum LogFreqRep { cqt, resonators }

enum PitchTrackerState { search, locked, nopitch }

class SpectroidConfig extends Equatable {
  final SpectroidPreset preset;
  final String requestedSampleRate; // 'auto' or numeric string
  final List<int> supportedSampleRates; // read-only
  final int effectiveSampleRate; // runtime info

  final int fsCapture; // capture request
  final int? resampleTo; // null = none
  final AAMode aaMode;

  final int fftSize;
  final double overlap; // 0..1
  final SpectroidWindow window;
  final double? kaiserBeta;
  // FIR decimation before FFT (anti-alias): 1(off),2,4,8
  final int firDecimation;
  // Ladder decimation levels (pre-FFT): 0..9 meaning factor 2^k
  final int decimLevels;
  // Low-frequency HPF after decimation (pre-FFT)
  final LowFreqHighPass lowFreqHpf;
  // Pitch detection parameters
  final bool enablePitch; // master switch
  final double pitchFMin;
  final double pitchFMax;
  final int pitchBinsPerOctave; // log-frequency resolution for salience
  final LogFreqRep logFreqRep; // CQT or resonators
  // YIN
  final int yinWindow; // samples at effective fs
  final int yinHop; // hop in samples (analysis step inside frame scheduler)
  final double yinThreshold; // CMND threshold
  // Harmonic sum
  final int harmH; // number of harmonics
  final double harmTolCents; // tolerance per harmonic in cents
  final double harmWeightDecay; // decay factor per harmonic (0..1)
  // Fusion
  final double fusionYinWeight;
  final double fusionHarmWeight;
  // Anti-octave
  final bool antiOctaveEnabled;
  final double
      antiOctaveSubharmThresh; // threshold to accept subharmonic switch
  // Tracker
  final int trackerBinsPerOct; // resolution for tracker grid
  final double trackerLockWindowCents;
  final double trackerMaxJumpLockedCents;
  final double trackerMaxJumpSearchCents;
  final int trackerHoldInMs;
  final int trackerHoldOutMs;
  final int trackerSmoothMs; // smoothing window / EMA equivalent
  final double trackerSnrOn; // SNR to engage pitch
  final double trackerSnrOff; // SNR to disengage
  // Advanced Pitch Focus Tracker
  final int trackerLockInMs; // time of stability to lock
  final bool trackerAdaptiveWindow; // adapt W within min/max
  final double trackerWindowMinCents; // adaptive lower bound
  final double trackerWindowMaxCents; // adaptive upper bound
  final double trackerCompetitorMarginDb; // margin vs competitor to drop
  final double trackerGatingDbfs; // in-band absolute power gating (dBFS)
  final bool trackerCoDecayEnabled; // enable co-decay term in focus score
  // Dominant Peak Tracker params
  final double dominantLockThresholdDb; // SNR threshold to lock
  final double dominantUnlockThresholdDb; // SNR threshold to unlock
  final int dominantHoldInMs; // time to build lock
  final int dominantHoldOutMs; // time to lose lock
  final double dominantLockWindowCents; // lock window size
  final double dominantMaxJumpCentsPerS; // max drift rate
  final bool dominantRescueEnabled; // missing fundamental rescue
  final double dominantPeakProminenceDb; // peak prominence threshold
  final int dominantNeighborSpanBins; // neighbor span for prominence
  // Whitening option
  final bool whiteningEnabled;
  // Show tracker state overlay
  final bool showTrackerState;
  // Overlay ± band (cents)
  final double overlayCentsBand;

  final int displayBandMax; // 4k/8k/20k etc.

  final double emaAlphaAmp; // 0..1 visual smoothing
  final bool peakTracking;
  final int peakSearchMin;
  final int peakSearchMax;
  final double emaAlphaFreq;
  final bool harmonicGuard;
  final int decimation; // 0..9, 0 = none; >0 = group that many bins for display
  final bool dcRemove; // subtract mean before window to remove DC

  // Spectroid-compatible mode
  final bool
      spectroidMode; // Use integrated frequency bands (dBFS) vs raw PSD (dB/Hz)
  final DisplayUnit displayUnit; // dBFS or dB/Hz
  final bool firSmoothing; // Apply FIR smoothing filter
  final DisplayMode displayMode; // PSD precise per Hz vs Spectroid per bin
  final AveragingDomain averagingDomain; // EMA domain for averaging

  // Advanced audio settings
  final AudioSource audioSource; // Prefer UNPROCESSED or VOICE_RECOGNITION
  final DcFilterType dcFilter; // DC removal method
  final NotchFilter notchFilter; // Power line frequency notch
  final bool disableAudioEffects; // Disable AGC, NS, AEC via AudioEffect

  const SpectroidConfig({
    this.preset = SpectroidPreset.spectre,
    this.requestedSampleRate = 'auto',
    this.supportedSampleRates = const [44100, 48000],
    this.effectiveSampleRate = 48000,
    this.fsCapture = 48000,
    this.resampleTo,
    this.aaMode = AAMode.auto,
    this.fftSize = 2048,
    this.overlap = 0.75,
    this.window = SpectroidWindow.hann,
    this.kaiserBeta,
    this.firDecimation = 2,
    this.decimLevels = 0,
    this.lowFreqHpf = LowFreqHighPass.hz1,
    this.enablePitch = true,
    this.pitchFMin = 40.0,
    this.pitchFMax = 4000.0,
    this.pitchBinsPerOctave = 24,
    this.logFreqRep = LogFreqRep.cqt,
    this.yinWindow = 2048,
    this.yinHop = 256,
    this.yinThreshold = 0.15,
    this.harmH = 8,
    this.harmTolCents = 20.0,
    this.harmWeightDecay = 0.85,
    this.fusionYinWeight = 0.5,
    this.fusionHarmWeight = 0.5,
    this.antiOctaveEnabled = true,
    this.antiOctaveSubharmThresh = 0.25,
    this.trackerBinsPerOct = 36,
    this.trackerLockWindowCents = 15.0,
    this.trackerMaxJumpLockedCents = 80.0,
    this.trackerMaxJumpSearchCents = 400.0,
    this.trackerHoldInMs = 120,
    this.trackerHoldOutMs = 250,
    this.trackerSmoothMs = 40,
    this.trackerSnrOn = 6.0,
    this.trackerSnrOff = 3.0,
    this.trackerLockInMs = 2000,
    this.trackerAdaptiveWindow = true,
    this.trackerWindowMinCents = 30.0,
    this.trackerWindowMaxCents = 80.0,
    this.trackerCompetitorMarginDb = 6.0,
    this.trackerGatingDbfs = -18.0,
    this.trackerCoDecayEnabled = true,
    this.dominantLockThresholdDb = 3.0, // SIGNAUX FAIBLES: Pour lock à -50dB (was 6.0)
    this.dominantUnlockThresholdDb = 1.0, // ÉQUILIBRÉ: Responsive mais stable (was -2.0)
    this.dominantHoldInMs = 150, // RESTAURÉ: Timing historique stable (was 80)
    this.dominantHoldOutMs = 150, // RESTAURÉ: Valeur historique responsive (was 400) 
    this.dominantLockWindowCents = 60.0, // RESTAURÉ: Fenêtre historique (was 80.0)
    this.dominantMaxJumpCentsPerS = 80.0, // RESTAURÉ: Vitesse historique stable (was 300.0)
    this.dominantRescueEnabled = true,
    this.dominantPeakProminenceDb = 4.0, // RESTAURÉ: Valeur historique stable (was 3.0)
    this.dominantNeighborSpanBins = 20,
    this.whiteningEnabled = false,
    this.showTrackerState = true,
    this.overlayCentsBand = 20.0,
    this.displayBandMax = 20000,
    this.emaAlphaAmp = 0.7,
    this.peakTracking = true,
    this.peakSearchMin = 20,
    this.peakSearchMax = 20000,
    this.emaAlphaFreq = 0.7,
    this.harmonicGuard = false,
    this.decimation = 0,
    this.dcRemove = true,
    this.spectroidMode = false,
    this.displayUnit = DisplayUnit.dBHz,
    this.firSmoothing = false,
    this.displayMode = DisplayMode.psdPrecise,
    this.averagingDomain = AveragingDomain.linear,
    this.audioSource = AudioSource.auto,
    this.dcFilter = DcFilterType.iir,
    this.notchFilter = NotchFilter.none,
    this.disableAudioEffects = true,
  });

  SpectroidConfig copyWith({
    SpectroidPreset? preset,
    String? requestedSampleRate,
    List<int>? supportedSampleRates,
    int? effectiveSampleRate,
    int? fsCapture,
    int? resampleTo, // use -1 to indicate null
    AAMode? aaMode,
    int? fftSize,
    double? overlap,
    SpectroidWindow? window,
    double? kaiserBeta,
    int? firDecimation,
    int? displayBandMax,
    double? emaAlphaAmp,
    bool? peakTracking,
    int? peakSearchMin,
    int? peakSearchMax,
    double? emaAlphaFreq,
    bool? harmonicGuard,
    int? decimation,
    bool? dcRemove,
    bool? spectroidMode,
    DisplayUnit? displayUnit,
    bool? firSmoothing,
    DisplayMode? displayMode,
    AveragingDomain? averagingDomain,
    int? decimLevels,
    LowFreqHighPass? lowFreqHpf,
    bool? enablePitch,
    double? pitchFMin,
    double? pitchFMax,
    int? pitchBinsPerOctave,
    LogFreqRep? logFreqRep,
    int? yinWindow,
    int? yinHop,
    double? yinThreshold,
    int? harmH,
    double? harmTolCents,
    double? harmWeightDecay,
    double? fusionYinWeight,
    double? fusionHarmWeight,
    bool? antiOctaveEnabled,
    double? antiOctaveSubharmThresh,
    int? trackerBinsPerOct,
    double? trackerLockWindowCents,
    double? trackerMaxJumpLockedCents,
    double? trackerMaxJumpSearchCents,
    int? trackerHoldInMs,
    int? trackerHoldOutMs,
    int? trackerSmoothMs,
    double? trackerSnrOn,
    double? trackerSnrOff,
    int? trackerLockInMs,
    bool? trackerAdaptiveWindow,
    double? trackerWindowMinCents,
    double? trackerWindowMaxCents,
    double? trackerCompetitorMarginDb,
    double? trackerGatingDbfs,
    bool? trackerCoDecayEnabled,
    double? dominantLockThresholdDb,
    double? dominantUnlockThresholdDb,
    int? dominantHoldInMs,
    int? dominantHoldOutMs,
    double? dominantLockWindowCents,
    double? dominantMaxJumpCentsPerS,
    bool? dominantRescueEnabled,
    double? dominantPeakProminenceDb,
    int? dominantNeighborSpanBins,
    bool? whiteningEnabled,
    bool? showTrackerState,
    double? overlayCentsBand,
    AudioSource? audioSource,
    DcFilterType? dcFilter,
    NotchFilter? notchFilter,
    bool? disableAudioEffects,
  }) {
    return SpectroidConfig(
      preset: preset ?? this.preset,
      requestedSampleRate: requestedSampleRate ?? this.requestedSampleRate,
      supportedSampleRates: supportedSampleRates ?? this.supportedSampleRates,
      effectiveSampleRate: effectiveSampleRate ?? this.effectiveSampleRate,
      fsCapture: fsCapture ?? this.fsCapture,
      resampleTo: resampleTo == -1 ? null : (resampleTo ?? this.resampleTo),
      aaMode: aaMode ?? this.aaMode,
      fftSize: fftSize ?? this.fftSize,
      overlap: overlap ?? this.overlap,
      window: window ?? this.window,
      kaiserBeta: kaiserBeta ?? this.kaiserBeta,
      firDecimation: firDecimation ?? this.firDecimation,
      decimLevels: decimLevels ?? this.decimLevels,
      lowFreqHpf: lowFreqHpf ?? this.lowFreqHpf,
      enablePitch: enablePitch ?? this.enablePitch,
      pitchFMin: pitchFMin ?? this.pitchFMin,
      pitchFMax: pitchFMax ?? this.pitchFMax,
      pitchBinsPerOctave: pitchBinsPerOctave ?? this.pitchBinsPerOctave,
      logFreqRep: logFreqRep ?? this.logFreqRep,
      yinWindow: yinWindow ?? this.yinWindow,
      yinHop: yinHop ?? this.yinHop,
      yinThreshold: yinThreshold ?? this.yinThreshold,
      harmH: harmH ?? this.harmH,
      harmTolCents: harmTolCents ?? this.harmTolCents,
      harmWeightDecay: harmWeightDecay ?? this.harmWeightDecay,
      fusionYinWeight: fusionYinWeight ?? this.fusionYinWeight,
      fusionHarmWeight: fusionHarmWeight ?? this.fusionHarmWeight,
      antiOctaveEnabled: antiOctaveEnabled ?? this.antiOctaveEnabled,
      antiOctaveSubharmThresh:
          antiOctaveSubharmThresh ?? this.antiOctaveSubharmThresh,
      trackerBinsPerOct: trackerBinsPerOct ?? this.trackerBinsPerOct,
      trackerLockWindowCents:
          trackerLockWindowCents ?? this.trackerLockWindowCents,
      trackerMaxJumpLockedCents:
          trackerMaxJumpLockedCents ?? this.trackerMaxJumpLockedCents,
      trackerMaxJumpSearchCents:
          trackerMaxJumpSearchCents ?? this.trackerMaxJumpSearchCents,
      trackerHoldInMs: trackerHoldInMs ?? this.trackerHoldInMs,
      trackerHoldOutMs: trackerHoldOutMs ?? this.trackerHoldOutMs,
      trackerSmoothMs: trackerSmoothMs ?? this.trackerSmoothMs,
      trackerSnrOn: trackerSnrOn ?? this.trackerSnrOn,
      trackerSnrOff: trackerSnrOff ?? this.trackerSnrOff,
      trackerLockInMs: trackerLockInMs ?? this.trackerLockInMs,
      trackerAdaptiveWindow:
          trackerAdaptiveWindow ?? this.trackerAdaptiveWindow,
      trackerWindowMinCents:
          trackerWindowMinCents ?? this.trackerWindowMinCents,
      trackerWindowMaxCents:
          trackerWindowMaxCents ?? this.trackerWindowMaxCents,
      trackerCompetitorMarginDb:
          trackerCompetitorMarginDb ?? this.trackerCompetitorMarginDb,
      trackerGatingDbfs: trackerGatingDbfs ?? this.trackerGatingDbfs,
      trackerCoDecayEnabled:
          trackerCoDecayEnabled ?? this.trackerCoDecayEnabled,
      dominantLockThresholdDb:
          dominantLockThresholdDb ?? this.dominantLockThresholdDb,
      dominantUnlockThresholdDb:
          dominantUnlockThresholdDb ?? this.dominantUnlockThresholdDb,
      dominantHoldInMs: dominantHoldInMs ?? this.dominantHoldInMs,
      dominantHoldOutMs: dominantHoldOutMs ?? this.dominantHoldOutMs,
      dominantLockWindowCents:
          dominantLockWindowCents ?? this.dominantLockWindowCents,
      dominantMaxJumpCentsPerS:
          dominantMaxJumpCentsPerS ?? this.dominantMaxJumpCentsPerS,
      dominantRescueEnabled:
          dominantRescueEnabled ?? this.dominantRescueEnabled,
      dominantPeakProminenceDb:
          dominantPeakProminenceDb ?? this.dominantPeakProminenceDb,
      dominantNeighborSpanBins:
          dominantNeighborSpanBins ?? this.dominantNeighborSpanBins,
      whiteningEnabled: whiteningEnabled ?? this.whiteningEnabled,
      showTrackerState: showTrackerState ?? this.showTrackerState,
      overlayCentsBand: overlayCentsBand ?? this.overlayCentsBand,
      displayBandMax: displayBandMax ?? this.displayBandMax,
      emaAlphaAmp: emaAlphaAmp ?? this.emaAlphaAmp,
      peakTracking: peakTracking ?? this.peakTracking,
      peakSearchMin: peakSearchMin ?? this.peakSearchMin,
      peakSearchMax: peakSearchMax ?? this.peakSearchMax,
      emaAlphaFreq: emaAlphaFreq ?? this.emaAlphaFreq,
      harmonicGuard: harmonicGuard ?? this.harmonicGuard,
      decimation: decimation ?? this.decimation,
      dcRemove: dcRemove ?? this.dcRemove,
      spectroidMode: spectroidMode ?? this.spectroidMode,
      displayUnit: displayUnit ?? this.displayUnit,
      firSmoothing: firSmoothing ?? this.firSmoothing,
      displayMode: displayMode ?? this.displayMode,
      averagingDomain: averagingDomain ?? this.averagingDomain,
      audioSource: audioSource ?? this.audioSource,
      dcFilter: dcFilter ?? this.dcFilter,
      notchFilter: notchFilter ?? this.notchFilter,
      disableAudioEffects: disableAudioEffects ?? this.disableAudioEffects,
    );
  }

  static SpectroidConfig presetSpectre() => const SpectroidConfig(
        preset: SpectroidPreset.spectre,
        fsCapture: 48000,
        resampleTo: null,
        fftSize: 2048,
        overlap: 0.75,
        window: SpectroidWindow.hann,
        emaAlphaAmp: 0.7,
        emaAlphaFreq: 0.7,
        displayBandMax: 20000,
        dcRemove: true,
        spectroidMode: false,
        displayUnit: DisplayUnit.dBHz,
        displayMode: DisplayMode.psdPrecise,
        firDecimation: 4,
        decimLevels: 0,
        lowFreqHpf: LowFreqHighPass.hz1,
        enablePitch: true,
        // CORRECTIONS URGENTES: Éviter lock sans signal + convergence rapide
        dominantLockThresholdDb: 20.0, // BEAUCOUP plus strict - éviter lock sans signal
        dominantUnlockThresholdDb: 10.0, // Plus strict aussi pour éviter lock fantôme  
        dominantHoldInMs: 200, // PLUS DE TEMPS - permet YIN/Harmonic de converger vers fondamental (was 100ms)
        dominantHoldOutMs: 50,  // TRÈS RAPIDE unlock
        dominantLockWindowCents: 80.0, // Fenêtre plus large pour exploration
        dominantMaxJumpCentsPerS: 1000.0, // BEAUCOUP plus rapide - 10x plus
        firSmoothing: false,
        audioSource: AudioSource.auto,
        dcFilter: DcFilterType.iir,
        notchFilter: NotchFilter.none,
        disableAudioEffects: true,
      );

  static SpectroidConfig presetAccordeur() => const SpectroidConfig(
        preset: SpectroidPreset.accordeur,
        fsCapture: 48000,
        resampleTo: 16000,
        fftSize: 1024,
        overlap: 0.5,
        window: SpectroidWindow.hann,
        emaAlphaFreq: 0.7,
        peakSearchMin: 50,
        peakSearchMax: 2000,
        harmonicGuard: true,
        displayBandMax: 8000,
        decimation: 0,
        dcRemove: true,
        spectroidMode: false,
        displayUnit: DisplayUnit.dBHz,
        displayMode: DisplayMode.psdPrecise,
        firDecimation: 2,
        decimLevels: 4,
        lowFreqHpf: LowFreqHighPass.hz1,
        enablePitch: true,
        // CORRECTIONS ACCORDEUR: Strict mais rapide
        dominantLockThresholdDb: 22.0, // TRÈS strict - éviter lock sans signal guitare
        dominantUnlockThresholdDb: 12.0, // Strict aussi
        dominantHoldInMs: 250, // PLUS DE TEMPS - permet convergence vers fondamental grave (was 150ms)
        dominantHoldOutMs: 75,  // TRÈS rapide unlock
        dominantLockWindowCents: 30.0, // Fenêtre plus petite pour précision
        dominantMaxJumpCentsPerS: 800.0, // Rapide pour suivi accordage
        firSmoothing: false,
        audioSource: AudioSource.unprocessed,
        dcFilter: DcFilterType.iir,
        notchFilter: NotchFilter.none,
        disableAudioEffects: true,
      );

  static SpectroidConfig presetVoix() => const SpectroidConfig(
        preset: SpectroidPreset.voix,
        fsCapture: 44100,
        resampleTo: null,
        fftSize: 2048,
        overlap: 0.66,
        window: SpectroidWindow.blackmanHarris,
        emaAlphaFreq: 0.85,
        emaAlphaAmp: 0.8,
        displayBandMax: 20000,
        dcRemove: true,
        spectroidMode: false,
        displayUnit: DisplayUnit.dBHz,
        displayMode: DisplayMode.psdPrecise,
        firDecimation: 4,
        decimLevels: 0,
        lowFreqHpf: LowFreqHighPass.hz1,
        enablePitch: true,
        firSmoothing: false,
        audioSource: AudioSource.voiceRecognition,
        dcFilter: DcFilterType.dcBlocker,
        notchFilter: NotchFilter.none,
        disableAudioEffects: false,
      );

  static SpectroidConfig presetAnalyse() => const SpectroidConfig(
        preset: SpectroidPreset.analyse,
        fsCapture: 48000,
        resampleTo: null,
        fftSize: 8192, // Test large FFT for PSD validation
        overlap: 0.75,
        window: SpectroidWindow.flattop,
        emaAlphaFreq: 0.95,
        emaAlphaAmp: 0.9,
        displayBandMax: 20000,
        dcRemove: true,
        spectroidMode: false,
        displayUnit: DisplayUnit.dBHz,
        displayMode: DisplayMode.psdPrecise,
        firDecimation: 4,
        decimLevels: 0,
        lowFreqHpf: LowFreqHighPass.hz1,
        enablePitch: true,
        firSmoothing: false,
        audioSource: AudioSource.unprocessed,
        dcFilter: DcFilterType.iir,
        notchFilter: NotchFilter.hz50,
        disableAudioEffects: true,
      );

  static SpectroidConfig presetSpectroid() => const SpectroidConfig(
        preset: SpectroidPreset.spectroid,
        requestedSampleRate: '48000',
        fsCapture: 48000,
        resampleTo: null,
        fftSize: 2048,
        overlap: 0.75,
        window: SpectroidWindow.hann,
        peakTracking: false,
        emaAlphaAmp: 0.15,
        displayBandMax: 20000,
        dcRemove: false,
        spectroidMode: true,
        displayUnit: DisplayUnit.dBFS,
        displayMode: DisplayMode.spectroidCompat,
        firDecimation: 1,
        decimLevels: 0,
        lowFreqHpf: LowFreqHighPass.hz1,
        enablePitch: true,
        firSmoothing: true,
        audioSource: AudioSource.unprocessed,
        dcFilter: DcFilterType.dcBlocker,
        notchFilter: NotchFilter.none,
        disableAudioEffects: true,
      );

  @override
  List<Object?> get props => [
        preset,
        requestedSampleRate,
        supportedSampleRates,
        effectiveSampleRate,
        fsCapture,
        resampleTo,
        aaMode,
        fftSize,
        overlap,
        window,
        kaiserBeta,
        firDecimation,
        decimLevels,
        lowFreqHpf,
        displayBandMax,
        emaAlphaAmp,
        peakTracking,
        peakSearchMin,
        peakSearchMax,
        emaAlphaFreq,
        harmonicGuard,
        decimation,
        dcRemove,
        spectroidMode,
        displayUnit,
        firSmoothing,
        displayMode,
        averagingDomain,
        audioSource,
        dcFilter,
        notchFilter,
        disableAudioEffects,
        enablePitch,
        pitchFMin,
        pitchFMax,
        pitchBinsPerOctave,
        logFreqRep,
        yinWindow,
        yinHop,
        yinThreshold,
        harmH,
        harmTolCents,
        harmWeightDecay,
        fusionYinWeight,
        fusionHarmWeight,
        antiOctaveEnabled,
        antiOctaveSubharmThresh,
        trackerBinsPerOct,
        trackerLockWindowCents,
        trackerMaxJumpLockedCents,
        trackerMaxJumpSearchCents,
        trackerHoldInMs,
        trackerHoldOutMs,
        trackerSmoothMs,
        trackerSnrOn,
        trackerSnrOff,
        trackerLockInMs,
        trackerAdaptiveWindow,
        trackerWindowMinCents,
        trackerWindowMaxCents,
        trackerCompetitorMarginDb,
        trackerGatingDbfs,
        trackerCoDecayEnabled,
        dominantLockThresholdDb,
        dominantUnlockThresholdDb,
        dominantHoldInMs,
        dominantHoldOutMs,
        dominantLockWindowCents,
        dominantMaxJumpCentsPerS,
        dominantRescueEnabled,
        dominantPeakProminenceDb,
        dominantNeighborSpanBins,
        whiteningEnabled,
        showTrackerState,
        overlayCentsBand,
      ];
}
