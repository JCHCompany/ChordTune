part of 'research_bloc.dart';

class ResearchState extends Equatable {
  final ResearchStatus status;
  final PitchFrameResearch? last;
  final bool holding;
  final String selectedDetector; // 'auto' | 'MPM' | 'YIN' | 'SRH'
  final List<double>? lastWave; // recent time-domain frame (after preproc)
  final List<double>? lastSpectrum; // magnitude spectrum for display
  const ResearchState({
    this.status = ResearchStatus.initial,
    this.last,
    this.holding = false,
    this.selectedDetector = 'auto',
    this.lastWave,
    this.lastSpectrum,
  });

  ResearchState copyWith({
    ResearchStatus? status,
    PitchFrameResearch? last,
    bool? holding,
    String? selectedDetector,
    List<double>? lastWave,
    List<double>? lastSpectrum,
  }) => ResearchState(
        status: status ?? this.status,
        last: last ?? this.last,
        holding: holding ?? this.holding,
        selectedDetector: selectedDetector ?? this.selectedDetector,
        lastWave: lastWave ?? this.lastWave,
        lastSpectrum: lastSpectrum ?? this.lastSpectrum,
      );

  @override
  List<Object?> get props => [status, last, holding, selectedDetector, lastWave, lastSpectrum];
}