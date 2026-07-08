# ROADMAP.md — HomeSpotify

Règle : une phase ne démarre que si les critères de réussite de la précédente sont atteints. Simple avant beau.

## Phase 0 — Documentation et décisions

- **Objectif** : fondations documentaires complètes et cohérentes.
- **Livrables** : `CLAUDE.md`, `AGENTS.md`, `PROJECT.md`, `AUDIO_SOURCING.md`, `ARCHITECTURE.md`, `ROADMAP.md`, `TECH_DECISIONS.md`, `LESSONS.md` ; dépôt git initialisé avec `.gitignore`.
- **Critères de réussite** : les 8 fichiers existent, sections complètes, aucune contradiction ; points `À vérifier` listés.
- **Pièges** : sur-documenter des détails qui changeront ; décider sans marquer « temporaire » ce qui est incertain.

## Phase 1 — Backend minimal

- **Objectif** : squelette API sain et exécutable.
- **Livrables** : projet TypeScript/Fastify, config par variables d'environnement, SQLite + migrations Drizzle, `/health`, logs pino, tests de base, Dockerfile + docker-compose.
- **Critères** : `docker compose up` → API répond ; migration/rollback fonctionnent ; lint + tests passent en CI locale.
- **Pièges** : ajouter des features métier trop tôt ; coupler la config à la machine ; ignorer la gestion d'erreurs dès le départ.

## Phase 2 — Import musical local

- **Objectif** : faire entrer des fichiers possédés proprement.
- **Livrables** : zone de staging, upload API (multipart en flux), hash en streaming, détection de doublons, analyse ffprobe + statut qualité, normalisation `Artiste/Album (Année)/NN - Titre.ext`, table `import_jobs`.
- **Critères** : importer un album FLAC et un album MP3 → fichiers rangés, qualité mesurée en base, doublon rejeté avec raison ; aucun fichier chargé entier en RAM.
- **Pièges** : faire confiance à l'extension ; écraser un fichier existant ; bloquer l'API pendant l'analyse (→ jobs en fond).

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
