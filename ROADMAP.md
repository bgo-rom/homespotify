# ROADMAP.md — HomeSpotify

Règle : une phase ne démarre que si les critères de réussite de la précédente sont atteints. Simple avant beau.

> État : Phase 0 ✅ · Phase 1 ✅ · Phase 2 ✅ (import upload + scanner de dossier + streaming livrés le 2026-07-08 ; enrichissement MusicBrainz reporté en Phase 3) · Phase 3 amorcée (téléchargement offline). Toutes dates 2026-07-08.
>
> **Note de périmètre (2026-07-08)** : l'ingestion est **WAV PCM 16 bit / 44,1–48 kHz uniquement** (décision utilisateur) ; serveur hôte **Windows 11**. Le streaming (Phase 4) et le téléchargement offline (Phase 6) sont amorcés dès la Phase 2/3 car indissociables de la validation des gros WAV.

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

## Phase 2 — Import musical local ✅

- **Objectif** : faire entrer des WAV possédés proprement, et pouvoir les écouter.
- **Livrables** : ~~zone de staging~~ ✅, ~~upload API (multipart en flux)~~ ✅, ~~hash en streaming (SHA-256)~~ ✅, ~~détection de doublons~~ ✅, ~~analyse + statut qualité (music-metadata, provenance→statut)~~ ✅, ~~normalisation `Artiste/Album/Titre.wav`~~ ✅, ~~streaming HTTP Range + pochette~~ ✅, ~~**scanner de dossier local** (CLI `scan`, ingestion masse hors upload, dédup par hash, gestion chemins Windows)~~ ✅. **Reporté Phase 3** : file `import_jobs` pour lots asynchrones, enrichissement MusicBrainz.
- **Critères** : ~~importer un WAV → fichier rangé, qualité mesurée, doublon rejeté~~ ✅ ; ~~scanner une bibliothèque WAV existante avec dédup~~ ✅ (validé sur vrai dossier Windows : 3 importés, refus 96 kHz, re-scan 100 % dédupé, 43 tests). Format borné au WAV PCM 16 bit / 44,1–48 kHz ; autres formats refusés en 422.
- **Pièges** : ~~faire confiance à l'extension~~ (conteneur vérifié, statut par provenance) ; ~~écraser un fichier existant~~ (suffixe hash) ; ~~scanner qui re-parcourt sa propre bibliothèque gérée~~ (dossiers gérés exclus de la marche) ; bloquer l'API pendant l'analyse (analyse WAV rapide ; scan en CLI hors requête HTTP).

## Phase 3 — Bibliothèque et métadonnées

- **Objectif** : bibliothèque navigable et fiable.
- **Livrables** : scanner complet + watcher, modèles artistes/albums/pistes, extraction de tags, pochettes + miniatures, enrichissement MusicBrainz optionnel, API paginée de navigation/recherche.
- **Critères** : bibliothèque de test (≥ 500 pistes) scannée sans erreur ; re-scan idempotent ; recherche répond < 200 ms en local.
- **Pièges** : écraser les tags d'origine ; scanner récursif qui suit les liens symboliques ; tags malveillants non échappés (injection).

## Phase 4 — Application mobile Flutter

- **Objectif** : créer le client mobile v1 en Flutter, robuste pour les WAV lourds.
- **Livrables** : projet Flutter initialisé, architecture mobile, navigation bibliothèque/recherche/lecteur, couche audio `just_audio` + `audio_service`, client API `dio`, manifeste offline via `sqflite` + `path_provider`.
- **Critères** : streaming WAV avec seek/reprise via HTTP Range ; lecture arrière-plan/lockscreen Android ; sync manifeste en une requête légère ; premiers téléchargements offline vérifiés par ETag.
- **Pièges** : piloter `just_audio` directement depuis l'UI ; télécharger des WAV entiers en mémoire ; ignorer les ETags ; soigner l'esthétique avant la stabilité audio.

## Phase 5 — Expérience mobile avancée

- **Objectif** : enrichir l'app Flutter après validation du socle audio/offline.
- **Livrables** : animations avancées, file d'attente complète, badges de qualité, politiques Wi-Fi/cellulaire pour les WAV lourds, gestion fine du cache, éventuellement iOS.
- **Critères** : lecture continue en arrière-plan et écran verrouillé ; contrôles casque/voiture ; parcours fluide sur bibliothèque réelle ; cache cohérent après modifications serveur.
- **Pièges** : sous-estimer les permissions/audio focus Android et iOS ; dupliquer la logique métier côté client ; complexifier les animations avant d'avoir stabilisé lecture et offline.

## Phase 6 — Cache hors ligne

- **Objectif** : écouter sans réseau.
- **Fondations posées en Phase 2/3** : route `GET /api/tracks/:id/download` (`Content-Disposition: attachment`, Range-resumable) + `etag`/`lastModified` par piste dans le listing → le client compare son cache local au serveur par hash.
- **Livrables** : téléchargement par piste/album/playlist (route unitaire prête), manifeste local + `cache_state` serveur, vérification par hash, politique de cache WAV original, purge LRU par plafond d'espace, lecture 100 % locale.
- **Critères** : album mis en cache → lecture complète en mode avion ; resync correcte après modification serveur ; suppression libère l'espace annoncé.
- **Pièges** : cache incohérent après renommage serveur (→ toujours réconcilier par hash) ; télécharger sur cellulaire sans consentement ; corruption silencieuse (→ vérifier les hashes).

## Phase 7 — Sécurité, optimisation, production

- **Objectif** : passage en régime de production durable.
- **Livrables** : auth complète (Argon2id, JWT + refresh révocable, rate limiting), accès distant WireGuard/Tailscale documenté, sauvegardes automatisées + test de restauration, Uptime Kuma + alertes, revue de sécurité (`/security-review`), documentation d'exploitation.
- **Critères** : critères de réussite de `PROJECT.md` tous atteints, dont 30 jours sans intervention et restauration testée.
- **Pièges** : exposer l'API publiquement « temporairement » ; sauvegardes jamais testées en restauration ; alertes trop bruyantes qu'on finit par ignorer.
