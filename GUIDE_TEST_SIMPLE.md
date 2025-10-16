# Guide de Test Simple - Paramètres de Détection

## 🎯 Configuration Actuelle (Baseline Conservative)
- **YIN Threshold**: 0.30 (plus sélectif)
- **Fusion Weights**: 0.5/0.5 (équilibré YIN + HarmonicSalience)
- **Lock Threshold**: 12.0 dB (plus restrictif)
- **Unlock Threshold**: 6.0 dB (plus permissif)
- **Octave Correction**: DÉSACTIVÉE

## 🧪 Tests à Effectuer

### Test 1: Corde Mi grave (82.4 Hz)
1. Jouez la corde Mi grave
2. Observez si la détection:
   - ✅ Affiche ~82 Hz (pas 164 Hz)
   - ✅ Ne reste pas locked H24
   - ✅ Unlock quand vous arrêtez de jouer

### Test 2: Accord Standard
- **Mi grave**: 82.4 Hz
- **La**: 110.0 Hz  
- **Ré**: 146.8 Hz
- **Sol**: 196.0 Hz
- **Si**: 246.9 Hz
- **Mi aigu**: 329.6 Hz

### Test 3: Preset Accordeur vs Spectre
- **Preset Accordeur**: Pour l'accordage précis
- **Preset Spectre**: Pour l'exploration/visualisation

## 🔧 Si Problèmes Persistent

### Problème: Fréquence doublée (164 Hz au lieu de 82 Hz)
**Réglages à essayer** (dans spectroid_config.dart):
```dart
// Option A: YIN plus strict
yinThreshold: 0.35,

// Option B: Plus de poids sur YIN
yinWeight: 0.7,
harmonicWeight: 0.3,
```

### Problème: Toujours locked
**Réglages à essayer**:
```dart
// Lock plus restrictif
lockThreshold: 15.0,  // était 12.0
```

### Problème: Jamais locked
**Réglages à essayer**:
```dart
// Lock plus permissif  
lockThreshold: 8.0,   // était 12.0
```

### Problème: Trop lent à réagir
**Réglages à essayer**:
```dart
// Temps plus courts
holdInDuration: 200,  // était 400
holdOutDuration: 100, // était 150
```

## 📊 Logs à Surveiller

Recherchez dans les logs:
- `YIN detected:` pour voir les résultats YIN
- `HarmonicSalience result:` pour les harmoniques
- `Pitch fusion result:` pour la combinaison
- `DominantTracker state:` pour le lock/unlock

## 🎵 Ordre de Test Recommandé

1. **Test Mi grave** - Le plus critique (82 Hz vs 164 Hz)
2. **Test verrouillage** - Unlock quand arrêt de jeu  
3. **Test autres cordes** - Si Mi grave OK
4. **Ajustements fins** - Seulement si nécessaire

## 💡 Règle d'Or

**UN SEUL réglage à la fois !** Si vous changez plusieurs paramètres ensemble, impossible de savoir lequel cause quoi.

## 🔄 Hot Reload

Après chaque modification dans `spectroid_config.dart`:
1. Sauvegardez le fichier
2. L'app se recharge automatiquement
3. Testez immédiatement

---

**Objectif**: Avoir une détection stable qui:
- Détecte correctement 82 Hz (pas 164 Hz)  
- Lock quand note stable
- Unlock quand arrêt de jeu
- Réagit en moins de 500ms