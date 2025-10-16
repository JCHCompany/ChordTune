# Fix: Problème "Locked Never Unlocks" 

## 🚨 Problèmes identifiés

### 1. **Calcul incorrect du meilleur SNR**
**Problème** : Le code utilisait `peaks.first.snr` pour déterminer le meilleur SNR disponible, mais les pics sont triés par `totalScore`, pas par `snr`.

```dart
// AVANT (incorrect)
final bestAvailableSnr = peaks.isNotEmpty ? peaks.first.snr : -120.0;

// APRÈS (correct) 
final bestAvailableSnr = peaks.isNotEmpty ? 
  peaks.map((p) => p.snr).reduce(math.max) : -120.0;
```

### 2. **Reset systématique du timer unlock**
**Problème** : Dès qu'un pic était trouvé dans la fenêtre de tracking (même faible), `_unlockTimer` était remis à 0, empêchant l'unlock même avec un signal dégradé.

```dart
// AVANT (problématique)
if (selectedPeak != null) {
  _unlockTimer = 0; // Reset systématique
}

// APRÈS (intelligent)
if (selectedPeak != null) {
  if (selectedPeak.snr >= unlockThresholdDb) {
    _unlockTimer = 0;  // Reset seulement si le signal est fort
  } else {
    _unlockTimer += frameDurationMs; // Construire unlock même en trackant un pic faible
  }
}
```

### 3. **Pas de force unlock**
**Problème** : Si le système trackait continuellement des pics faibles, il ne se forçait jamais à unlock.

```dart
// AJOUTÉ : Force unlock après 2x holdOut
final shouldUnlock = (bestAvailableSnr < unlockThresholdDb && _unlockTimer >= holdOutMs) ||
                    (strongCompetitor && _unlockTimer >= 150) ||
                    (_unlockTimer >= holdOutMs * 2); // Force unlock
```

## 🔧 Solutions appliquées

### **Correction 1 : SNR réel**
- Calcul du vrai meilleur SNR en parcourant tous les pics
- Utilise `math.max` sur la liste des SNR au lieu de prendre le premier

### **Correction 2 : Unlock intelligent** 
- `_unlockTimer` ne se reset que si `selectedPeak.snr >= unlockThresholdDb`
- Si on tracke un pic faible (`< unlockThresholdDb`), le timer continue de compter
- Permet l'unlock même en présence d'un pic faible persistant

### **Correction 3 : Force unlock**
- Timeout forcé après `holdOutMs * 2` millisecondes
- Empêche les situations où le tracker reste bloqué indéfiniment
- Messages d'unlock informatifs pour debug

## 📊 Impact par preset

### **Preset Accordeur**
- `unlockThresholdDb = 8.0 dB`, `holdOutMs = 150ms`
- Force unlock après 300ms maximum
- Plus restrictif mais unlock garanti

### **Preset Spectre** 
- `unlockThresholdDb = 5.0 dB`, `holdOutMs = 200ms`
- Force unlock après 400ms maximum
- Plus permissif et réactif

## 🧪 Tests recommandés

1. **Test silence → son** : Vérifier que ça lock puis unlock correctement
2. **Test son faible** : Vérifier que ça unlock après le timeout même avec du bruit résiduel  
3. **Test changement de note** : Vérifier que ça unlock/relock sur une nouvelle fréquence
4. **Test preset** : Vérifier les différences de comportement accordeur vs spectre

## ✅ Résultat attendu

- **Fini les locks permanents** 🎯
- **Unlock basé sur la vraie qualité du signal** ✨  
- **Force unlock pour éviter les blocages** 🔓
- **Comportement différencié par preset** 🎛️
- **Messages de debug informatifs** 📝

Le système devrait maintenant unlock correctement quand le signal devient trop faible ou après un timeout raisonnable !