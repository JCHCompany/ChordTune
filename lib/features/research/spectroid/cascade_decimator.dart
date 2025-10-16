import 'dart:math' as math;
import 'package:flutter/foundation.dart';

/// Décimateur cascade efficace pour remplacer DecimatorFIR monolithique
/// Utilise des stages multiples (×2, ×4, ×8) pour réduire la charge computationnelle
class CascadeDecimator {
  final int totalFactor; // facteur de décimation total (ex: 32)
  final List<_SingleStageDecimator> _stages = [];
  
  CascadeDecimator({required this.totalFactor}) {
    _buildCascade();
  }

  void _buildCascade() {
    // Décompose le facteur total en facteurs premiers optimaux
    int remaining = totalFactor;
    
    // Priorité aux facteurs de 2, 4, 8 pour efficacité maximale
    while (remaining > 1) {
      if (remaining >= 8 && remaining % 8 == 0) {
        _stages.add(_SingleStageDecimator(factor: 8));
        remaining ~/= 8;
      } else if (remaining >= 4 && remaining % 4 == 0) {
        _stages.add(_SingleStageDecimator(factor: 4));
        remaining ~/= 4;
      } else if (remaining >= 2 && remaining % 2 == 0) {
        _stages.add(_SingleStageDecimator(factor: 2));
        remaining ~/= 2;
      } else {
        // Pour les facteurs premiers impairs, utiliser un stage direct
        _stages.add(_SingleStageDecimator(factor: remaining));
        remaining = 1;
      }
    }
    
    debugPrint('CascadeDecimator: Facteur total ×$totalFactor décomposé en ${_stages.length} stages: ${_stages.map((s) => '×${s.factor}').join(' → ')}');
  }

  /// Traite un échantillon à travers la cascade
  /// Returns null si pas d'output disponible, sinon l'échantillon décimé
  double? processSample(double input) {
    double current = input;
    
    // Propage à travers chaque stage de la cascade
    for (final stage in _stages) {
      final output = stage.processSample(current);
      if (output == null) {
        return null; // Stage pas prêt, pas d'output final
      }
      current = output;
    }
    
    return current; // Tous les stages ont produit un output
  }

  /// Réinitialise tous les buffers internes
  void reset() {
    for (final stage in _stages) {
      stage.reset();
    }
  }
}

/// Stage de décimation simple optimisé pour facteurs 2, 4, 8
class _SingleStageDecimator {
  final int factor;
  late final Float32List _coeffs;
  late final Float32List _buffer;
  int _bufferIndex = 0;
  int _phaseCounter = 0;

  _SingleStageDecimator({required this.factor}) {
    _coeffs = _generateOptimizedCoeffs(factor);
    _buffer = Float32List(_coeffs.length);
  }

  /// Génère des coefficients FIR optimisés pour chaque facteur
  /// Utilise des cutoffs plus agressifs pour reproduire l'effet DecimatorFIR original
  Float32List _generateOptimizedCoeffs(int M) {
    switch (M) {
      case 2:
        // FIR plus agressif pour décimation ×2 (reproduire effet original)
        return Float32List.fromList(_designFIR(33, 0.45 / 2, 8.6)); // ~129/4 taps, cutoff original
      case 4:
        // FIR plus agressif pour décimation ×4  
        return Float32List.fromList(_designFIR(49, 0.45 / 4, 8.6)); // ~129/2.6 taps, cutoff original
      case 8:
        // FIR très agressif pour décimation ×8 (reproduire suppression basses fréq)
        return Float32List.fromList(_designFIR(65, 0.45 / 8, 8.6)); // ~129/2 taps, cutoff original
      default:
        // Pour facteurs inhabituels, utilise la formule DecimatorFIR originale
        final taps = math.min(129, (M * 16 + 1)); // Plus conservateur mais efficace
        return Float32List.fromList(_designFIR(taps, 0.45 / M, 8.6)); // Même cutoff que l'original
    }
  }

  /// Design FIR lowpass avec Kaiser window (version optimisée)
  List<double> _designFIR(int N, double fc, double beta) {
    final h = List<double>.filled(N, 0.0);
    final center = (N - 1) / 2.0;
    final besselDenom = _modifiedBessel0(beta);
    
    for (int n = 0; n < N; n++) {
      // Kaiser window
      final arg = 2.0 * (n - center) / (N - 1);
      final kaiser = _modifiedBessel0(beta * math.sqrt(1 - arg * arg)) / besselDenom;
      
      // Sinc function centered
      final k = n - center;
      final sinc = (k.abs() < 1e-10) 
          ? 2 * fc 
          : math.sin(2 * math.pi * fc * k) / (math.pi * k);
      
      h[n] = kaiser * sinc;
    }
    
    // Normalize for unity DC gain
    final dcGain = h.reduce((a, b) => a + b);
    for (int i = 0; i < N; i++) {
      h[i] /= dcGain;
    }
    
    return h;
  }

  /// Modified Bessel function I0 (optimized)
  double _modifiedBessel0(double x) {
    final ax = x.abs();
    if (ax < 3.75) {
      final t = (x / 3.75) * (x / 3.75);
      return 1.0 + t * (3.5156229 + 
             t * (3.0899424 + 
             t * (1.2067492 + 
             t * (0.2659732 + 
             t * (0.0360768 + 
             t * 0.0045813)))));
    } else {
      final t = 3.75 / ax;
      return (math.exp(ax) / math.sqrt(ax)) * 
             (0.39894228 + t * (0.01328592 + 
              t * (0.00225319 + t * (-0.00157565 + 
              t * (0.00916281 + t * (-0.02057706 + 
              t * (0.02635537 + t * (-0.01647633 + 
              t * 0.00392377))))))));
    }
  }

  double? processSample(double input) {
    // Circular buffer insertion
    _buffer[_bufferIndex] = input;
    _bufferIndex = (_bufferIndex + 1) % _buffer.length;
    
    _phaseCounter++;
    if (_phaseCounter % factor != 0) {
      return null; // Pas encore temps pour output
    }
    
    // Convolution (circular buffer)
    double output = 0.0;
    int bufIdx = _bufferIndex; // Points to oldest sample
    
    for (int i = 0; i < _coeffs.length; i++) {
      if (--bufIdx < 0) bufIdx = _buffer.length - 1;
      output += _coeffs[i] * _buffer[bufIdx];
    }
    
    return output;
  }

  void reset() {
    _buffer.fillRange(0, _buffer.length, 0.0);
    _bufferIndex = 0;
    _phaseCounter = 0;
  }
}