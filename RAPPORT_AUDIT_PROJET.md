# RAPPORT AUDIT TECHNIQUE — HomeSpotify

**Date** : 30 juillet 2026  
**Commit** : e60c78678013a444c1ee1e9d823db4821dc3f2c9  
**Auditeur** : Analyse automatisée + revue technique  
**Périmètre** : Monorepo complet (backend, mobile, storage-agent, packages)

---

# 1. Résumé exécutif

HomeSpotify est un serveur de musique personnelle auto-hébergé, inspiré de Spotify, tournant H24 sur une machine Windows personnelle. Le projet est un monorepo structuré en pnpm workspace, comprenant :

- **Backend API** (Fastify + SQLite + Drizzle ORM) : gestion de bibliothèque musicale multi-utilisateurs, streaming audio avec HTTP Range, authentification JWT, découverte de musique via catalogues externes (iTunes, Apple Music, Spotify, Deezer, MusicBrainz), système de recommandations alimenté par Last.fm, import local de fichiers audio, acquisition automatisée via Lucida (script Python), variantes hors ligne encodées en Opus.
- **Application mobile Flutter** : lecteur complet avec background audio (Media3/ExoPlayer), mini-player, bibliothèque, favoris, playlists, mode hors ligne avec téléchargement de pistes, recherche catalogue, authentification biométrique.
- **Storage Agent** : service Fastify séparé pour le streaming audio distant (architecture hybride VPS/local), indexation des fichiers audio, authentification HMAC.

**État général** : Projet **Mature en développement avancé**. L'architecture est bien pensée, le code est documenté, les tests backend sont nombreux (557) et passent tous. Le backend est fonctionnellement riche et stable. L'application Flutter est complète avec gestion d'état Riverpod et lecteur audio robuste. Le projet est en "Phase 3 — bibliothèque, métadonnées & sync offline" selon le code.

**Niveau de production** : Prêt pour un usage personnel avancé. Quelques verrous pour une production multi-utilisateurs publique (authentification unique, monitoring, CI/CD, documentation déploiement).

---

# 2. Périmètre réellement inspecté

## Dossiers examinés

- `services/api/` — Backend complet (src/, tests, config)
- `apps/mobile/homespotify_mobile/` — Application Flutter
- `services/storage-agent/` — Service de streaming distant
- `packages/homespotify_just_audio/` — Fork personnalisé de just_audio
- `packages/shared/` — Vide actuellement (.gitkeep uniquement)
- `scripts/` — Scripts de déploiement, backup, diagnostic
- `docs/` — Documentation de migration VPS et features
- `tools/` — Outils divers (smoke tests, lucida, etc.)

## Fichiers importants lus

### Backend
- `services/api/src/app.ts` — Point d'entrée, wiring complet des routes et services
- `services/api/src/db/schema.ts` — Schéma SQLite complet (23+ tables)
- `services/api/src/routes/tracks.ts` — Routes pistes + streaming HTTP Range
- `services/api/src/config.ts` — Configuration (environ 30 variables d'environnement)
- `services/api/src/auth/guards.ts` — Guards d'authentification
- `services/api/src/db/migrate.ts` — Migrations Drizzle
- `services/api/src/storage/audio-storage.ts` — Abstraction de stockage audio
- `services/api/src/storage/local-file-storage.ts` — Implémentation locale
- `services/api/src/storage/remote-storage-provider.ts` — Provider distant (Storage Agent)
- `services/api/src/storage/provider-factory.ts` — Fabrique de providers
- `services/api/src/import/import-service.ts` — Service d'import WAV
- `services/api/src/discovery/discovery.ts` — Moteur de recommandations
- `services/api/src/library/user-library-service.ts` — Isolation bibliothèque par utilisateur

### Flutter
- `apps/mobile/homespotify_mobile/lib/main.dart` — Initialisation, providers, audio handler
- `apps/mobile/homespotify_mobile/lib/src/app/router.dart` — Routes go_router
- `apps/mobile/homespotify_mobile/lib/src/core/network/api_client.dart` — Client Dio
- `apps/mobile/homespotify_mobile/lib/src/core/config/app_config.dart` — Configuration
- `apps/mobile/homespotify_mobile/lib/src/features/auth/` — Authentification
- `apps/mobile/homespotify_mobile/lib/src/features/player/audio/` — Lecteur audio
- `apps/mobile/homespotify_mobile/lib/src/features/offline/` — Mode hors ligne

### Storage Agent
- `services/storage-agent/src/main.ts` — Point d'entrée
- `services/storage-agent/src/server.ts` — Serveur Fastify + routes
- `services/storage-agent/src/storage-index.ts` — Index des fichiers audio
- `services/storage-agent/src/path-safety.ts` — Protection path traversal
- `services/storage-agent/src/hmac-auth.ts` — Authentification HMAC

### Documentation
- `CLAUDE.md` — Instructions pour les IA
- `AGENTS.md` — Règles pour les agents
- `ARCHITECTURE.md` — Architecture du projet
- `PROJECT.md` — Description produit
- `AUDIO_SOURCING.md` — Politique de qualité audio
- `MOBILE_ARCHITECTURE.md` — Architecture Flutter
- `ROADMAP.md` — Roadmap produit
- `LESSONS.md` — Leçons apprises
- `TECH_DECISIONS.md` — Décisions techniques

## Commandes exécutées

| Commande | Résultat |
|----------|----------|
| `git ls-files` | Inventaire complet du dépôt |
| `npm test` (services/api) | **557 tests passés / 50 fichiers** |
| `npm run typecheck` (services/api) | **OK — 0 erreur** |
| `flutter analyze` (apps/mobile) | **12 infos mineures** (style uniquement) |
| Recherche TODO/FIXME | Aucun dans le code source principal |
| Recherche secrets dans git | Aucun secret en dur trouvé |

## Éléments non accessibles ou non analysés

- Contenu des fichiers `.env` (protégés par .clineignore)
- Base de données SQLite (protégée par .clineignore)
- Fichiers audio (protégés par .clineignore)
- Code natif Android du fork just_audio (non lu en détail)
- Scripts Python Lucida (non lus en détail)
- FLACidal-main (projet tiers inclus, non audité)

---

# 3. Architecture vérifiée

## Organisation du monorepo

```
homespotify/
├── services/
│   ├── api/              # Backend Fastify + SQLite (port 3000 par défaut)
│   └── storage-agent/    # Service streaming distant (port 3100 par défaut)
├── apps/
│   ├── mobile/
│   │   └── homespotify_mobile/  # Application Flutter (Android/iOS)
│   └── web/              # Vide actuellement
├── packages/
│   ├── shared/           # Vide (futur code partagé TS/Dart)
│   └── homespotify_just_audio/  # Fork de just_audio 0.10.6
├── scripts/              # Scripts PowerShell/Python de déploiement
├── docs/                 # Documentation technique et plans de migration
├── storage/              # Données persistantes (music, covers, cache, etc.)
└── tools/                # Outils de développement et tests
```

## Schéma d'architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                       Application Flutter                       │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────────────┐  │
│  │ Riverpod │  │ go_router│  │   Dio    │  │ just_audio +   │  │
│  │ (state)  │  │(routes)  │  │(HTTP)    │  │ audio_service  │  │
│  └────┬─────┘  └──────────┘  └────┬─────┘  └────────┬───────┘  │
│       │                          │                  │          │
│       └──────────────────────────┼──────────────────┘          │
│                                  │                              │
└──────────────────────────────────┼──────────────────────────────┘
                                   │
                                   │ HTTPS/HTTP
                                   │ (JWT Bearer)
                                   ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Backend API (Fastify)                        │
│                                                                  │
│  ┌────────────┐  ┌────────────┐  ┌──────────────────────────┐  │
│  │ Auth Guards│  │ Route      │  │ Services métier          │  │
│  │ (JWT)      │  │ Handlers   │  │                          │  │
│  └──────┬─────┘  └──────┬─────┘  │ - Bibliothèque           │  │
│         │               │        │ - Favoris / Playlists    │  │
│         │               │        │ - Découverte / Reco      │  │
│         │               │        │ - Import / Acquisition   │  │
│         │               │        │ - Variantes offline      │  │
│         │               │        │ - Métadonnées            │  │
│         │               │        └──────────┬───────────────┘  │
│         │               │                   │                  │
│         │               │        ┌──────────┴───────────────┐  │
│         │               │        │ Storage Provider Abstraction │
│         │               │        └──────────┬───────────────┘  │
│         │               │                   │                  │
│         │               ▼                   ▼                  │
│         │        ┌────────────┐    ┌──────────────────┐       │
│         │        │ SQLite +   │    │ Audio Storage    │       │
│         │        │ Drizzle ORM│    │ (local / remote) │       │
│         │        └────────────┘    └────────┬─────────┘       │
│         │                                   │                  │
└─────────┼───────────────────────────────────┼──────────────────┘
          │                                   │
          │                                   │ HTTP Range (HMAC)
          │                                   ▼
          │                        ┌──────────────────┐
          │                        │ Storage Agent    │
          │                        │ (Fastify distant)│
          │                        └────────┬─────────┘
          │                                 │
          ▼                                 ▼
   [Fichiers audio locaux]        [Fichiers audio distants]
```

## Responsabilités de chaque module

| Module | Responsabilité | Statut |
|--------|---------------|--------|
| `services/api` | API REST, business logic, streaming audio, DB | **CONFIRMÉ** — Code complet et testé |
| `services/storage-agent` | Streaming audio distant avec HMAC | **CONFIRMÉ** — Implémenté avec tests |
| `apps/mobile/homespotify_mobile` | Client mobile complet | **CONFIRMÉ** — Code complet |
| `packages/homespotify_just_audio` | Fork just_audio avec extensions Android | **CONFIRMÉ** — Fork de just_audio 0.10.6 |
| `packages/shared` | Code partagé (futur) | **ABSENT** — Vide actuellement |

## Points d'entrée

| Service | Point d'entrée | Commande |
|---------|---------------|----------|
| API | `services/api/src/server.ts` | `npm run dev` ou `npm start` |
| Storage Agent | `services/storage-agent/src/main.ts` | `npm run dev` ou `npm start` |
| Flutter | `apps/mobile/homespotify_mobile/lib/main.dart` | `flutter run` |

---

# 4. Inventaire des fonctionnalités

## 4.1 Gestion de bibliothèque musicale

- **Statut** : CONFIRMÉ
- **Preuves** :
  - `services/api/src/db/schema.ts` — Tables `tracks`, `user_tracks`, `albums`, `artists`
  - `services/api/src/routes/tracks.ts` — CRUD pistes
  - `services/api/src/import/import-service.ts` — Import WAV avec extraction métadonnées
- **Fonctionnement** : Import local de fichiers WAV, extraction de métadonnées avec `music-metadata`, indexation dans SQLite. Bibliothèque isolée par utilisateur via `user_tracks`.
- **Risques** : Support uniquement WAV confirmé dans le code (FLAC mentionné dans la doc mais pas explicitement dans l'import).

## 4.2 Streaming audio HTTP Range

- **Statut** : CONFIRMÉ
- **Preuves** :
  - `services/api/src/routes/tracks.ts` — `serveTrackFile()` avec `parseRangeHeader()`
  - `services/api/src/lib/range.ts` — Parsing des headers Range
  - Tests dans `services/api/src/routes/tracks.ts` (via tests unitaires)
- **Fonctionnement** : Support complet des requêtes Range (206 Partial Content), 416 Range Not Satisfiable, HEAD requests. Logging détaillé du streaming.
- **Limites** : Aucune détectée.

## 4.3 Authentification multi-utilisateurs

- **Statut** : CONFIRMÉ
- **Preuves** :
  - `services/api/src/auth/guards.ts` — Guards JWT
  - `services/api/src/auth/auth.test.ts` — Tests d'authentification
  - `services/api/src/routes/auth.ts` — Routes login/register
  - `services/api/src/db/schema.ts` — Tables `users`, `user_sessions`
  - `apps/mobile/homespotify_mobile/lib/src/features/auth/` — Implémentation Flutter
- **Fonctionnement** : JWT signés HMAC via `@fastify/jwt`. Rôles OWNER/USER. Refresh token. Tokens stockés dans `flutter_secure_storage` (Keystore Android).
- **Risques** : Rotation de secret implémentée (`scripts/rotate_auth_secret.ps1`) mais nécessite coordination.

## 4.4 Favoris et playlists

- **Statut** : CONFIRMÉ
- **Preuves** :
  - `services/api/src/db/schema.ts` — Tables `favorites`, `playlists`, `playlist_tracks`
  - `services/api/src/routes/favorites.ts`
  - `services/api/src/routes/playlists.ts`
- **Fonctionnement** : Favoris par utilisateur. Playlists avec ordonnancement. Isolation par utilisateur.

## 4.5 Découverte de musique et recommandations

- **Statut** : CONFIRMÉ
- **Preuves** :
  - `services/api/src/discovery/discovery.test.ts` — 48 tests détaillés
  - `services/api/src/discovery/catalog/` — Providers multi-fournisseurs
  - `services/api/src/routes/discovery-catalog.ts` — API de recherche catalogue
  - Providers : iTunes, Apple Music, Spotify, Deezer, MusicBrainz
- **Fonctionnement** : Recherche multi-fournisseurs avec cache normalisé. Recommandations basées sur le profil d'écoute (Last.fm similarity graph). File de recommandations par utilisateur avec pagination par curseur.
- **Qualité** : Très bien testé (48 tests, scénarios complexes).

## 4.6 Acquisition automatisée (Lucida)

- **Statut** : CONFIRMÉ
- **Preuves** :
  - `services/api/src/import/acquisition-import-service.ts` — Service d'acquisition
  - `services/api/src/import/lucida-process-runner.ts` — Runner Python
  - `services/api/src/routes/acquisition-imports.ts` — Routes d'acquisition
  - `services/api/src/import/acquisition-import-service.test.ts` — 42 tests
- **Fonctionnement** : Lancement de script Python Lucida pour télécharger des pistes depuis diverses sources. Vérification interactive optionnelle. File d'attente avec concurrence limitée.
- **Risques** : Dépend d'un script Python externe non audité ici.

## 4.7 Variantes hors ligne (Opus)

- **Statut** : CONFIRMÉ
- **Preuves** :
  - `services/api/src/db/schema.ts` — Table `track_offline_variants`
  - `services/api/src/audio/offline-variant-service.ts` — Service d'encodage
  - `services/api/src/routes/offline.ts` — Routes offline
  - `services/api/src/routes/offline.test.ts` — Tests
- **Fonctionnement** : Encodage ffmpeg de pistes source en Opus 128/256 kbps. File d'attente avec single-flight. Stockage en `storage/derived/`.

## 4.8 Mode hors ligne mobile

- **Statut** : CONFIRMÉ
- **Preuves** :
  - `apps/mobile/homespotify_mobile/lib/src/features/offline/` — Feature complète
  - `offline_index.dart`, `offline_manifest_store.dart`, `offline_track_downloader.dart`
  - `offline_batch_download_manager.dart` — Téléchargement par lots
- **Fonctionnement** : Index local SQLite des pistes téléchargées. Téléchargement via `/api/tracks/:id/download`. Manifeste de synchronisation.

## 4.9 Lecture audio en arrière-plan

- **Statut** : CONFIRMÉ
- **Preuves** :
  - `apps/mobile/homespotify_mobile/lib/main.dart` — `AudioService.init()`
  - `apps/mobile/homespotify_mobile/lib/src/features/player/audio/homespotify_audio_handler.dart`
  - Dépendances : `audio_service`, `just_audio`, `audio_session`
- **Fonctionnement** : AudioService avec HomeSpotifyAudioHandler personnalisé. Notification de contrôle. Replay Gain. Loudness Enhancer Android.

## 5. Analyse du backend

## 5.1 Framework et architecture

- **Framework** : Fastify 5.4.0 (TypeScript strict)
- **Base de données** : SQLite via better-sqlite3 12.2.0 + Drizzle ORM 0.44.2
- **Architecture** : Routes → Services → Repository/DB. Injection de dépendances via `BuildAppOptions`.
- **Qualité** : Très élevée. Code bien structuré, documenté, testé.

## 5.2 Routes API

| Route | Méthode | Auth | Description |
|-------|---------|------|-------------|
| `/health` | GET | Non | Health check |
| `/version` | GET | Non | Version du backend |
| `/api/status` | GET | Non | Statut phase/DB |
| `/api/tracks` | GET | Oui | Liste paginée (filtrée par bibliothèque) |
| `/api/tracks` | POST | Oui | Import WAV |
| `/api/tracks/:id/stream` | GET | Oui | Streaming HTTP Range |
| `/api/tracks/:id/download` | GET | Oui | Téléchargement forcé |
| `/api/tracks/:id/cover` | GET | Oui | Pochette |
| `/api/auth/login` | POST | Non | Connexion |
| `/api/auth/register` | POST | Non | Inscription |
| `/api/auth/refresh` | POST | Oui | Refresh token |
| `/api/favorites` | GET/POST/DELETE | Oui | Favoris |
| `/api/playlists` | CRUD | Oui | Playlists |
| `/api/discovery/search` | GET | Oui | Recherche catalogue |
| `/api/recommendations/feed` | GET | Oui | Feed de recommandations |
| `/api/music-requests` | CRUD | Oui | Demandes de musique |
| `/api/admin/*` | Various | OWNER | Administration |
| `/api/sync/*` | GET | Oui | Synchronisation bibliothèque |
| `/api/offline/*` | GET | Oui | Variantes offline |
| `/api/play-events` | POST | Oui | Événements d'écoute |
| `/api/playback-settings/*` | GET/PUT | Oui | Paramètres lecture |

## 5.3 Schéma de données

**Tables principales** (23+ tables) :

- `users` — Utilisateurs avec rôles (owner/user)
- `user_sessions` — Sessions JWT
- `tracks` — Pistes avec métadonnées complètes
- `user_tracks` — Relation utilisateur/piste (isolation)
- `albums`, `artists` — Entités musicales
- `favorites` — Favoris par utilisateur
- `playlists`, `playlist_tracks` — Playlists
- `recommendation_queue` — File de recommandations
- `recommendation_profile` — Profil de goût par utilisateur
- `music_requests` — Demandes de musique
- `discovery_cache` — Cache normalisé des réponses catalogue
- `track_quality` — Qualité audio mesurée
- `track_enrichment` — Métadonnées MusicBrainz
- `track_offline_variants` — Variantes Opus
- `play_events` — Historique d'écoute
- `offline_variants` — Variantes offline
- `acquisitions` — Jobs d'acquisition Lucida
- `provider_health` — Santé des providers d'acquisition

**Qualité du schéma** : Excellent. Index appropriés, contraintes de clé étrangère avec cascade, colonnes NOT NULL par défaut, timestamps cohérents.

## 5.4 Streaming audio

- Implémentation robuste avec `serveTrackFile()` réutilisable.
- Support HTTP Range complet (206, 416, HEAD).
- Logging détaillé avec métriques de performance.
- Gestion propre des erreurs de stockage.
- Abstraction `AudioStorageProvider` permettant local ou distant.

## 5.5 Gestion des erreurs

- ErrorHandler centralisé (`app.setErrorHandler`).
- NotFoundHandler dédié.
- Erreurs typées (`ImportError`, `AudioStorageError`).
- Messages d'erreur en français.
- En production, les erreurs 500 masquent les détails.

## 5.6 Problèmes constatés

| Problème | Gravité | Détails |
|----------|---------|---------|
| Aucun problème critique | - | - |
| Logger Fastify en test désactivé | Information | `enabled: config.nodeEnv !== 'test'` — acceptable |
| Dépendance à ffmpeg | Moyenne | Nécessaire pour encodage offline et analyse audio |

## 6. Analyse de l'application Flutter

## 6.1 Architecture

- **Gestion d'état** : Riverpod 3.3.2 avec code generation (`riverpod_annotation`)
- **Navigation** : go_router 17.3.0
- **Réseau** : Dio 5.10.0
- **Audio** : just_audio (fork) + audio_service 0.18.19
- **Persistance** : sqflite, shared_preferences, flutter_secure_storage

## 6.2 Structure des features

```
lib/src/features/
├── auth/           # Authentification, session, token
├── library/        # Bibliothèque musicale
├── player/         # Lecteur audio, mini-player, settings
├── favorites/      # Favoris
├── playlists/      # Playlists
├── discovery/      # Découverte, recherche catalogue
├── offline/        # Mode hors ligne, téléchargement
├── listening/      # Historique d'écoute
└── ...
```

## 6.3 Navigation

- Routes définies dans `lib/src/app/router.dart` avec go_router.
- Gotha : AuthFlowScreen pour login/register/change password.
- Mode offline : `AuthStatus.offline` permet l'accès sans serveur.

## 6.4 Lecteur audio

- `HomeSpotifyAudioHandler` personnalisé étendant `BaseAudioHandler`.
- Support du background audio via `audio_service`.
- Replay Gain avec `AndroidReplayGainEngine`.
- Loudness Enhancer Android.
- Gestion de la rotation de token JWT (rebuild de la file native).
- Diagnostics audio détaillés.

## 6.5 Problèmes constatés

| Problème | Gravité | Détails |
|----------|---------|---------|
| 12 warnings flutter analyze | Faible | Style uniquement (`prefer_initializing_formals`) |
| Fork just_audio | Moyenne | Maintenance supplémentaire pour suivre l'amont |

## 7. Cohérence backend/mobile

## 7.1 Contrats API

- **Format des réponses** : JSON cohérent. Backend retourne `{ statusCode, error, message }` pour les erreurs.
- **Modèles de données** : Les champs des pistes (`id`, `title`, `artist`, `album`, `durationSeconds`, `hasCover`, `mimeType`, `quality`) correspondent entre backend et mobile.
- **Authentification** : JWT Bearer cohérent. Refresh token implémenté des deux côtés.

## 7.2 Divergences détectées

| Élément | Statut | Détails |
|---------|--------|---------|
| Configuration URL | PARTIELLEMENT CONFIRMÉ | `AppConfig.apiBaseUrl` via `--dart-define` — doit être configuré manuellement |
| Streaming vs Download | CONFIRMÉ | Les deux routes utilisées correctement |
| Qualité audio | CONFIRMÉ | Structure `quality` cohérente entre backend et mobile |

## 8. Base de données et persistance

## 8.1 Schéma SQLite

- **ORM** : Drizzle ORM avec migrations.
- **Migrations** : `services/api/src/db/migrate.ts` — Migrations appliquées au démarrage automatiquement.
- **Schéma** : Bien conçu avec index, contraintes, cascades.
- **Transactions** : Utilisées pour les opérations liées.

## 8.2 Persistance mobile

- **Base locale** : SQLite via sqflite pour cache et mode offline.
- **Tokens** : `flutter_secure_storage` → Keystore Android.
- **Préférences** : `shared_preferences` pour settings.

## 8.3 Risques

| Risque | Gravité | Détails |
|--------|---------|---------|
| Backup SQLite | Moyenne | Script existe (`scripts/backup_homespotify.ps1`) mais pas automatisé par défaut |
| Corruption DB | Faible | better-sqlite3 est robuste, WAL mode recommandé |

## 9. Tests et qualité

## 9.1 Tests backend

| Métrique | Valeur |
|----------|--------|
| Fichiers de test | 50 |
| Tests | **557** |
| Résultat | **100% passés** |
| Durée | ~24s |

**Couverture par domaine** :
- Auth : tests complets (JWT, rôles, refresh)
- Library : isolation multi-utilisateur testée
- Discovery : 48 tests détaillés du moteur de recommandations
- Acquisition : 42 tests du service Lucida
- Offline : tests des variantes Opus
- Routes : tests des endpoints critiques

## 9.2 Tests Flutter

- **flutter analyze** : 12 infos mineures (style uniquement, 0 error, 0 warning).
- **flutter test** : Non exécuté (dépendances non installées dans l'environnement d'audit).

## 9.3 Analyse statique

- **TypeScript** : `tsc --noEmit` → 0 erreur.
- **Flutter** : 12 infos de style.

## 9.4 CI/CD

- **Statut** : ABSENT
- Aucun fichier de CI/CD détecté (.github/workflows, GitLab CI, etc.).
- Les scripts de déploiement sont manuels (PowerShell).

## 10. Sécurité

## 10.1 Secrets

| Élément | Statut | Détails |
|---------|--------|---------|
| Secrets dans git | **OK** | Aucun secret en dur trouvé dans le dépôt |
| .env | **OK** | Gitignoré correctement |
| .env.example | **OK** | Présents comme modèles |
| Tokens Apple Music | **OK** | Chargés depuis fichiers PEM configurés |

## 10.2 Authentification

| Élément | Statut | Détails |
|---------|--------|---------|
| JWT HMAC | **CONFIRMÉ** | `@fastify/jwt` avec `AUTH_TOKEN_SECRET` |
| Refresh token | **CONFIRMÉ** | Rotation et single-flight |
| Rôles | **CONFIRMÉ** | OWNER/USER avec guards |
| Stockage mobile | **CONFIRMÉ** | `flutter_secure_storage` (Keystore) |
| Biométrie | **CONFIRMÉ** | `local_auth` intégré |

## 10.3 Protection des routes

| Élément | Statut | Détails |
|---------|--------|---------|
| Routes protégées | **CONFIRMÉ** | Tous les endpoints sensibles exigent JWT |
| Isolation multi-user | **CONFIRMÉ** | `user_tracks` filtre par userId |
| Catalogue global | **CONFIRMÉ** | Publication contrôlée via `isTrackPublished()` |

## 10.4 Stockage audio

| Élément | Statut | Détails |
|---------|--------|---------|
| Path traversal (local) | **CONFIRMÉ** | Validation des chemins dans `local-file-storage.ts` |
| Path traversal (distant) | **CONFIRMÉ** | `services/storage-agent/src/path-safety.ts` avec tests |
| Exposition directe | **OK** | Les fichiers audio ne sont accessibles que via l'API |
| HMAC Storage Agent | **CONFIRMÉ** | `services/storage-agent/src/hmac-auth.ts` |

## 10.5 Problèmes de sécurité classés

| Gravité | Problème | Impact | Correction |
|---------|----------|--------|------------|
| **FAIBLE** | CORS non configuré explicitement | Accès cross-origin par défaut si exposé | Ajouter `@fastify/cors` avec whitelist |
| **FAIBLE** | Rate limiting absent | Attaque par force brute sur login | Ajouter `@fastify/rate-limit` |
| **INFORMATION** | Pas de HTTPS en local | Normal pour usage local | Configurer TLS pour exposition externe |
| **INFORMATION** | Logs en production masquent les détails | Bon pour la sécurité | Conservé tel quel |

## 11. Documentation contre réalité

## 11.1 Documentation lue

- `README.md` — Description générale
- `PROJECT.md` — Vision produit détaillée
- `ARCHITECTURE.md` — Architecture technique
- `MOBILE_ARCHITECTURE.md` — Architecture Flutter
- `AUDIO_SOURCING.md` — Politique qualité audio
- `ROADMAP.md` — Feuille de route
- `LESSONS.md` — Leçons apprises
- `TECH_DECISIONS.md` — Décisions techniques
- `CLAUDE.md` / `AGENTS.md` — Règles pour les IA

## 11.2 Cohérence

| Élément | Statut | Détails |
|---------|--------|---------|
| Architecture monorepo | **CONFIRMÉ** | Correspond à la doc |
| Technologies | **CONFIRMÉ** | Fastify, SQLite, Flutter, Riverpod |
| Streaming Range | **CONFIRMÉ** | Implémenté comme documenté |
| Qualité audio | **CONFIRMÉ** | `track_quality` table avec analyse technique |
| Isolation multi-user | **CONFIRMÉ** | Implémentée comme documentée |
| Providers découverte | **CONFIRMÉ** | iTunes, Apple Music, Spotify, Deezer, MusicBrainz |
| Phase actuelle | **CONFIRMÉ** | "Phase 3 — bibliothèque, métadonnées & sync offline" |

## 11.3 Fonctionnalités annoncées mais non implémentées

| Fonctionnalité | Statut | Détails |
|---------------|--------|---------|
| Application web | **ABSENT** | Dossier `apps/web/` vide |
| Package shared | **ABSENT** | Vide actuellement |

## 12. Dette technique

## 12.1 Structure

| Élément | Impact | Détails |
|---------|--------|---------|
| Fork just_audio | Moyen | Maintenance supplémentaire pour suivre l'amont |
| Scripts PowerShell | Faible | Déploiement manuel, pas de CI/CD |
| Pas de package shared | Faible | Duplication potentielle de types entre backend et mobile |

## 12.2 Code

| Élément | Impact | Détails |
|---------|--------|---------|
| 12 warnings Flutter | Négligeable | Style uniquement |
| Complexité du moteur de discovery | Moyenne | 48 tests montrent la complexité, mais bien gérée |

## 13. Points forts

1. **Tests backend excellents** : 557 tests couvrant les cas critiques, incluant isolation multi-utilisateur, recommandations, acquisition.

2. **Architecture de streaming robuste** : HTTP Range complet, abstraction de stockage, logging détaillé, gestion des erreurs.

3. **Isolation multi-utilisateur** : Implémentée correctement avec `user_tracks`, tests dédiés, OWNER n'a pas plus d'accès de lecture qu'un USER.

4. **Qualité audio mesurée** : Table `track_quality` avec analyse technique (codec, sample rate, bit depth), jamais déduite de l'extension.

5. **Gestion d'erreurs Flutter soignée** : `_DarkErrorScreen` personnalisé, pas d'écran rouge Flutter en production.

6. **Authentification solide** : JWT HMAC, refresh token, secure storage, biométrie, rotation de secret.

7. **Documentation riche** : CLAUDE.md, AGENTS.md, AUDIO_SOURCING.md, LESSONS.md — projet bien documenté.

8. **Protection path traversal** : Implémentée et testée dans le Storage Agent.

9. **Moteur de recommandations avancé** : Profil de goût, graphe Last.fm, pagination par curseur, single-flight.

10. **Code propre** : Aucun TODO/FIXME dans le code source principal, commentaires en français cohérents.

## 14. Plan d'action priorisé

## P0 — À corriger immédiatement

| # | Action | Fichiers concernés | Complexité | Risque | Validation |
|---|--------|-------------------|------------|--------|------------|
| 1 | Aucun problème critique identifié | - | - | - | - |

## P1 — Avant de considérer le MVP stable

| # | Action | Fichiers concernés | Complexité | Risque | Validation |
|---|--------|-------------------|------------|--------|------------|
| 1 | Ajouter rate limiting sur `/api/auth/login` | `services/api/src/app.ts`, `src/routes/auth.ts` | Faible | Faible | Test attaque brute force |
| 2 | Configurer CORS explicitement | `services/api/src/app.ts` | Faible | Faible | Test cross-origin |
| 3 | Automatiser les backups SQLite | `scripts/backup_homespotify.ps1` | Faible | Faible | Vérifier restauration |
| 4 | Mettre en place CI/CD basique | `.github/workflows/` | Moyenne | Faible | Build + tests automatisés |

## P2 — Améliorations importantes

| # | Action | Fichiers concernés | Complexité | Risque | Validation |
|---|--------|-------------------|------------|--------|------------|
| 1 | Créer `packages/shared` avec types communs | `packages/shared/` | Moyenne | Faible | Utilisation par backend et mobile |
| 2 | Ajouter tests Flutter unitaires | `apps/mobile/homespotify_mobile/test/` | Moyenne | Faible | `flutter test` |
| 3 | Support FLAC dans l'import | `services/api/src/import/import-service.ts` | Moyenne | Moyen | Test import FLAC |
| 4 | Monitoring santé du serveur | N/A | Moyenne | Faible | Dashboard métriques |

## P3 — Évolutions futures

| # | Action | Fichiers concernés | Complexité | Risque | Validation |
|---|--------|-------------------|------------|--------|------------|
| 1 | Application web | `apps/web/` | Élevée | Moyen | Tests E2E |
| 2 | Mise à jour just_audio amont | `packages/homespotify_just_audio/` | Élevée | Moyen | Tests audio complets |
| 3 | Mode kiosk / écran TV | N/A | Élevée | Moyen | Tests UI |

## 15. Évaluation finale

| Critère | Note /10 | Justification |
|---------|----------|---------------|
| **Architecture** | 9 | Monorepo bien structuré, séparation claire, abstraction de stockage, injection de dépendances |
| **Backend** | 9 | Fastify robuste, 557 tests, streaming Range excellent, isolation multi-user |
| **Application Flutter** | 8 | Complète, Riverpod bien utilisé, lecteur audio robuste, 12 warnings mineurs |
| **Qualité du code** | 9 | Propre, documenté, aucun TODO, conventions respectées |
| **Tests** | 8 | Backend excellent (557), Flutter non vérifié (pas exécuté) |
| **Sécurité** | 8 | Secrets protégés, JWT, HMAC, path traversal protégé. Rate limiting et CORS à ajouter |
| **Documentation** | 9 | Riche et cohérente avec le code |
| **Maintenabilité** | 8 | Bonne structure, fork just_audio ajoute une dépendance |
| **Préparation à la production** | 7 | Fonctionnel pour usage personnel. CI/CD, monitoring, HTTPS à ajouter pour production publique |
| **Avancement du MVP** | 8 | Fonctionnalités principales implémentées et testées |

### Note globale : 8.3 / 10

**Verdict** : Projet **mature et bien conçu**, prêt pour un usage personnel avancé. Le backend est solide avec une excellente couverture de tests. L'application Flutter est complète. Les améliorations nécessaires pour une production multi-utilisateurs sont mineures (CI/CD, monitoring, rate limiting). Aucune dette technique critique identifiée.

---

# Annexes

## Commandes de vérification recommandées

```bash
# Backend
cd services/api
npm run test          # 557 tests
npm run typecheck     # TypeScript strict
npm run build         # Compilation

# Flutter
cd apps/mobile/homespotify_mobile
flutter analyze       # 12 infos mineures
flutter test          # Tests unitaires (à exécuter)

# Storage Agent
cd services/storage-agent
npm test              # Tests unitaires
npm run typecheck     # TypeScript strict
```

## Fichiers de configuration clés

- `services/api/.env.example` — Variables d'environnement backend
- `services/storage-agent/.env.example` — Variables d'environnement storage agent
- `pnpm-workspace.yaml` — Configuration du monorepo
- `tsconfig.base.json` — Configuration TypeScript partagée