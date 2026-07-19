# MOBILE_ARCHITECTURE.md — HomeSpotify Mobile

Document de cadrage de la Phase 4 : client mobile Flutter. Aucun code d'interface n'est produit ici ; ce fichier fixe la stack, les frontières d'architecture et les commandes d'initialisation.

## Objectif Phase 4

Créer une application mobile fluide et robuste pour parcourir la bibliothèque HomeSpotify, streamer des WAV/FLAC natifs via HTTP Range, afficher les métadonnées enrichies, puis préparer le cache hors ligne piloté par `GET /api/sync/manifest`.

Contraintes non négociables :

- Les fichiers source restent des WAV PCM ou FLAC lossless côté serveur ; le client ne réécrit, ne convertit ni ne compresse jamais l'audio.
- Streaming réseau par URL `/api/tracks/:id/stream`, avec seek/reprise via Range serveur.
- Téléchargement offline par `/api/tracks/:id/download`, jamais via chargement complet en mémoire.
- Synchronisation légère via `/api/sync/manifest` et ETag global.
- Android d'abord ; les validations runtime officielles se font sur un vrai téléphone Android. iOS reste activable ensuite, idéalement depuis une machine macOS.

## Stack Flutter Recommandée

### Base

- **Flutter stable + Dart** : stack mobile retenue à partir de la Phase 4.
- **Projet cible** : `apps/mobile/homespotify_mobile`.
- **Plateforme initiale** : Android.

### Audio / Lockscreen

- **`just_audio` — obligatoire** : lecteur audio principal. Il sait charger des URL, gérer les playlists, le seek, les erreurs de lecture, et s'appuie sur les en-têtes serveur (`Content-Length`, `Content-Type`, Range) pour les flux distants. C'est le bon choix pour les WAV/FLAC lourds servis nativement par l'API HomeSpotify.
- **`audio_service` — obligatoire** : couche background audio, notification média, lockscreen, contrôles casque/voiture et file de lecture système. Toute logique audio longue durée passe par un `AudioHandler`.
- **`audio_session` — recommandé** : configuration explicite de l'audio focus Android/iOS, interruptions et coexistence avec les autres apps audio. Les interruptions mettent HomeSpotify en pause ; aucun ducking ou changement automatique de gain n'est appliqué.
- **Vitesse par piste** : `HomeSpotifyAudioHandler` applique seul `setSpeed(0.70–1.30)` et fixe systématiquement le pitch à 1,0. Le fork local `packages/homespotify_just_audio` conserve ExoPlayer mais injecte une chaîne `DefaultAudioSink` exclusive : Signalsmith traite le PCM sur `arm64-v8a`/`x86_64` lorsque le flag vaut `signalsmith`, sinon le processeur Sonic interne sert de fallback compatible. Une transition remet immédiatement le lecteur à 1,00x avant toute résolution réseau, le seek vide les buffers DSP et une simple pause ne les réinitialise pas. L'audition d'une piste non courante reste un `AudioPlayer` éphémère limité à 15 s ; elle utilise le même plugin Android sans rejoindre la file principale. Le moteur natif applique une seule configuration Signalsmith calibrée pour tout ratio actif (bypass à 1,00x) ; l'écran développeur caché `/dev/stretch-lab` (appui long sur le panneau « Mode audio » de la feuille de vitesse) permet l'A/B des géométries et du fallback Media3 sur la même piste à la même position, via un seek sur place.

Règle d'architecture : l'UI ne pilote jamais directement le lecteur principal. Elle envoie des intentions au `HomeSpotifyAudioHandler`. L'unique exception est le lecteur d'audition éphémère, isolé et possédé par sa session modale ; il ne rejoint jamais la file principale et ne persiste aucun audio.

### Réseau / API

- **`dio` — obligatoire** : client HTTP unique pour l'API HomeSpotify.
- Usages imposés :
  - `BaseOptions` avec `baseUrl`, timeouts et headers communs.
  - Intercepteurs pour logs debug, erreurs normalisées, futur auth JWT.
  - Lecture des ETags sur `/api/sync/manifest`.
  - Téléchargements offline avec progression, annulation et reprise.
  - Gestion explicite des statuts `304`, `404`, `416`, `5xx`.

### Cache Local / Offline

- **`sqflite` — obligatoire** : base locale du manifeste et de l'état cache.
- **`path_provider` — obligatoire** : racines de stockage de l'application.
- Stockage cible :
  - DB locale : `Application Support` ou `Application Documents` selon plateforme.
  - Fichiers téléchargés : sous-dossier applicatif `offline/tracks/{track_id}.{ext}`.
  - Pochettes : sous-dossier applicatif `offline/covers/{track_id}.jpg` ou URL distante tant que non cachée.

Tables locales prévues :

- `manifest_tracks(track_id, enrichment_status, etag, last_modified, updated_at)`
- `cached_tracks(track_id, etag, file_path, size_bytes, downloaded_at, verified_at)`
- `sync_state(key, value, updated_at)` avec `manifest_etag`

Règle : la DB ne stocke jamais d'audio, seulement chemins, hashes, dates et états.

Les favoris et playlists personnels utilisent le backend authentifié comme
source de vérité. Riverpod ne garde que l'état mémoire du compte courant et
l'invalide au logout. Aucun JSON personnel local n'est conservé. Le stockage
local reste réservé au futur cache audio offline, jamais à l'autorité métier.

### State Management

- **Choix retenu : Riverpod (`flutter_riverpod` + `riverpod_annotation`)**.
- Justification :
  - Très bon modèle pour API async, cache local et états `loading/error/data`.
  - Sépare naturellement logique et UI.
  - Testable sans coupler les widgets aux singletons.
  - Plus léger que Bloc pour une app personnelle riche mais maîtrisée.

Bloc est rejeté pour cette phase : robuste, mais plus verbeux et moins direct pour combiner API, DB locale, lecteur audio et état offline.

### Navigation, Modèles et Qualité

- **`go_router`** : navigation déclarative sombre avec routes bibliothèque, albums, artistes, favoris, playlists, paramètres, découverte par swipe, demandes de musique, administration OWNER et lecteur (`/`, `/albums`, `/albums/:albumKey`, `/artists`, `/artists/:artistRouteId`, `/favorites`, `/playlists`, `/playlists/:playlistId`, `/settings`, `/discover`, `/requests`, `/admin`, `/admin/users`, `/player`). Les paramètres album/artiste sont des identifiants base64Url, jamais des noms bruts.
- **`freezed` + `json_serializable`** : modèles immuables, parsing strict des DTO API, unions d'état si nécessaire.
- **`connectivity_plus`** : détection réseau pour éviter les téléchargements offline hors Wi-Fi si l'utilisateur ne l'a pas autorisé.
- **`flutter_lints`** : lint Flutter minimal dès l'initialisation.

### Authentification & Sécurité locale

- **Flux d'états** (`features/auth/application/auth_controller.dart`) :
  `loading → bootstrapRequired | unauthenticated | passwordChangeRequired |
  locked | authenticated | error`. `main.dart` ne monte le routeur principal
  qu'en `authenticated` ; tous les autres états passent par `AuthFlowScreen`
  (rien de l'application n'est visible avant résolution).
- **`flutter_secure_storage` — obligatoire** : access/refresh tokens dans le
  Keystore Android uniquement. Le mot de passe n'est JAMAIS stocké, sous
  aucune forme.
- **Intercepteur dio** (`auth_session_manager.dart`) : injection `Bearer`,
  refresh **single-flight** (un seul refresh en vol, partagé), une seule
  retentative par requête 401 (drapeau `extra`), routes d'auth exclues —
  aucune boucle possible sur les 401. Si le refresh échoue définitivement,
  déconnexion propre via `onSessionExpired`.
- **`local_auth`** : déverrouillage biométrique **local** de la session
  (empreinte/visage). Rien n'est envoyé au backend ; option désactivée si
  l'appareil n'a pas de biométrie sécurisée enrôlée ; échec/annulation sans
  crash ; retour possible à la connexion par mot de passe (= déconnexion).
  `MainActivity` étend `FlutterFragmentActivity` (requis par BiometricPrompt)
  et le manifest déclare `USE_BIOMETRIC`.
- **Administration OWNER** (`features/admin/`) : tableau de bord
  (`/admin`) et gestion des utilisateurs (`/admin/users`), visibles uniquement
  pour le rôle `OWNER` (`AdminGuard`) — le backend revérifie chaque appel,
  l'UI n'est jamais la seule barrière.

## Arborescence Cible

```text
apps/mobile/homespotify_mobile/
  android/
  lib/
    main.dart
    src/
      app/
        homespotify_app.dart
        router.dart
        theme/
          app_theme.dart
          motion.dart
      core/
        config/
          app_config.dart
        network/
          api_client.dart
          api_error.dart
          etag_interceptor.dart
        storage/
          app_paths.dart
          local_database.dart
        utils/
          result.dart
      features/
        discovery/
          data/
            discovery_api.dart
          domain/
            discovery_models.dart
          presentation/
            discover_screen.dart
            music_requests_screen.dart
        library/
          data/
            favorites_api.dart
            library_api.dart
            library_repository.dart
            playlists_api.dart
            dto/
          domain/
            local_playlist.dart
            track.dart
            album.dart
            artist.dart
          presentation/
            library_screen.dart
            albums_screen.dart
            album_detail_screen.dart
            artists_screen.dart
            artist_detail_screen.dart
            favorites_screen.dart
            library_albums.dart
            library_artists.dart
            library_favorites.dart
            library_playlists.dart
            playlist_detail_screen.dart
            playlists_screen.dart
            track_list.dart
        player/
          audio/
            homespotify_audio_handler.dart
            playback_controller.dart
            queue_controller.dart
          domain/
            playback_state.dart
          presentation/
            player_screen.dart
            mini_player.dart
        sync/
          data/
            sync_api.dart
            manifest_store.dart
            sync_repository.dart
          domain/
            sync_manifest.dart
            cached_track.dart
          presentation/
            sync_status_provider.dart
        offline/
          data/
            download_manager.dart
            offline_store.dart
          domain/
            offline_policy.dart
          presentation/
            offline_screen.dart
      shared/
        widgets/
        animations/
        formatters/
  test/
    core/
    features/
```

Règles de séparation :

- `data/` parle à l'API, à SQLite ou au système de fichiers.
- `domain/` contient les objets métier sans dépendance Flutter.
- `presentation/` contient widgets et providers UI.
- `player/audio/` est la seule zone qui manipule `just_audio` et `audio_service`.
- `core/network` est le seul endroit où `dio` est instancié.
- `core/storage` est le seul endroit où `sqflite` et `path_provider` sont initialisés.

## Initialisation du Projet

Depuis la racine du dépôt :

```powershell
flutter --version
flutter doctor

flutter create `
  --org com.homespotify `
  --project-name homespotify_mobile `
  --platforms android `
  apps/mobile/homespotify_mobile

Set-Location apps/mobile/homespotify_mobile
```

### Dépendances Runtime

```powershell
flutter pub add `
  just_audio `
  audio_service `
  audio_session `
  dio `
  sqflite `
  path_provider `
  flutter_riverpod `
  riverpod_annotation `
  go_router `
  freezed_annotation `
  json_annotation `
  connectivity_plus
```

### Dépendances Dev

```powershell
flutter pub add --dev `
  build_runner `
  riverpod_generator `
  freezed `
  json_serializable `
  flutter_lints
```

### Vérification Initiale

```powershell
flutter pub get
flutter analyze
flutter test
flutter run -d android
```

### iOS Plus Tard

À exécuter depuis une machine macOS si iOS devient prioritaire :

```bash
cd apps/mobile/homespotify_mobile
flutter create --platforms ios .
flutter doctor
```

## Tests runtime (vrai téléphone Android)

Base URL configurable via le dart-define **`HOMESPOTIFY_API_BASE_URL`** (défaut
neutre `http://localhost:3000`, défini dans `core/config/app_config.dart`). Le HTTP en
clair est autorisé en **debug uniquement** (network security config sous
`android/app/src/debug`) ; la build release refuse le cleartext.

Le vrai téléphone Android est la cible runtime officielle. L'émulateur n'est plus utilisé pour valider les parcours, l'audio ou les performances. En USB, `adb reverse tcp:3000 tcp:3000` permet au téléphone d'utiliser `http://127.0.0.1:3000`.

### Backend

```powershell
$env:HOST = "0.0.0.0"
$env:PORT = "3000"
pnpm --filter @homespotify/api dev
```

### Application (même Wi-Fi que le PC)

Récupère l'IP LAN du PC (`ipconfig` → IPv4, ex. 192.168.1.20), puis :

```powershell
flutter run --dart-define=HOMESPOTIFY_API_BASE_URL=http://<IP_LAN_DU_PC>:3000
```

Le pare-feu Windows doit autoriser le port 3000 entrant.

### Profile mode (perf / grésillements)

Les micro-grésillements audio et lenteurs d'UI viennent souvent du **mode debug**
(JIT, instrumentation). Pour juger les vraies performances, lancer en profile :

```powershell
flutter run --profile --dart-define=HOMESPOTIFY_API_BASE_URL=http://<IP_LAN_DU_PC>:3000
```

## Contrats Backend Consommés

- `GET /api/recommendations?cursor=&limit=` : page de la file PRÉ-CALCULÉE
  (moteur hybride V2, `modelVersion`), métadonnées descriptives uniquement,
  raison française (`reason`/`reasonCode`), `previewUrl` https éventuelle.
  Lecture strictement locale côté serveur (aucun appel externe au GET).
- `POST /api/recommendations/refresh` : déclenche la régénération ASYNCHRONE
  de la file (202, `started`/`already_running`, single-flight par compte).
- `GET /api/recommendations/status` : taille de file, fraîcheur, job en cours.
- `POST /api/recommendations/:candidateId/action` : journalise LIKE / DISLIKE /
  SKIP / OPEN / REQUEST (DISLIKE masque le candidat pour ce compte et le retire
  immédiatement de la file ; LIKE/DISLIKE/REQUEST relancent le job async).
- `POST/GET /api/music-requests`, `GET /api/music-requests/:id`,
  `POST /api/music-requests/:id/cancel` : demandes de musique du SEUL compte du
  token, traitées manuellement par le OWNER — aucune recherche ne déclenche de
  téléchargement ; annulation permise uniquement avant `IMPORTING`.
- `DELETE /api/library/tracks/:trackId` : suppression douce — retire l'accès de
  ce compte (fichier physique intact), favoris/occurrences playlists compris,
  et masque la piste pour les futures recommandations.
- `GET /api/tracks?page&limit` : liste paginée de bibliothèque.
- `GET /api/tracks/:id/stream` : streaming WAV/FLAC natif avec HTTP Range.
- `GET /api/tracks/:id/download` : téléchargement offline Range-resumable.
- `GET /api/tracks/:id/cover` : pochette HD enrichie ou fallback embarqué.
- `GET /api/sync/manifest` : manifeste léger avec ETag global.

Le client mobile doit démarrer par le manifeste : si `If-None-Match` retourne `304`, il conserve son état local ; sinon il met à jour SQLite puis réconcilie les fichiers WAV/FLAC présents sur disque par `track_id` + `etag`.

## Références Officielles

- `just_audio` : https://pub.dev/packages/just_audio
- `audio_service` : https://pub.dev/packages/audio_service
- `dio` : https://pub.dev/packages/dio
- `sqflite` : https://pub.dev/packages/sqflite
- `path_provider` : https://pub.dev/packages/path_provider
- `flutter_riverpod` : https://pub.dev/packages/flutter_riverpod
