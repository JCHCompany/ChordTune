# Tuner Production - Interface Utilisateur

## Vue d'ensemble

Le **Production Tuner** est l'interface utilisateur finale de l'accordeur, destinée aux utilisateurs finaux. Il utilise le pipeline de détection de hauteur (pitch) du module "Accordeur R&D" (`SpectroidCubit`) pour offrir une expérience d'accordage stable et fiable.

## Fichier principal

- **Fichier**: `lib/features/tuner/ui/production_tuner_screen.dart`
- **Route**: `/tuner` (accessible depuis l'écran d'accueil)

## Caractéristiques

### 1. Pipeline de détection

Le tuner utilise la sortie finale du pipeline R&D implémenté dans `SpectroidEngine` :
- **Source de données**: `SpectroidCubit.state.f0Tracked` et `trackerState`
- **Critère de détection**: Utilise uniquement les notes avec `trackerState == 'locked'` pour garantir la fiabilité
- **Pipeline complet**: YIN → Harmonic Salience → Fusion → Dominant Tracker

### 2. Stabilité de l'affichage

Pour éviter les sauts intempestifs de notes, un système de stabilité à deux niveaux est implémenté :

#### Fenêtre de conservation (1 seconde)
- Lorsqu'une note est affichée, elle reste visible pendant **1 seconde** même si une autre note est détectée
- Si pendant cette seconde on revient sur la même note, l'affichage est conservé (prolongation)
- Après 1 seconde sans retour sur la note initiale, on accepte un changement

#### Fenêtre de confirmation (0.5 seconde)
- Une nouvelle note doit être **confirmée pendant 0.5 seconde** avant d'être affichée
- Cela évite les transitions rapides dues au bruit ou aux harmoniques

**Classe**: `_NoteStabilityManager`

### 3. Interface visuelle

L'interface utilise le **thème centralisé** (`app_theme.dart`) :

#### Composants d'affichage
1. **État d'écoute** (`_BuildingListeningState`)
   - Icône de microphone
   - Message "Écoute en cours..."
   - Indicateur de chargement

2. **Affichage de la note** (`_BuildNoteDisplay`)
   - **Nom de la note + Octave** : Grande police (ex: E2, A4, B3), couleur primaire du thème (100pt, bold)
   - **Fréquence** : Valeur exacte du f0Tracked en Hz (même que le cadre vert R&D)
   - **Jauge de justesse** : Barre horizontale avec indicateur de position
   - **Indicateur de cents** : ✓ (juste), ↑ (trop haut), ↓ (trop bas)
   - **Valeur en cents** : Affichage numérique avec code couleur

#### Couleurs de justesse
- **Vert** : ≤ 5 cents (juste)
- **Orange** : 6-15 cents (acceptable)
- **Rouge** : > 15 cents (désaccordé)

### 4. Jauge visuelle personnalisée

**Widget**: `_TuningGauge` avec `_TuningGaugePainter`

- Barre horizontale avec fond du thème (`surfaceContainer`)
- Ligne centrale pour le repère (juste)
- Indicateur circulaire qui se déplace selon l'erreur en cents
- Plage : -50 à +50 cents
- Animation fluide grâce au repaint automatique

### 5. Gestion du retour arrière

- **Widget**: `PopScope` avec `canPop: true`
- Supporte le **geste de retour tactile** sur mobile
- Bouton de retour explicite dans l'AppBar
- Navigation vers l'écran d'accueil

### 6. Conversion de fréquence

**Classe**: `_PitchConverter`

Convertit une fréquence (Hz) en :
- Nom de note (C, D, E, F, G, A, B - notation anglaise/internationale)
- Octave
- Cents (déviation par rapport à la note la plus proche)
- Note MIDI

**Exemples de notes de guitare** :
- E2 (Mi grave) : 82.4 Hz
- A2 (La) : 110.0 Hz
- D3 (Ré) : 146.8 Hz
- G3 (Sol) : 196.0 Hz
- B3 (Si) : 246.9 Hz
- E4 (Mi aigu) : 329.6 Hz

**Formule utilisée**:
```dart
midiNote = 69 + 12 * log2(f / 440.0)
cents = (midiNote - round(midiNote)) * 100
```

## Architecture

```
ProductionTunerScreen (StatefulWidget)
  ├─ BlocProvider<SpectroidCubit>
  │   └─ SpectroidCubit.start() → Lance le pipeline
  │
  ├─ BlocListener
  │   └─ _updateNote() → Met à jour la stabilité
  │
  ├─ _NoteStabilityManager
  │   └─ Gère les fenêtres de temps
  │
  └─ UI conditionnelle
      ├─ _BuildingListeningState (pas de note)
      └─ _BuildNoteDisplay (note détectée)
          └─ _TuningGauge (jauge visuelle)
```

## Intégration au thème

Le tuner utilise systématiquement les couleurs du thème :
- `theme.colorScheme.primary` : Nom de la note
- `theme.colorScheme.onSurface` : Texte principal
- `theme.colorScheme.onSurfaceVariant` : Texte secondaire (octave, Hz)
- `theme.colorScheme.surfaceContainer` : Fond de la jauge
- `theme.colorScheme.outline` : Ligne centrale de la jauge

Mode clair/sombre géré automatiquement via `ThemeMode.system`.

## Navigation

### Depuis l'écran d'accueil
```dart
FilledButton.icon(
  onPressed: () => context.go('/tuner'),
  icon: const Icon(Icons.tune),
  label: Text(loc.tunerTitle),
)
```

### Accès développeur
L'ancien tuner de développement reste accessible via `/tuner-dev` pour les tests.

## Améliorations futures possibles

1. **Modes d'accordage** : Standard, Drop D, Open tunings, etc.
2. **Calibration A4** : Permettre de changer le A4 (440 Hz par défaut)
3. **Historique** : Afficher les dernières notes détectées
4. **Mode stroboscopique** : Animation visuelle alternative
5. **Sons de référence** : Jouer la note cible
6. **Enregistrement** : Sauvegarder une session d'accordage

## Tests recommandés

1. ✅ Tester avec une corde de guitare (Mi grave à Mi aigu)
2. ✅ Vérifier la stabilité avec des notes rapides
3. ✅ Tester le retour arrière (geste et bouton)
4. ✅ Vérifier en mode clair et sombre
5. ✅ Tester sur différentes tailles d'écran
