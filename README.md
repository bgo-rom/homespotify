# HomeSpotify

Application musicale personnelle type Spotify, **100 % auto-hébergée** sur un serveur maison : bibliothèque privée, streaming mobile, cache hors ligne, et priorité absolue à la **qualité audio réelle et vérifiée**.

## ⚠️ Avertissement qualité audio

**YouTube ≠ lossless.** YouTube (et toute source équivalente) sert de l'audio déjà compressé (~130–160 kbps Opus/AAC). Le convertir en FLAC ne recrée aucune qualité perdue. Ici, la qualité affichée est toujours **mesurée** (ffprobe + analyse), jamais déduite de l'extension du fichier. Détails : [AUDIO_SOURCING.md](AUDIO_SOURCING.md). Aucun contournement DRM dans ce projet.

## Statut actuel

**Phase 2 ✅ → Phase 3 amorcée** — dans `services/api` : upload multipart de gros WAV, **scanner de dossier local** (CLI `scan`, dédup par hash, chemins Windows), extraction tags/pochette (music-metadata), qualité mesurée + statut par provenance, streaming HTTP Range robuste (`audio/wav`, 206/416), **téléchargement offline** (`download` + `etag`/`lastModified`), lecteur dev `/player`. 43 tests. Serveur hôte **Windows 11**. **Ingestion bornée au WAV PCM 16 bit / 44,1–48 kHz.** Restant : enrichissement MusicBrainz, watcher de dossier (Phase 3).

## Stack pressentie

Node.js LTS + TypeScript + Fastify · SQLite (WAL) + Drizzle · ffmpeg/ffprobe · FLAC (stockage) / Opus (streaming mobile) · PWA puis React Native/Expo · WireGuard/Tailscale · Docker Compose. Justifications et statuts (définitif/temporaire) : [TECH_DECISIONS.md](TECH_DECISIONS.md).

## Ordre de lecture

1. [CLAUDE.md](CLAUDE.md) — règles de travail des IA sur ce dépôt
2. [PROJECT.md](PROJECT.md) — vision, objectifs, MVP, critères de réussite
3. [TECH_DECISIONS.md](TECH_DECISIONS.md) — choix techniques
4. [ARCHITECTURE.md](ARCHITECTURE.md) — architecture cible
5. [ROADMAP.md](ROADMAP.md) — phases 0 → 7
6. [AUDIO_SOURCING.md](AUDIO_SOURCING.md) — acquisition et qualité audio
7. [AGENTS.md](AGENTS.md) — règles pour les sous-agents
8. [LESSONS.md](LESSONS.md) — leçons apprises

## Structure du dépôt

```
docs/               Documentation complémentaire
apps/mobile/        Future app React Native (Phase 5)
apps/web/           Future PWA mobile-first (Phase 4)
services/api/       Futur backend Fastify (Phase 1)
packages/shared/    Types et logique partagés
storage/            Données locales (music, imports, covers, cache) — non versionnées
scripts/            Scripts d'exploitation
infra/              Docker Compose, config déploiement
tests/              Tests transverses
```

## Démarrage rapide

Prérequis : Node.js ≥ 22 et pnpm 10 (`corepack enable` ou `npx -y pnpm@10 <cmd>`).

```bash
pnpm install          # dépendances du monorepo
pnpm dev              # backend en mode watch (http://127.0.0.1:3000)
pnpm test             # tests (Vitest, DB en mémoire, aucun service externe)
pnpm typecheck        # vérification TypeScript stricte
pnpm build            # compilation vers services/api/dist
pnpm start            # lance le build compilé
pnpm db:migrate       # applique les migrations Drizzle sur la base locale
```

Configuration par variables d'environnement (toutes optionnelles en dev) : `HOST`, `PORT`, `DB_PATH`, `LOG_LEVEL`, `NODE_ENV`, `MUSIC_DIR`, `INCOMING_DIR`, `COVERS_DIR`, `MAX_UPLOAD_MB` (≥ 150, défaut 200).

### Endpoints (Phase 2)

| Méthode | Route | Rôle |
|---|---|---|
| GET | `/health` `/version` `/api/status` | Sondes (status inclut `trackCount`) |
| POST | `/api/tracks` | Import WAV (multipart : champ `file` + `provenance` optionnel) |
| GET | `/api/tracks?page&limit` | Liste paginée + qualité + `etag`/`lastModified` (comparaison cache) |
| GET | `/api/tracks/:id/stream` | Streaming WAV avec HTTP Range (206/416) |
| GET | `/api/tracks/:id/download` | Téléchargement forcé (`Content-Disposition`, offline mobile) |
| GET | `/api/tracks/:id/cover` | Pochette embarquée |
| GET | `/player` | Lecteur web de validation (dev) |

Import via curl (chemin **relatif**, cf. [LESSONS.md](LESSONS.md) L-010) :

```bash
cd /dossier/du/wav
curl -X POST http://127.0.0.1:3000/api/tracks \
  -F "provenance=rip_cd" -F "file=@morceau.wav;type=audio/wav"
```

Provenances acceptées : `rip_cd`, `achat`, `libre`, `upscale_ia`, `inconnue` (défaut). Elle détermine le statut qualité — un `upscale_ia` est marqué `lossy`, jamais lossless.

### Scanner un dossier local (ingestion en masse)

Pour ingérer une bibliothèque WAV existante sans upload HTTP (dédup automatique par hash, re-scan sûr) :

```bash
pnpm --filter @homespotify/api scan -- "C:\Musique_HomeSpotify" --provenance rip_cd
```

Le scanner parcourt récursivement le dossier (chemins Windows gérés), copie chaque WAV valide dans la bibliothèque gérée (`MUSIC_DIR`), ignore les fichiers déjà en base et refuse ce qui n'est pas du WAV 16 bit / 44,1–48 kHz. Un fichier en échec n'interrompt pas le lot ; code de sortie ≠ 0 s'il y a au moins un échec.

### Docker

```bash
docker compose -f infra/compose.yaml up --build
```

Non testé sur cette machine (Docker absent) — à valider sur le serveur cible.

## Prochaine étape

Terminer la Phase 2 : **scanner de dossier** (ingérer une bibliothèque WAV existante sans passer par l'upload) et file `import_jobs` pour les lots. Puis **Phase 3 — bibliothèque & métadonnées** (enrichissement MusicBrainz, miniatures). Voir [ROADMAP.md](ROADMAP.md).

## Commandes Git utiles

```bash
git status                  # état du dépôt
git add -A                  # indexer les changements
git commit -m "message"     # committer
git log --oneline           # historique
git diff                    # changements non indexés
```

## Règle absolue

**Jamais dans Git** : musique réelle, fichiers audio, tokens, clés API, mots de passe, `.env`, bases SQLite générées. Le [.gitignore](.gitignore) les bloque — ne pas le contourner avec `git add -f`.
