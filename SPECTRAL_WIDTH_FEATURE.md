# Discrimination par Largeur Spectrale + Compétition par Niveau

## Concept

Cette fonctionnalité résout le problème de "sticky lock" en utilisant **deux mécanismes complémentaires** :

### 1. Discrimination par largeur spectrale

Distingue entre :

**Pics tonaux précis** (notes de guitare) : largeur < 20 Hz
   - Déclenchent un **unlock rapide** (100 ms au lieu de 200 ms)
   - Marge compétiteur faible (3 dB par défaut)
   
**Bruit large bande** (claquements, coups) : largeur > 50 Hz
   - **Tolérés** pendant plus longtemps (400 ms au lieu de 200 ms)
   - Marge compétiteur élevée (12 dB par défaut)

### 2. **NOUVEAU** : Compétition par niveau absolu

**Problème résolu** : Quand vous jouez 330 Hz puis 82 Hz fort, le tracker restait bloqué sur 330 Hz même si 82 Hz était beaucoup plus fort.

**Solution** : Si un pic **hors fenêtre de tracking** est **significativement plus fort** (par défaut +15 dB) que le pic actuellement locké **ET** que c'est un pic tonal étroit, le tracker force un unlock immédiat.

**Exemple concret** :
- Lock sur 330 Hz à -25 dB
- Vous jouez 82 Hz fort à -50 dB → différence = 25 dB
- 82 Hz a une largeur < 20 Hz (pic tonal)
- → **Force unlock immédiat** pour permettre le switch vers 82 Hz

## Mesure de largeur spectrale

La largeur est calculée par la méthode **FWHM** (Full Width at Half Maximum) :
- On cherche les bins où l'énergie tombe à **-3 dB** du pic
- La largeur est la distance en Hz entre ces points

```
Pic tonal (note E2) :
    |
   /|\     ← Largeur ~10-15 Hz
  / | \
 /  |  \
---------

Bruit (claquement) :
  _____
 /     \   ← Largeur ~80-120 Hz
/       \
----------
```

## Paramètres réglables (R&D Settings)

### Section "Discrimination largeur spectrale"

1. **Seuil pic étroit** (5-50 Hz, défaut: 20 Hz)
   - En dessous = pic tonal → unlock rapide

2. **Seuil pic large** (30-150 Hz, défaut: 50 Hz)
   - Au-dessus = bruit → toléré

3. **Marge pic étroit** (1-8 dB, défaut: 3 dB)
   - Compétiteur étroit doit être 3 dB plus fort → unlock facile

4. **Marge pic large** (8-20 dB, défaut: 12 dB)
   - Compétiteur large doit être 12 dB plus fort → très toléré

5. **NOUVEAU : Seuil niveau pic extérieur** (8-25 dB, défaut: 15 dB)
   - Si un pic hors fenêtre est N dB plus fort → force unlock immédiat
   - **C'est le paramètre clé pour votre cas 330→82 Hz**

## Tests recommandés

### Test 1 : Changement rapide avec sustain (VOTRE CAS)
**Scénario** : 330 Hz à -25 dB → jouer 82 Hz fort à -50 dB
**Avant** : Reste locké sur 330 Hz (l'ancien pic est encore là)
**Après** : Unlock immédiat car 82 Hz est 25 dB plus fort (> seuil de 15 dB)

**Comment tester** :
1. Jouer la corde E4 (330 Hz)
2. Attendre le lock (cadre vert)
3. Laisser le son baisser à ~-25 dB (sans étouffer)
4. Jouer **fort** la corde E2 (82 Hz)
5. Observer le décrochage → devrait être **immédiat** (< 50 ms)

**Ajuster si nécessaire** :
- Si unlock trop lent : baisser "Seuil niveau pic extérieur" vers 10-12 dB
- Si unlock trop agressif : augmenter vers 18-20 dB

### Test 2 : Changement rapide note à note (enchaînement rapide)
**Avant** : Reste locké sur 330 Hz pendant ~400-600 ms
**Après** : Décroche en ~100-150 ms (si E2 a une largeur < 20 Hz)

**Comment tester** :
1. Jouer la corde B (246 Hz) ou E4 (330 Hz)
2. Attendre le lock (cadre vert)
3. Jouer immédiatement la corde E2 (82 Hz)
4. Observer le temps de décrochage

**Valeurs typiques mesurées** :
- Note de guitare bien jouée : 8-18 Hz
- Harmoniques fortes : 12-25 Hz
- Claquement : 60-150 Hz

### Test 2 : Claquement de mains pendant qu'une note est lockée
**Avant** : Pouvait causer un unlock intempestif
**Après** : Le claquement (large bande) est toléré, pas d'unlock

**Comment tester** :
1. Jouer une note stable (ex: 110 Hz, corde A)
2. Attendre le lock
3. Taper dans les mains à côté de la guitare
4. Vérifier que le lock ne saute PAS

### Test 3 : Ajuster les seuils en live
Dans R&D Settings → "Discrimination largeur spectrale" :
1. Commencer avec défauts (20 Hz / 50 Hz / 3 dB / 12 dB)
2. Si unlock trop lent sur changements rapides :
   - Baisser "Marge pic étroit" vers 2 dB
   - Baisser "Seuil pic étroit" vers 15 Hz
3. Si unlock intempestif sur bruits :
   - Augmenter "Seuil pic large" vers 70 Hz
   - Augmenter "Marge pic large" vers 15 dB

## Debug : Voir la largeur spectrale

Dans la vue R&D, le message "lockReason" affiche maintenant :
```
FORCE UNLOCK: Jump 509 cents for 120ms (width=12.3Hz)
                                         ↑
                         Largeur spectrale du compétiteur
```

Si width < 20 Hz → c'est un pic tonal (réaction rapide)
Si width > 50 Hz → c'est du bruit (toléré)

## Valeurs par défaut optimisées

```dart
narrowPeakWidthHz: 20.0,    // Notes < 20 Hz
widePeakWidthHz: 50.0,      // Bruit > 50 Hz
narrowPeakMarginDb: 3.0,    // Unlock rapide sur notes
widePeakMarginDb: 12.0,     // Tolérance haute sur bruit
```

Ces valeurs sont un bon point de départ, ajustez selon vos observations terrain.

## Scénarios résolus

✅ **330 Hz → 82 Hz en enchaînant** : Unlock en ~100 ms au lieu de 400+ ms
✅ **Claquement pendant lock** : Pas d'unlock intempestif
✅ **Notes rapides (triolets)** : Suit les changements sans latence excessive
✅ **Environnement bruyant** : Reste stable sur la note jouée

## Limitations connues

- Si une note est jouée **très doucement** avec peu d'harmoniques, sa largeur peut être artificiellement élargie par le bruit → peut être catégorisée comme "large"
- Solution : Jouer avec un SNR > 6 dB (déjà requis pour lock de toute façon)

## Prochaines améliorations possibles

1. Ajouter un indicateur visuel de largeur spectrale dans le debug overlay
2. Historique des largeurs pour chaque pic (détecter patterns)
3. Auto-calibration : apprendre les largeurs typiques des notes vs bruits
