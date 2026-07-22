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
- Correspondance dépôt ↔ runtime : les dossiers `storage/music`, `storage/imports`, `storage/covers`, `storage/cache` du projet servent de racines locales de dev et sont montés en volumes Docker sur `/data/music`, `/data/imports`, `/data/artwork`, `/data/cache`. `storage/cache/offline-opus` ne contient que des dérivées régénérables, jamais une source canonique. Leur contenu est ignoré par git (`.gitkeep` seulement).
- Le serveur **ne modifie jamais** un fichier audio sans action explicite ; l'import copie puis normalise le nom.
- Zone de staging `HOMESPOTIFY_IMPORT_ROOT` (`/data/imports` en Docker) : un dossier immuable par compte `<userId>_<username>`, avec `inbox`, `processed` et `rejected`. Au boot, seuls les dossiers manquants sont créés ; aucun fichier ni chemin `tracks.path` existant n'est déplacé.
- Aucune acquisition distante : la recherche catalogue Deezer + iTunes +
  MusicBrainz/Cover Art Archive ne manipule que métadonnées, images et extraits
  officiels éphémères, puis crée des `music_requests`. L'ajout audio est
  exclusivement manuel via l'inbox locale surveillée et l'association OWNER.
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
- Chaque requête stream/download possède un `X-Request-Id` sûr, propagé dans la réponse et journalisé avec une route normalisée. Les événements `STREAM_*` couvrent auth, stat, Range, ouverture, premiers octets, fin, abandon client et erreur ; ils n'exposent ni chemin absolu, ni Bearer, ni query sensible. Un seul événement terminal est émis par requête.
- **Téléchargement original** : `GET /api/tracks/:id/download` partage le même service de fichier (Range-resumable) mais force le téléchargement via `Content-Disposition: attachment` (fallback ASCII + `filename*=UTF-8''…` pour les tags accentués). Il reste disponible pour l'export explicite de l'original, mais n'est pas le format par défaut du cache mobile.
- **Options hors connexion** : le client demande les trois profils disponibles et leur taille avant de télécharger : `opus-128-v1`, `opus-256-v1` ou `original`. Les tailles Opus sont explicitement estimées depuis la durée et le débit tant que la variante n'est pas matérialisée, puis remplacées par la taille mesurée ; l'original expose sa taille exacte. Une route dédiée sert par Range chaque dérivée Ogg/Opus vérifiée. Si elle n'existe pas, l'API crée ou rejoint un job single-flight pour ce profil et répond `202` jusqu'à disponibilité.
- **Règle de transformation** : le fichier canonique WAV/FLAC n'est jamais altéré. FFmpeg décode la source en flux et produit la dérivée dans un fichier temporaire, avec concurrence serveur bornée ; validation Ogg/Opus, taille et SHA-256 précèdent le renommage atomique. Aucun transcodage n'est effectué sur le téléphone ni à la volée pendant une réponse HTTP.

## Application mobile

- **Flutter Android-first**, lecteur via `just_audio` + `audio_service` (lecture arrière-plan, notifications média, lockscreen, files d'attente).
- `AudioService.init` enregistre le handler avant `runApp` : la lecture ne peut pas démarrer dans un mode local sans service média. Android déclare le foreground service `mediaPlayback`, le `MediaButtonReceiver` et `POST_NOTIFICATIONS`, demandée au lancement sur Android 13+. Le service reste au premier plan pendant une pause et n'est libéré que par un arrêt explicite. Les ressources `@drawable/audio_service_*`, résolues dynamiquement par le plugin, sont protégées du resource shrinker release par `res/raw/keep.xml`; sans elles, la publication du `PlaybackState` échoue avant la création de la notification.
- Le handler audio reste l'unique source de vérité de la file. Chaque rotation proactive du JWT est propagée au handler : les sources Media3, dont les headers sont immuables, sont reconstruites immédiatement avec le nouveau Bearer au même index/position. Le changement de piste revérifie cette divergence et la récupération 401 reste un dernier filet single-flight. Les doublons natifs rapprochés sont supprimés et un état `completed` prématuré peut déclencher une seule auto-avance bornée. Les sources HTTP envoient directement le Bearer au serveur (`useProxyForRequestHeaders: false`) ainsi que des identifiants non secrets de session/file/source.
- La file, l'index, la position, repeat/shuffle et la vitesse sont persistés par compte dans le stockage applicatif. Aucun header ni token n'est sérialisé ; les sources restaurées reçoivent le Bearer courant. Après un lancement manuel, la session revient en pause. Une déconnexion explicite efface cette session locale.
- Une erreur réseau transitoire conserve la piste et sa position au lieu d'utiliser la politique de saut des fichiers réellement invalides. Le retour de connectivité déclenche une reprise immédiate ; si l'interface réseau est présente mais que le serveur reste indisponible, un backoff plafonné à 30 secondes poursuit les tentatives tant que la lecture est demandée.
- Le diagnostic audio normal est un journal JSON Lines persistant et rotatif, initialisé après la première frame ; la trace détaillée est temporaire (15 minutes par défaut). L'écran OWNER/debug `/dev/audio-diagnostics` expose un état sûr, un marqueur utilisateur, l'export et un test guidé. Aucun token, URL complète ou chemin local ne doit être exporté.
- La vitesse par piste est persistée par compte côté API et appliquée uniquement par le `HomeSpotifyAudioHandler` entre 0,70x et 1,30x. Sur Android compatible, le lecteur Media3 unique passe par le package local `packages/homespotify_just_audio` et HomeSpotify Stretch (Signalsmith 1.3.2) avec **une seule configuration calibrée pour tout ratio actif** (120 ms / 30 ms ; bypass complet à 1,00x) — un profil dépendant du ratio ne peut pas être réappliqué en cours de flux (voir L-046) ; Sonic n'est utilisé qu'en fallback exclusif. Chaque changement de piste force d'abord 1,00x et vide le DSP, empêchant tout héritage entre titres ; aucun fichier audio n'est transformé.
- Le BPM descriptif vient d'abord des tags existants ; à défaut, une tâche serveur asynchrone décode un flux PCM mono borné pour estimer le tempo sans fichier intermédiaire ni modification de la source. Une confiance faible est présentée comme approximative.
- Écrans MVP : bibliothèque (artistes/albums/pistes), recherche, lecteur, file d'attente, gestion hors ligne, réglages (qualité originale en ligne/cache Opus compact).
- Affiche systématiquement le badge de qualité mesurée de chaque piste.
- Le client v1 est l'app Flutter décrite dans `MOBILE_ARCHITECTURE.md`.

## Cache hors ligne

- Téléchargement explicite par piste/album/playlist vers le stockage sandboxé de l'app, avec choix **Opus 128 kb/s VBR**, **Opus 256 kb/s VBR** ou **original WAV/FLAC**. Opus 256 est recommandé par défaut mais la préférence peut être mémorisée par appareil. Le serveur partage physiquement chaque dérivée entre les comptes autorisés ; l'autorisation reste vérifiée à chaque demande.
- Table `track_offline_variants` côté serveur (implémentée le 2026-07-22, nom aligné sur la convention `track_*` du schéma — cf. TECH_DECISIONS) : `track_id`, hash source, profil/version encodeur, débit cible et débit mesuré par ffprobe, chemin relatif, taille, SHA-256, états `PENDING|ENCODING|READY|FAILED|STALE` et dates. La clé single-flight contient le profil : une variante 128 ne peut jamais satisfaire une demande 256. L'original ne devient pas une variante serveur : sa route Range existante et son hash canonique sont réutilisés. Table `cache_state` par appareil + manifeste SQLite mobile : état de téléchargement, octets reçus, hash attendu/vérifié et dernière utilisation.
- Les dérivées Opus sont volontairement **lossy** et affichées « Hors ligne · Opus 128 kb/s » ou « Hors ligne · Opus 256 kb/s ». Elles n'héritent jamais du badge lossless de la source. L'option originale conserve le badge issu de l'analyse technique de la source. Les métadonnées sont conservées dans le manifeste mobile ; la pochette est un fichier durable adjacent, partitionné par compte et référencé par convention interne, indépendamment des tags du fichier dérivé.
- Lecture 100 % locale lorsque le serveur est injoignable. Au retour d'un serveur réellement joignable, la sélection de source repasse à l'original WAV/FLAC au prochain chargement de piste ; le morceau Opus déjà commencé se termine localement pour éviter une coupure ou une dérive de position.
- **Session locale hors connexion (Phase 1A.1)** : après une connexion réussie, une identité minimale du compte (jamais de token) est mémorisée dans le stockage sécurisé. Si le serveur est injoignable au démarrage mais qu'une session locale existe, l'application s'ouvre en « Mode hors connexion » (bandeau discret) et donne accès à l'écran Téléchargements, à la bibliothèque reconstruite depuis le manifeste et à la lecture locale. Une panne réseau, un timeout ou un 5xx ne sont jamais un logout ; seuls un logout explicite ou un refus 401 confirmé par un serveur joignable terminent la session. Le retour du serveur rétablit le fonctionnement en ligne sans redémarrer l'application. L'écran Téléchargements, les pochettes locales et les badges de bibliothèque sont alimentés par l'index local partitionné par compte, sans dépendre de `GET /api/tracks` pour s'afficher.
- Phase 1A ne change pas de source au milieu d'un titre. La bascule d'un flux original en erreur vers une copie locale au même index et à la position la plus proche est planifiée en Phase 1C, après qualification du handler. La politique cellulaire explicite est également ultérieure ; le mode actuel reste original en ligne.
- Purge LRU configurable par plafond d'espace. Les variantes serveur sont régénérables et suivent une rétention distincte ; supprimer une variante ne supprime jamais l'original.

## Authentification

- Comptes locaux (usage personnel/familial), mots de passe hachés **Argon2id**.
- Sessions par **JWT court + refresh token** révocable par appareil (table `devices`).
- Le mobile renouvelle automatiquement le JWT 90 secondes avant son expiration et propage immédiatement le nouveau Bearer à toute file audio chargée. Le refresh token est rotatif avec une expiration glissante : tant que l'application reste active et que le serveur accepte les rotations, la session se prolonge sans limite fixe. Une écoute en arrière-plan ne dépend donc pas d'un JWT artificiellement infini ; seuls une révocation, un refus définitif ou une inactivité dépassant la durée du refresh token terminent réellement la session.
- Toutes les routes authentifiées par défaut ; rate limiting sur `/auth`.

## Accès distant sécurisé

- **Par défaut : VPN WireGuard (via Tailscale)** — aucune exposition publique, surface d'attaque minimale.
- Option ultérieure : exposition HTTPS via Caddy (certificats automatiques) + rate limiting + fail2ban, seulement si le VPN devient trop contraignant.
- Jamais d'API exposée en HTTP clair hors localhost.

## Sauvegardes

- **DB** : `scripts/backup_homespotify.ps1` utilise l'API online backup de `better-sqlite3`, exécute `PRAGMA integrity_check`, puis produit un manifest versionné avec taille et SHA-256.
- **Artwork** : les pochettes sont incluses dans chaque sauvegarde serveur.
- **Musique** : exclue par défaut pour garder la sauvegarde quotidienne légère ; `-IncludeMedia` crée une copie complète à placer sur un second disque ou une cible hors site.
- **Secrets** : jamais inclus ; ils restent dans un coffre chiffré distinct.
- **Restauration** : le service doit être arrêté, le manifest/hash/intégrité sont revérifiés et l'ancienne base est conservée en `.pre-restore-*`. La procédure et la matrice de qualification sont dans `STABILIZATION_RUNBOOK.md`.

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

DEMANDE
App → Recherche catalogue Deezer/iTunes/MusicBrainz → Sélection d'un résultat
→ `music_requests` (anti-doublon) → Dépôt manuel OWNER dans l'inbox
→ Watcher local (hash + déduplication + import) → Réconciliation

ÉCOUTE
App mobile → Auth (JWT) → Parcourt bibliothèque (API paginée)
→ Play → GET /stream (Range) → WAV/FLAC natif
→ Seek/reprise via Range

HORS LIGNE
App → Sélection pistes + profil 128/256/original
→ Opus : job serveur single-flight + dérivée vérifiée ; original : route canonique
→ Téléchargement Range + SHA-256 → Manifeste local → Mode avion → Lecture locale
→ Serveur de nouveau joignable → morceau courant inchangé → piste suivante en WAV/FLAC original
```
