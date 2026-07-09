# TECH_DECISIONS.md — HomeSpotify

Registre des décisions techniques. Toute nouvelle décision ou changement passe par ce fichier. Statuts : **définitive** (remise en cause = discussion explicite) / **temporaire** (réévaluation prévue).

## Stack recommandée

| Domaine | Choix | Statut |
|---|---|---|
| Backend | Node.js LTS + TypeScript + Fastify | définitive |
| Base de données | SQLite (WAL) + Drizzle ORM | définitive (SQLite) / temporaire (Drizzle) |
| Audio (analyse/validation) | ffmpeg + ffprobe (binaires externes) | définitive |
| Tags | music-metadata | temporaire |
| Scanner | scan complet + watcher chokidar | temporaire |
| Format d'ingestion & stockage | WAV PCM 16 bit / 44,1 ou 48 kHz + FLAC lossless 16/24 bit / 44,1, 48, 88,2, 96, 176,4 ou 192 kHz, conservés nativement | définitive (mis à jour 2026-07-09) |
| Extraction tags & qualité | music-metadata (RIFF INFO + ID3v2 embarqué + pochette) | définitive |
| Upload | @fastify/multipart, limite 200 Mo (min 150) | définitive |
| Streaming mobile | WAV/FLAC natifs via HTTP Range | définitive |
| Client v1 | App mobile Flutter Android-first | définitive (décidé 2026-07-08) |
| App mobile | Flutter + just_audio + audio_service | définitive |
| Réseau client mobile | dio | définitive |
| Cache offline mobile | sqflite + path_provider | définitive |
| State management mobile | Riverpod | définitive |
| Auth | Comptes locaux, Argon2id, JWT + refresh révocable | définitive (principe) |
| Accès distant | WireGuard via Tailscale, pas d'exposition publique | définitive (v1) |
| Reverse proxy | Caddy | temporaire |
| Déploiement | Docker Compose | définitive |
| Logs | pino (JSON structuré) | définitive |
| Monitoring | Uptime Kuma + endpoint /health | temporaire |
| Sauvegardes | restic (fichiers) + VACUUM INTO (SQLite) | temporaire |
| Enrichissement métadonnées | MusicBrainz + Cover Art Archive | définitive |
| Package manager | pnpm 10 + workspaces (sans Turborepo/Nx) | définitive (pnpm) / temporaire (sans orchestrateur) |
| Tests | Vitest (DB SQLite `:memory:` pour les tests d'API) | définitive |
| Exécution dev | tsx watch ; build via tsc | temporaire |
| Lint | Aucun linter pour l'instant (TypeScript strict seul) | temporaire |
| Mobile : plateforme prioritaire | Android d'abord | définitive (v1) |
| OS serveur hôte | Windows 11 | définitive (confirmé 2026-07-08) |
| Ingestion masse | CLI `scan` (hors requête HTTP), dédup par hash, dossiers gérés exclus | définitive |
| Téléchargement offline | Route `download` (`Content-Disposition`, Range-resumable) + `etag`/`lastModified` au listing | définitive |

## Raisons des choix

- **Node.js/TypeScript/Fastify** : backend simple, typé, I/O-bound et adapté au streaming ; l'écosystème audio-métadonnées côté serveur reste mature (`music-metadata`). Le mobile passe en Flutter/Dart par décision Phase 4.
- **SQLite** : un serveur, une famille d'utilisateurs — un fichier suffit ; zéro administration ; sauvegarde triviale ; performances largement suffisantes pour des dizaines de milliers de pistes.
- **ffmpeg/ffprobe en binaires** : référence absolue du domaine ; les bindings natifs Node cassent aux mises à jour, les binaires non.
- **WAV et FLAC natifs** (mis à jour 2026-07-09) : le serveur accepte le WAV PCM 16 bit / 44,1–48 kHz et le FLAC lossless 16/24 bit / 44,1, 48, 88,2, 96, 176,4 ou 192 kHz. Il conserve l'extension, le contenu et les métadonnées du fichier importé ; aucune conversion, compression ou réécriture n'intervient dans le pipeline. Le statut qualité reste piloté par la provenance déclarée, jamais par le conteneur (un WAV ou FLAC issu d'un upscale IA = `lossy`).
- **WAV/FLAC natifs via HTTP Range pour le mobile** : la Phase 4 cible explicitement les flux lossless lourds ; l'optimisation côté client passe par Range, ETags, cache offline et politiques réseau, jamais par un transcodage serveur ou un DSP applicatif.
- **Flutter direct en Phase 4** : le backend Phase 1–3 est opérationnel ; l'application mobile devient le client v1. Flutter est retenu pour la fluidité UI, le contrôle natif audio et l'écosystème `just_audio`/`audio_service`.
- **Tailscale/WireGuard d'abord** : supprime toute la classe de risques « API exposée à Internet » pour un usage personnel ; l'exposition publique est un choix réversible plus tard, l'inverse ne l'est pas après compromission.
- **Docker Compose** : reproductibilité et rollback sur une machine unique, sans la complexité d'un orchestrateur.

## Alternatives rejetées

| Alternative | Raison du rejet |
|---|---|
| Réutiliser Navidrome / Jellyfin / Plexamp | Le but est une app maison sur mesure (import + qualité vérifiée + UX propre) ; servir de référence d'inspiration, oui |
| Go / Rust backend | Excellents pour le streaming, mais second langage à maintenir et écosystème tags/métadonnées moins direct ; gain non nécessaire à cette échelle |
| PostgreSQL | Surdimensionné pour un serveur mono-utilisateur ; un service de plus à maintenir H24 |
| Prisma | Plus lourd que Drizzle sur SQLite, moteur de requêtes opaque ; Drizzle reste temporaire |
| React Native + Expo | Remplacé en Phase 4 : Flutter offre un meilleur contrôle UI/animations et une pile audio claire (`just_audio` + `audio_service`) pour les WAV lourds |
| Transcodage Opus mobile en v1 | Écarté du cadrage Phase 4 : introduit une seconde représentation audio et complexifie cache/qualité alors que l'objectif immédiat est la lecture WAV/FLAC native |
| MP3/AAC comme format de stockage | Lossy : contraire à la priorité n°1 du projet |
| FLAC comme format de stockage | Décision WAV-only remplacée le 2026-07-09 : le FLAC lossless est désormais conservé et streamé nativement, sans conversion |
| Import multi-formats (MP3/AAC/ALAC…) | Rejeté : seuls WAV PCM et FLAC lossless sont acceptés ; les formats lossy ou sans analyse lossless fiable restent hors périmètre |
| Redis + BullMQ dès le départ | File de jobs in-process suffisante en v1 ; Redis ajouté seulement si besoin prouvé |
| Nginx | Très bien, mais Caddy automatise TLS avec une config minimale — adapté à une exploitation mono-personne |
| Exposition HTTPS publique en v1 | Surface d'attaque inutile tant que le VPN couvre l'usage |

## Décisions temporaires (réévaluation prévue)

- **Drizzle ORM** : réévaluer après Phase 1 (ergonomie migrations).
- **music-metadata** : réévaluer en Phase 2 si des tags exotiques passent mal (fallback : ffprobe seul).
- **chokidar watcher** : fiabilité à valider sur le système de fichiers réel du serveur (Phase 3).
- **Riverpod** : à réévaluer seulement si l'état applicatif devient trop événementiel pour un modèle provider (cas peu probable en v1 personnelle).
- **Uptime Kuma / restic / Caddy** : confirmer en Phase 7 selon l'infra réelle.
- **Politiques réseau mobile** : ajuster après tests réels de débit montant, consommation data et stabilité des gros WAV en Wi-Fi/cellulaire.
- **Sans Turborepo/Nx** : réévaluer seulement si les builds croisés deviennent pénibles (≥ 3 packages actifs).
- **Sans linter** : ajouter ESLint (config plate minimale) au plus tard en Phase 3, quand le volume de code le justifiera.
- **tsx/tsc** : réévaluer si le build devient lent (alternatives : tsup, esbuild).
- **Migrations auto au démarrage de l'app** : acceptable pour un serveur mono-utilisateur (idempotent, rapide) ; à revoir si multi-instances un jour.

## Décisions définitives

- Qualité audio stockée = qualité **mesurée** (specs) + **provenance déclarée** ; statuts `lossless_verifie` / `lossless_probable` / `lossy` / `inconnue`. La provenance mappe le statut : `rip_cd`/`achat`→`lossless_verifie`, `libre`→`lossless_probable`, `upscale_ia`→`lossy`, `inconnue`→`inconnue`.
- Aucun contournement DRM, jamais.
- Jamais de fichier audio chargé entier en mémoire ; streaming + HTTP Range obligatoires.
- Ingestion et stockage = WAV PCM 16 bit / 44,1–48 kHz ou FLAC lossless 16/24 bit / 44,1, 48, 88,2, 96, 176,4 ou 192 kHz, préservés sans transformation.
- SQLite, Docker Compose, comptes locaux, VPN d'abord.
- La documentation guide le code ; les fichiers de fondation sont maintenus à jour.

## Points à confirmer plus tard

- [ ] OS et specs exactes du serveur maison (CPU, RAM, disques) → dimensionnement streaming, scan et cache.
- [ ] Débit montant de la connexion domestique → qualité max de streaming distant.
- [ ] Vérifier sur les DAC/appareils Android cibles la fréquence réellement ouverte par le système : Android peut mixer ou rééchantillonner après la sortie de l'application, donc l'absence de DSP HomeSpotify ne suffit pas à promettre un bit-perfect matériel universel.
- [ ] Nombre d'utilisateurs réels (solo ou famille) → périmètre auth/profils.
- [ ] Outil de détection fake lossless (cf. `AUDIO_SOURCING.md > À vérifier`).
- [x] Plateforme mobile : **Android d'abord** (décidé 2026-07-08) ; iOS éventuellement plus tard (coût compte développeur Apple).
- [x] OS serveur hôte : **Windows 11** (confirmé 2026-07-08). Conséquence : chemins gérés via `node:path` (backslash), à surveiller si portage Linux un jour (les chemins stockés en base sont en `\`).
- [ ] Validation du build Docker sur le serveur cible (Docker absent de la machine de dev). Note : sous Windows, Docker Desktop (backend WSL2) sera nécessaire ; les chemins de volumes dans `compose.yaml` sont relatifs et compatibles.
- [ ] `import_jobs` / file asynchrone : utile si les scans de très grosses bibliothèques doivent tourner en tâche de fond pilotable depuis l'API (actuellement le scan est un CLI synchrone).
- [ ] Cible de sauvegarde hors site (cloud chiffré ? disque chez un proche ?).
