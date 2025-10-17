import 'dart:async';

import 'package:flutter/material.dart';

import '../engine/audio_capture.dart';
import '../engine/tuner_engine.dart';
import '../pitch/tracker.dart';
import 'dart:math' as math;
import 'package:wakelock_plus/wakelock_plus.dart';

class TunerPage extends StatefulWidget {
  const TunerPage({super.key});

  @override
  State<TunerPage> createState() => _TunerPageState();
}

class _TunerPageState extends State<TunerPage> {
  late final TunerEngine _engine;
  late final StreamSubscription _sub;
  TunerState? _last;
  bool _scientific = false;
  // Spectrogram buffer: a rolling texture of log-binned PSD frames
  final List<List<double>> _spec = [];
  List<double> _specFreqs = const [];
  DateTime? _lastDraw;
  static const _maxSpecRows = 200; // rolling history

  @override
  void initState() {
    super.initState();
    final capture = AudioCaptureService(preferredSampleRate: 48000);
    _engine = TunerEngine(capture: capture, settings: const TunerSettings());
    _engine.start();
    _sub = _engine.stream.listen((e) {
      // Throttle UI updates for spectrogram to ~25 FPS
      final now = DateTime.now();
      final shouldRebuild =
          _lastDraw == null || now.difference(_lastDraw!).inMilliseconds > 40;
      _last = e;
      // Update spectrogram buffers
      _updateSpectrogram(e);
      if (shouldRebuild) {
        _lastDraw = now;
        setState(() {});
      }
    });
    // Empêche la mise en veille de l'écran
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    _sub.cancel();
    _engine.stop();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = _last;
    return Scaffold(
      appBar: AppBar(
        title: const Text('ChordTune'),
        actions: [
          IconButton(
            tooltip: _scientific ? 'Simple view' : 'Scientific view',
            onPressed: () => setState(() => _scientific = !_scientific),
            icon: Icon(_scientific ? Icons.equalizer : Icons.science),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: _openSettings,
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: _scientific ? _buildScientific(e) : _buildSimple(e),
      ),
    );
  }

  Widget _buildSimple(TunerState? e) {
    final state = e?.state ?? TrackState.search;
    final color = switch (state) {
      TrackState.search => Colors.amber,
      TrackState.locked => Colors.green,
      TrackState.frozen => Colors.blueGrey,
    };
    final f0 = e?.f0 == null ? '--' : e!.f0!.toStringAsFixed(2);
    final cents = e?.cents ?? 0.0;
    final stable = (e?.yinConfidence ?? 0.0).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                  color: color, borderRadius: BorderRadius.circular(6)),
              child:
                  Text('$state', style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: Center(
            child: Text(
              f0,
              style: const TextStyle(fontSize: 72, fontWeight: FontWeight.bold),
            ),
          ),
        ),
        Text('Cents: ${cents.toStringAsFixed(1)}', textAlign: TextAlign.center),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: stable, minHeight: 8),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _buildScientific(TunerState? e) {
    final psd = e?.psd ?? const <double>[];
    final freqs = e?.freqs ?? const <double>[];
    return Column(
      children: [
        SizedBox(
          height: 180,
          child: CustomPaint(
            painter: _SpectrogramPainter(rows: _spec, freqs: _specFreqs),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 200,
          child: CustomPaint(
            painter: _SpectrumPainter(freqs: freqs, db: psd, f0: e?.f0),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(spacing: 12, children: [
          _chip('SNR', e?.snrDb, suffix: ' dB'),
          _chip('Flux', e?.spectralFlux),
          _chip('Flat', e?.spectralFlatnessDb, suffix: ' dB'),
          _chip('YIN', e?.yinConfidence),
        ]),
        const SizedBox(height: 8),
        Text(
            'State: ${e?.state}  Transient: ${e?.isTransient == true ? 'yes' : 'no'}'),
      ],
    );
  }

  Widget _chip(String label, double? v, {String suffix = ''}) => Chip(
        label:
            Text('$label: ${v == null ? '--' : v.toStringAsFixed(2)}$suffix'),
      );

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (context) {
        var settings = _engine.settings;
        return StatefulBuilder(builder: (context, setStateSheet) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  const Text('Decimation'),
                  const SizedBox(width: 12),
                  DropdownButton<int>(
                    value: settings.decimationLevels,
                    items: [
                      for (var i = 0; i <= 9; i++)
                        DropdownMenuItem(value: i, child: Text('$i'))
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      setStateSheet(() =>
                          settings = settings.copyWith(decimationLevels: v));
                      _engine.updateSettings(settings);
                    },
                  ),
                ]),
                Row(children: [
                  const Text('FFT size'),
                  const SizedBox(width: 12),
                  DropdownButton<int>(
                    value: settings.fftSize,
                    items: const [1024, 2048, 4096, 8192]
                        .map((e) =>
                            DropdownMenuItem(value: e, child: Text('$e')))
                        .toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      setStateSheet(
                          () => settings = settings.copyWith(fftSize: v));
                      _engine.updateSettings(settings);
                    },
                  ),
                ]),
                const SizedBox(height: 8),
                SwitchListTile(
                  title: const Text('DC blocker'),
                  value: settings.dcBlockEnabled,
                  onChanged: (v) {
                    setStateSheet(
                        () => settings = settings.copyWith(dcBlockEnabled: v));
                    _engine.updateSettings(settings);
                  },
                ),
                SwitchListTile(
                  title: const Text('Notch 50/60 Hz'),
                  value: settings.notchEnabled,
                  onChanged: (v) {
                    setStateSheet(
                        () => settings = settings.copyWith(notchEnabled: v));
                    _engine.updateSettings(settings);
                  },
                ),
                const Divider(),
                SwitchListTile(
                  title: const Text('Enable AI (TFLite)'),
                  value: settings.aiEnabled,
                  onChanged: (v) {
                    setStateSheet(
                        () => settings = settings.copyWith(aiEnabled: v));
                    _engine.updateSettings(settings);
                  },
                ),
              ],
            ),
          );
        });
      },
    );
  }

  void _updateSpectrogram(TunerState e) {
    if (e.freqs.isEmpty || e.psd.isEmpty) return;
    if (_specFreqs.isEmpty) {
      _specFreqs = _logBins(e.freqs.last, binsPerOct: 48, fMin: 55.0);
    }
    final row = _logBinPsd(e.freqs, e.psd, _specFreqs);
    _spec.add(row);
    if (_spec.length > _maxSpecRows) {
      _spec.removeAt(0);
    }
  }

  // Generate log-spaced center frequencies from fMin to fMax
  List<double> _logBins(double fMax,
      {required int binsPerOct, required double fMin}) {
    final bins = <double>[];
    var f = fMin;
    final step = math.pow(2, 1 / binsPerOct) as double;
    while (f <= fMax) {
      bins.add(f);
      f *= step;
    }
    return bins;
  }

  // Density-preserving log-binning of linear-PSD (dB input converted to linear power)
  List<double> _logBinPsd(
      List<double> freqs, List<double> db, List<double> centers) {
    // Convert dB back to linear for accumulation
    final lin = List<double>.generate(
        db.length, (i) => math.pow(10, db[i] / 10).toDouble());
    final out = List<double>.filled(centers.length, -120.0);
    for (var i = 0; i < centers.length; i++) {
      final c = centers[i];
      final fLo = c / math.sqrt(2); // half-band around center in log scale
      final fHi = c * math.sqrt(2);
      double sum = 0.0;
      double bw = 0.0;
      for (var k = 0; k < freqs.length - 1; k++) {
        final f1 = freqs[k];
        final f2 = freqs[k + 1];
        if (f2 < fLo || f1 > fHi) continue;
        final df = (f2 - f1).abs();
        sum += lin[k] * df;
        bw += df;
      }
      if (bw > 0) {
        final density = sum / bw;
        out[i] = 10 * math.log(density + 1e-12) / math.log(10);
      }
    }
    return out;
  }
}

class _SpectrumPainter extends CustomPainter {
  _SpectrumPainter({required this.freqs, required this.db, required this.f0});
  final List<double> freqs;
  final List<double> db;
  final double? f0;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = Colors.blueAccent;
    if (freqs.isEmpty || db.isEmpty) return;
    final path = Path();
    final minDb = db.reduce((a, b) => a < b ? a : b);
    final maxDb = db.reduce((a, b) => a > b ? a : b);
    for (var i = 0; i < db.length; i++) {
      final x = i / (db.length - 1) * size.width;
      final yNorm = (db[i] - minDb) / ((maxDb - minDb).abs() + 1e-6);
      final y = size.height * (1 - yNorm);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, p);

    if (f0 != null) {
      final idx = _nearestIndex(freqs, f0!);
      final x = idx / (db.length - 1) * size.width;
      final mark = Paint()
        ..color = Colors.red
        ..strokeWidth = 1.0;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), mark);
    }
  }

  int _nearestIndex(List<double> list, double value) {
    var best = 0;
    var bestDiff = double.infinity;
    for (var i = 0; i < list.length; i++) {
      final d = (list[i] - value).abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = i;
      }
    }
    return best;
  }

  @override
  bool shouldRepaint(covariant _SpectrumPainter oldDelegate) => true;
}

class _SpectrogramPainter extends CustomPainter {
  _SpectrogramPainter({required this.rows, required this.freqs});
  final List<List<double>> rows; // newest at end
  final List<double> freqs; // log-spaced center frequencies low→high

  @override
  void paint(Canvas canvas, Size size) {
    if (rows.isEmpty || freqs.isEmpty) return;
    final cols = rows.last.length;
    final rowsCount = rows.length;
    // Find global min/max dB for color scale
    double minDb = 999, maxDb = -999;
    for (final r in rows) {
      for (final v in r) {
        if (v < minDb) minDb = v;
        if (v > maxDb) maxDb = v;
      }
    }
    if (maxDb - minDb < 1e-3) {
      maxDb = minDb + 1.0;
    }
    final cellH = size.height / cols; // frequency on vertical axis (log up)
    final cellW = size.width / rowsCount; // time on horizontal axis

    for (var t = 0; t < rowsCount; t++) {
      final r = rows[t];
      for (var f = 0; f < cols; f++) {
        final v = ((r[f] - minDb) / (maxDb - minDb)).clamp(0.0, 1.0);
        // Simple turbo-like gradient
        final color = _colormap(v);
        final paint = Paint()..color = color;
        final x = t * cellW;
        final y = size.height - (f + 1) * cellH;
        canvas.drawRect(Rect.fromLTWH(x, y, cellW + 1, cellH + 1), paint);
      }
    }
  }

  Color _colormap(double x) {
    // Map 0..1 to a blue→cyan→yellow→red gradient
    x = x.clamp(0.0, 1.0);
    if (x < 0.25) {
      final t = x / 0.25;
      return Color.lerp(Colors.black, Colors.blue, t) ?? Colors.blue;
    } else if (x < 0.5) {
      final t = (x - 0.25) / 0.25;
      return Color.lerp(Colors.blue, Colors.cyan, t) ?? Colors.cyan;
    } else if (x < 0.75) {
      final t = (x - 0.5) / 0.25;
      return Color.lerp(Colors.cyan, Colors.yellow, t) ?? Colors.yellow;
    } else {
      final t = (x - 0.75) / 0.25;
      return Color.lerp(Colors.yellow, Colors.red, t) ?? Colors.red;
    }
  }

  @override
  bool shouldRepaint(covariant _SpectrogramPainter oldDelegate) => true;
}
