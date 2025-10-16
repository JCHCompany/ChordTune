# Test du Comportement Lock - Corrections Appliquées

## Problèmes identifiés par l'utilisateur
1. **Always locked au démarrage** - L'app démarre toujours en mode locked au lieu de search
2. **Valeurs incorrectes en preset accordeur** - Les valeurs finales ne sont pas les bonnes 
3. **Convergence lente en preset spectre** - Trop lent à converger sur la note jouée

## Corrections appliquées

### 1. Validation stricte des pics (`isPeakValid`)
```dart
final isPeakValid = bestPeak.snr >= lockThresholdDb && 
                   bestPeak.freq >= fMin && 
                   bestPeak.freq <= fMax &&
                   bestPeak.prominence >= peakProminenceDb;
```

### 2. Réinitialisation en mode search si pas de pic valide
```dart
if (!isPeakValid) {
    _lockTimer = 0;
    _currentF0 = 0.0; // Réinitialiser si pas de pic valide
    _lastLockReason = "No valid peak: SNR ${bestPeak.snr.toStringAsFixed(1)} dB < $lockThresholdDb dB or prominence ${bestPeak.prominence.toStringAsFixed(1)} < $peakProminenceDb dB";
}
```

### 3. Vérification de cohérence d'état au démarrage
```dart
// Vérification de cohérence d'état au démarrage
if (_currentF0 <= 0.0 && _state == DominantTrackerState.locked) {
    _state = DominantTrackerState.search; // Force reset si incohérent
    _lockTimer = 0;
    _unlockTimer = 0;
    _velocityCentsPerS = 0.0;
    _lastLockReason = "State reset: locked with f0=0";
}
```

### 4. Consistance checking pendant search
```dart
// Vérification de consistance : si le pic change trop, restart
if (_lockTimer > 0 && _currentF0 > 0) {
    final deltaCents = 1200.0 * math.log(bestPeak.freq / _currentF0).abs() / math.ln2;
    if (deltaCents > 200.0) { // Plus de 200 cents de changement = restart
        _lockTimer = frameDurationMs; // Restart le timer
        _lastLockReason = "Peak inconsistent: ${deltaCents.toStringAsFixed(0)} cents jump, restarting lock timer";
    }
}
```

### 5. Paramètres preset optimisés

**Preset Accordeur** (stabilité/précision):
- `dominantLockThresholdDb: 15.0` // Plus restrictif
- `dominantUnlockThresholdDb: 8.0`
- `dominantHoldInMs: 800` // Confirmation lente pour stabilité
- `dominantHoldOutMs: 150` // Unlock rapide pour réactivité  
- `dominantLockWindowCents: 30.0` // Fenêtre plus petite pour précision
- `dominantMaxJumpCentsPerS: 50.0` // Moins de variation

**Preset Spectre** (réactivité/exploration):
- `dominantLockThresholdDb: 10.0` // Moins restrictif pour réactivité
- `dominantUnlockThresholdDb: 5.0`
- `dominantHoldInMs: 300` // Plus rapide pour suivi temps réel
- `dominantHoldOutMs: 200`
- `dominantLockWindowCents: 80.0` // Fenêtre plus large pour exploration
- `dominantMaxJumpCentsPerS: 120.0` // Plus de liberté de mouvement

## Comment tester

1. **Vérifier startup en search**: Au démarrage de l'app, l'état devrait être `search` et non `locked`

2. **Tester preset accordeur**: 
   - Jouer une note de guitare
   - Vérifier que le lock prend plus de temps (800ms) mais donne une valeur stable et précise
   - Vérifier que les sauts de fréquence sont limités (±50 cents/s max)

3. **Tester preset spectre**:
   - Jouer une note et faire des bends
   - Vérifier que ça suit plus rapidement (300ms pour lock)
   - Vérifier que ça peut suivre des changements plus rapides (±120 cents/s)

4. **Tester transitions**:
   - Passer du silence au son → ne devrait pas locker immédiatement sur du bruit
   - Utiliser des notes faibles → ne devrait locker que si SNR suffisant (15dB pour accordeur, 10dB pour spectre)

## Résultat attendu

- ✅ Plus de "always locked" au démarrage
- ✅ Preset accordeur: valeurs stables et précises, pas de faux locks
- ✅ Preset spectre: suivi réactif mais pas trop sensible au bruit
- ✅ Validation stricte empêche les locks sur le bruit
- ✅ Consistency checking empêche les sauts erratiques pendant l'acquisition du lock