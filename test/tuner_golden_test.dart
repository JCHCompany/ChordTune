import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_tuner/features/tuner/ui/tuner_widget.dart';
import 'package:flutter_tuner/features/tuner/application/tuner_bloc.dart';
import 'package:flutter_tuner/app/l10n/l10n.dart';

void main() {
  // Golden tests are marked skipped by default because they require
  // a stable rendering environment and golden files to be checked in.
  // To record/update goldens locally, run with --update-goldens.
  testWidgets('TunerWidget locked state - light (golden)', (tester) async {
    final state = const TunerState.ready(note: 'A4', cents: 0, frequency: 440, locked: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(useMaterial3: true),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Center(child: TunerWidget(state: state))),
      ),
    );
    await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/tuner_locked_light.png'));
  }, skip: true);

  testWidgets('TunerWidget locked state - dark (golden)', (tester) async {
    final state = const TunerState.ready(note: 'A4', cents: 0, frequency: 440, locked: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Center(child: TunerWidget(state: state))),
      ),
    );
    await expectLater(find.byType(Scaffold), matchesGoldenFile('goldens/tuner_locked_dark.png'));
  }, skip: true);
}
