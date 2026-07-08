# ARCHITECTURE.md — HomeSpotify

Architecture cible. Les choix sont justifiés dans `TECH_DECISIONS.md` ; ce fichier décrit le *comment*.

## Vue d'ensemble

```
[App mobile / Web]  ⇄ HTTPS/VPN ⇄  [Caddy reverse proxy]
                                        │
                                  [API Node.js/Fastify]
                                   │        │       │
                              [SQLite]  [Stockage  [Workers
                               (bib.)    fichiers]  import/scan/analyse]
```

Un seul serveur, déployé en **Docker Compose** (api, proxy, monitoring). Les fichiers audio vivent sur le système de fichiers hôte, montés en volume.

## Backend

- **Node.js LTS + TypeScript + Fastify.**
- Rôles : API REST (bibliothèque, lecture, import), service de streaming, orchestration des workers.
- Tâches lourdes (scan, analyse qualité, transcodage) hors du cycle requête/réponse : file de jobs interne (better-queue ou BullMQ si Redis ajouté plus tard — démarrer sans Redis).
- `ffmpeg`/`ffprobe` invoqués comme binaires externes (pas de bindings natifs fragiles).

## Base de données

- **SQLite** (fichier unique, mode WAL), accès via Drizzle ORM.
- Tables principales : `artists`, `albums`, `tracks`, `track_quality`, `playlists`, `playlist_tracks`, `users`, `devices`, `cache_state` (pistes hors ligne par appareil), `import_jobs`, `scan_log`.
- `tracks` stocke : chemin relatif, hash (BLAKE3 ou SHA-256 en flux), taille, durée, tags canoniques, IDs MusicBrainz.
- `track_quality` stocke : codec, sample rate, bit depth, bitrate, canaux, statut (`lossless_verifie` / `lossless_probable` / `lossy` / `inconnue`), provenance, date d'analyse.

## Stockage des fichiers

- Racine unique, ex. `/data/music`, arborescence `Artiste/Album/Titre.wav` (composants assainis : caractères interdits Windows/Linux remplacés). En cas de collision de nom, suffixe `[hash8]`. Le numéro de piste et l'année (peu fiables dans les tags WAV) seront réintroduits dans le nom en Phase 3 si l'enrichissement les fournit.
- Correspondance dépôt ↔ runtime : les dossiers `storage/music`, `storage/imports`, `storage/covers`, `storage/cache` du projet servent de racines locales de dev et sont montés en volumes Docker sur `/data/music`, `/data/incoming`, `/data/artwork`, `/data/cache`. Leur contenu est ignoré par git (`.gitkeep` seulement).
- Le serveur **ne modifie jamais** un fichier audio sans action explicite ; l'import copie puis normalise le nom.
- Zone de staging `/data/incoming` pour les uploads avant analyse/validation.
- Pochettes et miniatures dans `/data/artwork`, nommées par ID d'album.
- La base ne contient jamais d'audio : chemins + hashes uniquement.

## Scanner de bibliothèque

- **Livré (Phase 2)** : CLI `scan` (`src/scripts/scan-cli.ts` → `src/import/scan.ts`) ingère en masse un dossier WAV local sans passer par l'upload HTTP. Marche récursive `node:path` (gère les `\` Windows), copie chaque WAV dans la bibliothèque gérée en réutilisant le cœur d'ingestion (`importFromPath`), déduplication par hash SHA-256, un échec par fichier n'interrompt pas le lot. Les dossiers gérés (`musicDir`/`incomingDir`/`coversDir`) sont exclus de la marche pour ne pas re-scanner les copies. Usage : `pnpm --filter @homespotify/api scan -- "C:\Musique" --provenance rip_cd`.
- **À venir** : **watcher** (chokidar) sur le dossier musique pour les ajouts/retraits à chaud ; journalisation dans `scan_log` ; réconciliation des déplacements/suppressions.
- Idempotent et reprenable : re-scanner est sûr (tout doublon est ignoré par hash).

## Gestion des métadonnées

- Extraction locale à l'import : `music-metadata` — lit les tags **RIFF INFO** et **ID3v2 embarqué** des WAV, plus la pochette embarquée, sans dépendre d'un `ffprobe` installé. Fallback sur le nom de fichier si un tag manque (`Artiste inconnu` / `Album inconnu`).
- Enrichissement optionnel (Phase 3) : MusicBrainz (IDs, année, artiste d'album), Cover Art Archive (pochettes HD).
- Valeurs enrichies stockées en base ; réécriture des tags dans le fichier uniquement sur demande.
- Règles détaillées dans `AUDIO_SOURCING.md`.

## Analyse de qualité audio

- Ingestion bornée : **WAV PCM 16 bit / 44,1 ou 48 kHz uniquement**. Tout autre conteneur ou spec est refusé en `422` à l'import (`music-metadata` fournit `container`, `bitsPerSample`, `sampleRate`).
- Le **statut** (`lossless_verifie` / `lossless_probable` / `lossy` / `inconnue`) vient de la **provenance déclarée** à l'import, pas du conteneur : un WAV issu d'un upscale IA reste `lossy`. Mapping : `rip_cd`/`achat`→`lossless_verifie`, `libre`→`lossless_probable`, `upscale_ia`→`lossy`, `inconnue`→`inconnue`.
- Specs mesurées + statut stockés dans `track_quality` ; re-analyse possible.
- Aucun affichage « lossless » côté client sans statut `lossless_verifie` ou `lossless_probable` (badge distinct pour chacun).

## Streaming (HTTP Range)

- Endpoint `GET /api/tracks/:id/stream` avec support complet **`Range: bytes=`** : `206 Partial Content`, `Accept-Ranges: bytes`, `Content-Range`, `416` si hors borne, `200` complet si pas de Range — indispensable pour le seek et la reprise sur des WAV lourds (~50 Mo). Parsing isolé et testé dans `lib/range.ts` (formes `a-b`, `a-`, `-n`, multi-range → 200).
- `Content-Type: audio/wav` ; `ETag` = hash SHA-256 du fichier ; `Last-Modified` = mtime ; `Cache-Control: private`.
- Envoi par flux (`fs.createReadStream` borné à `{ start, end }`), jamais de lecture complète en mémoire.
- **Téléchargement offline** : `GET /api/tracks/:id/download` partage le même service de fichier (Range-resumable) mais force le téléchargement via `Content-Disposition: attachment` (fallback ASCII + `filename*=UTF-8''…` pour les tags accentués). Le listing expose `etag` (hash) et `lastModified` par piste pour que le client compare son cache local sans télécharger.
- **Évolution prévue** (Phase 4/5) : mode transcodé à la volée WAV → Opus (~128–192 kbps) pour le mobile en données cellulaires ; le fichier source n'est jamais altéré.

## Application mobile

- **React Native + Expo**, lecteur via `react-native-track-player` (lecture arrière-plan, notifications média, files d'attente).
- Écrans MVP : bibliothèque (artistes/albums/pistes), recherche, lecteur, file d'attente, gestion hors ligne, réglages (qualité streaming/cache).
- Affiche systématiquement le badge de qualité mesurée de chaque piste.
- Avant l'app native, un client **web mobile-first** (PWA) sert de premier client (Phase 4).

## Cache hors ligne

- Téléchargement explicite par piste/album/playlist vers le stockage local de l'app (route unitaire `download` livrée en Phase 2/3 ; groupage album/playlist à venir).
- Table `cache_state` côté serveur + manifeste local côté client : synchronisation par comparaison des `etag`/`lastModified` exposés au listing (identité par hash).
- Choix de qualité du cache : original ou Opus transcodé (économie d'espace).
- Lecture hors ligne 100 % locale (mode avion) ; purge LRU configurable par plafond d'espace.

## Authentification

- Comptes locaux (usage personnel/familial), mots de passe hachés **Argon2id**.
- Sessions par **JWT court + refresh token** révocable par appareil (table `devices`).
- Toutes les routes authentifiées par défaut ; rate limiting sur `/auth`.

## Accès distant sécurisé

- **Par défaut : VPN WireGuard (via Tailscale)** — aucune exposition publique, surface d'attaque minimale.
- Option ultérieure : exposition HTTPS via Caddy (certificats automatiques) + rate limiting + fail2ban, seulement si le VPN devient trop contraignant.
- Jamais d'API exposée en HTTP clair hors localhost.

## Sauvegardes

- **DB** : snapshot SQLite quotidien (`VACUUM INTO`), rétention 30 jours.
- **Musique + artwork** : sauvegarde incrémentale `restic` vers un second disque, idéalement + une cible hors site.
- Test de restauration documenté et exécuté au moins une fois avant la mise en production (critère `PROJECT.md`).

## Logs

- **pino** (JSON structuré), niveaux par module, rotation par taille/durée.
- Journaliser : imports, scans, analyses qualité, authentifications, erreurs de streaming.
- Jamais de secrets ni de tokens dans les logs.

## Monitoring

- Endpoint `/health` (DB, disque, workers).
- **Uptime Kuma** auto-hébergé pour la disponibilité + alertes (mail/notification).
- Métriques minimales : espace disque restant, taille de bibliothèque, jobs en échec.

## Flux utilisateur (schéma)

```
AJOUT
Utilisateur → Upload/dépôt fichier → Staging → Analyse (ffprobe + spectral)
→ Statut qualité + doublon check → Normalisation nom → /data/music
→ Métadonnées (tags + MusicBrainz) → Bibliothèque (SQLite) → Visible dans l'app

ÉCOUTE
App mobile → Auth (JWT) → Parcourt bibliothèque (API paginée)
→ Play → GET /stream (Range) → Direct FLAC (Wi-Fi) ou Opus (cellulaire)
→ Seek/reprise via Range

HORS LIGNE
App → Sélection pistes → Téléchargement (original ou Opus) → Manifeste local
→ Mode avion → Lecture locale → Reconnexion → Sync cache_state
```
