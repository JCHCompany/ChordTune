part of 'tuner_bloc.dart';

class TunerState extends Equatable {
  final TunerStatus status;
  final String? note; // e.g., A4
  final double? cents; // deviation from target
  final double? frequency; // raw detected
  final bool locked; // within tolerance
  final String? tuningName; // e.g., Standard EADGBE
  final String? stringLabel; // target string label (E2, A2...)
  final int? capo; // detected capo number

  const TunerState._(this.status, {this.note, this.cents, this.frequency, this.locked = false, this.tuningName, this.stringLabel, this.capo});
  const TunerState.initial() : this._(TunerStatus.initial);
  const TunerState.permissionDenied() : this._(TunerStatus.permissionDenied);
  const TunerState.permissionPermanentlyDenied() : this._(TunerStatus.permissionPermanentlyDenied);
  const TunerState.warmUp() : this._(TunerStatus.warmUp);
  const TunerState.ready({String? note, double? cents, double? frequency, bool locked = false, String? tuningName, String? stringLabel, int? capo})
      : this._(TunerStatus.ready, note: note, cents: cents, frequency: frequency, locked: locked, tuningName: tuningName, stringLabel: stringLabel, capo: capo);

  @override
  List<Object?> get props => [status, note, cents, frequency, locked, tuningName, stringLabel, capo];
}

enum TunerStatus { initial, permissionDenied, permissionPermanentlyDenied, warmUp, ready }
