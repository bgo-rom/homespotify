# Phase 1 — Abstraction du stockage audio (provider local)

**Date :** 2026-07-25 · **Statut :** TERMINÉE
**Plan de référence :** [VPS_HYBRID_MIGRATION_PLAN.md](VPS_HYBRID_MIGRATION_PLAN.md) · **Inventaire :** [VPS_PHASE0_INVENTORY.md](VPS_PHASE0_INVENTORY.md)

> Cette phase prépare l'architecture distante **sans changer le comportement de
> production**. Aucun service redémarré, aucun déploiement, aucune écriture en
> base, aucun commit.

---

## 1. Abstraction introduite

Le backend ne connaît plus la localisation physique des fichiers audio. Il
manipule une **référence portable** et demande des informations ou un flux à un
**provider**.

```
Route HTTP  ──▶  serveTrackFile  ──▶  AudioStorageProvider
(statuts,        (Range, en-têtes,     (stat / createReadStream /
 auth)            diagnostics)          healthCheck)
                                              │
                                    LocalFileStorageProvider   ← seule impl.
```

**Séparation des responsabilités, volontairement stricte :**

| Couche | Responsabilité | Ce qu'elle ignore |
|---|---|---|
| Route | Authentification, accès utilisateur, choix du provider | Le disque |
| `serveTrackFile` | Parsing Range, statuts 200/206/416, en-têtes, diagnostics `STREAM_*` | L'origine des octets |
| Provider | Résolution de chemin, confinement, `stat`, flux | HTTP |

Le parsing du Range **n'a pas été déplacé** dans le provider : il reste dans la
couche HTTP, à laquelle il appartient. Le provider reçoit une plage d'octets
déjà validée.

## 2. Fichiers créés

| Fichier | Rôle |
|---|---|
| `services/api/src/storage/audio-storage.ts` | Types, interface, erreurs, **normalisation des chemins** |
| `services/api/src/storage/local-file-storage.ts` | `LocalFileStorageProvider` |
| `services/api/src/storage/provider-factory.ts` | Modes, validation, fabrique |
| `services/api/src/storage/audio-storage.test.ts` | 37 tests |
| `services/api/src/scripts/verify-track-paths-cli.ts` | Vérification lecture seule des chemins réels |
| `docs/VPS_PHASE1_STORAGE_ABSTRACTION.md` | Ce document |

## 3. Fichiers modifiés

| Fichier | Modification |
|---|---|
| `services/api/src/routes/tracks.ts` | Signature de `serveTrackFile` : `absPath: string` + `hash` → `provider` + `reference` ; `stat` et `createReadStream` délégués |
| `services/api/src/routes/offline.ts` | Utilise `app.offlineVariantStorage` avec une référence portable |
| `services/api/src/app.ts` | Décorateurs `audioStorage` et `offlineVariantStorage` |
| `services/api/src/config.ts` | Champ `audioStorageMode` (optionnel) + lecture de `AUDIO_STORAGE_MODE` |
| `services/api/package.json` | Script `verify:paths` |

## 4. Types

```ts
interface TrackStorageReference {
  trackId: number;        // diagnostics STREAM_*
  relativePath: string;   // portable, séparateur `/`, relatif à la racine
  contentHash: string;    // SHA-256 : ETag aujourd'hui, clé de cache en Phase 5
}

interface ByteRange { start: number; end: number }   // inclusif, comme HTTP

interface AudioFileInfo {
  sizeBytes: number;
  modifiedAt: Date;
  source: 'local' | 'cache' | 'remote';
}

type StorageHealth =
  | { status: 'online'; source: 'local' | 'cache' | 'remote'; latencyMs: number }
  | { status: 'offline'; reason: string }
  | { status: 'degraded'; reason: string };

interface AudioStorageProvider {
  stat(reference: TrackStorageReference): Promise<AudioFileInfo>;
  createReadStream(reference: TrackStorageReference, range?: ByteRange): Promise<Readable>;
  healthCheck(): Promise<StorageHealth>;
}
```

`AudioStorageError` porte un code métier (`NOT_FOUND`, `PATH_TRAVERSAL`,
`STORAGE_OFFLINE`…) **distinct des codes HTTP**. C'est ce qui permettra, en
Phase 4, de traduire `STORAGE_OFFLINE` en **503** au lieu d'un 404 trompeur.

## 5. Normalisation des chemins

**Problème traité :** les 158 chemins de la base utilisent le séparateur `\`.
Sous Linux, `\` n'est pas un séparateur — il ferait partie du nom de fichier et
**toutes les lectures échoueraient**.

**Solution :** fonction pure `toPortableRelativePath`, appelée à la construction
de chaque référence. **Aucune donnée n'est modifiée en base.**

| Entrée | Sortie |
|---|---|
| `Artiste\Album\Piste.flac` | `Artiste/Album/Piste.flac` |
| `Artiste/Album/Piste.flac` | inchangé |
| `Artiste\Album/Piste.flac` (mixte) | `Artiste/Album/Piste.flac` |
| `Artiste\\Album//Piste.flac` | `Artiste/Album/Piste.flac` |
| `Artiste\.\Album\Piste.flac` | `Artiste/Album/Piste.flac` |
| Accents, apostrophes, Unicode, espaces | préservés à l'identique |

**Rejets — aucune réparation silencieuse :**

| Entrée | Code d'erreur |
|---|---|
| `../secret`, `..\secret` | `PATH_TRAVERSAL` |
| `C:\Music\x.flac`, `f:/x.flac` | `INVALID_REFERENCE` |
| `/etc/passwd` | `INVALID_REFERENCE` |
| `\\serveur\partage\x` (UNC) | `INVALID_REFERENCE` |
| `\Artiste\x` (commence par séparateur) | `INVALID_REFERENCE` |
| `""`, `"   "`, `.`, `.\.\.`  | `INVALID_REFERENCE` |

**Pourquoi la normalisation plutôt qu'un `UPDATE` en base :** additive, le
backend Windows actuel continue de fonctionner sur la même base (donc le
rollback marche), les imports futurs peuvent continuer d'écrire des `\` sans
casse, et `\` est un caractère interdit dans un nom de fichier NTFS — aucun nom
légitime ne peut être corrompu par la substitution.

## 6. Protection anti-traversal — deux barrières

**Barrière 1 — à la construction de la référence.** `toPortableRelativePath`
rejette `..`, les chemins absolus et UNC **avant toute résolution**.

**Barrière 2 — à la résolution.** `LocalFileStorageProvider.resolvePath` vérifie
que le chemin résolu est bien sous la racine :

```ts
if (candidate === this.root) throw …            // désigne le dossier, pas un fichier
if (!candidate.startsWith(this.root + sep)) throw …   // sort de la racine
```

La comparaison **inclut le séparateur** : une racine sœur nommée
`<root>-autre` commence par `<root>` sans être dedans, et est correctement
rejetée. Un test dédié couvre ce cas.

La seconde barrière intercepte ce que la première ne peut pas voir : toute
référence fabriquée sans passer par le constructeur normal. C'est la garantie
qui survivra à l'ajout du provider distant.

## 7. Configuration — `AUDIO_STORAGE_MODE`

| Valeur | Comportement |
|---|---|
| absente | `local` — **comportement identique à aujourd'hui** |
| `local` | Système de fichiers local ✅ implémenté |
| `remote` | **Échec explicite** au démarrage : « n'est pas implémenté (Phase 4) » |
| `cached` | **Échec explicite** au démarrage : « n'est pas implémenté (Phase 5) » |
| inconnue | **Échec explicite** : `Config invalide : AUDIO_STORAGE_MODE="…"` |

Aucun repli silencieux : une faute de frappe (`locale`, `LOCAL`) fait échouer le
démarrage plutôt que de laisser croire à un mode distant actif.

Le champ `audioStorageMode` d'`AppConfig` est **optionnel** : un `AppConfig`
construit programmatiquement (tests, outils) reste valide et reçoit `local`.

## 8. Intégration dans le streaming

**Avant :**
```ts
serveTrackFile(request, reply, track.id, join(config.musicDir, track.path), track.hash, contentType)
```

**Après :**
```ts
serveTrackFile(request, reply, app.audioStorage, trackStorageReference(track), contentType)
```

Trois appelants adaptés : `/api/tracks/:id/stream`, `/api/tracks/:id/download`,
`/api/tracks/:id/offline-variants/:profile/file`.

**Deux racines, deux providers.** La bibliothèque (`musicDir`) passera au distant
en Phase 4 ; les dérivées hors ligne (`derivedCacheDir`) sont régénérables et
**resteront toujours locales** — elles ne transiteront jamais par le Storage
Agent. D'où `app.audioStorage` et `app.offlineVariantStorage`.

## 9. Comportement HTTP — inchangé

| Élément | Avant | Après |
|---|---|---|
| 200 complet | ✅ | ✅ identique |
| 206 partiel | ✅ | ✅ identique |
| 416 + `content-range: bytes */size` | ✅ | ✅ identique |
| `bytes=N-` | ✅ | ✅ identique |
| `bytes=-N` (suffixe) | ✅ | ✅ identique |
| Range invalide → 200 | ✅ | ✅ identique |
| `accept-ranges`, `content-length`, `content-range` | ✅ | ✅ identique |
| `etag` (hash), `last-modified` | ✅ | ✅ identique |
| `content-type`, `content-disposition` | ✅ | ✅ identique |
| `x-request-id` | ✅ | ✅ identique |
| Abandon client, backpressure | ✅ | ✅ identique |
| Événements `STREAM_*` | ✅ | ✅ **identiques**, aucun ajout ni retrait |

Aucun changement de contrat HTTP, d'URL ou de JSON. **Aucune modification
Flutter n'a été nécessaire.**

## 10. Vérification des chemins réels

```bash
pnpm --filter @homespotify/api run verify:paths
```

Résultat au 2026-07-25 :

```
158 chemins inspectés
158 fichiers résolus
0 chemin(s) invalide(s) ou absolu(s)
0 tentative(s) de traversal
0 fichier(s) manquant(s)
158 chemin(s) au format Windows (séparateur \)
```

**Écart assumé avec l'attendu de 157 :** la Phase 0 comptait 157 pistes. La
piste #158 a été créée le 2026-07-25 à 16:01:02, soit exactement l'horodatage du
fichier WAL relevé pendant l'inventaire. Un import a eu lieu entre les deux
mesures. La bibliothèque est vivante ; ce n'est pas une anomalie.

L'outil ouvre la base en `readonly` + `fileMustExist`, n'ouvre aucun fichier
audio (`stat` uniquement) et n'affiche **aucun chemin complet** — seulement des
compteurs, et pour une anomalie l'identifiant de piste et le motif.

## 11. Tests

| Suite | Résultat |
|---|---|
| `src/storage/audio-storage.test.ts` (nouveau) | **37/37** |
| Suite backend complète | **419/419** (39 fichiers → 40) |
| Baseline avant Phase 1 | 382/382 |
| Typecheck | ✅ |
| Build | ✅ |

Couverture des 37 nouveaux tests : normalisation (17 cas dont Unicode, accents,
apostrophes, UNC, absolus, traversal, vides), `LocalFileStorageProvider` (stat,
plage, flux complet, fermeture, erreur disque, health), anti-traversal (4 cas
dont le préfixe trompeur), modes de configuration (défaut, valides, inconnus,
non implémentés).

Les tests de streaming existants (200, 206, 416, `bytes=N-`, `bytes=-N`, Range
invalide, requestId, FLAC, download) passent **inchangés** — c'est la preuve
que le contrat HTTP est préservé. **Aucun test n'a été supprimé ni neutralisé.**

## 12. Rollback

Trois niveaux, du plus léger au plus lourd :

1. **Configuration** — `AUDIO_STORAGE_MODE` absente ou `local` : c'est déjà le
   défaut, le comportement est celui d'avant la phase.
2. **Code** — les fichiers modifiés sont identifiés au §3 ; aucun n'a de
   dépendance croisée avec les travaux Lucida en cours.
3. **Données** — **aucun rollback nécessaire** : la base n'a pas été touchée.

## 13. Limites

- Un seul provider existe. `remote` et `cached` échouent volontairement.
- `healthCheck()` n'est encore exposé par aucune route ; il est prêt pour la
  Phase 4.
- `AudioFileInfo.source` vaut toujours `'local'`.
- La normalisation suppose que `\` n'apparaît jamais dans un nom de fichier
  légitime — vrai sous Windows (caractère interdit), **à revérifier** si la
  bibliothèque est un jour alimentée depuis Linux.
- Le comportement HEAD n'a pas été vérifié en conditions réelles (relevé
  Windows toujours attendu, cf. Phase 0).

## 14. Prérequis Phase 2 — Storage Agent Windows

- [ ] **Rapport Windows** : règles de pare-feu sur le port 3000, comportement
      HEAD, empreinte mémoire
- [x] Interface `AudioStorageProvider` stabilisée
- [x] Références portables validées sur les données réelles
- [x] Protection anti-traversal testée
- [ ] Secret partagé `HOMESPOTIFY_STORAGE_SHARED_SECRET` à générer (≥ 32 octets)
- [ ] Port de l'agent à réserver : **3100** sur `10.8.0.2`
- [ ] Règle de pare-feu Windows entrante limitée à `10.8.0.1`

Le contrat de la Phase 2 est déjà fixé par l'interface : l'agent devra exposer
l'équivalent HTTP de `stat`, `createReadStream(range)` et `healthCheck`.
