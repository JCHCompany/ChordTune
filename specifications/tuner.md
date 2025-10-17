# Tuner hybride DSP+IA — Spécification produit et technique

## 0) Objectif
Construire un **accordeur guitare** temps réel ultra-robuste qui :
- **Accroche** très vite (dès qu’on frôle la corde),
- **Reste locké** malgré le bruit, les transitoires (toux, tasse), et les partiels dominants,
- **Suit** la fondamentale f0 sur toute la plage (~70–1200 Hz) avec peu d’erreurs d’octave,
- Offre **deux vues** :
  - **Simple** (grand affichage note/cents + stabilité),
  - **Scientifique** (spectre/spectrogramme + métriques internes),
- S’intègre au code Flutter existant, **0 issue** à `flutter analyze`, et livrable **en une passe**.

## 1) Résumé du pipeline (vue d’ensemble)
1. **Capture** audio non-traitée (unprocessed) à 48 kHz ou 44.1 kHz.
2. **Prétraitements** :
   - DC-blocker léger, notch secteur 50/60 Hz (optionnel),
   - **Décimation multi-taux** avec **FIR anti-aliasing** (mode « Spectroid-like ») → plusieurs bandes de travail, dont une **basse fréquence** à forte résolution,
   - Fenêtrage **Hann** per-frame, **overlap** (75% typique).
3. **Spectre** : FFT in-place (pure Dart OK). **Normalisation cohérente** :
   - puissance par bin = |X[k]|^2 / N^2,
   - correction de fenêtre via **ENBW** si PSD dB/Hz affichée,
   - **log-binning** (option) density-preserving pour la vue scientifique.
4. **Détecteurs f0 en parallèle** :
   - **YIN** (domaine temps),
   - **HPS/HSS** (somme harmonique sur spectre),
   - **IA légère** (CREPE-lite / SPICE TFLite) sur trame 40–64 ms, hop 10 ms.
5. **Fusion candidats** (mélange d’experts) :
   - Score final = pondération de (conf_IA, SNR_dsp, score_peigne) − pénalités d’octave,
   - **Rescue fondamentale** (candidat/2, /3) si gain peigne ≥ 4–6 dB.
6. **Tracker** (cents) : médiane 3 frames → **filtre α–β** (ou Kalman) avec hystérésis LOCK/SEARCH, **Transient Shield** (gel sur transitoires 150–250 ms).
7. **UI** :
   - **Simple** : note/cent, barre de stabilité, état (LOCKED/SEARCH/SHIELD),
   - **Scientifique** : spectrogramme multi-taux, curseurs f0, scores, SNR, flux, flatness, harmonicité, conf_IA.

## 2) Contraintes & cibles
- **Latence** totale (capture→affichage) ≤ 60–80 ms.
- **Taille fenêtre** : 64 ms max (32–64 ms recommandé), **hop** 10 ms.
- **CPU** : tenir sur mid-range Android (1–2 ms/frame budget IA quantized int8).
- **Robustesse** : pas d’unlock intempestif; gestion outliers; fausses octaves < 1%.
- **Qualité** : `flutter analyze` **zéro issue**, tests unitaires & intégration.

## 3) Acquisition & tampon
- **Source** : Android **unprocessed** (AGC/AEC/NS off). 48 kHz (priorité) ou 44.1 kHz.
- **Tampon** circulaire audio → frames de traitement (par taux de décimation).
- **Horloge** : timestamps par frame pour synchroniser IA/DSP/affichage.

## 4) Prétraitements
- **DC-blocker** IIR léger (z^-1 feedback), activable/désactivable.
- **Notch secteur** 50/60 Hz activable.
- **Décimation multi-taux** (niveau 0..9 comme Spectroid) :
  - Chaque niveau applique **FIR LP** (≥ 60 dB rejection hors-bande) puis **downsample**.
  - Exemple : niveaux 0..5 couvrent basses → médiums; plus le niveau est haut, plus la bande utile BF est propre; 0 = brute (peu lisible BF).
  - Implémenter une **échelle de mapping** niveau → (Fc LP, ordre FIR, facteur d) fournie en constantes.
- **Fenêtrage** : Hann. **Overlap** 75% (fenêtre glissante par hop 10 ms).

## 5) Spectre & normalisation
- **FFT** in-place (pure Dart).
- **Puissance par bin** : power[k] = |X[k]|^2 / N^2.
- **Bins DC/Nyquist** : scaling bord **1/sum(window)** (évite boost artificiel BF).
- **Option PSD dB/Hz** : power_density = power / (bin_width_Hz * ENBW_window). ENBW(Hann) ≈ 1.5 bins.
- **Averages** : moyenne **linéaire** (EMA) avant dB; dB = 10*log10(power).
- **Log-binning** (vue scientifique) : somme linéaire normalisée par largeur en Hz (density-preserving).

## 6) Détecteurs f0 (trois voies)
### 6.1 YIN (domaine temps)
- Fenêtre 32–64 ms, auto-corr améliorée; seuil `yin_threshold` ajustable.
- Sorties : f0_yin, conf_yin ∈ [0,1].

### 6.2 HPS/HSS (spectre)
- Cherche maximum local, puis **somme harmonique** sur k, 2k, 3k, 4k (poids décroissants, ex 1, 0.8, 0.6, 0.4).
- **Rescue fondamentale** : si un pic fort à 2f0/3f0 domine, tester f0/2, f0/3 avec peigne; accepter si gain ≥ 4–6 dB.
- Sorties : f0_hps, score_peigne ∈ [0,1], snr_dsp (pic – médiane bande).

### 6.3 IA légère (TFLite)
- Modèle : **CREPE-lite** ou **SPICE** (quantized int8 si possible).
- Entrée : trame 40–64 ms mono normalisée (post-prétraitements), hop 10 ms.
- Sorties : f0_ai (Hz), conf_ai ∈ [0,1].
- Implémentation : `tflite_flutter` + delegate NNAPI si dispo.

## 7) Fusion des candidats (mélange d’experts)
- **Candidats** : {f0_ai, f0_yin, f0_hps} avec scores {conf_ai, conf_yin, norm(score_peigne), snr_dsp}.
- **Pénalités d’octave** : si |cents(candidate, f_prev)| ≈ ±1200, pénalité forte; ±700–900 pénalité moyenne.
- **Prior accordage** (option) : si une corde est sélectionnée, prioriser ±200 cents autour de sa note attendue; tolérance > en mode SEARCH.
- **Score global** (plain text) :
  - score = w_ai*conf_ai + w_hps*norm(score_peigne) + w_snr*norm(snr_dsp) + w_yin*conf_yin − penalty_octave.
  - Choisir f0_candidate = argmax(score).
- **Médiane 3 frames** sur **cents** avant envoi au tracker.

## 8) Tracker f0 (suivi + états)
- Espace **cents** (log-fréquence).
- **Filtre α–β** (ou Kalman) :
  - α ≈ 0.6, β ≈ 0.2 (par défaut), réglables.
  - `maxJumpLockedCents` < `maxJumpSearchCents`.
- **États** :
  - SEARCH → LOCKED si SNR ≥ `lockThresholdDb` pendant `holdInMs`.
  - LOCKED → SEARCH si SNR < `unlockThresholdDb` pendant `holdOutMs`.
- **Transient Shield** : si transitoire détecté (ΔRMS ≥ `energyJumpDb` en ≤20 ms **ET** spectral_flux haut **ET/OU** spectral_flatness > seuil **ET/OU** harmonicité chute) : **geler** la sortie 150–250 ms (prédiction pure du tracker), ignorer la frame pour décisions.
- **Unlock concurrent** : si un candidat hors fenêtre ±W cents est **≥ crossDb** plus fort **pendant ≥ crossMs** → bascule contrôlée.

## 9) Mesures de transitoires et qualité
- **RMS dB** par frame; **ΔRMS**.
- **Spectral flux** (différence frame à frame des magnitudes normalisées).
- **Spectral flatness (SFM)** : géométrique / arithmétique (0=tonal, 1=bruit).
- **Harmonicité** : ratio énergie sur peigne vs bande.
- Ces mesures alimentent : Shield, lock/unlock, et affichage « stabilité ».

## 10) Réduction de bruit (optionnelle, légère)
- **Noise gate** adaptatif basé sur SNR + flatness (avant détection f0).
- **Soustraction spectrale** très légère (EMA du bruit de fond) si nécessaire.
- **RNNoise-lite** possible mais tester le coût CPU et la latence; ne pas dégrader f0.

## 11) UI / UX
### 11.1 Vue Simple (Tuner)
- Grande **note + offset en cents**, aiguille ou barre de déviation ±50 cents.
- **Badge état** : LOCKED (vert/cyan), SEARCH (ambre), SHIELD (bleu/gris).
- **Barre stabilité** (SNR + harmonicité combinées).
- **Option accordage** (EADGBE / custom) → prior f0.

### 11.2 Vue Scientifique
- **Spectrogramme** multi-taux (comme Spectroid) avec curseur **f0** (ligne verticale), **bande ±cents** ombrée.
- **Courbes** temps-réel :
  - f0_yin, f0_hps, f0_ai, f0_final,
  - SNR, score_peigne, conf_ai, flatness, flux, RMS,
  - état du tracker, fenêtres de Shield.
- **Panneau Debug** (toggle) :
  - histogramme de candidats, pénalités d’octave, décisions lock/unlock, temps de latence par étape.
- **Bascule facile** Simple ↔ Scientifique (toggle en AppBar).

## 12) Réglages (exposés dans l’app)
- **Capture/Prétraitements** : DC-block, notch 50/60 Hz, niveau de **Décimation** (0..9).
- **Détection** : YIN on/off + seuil, HPS on/off + nb d’harmoniques, IA on/off + modèle (CREPE-lite/SPICE), fenêtre et hop.
- **Fusion** : poids w_ai, w_hps, w_snr, w_yin; pénalité octave; prior accordage (on/off) + tolerance cents.
- **Tracker** : lockThresholdDb, unlockThresholdDb, holdInMs, holdOutMs, lockWindowCents, maxJumpLockedCents, maxJumpSearchCents, α, β.
- **Transient Shield** : on/off, shieldMs, energyJumpDb, sfmThresh, harmDrop, fluxThresh, crossDb, crossMs.
- **Affichage** : lissage UI (médiane on/off), minDisplayCents (p. ex. 5), minDisplayMs (100), showTrackerState, showEvents.
- **Performance** : limiter FPS spectrogramme, downsample affichage, mode économie CPU.

## 13) Journalisation & export
- **Frame log** optionnel JSON : timestamps, f0_* (yin/hps/ai/final), scores, SNR, flatness, flux, état tracker, décisions.
- **Snapshot** PNG de la vue scientifique.
- **Replay** : charger un wav + reproduire pipeline (mode dev).

## 14) Performance & budgets
- **FFT** : < 0.5 ms / frame (taille 1024–4096 selon bande).
- **IA** : < 1.5 ms / frame (quantized int8, 64 ms window, hop 10 ms).
- **Dessins** : throttling à 30–45 FPS (vue simple), 20–30 FPS (scientifique).
- **Latence** bout-en-bout ≤ 80 ms.

## 15) Structure de code (Flutter)
```
lib/
  dsp/
    preproc.dart            // DC, notch, FIR LP, décimation
    fft.dart                // FFT in-place, fenêtres, ENBW helpers
    yin.dart                // YIN + conf
    hps.dart                // peigne harmonique + SNR
    features.dart           // flux, flatness, harmonicité, RMS
    fusion.dart             // scoring candidats + pénalités
    tracker.dart            // α–β, états, Shield
  ai/
    f0_model.dart           // wrapper TFLite, loading, inference
  engine/
    spectroid_engine.dart   // orchestrateur frames → SpectroidFrame étendu
    ring_buffer.dart
  ui/
    views/
      tuner_view.dart       // Vue Simple
      lab_view.dart         // Vue Scientifique
    painters/
      spectrum_painter.dart // spectrogramme + overlays
    widgets/
      state_badge.dart, stability_bar.dart, debug_panels.dart
  config/
    spectroid_config.dart   // tous les réglages + defaults + persist
  bloc/
    spectroid_cubit.dart    // états (incl. trackState, f0*, scores, SHIELD)
```

## 16) Pseudo-code clés
### 16.1 Boucle de traitement
```
pour chaque frame audio:
  preproc = dc_block + notch(50/60Hz?)
  multi_rate_frames = decimate_with_FIR_levels(preproc)
  pour chaque bande:
    fft = FFT(Hann(frame), N)
    power = |fft|^2 / N^2; power_db = 10*log10(EMA(power))
  yin -> (f0_yin, conf_yin)
  hps -> (f0_hps, score_peigne, snr_dsp)
  ai  -> (f0_ai, conf_ai)  // TFLite si activé

  metrics = {RMS, spectral_flux, flatness, harmonicite}
  candidate = fuse_candidates()
  f0_smoothed = median3(cents(candidate))

  if transient_detected(metrics):
    tracker.freeze(shieldMs)
  else:
    tracker.update(f0_smoothed, snr_dsp, metrics)

  emit SpectroidFrameExt { f0_yin, f0_hps, f0_ai, f0_final, scores, metrics, state }
```

### 16.2 Transient Shield (détection)
```
if (ΔRMS_dB >= energyJumpDb in ≤20ms) AND (flatness >= sfmThresh OR flux>=fluxThresh OR harmonicite_drop>=harmDrop):
  return TRUE  // geler sortie tracker pendant shieldMs
```

## 17) Valeurs par défaut (proposées)
- **Fenêtre** 64 ms, **hop** 10 ms.
- **Décimation** niveau 5 par défaut; 0..9 disponible.
- **YIN** threshold 0.15.
- **HPS** harmonics = 4; rescue gain ≥ 5 dB.
- **Fusion** : w_ai=0.45, w_hps=0.35, w_snr=0.15, w_yin=0.05; penalty_octave fort à ±1200 cents.
- **Tracker** : lock=+6 dB, unlock=+3 dB, holdIn=150 ms, holdOut=300 ms, lockWindow=25 cents, maxJumpLocked=30, maxJumpSearch=150, α=0.6, β=0.2.
- **Shield** : on, shieldMs=200, energyJumpDb=10, sfmThresh=0.5, fluxThresh=0.6, harmDrop=0.2, crossDb=12, crossMs=200.
- **UI** : médiane3 on, minDisplayCents=5, minDisplayMs=100, showTrackerState on, showEvents on.

## 18) Tests & validation
- **Synthétiques** :
  - sinusoïdes aux fréquences cibles (E2=82.41, A2=110, … jusqu’à E5),
  - sweeps, bursts, SNR variés (0–30 dB), bruits (rose/blanc),
  - attaques/relâches, vibrato ±30 cents, bends ±200 cents.
- **Réels** :
  - prises micro smartphone en environnement calme et bruité,
  - perturbations (toux, clinks), arrière-plan TV/YouTube.
- **Critères** :
  - temps d’accrochage, taux d’erreurs d’octave, stabilité (std en cents), taux unlock sous bruit, latence bout-en-bout.
- **Automatisation** : goldens + CI; `flutter analyze` zéro issue; tests unitaires pour fusion/tracker/transient; tests d’intégration sur frames enregistrées.

## 19) Livraison « en une fois »
- Implémentation complète des modules ci-dessus + réglages + deux vues.
- Bench CPU/latence sur 2–3 appareils Android.
- Documentation brève des API internes et mapping des réglages → comportements.
- Tous warnings corrigés (analyzer, lints), formatage `dart format`.

## 20) Notes d’intégration IA
- Prévoir **fallback** si modèle IA absent (mode DSP-only).
- Charger modèle au démarrage (isolate si nécessaire), warm-up une passe.
- Quantization int8 prioritaire pour CPU; tester NNAPI delegate.

---
**But final** : un tuner qui accroche immédiatement, reste stable, explique ce qu’il fait (vue scientifique), et dont le code est propre, testé et maintenable. Merci d’implémenter en respectant strictement cette spécification. 

