// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class AppLocalizationsFr extends AppLocalizations {
  AppLocalizationsFr([String locale = 'fr']) : super(locale);

  @override
  String get appTitle => 'Guitar Trainer';

  @override
  String get homeWelcome => 'Bienvenue dans la coquille d\'application';

  @override
  String get tunerTitle => 'Accordeur';

  @override
  String tunerPlaceholderCents(num cents) {
    return 'Écart : $cents cents';
  }

  @override
  String tunerSampleNote(String note) {
    return 'Note exemple : $note';
  }

  @override
  String get tunerMicRationale =>
      'L\'accordeur a besoin de l\'accès au microphone pour détecter la hauteur.';

  @override
  String get tunerGrantPermission => 'Autoriser le microphone';

  @override
  String get tunerMicPermanentlyDenied =>
      'L\'accès au microphone est interdit de façon permanente. Activez-le dans les Réglages pour utiliser l\'accordeur.';

  @override
  String get tunerOpenSettings => 'Ouvrir les réglages';

  @override
  String get tunerLock => 'VERROU';
}
