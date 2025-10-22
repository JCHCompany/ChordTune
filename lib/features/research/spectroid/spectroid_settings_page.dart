import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'spectroid_config.dart';
import '../../../dsp/debug_logger.dart';

class SpectroidSettingsPage extends StatefulWidget {
  final SpectroidConfig initialConfig;
  final void Function(SpectroidConfig) onApply;

  const SpectroidSettingsPage(
      {super.key, required this.initialConfig, required this.onApply});

  @override
  State<SpectroidSettingsPage> createState() => _SpectroidSettingsPageState();
}

class _SpectroidSettingsPageState extends State<SpectroidSettingsPage> {
  late SpectroidConfig _cfg;

  @override
  void initState() {
    super.initState();
    _cfg = widget.initialConfig;
  }

  void _apply() {
    widget.onApply(_cfg);
    Navigator.of(context).pop();
  }

  // Compute guided detection range from targets and window in cents
  (double minHz, double maxHz) _guidedRange() {
    if (!_cfg.guidanceEnabled || _cfg.guidedTargetsHz.isEmpty) {
      return (_cfg.pitchFMin, _cfg.pitchFMax);
    }
    final targets =
        _cfg.guidedTargetsHz.where((f) => f.isFinite && f > 0).toList();
    if (targets.isEmpty) return (_cfg.pitchFMin, _cfg.pitchFMax);
    targets.sort();
    final minT = targets.first;
    final maxT = targets.last;
    final ratio = math.pow(2.0, _cfg.guidanceWindowCents / 1200.0) as double;
    final fMin = (minT / ratio).clamp(15.0, 12000.0);
    final fMax = (maxT * ratio).clamp(15.0, 12000.0);
    return (fMin, fMax);
  }

  @override
  Widget build(BuildContext context) {
    final spacing = const SizedBox(height: 12);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Réglages Spectroid'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'Appliquer',
            onPressed: _apply,
          )
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // Guided tuning controls (appliquent un biais doux autour des notes cibles)
          SwitchListTile(
            title: const Text('Guidage (accordage)'),
            subtitle:
                const Text('Favorise le verrouillage près des notes cibles'),
            value: _cfg.guidanceEnabled,
            onChanged: (v) => setState(() {
              _cfg = _cfg.copyWith(guidanceEnabled: v);
              if (v) {
                final (fMin, fMax) = _guidedRange();
                _cfg = _cfg.copyWith(pitchFMin: fMin, pitchFMax: fMax);
              }
            }),
          ),
          Row(
            children: [
              const SizedBox(width: 160, child: Text('Accordage')),
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _cfg.guidedTargetsHz.isNotEmpty
                      ? 'guitar_standard'
                      : 'none',
                  items: const [
                    DropdownMenuItem(value: 'none', child: Text('Aucun')),
                    DropdownMenuItem(
                        value: 'guitar_standard',
                        child: Text('Guitare (E2 A2 D3 G3 B3 E4)')),
                  ],
                  onChanged: (k) {
                    if (k == null) return;
                    if (k == 'none') {
                      setState(() =>
                          _cfg = _cfg.copyWith(guidedTargetsHz: const []));
                    } else if (k == 'guitar_standard') {
                      setState(() {
                        _cfg = _cfg.copyWith(guidedTargetsHz: const [
                          82.4069, // E2
                          110.0000, // A2
                          146.8324, // D3
                          195.9977, // G3
                          246.9417, // B3
                          329.6276, // E4
                        ]);
                        if (_cfg.guidanceEnabled) {
                          final (fMin, fMax) = _guidedRange();
                          _cfg =
                              _cfg.copyWith(pitchFMin: fMin, pitchFMax: fMax);
                        }
                      });
                    }
                  },
                ),
              ),
            ],
          ),
          if (_cfg.guidanceEnabled) ...[
            Row(children: [
              const SizedBox(width: 160, child: Text('Fenêtre (cents)')),
              Expanded(
                  child: Slider(
                      min: 20,
                      max: 120,
                      divisions: 20,
                      value: _cfg.guidanceWindowCents.clamp(20, 120),
                      label: _cfg.guidanceWindowCents.toStringAsFixed(0),
                      onChanged: (v) => setState(
                          () => _cfg = _cfg.copyWith(guidanceWindowCents: v))))
            ]),
            Row(children: [
              const SizedBox(width: 160, child: Text('Biais (+dB)')),
              Expanded(
                  child: Slider(
                      min: 0,
                      max: 6,
                      divisions: 12,
                      value: _cfg.guidanceBiasDb.clamp(0, 6),
                      label: _cfg.guidanceBiasDb.toStringAsFixed(1),
                      onChanged: (v) => setState(
                          () => _cfg = _cfg.copyWith(guidanceBiasDb: v))))
            ]),
            spacing,
            const Divider(),
            spacing,
          ],
          // Single default configuration (Spectre) - presets removed
          spacing,
          const Divider(),
          spacing,
          // Pitch detection section
          SwitchListTile(
            title: const Text('Détection f0 (global)'),
            value: _cfg.enablePitch,
            onChanged: (v) =>
                setState(() => _cfg = _cfg.copyWith(enablePitch: v)),
          ),
          if (_cfg.enablePitch) ...[
            Row(children: [
              const SizedBox(width: 160, child: Text('f0 min (Hz)')),
              Expanded(
                  child: Slider(
                min: 20,
                max: 200,
                value: _cfg.pitchFMin.clamp(20, 200),
                label: _cfg.pitchFMin.toStringAsFixed(0),
                onChanged: _cfg.guidanceEnabled
                    ? null
                    : (v) => setState(() => _cfg = _cfg.copyWith(pitchFMin: v)),
              )),
            ]),
            Row(children: [
              const SizedBox(width: 160, child: Text('f0 max (Hz)')),
              Expanded(
                  child: Slider(
                min: 1000,
                max: 8000,
                value: _cfg.pitchFMax.clamp(1000, 8000),
                label: _cfg.pitchFMax.toStringAsFixed(0),
                onChanged: _cfg.guidanceEnabled
                    ? null
                    : (v) => setState(() => _cfg = _cfg.copyWith(pitchFMax: v)),
              )),
            ]),
            Row(children: [
              const SizedBox(width: 160, child: Text('Bins / octave')),
              Expanded(
                  child: Slider(
                      min: 12,
                      max: 60,
                      divisions: 48,
                      value: _cfg.pitchBinsPerOctave.toDouble(),
                      label: _cfg.pitchBinsPerOctave.toString(),
                      onChanged: (v) => setState(() =>
                          _cfg = _cfg.copyWith(pitchBinsPerOctave: v.round()))))
            ]),
            Row(children: [
              const SizedBox(width: 160, child: Text('YIN fenêtre')),
              Expanded(
                  child: Slider(
                      min: 512,
                      max: 8192,
                      divisions: 15,
                      value: _cfg.yinWindow.toDouble().clamp(512, 8192),
                      label: _cfg.yinWindow.toString(),
                      onChanged: (v) => setState(
                          () => _cfg = _cfg.copyWith(yinWindow: v.round()))))
            ]),
            Row(children: [
              const SizedBox(width: 160, child: Text('YIN hop')),
              Expanded(
                  child: Slider(
                      min: 64,
                      max: 1024,
                      divisions: 15,
                      value: _cfg.yinHop.toDouble().clamp(64, 1024),
                      label: _cfg.yinHop.toString(),
                      onChanged: (v) => setState(
                          () => _cfg = _cfg.copyWith(yinHop: v.round()))))
            ]),
            Row(children: [
              const SizedBox(width: 160, child: Text('YIN seuil')),
              Expanded(
                  child: Slider(
                      min: 0.05,
                      max: 0.3,
                      divisions: 25,
                      value: _cfg.yinThreshold.clamp(0.05, 0.3),
                      label: _cfg.yinThreshold.toStringAsFixed(2),
                      onChanged: (v) => setState(
                          () => _cfg = _cfg.copyWith(yinThreshold: v))))
            ]),
            Row(children: [
              const SizedBox(width: 160, child: Text('Harmoniques (H)')),
              Expanded(
                  child: Slider(
                      min: 3,
                      max: 12,
                      divisions: 9,
                      value: _cfg.harmH.toDouble().clamp(3, 12),
                      label: _cfg.harmH.toString(),
                      onChanged: (v) => setState(
                          () => _cfg = _cfg.copyWith(harmH: v.round()))))
            ]),
            Row(children: [
              const SizedBox(width: 160, child: Text('Tolérance (cents)')),
              Expanded(
                  child: Slider(
                      min: 5,
                      max: 50,
                      divisions: 45,
                      value: _cfg.harmTolCents.clamp(5, 50),
                      label: _cfg.harmTolCents.toStringAsFixed(0),
                      onChanged: (v) => setState(
                          () => _cfg = _cfg.copyWith(harmTolCents: v))))
            ]),
            Row(children: [
              const SizedBox(width: 160, child: Text('Décroissance harm.')),
              Expanded(
                  child: Slider(
                      min: 0.5,
                      max: 0.95,
                      divisions: 45,
                      value: _cfg.harmWeightDecay.clamp(0.5, 0.95),
                      label: _cfg.harmWeightDecay.toStringAsFixed(2),
                      onChanged: (v) => setState(
                          () => _cfg = _cfg.copyWith(harmWeightDecay: v))))
            ]),
            Row(children: [
              const SizedBox(width: 160, child: Text('Poids YIN')),
              Expanded(
                  child: Slider(
                      min: 0,
                      max: 1,
                      divisions: 20,
                      value: _cfg.fusionYinWeight.clamp(0, 1),
                      label: _cfg.fusionYinWeight.toStringAsFixed(2),
                      onChanged: (v) => setState(
                          () => _cfg = _cfg.copyWith(fusionYinWeight: v))))
            ]),
            Row(children: [
              const SizedBox(width: 160, child: Text('Poids Harm')),
              Expanded(
                  child: Slider(
                      min: 0,
                      max: 1,
                      divisions: 20,
                      value: _cfg.fusionHarmWeight.clamp(0, 1),
                      label: _cfg.fusionHarmWeight.toStringAsFixed(2),
                      onChanged: (v) => setState(
                          () => _cfg = _cfg.copyWith(fusionHarmWeight: v))))
            ]),
            SwitchListTile(
                title: const Text('Anti-octave'),
                value: _cfg.antiOctaveEnabled,
                onChanged: (v) =>
                    setState(() => _cfg = _cfg.copyWith(antiOctaveEnabled: v))),
            Row(children: [
              const SizedBox(width: 160, child: Text('Seuil subharm.')),
              Expanded(
                  child: Slider(
                      min: 0.05,
                      max: 0.6,
                      divisions: 55,
                      value: _cfg.antiOctaveSubharmThresh.clamp(0.05, 0.6),
                      label: _cfg.antiOctaveSubharmThresh.toStringAsFixed(2),
                      onChanged: (v) => setState(() =>
                          _cfg = _cfg.copyWith(antiOctaveSubharmThresh: v))))
            ]),
            const Divider(),
            const Text('Tracker f0 (héritage)',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
            Row(children: [
              const SizedBox(
                  width: 160, child: Text('Fenêtre de capture (cents)')),
              Expanded(
                  child: Slider(
                      min: 5,
                      max: 50,
                      divisions: 45,
                      value: _cfg.trackerLockWindowCents.clamp(5, 50),
                      label: _cfg.trackerLockWindowCents.toStringAsFixed(0),
                      onChanged: (v) => setState(() =>
                          _cfg = _cfg.copyWith(trackerLockWindowCents: v))))
            ]),
            Row(children: [
              const SizedBox(
                  width: 160, child: Text('Temps de verrouillage (ms)')),
              Expanded(
                  child: Slider(
                      min: 500,
                      max: 4000,
                      divisions: 35,
                      value: _cfg.trackerLockInMs.clamp(500, 4000).toDouble(),
                      label: _cfg.trackerLockInMs.toString(),
                      onChanged: (v) => setState(() =>
                          _cfg = _cfg.copyWith(trackerLockInMs: v.round()))))
            ]),
            SwitchListTile(
                title: const Text('Fenêtre adaptative'),
                value: _cfg.trackerAdaptiveWindow,
                onChanged: (v) => setState(
                    () => _cfg = _cfg.copyWith(trackerAdaptiveWindow: v))),
            Row(children: [
              const SizedBox(width: 160, child: Text('W min (cents)')),
              Expanded(
                  child: Slider(
                      min: 20,
                      max: 80,
                      divisions: 60,
                      value: _cfg.trackerWindowMinCents.clamp(20, 80),
                      label: _cfg.trackerWindowMinCents.toStringAsFixed(0),
                      onChanged: (v) => setState(() =>
                          _cfg = _cfg.copyWith(trackerWindowMinCents: v))))
            ]),
            Row(children: [
              const SizedBox(width: 160, child: Text('W max (cents)')),
              Expanded(
                  child: Slider(
                      min: 30,
                      max: 120,
                      divisions: 90,
                      value: _cfg.trackerWindowMaxCents.clamp(30, 120),
                      label: _cfg.trackerWindowMaxCents.toStringAsFixed(0),
                      onChanged: (v) => setState(() =>
                          _cfg = _cfg.copyWith(trackerWindowMaxCents: v))))
            ]),
            Row(children: [
              const SizedBox(
                  width: 160, child: Text('Saut max LOCKED (cents)')),
              Expanded(
                  child: Slider(
                      min: 20,
                      max: 200,
                      divisions: 18,
                      value: _cfg.trackerMaxJumpLockedCents.clamp(20, 200),
                      label: _cfg.trackerMaxJumpLockedCents.toStringAsFixed(0),
                      onChanged: (v) => setState(() =>
                          _cfg = _cfg.copyWith(trackerMaxJumpLockedCents: v))))
            ]),
            Row(children: [
              const SizedBox(
                  width: 160, child: Text('Saut max SEARCH (cents)')),
              Expanded(
                  child: Slider(
                      min: 100,
                      max: 800,
                      divisions: 14,
                      value: _cfg.trackerMaxJumpSearchCents.clamp(100, 800),
                      label: _cfg.trackerMaxJumpSearchCents.toStringAsFixed(0),
                      onChanged: (v) => setState(() =>
                          _cfg = _cfg.copyWith(trackerMaxJumpSearchCents: v))))
            ]),
            Row(children: [
              const SizedBox(
                  width: 160, child: Text('Temps de lock (Hold‑in, ms)')),
              Expanded(
                  child: Slider(
                      min: 20,
                      max: 400,
                      divisions: 38,
                      value: _cfg.trackerHoldInMs.clamp(20, 400).toDouble(),
                      label: _cfg.trackerHoldInMs.toString(),
                      onChanged: (v) => setState(() =>
                          _cfg = _cfg.copyWith(trackerHoldInMs: v.round()))))
            ]),
            Row(children: [
              const SizedBox(
                  width: 160, child: Text('Temps sans pic (Hold‑out, ms)')),
              Expanded(
                  child: Slider(
                      min: 50,
                      max: 800,
                      divisions: 30,
                      value: _cfg.trackerHoldOutMs.clamp(50, 800).toDouble(),
                      label: _cfg.trackerHoldOutMs.toString(),
                      onChanged: (v) => setState(() =>
                          _cfg = _cfg.copyWith(trackerHoldOutMs: v.round()))))
            ]),
            Row(children: [
              const SizedBox(width: 160, child: Text('Lissage (ms)')),
              Expanded(
                  child: Slider(
                      min: 0,
                      max: 200,
                      divisions: 20,
                      value: _cfg.trackerSmoothMs.clamp(0, 200).toDouble(),
                      label: _cfg.trackerSmoothMs.toString(),
                      onChanged: (v) => setState(() =>
                          _cfg = _cfg.copyWith(trackerSmoothMs: v.round()))))
            ]),
            Row(children: [
              const SizedBox(width: 160, child: Text('SNR on (dB)')),
              Expanded(
                  child: Slider(
                      min: 0,
                      max: 20,
                      divisions: 20,
                      value: _cfg.trackerSnrOn.clamp(0, 20),
                      label: _cfg.trackerSnrOn.toStringAsFixed(1),
                      onChanged: (v) => setState(
                          () => _cfg = _cfg.copyWith(trackerSnrOn: v))))
            ]),
            Row(children: [
              const SizedBox(width: 160, child: Text('SNR off (dB)')),
              Expanded(
                  child: Slider(
                      min: 0,
                      max: 20,
                      divisions: 20,
                      value: _cfg.trackerSnrOff.clamp(0, 20),
                      label: _cfg.trackerSnrOff.toStringAsFixed(1),
                      onChanged: (v) => setState(
                          () => _cfg = _cfg.copyWith(trackerSnrOff: v))))
            ]),
            Row(children: [
              const SizedBox(width: 160, child: Text('Gating dBFS (in-band)')),
              Expanded(
                  child: Slider(
                      min: -140,
                      max: 0,
                      divisions: 140,
                      value: _cfg.trackerGatingDbfs.clamp(-140, 0),
                      label: _cfg.trackerGatingDbfs.toStringAsFixed(0),
                      onChanged: (v) => setState(
                          () => _cfg = _cfg.copyWith(trackerGatingDbfs: v))))
            ]),
            Row(children: [
              const SizedBox(width: 160, child: Text('Competitor margin (dB)')),
              Expanded(
                  child: Slider(
                      min: 0,
                      max: 12,
                      divisions: 12,
                      value: _cfg.trackerCompetitorMarginDb.clamp(0, 12),
                      label: _cfg.trackerCompetitorMarginDb.toStringAsFixed(0),
                      onChanged: (v) => setState(() =>
                          _cfg = _cfg.copyWith(trackerCompetitorMarginDb: v))))
            ]),
            SwitchListTile(
                title: const Text('Activer co-décroissance'),
                value: _cfg.trackerCoDecayEnabled,
                onChanged: (v) => setState(
                    () => _cfg = _cfg.copyWith(trackerCoDecayEnabled: v))),
            SwitchListTile(
                title: const Text('Afficher état tracker'),
                value: _cfg.showTrackerState,
                onChanged: (v) =>
                    setState(() => _cfg = _cfg.copyWith(showTrackerState: v))),
            Row(children: [
              const SizedBox(width: 160, child: Text('Overlay ± cents')),
              Expanded(
                  child: Slider(
                      min: 0,
                      max: 100,
                      divisions: 20,
                      value: _cfg.overlayCentsBand.clamp(0, 100),
                      label: _cfg.overlayCentsBand.toStringAsFixed(0),
                      onChanged: (v) => setState(
                          () => _cfg = _cfg.copyWith(overlayCentsBand: v))))
            ]),
            spacing,
            const Text('Dominant Peak Tracker (principal)',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            Row(children: [
              const SizedBox(width: 160, child: Text('Seuil de lock SNR (dB)')),
              Expanded(
                  child: Slider(
                      min: 3,
                      max: 40,
                      divisions: 37,
                      value: _cfg.dominantLockThresholdDb.clamp(3, 40),
                      label: _cfg.dominantLockThresholdDb.toStringAsFixed(1),
                      onChanged: (v) => setState(() =>
                          _cfg = _cfg.copyWith(dominantLockThresholdDb: v))))
            ]),
            Row(children: [
              const SizedBox(
                  width: 160, child: Text('Seuil de délock SNR (dB)')),
              Expanded(
                  child: Slider(
                      min: 0,
                      max: 40,
                      divisions: 40,
                      value: _cfg.dominantUnlockThresholdDb.clamp(0, 40),
                      label: _cfg.dominantUnlockThresholdDb.toStringAsFixed(1),
                      onChanged: (v) => setState(() =>
                          _cfg = _cfg.copyWith(dominantUnlockThresholdDb: v))))
            ]),
            Row(children: [
              const SizedBox(
                  width: 160, child: Text('Temps de lock (Hold‑in, ms)')),
              Expanded(
                  child: Slider(
                      min: 50,
                      max: 500,
                      divisions: 18,
                      value: _cfg.dominantHoldInMs.clamp(50, 500).toDouble(),
                      label: _cfg.dominantHoldInMs.toString(),
                      onChanged: (v) => setState(() =>
                          _cfg = _cfg.copyWith(dominantHoldInMs: v.round()))))
            ]),
            Row(children: [
              const SizedBox(
                  width: 200, child: Text('Temps sans pic (Hold‑out, ms)')),
              Expanded(
                  child: Slider(
                      min: 100,
                      max: 1500,
                      divisions: 28,
                      value: _cfg.dominantHoldOutMs.clamp(100, 1500).toDouble(),
                      label:
                          '${_cfg.dominantHoldOutMs} (délock forcé ≈ ${_cfg.dominantHoldOutMs * 2} ms)',
                      onChanged: (v) => setState(() =>
                          _cfg = _cfg.copyWith(dominantHoldOutMs: v.round()))))
            ]),
            Row(children: [
              const SizedBox(
                  width: 160, child: Text('Fenêtre de capture (cents)')),
              Expanded(
                  child: Slider(
                      min: 30,
                      max: 120,
                      divisions: 18,
                      value: _cfg.dominantLockWindowCents.clamp(30, 120),
                      label: _cfg.dominantLockWindowCents.toStringAsFixed(0),
                      onChanged: (v) => setState(() =>
                          _cfg = _cfg.copyWith(dominantLockWindowCents: v))))
            ]),
            Row(children: [
              const SizedBox(width: 160, child: Text('Vitesse max (cents/s)')),
              Expanded(
                  child: Slider(
                      min: 20,
                      max: 200,
                      divisions: 18,
                      value: _cfg.dominantMaxJumpCentsPerS.clamp(20, 200),
                      label: _cfg.dominantMaxJumpCentsPerS.toStringAsFixed(0),
                      onChanged: (v) => setState(() =>
                          _cfg = _cfg.copyWith(dominantMaxJumpCentsPerS: v))))
            ]),
            Row(children: [
              const SizedBox(
                  width: 160, child: Text('Prominence minimale (dB)')),
              Expanded(
                  child: Slider(
                      min: 2,
                      max: 10,
                      divisions: 8,
                      value: _cfg.dominantPeakProminenceDb.clamp(2, 10),
                      label: _cfg.dominantPeakProminenceDb.toStringAsFixed(1),
                      onChanged: (v) => setState(() =>
                          _cfg = _cfg.copyWith(dominantPeakProminenceDb: v))))
            ]),
            Row(children: [
              const SizedBox(
                  width: 200, child: Text('Portée médiane locale (bins)')),
              Expanded(
                  child: Slider(
                      min: 10,
                      max: 50,
                      divisions: 8,
                      value: _cfg.dominantNeighborSpanBins
                          .clamp(10, 50)
                          .toDouble(),
                      label: _cfg.dominantNeighborSpanBins.toString(),
                      onChanged: (v) => setState(() => _cfg =
                          _cfg.copyWith(dominantNeighborSpanBins: v.round()))))
            ]),
            Row(children: [
              const SizedBox(
                  width: 200, child: Text('Marge concurrent (base, dB)')),
              Expanded(
                  child: Slider(
                      min: 0,
                      max: 16,
                      divisions: 16,
                      value: _cfg.dominantCompetitorMarginBaseDb.clamp(0, 16),
                      label: _cfg.dominantCompetitorMarginBaseDb
                          .toStringAsFixed(1),
                      onChanged: (v) => setState(() => _cfg =
                          _cfg.copyWith(dominantCompetitorMarginBaseDb: v))))
            ]),
            Row(children: [
              const SizedBox(
                  width: 200,
                  child: Text('Marge adaptative (dB / dB de déficit)')),
              Expanded(
                  child: Slider(
                      min: 0.0,
                      max: 1.0,
                      divisions: 20,
                      value: _cfg.dominantCompetitorMarginAdaptiveSlope
                          .clamp(0.0, 1.0),
                      label: _cfg.dominantCompetitorMarginAdaptiveSlope
                          .toStringAsFixed(2),
                      onChanged: (v) => setState(() => _cfg = _cfg.copyWith(
                          dominantCompetitorMarginAdaptiveSlope: v))))
            ]),
            const Divider(),
            const Text('Discrimination largeur spectrale (pic tonal vs bruit)',
                style: TextStyle(fontWeight: FontWeight.bold)),
            Row(children: [
              const SizedBox(width: 200, child: Text('Seuil pic étroit (Hz)')),
              Expanded(
                  child: Slider(
                      min: 5,
                      max: 50,
                      divisions: 9,
                      value: _cfg.narrowPeakWidthHz.clamp(5, 50),
                      label: _cfg.narrowPeakWidthHz.toStringAsFixed(0),
                      onChanged: (v) => setState(
                          () => _cfg = _cfg.copyWith(narrowPeakWidthHz: v))))
            ]),
            Row(children: [
              const SizedBox(width: 200, child: Text('Seuil pic large (Hz)')),
              Expanded(
                  child: Slider(
                      min: 30,
                      max: 150,
                      divisions: 12,
                      value: _cfg.widePeakWidthHz.clamp(30, 150),
                      label: _cfg.widePeakWidthHz.toStringAsFixed(0),
                      onChanged: (v) => setState(
                          () => _cfg = _cfg.copyWith(widePeakWidthHz: v))))
            ]),
            Row(children: [
              const SizedBox(width: 200, child: Text('Marge pic étroit (dB)')),
              Expanded(
                  child: Slider(
                      min: 1,
                      max: 8,
                      divisions: 14,
                      value: _cfg.narrowPeakMarginDb.clamp(1, 8),
                      label: _cfg.narrowPeakMarginDb.toStringAsFixed(1),
                      onChanged: (v) => setState(
                          () => _cfg = _cfg.copyWith(narrowPeakMarginDb: v))))
            ]),
            Row(children: [
              const SizedBox(width: 200, child: Text('Marge pic large (dB)')),
              Expanded(
                  child: Slider(
                      min: 8,
                      max: 20,
                      divisions: 12,
                      value: _cfg.widePeakMarginDb.clamp(8, 20),
                      label: _cfg.widePeakMarginDb.toStringAsFixed(1),
                      onChanged: (v) => setState(
                          () => _cfg = _cfg.copyWith(widePeakMarginDb: v))))
            ]),
            SwitchListTile(
                title: const Text('Rescue fondamentale (/2, /3)'),
                value: _cfg.dominantRescueEnabled,
                onChanged: (v) => setState(
                    () => _cfg = _cfg.copyWith(dominantRescueEnabled: v))),
          ],
          // Sample rate
          Row(
            children: [
              const SizedBox(width: 160, child: Text('Capture SR')),
              Expanded(
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: _cfg.fsCapture,
                  items: const [8000, 16000, 22050, 32000, 44100, 48000]
                      .map((sr) => DropdownMenuItem<int>(
                          value: sr, child: Text('$sr Hz')))
                      .toList(),
                  onChanged: (v) => setState(() =>
                      _cfg = _cfg.copyWith(fsCapture: v ?? _cfg.fsCapture)),
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
                      .map((sr) => DropdownMenuItem<int?>(
                          value: sr,
                          child: Text(sr == null ? 'Aucun' : '$sr Hz')))
                      .toList(),
                  onChanged: (v) =>
                      setState(() => _cfg = _cfg.copyWith(resampleTo: v ?? -1)),
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
                  items: AAMode.values
                      .map((m) =>
                          DropdownMenuItem(value: m, child: Text(m.name)))
                      .toList(),
                  onChanged: (v) => setState(
                      () => _cfg = _cfg.copyWith(aaMode: v ?? _cfg.aaMode)),
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
                      .map((n) =>
                          DropdownMenuItem<int>(value: n, child: Text('$n')))
                      .toList(),
                  onChanged: (v) => setState(
                      () => _cfg = _cfg.copyWith(fftSize: v ?? _cfg.fftSize)),
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
                  onChanged: (v) =>
                      setState(() => _cfg = _cfg.copyWith(overlap: v)),
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
                      .map((w) =>
                          DropdownMenuItem(value: w, child: Text(w.name)))
                      .toList(),
                  onChanged: (v) => setState(
                      () => _cfg = _cfg.copyWith(window: v ?? _cfg.window)),
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
                    onChanged: (v) =>
                        setState(() => _cfg = _cfg.copyWith(kaiserBeta: v)),
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
            onChanged: (v) =>
                setState(() => _cfg = _cfg.copyWith(spectroidMode: v)),
          ),
          Row(
            children: [
              const SizedBox(width: 160, child: Text('Mode d\'affichage')),
              Expanded(
                child: DropdownButton<DisplayMode>(
                  isExpanded: true,
                  value: _cfg.displayMode,
                  items: const [
                    DropdownMenuItem(
                        value: DisplayMode.psdPrecise,
                        child: Text('PSD précise (dBFS/Hz)')),
                    DropdownMenuItem(
                        value: DisplayMode.spectroidCompat,
                        child: Text('Spectroid compat. (dBFS/bin)')),
                  ],
                  onChanged: (v) => setState(() =>
                      _cfg = _cfg.copyWith(displayMode: v ?? _cfg.displayMode)),
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
                      .map((d) =>
                          DropdownMenuItem(value: d, child: Text(d.name)))
                      .toList(),
                  onChanged: (v) => setState(() => _cfg = _cfg.copyWith(
                      averagingDomain: v ?? _cfg.averagingDomain)),
                ),
              ),
            ],
          ),
          Row(
            children: [
              const SizedBox(
                  width: 160, child: Text('Décimation FIR (pré‑FFT)')),
              Expanded(
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: _cfg.firDecimation,
                  items: const [1, 2, 4, 8]
                      .map((m) =>
                          DropdownMenuItem<int>(value: m, child: Text('×$m')))
                      .toList(),
                  onChanged: (v) => setState(() => _cfg =
                      _cfg.copyWith(firDecimation: v ?? _cfg.firDecimation)),
                ),
              ),
            ],
          ),
          spacing,
          Row(
            children: [
              const SizedBox(
                  width: 160, child: Text('Décimations (échelle 2^k)')),
              Expanded(
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: _cfg.decimLevels,
                  items: List.generate(10, (i) => i)
                      .map((d) => DropdownMenuItem<int>(
                          value: d, child: Text('$d (×${1 << d})')))
                      .toList(),
                  onChanged: (v) => setState(() =>
                      _cfg = _cfg.copyWith(decimLevels: v ?? _cfg.decimLevels)),
                ),
              ),
            ],
          ),
          spacing,
          Row(
            children: [
              const SizedBox(width: 160, child: Text('Filtre passe‑haut BF')),
              Expanded(
                child: DropdownButton<LowFreqHighPass>(
                  isExpanded: true,
                  value: _cfg.lowFreqHpf,
                  items: const [
                    DropdownMenuItem(
                        value: LowFreqHighPass.off, child: Text('OFF')),
                    DropdownMenuItem(
                        value: LowFreqHighPass.hz0p5, child: Text('0.5 Hz')),
                    DropdownMenuItem(
                        value: LowFreqHighPass.hz1,
                        child: Text('1 Hz (défaut)')),
                    DropdownMenuItem(
                        value: LowFreqHighPass.hz5, child: Text('5 Hz')),
                    DropdownMenuItem(
                        value: LowFreqHighPass.hz10, child: Text('10 Hz')),
                  ],
                  onChanged: (v) => setState(() =>
                      _cfg = _cfg.copyWith(lowFreqHpf: v ?? _cfg.lowFreqHpf)),
                ),
              ),
            ],
          ),
          SwitchListTile(
            title: const Text('Lissage FIR (style Spectroid)'),
            value: _cfg.firSmoothing,
            onChanged: (v) =>
                setState(() => _cfg = _cfg.copyWith(firSmoothing: v)),
          ),
          spacing,
          const Divider(),
          spacing,
          // DC removal
          SwitchListTile(
            title: const Text('Retirer composante DC (x − moyenne)'),
            value: _cfg.dcRemove,
            onChanged: (v) => setState(() => _cfg = _cfg.copyWith(dcRemove: v)),
          ),
          spacing,
          const Divider(),
          spacing,
          // Decimation (spectral bin grouping)
          Row(
            children: [
              const SizedBox(width: 160, child: Text('Décimation (bins)')),
              Expanded(
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: _cfg.decimation,
                  items: List.generate(10, (i) => i)
                      .map((d) =>
                          DropdownMenuItem<int>(value: d, child: Text('$d')))
                      .toList(),
                  onChanged: (v) => setState(() =>
                      _cfg = _cfg.copyWith(decimation: v ?? _cfg.decimation)),
                ),
              ),
            ],
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
                  onChanged: (v) =>
                      setState(() => _cfg = _cfg.copyWith(emaAlphaAmp: v)),
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
                  onChanged: (v) =>
                      setState(() => _cfg = _cfg.copyWith(emaAlphaFreq: v)),
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
            onChanged: (v) =>
                setState(() => _cfg = _cfg.copyWith(peakTracking: v)),
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
            onChanged: (v) =>
                setState(() => _cfg = _cfg.copyWith(harmonicGuard: v)),
          ),
          spacing,
          const Divider(),
          spacing,
          // Audio configuration
          const Text('Configuration Audio',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          spacing,
          Row(
            children: [
              const SizedBox(width: 160, child: Text('Source audio')),
              Expanded(
                child: DropdownButton<AudioSource>(
                  isExpanded: true,
                  value: _cfg.audioSource,
                  items: const [
                    DropdownMenuItem(
                        value: AudioSource.auto, child: Text('Auto')),
                    DropdownMenuItem(
                        value: AudioSource.unprocessed,
                        child: Text('UNPROCESSED (recommandé)')),
                    DropdownMenuItem(
                        value: AudioSource.voiceRecognition,
                        child: Text('VOICE_RECOGNITION')),
                  ],
                  onChanged: (v) => setState(() =>
                      _cfg = _cfg.copyWith(audioSource: v ?? _cfg.audioSource)),
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
                    DropdownMenuItem(
                        value: DcFilterType.none, child: Text('Aucun')),
                    DropdownMenuItem(
                        value: DcFilterType.iir,
                        child: Text('IIR 1er ordre (~3Hz)')),
                    DropdownMenuItem(
                        value: DcFilterType.dcBlocker,
                        child: Text('DC-Blocker')),
                  ],
                  onChanged: (v) => setState(
                      () => _cfg = _cfg.copyWith(dcFilter: v ?? _cfg.dcFilter)),
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
                    DropdownMenuItem(
                        value: NotchFilter.none, child: Text('Aucun')),
                    DropdownMenuItem(
                        value: NotchFilter.hz50, child: Text('50 Hz (Q=30)')),
                    DropdownMenuItem(
                        value: NotchFilter.hz60, child: Text('60 Hz (Q=30)')),
                  ],
                  onChanged: (v) => setState(() =>
                      _cfg = _cfg.copyWith(notchFilter: v ?? _cfg.notchFilter)),
                ),
              ),
            ],
          ),
          spacing,
          SwitchListTile(
            title: const Text('Désactiver effets audio'),
            subtitle:
                const Text('Désactive AGC, NS et AEC pour analyse précise'),
            value: _cfg.disableAudioEffects,
            onChanged: (v) =>
                setState(() => _cfg = _cfg.copyWith(disableAudioEffects: v)),
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
                      .map((hz) => DropdownMenuItem(
                          value: hz,
                          child: Text(hz >= 1000
                              ? '${(hz / 1000).round()} kHz'
                              : '$hz Hz')))
                      .toList(),
                  onChanged: (v) => setState(() => _cfg =
                      _cfg.copyWith(displayBandMax: v ?? _cfg.displayBandMax)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 16),
          // Section de debug - affichage du chemin du fichier de log
          const Text('Debug',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          ListTile(
            title: const Text('Fichier de log du Dominant Tracker'),
            subtitle: FutureBuilder<String?>(
              future: DebugLogger.instance
                  .init()
                  .then((_) => DebugLogger.instance.logFilePath),
              builder: (context, snapshot) {
                if (snapshot.hasData && snapshot.data != null) {
                  return Text(
                    snapshot.data!,
                    style:
                        const TextStyle(fontSize: 11, fontFamily: 'monospace'),
                  );
                }
                return const Text('Initialisation...');
              },
            ),
            trailing: IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copier le chemin',
              onPressed: () async {
                await DebugLogger.instance.init();
                final path = DebugLogger.instance.logFilePath;
                if (path != null) {
                  await Clipboard.setData(ClipboardData(text: path));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('Chemin copié dans le presse-papier')),
                    );
                  }
                }
              },
            ),
          ),
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
    );
  }

  // Presets removed — single default configuration used.
}
