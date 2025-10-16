class PitchFusionResult {
  final double f0;
  final double confidence;
  const PitchFusionResult(this.f0, this.confidence);
}

class PitchFusion {
  final double wYin;
  final double wHarm;
  final bool antiOctaveEnabled;
  final double subharmThresh;

  PitchFusion({
    required this.wYin,
    required this.wHarm,
    required this.antiOctaveEnabled,
    required this.subharmThresh,
  });

  PitchFusionResult fuse(double fYin, double cYin, double fHarm, double cHarm) {
    if (fYin <= 0 && fHarm <= 0) return const PitchFusionResult(0.0, 0.0);
    
    // Standard weighted fusion with confidence weighting
    final totalW = (cYin * wYin) + (cHarm * wHarm) + 1e-12;
    double f = 0.0;
    if (fYin > 0) f += fYin * cYin * wYin;
    if (fHarm > 0) f += fHarm * cHarm * wHarm;
    f /= totalW;
    double conf = (cYin * wYin + cHarm * wHarm) / (wYin + wHarm);
    
    // CORRECTION: Respecter les poids mais gérer les cas extrêmes
    
    // Si YIN a une confiance très élevée (>0.9) et Harmonic détecte un octave → privilégier YIN
    if (cYin > 0.9 && fYin > 0 && fHarm > 0) {
      final ratio = fHarm / fYin;
      if (ratio > 1.8 && ratio < 2.2) { // Harmonic détecte l'octave
        // YIN est très sûr du fondamental, Harmonic détecte l'octave → Force YIN
        f = fYin;
        conf = cYin;
        return PitchFusionResult(f, conf.clamp(0.0, 1.0));
      }
    }
    
    // Anti-octave: ajuster légèrement la fusion si détection d'octave possible
    if (antiOctaveEnabled && f > 0 && fHarm > 0 && fYin > 0) {
      final ratio = fYin > fHarm ? fYin / fHarm : fHarm / fYin;
      
      // Détection possible d'octave (ratio ~2.0) → favoriser le plus grave
      if (ratio > 1.8 && ratio < 2.2) {
        final fLower = fYin < fHarm ? fYin : fHarm;
        
        // Appliquer un biais vers la fondamentale (fréquence plus grave)
        // Mais TOUJOURS respecter les poids configurés
        final gravityBias = 0.25; // 25% de biais vers fondamentale (augmenté)
        final biasWeight = fYin < fHarm ? (wYin * gravityBias) : (wHarm * gravityBias);
        
        // Recalculer avec biais mais conserver la logique des poids
        final adjustedTotalW = totalW + biasWeight * (cYin + cHarm) * 0.5;
        f = (f * totalW + fLower * biasWeight * (cYin + cHarm) * 0.5) / adjustedTotalW;
      }
    }
    
    return PitchFusionResult(f, conf.clamp(0.0, 1.0));
  }
}
