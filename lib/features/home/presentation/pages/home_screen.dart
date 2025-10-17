import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../../app/l10n/l10n.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(loc.appTitle)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              loc.homeWelcome,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => context.go('/tuner'),
              icon: const Icon(Icons.tune),
              label: Text(loc.tunerTitle),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => context.go('/research'),
              icon: const Icon(Icons.science),
              label: const Text('Accordeur R&D'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => context.go('/guided'),
              icon: const Icon(Icons.light_mode),
              label: const Text('Accordeur guidé'),
            ),
          ],
        ),
      ),
    );
  }
}
