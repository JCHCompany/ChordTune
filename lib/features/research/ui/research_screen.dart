import 'dart:async';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import '../spectroid/spectroid_cubit.dart';
// import '../spectroid/spectroid_config.dart';
import '../spectroid/spectrum_painter.dart';
import '../spectroid/spectroid_settings_page.dart';
import '../spectroid/audio_dsp.dart';

class ResearchScreen extends StatefulWidget {
  const ResearchScreen({super.key});

  @override
  State<ResearchScreen> createState() => _ResearchScreenState();
}

class _ResearchScreenState extends State<ResearchScreen> {
  Timer? _lockDisplayTimer;
  bool _showLockDisplay = false;
  String _lastTrackerState = '';
  double _lastF0Tracked = 0.0;

  @override
  void initState() {
    super.initState();
    // Keep screen awake while in research mode
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    _lockDisplayTimer?.cancel();
    // Allow device to sleep when leaving screen
    WakelockPlus.disable();
    super.dispose();
  }

  void _updateLockDisplay(String trackerState, double f0Tracked) {
    final isLocked = trackerState.toLowerCase() == 'locked';
    final f0Changed =
        (f0Tracked - _lastF0Tracked).abs() > 1.0; // Plus de 1Hz de changement

    if (isLocked && (_lastTrackerState != 'locked' || f0Changed)) {
      // Nouveau lock ou changement de fréquence → Reset du timer
      _lockDisplayTimer?.cancel();
      setState(() {
        _showLockDisplay = false;
      });

      _lockDisplayTimer = Timer(const Duration(milliseconds: 500), () {
        if (mounted) {
          setState(() {
            _showLockDisplay = true;
          });
        }
      });
    } else if (!isLocked) {
      // Plus locké → Hide immédiatement
      _lockDisplayTimer?.cancel();
      setState(() {
        _showLockDisplay = false;
      });
    }

    _lastTrackerState = trackerState;
    _lastF0Tracked = f0Tracked;
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => SpectroidCubit()..start(),
      child: BlocListener<SpectroidCubit, SpectroidState>(
        listener: (context, state) {
          // Gère le délai d'affichage du cadre vert en dehors du build
          _updateLockDisplay(state.trackerState, state.f0Tracked);
        },
        child: PopScope(
          canPop: false,
          onPopInvoked: (didPop) {
            if (!didPop && mounted) {
              context.go('/');
            }
          },
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Spectroid'),
              actions: [
                Builder(builder: (context) {
                  final st = context.watch<SpectroidCubit>().state;
                  final cfg = st.config;
                  // Fixed unit label per requirement
                  final unit = 'dBFS/Hz';
                  final decim = cfg.firDecimation;
                  final decimText = decim > 1 ? ' (×$decim décim)' : '';
                  final hzPerBin = st.effectiveSampleRate > 0 && cfg.fftSize > 0
                      ? (st.effectiveSampleRate / cfg.fftSize)
                          .toStringAsFixed(1)
                      : '—';
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                          'FS eff: ${st.effectiveSampleRate} Hz$decimText · Hz/bin@DC: $hzPerBin · $unit'),
                    ),
                  );
                }),
                Builder(builder: (context) {
                  return IconButton(
                    tooltip: 'Réglages',
                    icon: const Icon(Icons.settings),
                    onPressed: () async {
                      final cubit = context.read<SpectroidCubit>();
                      final cfg = cubit.state.config;
                      await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => SpectroidSettingsPage(
                          initialConfig: cfg,
                          onApply: (next) => cubit.reconfigure(next),
                        ),
                      ));
                    },
                  );
                }),
              ],
            ),
            body: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final st = context.watch<SpectroidCubit>().state;
                  final cfg = st.config;
                  return Stack(
                    children: [
                      // Audio status display at the top
                      Positioned(
                        top: 8,
                        left: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Theme.of(context)
                                .colorScheme
                                .surface
                                .withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color: Theme.of(context)
                                    .colorScheme
                                    .outline
                                    .withValues(alpha: 0.2)),
                          ),
                          child:
                              _AudioStatusWidget(audioStatus: st.audioStatus),
                        ),
                      ),
                      // Pitch chips column for stable alignment
                      Positioned(
                        top: 58,
                        left: 8,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _pitchChip('YIN', st.f0Yin, st.confYin),
                            SizedBox(height: 6),
                            _pitchChip('Harm', st.f0Harm, st.confHarm),
                            SizedBox(height: 6),
                            _pitchChip('Fusion', st.f0Fused, st.confFused),
                            SizedBox(height: 6),
                            // Final tracked f0 + state chip
                            _pitchChip(
                              st.trackerState.toUpperCase(),
                              st.f0Tracked,
                              st.confFused,
                            ),
                            const SizedBox(height: 6),
                            if (st.f0Tracked > 0)
                              Text(
                                'f0: ${st.f0Tracked.toStringAsFixed(2)} Hz',
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12),
                              ),
                            const SizedBox(height: 6),
                            // Debug overlay for dominant tracker
                            if (st.debugPeaks.isNotEmpty) ...[
                              const Text('Top Peaks:',
                                  style: TextStyle(
                                      color: Colors.white70, fontSize: 10)),
                              for (int i = 0;
                                  i < st.debugPeaks.length.clamp(0, 3);
                                  i++)
                                Text(
                                  '${(i + 1)}: ${st.debugPeaks[i].freq.toStringAsFixed(2)}Hz, ${st.debugPeaks[i].snr.toStringAsFixed(1)}dB',
                                  style: const TextStyle(
                                      color: Colors.white60, fontSize: 9),
                                ),
                            ],
                            if (st.lockReason.isNotEmpty)
                              Text(
                                st.lockReason,
                                style: const TextStyle(
                                    color: Colors.white60, fontSize: 9),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            if (st.predictedF0 > 0)
                              Text(
                                'Pred: ${st.predictedF0.toStringAsFixed(2)}Hz, W±${st.currentWindow.toStringAsFixed(0)}¢',
                                style: const TextStyle(
                                    color: Colors.white60, fontSize: 9),
                              ),
                            // EMA Alpha display - shows freeze state
                            const SizedBox(height: 4),
                            Builder(
                              builder: (context) {
                                final alpha = cfg.emaAlphaAmp;
                                final isFrozen = alpha < 0.1;
                                return Text(
                                  'EMA α: ${alpha.toStringAsFixed(3)}${isFrozen ? ' ⚠️ FREEZE' : ''}',
                                  style: TextStyle(
                                      color: isFrozen
                                          ? Colors.red
                                          : Colors.white60,
                                      fontSize: 10,
                                      fontWeight: isFrozen
                                          ? FontWeight.bold
                                          : FontWeight.normal),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      // Lock Display - Fixed Green Frame on Right when locked (with 0.5s delay)
                      if (_showLockDisplay)
                        Positioned(
                          top: 58,
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
                                Text(
                                  'LOCKED',
                                  style: TextStyle(
                                    color: Colors.green,
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '${st.f0Tracked.toStringAsFixed(2)}',
                                  style: TextStyle(
                                    color: Colors.green,
                                    fontSize: 28,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
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
                      // Centered spectrum at 50% of screen height
                      Positioned.fill(
                        child: Padding(
                          padding: const EdgeInsets.only(
                              top: 110), // Make room for status + chips
                          child: Center(
                            child: SizedBox(
                              width: constraints.maxWidth,
                              height: constraints.maxHeight * 0.5,
                              child: st.spectrum == null
                                  ? const Center(child: Text('Initialisation…'))
                                  : CustomPaint(
                                      painter: SpectrumPainter(
                                        magLinear: st.spectrum!,
                                        // Use the actual effective sample rate used by the engine for FFT,
                                        // not the target resample setting (which may not be applied).
                                        fs: st.effectiveSampleRate,
                                        fMax: cfg.displayBandMax,
                                        emaAlphaAmp: cfg.emaAlphaAmp,
                                        peakFreqHz: st.peakFreqHz,
                                        displayUnit: 'dBFS/Hz',
                                        spectroidMode: cfg.spectroidMode,
                                        f0Tracked: st.f0Tracked,
                                        overlayCentsBand: cfg.overlayCentsBand,
                                        trackerState: st.trackerState,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                      // Band buttons anchored to bottom
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: const [
                              _BandButton(4000),
                              SizedBox(width: 8),
                              _BandButton(8000),
                              SizedBox(width: 8),
                              _BandButton(20000),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ), // Fermeture du BlocListener
    );
  }
}

class _BandButton extends StatelessWidget {
  final int hz;
  const _BandButton(this.hz);

  @override
  Widget build(BuildContext context) {
    final cfg = context.watch<SpectroidCubit>().state.config;
    final selected = cfg.displayBandMax == hz;
    return ChoiceChip(
      label: Text('${hz >= 1000 ? '${(hz / 1000).toStringAsFixed(0)}k' : hz}'),
      selected: selected,
      onSelected: (_) => context.read<SpectroidCubit>().setDisplayBandMax(hz),
    );
  }
}

class _AudioStatusWidget extends StatelessWidget {
  final AudioEffectStatus audioStatus;
  const _AudioStatusWidget({required this.audioStatus});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textStyle = theme.textTheme.bodySmall;

    return Row(
      children: [
        Icon(
          Icons.mic,
          size: 16,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Row(
            children: [
              Text('Source: ', style: textStyle),
              Text(
                audioStatus.unprocessedAvailable
                    ? 'UNPROCESSED'
                    : 'VOICE_RECOGNITION',
                style: textStyle?.copyWith(
                  color: audioStatus.unprocessedAvailable
                      ? Colors.green
                      : Colors.orange,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 16),
              Text('AGC:', style: textStyle),
              Text(
                audioStatus.agcDisabled ? 'OFF' : 'ON',
                style: textStyle?.copyWith(
                  color: audioStatus.agcDisabled ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              Text('NS:', style: textStyle),
              Text(
                audioStatus.nsDisabled ? 'OFF' : 'ON',
                style: textStyle?.copyWith(
                  color: audioStatus.nsDisabled ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 8),
              Text('AEC:', style: textStyle),
              Text(
                audioStatus.aecDisabled ? 'OFF' : 'ON',
                style: textStyle?.copyWith(
                  color: audioStatus.aecDisabled ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Widget _pitchChip(String label, double f0, double conf) {
  final has = f0 > 0 && conf > 0;
  final text = has
      ? '${f0.toStringAsFixed(2)} Hz (${(conf * 100).toStringAsFixed(0)}%)'
      : '—';
  return Chip(
    label: Text('$label: $text'),
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    visualDensity: VisualDensity.compact,
  );
}
