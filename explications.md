# Explications du pipeline de détection de pitch (Spectroid / Dominant Tracker)

Ce document explique, de manière simple mais précise, toutes les étapes du pipeline de détection de hauteur (f0) utilisé dans le projet. Il liste les composants, les comparaisons effectuées, la façon dont le fondamental est choisi parmi les harmoniques, et indique où chercher dans le code pour chaque étape.

Fichiers clés :
- `lib/features/research/spectroid/spectroid_engine.dart` — orchestration principale, prétraitement et instanciation des détecteurs.
- `lib/dsp/yin.dart` — implémentation YIN (time-domain, CMND).
- `lib/dsp/harmonic_salience.dart` — algorithme de salience harmonique (comb-like scoring).
- `lib/dsp/pitch_fusion.dart` — fusion YIN + Harmonic (poids, anti-octave heuristics).
- `lib/dsp/dominant_pitch_tracker.dart` — tracker d'état (search/locked), détection des pics, scoring, comparaisons, heuristiques (le coeur du comportement observable).

## Vue d'ensemble du pipeline

Flux de données (haute-niveau) :
1. Capture audio → pré-traitement (filtres, décimation, fenêtre) — voir `SpectroidEngine.start()` et `AudioDSP`.
2. Calcul du spectre (FFT → PSD / bins) et post-traitements (EMA, smoothing). (`spectroid_engine.dart` lignes où `mag` est construit)
3. Détecteurs hybrides (Option C) :
   - YIN : détection temps-domaine indépendante (voir `lib/dsp/yin.dart`).
   - Harmonic Salience : balayage de candidats fondamentaux sur une grille log-freq et sommation d'énergie harmonique (voir `lib/dsp/harmonic_salience.dart`).
   - Pitch Fusion : combine YIN et Harmonic pour donner un hint/global (voir `lib/dsp/pitch_fusion.dart`).
4. DominantPitchTracker : détecte les pics dans le spectre, calcule des scores (SNR, prominence, harmonic score, hintBias), mesure largeur spectrale (FWHM), applique comparateurs/filtres et décide d'un lock/unlock.

Chaque frame produit : `f0Yin`, `f0Harm`, `f0Fused`, puis `f0Tracked` (résultat final du tracker). Les sorties de debug `debugPeaks` et `lockReason` expliquent les décisions pour la frame.

## Étape par étape (détails techniques)

1) Prétraitement & spectre
- Décimation / cascade decimator → `effectiveFs` calculé dans `SpectroidEngine.start()`.
- Fenêtrage (Hann / Kaiser selon config), FFT, conversion en PSD/linear power.
- Lissage / EMA sur le domaine linéaire (optionnel en dB). Ces étapes affectent la résolution SNR et la stabilité temporelle.

2) YIN (temps-domain)
- Implémentation classique CMND (cumulative mean normalized difference) dans `lib/dsp/yin.dart`.
- Renvoie `YinResult(f0, confidence)` (confidence = 1 - CMND_at_tau).
- Avantages : robuste aux harmoniques (cherche périodicité dans le temps). Limites : sensible au bruit, fenêtre/time-resolution tradeoff.

3) Harmonic Salience
- `lib/dsp/harmonic_salience.dart` parcourt une grille de candidats fondamentaux `freqs[]` (log-scale).
- Pour chaque candidat f, il somme l'énergie des harmoniques (2f, 3f, ...) dans les bins correspondants pondérés par `weightDecay`.
- Score = somme pondérée des puissances sur harmoniques; on retient le meilleur candidat et une confiance heuristique (best/(best+secondBest)).
- C'est un algorithme classique de type "harmonic summation"/"comb-like". Il favorise la fréquence dont les harmoniques coïncident avec des pics d'énergie.

4) PitchFusion
- `lib/dsp/pitch_fusion.dart` combine YIN et Harmonic par pondération (wYin, wHarm) et applique quelques règles d'anti-octave :
  - Si YIN est très confiant (>0.9) et Harmonic est octave (ratio ≈ 2.0) → forcer YIN.
  - Si anti-octave détecté, appliquer un léger biais vers la fréquence la plus grave.
- Résultat : `f0Fused` et `confFused` qui servent ensuite de *hints* au tracker.

5) Détection de pics et calcul des métriques (DominantPitchTracker)
- `DominantPitchTracker._findProminentPeaks(...)` parcourt les bins entre `fMin` et `fMax` et :
  - Cherche maxima locaux.
  - Calcule `prominence` (différent entre le pic et la médiane locale dans un voisinage `neighborSpanBins`).
  - Parabolic interpolation pour affiner la fréquence et le niveau sub-bin.
  - Calcule `snr` = niveau du pic - median local.
  - Calcule `harmonicScore` via `_calculateHarmonicScore` (contrôle présence d'harmoniques 2x/3x près de la fréquence du pic).
  - Calcule `spectralWidthHz` via `_calculateSpectralWidth(...)` (FWHM approximé à -3 dB, voir plus bas).
  - Construit un `PeakInfo(freq, dbLevel, snr, prominence, harmonicScore, totalScore, spectralWidthHz)`.

6) Scoring & hintBias
- `totalScore = snr + harmonicScore + hintBias`.
- `hintBias` : bias additionnel lié au fait que la fréquence du pic corresponde à YIN/Harmonic hints (augmenté si proche). Récemment on a ajouté une *Fundamental Consensus Bias* : si YIN et HarmonicSalience s'accordent (<50 cents), le pic correspondant reçoît un bonus très fort (+15 dB) pour favoriser la fondamentale visible par les deux méthodes (évite oscillation vers harmonique plus fort).

7) Comparateur fondamental & promotion du candidate fondamental
- Après détection initiale, `_applyFundamentalComparator(...)` tente d'identifier si un pic plus grave (candidate) est probablement le fondamental d'un pic aigu (peak). Il vérifie :
  - ratio ≈ 2,3,4,... (harmonic relation)
  - `candidate.snr >= minSnrForFundamental` (ex: 8 dB)
  - `peak.dbLevel - candidate.dbLevel <= maxLevelDiff` (ex: harmonique ne devrait pas être >15 dB plus fort)
  - `harmonicSupport >= minHarmonicSupport` (comb gain calculé pour candidate)
- Si ces conditions sont OK, on **booste** le score du candidat fondamental (`fundamentalBonus`) et on **pénalise** l'harmonique correspondante. Ceci est une heuristique visant à choisir le fondamental quand il existe une cohérence harmonique.

8) Attempt Fundamental Rescue
- `_attemptFundamentalRescue(...)` : si on ne voit pas directement le fondamental, on essaie pour chaque pic d'examiner `f/2`, `f/3` etc. et calcule un `combGain` (gain de peigne) autour de cette hypothèse. Si `combGain >= threshold` → on construit un `PeakInfo` artificiel pour le subharmonic avec pénalités (db/snr réduits) mais avec harmonicScore élevé pour lui donner une chance.

9) Locked state machine
- Conditions pour lock (dans `_processSearchState`) :
  - `bestPeak.snr >= lockThresholdDb` AND `prominence >= effectiveProminenceForLock`
  - Un timer `lockTimer` doit atteindre `holdInMs` pour confirmer le lock (validation temporelle)
  - Une fois locké, on passe en `locked` et on suit les candidats dans une fenêtre adaptative autour de la fréquence prédite.
- Conditions pour unlock :
  - SNR du meilleur pic < `unlockThresholdDb` pour la durée `holdOutMs` (ou autre règles combinées)
  - Présence d'un *strong competitor* (pic hors fenêtre beaucoup plus fort) et certaines marges dépendant de la largeur spectrale (narrow/wide)

## Mesures spécifiques et heuristiques importantes

- Spectral width (largeur spectrale) : mesurée par FWHM approximé à -3 dB dans `_calculateSpectralWidth(...)` (cherche bin gauche/droit où niveau ≤ peakDb - 3 dB, convertit bins→Hz). Influencée par binWidth (resolution) et fenêtrage.
- Comb gain / harmonic support : `_calculateCombGain(...)` mesure la présence des harmoniques attendues autour d'un candidat f0 (somme des puissances des harmoniques). Utilisé pour valider un candidate fondamental.
- Prominence : différence entre pic et médiane locale dans un voisinage (évite prendre des petits crêtes dans un bruit montant).

## Pourquoi HarmonicSalience peut trouver 220 Hz alors que 110 Hz est visible ?

Cas typique (ton exemple, screenshot) :
- Mesures extraites : peak#1 = 110.31 Hz @ 38.3 dB ; peak#2 = 220.61 Hz @ 49.5 dB ; YIN=110 Hz conf=0.91 ; Harm=221 Hz conf=0.58

Raisons pour lesquelles l'algorithme choisit 220 Hz :
1. Harmonic salience (ou le scoring des pics) privilégie souvent le pic avec la plus forte énergie/SNR. Ici 220 Hz est ~11 dB plus fort → meilleur `snr` et `totalScore` si aucun bias robuste n'intervient.
2. Avant nos récentes modifications, la logique podait favoriser l'harmonique si le fondamental a SNR insuffisant selon les seuils (`minSnrForFundamental`) ou si `levelDifference` > `maxLevelDiff` (ex: harmonique >15 dB plus fort).
3. YIN est robuste, mais si la fusion donne un poids insuffisant (poids configurés wYin vs wHarm) ou si le tracker est en mode autonome, alors l'énergie spectrale domine.

Qu'est-ce qui est appliqué pour contrer ça ?
- Plusieurs mécanismes dans le pipeline sont explicitement conçus pour éviter ce faux choix :
  - `PitchFusion` contient une logique anti-octave (favoriser YIN si très confiant).
  - `_applyFundamentalComparator` booste le candidat fondamental si sa cohérence harmonique et son SNR sont suffisants.
  - `_attemptFundamentalRescue` crée un candidat subharmonique lorsqu'un pic semble être un multiple.
  - Récemment, une règle `Fundamental Consensus Bias` a été ajoutée : si YIN et HarmonicSalience s'accordent (consensus < 50 cents), on applique un bonus fort (+15 dB) au pic proche du consensus pour forcer la sélection du fondamental même si un harmonique apparent est plus fort.

Donc, il n'y a pas (uniquement) un algorithme unique et formel du type "estimating fundamental from harmonic series" appliqué ; le pipeline combine plusieurs méthodes classiques (YIN, harmonic summation/comb, fusion pondérée) puis applique des heuristiques (boosts/pénalités, rescue, comparateurs) pour choisir le fondamental.

## Algorithmes reconnus utilisés
- YIN (classique, temps-domain CMND) — très répandu et reconnu.
- Harmonic summation / comb-like salience — technique classique pour estimer la fréquence fondamentale par sommation d'énergie des harmoniques.
- Pitch fusion (pondération YIN/Harm) — approche heuristique mais standard pour combiner détecteurs complémentaires.

Ces éléments forment un ensemble d'algorithmes reconnus. Les heuristiques (penalties, bonuses, thresholds) sont des adaptations pratiques pour la guitare et environnements bruités.

## Paramètres clés à connaître et où les régler
- `dominantLockThresholdDb` (ex : 3.0) — SNR minimal pour commencer à considérer un pic pour lock. (config : `spectroid_config.dart`)
- `dominantHoldInMs` / `dominantHoldOutMs` — durée pour lock / unlock (temporelle).
- `peakProminenceDb` — contraste local requis pour qu'un pic soit considéré.
- `narrowPeakWidthHz` / `widePeakWidthHz` — classification tonal vs bruit (spectral width thresholds).
- `narrowPeakMarginDb` / `widePeakMarginDb` — marges de compétition pour forcer unlock selon largeur spectrale.
- `dominantRescueEnabled` — active les tentatives de rescues subharmoniques.
- `wYin` / `wHarm` (dans `PitchFusion`) — poids de fusion entre YIN et Harmonic.

## Comment déboguer un cas (ex: 110 vs 220 Hz)
1. Activer le debug overlay (R&D view) → lire : `YIN`, `Harm`, `Fusion`, `Top Peaks`, `LOCKED`, `lockReason`.
2. Vérifier :
  - `YIN` confidence (si >0.9, YIN est très fiable)
  - `Harm` frequency et confidence
  - `Top Peaks` : fréquences / niveaux / snr / width
  - `lockReason` : explique pourquoi le tracker a lock/unlock
3. Si harmonic domine malgré YIN fort :
  - Vérifier `peak db` difference (ici 220 est ~11 dB plus fort) → expliquer pourquoi l'algorithme penche vers l'harmonique
  - Activer `dominantRescueEnabled` et/ou augmenter `wYin` dans fusion
  - Si tu veux comportement strict, augmenter `fundamental consensus bias` (paramètre dans le code : on l'a mis à +15 dB dans l'implémentation actuelle)

## Recommandations pratiques
- Pour guitare en jeu réel, les valeurs par défaut sont raisonnables : `narrowPeakWidthHz=20`, `widePeakWidthHz=50`, `narrowPeakMarginDb=3`, `widePeakMarginDb=12`.
- Si tu observes trop d'oscillations vers les harmoniques : augmenter le poids YIN (`wYin`) ou activer/augmenter les heuristiques de promotion du fondamental (consensus bias, rescue thresholds).
- Si tu observes des unlocks intempestifs lors de bruits transitoires, augmente `widePeakMarginDb` ou la valeur `transientFreezeDurationMs`.

## Proposition d'améliorations futures
- Interpoler les points -3 dB pour une estimation plus précise de la largeur spectrale (réduction des erreurs liées à la résolution).
- Ajouter un estimateur d'énergie cumulée (bandwidth at X% energy) pour remplacer/supplémenter le FWHM.
- Entraîner une petite heuristique ML (logistic regression) sur features (snr, width, harmonicSupport, prominence) pour décider lock/unlock automatiquement sur des données annotées.

## Où regarder dans le code
- `SpectroidEngine.start()` — orchestration, création de `DominantPitchTracker` et initialisation des paramètres.
- `lib/dsp/yin.dart` — implémentation YIN.
- `lib/dsp/harmonic_salience.dart` — implémentation de la salience harmonique (comb-like).
- `lib/dsp/pitch_fusion.dart` — logique de fusion (poids/anti-octave).
- `lib/dsp/dominant_pitch_tracker.dart` — coeur décisionnel :
  - `_findProminentPeaks` (peak detection + metrics)
  - `_calculateSpectralWidth` (FWHM à -3 dB)
  - `_calculateHarmonicScore`, `_calculateCombGain` (harmonic support)
  - `_applyFundamentalComparator` (promotion du fondamental)
  - `_attemptFundamentalRescue` (création de candidats subharmoniques)
  - `_processSearchState` / `_processLockedState` (machine d'état lock/unlock)

## Conclusion (résumé simple)
Le pipeline utilise des méthodes reconnues (YIN + harmonic summation) et des heuristiques pratiques (fusion pondérée, promotion du fondamental, rescue) pour produire un résultat stable en conditions réelles. Le cas où `Harm` trouve 220 Hz alors que 110 Hz est visible est attendu quand un harmonique a plus d'énergie; le système contient plusieurs mécanismes pour corriger cela (fusion, rescue, comparator, consensus bias). Tu peux modifier les poids et seuils dans la configuration R&D pour prioriser le comportement que tu souhaites.

---

Si tu veux, je peux :
- Générer un petit script de test (synthèse sinusoïdes à 82/110/220 Hz) pour mesurer les `PeakInfo` (snr, width, harmonicSupport) et produire un CSV pour calibration.
- Ajuster dynamiquement les poids (`wYin`) ou le `consensus bias` et faire un test rapide.

Dis-moi quelle suite tu préfères (script de test / réglages automatiques / visualisations supplémentaires).
