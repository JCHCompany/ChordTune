import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../app/l10n/l10n.dart';
import 'tuner_widget.dart';
import '../application/tuner_bloc.dart';
import '../infrastructure/permission_repository_impl.dart';
import '../engine/mock_pitch_engine.dart';
import '../engine/pitch_engine_interface.dart';
import '../engine/mic_pitch_engine.dart';
import '../engine/mixed_mic_pitch_engine.dart';
import '../engine/harmonic_pitch_engine.dart';
import '../core/tuning/tuning_preset.dart';

enum DevEngineMode { mock, mic, micOnnx, micMixed, harmonicTest }

class TunerScreen extends StatefulWidget {
  final PermissionRepository? permissions;
  final PitchEngine? engine; // optional external injection
  const TunerScreen({super.key, this.permissions, this.engine});

  @override
  State<TunerScreen> createState() => _TunerScreenState();
}

// ...existing imports...

class _TunerScreenState extends State<TunerScreen> {
  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    super.dispose();
  }
  DevEngineMode _mode = DevEngineMode.micOnnx;
  HarmonicExperimentMode _harmonicMode = HarmonicExperimentMode.optionA;

  PitchEngine _buildEngine() {
    if (widget.engine != null) return widget.engine!;
    switch (_mode) {
      case DevEngineMode.mock:
        return MockPitchEngine();
      case DevEngineMode.mic:
        return MicPitchEngine(backend: InferenceBackend.none);
      case DevEngineMode.micOnnx:
        return MicPitchEngine(
          backend: InferenceBackend.onnx,
          modelAsset: 'assets/models/swift_f0.onnx',
          debugOnnx: true,
        );
      case DevEngineMode.micMixed:
        return MixedMicPitchEngine(
          sampleRate: 48000,
          isBass: false,
          isViolinFamily: false,
          onnxSession: null,
        );
      case DevEngineMode.harmonicTest:
        return HarmonicPitchEngine(
          modelAsset: 'assets/models/swift_f0.onnx',
          mode: _harmonicMode,
          debug: true,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final engine = _buildEngine();
    return BlocProvider(
      key: ValueKey('${_mode}_$_harmonicMode'), // recreate bloc on mode or harmonic mode change
      create: (_) => TunerBloc(
        permissions: widget.permissions ?? const PermissionRepositoryImpl(),
        engine: engine,
      )..add(const TunerStarted()),
      child: Scaffold(
        appBar: AppBar(
          title: Text(loc.tunerTitle),
          actions: [
            BlocBuilder<TunerBloc, TunerState>(
              builder: (context, state) => PopupMenuButton<String>(
                tooltip: 'Tuning',
                icon: const Icon(Icons.music_note),
                onSelected: (name) => context.read<TunerBloc>().add(TunerChangePreset(name)),
                itemBuilder: (menuContext) {
                  final items = <PopupMenuEntry<String>>[];
                  for (final p in BuiltInTunings.all()) {
                    items.add(PopupMenuItem(value: p.name, child: Text(p.name)));
                  }
                  items.add(const PopupMenuDivider());
                  // Common capo presets
                  for (final k in [1, 2, 3, 4]) {
                    final name = 'Capo $k';
                    items.add(PopupMenuItem(value: name, child: Text(name)));
                  }
                  return items;
                },
              ),
            ),
            PopupMenuButton<DevEngineMode>(
              tooltip: 'Engine',
              icon: const Icon(Icons.settings_input_component),
              initialValue: _mode,
              onSelected: (m) => setState(() => _mode = m),
              itemBuilder: (context) => [
                const PopupMenuItem(value: DevEngineMode.mock, child: Text('Mock engine')),
                const PopupMenuItem(value: DevEngineMode.mic, child: Text('Microphone (DSP)')),
                const PopupMenuItem(value: DevEngineMode.micOnnx, child: Text('Microphone (ONNX SwiftF0)')),
                const PopupMenuItem(value: DevEngineMode.micMixed, child: Text('Microphone (mixte)')),
                const PopupMenuItem(value: DevEngineMode.harmonicTest, child: Text('Expérimental (harmonic comb)')),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            if (_mode == DevEngineMode.harmonicTest)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 16.0),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    const Text('Option:'),
                    ChoiceChip(
                      label: const Text('A (octave protection)'),
                      selected: _harmonicMode == HarmonicExperimentMode.optionA,
                      onSelected: (v) => setState(() => _harmonicMode = HarmonicExperimentMode.optionA),
                    ),
                    ChoiceChip(
                      label: const Text('B (harmonic weighting)'),
                      selected: _harmonicMode == HarmonicExperimentMode.optionB,
                      onSelected: (v) => setState(() => _harmonicMode = HarmonicExperimentMode.optionB),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: BlocBuilder<TunerBloc, TunerState>(
                builder: (context, state) {
                  switch (state.status) {
                    case TunerStatus.initial:
                      return const Center(child: CircularProgressIndicator());
                    case TunerStatus.permissionDenied:
                      return _PermissionDeniedView(onRequest: () => context.read<TunerBloc>().add(const TunerRequestPermission()));
                    case TunerStatus.permissionPermanentlyDenied:
                      return _PermissionPermanentlyDeniedView(
                        onOpenSettings: () => context.read<TunerBloc>().add(const TunerOpenSettings()),
                      );
                    case TunerStatus.warmUp:
                      return const Center(child: Text('Listening…'));
                    case TunerStatus.ready:
                      return Center(child: TunerWidget(state: state));
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionDeniedView extends StatelessWidget {
  final VoidCallback onRequest;
  const _PermissionDeniedView({required this.onRequest});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(loc.tunerMicRationale, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRequest, child: Text(loc.tunerGrantPermission)),
        ],
      ),
    );
  }
}

class _PermissionPermanentlyDeniedView extends StatelessWidget {
  final VoidCallback onOpenSettings;
  const _PermissionPermanentlyDeniedView({required this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(loc.tunerMicPermanentlyDenied, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: onOpenSettings, child: Text(loc.tunerOpenSettings)),
        ],
      ),
    );
  }
}
