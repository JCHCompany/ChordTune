import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_tuner/features/tuner/ui/tuner_screen.dart';
import 'package:flutter_tuner/features/tuner/application/tuner_bloc.dart';
import 'package:flutter_tuner/app/l10n/l10n.dart';
import 'package:flutter_tuner/features/tuner/engine/mock_pitch_engine.dart';
import 'package:flutter_tuner/features/tuner/engine/pitch_engine_interface.dart';

void main() {
  testWidgets('TunerScreen shows permission denied UI', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: TunerScreen(permissions: MockPermissionRepository(granted: false)),
      ),
    );

    await tester.pumpAndSettle();
    expect(find.text('The tuner needs microphone access to detect pitch.'), findsOneWidget);
    expect(find.text('Grant microphone access'), findsOneWidget);
  });

  testWidgets('TunerScreen shows tuner when permission granted', (tester) async {
    final PitchEngine engine = MockPitchEngine(interval: const Duration(milliseconds: 10));
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: TunerScreen(permissions: const _GrantedPerms(), engine: engine),
      ),
    );

  await tester.pumpAndSettle();
    // Should render the tuner UI (ready state), not the permission UI.
    expect(find.text('Grant microphone access'), findsNothing);
    // Wait for warm-up then note
    bool foundNote = false;
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.textContaining('Sample note').evaluate().isNotEmpty) {
        foundNote = true;
        break;
      }
    }
    expect(foundNote, isTrue);
    // Unmount to ensure engine timers are stopped
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    await engine.stop();
    if (engine is MockPitchEngine) {
      engine.dispose();
    }
  });
}

class _GrantedPerms implements PermissionRepository {
  const _GrantedPerms();
  @override
  Future<bool> hasMicPermission() async => true;
  @override
  Future<bool> requestMicPermission() async => true;
  @override
  Future<bool> isMicPermanentlyDenied() async => false;
  @override
  Future<bool> openAppSettings() async => true;
}
