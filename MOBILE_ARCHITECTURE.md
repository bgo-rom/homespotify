# MOBILE_ARCHITECTURE.md — HomeSpotify Mobile

Document de cadrage de la Phase 4 : client mobile Flutter. Aucun code d'interface n'est produit ici ; ce fichier fixe la stack, les frontières d'architecture et les commandes d'initialisation.

## Objectif Phase 4

Créer une application mobile fluide et robuste pour parcourir la bibliothèque HomeSpotify, streamer des WAV lourds via HTTP Range, afficher les métadonnées enrichies, puis préparer le cache hors ligne piloté par `GET /api/sync/manifest`.

Contraintes non négociables :

- Les fichiers source restent des WAV PCM côté serveur ; le client ne réécrit jamais l'audio.
- Streaming réseau par URL `/api/tracks/:id/stream`, avec seek/reprise via Range serveur.
- Téléchargement offline par `/api/tracks/:id/download`, jamais via chargement complet en mémoire.
- Synchronisation légère via `/api/sync/manifest` et ETag global.
- Android d'abord ; iOS activable ensuite, idéalement depuis une machine macOS.

## Stack Flutter Recommandée

### Base

- **Flutter stable + Dart** : stack mobile retenue à partir de la Phase 4.
- **Projet cible** : `apps/mobile/homespotify_mobile`.
- **Plateforme initiale** : Android.

### Audio / Lockscreen

- **`just_audio` — obligatoire** : lecteur audio principal. Il sait charger des URL, gérer les playlists, le seek, les erreurs de lecture, et s'appuie sur les en-têtes serveur (`Content-Length`, `Content-Type`, Range) pour les flux distants. C'est le bon choix pour les WAV lourds servis par l'API HomeSpotify.
- **`audio_service` — obligatoire** : couche background audio, notification média, lockscreen, contrôles casque/voiture et file de lecture système. Toute logique audio longue durée passe par un `AudioHandler`.
- **`audio_session` — recommandé** : configuration explicite de l'audio focus Android/iOS, interruptions, ducking et coexistence avec les autres apps audio.

Règle d'architecture : l'UI ne pilote jamais directement `AudioPlayer`. Elle envoie des intentions à un service applicatif qui délègue à l'`AudioHandler`.

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
  - WAV téléchargés : sous-dossier applicatif `offline/tracks/{track_id}.wav`.
  - Pochettes : sous-dossier applicatif `offline/covers/{track_id}.jpg` ou URL distante tant que non cachée.

Tables locales prévues :

- `manifest_tracks(track_id, enrichment_status, etag, last_modified, updated_at)`
- `cached_tracks(track_id, etag, file_path, size_bytes, downloaded_at, verified_at)`
- `sync_state(key, value, updated_at)` avec `manifest_etag`

Règle : la DB ne stocke jamais d'audio, seulement chemins, hashes, dates et états.

### State Management

- **Choix retenu : Riverpod (`flutter_riverpod` + `riverpod_annotation`)**.
- Justification :
  - Très bon modèle pour API async, cache local et états `loading/error/data`.
  - Sépare naturellement logique et UI.
  - Testable sans coupler les widgets aux singletons.
  - Plus léger que Bloc pour une app personnelle riche mais maîtrisée.

Bloc est rejeté pour cette phase : robuste, mais plus verbeux et moins direct pour combiner API, DB locale, lecteur audio et état offline.

### Navigation, Modèles et Qualité

- **`go_router`** : navigation déclarative, deep links futurs (`track/:id`, `album/:id`).
- **`freezed` + `json_serializable`** : modèles immuables, parsing strict des DTO API, unions d'état si nécessaire.
- **`connectivity_plus`** : détection réseau pour éviter les téléchargements offline hors Wi-Fi si l'utilisateur ne l'a pas autorisé.
- **`flutter_lints`** : lint Flutter minimal dès l'initialisation.

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
        library/
          data/
            library_api.dart
            library_repository.dart
            dto/
          domain/
            track.dart
            album.dart
            artist.dart
          presentation/
            library_screen.dart
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

## Contrats Backend Consommés

- `GET /api/tracks?page&limit` : liste paginée de bibliothèque.
- `GET /api/tracks/:id/stream` : streaming WAV avec HTTP Range.
- `GET /api/tracks/:id/download` : téléchargement offline Range-resumable.
- `GET /api/tracks/:id/cover` : pochette HD enrichie ou fallback embarqué.
- `GET /api/sync/manifest` : manifeste léger avec ETag global.

Le client mobile doit démarrer par le manifeste : si `If-None-Match` retourne `304`, il conserve son état local ; sinon il met à jour SQLite puis réconcilie les fichiers WAV présents sur disque par `track_id` + `etag`.

## Références Officielles

- `just_audio` : https://pub.dev/packages/just_audio
- `audio_service` : https://pub.dev/packages/audio_service
- `dio` : https://pub.dev/packages/dio
- `sqflite` : https://pub.dev/packages/sqflite
- `path_provider` : https://pub.dev/packages/path_provider
- `flutter_riverpod` : https://pub.dev/packages/flutter_riverpod
