# ChordTune – Tuner pipeline

This document summarizes the DSP + ML pipeline, defaults, and how to validate.

## Overview

- Capture: microphone raw PCM16, 48 kHz preferred, Android requests `UNPROCESSED` source and disables AGC/NS/AEC when possible.
- Pre: optional DC blocker (IIR) and optional 50/60 Hz notch.
- Multi-rate decimation: 0–9 stages (2x each) with 63-tap FIR anti-alias per stage (Hann-windowed sinc). Preserves PSD density.
- Window: Hann.
- FFT: in-place Radix-2, single-sided power spectrum, normalized by N, DC/Nyquist not doubled.
- PSD: power to dB/Hz with Hann ENBW correction (~1.5 bins) and window power normalization.
- Smoothing: EMA in linear power, conversion to dB for UI only.
- f0 detection: YIN (time-domain) + Harmonic Summation (frequency-domain) with fusion (weights configurable).
- Tracking: alpha–beta on cents with SEARCH/LOCKED/FROZEN states. Lock window ±cents, SNR thresholds, hold-in/out, max jumps. Fundamental rescue (divide by 2/3) heuristic.
- Transient Shield: detects bursts using spectral flux, flatness and harmonicity drop; freezes output for shieldMs and uses predictor.

## Defaults

- Decimation levels: 2 (4x). FFT size: 4096. EMA: 150 ms.
- YIN window: 2048, fmin=55 Hz, fmax=1100 Hz, thr=0.12.
- Harmonics: 4, tolerance 15 cents. Fusion: YIN 0.6 / Harm 0.4.
- Tracking: lock ±15 cents, SNR enter/exit 8/4 dB, hold-in/out 200/400 ms, max jump locked/search 60/200 cents, shield 120 ms.

## UI

- Simple view: large f0, cents error, stability bar, state badge (SEARCH/LOCKED/SHIELD).
- Scientific view: live spectrum plot, f0 marker, SNR/flux/flatness/YIN chips. Live sliders can be added later (architecture ready).

## Validation

Run locally:

```
flutter pub get
flutter analyze
flutter test
```

Open the app and tap “Open Tuner” to switch between views with the top-right toggle.

## Notes

- Power vs amplitude: all PSD uses power and 10*log10.
- DC/Nyquist: no doubling at edges, window normalization applied.
- Decimation: FIR always applied before downsampling.
- EMA is in linear domain; convert to dB only for display.
- Performance: all heavy math pre-allocates buffers and avoids dynamic allocations in the audio callback path.

## Troubleshooting

- Low bass wobble: increase decimation level and/or FFT size.
- Aliasing: ensure decimation stages are enabled; increase FIR taps if needed.
- Unstable lock: widen lock window a bit and increase hold-in time; check SNR.
