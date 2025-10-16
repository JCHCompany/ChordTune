# 🎛️ Guide des Paramètres de Fine-Tuning

## 🎯 **Paramètres Critiques pour le Réglage**

### **YIN Detector Parameters**
**Fichier**: `spectroid_engine.dart`
- **`yinThreshold`** → **"YIN Threshold"** 
  - Valeur actuelle: `0.30`
  - Range: `0.18 - 0.50`
  - **Plus bas** = plus sensible, détecte plus de notes faibles
  - **Plus haut** = plus strict, évite fausses détections

### **HarmonicSalience Parameters**  
**Fichier**: `spectroid_engine.dart`
- **`harmonicsToCheck`** → **"Harmonic Count"**
  - Valeur actuelle: `6`
  - Range: `4 - 8`
  - Plus d'harmoniques = détection plus robuste mais plus lente
  
- **`toleranceCents`** → **"Harmonic Tolerance"**
  - Valeur actuelle: `30.0`
  - Range: `20.0 - 50.0`
  - **Plus bas** = plus strict sur alignement harmonique
  - **Plus haut** = plus tolérant, détecte instruments désaccordés

### **Anti-Harmonique Bias System**
**Fichier**: `dominant_pitch_tracker.dart` (fonction `_findProminentPeaks`)

#### **YIN Hints**
- **YIN Bonus** → **"YIN Match Bonus"**: `+8.0`
- **YIN ×2 Penalty** → **"YIN Octave Penalty"**: `-5.0` 
- **YIN ×4 Penalty** → **"YIN 4th Harm Penalty"**: `-7.0`
- **YIN ×8 Penalty** → **"YIN 8th Harm Penalty"**: `-9.0`

#### **Harmonic Hints**  
- **Harmonic Bonus** → **"Harmonic Match Bonus"**: `+6.0`
- **Harmonic ×2 Penalty** → **"Harmonic Octave Penalty"**: `-3.0`
- **Harmonic ×4 Penalty** → **"Harmonic 4th Harm Penalty"**: `-5.0`
- **Harmonic ×8 Penalty** → **"Harmonic 8th Harm Penalty"**: `-7.0`

### **Lock/Unlock Behavior**
**Fichier**: `spectroid_config.dart`

#### **Preset Accordeur**
- **`lockThresholdDb`** → **"Lock Threshold"**: `22.0` dB
- **`unlockThresholdDb`** → **"Unlock Threshold"**: `18.0` dB  
- **`holdInMs`** → **"Lock Hold Time"**: `150` ms
- **`holdOutMs`** → **"Unlock Hold Time"**: `200` ms
- **`maxJumpCentsPerS`** → **"Max Jump Rate"**: `800.0` cents/s

#### **Preset Spectre**
- **`lockThresholdDb`** → **"Lock Threshold"**: `20.0` dB
- **`unlockThresholdDb`** → **"Unlock Threshold"**: `16.0` dB
- **`holdInMs`** → **"Lock Hold Time"**: `100` ms  
- **`holdOutMs`** → **"Unlock Hold Time"**: `150` ms
- **`maxJumpCentsPerS`** → **"Max Jump Rate"**: `1000.0` cents/s

### **Alpha-Beta Filter (Speed/Responsiveness)**
**Fichier**: `spectroid_config.dart`
- **`alphaPos`** → **"Position Alpha"**: `0.9` (ultra-rapide)
- **`betaVel`** → **"Velocity Beta"**: `0.7` (ultra-rapide)
- Range recommandé: `0.1 - 0.9`
- **Plus haut** = convergence plus rapide mais moins stable
- **Plus bas** = plus stable mais convergence plus lente

### **Jump Detection (Anti-Lock Jumping)**
**Fichier**: `dominant_pitch_tracker.dart`
- **Jump Threshold** → **"Jump Detection Cents"**: `150.0` cents
- **Jump Duration** → **"Jump Detection Time"**: `200` ms
- **Plus bas** = détection plus sensible des sauts inappropriés
- **Plus haut** = permet plus de variation avant unlock

---

## 🔧 **Cas d'Usage de Réglage**

### **Problème: Trop de fausses détections**
→ **Augmenter**: YIN Threshold, Lock Threshold  
→ **Réduire**: Harmonic Tolerance, Jump Detection Cents

### **Problème: Ne détecte pas les notes faibles**  
→ **Réduire**: YIN Threshold, Lock Threshold, Unlock Threshold
→ **Augmenter**: Harmonic Tolerance

### **Problème: Converge trop lentement**
→ **Augmenter**: Position Alpha, Velocity Beta, Max Jump Rate
→ **Réduire**: Lock Hold Time, Unlock Hold Time

### **Problème: Trop instable, saute entre fréquences**
→ **Réduire**: Position Alpha, Velocity Beta, Max Jump Rate  
→ **Augmenter**: Lock Hold Time
→ **Réduire**: Jump Detection Cents (plus sensible aux sauts)

### **Problème: Détecte harmoniques au lieu de fondamentale**
→ **Augmenter**: YIN/Harmonic Match Bonus
→ **Augmenter**: Toutes les pénalités harmoniques (×2, ×4, ×8)

---

## ⚡ **Paramètres de Test Rapide**

### **Mode Debug Ultra-Rapide**
```dart
// Pour tests rapides
alphaPos: 0.95, betaVel: 0.8
lockThresholdDb: 18.0, holdInMs: 50
```

### **Mode Stable Production**  
```dart
// Pour usage normal
alphaPos: 0.7, betaVel: 0.5  
lockThresholdDb: 22.0, holdInMs: 200
```

### **Mode Guitar Électrique**
```dart
// Signal fort, harmoniques claires
yinThreshold: 0.25, toleranceCents: 25.0
lockThresholdDb: 20.0
```

### **Mode Guitar Acoustique**
```dart  
// Signal plus faible, harmoniques variables
yinThreshold: 0.35, toleranceCents: 35.0
lockThresholdDb: 24.0
```