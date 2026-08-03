# @homespotify/storage-agent

Agent de stockage Windows : sert les octets des fichiers audio locaux au VPS
HomeSpotify et reçoit les nouveaux objets audio immuables à travers WireGuard.

**Documentation de référence : [`docs/VPS_PHASE2_STORAGE_AGENT.md`](../../docs/VPS_PHASE2_STORAGE_AGENT.md).**

## État (Phase 2)

Implémenté et testé en local. **Non déployé** : aucun service Windows installé,
aucune exposition réseau, aucune règle de pare-feu touchée. L'agent n'écoute que
sur `127.0.0.1` et n'est lancé qu'à la main.

## Routes

| Méthode | Route | Rôle |
| --- | --- | --- |
| `GET` | `/internal/storage/health` | état de l'agent (authentifié) |
| `HEAD` | `/internal/storage/tracks/:trackId` | métadonnées, `stat` seul |
| `GET` | `/internal/storage/tracks/:trackId` | flux audio, HTTP Range |
| `PUT` | `/internal/storage/objects/:sha256.:extension` | import streaming durable FLAC/WAV |
| `PUT` | `/internal/storage/index` | publication atomique de l’index complet |

La route d'import n'accepte aucun chemin choisi par le client : le stockage
final est dérivé du SHA-256 sous `.homespotify/objects/`. Le reçu n'est renvoyé
qu'après contrôle taille/empreinte, `fsync`, renommage atomique et nouvelle
synchronisation du fichier final. L’index complet est ensuite publié par une
route distincte, validé, écrit sur le même volume puis installé en mémoire sans
fenêtre d’index partiel.

Toutes authentifiées par HMAC-SHA256 daté avec anti-rejeu, derrière un filtrage
strict de l'IP source.

## Utilisation locale

```bash
pnpm --filter @homespotify/api storage-index:export
```

puis, après avoir créé `.env` depuis `.env.example` :

```bash
pnpm --filter @homespotify/storage-agent dev
```

## Vérification

```bash
pnpm --filter @homespotify/storage-agent test
```
