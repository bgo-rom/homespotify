# Phase 5 — Cache audio VPS

- **Date :** 2026-07-26, qualification réelle close le 2026-07-27
- **État :** **GO FINAL — PHASE 5 VALIDÉE SUR ENVIRONNEMENT RÉEL**

Validation menée depuis une API parallèle liée à `127.0.0.1:3001` sur le VPS,
sur trois racines de cache isolées, avec `failedChecks=[]` et `ok=true` pour
chaque scénario.

La production reste sur HomeSpotifyApi Windows avec `AUDIO_STORAGE_MODE`
absent/local. Aucun changement Caddy, WireGuard, pare-feu, Flutter ou SQLite de
production n'appartient à cette phase. Ce GO ne vaut aucune bascule : il
qualifie le cache, pas un déploiement.

## 1. Checkpoint

Avant le code, un checkpoint hors dépôt
`phase45-checkpoint-20260726-223100` a été créé :

- HEAD `c1384cf3149d1248cb4df6fe2f0422589a5410e2` ;
- état, diff stat et `git diff --check` ;
- patch binaire réversible du working tree suivi ;
- inventaire de 494 fichiers non suivis ;
- copie sélective de 49 sources, scripts et documents Phase 1–4.5 ;
- 57 entrées dans le manifeste, zéro hash invalide ;
- zéro correspondance de clé privée, Bearer ou clé SSH ;
- SHA-256 du manifeste :
  `585ED6F57B35702D8FE694A8CF5DBDD781F0A8D576AF04B0895EBD1DE7545E88`.

Aucun `.env`, secret, SQLite, audio, `node_modules`, log ou diagnostic n'a été
copié.

## 2. Architecture

```text
route HTTP /stream
→ CachedAudioStorageProvider
  → HIT : objet immuable sur disque VPS
  → MISS/BYPASS : RemoteWindowsStorageProvider
    → Storage Agent Windows
```

`offlineVariantStorage` reste un `LocalFileStorageProvider` indépendant.

La factory conserve :

- valeur absente ou `local` → local ;
- `remote` → distant ;
- `cached` → cache décorant le distant ;
- valeur inconnue ou configuration incomplète → échec explicite.

## 3. Identité et structure disque

L'audit de `import-service.ts` confirme que `tracks.hash` est le SHA-256 brut
du fichier, calculé par pipeline de streaming. Il sert donc de clé de version,
de nom d'objet et de contrôle avant promotion.

```text
<AUDIO_CACHE_ROOT>/
├── objects/<2 premiers caractères>/<sha256>.audio
├── tmp/<sha256>.<uuid>.part
└── metadata/cache-index.sqlite
```

Un objet n'est servable que si l'index le marque complet, si son hash demandé
correspond à sa clé et si sa taille disque correspond à l'index. Un `.part`
n'est jamais lu.

L'index SQLite est distinct de la base applicative, en WAL avec
`synchronous=FULL`. Il stocke trackId, contentHash, taille, Content-Type,
Last-Modified, création et dernier accès. La base HomeSpotify ne reçoit aucune
métadonnée de cache.

## 4. Configuration

Variables obligatoires uniquement en mode `cached` :

- `AUDIO_CACHE_ROOT`, absolue et différente du dossier applicatif ;
- `AUDIO_CACHE_MAX_BYTES` ;
- `AUDIO_CACHE_MIN_FREE_BYTES` ;
- `AUDIO_CACHE_TEMP_MAX_AGE_MS` ;
- `AUDIO_CACHE_FILL_ON_FULL_GET` ;
- `AUDIO_CACHE_VERIFY_ON_HIT=size` ;
- `AUDIO_CACHE_EVICTION_TARGET_RATIO`, entre 0,5 inclus et 1 exclu.

Le mode cached exige aussi toute la configuration `AUDIO_REMOTE_*`. Aucun
fallback local silencieux n'existe.

## 5. Remplissage et streaming

- HEAD MISS : stat distant, aucun remplissage.
- Range MISS : flux distant, aucun remplissage implicite.
- GET complet MISS : stat distant puis tee vers le client et un `.part`.
- HIT complet ou Range : lecture disque VPS.
- abandon client : destruction immédiate de l'amont et suppression du `.part`.
- écriture disque impossible : cache abandonné, flux distant maintenu.
- taille ou SHA-256 divergent : aucune promotion.
- succès : taille et SHA-256 validés, `fsync`, fermeture puis renommage
  atomique vers l'objet final.

Le Transform n'accepte le chunk suivant qu'après l'écriture disque du chunk
courant. La backpressure dépend donc du plus lent entre client et disque,
sans Buffer de piste complète.

## 6. Concurrence

Un verrou mémoire par contentHash impose un seul remplissage. Une requête
concurrente contourne le cache et ouvre un flux distant indépendant : elle
n'attend jamais et ne lit jamais le `.part`. Le verrou est libéré sur succès,
erreur, abandon et arrêt.

## 7. Éviction et réparation

LRU sur `last_access_ms`, déclenché avant remplissage si la limite logique ou
l'espace libre minimal serait dépassé. Les entrées lues et les remplissages
actifs sont protégés. L'éviction vise le ratio configuré. Si elle ne libère pas
assez, la lecture distante continue sans cache.

Au démarrage :

- `.part` anciens supprimés ;
- lignes sans objet ou avec taille incorrecte supprimées ;
- objets sans index supprimés ;
- aucun parcours de la bibliothèque Windows.

## 8. Observabilité et santé

Événements sûrs : `CACHE_HIT`, `CACHE_MISS`, `CACHE_BYPASS`,
`CACHE_FILL_STARTED`, `CACHE_FILL_COMPLETED`, `CACHE_FILL_ABORTED`,
`CACHE_FILL_FAILED`, `CACHE_CORRUPT_ENTRY`, `CACHE_EVICTION_STARTED`,
`CACHE_EVICTED`, `CACHE_DISK_PRESSURE`.

Ils n'incluent que requestId, trackId, préfixe de hash, bornes, tailles,
durées et raisons typées. Aucun secret, chemin musical, nom de fichier,
Authorization, nonce, signature ou audio.

Le provider expose en interne compteurs HIT/MISS/fill/éviction/corruption,
occupation, limite, espace libre et temporaires. Son `healthCheck` vérifie la
racine et l'index sans exposer le chemin dans `/health`.

## 9. Tests locaux

- Cache, stockage local, remote et câblage ciblés : **68/68**.
- Suite API complète : **503/503**, 47 fichiers.
- Storage Agent : **148/148**.
- Harnais Phase 5 (sélection, preuves, journaux, isolation) : **107/107**.
- Typechecks API et Storage Agent : verts.
- Builds API et Storage Agent : verts.
- `git diff --check` : vert, hors avertissements CRLF préexistants.
- Aucun test supprimé, ignoré ou neutralisé.

Scénarios cache : configuration, HIT/MISS, HEAD/Range offline, promotion
atomique, SHA-256 divergent, abandon, corruption, single-flight, pression
disque, LRU, redémarrage et nettoyage des orphelins.

## 10. Validation VPS réelle — GO final (2026-07-27)

Exécutée depuis le PowerShell administrateur détenant l'accès SSH, sans
`npm install`, en réutilisant les dépendances et la copie SQLite isolée de la
Phase 4.5, avec le `dist` transféré et une API parallèle liée à
`127.0.0.1:3001`.

```powershell
Set-Location F:\dev\homespotify
.\scripts\run_phase5_cache_integration.ps1
```

Modes ciblés disponibles pour itérer sans rejouer la séquence complète :
`-FinalizeOnly`, `-AbortOnly`, `-OfflineOnly`.

### 10.1 Trois caches isolés

Chaque scénario dispose de **sa** racine et de **sa** capacité. C'est la
correction structurante de cette phase : une limite unique, calibrée pour
garantir l'éviction, détruisait la précondition des autres scénarios (§12.5).

| Scénario | Racine de cache | `AUDIO_CACHE_MAX_BYTES` | Éviction |
| --- | --- | --- | --- |
| `finalize-offline` | `runtime/cache-finalize-offline` | `(small + second) × 2` | interdite, vérifiée à zéro |
| `abort` | `runtime/cache-abort` | `(small + second) × 2` | interdite, vérifiée à zéro |
| `eviction` | `runtime/cache-eviction` | `max(small, second) + 1` | **sujet du test** |

La bascule passe par `scripts/vps_phase5_switch_scenario.sh` : arrêt de l'API,
vérification que le port 3001 est libre, archivage du journal, réécriture d'un
`.env` 0600, cache du scénario effacé, redémarrage. Jamais deux API
simultanées. Chaque rapport publie `scenario`, `cacheRoot`, `cacheMaxBytes`,
`objectCountBefore/After`, `indexEntryCountBefore/After` et
`evictionsObserved`, ce dernier compté sur le seul journal du scénario courant.

### 10.2 Finalisation et HIT — scénario `finalize-offline`

MISS 200, `CACHE_FILL_STARTED` puis `CACHE_FILL_COMPLETED` observés, objet
final visible de **9 165 881 octets** exactement, `indexEntryCount=1`,
`partCount=0`, aucun échec ni bypass. Le GET suivant est un **vrai
`CACHE_HIT`** — événement corrélé par `requestId`, pas un simple 200 — sans
aucun `REMOTE_STORAGE_REQUEST_STARTED`. HEAD HIT et Range HIT validés. Aucune
éviction.

| Mesure | Valeur |
| --- | --- |
| TTFB MISS | 133,5 ms |
| TTFB HIT | 13,0 ms |
| TTFB HEAD HIT | 8,0 ms |
| TTFB Range HIT | 9,5 ms |
| Débit MISS | 4,552 Mio/s |
| Débit HIT | 182,083 Mio/s |

Le rapport HIT/MISS est de **40×** en débit et **10×** en TTFB : le cache tient
sa promesse sur le lien réel, et non sur une estimation.

### 10.3 Mode hors ligne, Storage Agent arrêté

Le mode hors ligne s'exécute **immédiatement** après la finalisation, pendant
que l'objet existe, et n'est jamais précédé d'un scénario capable de l'évincer.
Un mode `offline-precheck` **bloquant** conditionne l'arrêt de l'agent : il
échoue si `objectCount != 1`, `indexEntryCount != 1`, `partCount != 0`, si
l'objet, sa taille ou son empreinte manquent, si le `CACHE_HIT` n'est pas
prouvé, ou si l'upstream a été contacté. Sans son laissez-passer, le mode hors
ligne **refuse de s'exécuter** au lieu d'interpréter un 503 ambigu. La piste
non cachée du contrôle MISS est choisie pendant que l'agent tourne encore.

Résultats agent arrêté :

- GET piste cachée : **200**, `CACHE_HIT` observé ;
- HEAD piste cachée : **200** ;
- Range piste cachée : **206** ;
- aucun accès distant pendant les HIT ;
- objet et index toujours présents ;
- piste non cachée : **503 `service_unavailable`** ;
- aucun 401 interne exposé.

Après le test : `agentRestarted=true`, `listenerRestored=true` (listener
`10.8.0.2:3100`), `publicDomainHealthy=true`. Le redémarrage de l'agent est
placé dans un `finally` — il a lieu même si le mode hors ligne échoue — et un
second filet couvre le `finally` externe du harnais.

### 10.4 Récupération après redémarrage de l'API

Après redémarrage de l'API parallèle sur la même racine de cache : HEAD **200**,
`CACHE_HIT` observé, aucun appel distant, objet et index récupérés depuis le
disque, TTFB **12,5 ms**. L'index SQLite du cache survit donc au cycle de vie
du processus, sans reconstruction ni parcours de la bibliothèque Windows.

### 10.5 Abandon — scénario `abort`, cache isolé vide

GET 200, **65 536 octets** lus puis fermeture brutale : `.part` observé puis
supprimé, `CACHE_FILL_ABORTED` observé, **aucune promotion**. Un second
remplissage démarre sur la même empreinte — preuve **comportementale** que le
verrou single-flight a été rendu, et non une simple ligne de journal. Second
`.part` supprimé, `activeStreams` de l'agent revenu à zéro, aucune éviction.

### 10.6 Éviction LRU — scénario `eviction`, cache isolé serré

Premier objet promu, limite volontairement serrée, `CACHE_EVICTION_STARTED` et
`CACHE_EVICTED` observés, ancien objet supprimé, nouvel objet promu puis servi
en `CACHE_HIT`. État final : `objectCount=1`, `indexEntryCount=1`,
`partCount=0`. Cet état n'est jamais réutilisé par un autre scénario.

## 11. Garanties de cleanup et intégrité de production

`scripts/vps_phase5_cleanup.sh` supprime `.env`, `.hmac-secret`, le
laissez-passer hors ligne, `cache/` et **toutes** les racines
`runtime/cache-*`, puis assère lui-même son résultat :

```text
remainingSecretFiles=0
remainingCacheRoots=0
remainingListeners=0
```

Production après exécution complète :

- `HomeSpotifyApi` inchangé, même `ProcessId` qu'avant le test ;
- `HomeSpotifyStorageAgent` restauré et `Running` ;
- listener `10.8.0.2:3100` restauré ;
- domaine public sain (`/health` 200) ;
- Caddy, WireGuard et pare-feu inchangés ;
- `AUDIO_STORAGE_MODE` de production toujours local.

## 12. Défauts de harnais découverts et corrigés

Cinq défauts ont été trouvés **dans le harnais**, aucun dans
`CachedAudioStorageProvider`. Ils sont listés parce qu'ils ont chacun coûté un
aller-retour d'exécution réelle et qu'ils sont reproduits par des tests.

| # | Défaut | Symptôme observé | Correction | Tests |
| --- | --- | --- | --- | --- |
| 1 | Collision de variable tuple/chemin | `TypeError: expected string or bytes-like object, got 'tuple'` en profondeur dans `http.client` | `SelectedTrack.stream_path`, `ensure_http_path`, `ensure_track_id` : le type est refusé **par son nom**, sans jamais citer le jeton | `test_vps_phase5_harness.Phase5PathTypingTest` |
| 2 | Piste périmée Phase 4.5 sélectionnée | 503 systématique : `404 TRACK_NOT_INDEXED` → `INDEX_STALE` sur une piste de 4 096 octets, `hash = "f" × 64` | plancher de taille, ordre déterministe, `HEAD` de servabilité obligatoire, sélection partagée entre dimensionnement et test | `AbortTrackSelectionTest` (L-105) |
| 3 | Course de promotion | `objectCount=0` juste après un GET 200 réussi | le `content-length` termine la réponse **avant** `fsync`/rename/index : attente d'une condition **terminale** (événement ou objet final de la bonne taille), jamais d'un délai | `FillFinalizationTest` (L-107) |
| 4 | Logger désactivé par `NODE_ENV=test` | stdout à zéro octet, aucun événement `CACHE_*`, donc aucune preuve possible | `.env` du harnais en `NODE_ENV=production` ; le setup **vérifie la capture des journaux dès le démarrage** au lieu de la découvrir à la fin | `vps_phase5_setup.sh` étape `verify_log_capture` (L-108) |
| 5 | Cache unique détruisant les préconditions hors ligne | éviction légitime de l'objet promu par le scénario d'abandon, puis 503 correct sur un cache vide | trois racines et trois capacités isolées, hors ligne exécuté immédiatement, `offline-precheck` bloquant | `test_vps_phase5_isolation.py`, 38 tests (L-106) |

Principe commun aux corrections : **un statut HTTP ne prouve rien**. Un HIT
n'est un HIT que si un `CACHE_HIT` porte le `requestId` de la requête ; une
absence de journal rend `unknown`, jamais `false` ; un verrou n'est déclaré
libéré que si un second remplissage démarre réellement.

## 13. Réserves Phase 5 — toutes résolues

| Réserve initiale (§12 d'origine) | État | Preuve |
| --- | --- | --- |
| Module natif SQLite et filesystem VPS non qualifiés | **résolue** | index SQLite du cache créé, alimenté, relu après redémarrage de l'API |
| Métriques HIT/MISS réelles inconnues | **résolue** | §10.2, HIT 182,083 Mio/s contre MISS 4,552 Mio/s |
| Comportement sous éviction pendant lectures concurrentes | **résolue** | §10.6 et single-flight prouvé comportementalement en §10.5 |
| Reprise après redémarrage non validée sur le VPS | **résolue** | §10.4, HEAD 200 en `CACHE_HIT` à 12,5 ms |
| Cleanup sans secret ni listener résiduel | **résolue** | §11, trois compteurs à zéro |

## 14. Rollback

Rollback logiciel : utiliser `remote` ou `local`, ignorer/supprimer le cache
VPS, sans toucher à la bibliothèque, SQLite de production ou au réseau. Le
cache étant un décorateur sans état applicatif, sa suppression est sans perte :
les objets sont régénérables depuis le Storage Agent.

## 15. Suite

La Phase 6 (déploiement shadow de l'API sur le VPS) est **planifiée, non
commencée** : voir `docs/VPS_PHASE6_SHADOW_DEPLOYMENT_PLAN.md`. Aucune bascule
Caddy n'appartient à la Phase 6.
