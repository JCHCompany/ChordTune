import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../research/spectroid/spectroid_cubit.dart';
import '../../../app/l10n/l10n.dart';
import '../../../dsp/dominant_pitch_tracker.dart';
import '../widgets/tuner_needle_gauge.dart';
import '../../../app/app_theme.dart';

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
  DateTime _lastLockTime =
      DateTime.fromMillisecondsSinceEpoch(0); // pour maintien 200ms

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

  // Per-note tuning state
  final Map<String, bool> _noteTuned = {}; // true=green/tuned
  final Map<String, DateTime> _noteEnterZoneAt = {};
  final Map<String, DateTime> _noteExitZoneAt = {};

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
    // Gate: show only when locked; hide after 200ms hold
    final locked = trackerState.toLowerCase() == 'locked' && f0 > 0;
    final now = DateTime.now();

    if (!locked) {
      // Maintien de la dernière valeur pendant 200ms pour éviter le clignotement
      final timeSinceLastLock = now.difference(_lastLockTime).inMilliseconds;
      if (timeSinceLastLock > 200 && mounted) {
        setState(() {
          _isLocked = false;
          _showLockDisplay = false;
          _displayedNote = null;
          // Stop all animations when stability is lost
          _fillStartAt = null;
          _fillProgress = 0.0;
          _isTuned = false;
          _bounce = false;
          // Track exit for currently highlighted note
          if (_lastNoteName != null) {
            _noteExitZoneAt[_lastNoteName!] = DateTime.now();
          }
        });
      }
      return;
    } else {
      // Locked: mettre à jour le timestamp de dernier lock
      _lastLockTime = now;
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
    
    // Détection de changement de note pour reset du lissage
    final noteChanged = _lastNoteName != null && _lastNoteName != noteName;
    
    // RESET du lissage lors du premier lock ou changement de note
    // pour convergence immédiate au lieu de partir de 0
    if (_lastNoteName == null || noteChanged) {
      _errS = errCents; // Initialiser avec la vraie valeur
    }

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

    // Lissage adaptatif pour affichage stable et fluide
    // - Tau (temps de lissage) adapté selon confiance: 80-300ms
    // - Haute confiance -> lissage rapide (80ms) pour réactivité
    // - Basse confiance -> lissage lent (300ms) pour stabilité
    _lastConf = conf.clamp(0.0, 1.0);
    const tauMinMs = 80.0; // Réactif quand signal stable
    const tauMaxMs = 300.0; // Stable quand signal incertain
    double tauMs = (_smoothTauMs).clamp(tauMinMs, tauMaxMs);
    tauMs = tauMaxMs - (_lastConf * (tauMaxMs - tauMinMs));

    // EMA (Exponential Moving Average) pour lisser les cents
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

          // ═══════════════════════════════════════════════════════════════
          // AFFICHAGE DE DÉVIATION POUR L'UTILISATEUR
          // ═══════════════════════════════════════════════════════════════
          // Valeur entre -50 et +50, où 0 = note parfaitement accordée
          //
          // - Utilise _errS (lissé sur 80-300ms selon confiance du signal)
          // - Clampé à ±50 cents pour plage lisible et cohérente
          // - Arrondi à l'unité pour affichage propre: -7, -3, 0, +2, +9, etc.
          //
          // Références de précision:
          // - ±10 cents: Correct pour scène live
          // - ±5 cents: Seuil de perception moyenne de l'oreille humaine
          // - ±3 cents: Précision pro
          // - ±2 cents: Zone "accordée" (affichage vert) - Juste en studio
          // - ±1 cent: Quasi parfait (luthier)
          final displayCents = _errS.clamp(-50.0, 50.0).roundToDouble();

          _displayedNote = _StableNoteState(
            noteName: noteName,
            frequency: f0,
            cents: displayCents,
            timestamp: now,
          );

          // Zone "accordée": ±2 cents (précision professionnelle/studio)
          final inZone = displayCents.abs() <= 2.0;
          if (inZone) {
            _noteEnterZoneAt[noteName] ??= now;
            _noteExitZoneAt.remove(noteName);
            final enteredAt = _noteEnterZoneAt[noteName]!;
            if (now.difference(enteredAt).inMilliseconds >= 2000) {
              _noteTuned[noteName] = true; // turn green after 2s in zone
            }
          } else {
            _noteExitZoneAt[noteName] ??= now;
            final exitedAt = _noteExitZoneAt[noteName]!;
            if (now.difference(exitedAt).inMilliseconds >= 500) {
              _noteTuned[noteName] = false; // revert after 0.5s detuned
              _noteEnterZoneAt.remove(noteName);
            }
          }

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
                  // Main tuner UI
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Semicircle gauge; when not locked, shows mic+dots
                        Padding(
                          padding: const EdgeInsets.only(bottom: 20.0),
                          child: TunerNeedleGauge(
                            cents: _isLocked ? _displayedNote?.cents : null,
                            size: MediaQuery.of(context).size.width * 0.9,
                          ),
                        ),
                        _ChordRowTuner(
                          display: _displayedNote,
                          step: _qDisplay,
                          showPlusMinus: _showPlusMinus,
                          guidedTargets: _guidedTargets,
                          tuned: _noteTuned,
                          noteEnterZoneAt: _noteEnterZoneAt,
                        ),
                      ],
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

/// Horizontal chord row with always-visible notes and tuned state
class _ChordRowTuner extends StatelessWidget {
  final _StableNoteState? display;
  final int step; // -5..+5
  final bool showPlusMinus;
  final List<_GuidedTarget> guidedTargets;
  final Map<String, bool> tuned; // note label -> tuned state
  final Map<String, DateTime> noteEnterZoneAt; // note label -> enter time
  const _ChordRowTuner({
    required this.display,
    required this.step,
    required this.showPlusMinus,
    required this.guidedTargets,
    required this.tuned,
    required this.noteEnterZoneAt,
  });

  @override
  Widget build(BuildContext context) {
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
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final t in notes)
            _NoteChip(
              label: t.label,
              active: t.label == activeLabel,
              tuned: tuned[t.label] == true,
              inZone: t.label == activeLabel &&
                  display != null &&
                  display!.cents.abs() <= 2.0,
            ),
        ],
      ),
    );
  }
}

class _NoteChip extends StatefulWidget {
  final String label;
  final bool active;
  final bool tuned;
  final bool inZone; // true if active AND within ±4 cents
  const _NoteChip({
    required this.label,
    required this.active,
    required this.tuned,
    required this.inZone,
  });

  @override
  State<_NoteChip> createState() => _NoteChipState();
}

class _NoteChipState extends State<_NoteChip>
    with SingleTickerProviderStateMixin {
  AnimationController? _progressController;
  bool _wasInZone = false;

  @override
  void initState() {
    super.initState();
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
  }

  @override
  void dispose() {
    _progressController?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_NoteChip oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Start animation when entering zone (active + within ±4 cents)
    if (widget.inZone && !_wasInZone && !widget.tuned) {
      _progressController?.forward(from: 0.0);
      _wasInZone = true;
    }

    // Cancel animation if exiting zone before completion
    if (!widget.inZone && _wasInZone && !widget.tuned) {
      _progressController?.reset();
      _wasInZone = false;
    }

    // Complete animation immediately when tuned
    if (widget.tuned && !oldWidget.tuned) {
      _progressController?.value = 1.0;
      _wasInZone = false;
    }

    // Reset if no longer tuned or no longer active
    if ((!widget.tuned && oldWidget.tuned) ||
        (!widget.active && oldWidget.active)) {
      _progressController?.reset();
      _wasInZone = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tTheme = theme.extension<TunerTheme>();
    final baseColor = theme.colorScheme.onSurface;
    final gold = tTheme?.gold ?? theme.colorScheme.secondary;
    final green = tTheme?.green ?? Colors.green;

    // Scale up ONLY during active detection (not after tuned)
    final double scale = widget.active && !widget.tuned ? 1.08 : 1.0;

    // Font size transitions
    final double fontSize = widget.active && !widget.tuned ? 28 : 24;

    return AnimatedScale(
      scale: scale,
      duration: const Duration(milliseconds: 150),
      child: SizedBox(
        width: 50,
        height: 50,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Base border circle
            AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(
                  color: widget.tuned
                      ? green
                      : (widget.active ? gold : baseColor.withOpacity(0.3)),
                  width: widget.tuned ? 2.5 : (widget.active ? 2 : 1),
                ),
              ),
            ),
            // Green progress ring during validation (2s animation)
            // Only show when in zone and not yet tuned
            if (widget.inZone && !widget.tuned && _wasInZone)
              AnimatedBuilder(
                animation: _progressController!,
                builder: (context, child) {
                  return CustomPaint(
                    size: const Size(50, 50),
                    painter: _ProgressRingPainter(
                      progress: _progressController!.value,
                      color: green,
                      strokeWidth: 3.0,
                    ),
                  );
                },
              ),
            // Note label - GREEN when tuned
            Text(
              widget.label,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.bold,
                color: widget.tuned ? green : baseColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProgressRingPainter extends CustomPainter {
  final double progress;
  final Color color;
  final double strokeWidth;

  _ProgressRingPainter({
    required this.progress,
    required this.color,
    this.strokeWidth = 3.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    const startAngle = -math.pi / 2; // Start at top
    final sweepAngle = 2 * math.pi * progress;

    canvas.drawArc(rect, startAngle, sweepAngle, false, paint);
  }

  @override
  bool shouldRepaint(_ProgressRingPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

/// Affichage simplifié: cercle + note blanche, remplissage vert 2s quand proche
// Old circular display removed in favor of chord row with precision indicator
