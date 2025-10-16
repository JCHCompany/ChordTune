// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Guitar Trainer';

  @override
  String get homeWelcome => 'Welcome to the app shell';

  @override
  String get tunerTitle => 'Tuner';

  @override
  String tunerPlaceholderCents(num cents) {
    return 'Deviation: $cents cents';
  }

  @override
  String tunerSampleNote(String note) {
    return 'Sample note: $note';
  }

  @override
  String get tunerMicRationale =>
      'The tuner needs microphone access to detect pitch.';

  @override
  String get tunerGrantPermission => 'Grant microphone access';

  @override
  String get tunerMicPermanentlyDenied =>
      'Microphone access is permanently denied. Please enable it in Settings to use the tuner.';

  @override
  String get tunerOpenSettings => 'Open Settings';

  @override
  String get tunerLock => 'LOCK';
}
