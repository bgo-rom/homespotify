# TECH_DECISIONS.md — HomeSpotify

Registre des décisions techniques. Toute nouvelle décision ou changement passe par ce fichier. Statuts : **définitive** (remise en cause = discussion explicite) / **temporaire** (réévaluation prévue).

## Stack recommandée

| Domaine | Choix | Statut |
|---|---|---|
| Backend | Node.js LTS + TypeScript + Fastify | définitive |
| Base de données | SQLite (WAL) + Drizzle ORM | définitive (SQLite) / temporaire (Drizzle) |
| Audio (analyse/transcodage) | ffmpeg + ffprobe (binaires externes) | définitive |
| Tags | music-metadata | temporaire |
| Scanner | scan complet + watcher chokidar | temporaire |
| Format de stockage lossless | FLAC | définitive |
| Transcodage streaming mobile | Opus 128–192 kbps à la volée | définitive (principe) / temporaire (débits) |
| Client v1 | Web mobile-first (PWA) | définitive |
| App mobile | React Native + Expo + react-native-track-player | temporaire |
| Auth | Comptes locaux, Argon2id, JWT + refresh révocable | définitive (principe) |
| Accès distant | WireGuard via Tailscale, pas d'exposition publique | définitive (v1) |
| Reverse proxy | Caddy | temporaire |
| Déploiement | Docker Compose | définitive |
| Logs | pino (JSON structuré) | définitive |
| Monitoring | Uptime Kuma + endpoint /health | temporaire |
| Sauvegardes | restic (fichiers) + VACUUM INTO (SQLite) | temporaire |
| Enrichissement métadonnées | MusicBrainz + Cover Art Archive | définitive |

## Raisons des choix

- **Node.js/TypeScript/Fastify** : un seul langage du backend au mobile (React Native) ; écosystème audio-métadonnées mature (`music-metadata`) ; le streaming est I/O-bound, domaine où Node excelle ; Fastify est rapide, typé, avec plugins de streaming éprouvés.
- **SQLite** : un serveur, une famille d'utilisateurs — un fichier suffit ; zéro administration ; sauvegarde triviale ; performances largement suffisantes pour des dizaines de milliers de pistes.
- **ffmpeg/ffprobe en binaires** : référence absolue du domaine ; les bindings natifs Node cassent aux mises à jour, les binaires non.
- **FLAC comme format de référence** : lossless, libre, tags natifs, ~50 % plus léger que WAV, supporté partout.
- **Opus pour le transcodage mobile** : meilleur codec lossy à débit égal ; standard ouvert ; supporté nativement Android/iOS moderne.
- **PWA avant app native** : valide l'API et l'UX de streaming sans le coût mobile ; l'app native (Phase 5) arrive quand le backend est prouvé.
- **Tailscale/WireGuard d'abord** : supprime toute la classe de risques « API exposée à Internet » pour un usage personnel ; l'exposition publique est un choix réversible plus tard, l'inverse ne l'est pas après compromission.
- **Docker Compose** : reproductibilité et rollback sur une machine unique, sans la complexité d'un orchestrateur.

## Alternatives rejetées

| Alternative | Raison du rejet |
|---|---|
| Réutiliser Navidrome / Jellyfin / Plexamp | Le but est une app maison sur mesure (import + qualité vérifiée + UX propre) ; servir de référence d'inspiration, oui |
| Go / Rust backend | Excellents pour le streaming, mais second langage à maintenir et écosystème tags/métadonnées moins direct ; gain non nécessaire à cette échelle |
| PostgreSQL | Surdimensionné pour un serveur mono-utilisateur ; un service de plus à maintenir H24 |
| Prisma | Plus lourd que Drizzle sur SQLite, moteur de requêtes opaque ; Drizzle reste temporaire |
| Flutter | Solide, mais impose Dart ; React Native mutualise TypeScript avec le backend |
| MP3/AAC comme format de stockage | Lossy : contraire à la priorité n°1 du projet |
| Redis + BullMQ dès le départ | File de jobs in-process suffisante en v1 ; Redis ajouté seulement si besoin prouvé |
| Nginx | Très bien, mais Caddy automatise TLS avec une config minimale — adapté à une exploitation mono-personne |
| Exposition HTTPS publique en v1 | Surface d'attaque inutile tant que le VPN couvre l'usage |

## Décisions temporaires (réévaluation prévue)

- **Drizzle ORM** : réévaluer après Phase 1 (ergonomie migrations).
- **music-metadata** : réévaluer en Phase 2 si des tags exotiques passent mal (fallback : ffprobe seul).
- **chokidar watcher** : fiabilité à valider sur le système de fichiers réel du serveur (Phase 3).
- **React Native/Expo** : confirmer en début de Phase 5 (état de react-native-track-player à ce moment-là).
- **Uptime Kuma / restic / Caddy** : confirmer en Phase 7 selon l'infra réelle.
- **Débits Opus (128–192)** : ajuster après tests d'écoute et mesure du débit montant réel.

## Décisions définitives

- Qualité audio stockée = qualité **mesurée** ; statuts `lossless_verifie` / `lossless_probable` / `lossy` / `inconnue`.
- Aucun contournement DRM, jamais.
- Jamais de fichier audio chargé entier en mémoire ; streaming + HTTP Range obligatoires.
- FLAC = format de stockage lossless de référence.
- SQLite, Docker Compose, comptes locaux, VPN d'abord.
- La documentation guide le code ; les fichiers de fondation sont maintenus à jour.

## Points à confirmer plus tard

- [ ] OS et specs exactes du serveur maison (CPU, RAM, disques) → dimensionnement transcodage.
- [ ] Débit montant de la connexion domestique → qualité max de streaming distant.
- [ ] Nombre d'utilisateurs réels (solo ou famille) → périmètre auth/profils.
- [ ] Outil de détection fake lossless (cf. `AUDIO_SOURCING.md > À vérifier`).
- [ ] iOS, Android ou les deux pour l'app mobile (impacte Phase 5 et le coût compte développeur Apple).
- [ ] Cible de sauvegarde hors site (cloud chiffré ? disque chez un proche ?).
