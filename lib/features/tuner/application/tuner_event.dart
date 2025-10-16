part of 'tuner_bloc.dart';

abstract class TunerEvent extends Equatable {
  const TunerEvent();
  @override
  List<Object?> get props => [];
}

class TunerStarted extends TunerEvent {
  const TunerStarted();
}

class TunerRequestPermission extends TunerEvent {
  const TunerRequestPermission();
}

class TunerOpenSettings extends TunerEvent {
  const TunerOpenSettings();
}

class TunerFrame extends TunerEvent {
  final PitchFrame frame;
  const TunerFrame(this.frame);
  @override
  List<Object?> get props => [frame];
}

class TunerChangePreset extends TunerEvent {
  final String presetName; // must match BuiltInTunings names (or Capo k)
  const TunerChangePreset(this.presetName);
  @override
  List<Object?> get props => [presetName];
}
