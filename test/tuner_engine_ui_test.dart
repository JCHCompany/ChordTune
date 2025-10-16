import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_tuner/features/tuner/ui/tuner_screen.dart';
import 'package:flutter_tuner/features/tuner/application/tuner_bloc.dart';
import 'package:flutter_tuner/features/tuner/engine/mock_pitch_engine.dart';
import 'package:flutter_tuner/features/tuner/engine/pitch_engine_interface.dart';
import 'package:flutter_tuner/app/l10n/l10n.dart';

class _Perms implements PermissionRepository {
  @override
  Future<bool> hasMicPermission() async => true;
  @override
  Future<bool> isMicPermanentlyDenied() async => false;
  @override
  Future<bool> openAppSettings() async => true;
  @override
  Future<bool> requestMicPermission() async => true;
}

class _StepEngine extends MockPitchEngine {
  _StepEngine(List<double> seq) : super(sequence: seq, interval: const Duration(milliseconds: 10));
}

void main() {
  testWidgets('Tuner UI updates with engine frames', (tester) async {
  final PitchEngine engine = _StepEngine([430, 440, 450]);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: TunerScreen(permissions: _Perms(), engine: engine),
      ),
    );

    // Initial loading -> then warm-up state
    await tester.pump();
    expect(find.text('Listening…'), findsOneWidget);
    // Pump until note appears (simulate enough frames for warm-up)
    bool foundNote = false;
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.textContaining('Sample note').evaluate().isNotEmpty) {
        foundNote = true;
        break;
      }
    }
    expect(foundNote, isTrue);
    // And deviation text present
    expect(find.textContaining('Deviation'), findsOneWidget);
    // Dispose tree to stop engine timers cleanly
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    await engine.stop();
    if (engine is MockPitchEngine) {
      engine.dispose();
    }
  });
}
