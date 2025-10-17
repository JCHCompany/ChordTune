import 'dart:async';
import 'package:flutter/material.dart';

import 'guided_tuner_config.dart';
import 'guided_tuner_engine.dart';
import 'strobe_painter.dart';

class GuidedTunerPage extends StatefulWidget {
  const GuidedTunerPage({super.key});

  @override
  State<GuidedTunerPage> createState() => _GuidedTunerPageState();
}

class _GuidedTunerPageState extends State<GuidedTunerPage> {
  final _engine = GuidedTunerEngine();
  GuidedTunerFrame? _last;
  StreamSubscription? _dummy; // placeholder if needed later

  @override
  void initState() {
    super.initState();
    final cfg = GuidedTunerConfig();
    _engine.start(cfg: cfg, onFrame: (f) {
      if (!mounted) return;
      setState(() { _last = f; });
    });
  }

  @override
  void dispose() {
    _engine.stop();
    _dummy?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cent = _last?.centOffset;
    final note = _last?.noteName ?? '--';
    final state = _last?.state.name ?? 'search';
    final rms = _last?.rmsDbfs.toStringAsFixed(1) ?? '--';
    final flux = _last?.spectralFlux.toStringAsFixed(3) ?? '--';
    final flat = _last?.spectralFlatness.toStringAsFixed(3) ?? '--';
    return Scaffold(
      appBar: AppBar(title: const Text('Accordeur guidé')),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            height: 240,
            child: CustomPaint(
              painter: StrobePainter(centOffset: cent),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(note, style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold)),
                    if (cent != null)
                      Text('${cent.toStringAsFixed(1)} cents', style: const TextStyle(fontSize: 18)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 16,
            children: [
              Chip(label: Text('state: $state')),
              Chip(label: Text('RMS: $rms dBFS')),
              Chip(label: Text('flux: $flux')),
              Chip(label: Text('flat: $flat')),
            ],
          ),
        ],
      ),
    );
  }
}
