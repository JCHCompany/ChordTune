import 'package:flutter/material.dart';
import '../../../app/l10n/l10n.dart';
import '../application/tuner_bloc.dart';

class TunerWidget extends StatelessWidget {
  final TunerState state;
  const TunerWidget({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(loc.tunerTitle, style: textTheme.headlineSmall),
        const SizedBox(height: 16),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (state.tuningName != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 8.0),
                        child: Chip(label: Text(state.tuningName!)),
                      ),
                    if (state.capo != null)
                      Chip(label: Text('Capo ${state.capo}')),
                  ],
                ),
                const SizedBox(height: 4),
                Text(loc.tunerSampleNote(state.note ?? '—'), style: textTheme.displaySmall),
                if (state.stringLabel != null) ...[
                  const SizedBox(height: 4),
                  Text(state.stringLabel!, style: textTheme.titleMedium),
                ],
                const SizedBox(height: 8),
                Text(loc.tunerPlaceholderCents((state.cents ?? 0).round())),
                if (state.locked) ...[
                  const SizedBox(height: 12),
                  Chip(label: Text(loc.tunerLock)),
                ]
              ],
            ),
          ),
        ),
      ],
    );
  }
}
