# AUDIO_SOURCING.md — Stratégie d'acquisition audio

Document de référence pour toute fonctionnalité d'import. Règle d'or : **la qualité affichée est la qualité mesurée, jamais la qualité espérée.**

> **Périmètre d'ingestion (mis à jour 2026-07-09)** : HomeSpotify n'importe que du **WAV PCM 16 bit / 44,1 ou 48 kHz** ou du **FLAC lossless 16/24 bit / 44,1, 48, 88,2, 96, 176,4 ou 192 kHz**. Le fichier accepté est conservé et streamé tel quel, sans transcodage ni conversion. Le conteneur ne prouvant rien sur l'origine, le **statut qualité est déterminé par la provenance déclarée à l'import** — voir le mapping en fin de section « Détection de qualité réelle ». Un WAV ou FLAC issu d'un upscale IA reste `lossy`.

## Vérité technique : YouTube et le lossless

- YouTube encode tout l'audio en **lossy** (Opus ~130–160 kbps, AAC ~128 kbps). L'original non compressé n'est jamais servi.
- Télécharger depuis YouTube donne donc au mieux un Opus ~160 kbps. C'est écoutable, ce n'est **pas** de la qualité CD.
- Convertir cet audio en WAV ou FLAC produit un fichier plus gros **sans récupérer aucune donnée perdue** : c'est du « fake lossless ».
- Conséquence projet : toute piste issue d'une source lossy est étiquetée `lossy` avec son débit source, quel que soit son format de stockage.

## Formats : lossy vs lossless

| Format | Type | Compression | Usage dans le projet |
|---|---|---|---|
| WAV PCM 16 bit 44,1/48 kHz | Lossless comme conteneur PCM | Aucune (PCM brut) | Accepté et streamé nativement |
| FLAC lossless 16/24 bit 44,1–192 kHz | Lossless | Sans perte | Accepté et streamé nativement, sans décompression stockée ni réencodage |
| MP3 | Lossy | Avec perte | Refusé à l'import ; toute conversion reste hors pipeline HomeSpotify et ne recrée pas la qualité perdue |
| AAC | Lossy | Avec perte (meilleur que MP3 à débit égal) | Refusé à l'import ; toute conversion reste hors pipeline HomeSpotify et ne recrée pas la qualité perdue |
| Opus | Lossy | Avec perte (le plus efficace des lossy) | Refusé à l'import canonique ; autorisé uniquement comme dérivée mobile hors connexion 128/256 kb/s créée depuis un WAV/FLAC conforme |

- **Lossy → lossless est impossible.** Convertir un lossy en WAV ou FLAC ne recrée aucune information ; cela ne fait que stocker un signal déjà dégradé dans un conteneur plus lourd. La seule conversion lossy autorisée est une dérivée Ogg/Opus hors connexion, créée depuis la source canonique lossless sans la remplacer ; elle est toujours affichée comme lossy avec son débit mesuré.
- Qualité CD = PCM 16 bit / 44,1 kHz. Le Hi-Res (24 bit / 96+ kHz) est un bonus, pas un objectif.

## Workflow recommandé

```
Titre voulu
  → Déjà possédé (disque/rip) ?          → oui : importer
  → Dispo gratuit légal (Bandcamp, CC,
    site artiste, archive autorisée) ?    → oui : télécharger WAV/FLAC si dispo
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
   - Tout conteneur autre que WAV PCM ou FLAC lossless → refus à l'import.
   - WAV PCM 16 bit 44,1/48 kHz et FLAC lossless 16/24 bit aux fréquences acceptées → acceptés techniquement, statut déterminé par la provenance déclarée.
3. **Détection de fake lossless** (fichier lossless issu d'une source lossy) : analyse spectrale — un cutoff net vers 16–20 kHz trahit un réencodage. Outils candidats : analyse spectrale ffmpeg, projets type « Lossless Audio Checker » (voir `À vérifier`).
4. **Statuts stockés en base** : `lossless_verifie`, `lossless_probable`, `lossy`, `inconnue` — plus les specs mesurées et la provenance déclarée.
5. La provenance est enregistrée à l'import et **détermine le statut** (implémenté Phase 2, `import-service.ts`) :

| Provenance déclarée | Statut attribué | Exemple |
|---|---|---|
| `rip_cd` | `lossless_verifie` | CD personnel rippé en WAV ou FLAC |
| `achat` | `lossless_verifie` | WAV/FLAC acheté et conforme, ou fichier sans DRM converti manuellement sans prétendre récupérer de qualité |
| `libre` | `lossless_probable` | Bandcamp gratuit, Creative Commons |
| `upscale_ia` | `lossy` | Sortie AudioSR — hautes fréquences générées, **pas** du vrai lossless |
| `inconnue` (défaut) | `inconnue` | Origine non déclarée |

> Note : la détection spectrale de « fake lossless » (§ Détection ci-dessus, point 3) reste pertinente comme garde-fou futur, mais pour les WAV/FLAC acceptés le statut repose d'abord sur la provenance honnêtement déclarée par l'utilisateur.

## Règles de métadonnées

- Tags lus à l'import (WAV RIFF INFO/ID3v2 et FLAC Vorbis comments) ; champs canoniques : artiste, artiste d'album, album, titre, numéro de piste/disque, année, genre, pochette.
- Enrichissement via **MusicBrainz** (IDs stockés) et pochettes via **Cover Art Archive** ; jamais d'écrasement silencieux des tags d'origine — les valeurs enrichies sont stockées en base, le fichier n'est réécrit que sur action explicite.
- La qualité audio (codec, kHz, bits, kbps, statut) est une métadonnée de première classe, affichée dans l'interface.
- Pochette : viser ≥ 1000×1000 ; conserver l'originale, générer des miniatures.
- Noms de fichiers normalisés : `Artiste/Album (Année)/NN - Titre.ext` ; caractères interdits Windows/Linux filtrés.

## À vérifier

- [ ] Outil exact de détection de fake lossless : fiabilité de « Lossless Audio Checker », alternatives maintenues, ou implémentation maison via analyse spectrale ffmpeg.
- [ ] Débits Opus/AAC réellement servis par YouTube en 2026 (les valeurs ~130–160 kbps datent des années précédentes).
- [ ] Disponibilité et catalogue Qobuz Download / 7digital selon le pays de l'utilisateur.
- [ ] API MusicBrainz : limites de débit actuelles et politique d'usage pour un serveur personnel.
