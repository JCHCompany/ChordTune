import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'spectroid_cubit.dart';
import 'spectroid_config.dart';

class SpectroidSettingsSheet extends StatefulWidget {
  const SpectroidSettingsSheet({super.key});

  @override
  State<SpectroidSettingsSheet> createState() => _SpectroidSettingsSheetState();
}

class _SpectroidSettingsSheetState extends State<SpectroidSettingsSheet> {
  late SpectroidConfig _cfg;

  @override
  void initState() {
    super.initState();
    _cfg = context.read<SpectroidCubit>().state.config;
  }

  void _apply() {
    context.read<SpectroidCubit>().reconfigure(_cfg);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final spacing = const SizedBox(height: 12);
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, controller) {
        return Material(
          color: Theme.of(context).colorScheme.surface,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: ListView(
              controller: controller,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Réglages Spectroid', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    IconButton(
                      icon: const Icon(Icons.check),
                      tooltip: 'Appliquer',
                      onPressed: _apply,
                    )
                  ],
                ),
                spacing,
                // Presets
                Wrap(
                  spacing: 8,
                  children: [
                    _presetChip('Spectre', SpectroidPreset.spectre),
                    _presetChip('Accordeur', SpectroidPreset.accordeur),
                    _presetChip('Voix', SpectroidPreset.voix),
                    _presetChip('Analyse', SpectroidPreset.analyse),
                    _presetChip('Spectroid', SpectroidPreset.spectroid),
                  ],
                ),
                spacing,
                const Divider(),
                spacing,
                // Sample rate
                Row(
                  children: [
                    const SizedBox(width: 160, child: Text('Capture SR')), 
                    Expanded(
                      child: DropdownButton<int>(
                        isExpanded: true,
                        value: _cfg.fsCapture,
                        items: const [8000, 16000, 22050, 32000, 44100, 48000]
                            .map((sr) => DropdownMenuItem<int>(value: sr, child: Text('$sr Hz'))) 
                            .toList(),
                        onChanged: (v) => setState(() => _cfg = _cfg.copyWith(fsCapture: v ?? _cfg.fsCapture)),
                      ),
                    ),
                  ],
                ),
                spacing,
                Row(
                  children: [
                    const SizedBox(width: 160, child: Text('Resample vers')),
                    Expanded(
                      child: DropdownButton<int?>(
                        isExpanded: true,
                        value: _cfg.resampleTo,
                        items: <int?>[null, 16000, 22050, 32000, 44100, 48000]
                            .map((sr) => DropdownMenuItem<int?>(value: sr, child: Text(sr == null ? 'Aucun' : '$sr Hz')))
                            .toList(),
                        onChanged: (v) => setState(() => _cfg = _cfg.copyWith(resampleTo: v ?? -1)),
                      ),
                    ),
                  ],
                ),
                spacing,
                Row(
                  children: [
                    const SizedBox(width: 160, child: Text('Anti-aliasing')),
                    Expanded(
                      child: DropdownButton<AAMode>(
                        isExpanded: true,
                        value: _cfg.aaMode,
                        items: AAMode.values.map((m) => DropdownMenuItem(value: m, child: Text(m.name))).toList(),
                        onChanged: (v) => setState(() => _cfg = _cfg.copyWith(aaMode: v ?? _cfg.aaMode)),
                      ),
                    )
                  ],
                ),
                spacing,
                const Divider(),
                spacing,
                // FFT
                Row(
                  children: [
                    const SizedBox(width: 160, child: Text('Taille FFT')),
                    Expanded(
                      child: DropdownButton<int>(
                        isExpanded: true,
                        value: _cfg.fftSize,
                        items: const [512, 1024, 2048, 4096, 8192]
                            .map((n) => DropdownMenuItem<int>(value: n, child: Text('$n')))
                            .toList(),
                        onChanged: (v) => setState(() => _cfg = _cfg.copyWith(fftSize: v ?? _cfg.fftSize)),
                      ),
                    ),
                  ],
                ),
                spacing,
                Row(
                  children: [
                    const SizedBox(width: 160, child: Text('Chevauchement')),
                    Expanded(
                      child: Slider(
                        value: _cfg.overlap,
                        min: 0,
                        max: 0.9,
                        divisions: 18,
                        label: '${(_cfg.overlap * 100).toStringAsFixed(0)}%',
                        onChanged: (v) => setState(() => _cfg = _cfg.copyWith(overlap: v)),
                      ),
                    ),
                  ],
                ),
                spacing,
                Row(
                  children: [
                    const SizedBox(width: 160, child: Text('Fenêtre')),
                    Expanded(
                      child: DropdownButton<SpectroidWindow>(
                        isExpanded: true,
                        value: _cfg.window,
                        items: SpectroidWindow.values
                            .map((w) => DropdownMenuItem(value: w, child: Text(w.name)))
                            .toList(),
                        onChanged: (v) => setState(() => _cfg = _cfg.copyWith(window: v ?? _cfg.window)),
                      ),
                    ),
                  ],
                ),
                if (_cfg.window == SpectroidWindow.kaiser) ...[
                  spacing,
                  Row(
                    children: [
                      const SizedBox(width: 160, child: Text('Kaiser β')),
                      Expanded(
                        child: Slider(
                          value: (_cfg.kaiserBeta ?? 8.0).clamp(1.0, 20.0),
                          min: 1.0,
                          max: 20.0,
                          divisions: 38,
                          label: (_cfg.kaiserBeta ?? 8.0).toStringAsFixed(1),
                          onChanged: (v) => setState(() => _cfg = _cfg.copyWith(kaiserBeta: v)),
                        ),
                      ),
                    ],
                  ),
                ],
                spacing,
                const Divider(),
                spacing,
                // Display modes
                SwitchListTile(
                  title: const Text('Mode Spectroid (bandes intégrées)'),
                  subtitle: const Text('Trace ligne seule, dBFS/bin'),
                  value: _cfg.spectroidMode,
                  onChanged: (v) => setState(() => _cfg = _cfg.copyWith(spectroidMode: v)),
                ),
                Row(
                  children: [
                    const SizedBox(width: 160, child: Text('Mode d\'affichage')),
                    Expanded(
                      child: DropdownButton<DisplayMode>(
                        isExpanded: true,
                        value: _cfg.displayMode,
                        items: const [
                          DropdownMenuItem(value: DisplayMode.psdPrecise, child: Text('PSD précise (dBFS/Hz)')),
                          DropdownMenuItem(value: DisplayMode.spectroidCompat, child: Text('Spectroid compat. (dBFS/bin)')),
                        ],
                        onChanged: (v) => setState(() => _cfg = _cfg.copyWith(displayMode: v ?? _cfg.displayMode)),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const SizedBox(width: 160, child: Text('Domaine de moyenne')),
                    Expanded(
                      child: DropdownButton<AveragingDomain>(
                        isExpanded: true,
                        value: _cfg.averagingDomain,
                        items: AveragingDomain.values
                            .map((d) => DropdownMenuItem(value: d, child: Text(d.name)))
                            .toList(),
                        onChanged: (v) => setState(() => _cfg = _cfg.copyWith(averagingDomain: v ?? _cfg.averagingDomain)),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const SizedBox(width: 160, child: Text('Décimation FIR (pré‑FFT)')),
                    Expanded(
                      child: DropdownButton<int>(
                        isExpanded: true,
                        value: _cfg.firDecimation,
                        items: const [1, 2, 4, 8]
                            .map((m) => DropdownMenuItem<int>(value: m, child: Text('×$m')))
                            .toList(),
                        onChanged: (v) => setState(() => _cfg = _cfg.copyWith(firDecimation: v ?? _cfg.firDecimation)),
                      ),
                    ),
                  ],
                ),
                SwitchListTile(
                  title: const Text('Lissage FIR (style Spectroid)') ,
                  value: _cfg.firSmoothing,
                  onChanged: (v) => setState(() => _cfg = _cfg.copyWith(firSmoothing: v)),
                ),
                spacing,
                const Divider(),
                spacing,
                // Visual smoothing
                Row(
                  children: [
                    const SizedBox(width: 160, child: Text('Lissage amp (EMA)')),
                    Expanded(
                      child: Slider(
                        value: _cfg.emaAlphaAmp,
                        min: 0.0,
                        max: 0.99,
                        divisions: 99,
                        label: _cfg.emaAlphaAmp.toStringAsFixed(2),
                        onChanged: (v) => setState(() => _cfg = _cfg.copyWith(emaAlphaAmp: v)),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    const SizedBox(width: 160, child: Text('Lissage pic (EMA)')),
                    Expanded(
                      child: Slider(
                        value: _cfg.emaAlphaFreq,
                        min: 0.0,
                        max: 0.99,
                        divisions: 99,
                        label: _cfg.emaAlphaFreq.toStringAsFixed(2),
                        onChanged: (v) => setState(() => _cfg = _cfg.copyWith(emaAlphaFreq: v)),
                      ),
                    ),
                  ],
                ),
                spacing,
                const Divider(),
                spacing,
                // Peak tracking
                SwitchListTile(
                  title: const Text('Suivi du pic actif'),
                  value: _cfg.peakTracking,
                  onChanged: (v) => setState(() => _cfg = _cfg.copyWith(peakTracking: v)),
                ),
                Row(
                  children: [
                    const SizedBox(width: 160, child: Text('Recherche pic min (Hz)')),
                    Expanded(
                      child: TextFormField(
                        initialValue: _cfg.peakSearchMin.toString(),
                        keyboardType: TextInputType.number,
                        onChanged: (s) {
                          final v = int.tryParse(s) ?? _cfg.peakSearchMin;
                          setState(() => _cfg = _cfg.copyWith(peakSearchMin: v));
                        },
                      ),
                    )
                  ],
                ),
                spacing,
                Row(
                  children: [
                    const SizedBox(width: 160, child: Text('Recherche pic max (Hz)')),
                    Expanded(
                      child: TextFormField(
                        initialValue: _cfg.peakSearchMax.toString(),
                        keyboardType: TextInputType.number,
                        onChanged: (s) {
                          final v = int.tryParse(s) ?? _cfg.peakSearchMax;
                          setState(() => _cfg = _cfg.copyWith(peakSearchMax: v));
                        },
                      ),
                    )
                  ],
                ),
                spacing,
                SwitchListTile(
                  title: const Text('Garde harmonique (÷2 si 2f domine)'),
                  value: _cfg.harmonicGuard,
                  onChanged: (v) => setState(() => _cfg = _cfg.copyWith(harmonicGuard: v)),
                ),
                spacing,
                const Divider(),
                spacing,
                // Audio configuration
                const Text('Configuration Audio', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                spacing,
                Row(
                  children: [
                    const SizedBox(width: 160, child: Text('Source audio')),
                    Expanded(
                      child: DropdownButton<AudioSource>(
                        isExpanded: true,
                        value: _cfg.audioSource,
                        items: const [
                          DropdownMenuItem(value: AudioSource.auto, child: Text('Auto')),
                          DropdownMenuItem(value: AudioSource.unprocessed, child: Text('UNPROCESSED')),
                          DropdownMenuItem(value: AudioSource.voiceRecognition, child: Text('VOICE_RECOGNITION')),
                        ],
                        onChanged: (v) => setState(() => _cfg = _cfg.copyWith(audioSource: v ?? _cfg.audioSource)),
                      ),
                    ),
                  ],
                ),
                spacing,
                Row(
                  children: [
                    const SizedBox(width: 160, child: Text('Filtre DC')),
                    Expanded(
                      child: DropdownButton<DcFilterType>(
                        isExpanded: true,
                        value: _cfg.dcFilter,
                        items: const [
                          DropdownMenuItem(value: DcFilterType.none, child: Text('Aucun')),
                          DropdownMenuItem(value: DcFilterType.iir, child: Text('IIR (~3Hz)')),
                          DropdownMenuItem(value: DcFilterType.dcBlocker, child: Text('DC-Blocker')),
                        ],
                        onChanged: (v) => setState(() => _cfg = _cfg.copyWith(dcFilter: v ?? _cfg.dcFilter)),
                      ),
                    ),
                  ],
                ),
                spacing,
                Row(
                  children: [
                    const SizedBox(width: 160, child: Text('Filtre secteur')),
                    Expanded(
                      child: DropdownButton<NotchFilter>(
                        isExpanded: true,
                        value: _cfg.notchFilter,
                        items: const [
                          DropdownMenuItem(value: NotchFilter.none, child: Text('Aucun')),
                          DropdownMenuItem(value: NotchFilter.hz50, child: Text('50 Hz')),
                          DropdownMenuItem(value: NotchFilter.hz60, child: Text('60 Hz')),
                        ],
                        onChanged: (v) => setState(() => _cfg = _cfg.copyWith(notchFilter: v ?? _cfg.notchFilter)),
                      ),
                    ),
                  ],
                ),
                spacing,
                SwitchListTile(
                  title: const Text('Désactiver effets audio'),
                  subtitle: const Text('AGC, NS, AEC'),
                  value: _cfg.disableAudioEffects,
                  onChanged: (v) => setState(() => _cfg = _cfg.copyWith(disableAudioEffects: v)),
                ),
                spacing,
                const Divider(),
                spacing,
                // Display band
                Row(
                  children: [
                    const SizedBox(width: 160, child: Text('Bande max (Hz)')),
                    Expanded(
                      child: DropdownButton<int>(
                        isExpanded: true,
                        value: _cfg.displayBandMax,
                        items: const [4000, 8000, 20000]
                            .map((hz) => DropdownMenuItem(value: hz, child: Text(hz >= 1000 ? '${(hz/1000).round()} kHz' : '$hz Hz')))
                            .toList(),
                        onChanged: (v) => setState(() => _cfg = _cfg.copyWith(displayBandMax: v ?? _cfg.displayBandMax)),
                      ),
                    ),
                  ],
                ),
                spacing,
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Annuler'),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      onPressed: _apply,
                      child: const Text('Appliquer'),
                    ),
                  ],
                )
              ],
            ),
          ),
        );
      },
    );
  }

  ChoiceChip _presetChip(String label, SpectroidPreset preset) {
    return ChoiceChip(
      label: Text(label),
      selected: _cfg.preset == preset,
      onSelected: (_) {
        setState(() {
          switch (preset) {
            case SpectroidPreset.spectre:
              _cfg = SpectroidConfig.presetSpectre();
              break;
            case SpectroidPreset.accordeur:
              _cfg = SpectroidConfig.presetAccordeur();
              break;
            case SpectroidPreset.voix:
              _cfg = SpectroidConfig.presetVoix();
              break;
            case SpectroidPreset.analyse:
              _cfg = SpectroidConfig.presetAnalyse();
              break;
            case SpectroidPreset.spectroid:
              _cfg = SpectroidConfig.presetSpectroid();
              break;
          }
        });
      },
    );
  }
}
