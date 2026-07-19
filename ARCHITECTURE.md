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
- Tâches lourdes (scan, analyse qualité, enrichissement) hors du cycle requête/réponse : file de jobs interne (better-queue ou BullMQ si Redis ajouté plus tard — démarrer sans Redis).
- `ffmpeg`/`ffprobe` invoqués comme binaires externes (pas de bindings natifs fragiles).

## Base de données

- **SQLite** (fichier unique, mode WAL), accès via Drizzle ORM.
- Tables principales : `artists`, `albums`, `tracks`, `track_quality`, `playlists`, `playlist_tracks`, `users`, `user_tracks`, `music_requests`, `music_request_items`, `user_import_directories`, `import_jobs`, `devices`, `cache_state` (pistes hors ligne par appareil), `scan_log`.
- `tracks` stocke : chemin relatif, hash (BLAKE3 ou SHA-256 en flux), taille, durée, tags canoniques, IDs MusicBrainz.
- `track_quality` stocke : codec, sample rate, bit depth, bitrate, canaux, statut (`lossless_verifie` / `lossless_probable` / `lossy` / `inconnue`), provenance, date d'analyse.

## Stockage des fichiers

- Racine unique, ex. `/data/music`, arborescence `Artiste/Album/Titre.ext` (`.wav` ou `.flac`, composants assainis : caractères interdits Windows/Linux remplacés). En cas de collision de nom, suffixe `[hash8]`. Le numéro de piste et l'année (parfois peu fiables dans les tags) seront réintroduits dans le nom en Phase 3 si l'enrichissement les fournit.
- Correspondance dépôt ↔ runtime : les dossiers `storage/music`, `storage/imports`, `storage/covers`, `storage/cache` du projet servent de racines locales de dev et sont montés en volumes Docker sur `/data/music`, `/data/imports`, `/data/artwork`, `/data/cache`. Leur contenu est ignoré par git (`.gitkeep` seulement).
- Le serveur **ne modifie jamais** un fichier audio sans action explicite ; l'import copie puis normalise le nom.
- Zone de staging `HOMESPOTIFY_IMPORT_ROOT` (`/data/imports` en Docker) : un dossier immuable par compte `<userId>_<username>`, avec `inbox`, `processed` et `rejected`. Au boot, seuls les dossiers manquants sont créés ; aucun fichier ni chemin `tracks.path` existant n'est déplacé.
- Récupération depuis un nœud privé : `POST /api/library/fetch-node` accepte une URL directe autorisée ; `GET /api/library/search-remote` et `POST /api/library/import-remote-track` ajoutent la recherche puis la résolution serveur d'un `trackId`. Le média résolu et chaque redirection doivent appartenir à une origine HTTPS exacte de `NODE_FETCH_MEDIA_ALLOWED_ORIGINS`. Le worker répond `202`, écrit le flux borné dans un `.part`, vérifie sa signature FLAC/WAV réelle puis le renomme atomiquement dans l'`inbox` immuable du compte. Un MP4 ne peut pas devenir un FLAC par simple extension. La file et les statuts sont en mémoire ; aucune donnée audio ne transite par SQLite.
- Watcher d'import : WAV/FLAC seulement, taille+mtime stables, lecture des métadonnées sans réécriture, SHA-256 par flux, déduplication hash→ISRC→titre/artiste/durée. L'association automatique à une demande est confinée au même `userId` et exige un résultat unique à score élevé ; sinon le job attend une décision OWNER. L'accès bibliothèque créé est exclusivement `user_tracks(userId, trackId)` pour le propriétaire du dossier.
- Pochettes et miniatures dans `/data/artwork`, nommées par ID d'album.
- La base ne contient jamais d'audio : chemins + hashes uniquement.

## Scanner de bibliothèque

- **Livré (Phase 2)** : CLI `scan` (`src/scripts/scan-cli.ts` → `src/import/scan.ts`) ingère en masse un dossier WAV/FLAC local sans passer par l'upload HTTP. Marche récursive `node:path` (gère les `\` Windows), copie chaque fichier accepté dans la bibliothèque gérée en réutilisant le cœur d'ingestion (`importFromPath`), déduplication par hash SHA-256, un échec par fichier n'interrompt pas le lot. Les dossiers gérés (`musicDir`/`incomingDir`/`coversDir`) sont exclus de la marche pour ne pas re-scanner les copies. Usage : `pnpm --filter @homespotify/api scan -- "C:\Musique" --provenance rip_cd`.
- **À venir** : **watcher** (chokidar) sur le dossier musique pour les ajouts/retraits à chaud ; journalisation dans `scan_log` ; réconciliation des déplacements/suppressions.
- Idempotent et reprenable : re-scanner est sûr (tout doublon est ignoré par hash).

## Gestion des métadonnées

- Extraction locale à l'import : `music-metadata` — lit les tags WAV/FLAC et la pochette embarquée, sans dépendre d'un `ffprobe` installé. Fallback sur le nom de fichier si un tag manque (`Artiste inconnu` / `Album inconnu`).
- Enrichissement optionnel (Phase 3) : MusicBrainz (IDs, année, artiste d'album), Cover Art Archive (pochettes HD).
- Valeurs enrichies stockées en base ; réécriture des tags dans le fichier uniquement sur demande.
- Règles détaillées dans `AUDIO_SOURCING.md`.

## Analyse de qualité audio

- Ingestion bornée : **WAV PCM 16 bit / 44,1 ou 48 kHz**, ou **FLAC lossless 16/24 bit / 44,1, 48, 88,2, 96, 176,4 ou 192 kHz**. Tout autre conteneur ou spec est refusé en `422` à l'import (`music-metadata` fournit `container`, `bitsPerSample`, `sampleRate`).
- Le **statut** (`lossless_verifie` / `lossless_probable` / `lossy` / `inconnue`) vient de la **provenance déclarée** à l'import, pas du conteneur : un WAV issu d'un upscale IA reste `lossy`. Mapping : `rip_cd`/`achat`→`lossless_verifie`, `libre`→`lossless_probable`, `upscale_ia`→`lossy`, `inconnue`→`inconnue`.
- Specs mesurées + statut stockés dans `track_quality` ; re-analyse possible.
- Aucun affichage « lossless » côté client sans statut `lossless_verifie` ou `lossless_probable` (badge distinct pour chacun).

## Streaming (HTTP Range)

- Endpoint `GET /api/tracks/:id/stream` avec support complet **`Range: bytes=`** : `206 Partial Content`, `Accept-Ranges: bytes`, `Content-Range`, `416` si hors borne, `200` complet si pas de Range — indispensable pour le seek et la reprise sur des WAV/FLAC lourds. Parsing isolé et testé dans `lib/range.ts` (formes `a-b`, `a-`, `-n`, multi-range → 200).
- `Content-Type: audio/wav` ou `audio/flac` selon le fichier ; `ETag` = hash SHA-256 du fichier ; `Last-Modified` = mtime ; `Cache-Control: private`.
- Envoi par flux (`fs.createReadStream` borné à `{ start, end }`), jamais de lecture complète en mémoire.
- **Téléchargement offline** : `GET /api/tracks/:id/download` partage le même service de fichier (Range-resumable) mais force le téléchargement via `Content-Disposition: attachment` (fallback ASCII + `filename*=UTF-8''…` pour les tags accentués). Le listing expose `etag` (hash) et `lastModified` par piste pour que le client compare son cache local sans télécharger.
- **Évolution prévue** (Phase 4/5) : lecture mobile WAV/FLAC native via HTTP Range, avec cache offline, reprise et politiques Wi-Fi/cellulaire ; le fichier source n'est jamais altéré ni transformé.

## Application mobile

- **Flutter Android-first**, lecteur via `just_audio` + `audio_service` (lecture arrière-plan, notifications média, lockscreen, files d'attente).
- La vitesse par piste est persistée par compte côté API et appliquée uniquement par le `HomeSpotifyAudioHandler` entre 0,70x et 1,30x. Sur Android compatible, le lecteur Media3 unique passe par le package local `packages/homespotify_just_audio` et HomeSpotify Stretch (Signalsmith 1.3.2) avec **une seule configuration calibrée pour tout ratio actif** (120 ms / 30 ms ; bypass complet à 1,00x) — un profil dépendant du ratio ne peut pas être réappliqué en cours de flux (voir L-046) ; Sonic n'est utilisé qu'en fallback exclusif. Chaque changement de piste force d'abord 1,00x et vide le DSP, empêchant tout héritage entre titres ; aucun fichier audio n'est transformé.
- Le BPM descriptif vient d'abord des tags existants ; à défaut, une tâche serveur asynchrone décode un flux PCM mono borné pour estimer le tempo sans fichier intermédiaire ni modification de la source. Une confiance faible est présentée comme approximative.
- Écrans MVP : bibliothèque (artistes/albums/pistes), recherche, lecteur, file d'attente, gestion hors ligne, réglages (streaming/cache WAV).
- Affiche systématiquement le badge de qualité mesurée de chaque piste.
- Le client v1 est l'app Flutter décrite dans `MOBILE_ARCHITECTURE.md`.

## Cache hors ligne

- Téléchargement explicite par piste/album/playlist vers le stockage local de l'app (route unitaire `download` livrée en Phase 2/3 ; groupage album/playlist à venir).
- Table `cache_state` côté serveur + manifeste local côté client : synchronisation par comparaison des `etag`/`lastModified` exposés au listing (identité par hash).
- Cache offline au format original WAV ou FLAC ; la gestion d'espace passe par quotas, suppression locale et priorités utilisateur.
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

NŒUD PRIVÉ
App → URL HTTPS autorisée → POST fetch-node → 202 + suivi du job
→ Flux borné vers `.part` → renommage atomique dans l'inbox du compte
→ Watcher existant (hash + déduplication + import) → invalidation différée de la bibliothèque

ÉCOUTE
App mobile → Auth (JWT) → Parcourt bibliothèque (API paginée)
→ Play → GET /stream (Range) → WAV/FLAC natif
→ Seek/reprise via Range

HORS LIGNE
App → Sélection pistes → Téléchargement WAV/FLAC original → Manifeste local
→ Mode avion → Lecture locale → Reconnexion → Sync cache_state
```
