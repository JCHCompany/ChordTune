# Tests Simplifiés - Mode DEBUG

## 🎯 **Modifications appliquées**

### **YIN** 
- `threshold: 0.30` (conservateur pour éviter doublements)

### **HarmonicSalience**
- `maxHarmonics: 6` (standard)
- `tolCents: 30.0` (standard)  
- `weightDecay: 0.8` (standard)

### **Fusion**
- `wYin: 0.5` / `wHarm: 0.5` (équilibré)
- `subharmThresh: 0.5` (standard)
- **Correction octave DÉSACTIVÉE**

### **DominantTracker (preset spectre)**
- `lockThresholdDb: 12.0` (plus strict)
- `unlockThresholdDb: 6.0` (permet unlock)  
- `holdInMs: 400` (plus lent mais sûr)
- `holdOutMs: 150` (unlock standard)

## 🧪 **Tests à faire**

1. **Hot reload l'app**
2. **Jouer Mi grave (82 Hz)** → doit détecter ~82 Hz (pas 164 Hz)
3. **Jouer Mi aigu (164 Hz)** → doit détecter ~164 Hz (pas 328 Hz)  
4. **Tester unlock** → arrêter de jouer → doit unlock après quelques secondes

## 🔧 **Si problèmes persistent**

### **Si encore doublements** :
```dart
// Dans spectroid_engine.dart ligne ~145
threshold: 0.35, // Encore plus conservateur
```

### **Si locked h24** :
```dart  
// Dans spectroid_config.dart preset spectre
dominantLockThresholdDb: 15.0, // Encore plus strict
dominantHoldInMs: 600,          // Encore plus lent
```

### **Si pas assez réactif** :
```dart
// Dans spectroid_config.dart preset spectre  
dominantLockThresholdDb: 10.0, // Plus permissif
dominantHoldInMs: 250,          // Plus rapide
```

## 📊 **Résultat attendu maintenant**

- **YIN, Harm, Fusion** : valeurs cohérentes sans doublements
- **LOCKED** : se verrouille après 400ms sur signal fort (>12dB)
- **UNLOCK** : se déverrouille après 150ms sans signal (<6dB)
- **Comportement** : plus conservateur mais prévisible

Testez maintenant avec ces réglages de base ! 🎸