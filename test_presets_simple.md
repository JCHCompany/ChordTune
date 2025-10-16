# Presets de Test Simplifiés

## 🎯 **Problème actuel**
- Détection **double** la fréquence (328 Hz au lieu de 164 Hz)
- **Locked en permanence**, jamais d'unlock
- **Trop de réglages** → difficile de savoir quoi modifier

## 🔧 **Presets de test faciles**

### **TEST 1 - "Conservative"** 
```dart
// YIN moins sensible pour éviter les doublements
threshold: 0.30

// HarmonicSalience standard  
maxHarmonics: 6, tolCents: 30.0, weightDecay: 0.8

// Fusion équilibrée
wYin: 0.5, wHarm: 0.5, subharmThresh: 0.5

// Lock plus strict pour éviter permanent lock
lockThresholdDb: 12.0, holdInMs: 400
unlockThresholdDb: 6.0, holdOutMs: 150
```

### **TEST 2 - "Rapide"**
```dart
// YIN standard
threshold: 0.25

// Lock très permissif
lockThresholdDb: 6.0, holdInMs: 150  
unlockThresholdDb: 3.0, holdOutMs: 100
```

### **TEST 3 - "Stable"** 
```dart
// Lock très strict
lockThresholdDb: 15.0, holdInMs: 800
unlockThresholdDb: 10.0, holdOutMs: 200
```

## 🎮 **Comment tester**
1. **Copier un preset** dans spectroid_config.dart
2. **Hot reload** l'app  
3. **Jouer une note** et observer
4. **Si ça double** → augmenter threshold YIN
5. **Si locked h24** → réduire lockThresholdDb ou réduire holdInMs

Voulez-vous que j'applique directement un de ces presets ?