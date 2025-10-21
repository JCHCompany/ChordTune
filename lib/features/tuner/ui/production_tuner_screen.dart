import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../research/spectroid/spectroid_cubit.dart';
import '../../../app/l10n/l10n.dart';
import '../../../dsp/dominant_pitch_tracker.dart';

/// État stable d'une note détectée
class _StableNoteState {
  final String noteName;
  final double frequency;
  final double cents;
  final DateTime timestamp;

  const _StableNoteState({
    required this.noteName,
    required this.frequency,
    required this.cents,
    required this.timestamp,
  });
}

class _GuidedTarget {
  final String label; // e.g., E2, A2, ...
  final double freq;
  const _GuidedTarget(this.label, this.freq);
}

/// Gestionnaire de stabilité pour éviter les sauts de notes
// Note stability manager removed: we now mirror R&D behavior and display immediately when locked.

/// Convertit une fréquence en nom de note + octave + cents
class _PitchConverter {
  // Notation anglaise : EADGBE (guitare)
  static const _noteNames = [
    'C',
    'C#',
    'D',
    'D#',
    'E',
    'F',
    'F#',
    'G',
    'G#',
    'A',
    'A#',
    'B'
  ];

  static Map<String, dynamic> frequencyToNote(double freq) {
    if (freq <= 0) {
      return {'name': '--', 'octave': 0, 'cents': 0.0, 'midiNote': 0};
    }

    // Formule MIDI: 69 + 12*log2(f/440)
    final midiNote = 69 + 12 * (math.log(freq / 440.0) / math.ln2);
    final roundedMidi = midiNote.round();
    final cents = ((midiNote - roundedMidi) * 100).roundToDouble();

    final noteIndex = roundedMidi % 12;
    final octave = (roundedMidi ~/ 12) - 1;

    final noteName = _noteNames[noteIndex];

    return {
      'name': noteName,
      'octave': octave,
      'cents': cents,
      'midiNote': roundedMidi,
    };
  }
}

/// Écran de tuner production pour l'utilisateur final
class ProductionTunerScreen extends StatefulWidget {
  const ProductionTunerScreen({super.key});

  @override
  State<ProductionTunerScreen> createState() => _ProductionTunerScreenState();
}

class _ProductionTunerScreenState extends State<ProductionTunerScreen> {
  // Immediate display state derived directly from tracker output
  _StableNoteState? _displayedNote;
  bool _isLocked = false; // mirror trackerState
  bool _showLockDisplay = false; // green frame overlay (immediate)

  // Smoothing/quantization state
  double _errS = 0.0; // smoothed cents error
  int _qDisplay = 0; // displayed step -5..+5
  DateTime _lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastStepChange = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _freezeUntil = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastFrameTs = DateTime.fromMillisecondsSinceEpoch(0);
  double _lastPeakDb = -120.0;
  double _lastConf = 0.0;

  // Tuning fill animation state (kept for future use; not drawing ring now)
  bool _isTuned = false;
  DateTime? _fillStartAt;
  double _fillProgress = 0.0;
  String? _lastNoteName;
  bool _bounce = false;

  // User settings
  double _qStepCents = 10.0; // 5 / 10 / 20
  double _smoothTauMs = 200.0; // default EMA tau in ms
  bool _showPlusMinus = true; // display +/- step around 0

  // Guided tuning UI state
  bool _guidanceEnabled = false;
  String _tuningKey = 'guitar_standard';
  List<_GuidedTarget> _guidedTargets = const [];

  @override
  void initState() {
    super.initState();
    // Prevent screen from sleeping while tuning
    WakelockPlus.enable();
    // Default guidance ON with 100 cents window for standard guitar
    _guidanceEnabled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyGuidanceConfig(windowCents: 100.0);
    });
  }

  @override
  void dispose() {
    // Allow screen sleep when leaving
    WakelockPlus.disable();
    super.dispose();
  }

  void _updateNote({
    required double f0,
    required String trackerState,
    required double conf,
    required double peakDb,
    List<PeakInfo>? peaks,
  }) {
    // Gate: show only when locked; hide immediately otherwise
    final locked = trackerState.toLowerCase() == 'locked' && f0 > 0;
    final now = DateTime.now();
    if (!locked) {
      if (mounted) {
        setState(() {
          _isLocked = false;
          _showLockDisplay = false;
          _displayedNote = null;
          // Stop all animations when stability is lost
          _fillStartAt = null;
          _fillProgress = 0.0;
          _isTuned = false;
          _bounce = false;
        });
      }
      return;
    } else {
      if (!_isLocked || !_showLockDisplay) {
        // Transition to locked -> show immediately
        _isLocked = true;
        _showLockDisplay = true;
      }
    }

    // Choose comparison target and label
    String noteName;
    double fTarget;
    if (_guidanceEnabled && _guidedTargets.isNotEmpty) {
      // Compare to nearest guided target of the selected tuning
      _GuidedTarget best = _guidedTargets.first;
      double bestDiff = (f0 - best.freq).abs();
      for (final t in _guidedTargets) {
        final d = (f0 - t.freq).abs();
        if (d < bestDiff) {
          best = t;
          bestDiff = d;
        }
      }
      noteName = best.label;
      fTarget = best.freq;
    } else {
      // Default chromatic nearest semitone
      final noteInfo = _PitchConverter.frequencyToNote(f0);
      noteName = '${noteInfo['name']}${noteInfo['octave']}';
      final int midiRounded = noteInfo['midiNote'] as int;
      fTarget = 440.0 * math.pow(2.0, (midiRounded - 69) / 12.0).toDouble();
    }
  // error in cents vs selected target
  final errCents = 1200.0 * (math.log(f0 / fTarget) / math.ln2);

  // Frame delta
    final dtMs = (_lastFrameTs.millisecondsSinceEpoch == 0)
        ? 16.0
        : (now
            .difference(_lastFrameTs)
            .inMilliseconds
            .toDouble()
            .clamp(1.0, 1000.0));
    _lastFrameTs = now;

    // Transient freeze: strong jump in peakDb (>9 dB) in <40ms
    final peakJump = (peakDb - _lastPeakDb);
    if (dtMs < 40.0 && peakJump > 9.0) {
      _freezeUntil = now.add(const Duration(milliseconds: 200));
    }
    _lastPeakDb = peakDb;

    // Adaptive tau by confidence in [0.08..0.30] s (slightly faster)
    _lastConf = conf.clamp(0.0, 1.0);
    const tauMinMs = 80.0; // 0.08 s
    const tauMaxMs = 300.0; // 0.30 s
    double tauMs = (_smoothTauMs).clamp(tauMinMs, tauMaxMs);
    // Adapt toward tauMin when confidence is high
    tauMs = tauMaxMs - (_lastConf * (tauMaxMs - tauMinMs));

    // EMA
    final alpha = dtMs / (tauMs + dtMs);
    _errS = _errS + alpha * (errCents - _errS);

    // Quantization step
    final step = _qStepCents;
    // Hysteresis around current qDisplay with ±0.5 step and 3 cents margin
    int nextDisplay = _qDisplay;
    final upThresh = (_qDisplay + 0.5) * step + 3.0;
    final dnThresh = (_qDisplay - 0.5) * step - 3.0;
    if (_errS > upThresh) nextDisplay = _qDisplay + 1;
    if (_errS < dnThresh) nextDisplay = _qDisplay - 1;

    // Rate limit: max ~3 steps per second (more responsive)
    final sinceChangeMs = now.difference(_lastStepChange).inMilliseconds;
    if (nextDisplay != _qDisplay) {
      if (sinceChangeMs < 330 || now.isBefore(_freezeUntil)) {
        nextDisplay = _qDisplay; // hold
      } else {
        _lastStepChange = now;
      }
    }
    nextDisplay = nextDisplay.clamp(-5, 5);
    _qDisplay = nextDisplay;

    // Immediate update: accept the new locked note/f0 directly
    if (mounted) {
      // throttle UI to ~30 Hz for snappier updates
      if (now.difference(_lastUiUpdate).inMilliseconds >= 33) {
        _lastUiUpdate = now;
        setState(() {
          // Reset tuned state if note changes
          final newName = noteName;
          if (_lastNoteName != null && _lastNoteName != newName) {
            _isTuned = false;
            _fillStartAt = null;
            _fillProgress = 0.0;
            _bounce = false;
          }
          _lastNoteName = newName;
          _displayedNote = _StableNoteState(
            noteName: noteName,
            frequency: f0,
            cents: errCents,
            timestamp: now,
          );

          // Update filling progress (kept, but does not gate display)
          final bool nearTarget = _qDisplay.abs() <= 1; // 0 or 1 step
          if (_isTuned) {
            _fillProgress = 1.0;
          } else if (nearTarget) {
            _fillStartAt ??= now;
            final elapsed =
                now.difference(_fillStartAt!).inMilliseconds.toDouble();
            _fillProgress = (elapsed / 2000.0).clamp(0.0, 1.0);
            if (_fillProgress >= 1.0) {
              _isTuned = true;
            }
          } else {
            if (!_isTuned) {
              _fillStartAt = null;
              _fillProgress = 0.0;
            }
          }
          if (_isTuned && !_bounce) {
            _bounce = true;
            Future.delayed(const Duration(milliseconds: 200), () {
              if (mounted) setState(() => _bounce = false);
            });
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop && mounted) context.go('/');
      },
      child: BlocProvider(
        create: (_) => SpectroidCubit()..start(),
        child: BlocListener<SpectroidCubit, SpectroidState>(
          listener: (context, state) {
            _updateNote(
              f0: state.f0Tracked,
              trackerState: state.trackerState,
              conf: state.confFused,
              peakDb: state.peakDb,
              peaks: state.debugPeaks,
            );
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(loc.tunerTitle),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => context.go('/'),
              ),
              actions: [
                IconButton(
                  tooltip: 'Réglages',
                  icon: const Icon(Icons.tune),
                  onPressed: _openSettings,
                ),
              ],
            ),
            body: SafeArea(
              child: Stack(
                children: [
                  // Main tuner UI shown only when locked
                  if (_isLocked)
                    Center(
                      child: _ChordRowTuner(
                        display: _displayedNote,
                        step: _qDisplay,
                        showPlusMinus: _showPlusMinus,
                        guidedTargets: _guidedTargets,
                      ),
                    ),
                  // Green lock frame overlay (same style as R&D), immediate
                  if (_showLockDisplay)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.15),
                          border: Border.all(color: Colors.green, width: 2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'LOCKED',
                              style: TextStyle(
                                color: Colors.green,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              (_displayedNote?.frequency ?? 0)
                                  .toStringAsFixed(2),
                              style: const TextStyle(
                                color: Colors.green,
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Text(
                              'Hz',
                              style: TextStyle(
                                color: Colors.green,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Paramètres d\'affichage',
                  style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 12),
              // Guided tuning section
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Guidage (accordage)',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Switch(
                    value: _guidanceEnabled,
                    onChanged: (v) async {
                      setState(() => _guidanceEnabled = v);
                      await _applyGuidanceConfig();
                    },
                  ),
                ],
              ),
              Row(
                children: [
                  const SizedBox(width: 160, child: Text('Accordage')),
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _tuningKey,
                      items: const [
                        DropdownMenuItem(
                          value: 'guitar_standard',
                          child: Text('Guitare (E2 A2 D3 G3 B3 E4)'),
                        ),
                      ],
                      onChanged: (k) async {
                        if (k == null) return;
                        setState(() => _tuningKey = k);
                        await _applyGuidanceConfig();
                      },
                    ),
                  ),
                ],
              ),
              const Divider(height: 24),
              Row(
                children: [
                  const SizedBox(
                      width: 160, child: Text('Pas de quantification (cents)')),
                  Expanded(
                    child: DropdownButton<double>(
                      isExpanded: true,
                      value: _qStepCents,
                      items: const [5.0, 10.0, 20.0]
                          .map((v) => DropdownMenuItem<double>(
                              value: v, child: Text(v.toStringAsFixed(0))))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _qStepCents = v ?? _qStepCents),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  const SizedBox(
                      width: 160, child: Text('Constante de lissage (ms)')),
                  Expanded(
                    child: Slider(
                      min: 50,
                      max: 500,
                      divisions: 18,
                      value: _smoothTauMs.clamp(50, 500),
                      label: _smoothTauMs.toStringAsFixed(0),
                      onChanged: (v) => setState(() => _smoothTauMs = v),
                    ),
                  ),
                ],
              ),
              SwitchListTile(
                title: const Text('Affichage ±step'),
                value: _showPlusMinus,
                onChanged: (v) => setState(() => _showPlusMinus = v),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _applyGuidanceConfig({double? windowCents}) async {
    // Build targets for selected tuning
    List<double> targets;
    switch (_tuningKey) {
      case 'guitar_standard':
      default:
        targets = const [
          82.4069, // E2
          110.0000, // A2
          146.8324, // D3
          195.9977, // G3
          246.9417, // B3
          329.6276, // E4
        ];
        _guidedTargets = const [
          _GuidedTarget('E2', 82.4069),
          _GuidedTarget('A2', 110.0000),
          _GuidedTarget('D3', 146.8324),
          _GuidedTarget('G3', 195.9977),
          _GuidedTarget('B3', 246.9417),
          _GuidedTarget('E4', 329.6276),
        ];
        break;
    }
    final cubit = context.read<SpectroidCubit>();
    final cfg = cubit.state.config;
    // Compute detection range if guidance enabled
    double pitchFMin = cfg.pitchFMin;
    double pitchFMax = cfg.pitchFMax;
    if (_guidanceEnabled && targets.isNotEmpty) {
      final sorted = [...targets]..sort();
      final minT = sorted.first;
      final maxT = sorted.last;
      final wc = windowCents ?? 100.0;
      final ratio = math.pow(2.0, wc / 1200.0).toDouble();
      pitchFMin = (minT / ratio).clamp(15.0, 12000.0);
      pitchFMax = (maxT * ratio).clamp(15.0, 12000.0);
    }
    await cubit.reconfigure(cfg.copyWith(
      guidanceEnabled: _guidanceEnabled,
      guidedTargetsHz: _guidanceEnabled ? targets : const [],
      guidanceWindowCents: windowCents ?? 100.0,
      guidanceBiasDb: 3.0,
      pitchFMin: pitchFMin,
      pitchFMax: pitchFMax,
    ));
  }
}

/// Horizontal chord row with a gold precision circle sweeping above
class _ChordRowTuner extends StatelessWidget {
  final _StableNoteState? display;
  final int step; // -5..+5
  final bool showPlusMinus;
  final List<_GuidedTarget> guidedTargets;
  const _ChordRowTuner({
    required this.display,
    required this.step,
    required this.showPlusMinus,
    required this.guidedTargets,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notes = guidedTargets.isNotEmpty
        ? guidedTargets
        : const [
            _GuidedTarget('E2', 82.4069),
            _GuidedTarget('A2', 110.0),
            _GuidedTarget('D3', 146.8324),
            _GuidedTarget('G3', 195.9977),
            _GuidedTarget('B3', 246.9417),
            _GuidedTarget('E4', 329.6276),
          ];

    // Compute nearest label and precise cents error
    String? activeLabel;
    double centsError = 0.0;
    if (display != null) {
      _GuidedTarget best = notes.first;
      double bestDiff = (display!.frequency - best.freq).abs();
      for (final t in notes) {
        final d = (display!.frequency - t.freq).abs();
        if (d < bestDiff) {
          best = t;
          bestDiff = d;
        }
      }
      activeLabel = best.label;
      // Calculate precise cents error vs target
      centsError = 1200.0 * (math.log(display!.frequency / best.freq) / math.ln2);
    }

    // Circle position and styling based on cents
    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth * 0.9;
        final leftPad = constraints.maxWidth * 0.05;
        
        // Map cents to position: -50¢ -> 0, 0¢ -> 0.5, +50¢ -> 1.0
        // Beyond ±50¢ clamp to edges
        final centsPos = ((centsError + 50.0) / 100.0).clamp(0.0, 1.0);
        final cx = leftPad + totalWidth * centsPos;
        final cy = 32.0; // moved higher up
        
        // Color coding: green at 0, gold within ±50, red beyond
        Color circleColor;
        Color textColor;
        Color haloColor;
        if (centsError.abs() <= 2.0) {
          // Perfect tuning: green
          circleColor = Colors.green;
          textColor = Colors.green;
          haloColor = Colors.green.withOpacity(0.15);
        } else if (centsError.abs() <= 50.0) {
          // Within range: gold
          circleColor = theme.colorScheme.secondary;
          textColor = theme.colorScheme.secondary;
          haloColor = theme.colorScheme.secondary.withOpacity(0.15);
        } else {
          // Out of range: red
          circleColor = Colors.red;
          textColor = Colors.red;
          haloColor = Colors.red.withOpacity(0.15);
        }
        
        final dotSize = 48.0;
        final shadow = Colors.black.withOpacity(0.10);
        
        // Format cents display
        String centsText;
        if (centsError.abs() > 50.0) {
          centsText = centsError > 0 ? '>50' : '<50';
        } else {
          final roundedCents = centsError.round();
          centsText = roundedCents == 0 ? '0' : '${roundedCents > 0 ? '+' : ''}${roundedCents}¢';
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: cy + dotSize + 16,
              width: constraints.maxWidth,
              child: Stack(
                children: [
                  // precision circle with halo (only when we have a display)
                  if (display != null)
                    Positioned(
                      left: cx - dotSize / 2,
                      top: cy - dotSize / 2,
                      child: Container(
                        width: dotSize,
                        height: dotSize,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: haloColor,
                          border: Border.all(color: circleColor, width: 2.5),
                          boxShadow: [
                            BoxShadow(color: shadow, blurRadius: 8, spreadRadius: 3),
                          ],
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          centsText,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                color: textColor,
                                fontWeight: FontWeight.w800,
                                fontSize: 13,
                              ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            // Row of chord notes
            Padding(
              padding: EdgeInsets.symmetric(horizontal: leftPad),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  for (final t in notes)
                    _NoteChip(
                      label: t.label,
                      active: t.label == activeLabel,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _NoteChip extends StatelessWidget {
  final String label;
  final bool active;
  const _NoteChip({required this.label, required this.active});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final baseColor = theme.colorScheme.onSurface;
    final highlight = theme.colorScheme.primary;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
      decoration: BoxDecoration(
        color: active ? baseColor.withOpacity(0.08) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: active ? Border.all(color: highlight, width: 2) : null,
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: baseColor,
              fontWeight: active ? FontWeight.w800 : FontWeight.w600,
              fontSize: active ? 28 : 22,
              letterSpacing: -0.5,
            ),
      ),
    );
  }
}

/// Affichage simplifié: cercle + note blanche, remplissage vert 2s quand proche
// Old circular display removed in favor of chord row with precision indicator
