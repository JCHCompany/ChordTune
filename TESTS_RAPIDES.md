# Tests Rapides - Configuration Actuelle

## ✅ Résumé des Corrections Appliquées

### Changements Récents (pour résoudre doublage de fréquence):
1. **YIN threshold**: 0.20 → 0.30 (plus sélectif)
2. **Octave correction**: DÉSACTIVÉE (était la cause principale)
3. **Fusion weights**: Retour équilibré 0.5/0.5
4. **HarmonicSalience**: Paramètres standard (6 harmoniques, 30.0 tolérance)
5. **Lock thresholds**: Plus conservateurs (12.0 dB lock, 6.0 dB unlock)

### Problèmes Corrigés:
- ❌ Scientific notation overflow (4.11e+21 Hz) → ✅ Bound checking
- ❌ Jamais unlock → ✅ SNR calculation corrigée  
- ❌ Fréquence doublée (164 Hz) → ✅ YIN threshold + octave correction off
- ❌ Lock permanent → ✅ Thresholds plus restrictifs

## 🎯 Tests à Faire Maintenant

### Test Priorité 1: Mi Grave (82.4 Hz)
```
🎸 Jouer corde Mi grave
👀 Vérifier affichage: ~82 Hz (PAS 164 Hz)
⏱️  Vérifier lock/unlock fonctionne
```

### Si Résultat Test 1:
- **✅ 82 Hz affiché**: Parfait ! Tester autres cordes
- **❌ 164 Hz affiché**: Augmenter YIN threshold à 0.35
- **❌ Lock permanent**: Augmenter lockThreshold à 15.0
- **❌ Jamais lock**: Diminuer lockThreshold à 10.0

## 🔧 Modifications Une par Une

### Option A: Si fréquence encore doublée
```dart
// Dans spectroid_config.dart
yinThreshold: 0.35,  // Plus strict
```

### Option B: Si lock trop facile  
```dart
lockThreshold: 15.0,  // Plus difficile à lock
```

### Option C: Si lock trop difficile
```dart
lockThreshold: 10.0,  // Plus facile à lock
```

### Option D: Si trop lent
```dart
holdInDuration: 200,   // Plus rapide
holdOutDuration: 100,
```

## 📱 Workflow de Test

1. Modifier **UN SEUL** paramètre
2. Sauvegarder (hot reload automatique)  
3. Tester corde Mi grave
4. Noter le résultat
5. Revenir en arrière si pire
6. Essayer paramètre suivant

## 🎵 Valeurs Cibles

- **Mi grave**: 82.4 Hz ±1 Hz
- **La**: 110.0 Hz ±1 Hz
- **Ré**: 146.8 Hz ±1 Hz
- **Sol**: 196.0 Hz ±1 Hz
- **Si**: 246.9 Hz ±1 Hz  
- **Mi aigu**: 329.6 Hz ±1 Hz

## 💬 Logs Utiles

Chercher dans la console:
```
YIN detected: 82.x Hz    ← Bon signe
Pitch fusion result: 82.x Hz  ← Résultat final
DominantTracker: LOCKED   ← État de verrouillage
```

---

**Commencer par**: Tester Mi grave avec config actuelle. Vous devriez maintenant voir ~82 Hz au lieu de 164 Hz !