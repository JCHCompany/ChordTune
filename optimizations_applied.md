# Optimisations Appliquées pour Améliorer la Rapidité et la Précision

## 🎯 **Problèmes identifiés sur l'image**

**YIN: 81.3 Hz** ➜ Détecte la sous-harmonique (E2) au lieu du fondamental (E3 ≈ 164 Hz)  
**Harm: 82.0 Hz** ➜ Même problème, détecte une octave en dessous  
**Fusion: 81.5 Hz** ➜ Fusion des deux erreurs précédentes  
**LOCKED: 161.9 Hz** ➜ **Correct !** Le DominantTracker trouve la vraie fréquence

## 🔧 **Corrections appliquées**

### 1. **YIN plus sensible aux fondamentales**
```dart
// AVANT
threshold: 0.35, // Trop restrictif, favorise les harmoniques fortes

// APRÈS  
threshold: 0.20, // Plus sensible pour éviter les sous-harmoniques
```

### 2. **HarmonicSalience optimisé**
```dart
// AVANT
maxHarmonics: 6,     // Trop d'harmoniques → bruit
tolCents: 30.0,      // Tolérance trop large
weightDecay: 0.8,    // Dévaluation trop forte

// APRÈS
maxHarmonics: 4,     // Moins d'harmoniques pour éviter bruit 
tolCents: 20.0,      // Plus strict pour meilleure précision
weightDecay: 0.85,   // Moins de décroissance pour valoriser les harmoniques
```

### 3. **Fusion intelligente avec correction d'octave**
```dart
// AVANT - Poids favorisant YIN
wYin: 0.6, wHarm: 0.4, subharmThresh: 0.6

// APRÈS - Poids favorisant HarmonicSalience + correction octave
wYin: 0.4, wHarm: 0.6, subharmThresh: 0.4

// + Correction octave automatique :
// Si YIN et Harmonic détectent la même fréquence mais 2x plus bas
// → Vérifier si l'octave supérieure est plus plausible pour guitare
```

### 4. **Verrouillage plus rapide (preset spectre)**
```dart
// AVANT
dominantLockThresholdDb: 10.0, holdInMs: 300

// APRÈS - Plus permissif et rapide
dominantLockThresholdDb: 8.0,  // Plus facile à locker (was 10.0)
holdInMs: 200,                 // Plus rapide (was 300)
dominantUnlockThresholdDb: 4.0 // Plus facile à unlocker (was 5.0) 
```

## 🎸 **Résultat attendu**

**Avant** :
- YIN/Harmonic détectent 81-82 Hz (sous-harmonique E2)  
- Fusion donne 81.5 Hz (fausse)
- DominantTracker lutte pour converger vers 164 Hz
- Lock lent et imprécis

**Après** :
- YIN détecte mieux le fondamental ≈ 164 Hz (threshold plus bas)
- HarmonicSalience plus précis et stable (moins d'harmoniques, plus strict)  
- Correction octave automatique : si détection à 82 Hz → teste 164 Hz
- Lock plus rapide : 200ms au lieu de 300ms
- Unlock plus facile pour réajustement rapide

## 🚀 **Tests recommandés**

1. **Jouer E3 (≈164 Hz)** → Tous les algorithmes devraient maintenant détecter ≈164 Hz
2. **Tester rapidité** → Lock en ~200ms au lieu de >300ms  
3. **Tester stabilité** → Moins de fluctuations entre octaves
4. **Tester guitare grave** → Mi grave (82 Hz) devrait être détecté correctement sans doubler

Les optimisations visent à **corriger les erreurs d'octave** et **accélérer la convergence** vers la vraie fréquence fondamentale ! 🎯