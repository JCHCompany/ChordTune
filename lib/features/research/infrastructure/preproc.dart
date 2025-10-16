import 'dart:math' as math;
import 'dart:typed_data';
import '../domain/interfaces.dart';

class BasicPreproc implements IAudioPreproc {
  final double hpfCut;
  final double lpfCut;
  const BasicPreproc({this.hpfCut = 70.0, this.lpfCut = 3000.0});

  @override
  Float32List process(Float32List x, int fs) {
    final out = Float32List.fromList(x);
    // DC blocker + HPF 1er ordre + LPF 1er ordre
    double ydc = 0, xprev = 0, yhp = 0, ylp = 0;
    final hpA = _hpAlpha(hpfCut, fs);
    final lpB = _lpBeta(lpfCut, fs);
    for (int i = 0; i < out.length; i++) {
      final xi = out[i];
      // DC block (leaky integrator)
      ydc = 0.995 * ydc + xi - xprev;
      xprev = xi;
      // HPF
      yhp = hpA * (yhp + ydc - (i > 0 ? out[i - 1] : 0.0));
      // LPF
      ylp = ylp + lpB * (yhp - ylp);
      out[i] = ylp;
    }
    // Normalize RMS to ~ -12 dBFS (optional simple)
    double rms = 0.0;
    for (final v in out) {
      rms += v * v;
    }
    rms = math.sqrt(rms / out.length);
    final target = 0.25; // ~ -12 dBFS
    if (rms > 1e-6) {
      final g = target / rms;
      for (int i = 0; i < out.length; i++) {
        out[i] *= g.clamp(0.25, 4.0);
      }
    }
    return out;
  }

  double _hpAlpha(double cutoff, int fs) {
    final rc = 1.0 / (2 * math.pi * cutoff);
    final dt = 1.0 / fs;
    return rc / (rc + dt);
  }

  double _lpBeta(double cutoff, int fs) {
    final rc = 1.0 / (2 * math.pi * cutoff);
    final dt = 1.0 / fs;
    return dt / (rc + dt);
  }
}

// --- Realtime DSP preprocessor with HPF/LPF/Notch and AGC freeze rules ---

class _Biquad {
  double a0 = 1, a1 = 0, a2 = 0, b1 = 0, b2 = 0;
  double z1 = 0, z2 = 0;
  void setLowpass(double fs, double fc, double q) {
    final w0 = 2 * math.pi * fc / fs;
    final alpha = math.sin(w0) / (2 * q);
    final c = math.cos(w0);
    final b0 = (1 - c) / 2;
    final b1n = 1 - c;
    final b2n = (1 - c) / 2;
    final a0n = 1 + alpha;
    final a1n = -2 * c;
    final a2n = 1 - alpha;
    a0 = b0 / a0n; 
    a1 = b1n / a0n; 
    a2 = b2n / a0n; 
    b1 = a1n / a0n; 
    b2 = a2n / a0n;
  }
  void setHighpass(double fs, double fc, double q) {
    final w0 = 2 * math.pi * fc / fs;
    final alpha = math.sin(w0) / (2 * q);
    final c = math.cos(w0);
    final b0 = (1 + c) / 2;
    final b1n = -(1 + c);
    final b2n = (1 + c) / 2;
    final a0n = 1 + alpha;
    final a1n = -2 * c;
    final a2n = 1 - alpha;
    a0 = b0 / a0n; 
    a1 = b1n / a0n; 
    a2 = b2n / a0n; 
    b1 = a1n / a0n; 
    b2 = a2n / a0n;
  }
  void setNotch(double fs, double f0, double q) {
    final w0 = 2 * math.pi * f0 / fs;
    final alpha = math.sin(w0) / (2 * q);
    final c = math.cos(w0);
    final b0 = 1.0;
    final b1n = -2 * c;
    final b2n = 1.0;
    final a0n = 1 + alpha;
    final a1n = -2 * c;
    final a2n = 1 - alpha;
    a0 = b0 / a0n; 
    a1 = b1n / a0n; 
    a2 = b2n / a0n; 
    b1 = a1n / a0n; 
    b2 = a2n / a0n;
  }
  double process(double x) {
    final y = a0 * x + z1;
    z1 = a1 * x - b1 * y + z2;
    z2 = a2 * x - b2 * y;
    return y;
  }
}

class RealtimePreproc implements IAudioPreproc {
  final int fs;
  final int mainsHz; // 50 or 60
  final bool useNotch;
  final double hpfCut;
  final double lpfCut;
  final double targetRms; // linear target amplitude (~ -12 dBFS ≈ 0.25)

  // DC blocker (leaky integrator)
  double _ydc = 0, _xprev = 0;
  final double _dcR = 0.995;

  // Filters
  final _Biquad _hpf = _Biquad();
  final _Biquad _lpf = _Biquad();
  final _Biquad _notch1 = _Biquad();
  final _Biquad _notch2 = _Biquad();

  // AGC state
  double _agcGain = 1.0;
  bool _agcFrozen = false;

  RealtimePreproc({
    required this.fs,
    this.mainsHz = 50,
    this.useNotch = true,
    this.hpfCut = 70.0,
    this.lpfCut = 3000.0,
    this.targetRms = 0.25,
  }) {
    _design();
  }

  void _design() {
    _hpf.setHighpass(fs.toDouble(), hpfCut, 0.707);
    _lpf.setLowpass(fs.toDouble(), lpfCut, 0.707);
    if (useNotch) {
      _notch1.setNotch(fs.toDouble(), mainsHz.toDouble(), 25.0);
      _notch2.setNotch(fs.toDouble(), (2 * mainsHz).toDouble(), 30.0);
    }
  }

  @override
  Float32List process(Float32List x, int sampleRate) {
    if (sampleRate != fs) {
      // Recompute if ever FS changes
      _design();
    }
    final out = Float32List(x.length);
    for (int i = 0; i < x.length; i++) {
      final xi = x[i];
      _ydc = _dcR * _ydc + xi - _xprev; // DC block
      _xprev = xi;
      double y = _ydc;
      y = _hpf.process(y);
      if (useNotch) {
        y = _notch1.process(y);
        y = _notch2.process(y);
      }
      y = _lpf.process(y);
      out[i] = y;
    }
    // RMS measure pre-AGC
    double sum = 0.0;
    for (final v in out) {
      sum += v * v;
    }
    final rms = math.sqrt(sum / out.length);
    final rmsDb = 20 * math.log(rms + 1e-12) / math.ln10;

    // AGC freeze/open
    if (rmsDb < -50.0) {
      _agcFrozen = true;
    } else if (rmsDb >= -45.0) {
      _agcFrozen = false;
    }
    if (!_agcFrozen && rms > 1e-6) {
      final gTarget = (targetRms / rms).clamp(0.25, 4.0);
      _agcGain = 0.9 * _agcGain + 0.1 * gTarget; // gentle
    }
    for (int i = 0; i < out.length; i++) {
      out[i] *= _agcGain;
    }
    return out;
  }
}