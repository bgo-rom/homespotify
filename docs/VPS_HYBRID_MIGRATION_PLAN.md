# Plan de migration hybride HomeSpotify vers VPS OVH

**Statut :** plan de conception validé — exécution par phases contrôlées.
**Audit initial :** 2026-07-25 · **Dépôt :** `F:\dev\homespotify` · branche `feature/lucida-import`
**Révision Phase 0 :** 2026-07-25 — budget disque recalculé sur mesures réelles, séparateurs de chemins requalifiés en risque bloquant.
**Avancement au 2026-07-27 :** phases 0 à 5 **qualifiées sur environnement réel** (Phase 4.5 et Phase 5 en GO final). Phase 6 planifiée, non commencée — `docs/VPS_PHASE6_SHADOW_DEPLOYMENT_PLAN.md`. La production reste sur HomeSpotifyApi Windows ; **aucune modification de Caddy n'a eu lieu et aucune n'est autorisée avant l'étape 10**.

> Ce document est la référence unique de la migration. Les relevés d'inventaire
> vivent dans `docs/VPS_PHASE0_INVENTORY.md`.

---

## 1. Résumé exécutif

L'audit du dépôt a invalidé trois hypothèses de départ, et la Phase 0 en a ajouté une quatrième — la seule vraiment défavorable.

1. **Aucun chemin absolu Windows n'est stocké en base.** `tracks.path` est déclaré *relatif à `musicDir`* ([schema.ts:22](../services/api/src/db/schema.ts)), `cover_path` relatif à `coversDir`, `import_jobs.relative_path`, `acquisition_jobs.downloaded_relative_path` et `track_offline_variants.path` sont également relatifs. **Vérifié sur les données réelles : 0 chemin absolu sur 157 pistes.** Aucune migration de schéma n'est requise.
2. **Le streaming est centralisé dans une seule fonction.** `serveTrackFile` ([tracks.ts:50](../services/api/src/routes/tracks.ts)) est le point de passage unique ; `routes/offline.ts` la réutilise explicitement. L'abstraction de stockage se greffe **à un seul endroit**.
3. **Le transfert cohérent de la base existe déjà.** `server-backup.ts` utilise la **SQLite Backup API** (`source.backup()`), avec `journal_mode = WAL` confirmé en production.
4. **⚠️ Les 157 chemins stockés utilisent le séparateur `\` (Windows).** Sur Linux, `\` n'est pas un séparateur de chemin : il fait partie du nom de fichier. **C'est le seul point réellement bloquant de la migration** et il est traité en Phase 1 (§18).

La bibliothèque mesure **2,93 Go pour 157 pistes** : elle tient intégralement dans le cache VPS envisagé. Le dimensionnement du cache est donc dicté par la **croissance future**, pas par le volume actuel.

**Effort total :** 5 à 8 jours-homme sur 3–4 semaines.
**Indisponibilité :** 5 à 15 minutes, une seule fois (Phase 10).

---

## 2. État actuel (constaté, non supposé)

### 2.1 Backend

| Élément | Valeur constatée | Source |
|---|---|---|
| Point d'entrée | `services/api/dist/server.js` | `HomeSpotifyApi.xml` |
| Exécutable | `C:\Program Files\nodejs\node.exe` | idem |
| Répertoire de travail | `F:\dev\homespotify\services\api` | idem |
| Compte de service | **LocalSystem** ⚠️ | idem |
| `HOST` | `0.0.0.0` ⚠️ | idem |
| `PORT` | `3000` | idem |
| Redémarrage auto | `onfailure restart`, délai 10 s | idem |
| Timeout d'arrêt | 20 s | idem |
| Logs | `%BASE%\logs`, mode `roll` | idem |
| Arrêt propre | `SIGINT`/`SIGTERM` → `app.close()` | [server.ts:28-40](../services/api/src/server.ts) |
| Health check | `GET /health` | [app.ts:410](../services/api/src/app.ts) |
| Node requis | `>=22` (local : v22.18.0) | `package.json` |
| Gestionnaire | `pnpm@10.12.1` | `package.json` |
| Dépendances natives | `better-sqlite3@^12.2.0`, `@node-rs/argon2@^2.0.2` | `services/api/package.json` |

⚠️ Deux corrections de sécurité à porter dans la cible : `LocalSystem` (privilèges maximaux) et `HOST=0.0.0.0` (écoute toutes interfaces).

### 2.2 Données mesurées

| Mesure | Valeur réelle |
|---|---|
| Base active | `services/api/data/homespotify.db` |
| Taille base | 3,23 Mo |
| WAL / SHM | 1,95 Mo / 32 Ko (présents) |
| `journal_mode` | `wal` |
| `PRAGMA quick_check` | **ok** |
| `page_size` | 4096 |
| Pistes | 157 |
| Comptes | 3 |
| Playlists / favoris | 1 / 9 |
| Sessions d'écoute | 443 |
| Demandes musicales | 16 |
| `user_tracks` | 158 |
| Bibliothèque | **2,93 Go** (157 FLAC + 1 WAV) |
| Taille moyenne / médiane / max | 19,1 / 17,8 / 38,9 Mo |
| Pochettes | 16 Mo |
| Staging imports | 3,3 Go |

### 2.3 Streaming

- `parseRangeHeader` conforme RFC 9110 ([lib/range.ts](../services/api/src/lib/range.ts)) : `bytes=a-b`, suffixe `bytes=-N`, multi-range → 200, hors bornes → 416. Couvert par `range.test.ts`.
- `serveTrackFile(request, reply, trackId, absPath, hash, contentType, disposition?)` : `createReadStream` avec `{start, end}`, `highWaterMark` dédié, `Transform` de métrage, gestion de `request.raw.'aborted'`.
- Événements émis : `STREAM_RANGE_PARSED`, `STREAM_FILE_OPEN_STARTED`, `STREAM_FILE_OPEN_COMPLETED`, `STREAM_FIRST_CHUNK_SENT`, `STREAM_FILE_ERROR`, `STREAM_COMPLETED`.
- **Cette instrumentation est corrélée aux diagnostics Android — elle doit être préservée à l'identique.**
- Tests présents : `lib/range.test.ts`, `tracks.test.ts`, `routes/offline.test.ts`.

### 2.4 Variables d'environnement (noms uniquement)

Lues par `config.ts` : `NODE_ENV`, `HOST`, `PORT`, `LOG_LEVEL`, `DB_PATH`, `MUSIC_DIR`, `INCOMING_DIR`, `HOMESPOTIFY_IMPORT_ROOT`, `COVERS_DIR`, `OFFLINE_CACHE_DIR`, `OFFLINE_ENCODE_CONCURRENCY`, `MAX_UPLOAD_MB`, `AUTH_TOKEN_SECRET`, `ACCESS_TOKEN_TTL_SECONDS`, `REFRESH_TOKEN_TTL_DAYS`, `BACKUP_ENABLED`, `BACKUP_ROOT`, `BACKUP_HOUR_LOCAL`, `BACKUP_RETENTION_COUNT`, `FFMPEG_PATH`, `FFPROBE_PATH`, `LASTFM_*`, `APPLE_MUSIC_*`, `SPOTIFY_*`, `DEEZER_*`, `MUSICBRAINZ_*`, `DISCOVERY_*`, `LUCIDA_*`.

Défauts appliqués en production Windows (non surchargés dans `.env`) : `DB_PATH=./data/homespotify.db`, `MUSIC_DIR=../../storage/music`, `COVERS_DIR=../../storage/covers`, `PORT=3000` (surchargé à 3000 par WinSW), `HOST=0.0.0.0` (par WinSW).

### 2.5 Absent du dépôt — INFORMATION À RELEVER

- Aucune configuration Caddy versionnée.
- Aucune configuration WireGuard versionnée.
- Aucun script de déploiement VPS.
- `ARCHITECTURE.md:144` et `TECH_DECISIONS.md:26` documentent encore « WireGuard via Tailscale, pas d'exposition publique » : **la documentation est en retard sur la réalité** (le domaine public existe). À corriger dans une mission dédiée.

---

## 3. Architecture cible

**VPS OVH :** API Fastify, authentification, SQLite, catalogue et métadonnées, utilisateurs, playlists, favoris, historique d'écoute, recommandations, recherche Discovery, demandes musicales, orchestration des tâches d'acquisition, administration, cache audio, cache des pochettes, logs, diagnostics, reverse proxy Caddy, HTTPS, service systemd, sauvegardes, supervision.

**PC Windows :** bibliothèque complète FLAC/WAV (source de vérité), imports, validation des fichiers, extraction des tags, hash et déduplication, watcher, connecteurs d'acquisition (Lucida/Playwright), sauvegarde locale, Storage Agent.

**Communication :** VPS ↕ WireGuard ↕ PC Windows. Le téléphone ne communique plus qu'avec `https://music.romainbegot.fr`.

---

## 4. Diagramme des flux

```
                    ┌───────────────────────── VPS OVH (Debian) ─────────────────────────┐
 Téléphone          │                                                                    │
 Android  ──HTTPS──▶│  Caddy :443  ──▶  Fastify 127.0.0.1:3000                            │
 (music.            │                        │                                           │
  romainbegot.fr)   │                        ├─ SQLite /var/lib/homespotify/db (local)   │
                    │                        ├─ CachedAudioStorageProvider               │
                    │                        │     ├─ hit  ──▶ cache local (8 Go max)    │
                    │                        │     └─ miss ──▶ RemoteWindowsStorage      │
                    └────────────────────────────────────┼───────────────────────────────┘
                                                         │ WireGuard (chiffré)
                    ┌────────────────────────────────────▼───────── PC Windows 11 ───────┐
                    │  HomeSpotifyStorageAgent  (écoute WG uniquement, jamais public)     │
                    │      └─ F:\dev\homespotify\storage\music  (source de vérité)        │
                    │  Watcher d'import · hash SHA-256 · déduplication · tags · Lucida    │
                    └────────────────────────────────────────────────────────────────────┘
```

---

## 5–7. Inventaire et répartition des composants

| Composant | Destination | Justification |
|---|---|---|
| API Fastify, auth, rôles | VPS | Disponibilité indépendante du domicile |
| SQLite + migrations | VPS | Base locale sur SSD, un seul écrivain |
| Catalogue, playlists, favoris, historique | VPS | Métadonnées, faible volume |
| Recommandations, Discovery | VPS | Appels sortants vers API publiques |
| Demandes musicales | VPS | Métier pur |
| Administration | VPS | |
| Cache audio + pochettes | VPS | Nouveau |
| Caddy, HTTPS | VPS | Déjà en place |
| **Fichiers FLAC/WAV** | **PC** | 2,93 Go, source de vérité |
| **Watcher d'import** | **PC** | Accès direct au système de fichiers |
| **Hash SHA-256, déduplication** | **PC** | Nécessite le fichier complet |
| **Extraction des tags** | **PC** | idem |
| **Runner Lucida (Python + Playwright)** | **PC** | Dépend de Chromium et du poste — **non migrable** |
| **Storage Agent** | **PC** | Nouveau |

**Q1/Q2 :** tout ce qui relève des métadonnées et de la décision va sur le VPS ; tout ce qui touche les octets audio et les processus lourds reste sur le PC.

---

## 8–9. Abstraction de stockage

**Q4 : oui, l'essentiel du backend est réutilisé.** Le point d'insertion est unique.

Nouveau fichier `services/api/src/storage/audio-storage.ts` :

```ts
export interface TrackStorageReference {
  trackId: number;
  relativePath: string;   // tracks.path — déjà relatif, à NORMALISER (§18)
  sizeBytes: number;      // tracks.size_bytes — garde-fou d'intégrité
  contentHash: string;    // tracks.hash (SHA-256) — ETag et validation du cache
}

export type ByteRange = { start: number; end: number };

export interface AudioFileInfo {
  sizeBytes: number;
  mtimeMs: number;
  source: 'local' | 'cache' | 'remote';
}

export type StorageHealth =
  | { status: 'online'; latencyMs: number }
  | { status: 'offline'; since: Date; reason: string }
  | { status: 'degraded'; reason: string };

export interface AudioStorageProvider {
  stat(ref: TrackStorageReference): Promise<AudioFileInfo>;
  createReadStream(ref: TrackStorageReference, range?: ByteRange): Promise<Readable>;
  healthCheck(): Promise<StorageHealth>;
}
```

**Implémentations :**
1. `LocalFileStorageProvider` — enveloppe le code actuel, comportement identique à aujourd'hui. Compatibilité et mode de secours.
2. `RemoteWindowsStorageProvider` — HTTP vers le Storage Agent via WireGuard.
3. `CachedAudioStorageProvider` — décorateur : cache local, sinon délégation au distant avec remplissage.

**Stratégie de compatibilité :** variable `AUDIO_STORAGE_MODE=local|remote|cached`, défaut **`local`**. Tant qu'elle vaut `local`, le comportement est celui d'aujourd'hui. **Le rollback de la Phase 1 est une variable d'environnement.**

**Fichiers concernés :** `routes/tracks.ts` (signature de `serveTrackFile` : `absPath: string` → `ref: TrackStorageReference`), `routes/offline.ts` (hérite du changement), `app.ts` (câblage), `config.ts` (nouvelles variables). **Aucun contrat HTTP ne change.**

**Q7/Q8 — transfert des Range :** le Range est parsé **une seule fois sur le VPS** (`parseRangeHeader` inchangé), puis :
- cache hit → `createReadStream` local avec `{start, end}` : identique à aujourd'hui ;
- cache miss → Range **retransmis** au Storage Agent, qui répond 206 ; le VPS relaie le flux.

Le VPS ne re-parse jamais la réponse de l'agent : il lit `Content-Length` et vérifie la cohérence avec `sizeBytes`.

---

## 10. Storage Agent Windows

**Q3 : oui, projet séparé** — `services/storage-agent/`, dans le monorepo pnpm existant.
Justification : cycle de vie, surface d'attaque et dépendances distincts. Il ne doit **pas** embarquer Drizzle, l'authentification applicative ni Discovery.

**Routes (minimales) :**
```
GET  /internal/storage/health          → {status, freeBytes, trackCount}
HEAD /internal/storage/tracks/:trackId → Content-Length, Accept-Ranges, ETag
GET  /internal/storage/tracks/:trackId → 200 | 206 | 404 | 416
```

**Pas de `POST /prefetch`** : le préchargement est un simple `GET` déclenché par le VPS. Un endpoint de plus = surface de plus, sans gain.

**Résolution de l'identifiant :** l'agent reçoit un `trackId` numérique, **jamais un chemin**. Il détient un index `trackId → relativePath` régénéré par le VPS et rechargé à chaud. Le chemin final est `resolve(MUSIC_ROOT, relativePath)` avec **vérification que le résultat reste sous `MUSIC_ROOT`** (anti-traversal).

**Exigences fonctionnelles :** FLAC/WAV, HTTP Range, HEAD, `Content-Length`, `Content-Range`, `Accept-Ranges`, 206/404/416, gestion des déconnexions et de la backpressure, corrélation `requestId`, journalisation sans chemin absolu, limite de concurrence (8 flux).

---

## 11–12. Protocole et authentification interne

| Option | Sécurité | Complexité | Verdict |
|---|---|---|---|
| WireGuard seul | Moyenne — toute machine du tunnel accède | Nulle | Insuffisant seul |
| Clé API statique | Moyenne | Très faible | Rejeté (rejouable, fuite dans les logs) |
| **Token HMAC daté** | **Bonne** | **Faible** | ✅ **Retenu** |
| mTLS | Excellente | Élevée (PKI, rotation, renouvellement) | Disproportionné |

**Retenu : WireGuard + HMAC-SHA256 daté.** L'agent vérifie `X-HS-Timestamp` (fenêtre ±60 s) et `X-HS-Signature = HMAC(secret, method + path + timestamp)`, et refuse toute IP hors du sous-réseau WireGuard. Secret dans `HOMESPOTIFY_STORAGE_SHARED_SECRET`, rotation par redémarrage coordonné des deux côtés.

**Défense en profondeur :** écoute uniquement sur l'IP WireGuard du PC (jamais `0.0.0.0`), règle de pare-feu Windows entrante limitée à l'IP WireGuard du VPS, aucun listing de dossier, aucune exécution de commande, aucun chemin absolu dans les réponses ni les journaux.

---

## 13. Gestion HTTP Range

Contrat client **inchangé**. Les événements `STREAM_*` sont **conservés à l'identique** et **complétés** (jamais remplacés) par : `STREAM_CACHE_HIT`, `STREAM_CACHE_MISS`, `STREAM_REMOTE_OPEN`, `STREAM_REMOTE_ERROR`.

Les corrections Android (`useProxyForRequestHeaders: false`, propagation des causes HTTP, récupération 401, refresh single-flight, reconstruction des sources, auto-avance bornée, diagnostic JSON Lines) **ne sont pas impactées** : elles portent sur l'authentification et le transport, pas sur l'origine des octets.

**Q36/Q37/Q38 : aucune modification Flutter n'est nécessaire pour la migration.** L'URL ne change pas. Évolutions *optionnelles* ultérieures : afficher l'état de disponibilité (cache / distant / hors ligne) et transmettre la queue pour le préchargement.

---

## 14. Cache audio VPS

**Politique MVP volontairement simple.**

- **Emplacement :** `/var/lib/homespotify/cache/audio`, permissions `0750`, propriétaire `homespotify`.
- **Nom de fichier :** `<trackId>-<contentHash[0..16]>.<ext>` — le hash dans le nom invalide automatiquement une piste modifiée.
- **Remplissage :** écriture dans `<nom>.part`, `fsync`, puis **`rename` atomique**. Tout `.part` orphelin au démarrage est supprimé ; il n'est jamais servi.
- **Validation :** taille finale comparée à `tracks.size_bytes`. Écart → suppression + `STREAM_CACHE_CORRUPT`.
- **Index :** table SQLite `audio_cache_entries` (`trackId`, `sizeBytes`, `lastAccessAt`, `pinned`) — transactionnel, déjà couvert par les sauvegardes, cohérent avec l'existant. Préféré à un fichier JSON.
- **Seuils :** haut **8 Go** → éviction jusqu'à **6 Go** (bas). Éviction **LRU stricte** sur `lastAccessAt`, en excluant les entrées `pinned` et la piste en cours de lecture.
- **Garde disque :** avant tout remplissage, vérifier **≥ 5 Go libres** sur la partition (`statfs`). En dessous → pas de mise en cache, streaming direct depuis le PC. Dégradation, jamais panne.
- **Single-flight (Q10) :** `Map<trackId, Promise>` en mémoire — deux lectures simultanées de la même piste déclenchent **un seul téléchargement**, les deux clients sont servis.
- **Q9 :** oui. Le premier lecteur reçoit le flux relayé depuis le PC **avec écriture simultanée** dans le `.part` (tee). Aucune attente de remplissage complet.
- **Q25 :** une piste en cours de remplissage est servie depuis le flux distant, pas depuis le `.part` (non encore cohérent).
- **Nettoyage :** au démarrage et toutes les heures.

**Exclu du MVP** (à ajouter après mesure du hit ratio réel) : priorisation par favoris/fréquence, pinning automatique, quotas par utilisateur.

**Ordre de priorité cible (post-MVP) :** piste en cours > pistes suivantes de la queue > favoris > récemment écoutés > récemment ajoutés > fréquemment écoutés.
**Ordre d'éviction :** LRU > non épinglé > disponible sur le PC > hors queue active.

---

## 15. Préchargement de la queue

- Le VPS ne connaît **pas** la queue aujourd'hui → nouvelle route `POST /api/player/prefetch`, corps `{trackIds: number[]}`, **maximum 5**, validé.
- Flutter l'appelle au démarrage d'une piste avec les 2 à 4 suivantes. Shuffle et repeat : Flutter transmet l'ordre **effectif**, le backend ne duplique aucune logique de file.
- **Annulation :** toute nouvelle requête d'un utilisateur annule ses tâches précédentes (`AbortController` par `userId`).
- **Concurrence globale :** 2 préchargements maximum, priorité absolue au streaming actif.
- **Anti-abus :** rate limit par utilisateur, plafond de 5 pistes, isolation par `userId`.
- **Protection du domicile :** le préchargement n'utilise jamais plus d'un tiers du débit montant mesuré (§48).

---

## 16 + 47. Budget disque VPS — 35 Go

Recalculé sur les mesures réelles de la Phase 0. **Les trois lignes de synthèse sont arithmétiquement liées.**

| Poste | Réservation | Base de calcul |
|---|---|---|
| Debian + paquets système | 4,0 Go | à confirmer (§ INFORMATION À RELEVER) |
| Node.js + store pnpm | 1,5 Go | |
| Application + `node_modules` | 1,5 Go | |
| SQLite (base + WAL) | 0,3 Go | mesuré : 3,2 Mo + 2,0 Mo — large marge de croissance |
| Sauvegardes SQLite (7 générations) | 0,5 Go | mesuré : 7 × 3,2 Mo ≈ 23 Mo — large marge |
| Logs (rotation 100 Mo × 7) | 1,0 Go | |
| Cache pochettes | 0,3 Go | mesuré : 16 Mo |
| Staging import temporaire (plafonné) | 2,0 Go | |
| **A — Sous-total hors cache audio** | **11,1 Go** | |
| **B — Cache audio (seuil haut)** | **8,0 Go** | 2,7 × la bibliothèque actuelle |
| **C = A + B — Occupation maximale** | **19,1 Go** | |
| **D = 35 − C — Marge libre garantie** | **15,9 Go** | |

**Vérification :** 11,1 + 8,0 = 19,1 ; 35,0 − 19,1 = 15,9. ✅

**Seuil de désactivation du cache :** si l'espace libre de la partition descend sous **5 Go**, le remplissage du cache s'arrête immédiatement (streaming direct maintenu). Avec 15,9 Go de marge nominale, ce seuil ne peut être atteint que par une anomalie externe (logs emballés, staging non purgé) — il agit comme filet de sécurité, pas comme régime normal.

**Q12/Q13 :** la limite de 8 Go est appliquée par l'index de cache (somme des `sizeBytes`) ; la marge libre est garantie par une vérification `statfs` **avant chaque écriture**, pas par convention.

**Capacité du cache :** 8 Go ÷ 19,1 Mo ≈ **~420 pistes**, soit **2,7 fois la bibliothèque actuelle** (157 pistes). Le cache peut donc contenir l'intégralité de la bibliothèque avec une marge de croissance confortable.

---

## 17. Migration SQLite

**Q14/Q15 : conserver SQLite.** Un seul processus écrivain, base locale sur SSD, WAL activé, 3,2 Mo. PostgreSQL n'apporterait rien et ajouterait un service à maintenir.

| Méthode | Cohérence | Service arrêté ? | Verdict |
|---|---|---|---|
| Copie de fichier à chaud | ❌ WAL/SHM incohérents | non | **Dangereux** |
| `VACUUM INTO` | ✅ | non | Correct, mais reconstruit la base |
| `.backup` via sqlite3 CLI | ✅ | non | Correct, dépend d'un binaire externe |
| **SQLite Backup API** (déjà implémentée) | ✅ | non | ✅ **Retenue** |

**Procédure :**
1. `PRAGMA quick_check` sur la source.
2. Sauvegarde via le script existant (`pnpm --filter @homespotify/api run backup`).
3. `PRAGMA wal_checkpoint(TRUNCATE)` **après arrêt du service** pour la copie finale.
4. Transfert `scp` **sur le tunnel WireGuard**, jamais en clair.
5. Sur le VPS : `PRAGMA quick_check` + `PRAGMA integrity_check` + comparaison des comptages (attendus : 157 tracks, 3 users, 1 playlist, 9 favorites, 443 sessions, 16 requests, 158 user_tracks).
6. Démarrage en lecture seule pour validation, puis lecture-écriture.

**Q18 — écritures concurrentes (point le plus critique du plan) :** un seul backend en écriture à tout instant. La séquence de bascule (§34) arrête le service Windows **avant** la copie finale et ne le redémarre pas. Il n'existe aucune fenêtre où les deux écrivent. En cas de rollback après écritures VPS, **la base VPS devient la référence** et est retransférée vers Windows — jamais l'inverse.

---

## 18. Gestion des chemins Windows — ⚠️ POINT BLOQUANT

**Constat Phase 0 :** 0 chemin absolu, mais **157 chemins sur 157 utilisent le séparateur `\`**.

Exemple de structure : `Artiste\Album\Titre.flac` (longueurs mesurées : 28 à 57 caractères).

**Le problème :** sur Linux, `path.join('/var/music', 'Artiste\\Album\\Titre.flac')` produit `/var/music/Artiste\Album\Titre.flac` — un fichier unique dont le nom contient des backslashes, qui n'existe pas. **Toute lecture échouerait en 404.**

**Solution retenue — normalisation dans le provider, sans toucher aux données :**

```ts
// Dans TrackStorageReference : normalisation systématique à la construction.
const portablePath = row.path.replace(/\\/g, '/');
```

- **Additive** : aucune donnée modifiée, aucune migration de schéma.
- **Bidirectionnelle** : le Storage Agent (Windows) reconvertit `/` → `\` si nécessaire — en pratique inutile, Node accepte `/` sous Windows.
- **Compatible** : les imports futurs sur le PC continuent d'écrire des `\`, sans casse.
- **Rollback trivial** : c'est une ligne de code derrière `AUDIO_STORAGE_MODE`.

**Contrainte de validation :** un nom de fichier légitime contenant un `\` sous Linux serait cassé par cette normalisation. Sous Windows, `\` est un caractère **interdit** dans un nom de fichier — le risque est donc nul pour les données existantes. À revérifier si la bibliothèque est un jour alimentée depuis Linux.

**Test obligatoire en Phase 1 :** vérifier que les 157 chemins normalisés résolvent vers un fichier existant.

---

## 19–20. Déploiement Debian et systemd

**Arborescence recommandée :**
```
/opt/homespotify/app             # code + node_modules
/etc/homespotify/api.env         # 0600 root:homespotify — secrets
/var/lib/homespotify/db/         # SQLite + WAL + SHM
/var/lib/homespotify/cache/audio
/var/lib/homespotify/cache/covers
/var/lib/homespotify/imports/    # staging temporaire borné
/var/log/homespotify/
/var/backups/homespotify/
```

**Prérequis système :** Node.js ≥ 22, pnpm 10.12.1, et **`build-essential` + `python3`** pour la compilation de `better-sqlite3` et `@node-rs/argon2` si aucun binaire précompilé n'est disponible pour l'architecture du VPS.

**Utilisateur :** `homespotify` (`--system --no-create-home --shell /usr/sbin/nologin`).

**Unité systemd (directives clés) :**
```ini
[Service]
User=homespotify
Environment=NODE_ENV=production HOST=127.0.0.1 PORT=3000
EnvironmentFile=/etc/homespotify/api.env
ExecStart=/usr/bin/node /opt/homespotify/app/services/api/dist/server.js
Restart=on-failure
RestartSec=5
TimeoutStopSec=30            # > 20 s du WinSW actuel
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/var/lib/homespotify /var/log/homespotify /var/backups/homespotify
MemoryMax=1G
```

`HOST=127.0.0.1` corrige le `0.0.0.0` actuel : seul Caddy atteint l'API.

---

## 21. Configuration Caddy

```caddy
music.romainbegot.fr {
    encode zstd gzip {
        not path /api/tracks/*/stream /api/tracks/*/download /api/offline/*
    }
    reverse_proxy 127.0.0.1:3000 {
        flush_interval -1
        transport http { read_timeout 0 write_timeout 0 }
        header_up X-Request-Id {http.request.uuid}
    }
    request_body { max_size 512MB }
    log { output file /var/log/caddy/homespotify.log }
}
```

**Points critiques :** compression **désactivée sur l'audio** (FLAC déjà compressé ; la compression casserait le Range), `flush_interval -1` obligatoire pour le streaming, timeouts désactivés pour les flux longs.
**Rollback :** une seule ligne — `reverse_proxy <IP_WG_PC>:3000`.

---

## 22–24. WireGuard et pare-feu

**INFORMATION À RELEVER** (aucune configuration versionnée) : adresses du tunnel, `AllowedIPs`, `PersistentKeepalive`, port UDP d'écoute, clés publiques.

**Recommandations :** `PersistentKeepalive = 25` côté PC (NAT domestique), `AllowedIPs` réduit au strict `/32` de part et d'autre.

**Pare-feu VPS :** entrant 80/443 public, 22 restreint, port WireGuard UDP public ; tout le reste fermé. Le port 3000 n'est jamais joignable de l'extérieur (`HOST=127.0.0.1` + règle).

**Pare-feu Windows :** règle entrante pour le port de l'agent **limitée à l'IP WireGuard du VPS**, profil privé uniquement. Aucune règle SMB, aucune redirection de port sur la box.

**Interdits explicites :** aucun partage SMB exposé, aucun port de stockage ouvert sur l'IP publique du domicile.

---

## 25. Sauvegardes

- **SQLite :** quotidienne (`BACKUP_ENABLED` existe déjà), rotation 7 générations, SHA-256 de chaque archive, `PRAGMA quick_check` **après** sauvegarde.
- **Configuration :** `/etc/homespotify/`, unité systemd, `Caddyfile`, `wg0.conf` → archive chiffrée hebdomadaire (`age` ou `gpg`), stockée **hors VPS**.
- **Bibliothèque PC :** conserve la sauvegarde locale existante (`scripts/backup_homespotify.ps1`).
- **Cache audio :** **non sauvegardé** — reconstructible par définition.
- **Restauration testée trimestriellement** sur une base jetable. Une sauvegarde jamais restaurée n'est pas une sauvegarde.

---

## 26. Supervision

Pas de Prometheus/Grafana pour un usage personnel. **Retenu :** Uptime Kuma (déjà envisagé dans `TECH_DECISIONS.md:207`) + trois tâches cron.

| Contrôle | Fréquence | Seuil d'alerte |
|---|---|---|
| `GET /health` | 1 min | 2 échecs consécutifs |
| Disque libre VPS | 15 min | < 6 Go |
| Taille du cache audio | 1 h | > 8,5 Go |
| Storage Agent `/health` | 5 min | 3 échecs |
| Handshake WireGuard | 5 min | > 5 min sans handshake |
| Expiration du certificat | 1 j | < 15 j |
| Sauvegarde du jour | 1 j | absente ou `quick_check` KO |

**Côté PC :** Storage Agent actif, WireGuard actif, stockage accessible, espace disque, temps d'ouverture des fichiers, débit vers le VPS, watcher actif, erreurs d'import.

---

## 27. Sécurité

- Utilisateur Linux non root, droits minimaux, durcissement systemd (§20).
- Secrets dans `/etc/homespotify/api.env` (0600), **jamais dans Git**, jamais journalisés.
- Pare-feu des deux côtés (§22-24).
- `fail2ban` seulement si les journaux Caddy montrent des tentatives réelles — pas par défaut.
- Rate limiting sur `/api/player/prefetch` et l'authentification.
- Storage Agent : HMAC daté, validation stricte du `trackId`, protection anti-traversal, aucune URL arbitraire (protection SSRF), limites de taille et timeouts.
- Nettoyage des fichiers temporaires (`.part`) au démarrage.
- Rotation des secrets documentée (`scripts/rotate_auth_secret.ps1` existe déjà pour `AUTH_TOKEN_SECRET`).
- Isolation des utilisateurs préservée (`user_tracks`).

---

## 28. Imports

| Option | Disque VPS | Robustesse | Verdict |
|---|---|---|---|
| Stockage temporaire complet sur VPS | ❌ lourd | Moyenne | Rejeté (35 Go) |
| Métadonnées extraites sur VPS | ❌ fichier requis | Faible | Rejeté |
| **Relais en flux vers le PC** | ✅ quasi nul | Bonne | ✅ **Retenu** |
| Traitement intégral sur PC | ✅ | Bonne | ✅ conservé |

**Recommandation :** le VPS **relaie le flux d'upload** vers le PC sans jamais écrire le fichier complet ; le PC valide, hashe, déduplique, range et notifie le VPS qui met à jour la base. Le pipeline actuel (`UserImportService`, watcher, `hashFile`, déduplication par `tracks.hash`) **reste intact sur le PC** — c'est ce qui rend cette option la moins risquée.

L'acquisition Lucida reste **entièrement sur le PC** (Python + Playwright + Chromium).

---

## 29. Comportement lorsque le PC est hors ligne

**Q20/Q21/Q23 : cinq états distincts, jamais confondus.**

| État | Code HTTP | Signification |
|---|---|---|
| En cache | 200 / 206 | Servi immédiatement |
| Distant disponible | 200 / 206 | Relayé depuis le PC |
| **Stockage hors ligne** | **503** + `Retry-After` | PC injoignable — **jamais 404** |
| Fichier réellement absent | 404 | Confirmé par un agent joignable |
| Erreur technique | 500 | |

Le retour du PC est détecté par le `healthCheck` périodique (30 s), sans action manuelle. Un cache de l'état de santé évite de sonder à chaque requête.

**Fonctionnel hors ligne :** connexion, bibliothèque, artistes, albums, playlists, favoris, historique, recherche de métadonnées, Discovery, administration, **et toute piste présente dans le cache**.
**Temporairement indisponible :** piste absente du cache, import, validation de fichier, acquisition.

---

## 30–33. Plan en phases

| # | Phase | Effort | Interruption | Dépend de |
|---|---|---|---|---|
| 0 | Inventaire et mesures | 0,5 j | 0 | — |
| 1 | Abstraction de stockage + normalisation des chemins | 1 j | 0 | 0 |
| 2 | Storage Agent Windows | 1,5 j | 0 | 1 |
| 3 | Tests Storage Agent via WireGuard | 0,5 j | 0 | 2 |
| 4 | `RemoteWindowsStorageProvider` | 0,5 j | 0 | 3 |
| 5 | Cache audio VPS | 1 j | 0 | 4 |
| 6 | Préparation Debian + systemd | 0,5 j | 0 | — |
| 7 | Copie test de la base SQLite | 0,5 j | 0 | 6 |
| 8 | Backend VPS sur port de test | 0,5 j | 0 | 7 |
| 9 | Tests de bout en bout sans bascule | 0,5 j | 0 | 8 |
| 10 | **Bascule Caddy** | 0,5 j | **5–15 min** | 9 |
| 11 | Validation mobile | 0,5 j | 0 | 10 |
| 12 | Soak test ≥ 2 h | 0,5 j | 0 | 11 |
| 13 | Désactivation de l'ancien backend | 0,5 j | 0 | 12 (+7 j d'observation) |
| 14 | Sauvegardes et supervision permanentes | 0,5 j | 0 | 13 |

**Q40 — chemin critique : 1 → 2 → 3 → 4 → 5 → 9 → 10.** Les phases 6 et 7 se mènent en parallèle du chemin critique.

**Critères d'acceptation transverses (toutes phases) :** suite backend verte (382 tests au 2026-07-25), suite Flutter verte (513), `flutter analyze` sans nouvelle erreur, aucun secret en clair, rollback documenté **et testé**.

---

## 34. Plan de bascule

**Fenêtre : 5 à 15 minutes.**

1. Choisir une heure creuse (usage personnel).
2. `Stop-Service HomeSpotifyApi` → **plus aucune écriture Windows**.
3. `PRAGMA wal_checkpoint(TRUNCATE)` + sauvegarde finale + SHA-256.
4. Transfert via WireGuard, vérification du SHA-256 à l'arrivée.
5. `quick_check` + comparaison des comptages sur le VPS.
6. `systemctl start homespotify-api`, vérifier `/health`.
7. Basculer `reverse_proxy` dans le Caddyfile → `caddy reload` (sans coupure).
8. Tests : connexion, bibliothèque, streaming cache hit, streaming cache miss, Range et seek, playlist, historique, import.
9. Surveillance rapprochée pendant 2 h.

---

## 35. Plan de rollback

**Objectif : moins de 5 minutes.**

1. `reverse_proxy` → IP WireGuard du PC, `caddy reload`.
2. `systemctl stop homespotify-api`.
3. `Start-Service HomeSpotifyApi`.
4. **Si des écritures ont eu lieu sur le VPS :** la base VPS fait foi, la retransférer vers le PC **avant** redémarrage. Sinon, divergence garantie.

Le service Windows n'est **désinstallé qu'en Phase 13**, après 7 jours d'observation.

**Réconciliation des écritures :** en cas de rollback tardif, les tables à réconcilier en priorité sont `listening_sessions`, `favorites`, `playlists`, `music_requests` — celles qui reçoivent des écritures utilisateur. La procédure est un remplacement complet par la base VPS, pas une fusion ligne à ligne.

---

## 36. Matrice de risques

| Risque | Probabilité | Impact | Détection | Prévention | Récupération |
|---|---|---|---|---|---|
| **Séparateurs `\` non normalisés** | **Certaine sans action** | **Critique** | Test Phase 1 (157 résolutions) | Normalisation dans le provider (§18) | `AUDIO_STORAGE_MODE=local` |
| Divergence des bases | Faible | **Critique** | Comptages divergents | Un seul écrivain, service arrêté avant copie | Base VPS = référence |
| Corruption SQLite | Très faible | **Critique** | `quick_check` | Backup API, jamais de copie à chaud | Restaurer la dernière génération saine |
| Disque VPS plein | Faible | Élevé | Alerte < 6 Go | Garde `statfs`, seuils 6/8 Go | Purge du cache (reconstructible) |
| PC hors ligne | **Élevée** | Moyen | `healthCheck` 30 s | Cache + 503 explicite | Automatique au retour |
| Débit domicile insuffisant | Moyenne | Élevé | Temps au premier octet | Préchargement, cache chaud | Élargir le cache |
| Secret agent compromis | Faible | Élevé | Journal d'audit | HMAC daté + WireGuard + pare-feu | Rotation + redémarrage |
| Range mal retransmis | Moyenne | Élevé | Tests 206/416 Phase 3 | Tests dédiés | `AUDIO_STORAGE_MODE=local` |
| Timeouts Caddy sur flux longs | Moyenne | Moyen | Coupures à durée fixe | `flush_interval -1`, timeouts 0 | Ajuster et recharger |
| Compilation native échouée (Debian) | Moyenne | Élevé | Échec `pnpm install` | `build-essential` + `python3` préinstallés | Binaires précompilés |
| Antivirus Windows sur l'agent | Moyenne | Moyen | Latence d'ouverture | Exclusion du dossier musique | Exclusion + redémarrage |
| Fichier `.part` après crash | Moyenne | Faible | Scan au démarrage | Rename atomique | Suppression automatique |
| WireGuard interrompu | Moyenne | Moyen | Handshake > 5 min | `PersistentKeepalive = 25` | Reconnexion automatique |
| Mise à jour Debian cassante | Faible | Moyen | Échec au redémarrage | `unattended-upgrades` limité à la sécurité | Snapshot VPS |
| Sauvegarde inutilisable | Faible | **Critique** | `quick_check` après backup | Test de restauration trimestriel | Génération antérieure |
| Perte du VPS | Très faible | Élevé | Supervision | Sauvegardes hors site | Réinstallation + restauration |
| Perte du PC | Très faible | **Critique** | Supervision | Sauvegarde locale de la bibliothèque | Restauration des fichiers |
| Changement d'IP publique domicile | Moyenne | Faible | Handshake perdu | VPS = point fixe, PC initie le tunnel | Automatique |
| Certificat expiré | Très faible | Élevé | Alerte < 15 j | Caddy renouvelle seul | `caddy reload` |
| Migration partiellement terminée | Faible | Moyen | Checklist Go/No-Go | Phases indépendantes et réversibles | Rollback de la phase |

---

## 37–38. Estimations

- **Effort total :** 5 à 8 jours-homme, étalés sur 3 à 4 semaines.
- **Indisponibilité totale : 5 à 15 minutes**, une seule fois (Phase 10).
- Toutes les autres phases se déroulent **sans interruption** : le backend Windows reste en production jusqu'à la Phase 10.

---

## 39. Ordre exact d'exécution

```
0 → 1 → 2 → 3 → 4 → 5 → 9 → 10 → 11 → 12 → 13 → 14
         ↑
      6 → 7 → 8  (en parallèle, rejoignent avant 9)
```

---

## 41–46. Éléments techniques

**Nouveaux fichiers :**
`services/api/src/storage/audio-storage.ts`, `local-file-storage.ts`, `remote-windows-storage.ts`, `cached-audio-storage.ts`, `cache-index.ts`, `prefetch-service.ts` ; `services/storage-agent/**` ; `infra/systemd/homespotify-api.service` ; `infra/caddy/Caddyfile` ; `infra/wireguard/*.example` ; `scripts/vps_phase0_inventory.sh` (créé en Phase 0).

**Fichiers existants concernés :**
`services/api/src/routes/tracks.ts` (signature `serveTrackFile`), `routes/offline.ts` (indirect), `app.ts` (câblage), `config.ts` (variables), `db/schema.ts` (table `audio_cache_entries`), `db/migrate.ts` (+1 migration additive).

**Variables d'environnement à ajouter :**
`AUDIO_STORAGE_MODE`, `STORAGE_AGENT_BASE_URL`, `HOMESPOTIFY_STORAGE_SHARED_SECRET`, `STORAGE_AGENT_TIMEOUT_MS`, `AUDIO_CACHE_DIR`, `AUDIO_CACHE_MAX_BYTES`, `AUDIO_CACHE_LOW_WATERMARK_BYTES`, `AUDIO_CACHE_MIN_FREE_BYTES`, `PREFETCH_MAX_TRACKS`, `PREFETCH_MAX_CONCURRENCY`.

**Ports :**
443 (Caddy, public) · 3000 (Fastify, **127.0.0.1 uniquement**) · 3100 (Storage Agent, **IP WireGuard uniquement**, proposé) · WireGuard UDP (à relever).

---

## 48. Mesures de performance avant / après

À relever **avant** la bascule (référence) puis **après** :

latence `/health` · latence d'authentification · latence de recherche · temps d'affichage de la bibliothèque · temps de démarrage d'une piste en cache miss · en cache hit · gap entre deux pistes · débit PC → VPS · débit VPS → téléphone · cache hit ratio · cache miss ratio · temps au premier octet · temps d'ouverture du fichier · CPU · RAM · espace disque · nombre de flux simultanés.

**Aucune amélioration ne sera annoncée sans mesure comparative.**

---

## 49. Tests téléphone finaux

Connexion · recherche · lecture · passage automatique · écran verrouillé · token expiré · Wi-Fi · 5G · bascule Wi-Fi ↔ 5G · seek · playlist · piste en cache · piste hors cache · PC hors ligne · retour du PC.

**Soak test :** ≥ 2 h, plusieurs pistes, plusieurs expirations de token, aucune coupure silencieuse, aucune corruption, aucun remplissage incontrôlé du disque.

---

## 50. Checklist Go / No-Go (avant bascule)

- [ ] Sauvegarde SQLite du jour vérifiée (`quick_check` + SHA-256)
- [ ] **157/157 chemins normalisés résolvent vers un fichier existant**
- [ ] Suites de tests vertes (382 backend / 513 Flutter)
- [ ] Storage Agent : 206, 416, 404, HEAD, déconnexion client — tous validés
- [ ] Cache : hit, miss, concurrence, `.part`, LRU, disque plein — tous validés
- [ ] WireGuard stable ≥ 24 h sans perte de handshake
- [ ] `/health` VPS vert sur port de test
- [ ] Rollback Caddy **testé** (aller-retour effectué au moins une fois)
- [ ] Espace libre VPS ≥ 8 Go
- [ ] Débit montant du domicile mesuré et documenté
- [ ] Fenêtre de bascule confirmée
- [ ] Ancien backend Windows prêt à redémarrer

**No-Go si :** un seul test Range échoue · débit domicile non mesuré · sauvegarde jamais restaurée · rollback non testé · normalisation des chemins non validée sur les 157 pistes.
