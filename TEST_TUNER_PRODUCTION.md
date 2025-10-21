# Test du Tuner Production

## Corrections appliquées

### ✅ Notation des notes
- **Avant** : Do, Ré, Mi, Fa, Sol, La, Si (notation française)
- **Après** : C, D, E, F, G, A, B (notation anglaise/internationale)
- **Format** : Note + Octave (ex: E2, A4, B3)

### ✅ Connexion au pipeline R&D
Le tuner est maintenant **correctement connecté** à la même sortie que le cadre vert du mode R&D :

```dart
// Exactement la même source que le cadre vert
state.f0Tracked    // Fréquence finale du tracker
state.trackerState // État: 'locked', 'search', 'nopitch'
```

**Flux de données** :
```
Audio → YIN → Harmonic Salience → Fusion → Dominant Tracker → f0Tracked
                                                                    ↓
                                                            Production Tuner
                                                            (affichage final)
```

### ✅ Affichage simplifié
- Note + Octave en grand (ex: **E2**)
- Fréquence exacte en Hz (ex: 82.4 Hz) - **même valeur que le cadre vert**
- Jauge de justesse avec indicateur visuel
- Cents avec code couleur

## Test rapide

### Étape 1 : Lancer l'application
```bash
flutter run
```

### Étape 2 : Accéder au tuner
1. Sur l'écran d'accueil, appuyer sur le bouton **"Tuner"** (gros bouton en haut)
2. Le tuner devrait afficher "Écoute en cours..."

### Étape 3 : Jouer une note de guitare
Tester avec les cordes standard :

| Corde | Note attendue | Fréquence |
|-------|---------------|-----------|
| 1 (aigu) | E4 | ~329.6 Hz |
| 2 | B3 | ~246.9 Hz |
| 3 | G3 | ~196.0 Hz |
| 4 | D3 | ~146.8 Hz |
| 5 | A2 | ~110.0 Hz |
| 6 (grave) | E2 | ~82.4 Hz |

### Étape 4 : Vérifier l'affichage

✅ **Quand locked** :
- Le tuner devrait afficher la note (ex: **E2**)
- La fréquence exacte (ex: **82.4 Hz**)
- La jauge de justesse avec indicateur mobile
- Les cents (ex: **+3 cents** avec ↑ si trop haut)

✅ **Stabilité** :
- Pas de sauts rapides entre notes
- Si on revient sur la même note en moins de 1s → affichage conservé
- Nouvelle note confirmée après 0.5s de stabilité

### Étape 5 : Comparer avec le mode R&D

Pour vérifier que c'est la même valeur :
1. Retour à l'accueil
2. Aller dans **"Accordeur R&D"**
3. Jouer la même note
4. Vérifier que le **cadre vert** affiche la **même fréquence** que le tuner production

**Exemple** : Mi grave (E2)
- Mode R&D (cadre vert) : `82.4 Hz`
- Tuner Production : `E2` + `82.4 Hz`
- ✅ **Les deux doivent être identiques**

## Vérifications techniques

### ✓ Pipeline correct
```dart
// Dans production_tuner_screen.dart
BlocListener<SpectroidCubit, SpectroidState>(
  listener: (context, state) {
    _updateNote(state.f0Tracked, state.trackerState);
    //           ^^^^^^^^^^^^^^^^  ^^^^^^^^^^^^^^^^^^
    //           Même valeur que le cadre vert R&D
  }
)
```

### ✓ Condition de verrouillage
```dart
if (trackerState.toLowerCase() != 'locked' || f0 <= 0) {
  // Pas d'affichage si pas locked
  return;
}
```

### ✓ Conversion de fréquence
```dart
// MIDI note: 69 = A4 = 440 Hz
midiNote = 69 + 12 * log2(f / 440.0)

// Exemples :
// 82.4 Hz  → MIDI 40 → E2
// 110.0 Hz → MIDI 45 → A2
// 329.6 Hz → MIDI 64 → E4
```

## Problèmes potentiels et solutions

### Problème : "Écoute en cours..." ne change jamais
**Cause** : Le tracker ne passe jamais en état 'locked'
**Solution** : 
1. Vérifier le volume/gain du micro
2. Essayer avec une note forte (corde grave)
3. Vérifier dans le mode R&D si le cadre vert apparaît

### Problème : Affichage avec des notes bizarres (C#-1, G9, etc.)
**Cause** : Fréquences hors gamme détectées
**Solution** : 
- Vérifier que la guitare est à peu près accordée
- Le pipeline R&D devrait filtrer ces cas

### Problème : Sauts rapides entre notes
**Cause** : Stabilité insuffisante ou mauvaise détection
**Solution** :
- Vérifier les paramètres du tracker (dominantHoldInMs, dominantLockThresholdDb)
- Augmenter les fenêtres de stabilité si nécessaire

## Notes de développement

### Configuration du tracker (dans SpectroidConfig)
```yaml
dominantLockThresholdDb: 20.0    # Seuil SNR pour verrouiller
dominantHoldInMs: 200            # Temps de stabilité avant lock
dominantLockWindowCents: 80.0    # Fenêtre d'acceptation
```

### Fenêtres de stabilité UI (dans production_tuner_screen.dart)
```dart
_confirmationDuration = 500ms    # Nouvelle note doit tenir 0.5s
_resetDuration = 1s              # Fenêtre de retour sur note stable
```

## Checklist finale

- [x] Notation anglaise (E, A, D, G, B) au lieu de française
- [x] Format Note+Octave (E2, A4, etc.)
- [x] Connexion à state.f0Tracked (sortie finale du pipeline)
- [x] Condition trackerState == 'locked'
- [x] Affichage de la fréquence en Hz
- [x] Système de stabilité anti-saut
- [x] Compatibilité avec le thème
- [x] Gestion du retour arrière

✅ **Prêt pour les tests !**
