import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_tuner/app/app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildApp() => const MyApp();

  testWidgets('HomeScreen shows localized title and welcome', (tester) async {
    await tester.pumpWidget(buildApp());
    // gen_l10n builds English by default when locale not specified.
    // Check for app title in AppBar and welcome text in body.
    expect(find.text('Guitar Trainer'), findsOneWidget);
    expect(find.text('Welcome to the app shell'), findsOneWidget);
  });
}
