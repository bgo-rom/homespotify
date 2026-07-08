# ROADMAP.md — HomeSpotify

Règle : une phase ne démarre que si les critères de réussite de la précédente sont atteints. Simple avant beau.

> État : Phase 0 ✅ · Phase 1 ✅ · Phase 2 🚧 (import + streaming WAV livrés le 2026-07-08 ; scanner de dossier et enrichissement MusicBrainz restent à faire) · toutes dates 2026-07-08.
>
> **Note de périmètre (2026-07-08)** : l'ingestion est désormais **WAV PCM 16 bit / 44,1–48 kHz uniquement** (décision utilisateur). Le streaming (Phase 4) est déjà amorcé en Phase 2 car indissociable de la validation des gros WAV.

## Phase 0 — Documentation et décisions

- **Objectif** : fondations documentaires complètes et cohérentes.
- **Livrables** : `CLAUDE.md`, `AGENTS.md`, `PROJECT.md`, `AUDIO_SOURCING.md`, `ARCHITECTURE.md`, `ROADMAP.md`, `TECH_DECISIONS.md`, `LESSONS.md` ; dépôt git initialisé avec `.gitignore`.
- **Critères de réussite** : les 8 fichiers existent, sections complètes, aucune contradiction ; points `À vérifier` listés.
- **Pièges** : sur-documenter des détails qui changeront ; décider sans marquer « temporaire » ce qui est incertain.

## Phase 1 — Backend minimal ✅

- **Objectif** : squelette API sain et exécutable.
- **Livrables** : projet TypeScript/Fastify, config par variables d'environnement, SQLite + migrations Drizzle, `/health`, logs pino, tests de base, Dockerfile + docker-compose. *(Livré : `services/api`, endpoints `/health` `/version` `/api/status`, table `app_meta`, 8 tests Vitest.)*
- **Critères** : `docker compose up` → API répond ; migration/rollback fonctionnent ; lint + tests passent en CI locale. *(Atteints localement — typecheck, tests, build, smoke-test serveur OK ; image Docker à valider sur le serveur cible, Docker absent de la machine de dev.)*
- **Pièges** : ajouter des features métier trop tôt ; coupler la config à la machine ; ignorer la gestion d'erreurs dès le départ.

## Phase 2 — Import musical local 🚧

- **Objectif** : faire entrer des WAV possédés proprement, et pouvoir les écouter.
- **Livrables** : ~~zone de staging~~ ✅, ~~upload API (multipart en flux)~~ ✅, ~~hash en streaming (SHA-256)~~ ✅, ~~détection de doublons~~ ✅, ~~analyse + statut qualité (music-metadata, provenance→statut)~~ ✅, ~~normalisation `Artiste/Album/Titre.wav`~~ ✅, ~~streaming HTTP Range + pochette~~ ✅. **Restant** : scanner de dossier existant (ingestion hors upload), file `import_jobs` pour les lots, enrichissement métadonnées (→ Phase 3).
- **Critères** : ~~importer un WAV → fichier rangé, qualité mesurée en base, doublon rejeté avec raison ; aucun fichier chargé entier en RAM~~ ✅ (vérifié end-to-end : import 201, dédup 409, Range 206/416, 32 tests). Format d'ingestion borné au WAV PCM 16 bit / 44,1–48 kHz ; les autres formats sont refusés en 422.
- **Pièges** : ~~faire confiance à l'extension~~ (le conteneur est vérifié, le statut vient de la provenance) ; ~~écraser un fichier existant~~ (suffixe hash en cas de collision) ; bloquer l'API pendant l'analyse (l'analyse WAV est rapide ; passer en job de fond si des lots volumineux apparaissent).

## Phase 3 — Bibliothèque et métadonnées

- **Objectif** : bibliothèque navigable et fiable.
- **Livrables** : scanner complet + watcher, modèles artistes/albums/pistes, extraction de tags, pochettes + miniatures, enrichissement MusicBrainz optionnel, API paginée de navigation/recherche.
- **Critères** : bibliothèque de test (≥ 500 pistes) scannée sans erreur ; re-scan idempotent ; recherche répond < 200 ms en local.
- **Pièges** : écraser les tags d'origine ; scanner récursif qui suit les liens symboliques ; tags malveillants non échappés (injection).

## Phase 4 — Streaming audio

- **Objectif** : écouter depuis un navigateur, de façon robuste.
- **Livrables** : endpoint stream avec HTTP Range complet (206, seek, reprise), ETag, transcodage Opus à la volée optionnel, client web mobile-first minimal (liste + lecteur).
- **Critères** : seek instantané dans un FLAC de 50 Mo ; reprise après coupure réseau ; deux lectures simultanées sans saturer le serveur.
- **Pièges** : implémenter Range à moitié (certains lecteurs exigent la spec complète) ; transcoder par défaut en local ; fuites de processus ffmpeg orphelins.

## Phase 5 — Application mobile

- **Objectif** : vraie app mobile avec lecture en arrière-plan.
- **Livrables** : app React Native/Expo, react-native-track-player (lock screen, notifications, file d'attente), navigation bibliothèque/recherche/lecteur, badges de qualité, choix direct/transcodé.
- **Critères** : lecture continue en arrière-plan et écran verrouillé ; contrôles casque/voiture ; parcours fluide sur la bibliothèque de test.
- **Pièges** : sous-estimer les permissions/audio focus Android et iOS ; dupliquer la logique métier côté client ; soigner l'esthétique avant la stabilité de lecture.

## Phase 6 — Cache hors ligne

- **Objectif** : écouter sans réseau.
- **Livrables** : téléchargement par piste/album/playlist, manifeste local + `cache_state` serveur, vérification par hash, choix qualité du cache, purge LRU par plafond d'espace, lecture 100 % locale.
- **Critères** : album mis en cache → lecture complète en mode avion ; resync correcte après modification serveur ; suppression libère l'espace annoncé.
- **Pièges** : cache incohérent après renommage serveur (→ toujours réconcilier par hash) ; télécharger sur cellulaire sans consentement ; corruption silencieuse (→ vérifier les hashes).

## Phase 7 — Sécurité, optimisation, production

- **Objectif** : passage en régime de production durable.
- **Livrables** : auth complète (Argon2id, JWT + refresh révocable, rate limiting), accès distant WireGuard/Tailscale documenté, sauvegardes automatisées + test de restauration, Uptime Kuma + alertes, revue de sécurité (`/security-review`), documentation d'exploitation.
- **Critères** : critères de réussite de `PROJECT.md` tous atteints, dont 30 jours sans intervention et restauration testée.
- **Pièges** : exposer l'API publiquement « temporairement » ; sauvegardes jamais testées en restauration ; alertes trop bruyantes qu'on finit par ignorer.
