# AUDIO_SOURCING.md — Stratégie d'acquisition audio

Document de référence pour toute fonctionnalité d'import. Règle d'or : **la qualité affichée est la qualité mesurée, jamais la qualité espérée.**

> **Périmètre d'ingestion (décidé 2026-07-08)** : HomeSpotify n'importe que du **WAV PCM 16 bit / 44,1 ou 48 kHz**. L'utilisateur gère l'acquisition et l'optimisation en amont (rip CD, achat, upscale AudioSR, etc.) et fournit un WAV final. Le conteneur PCM ne prouvant rien sur l'origine, le **statut qualité est déterminé par la provenance déclarée à l'import** — voir le mapping en fin de section « Détection de qualité réelle ». Un WAV issu d'un upscale IA reste `lossy`.

## Vérité technique : YouTube et le lossless

- YouTube encode tout l'audio en **lossy** (Opus ~130–160 kbps, AAC ~128 kbps). L'original non compressé n'est jamais servi.
- Télécharger depuis YouTube donne donc au mieux un Opus ~160 kbps. C'est écoutable, ce n'est **pas** de la qualité CD.
- Convertir cet audio en FLAC produit un fichier plus gros **sans récupérer aucune donnée perdue** : c'est du « fake lossless ».
- Conséquence projet : toute piste issue d'une source lossy est étiquetée `lossy` avec son débit source, quel que soit son format de stockage.

## Formats : lossy vs lossless

| Format | Type | Compression | Usage dans le projet |
|---|---|---|---|
| WAV | Lossless | Aucune (PCM brut) | Accepté à l'import, converti en FLAC (même qualité, ~50 % plus petit, tags natifs) |
| FLAC | Lossless | Sans perte | **Format de stockage de référence** |
| ALAC | Lossless | Sans perte | Accepté (écosystème Apple), conversion FLAC possible sans perte |
| MP3 | Lossy | Avec perte | Accepté tel quel, jamais converti en lossless |
| AAC | Lossy | Avec perte (meilleur que MP3 à débit égal) | Accepté tel quel |
| Opus | Lossy | Avec perte (le plus efficace des lossy) | Accepté ; format cible du transcodage streaming mobile |

- **Lossy → lossless est impossible.** Lossless → lossless (WAV→FLAC) est sans perte. Lossy → lossy (réencodage) dégrade encore : à éviter sauf transcodage de diffusion à la volée (le fichier source n'est jamais altéré).
- Qualité CD = PCM 16 bit / 44,1 kHz. Le Hi-Res (24 bit / 96+ kHz) est un bonus, pas un objectif.

## Voie gratuite autorisée

Sources légitimes pouvant fournir du vrai lossless ou du lossy assumé :

1. **Fichiers déjà possédés** (achats passés, rips existants).
2. **CD rippés** (CD possédés) : rip sécurisé → FLAC = vraie qualité CD vérifiable.
3. **Artistes/labels distribuant du FLAC gratuit** (sites officiels, promos).
4. **Bandcamp gratuit / name-your-price** : téléchargement FLAC officiel, souvent à prix libre.
5. **Musique libre** (Creative Commons) : Free Music Archive, Jamendo, ccMixter.
6. **Archives autorisées** : Internet Archive (collections sous licence, ex. concerts autorisés type etree, souvent en FLAC).

## Voie payante low-cost

Par coût croissant, pour les titres introuvables gratuitement :

1. **CD d'occasion à ripper** : souvent 1–5 €/album, vraie qualité CD, on possède le support.
2. **Bandcamp payant** : FLAC sans DRM, majorité du prix à l'artiste.
3. **Qobuz Download (boutique)** : achat définitif FLAC qualité CD ou Hi-Res, sans DRM.
4. Autres boutiques FLAC sans DRM : 7digital, HDtracks (catalogues à vérifier).

Critère d'achat : fichier **sans DRM**, téléchargeable, format lossless annoncé et vérifiable après analyse.

## Limites des abonnements streaming

- Spotify, Deezer, Apple Music, YouTube Music, Tidal, Qobuz (streaming) livrent des flux **chiffrés/DRM** liés à l'abonnement.
- On n'y « possède » rien : la musique disparaît avec l'abonnement.
- Leur mode hors ligne est interne à leur app, inutilisable par HomeSpotify.
- Un abonnement lossless (Qobuz/Tidal) reste utile pour *écouter/découvrir*, pas pour *constituer* la bibliothèque.

## Pourquoi ne pas contourner les DRM

- **Légal** : le contournement de mesures techniques de protection est illégal dans la plupart des juridictions (dont l'UE), indépendamment de l'usage privé.
- **Éthique** : les artistes ne sont pas rémunérés pour une copie extraite.
- **Technique** : les flux extraits sont de toute façon lossy dans la plupart des cas, et les outils de contournement cassent régulièrement.
- Position projet : **aucune fonctionnalité, doc ou dépendance liée au contournement DRM.**

## Workflow recommandé

```
Titre voulu
  → Déjà possédé (disque/rip) ?          → oui : importer
  → Dispo gratuit légal (Bandcamp, CC,
    site artiste, archive autorisée) ?    → oui : télécharger FLAC si dispo
  → Budget ok ?                           → CD occasion à ripper, sinon Bandcamp/Qobuz
  → Sinon                                 → liste d'attente « à acquérir »
Import (toutes voies)
  → Analyse qualité (ffprobe) → étiquette lossy/lossless + specs mesurées
  → Vérification doublon (hash) → normalisation nom/arborescence
  → Enrichissement métadonnées → entrée en bibliothèque
```

## Détection de qualité réelle

À l'import, pour chaque fichier :

1. **Analyse conteneur/codec** (ffprobe) : codec, fréquence d'échantillonnage, profondeur de bits, débit, durée, canaux.
2. **Classement** :
   - Codec lossy (MP3/AAC/Opus/Vorbis) → `lossy`, débit stocké.
   - Codec lossless (FLAC/ALAC/WAV) → candidat `lossless`, à confirmer.
3. **Détection de fake lossless** (fichier lossless issu d'une source lossy) : analyse spectrale — un cutoff net vers 16–20 kHz trahit un réencodage. Outils candidats : analyse spectrale ffmpeg, projets type « Lossless Audio Checker » (voir `À vérifier`).
4. **Statuts stockés en base** : `lossless_verifie`, `lossless_probable`, `lossy`, `inconnue` — plus les specs mesurées et la provenance déclarée.
5. La provenance est enregistrée à l'import et **détermine le statut** (implémenté Phase 2, `import-service.ts`) :

| Provenance déclarée | Statut attribué | Exemple |
|---|---|---|
| `rip_cd` | `lossless_verifie` | CD personnel rippé en WAV |
| `achat` | `lossless_verifie` | WAV/FLAC acheté (converti WAV) puis importé |
| `libre` | `lossless_probable` | Bandcamp gratuit, Creative Commons |
| `upscale_ia` | `lossy` | Sortie AudioSR — hautes fréquences générées, **pas** du vrai lossless |
| `inconnue` (défaut) | `inconnue` | Origine non déclarée |

> Note : la détection spectrale de « fake lossless » (§ Détection ci-dessus, point 3) reste pertinente comme garde-fou futur, mais en ingestion WAV-only le statut repose d'abord sur la provenance honnêtement déclarée par l'utilisateur.

## Règles de métadonnées

- Tags lus à l'import (ID3v2, Vorbis comments, MP4 tags) ; champs canoniques : artiste, artiste d'album, album, titre, numéro de piste/disque, année, genre, pochette.
- Enrichissement via **MusicBrainz** (IDs stockés) et pochettes via **Cover Art Archive** ; jamais d'écrasement silencieux des tags d'origine — les valeurs enrichies sont stockées en base, le fichier n'est réécrit que sur action explicite.
- La qualité audio (codec, kHz, bits, kbps, statut) est une métadonnée de première classe, affichée dans l'interface.
- Pochette : viser ≥ 1000×1000 ; conserver l'originale, générer des miniatures.
- Noms de fichiers normalisés : `Artiste/Album (Année)/NN - Titre.ext` ; caractères interdits Windows/Linux filtrés.

## À vérifier

- [ ] Outil exact de détection de fake lossless : fiabilité de « Lossless Audio Checker », alternatives maintenues, ou implémentation maison via analyse spectrale ffmpeg.
- [ ] Débits Opus/AAC réellement servis par YouTube en 2026 (les valeurs ~130–160 kbps datent des années précédentes).
- [ ] Disponibilité et catalogue Qobuz Download / 7digital selon le pays de l'utilisateur.
- [ ] Statut légal précis de la copie privée de CD possédés dans la juridiction de l'utilisateur (France : copie privée admise pour usage personnel, à confirmer pour le rip).
- [ ] API MusicBrainz : limites de débit actuelles et politique d'usage pour un serveur personnel.
