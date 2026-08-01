# Phase 2 — HomeSpotify Storage Agent

**État : implémenté et testé en local. Non déployé, non installé en service, non exposé au réseau.**

Workspace : `services/storage-agent` (`@homespotify/storage-agent`).

---

## 1. Rôle et limites de responsabilité

Le Storage Agent est un service Node/TypeScript/Fastify **minimal** qui tourne sur
le PC Windows et sert les octets des fichiers audio au VPS, à travers WireGuard.

### Il fait exactement dix choses

1. charge un index local `trackId → chemin relatif` ;
2. résout ce chemin sous `MUSIC_ROOT`, avec confinement strict ;
3. sert les fichiers audio en flux ;
4. répond aux requêtes `HEAD` ;
5. gère HTTP Range ;
6. authentifie le VPS (HMAC daté + anti-rejeu) ;
7. protège les chemins (rejet traversal / absolu / UNC) ;
8. borne le nombre de flux simultanés ;
9. expose un health check interne ;
10. produit des diagnostics sûrs.

### Il n'embarque rien d'autre

Pas de Drizzle, pas de SQLite, pas d'authentification utilisateur, pas de
Discovery, pas de playlists, favoris, historique, acquisition, administration,
ni aucune logique métier de l'API principale. Ses seules dépendances de
production sont **Fastify** et la bibliothèque standard de Node.

Cette frontière est le point essentiel : l'agent est petit **pour pouvoir être
relu ligne à ligne**. C'est le seul composant HomeSpotify qui aura, en Phase 3,
un port ouvert sur une interface réseau du PC personnel.

### Ce qui n'est PAS fait par cette phase

- aucun `RemoteStorageProvider` dans l'API principale (Phase 4) ;
- aucun cache VPS (Phase 5) ;
- aucune synchronisation automatique de l'index VPS → PC (phase ultérieure,
  voir §5) ;
- aucun service Windows installé, aucun compte créé, aucune règle de pare-feu
  touchée (Phase 3) ;
- aucun changement du mapping d'erreurs public de l'API.

---

## 2. Architecture

```
services/storage-agent/
├── src/
│   ├── main.ts             point d'entrée (lecture .env, listen, arrêt gracieux)
│   ├── server.ts           Fastify : hooks de sécurité + 3 routes
│   ├── config.ts           configuration + normalisation d'IP
│   ├── errors.ts           codes d'erreur stables + statuts HTTP
│   ├── hmac-auth.ts        signature canonique, vérification, cache anti-rejeu
│   ├── storage-index.ts    schéma strict + rechargement atomique de l'index
│   ├── path-safety.ts      confinement des chemins (portage Phase 1)
│   ├── range.ts            parsing HTTP Range
│   ├── stream-limiter.ts   compteur borné de flux simultanés
│   ├── content-type.ts     type MIME par extension (table close)
│   └── test/harness.ts     banc d'essai HTTP (127.0.0.1, port éphémère)
└── winsw/                  modèle de service Windows, INERTE (Phase 3)
```

Ordre des barrières sur chaque requête, du moins cher au plus cher :

```
IP source (403) → refus de corps (401) → HMAC + anti-rejeu (401)
   → trackId (400) → index (404) → confinement → stat (404/503)
   → emplacement de flux (503) → ouverture du fichier
```

Le fichier n'est **jamais** ouvert avant que toutes les validations soient
passées.

### Primitives de sécurité et Phase 1

`path-safety.ts` est un **portage autonome** de
`services/api/src/storage/audio-storage.ts` (`toPortableRelativePath`) et de
`LocalFileStorageProvider.resolvePath`.

Un import direct du module de l'API aurait traîné Drizzle, better-sqlite3 et la
configuration du backend dans un service qui doit rester minimal. Un package
partagé aurait ajouté un troisième workspace TypeScript pour ~80 lignes de
logique pure et figée. Contrepartie assumée et rendue explicite :
`path-safety.test.ts` rejoue le **même jeu de cas** que `audio-storage.test.ts`,
donc toute divergence de comportement entre les deux implémentations fait rougir
la suite plutôt que de dériver en silence.

---

## 3. Configuration

| Variable | Défaut | Bornes / notes |
| --- | --- | --- |
| `STORAGE_AGENT_HOST` | `127.0.0.1` | `0.0.0.0`, `::` et `*` sont **refusés**, même explicitement |
| `STORAGE_AGENT_PORT` | `3100` | 1–65535 |
| `STORAGE_AGENT_MUSIC_ROOT` | — | **obligatoire**, résolu en absolu |
| `STORAGE_AGENT_INDEX_PATH` | — | **obligatoire**, résolu en absolu |
| `STORAGE_AGENT_SHARED_SECRET` | — | **obligatoire hors test**, 32 caractères minimum |
| `STORAGE_AGENT_ALLOWED_REMOTE_IP` | `10.8.0.1` | liste d'IP littérales séparées par des virgules ; CIDR refusé |
| `STORAGE_AGENT_MAX_CONCURRENT_STREAMS` | `8` | 1–64 |
| `STORAGE_AGENT_HMAC_MAX_CLOCK_SKEW_SECONDS` | `60` | 5–300 |
| `STORAGE_AGENT_LOG_LEVEL` | `info` | niveaux pino |
| `STORAGE_AGENT_INDEX_POLL_INTERVAL_MS` | `5000` | 0 = rechargement manuel seulement |

Toute valeur absente, vide ou hors bornes provoque une erreur explicite au
démarrage — jamais un repli silencieux. Le secret n'apparaît ni dans les logs,
ni dans les messages d'erreur (test dédié), ni dans `/health`.

Modèle complet : `services/storage-agent/.env.example`.

**Le bind `10.8.0.2` est une opération de Phase 3.** En Phase 2, l'agent n'écoute
que sur `127.0.0.1` et n'est lancé qu'à la main.

---

## 4. Format de l'index

```json
{
  "version": 1,
  "generatedAt": "2026-07-26T10:00:00.000Z",
  "entries": {
    "1": { "relativePath": "Artiste/Album/Titre.flac" }
  }
}
```

Schéma **strict** — tout écart est un rejet de l'index entier :

- `version` doit valoir exactement `1` (une version inconnue n'est pas migrée) ;
- `generatedAt` doit être un ISO-8601 valide ;
- aucune clé racine autre que `version`, `generatedAt`, `entries` ;
- chaque clé d'entrée doit être un entier décimal **canonique** (`^[1-9][0-9]*$`) :
  `01`, `0`, `-1`, `1.0` sont refusés. C'est ainsi qu'on traite le « doublon
  d'identifiant » : deux clés littéralement identiques sont indiscernables après
  `JSON.parse` (la dernière écrase la première), mais les **alias** — seule forme
  de doublon réellement observable — sont refusés d'emblée ;
- chaque entrée n'a qu'un champ, `relativePath` ; tout champ supplémentaire est
  un rejet ;
- chaque `relativePath` passe par `toPortableRelativePath` : vide, absolu Unix,
  absolu Windows, UNC et segment `..` sont refusés.

**Une seule entrée dangereuse invalide tout l'index.** Les motifs de rejet
journalisés ne contiennent jamais le chemin fautif, seulement l'identifiant de
piste et la raison (`TRAVERSAL`, `WINDOWS_ABSOLUTE`, …).

### Génération

```bash
pnpm --filter @homespotify/api storage-index:export
```

Optionnellement `-- --out <chemin>`. Sortie par défaut :
`storage/storage-agent/index.json` (ignoré par Git : il contient les chemins
relatifs de la bibliothèque réelle, donnée personnelle, et il est régénérable).

Le CLI :

- ouvre SQLite en `readonly` + `fileMustExist` — aucune écriture possible ;
- normalise les backslashes via les primitives de la Phase 1 ;
- exclut et compte les chemins invalides plutôt que de les « réparer » ;
- vérifie l'existence de chaque fichier par `stat` (aucun fichier audio n'est
  ouvert ni modifié) ;
- écrit dans `<sortie>.tmp` puis renomme — remplacement atomique ;
- n'affiche que des compteurs et, pour les anomalies, des identifiants de
  pistes. Aucun chemin, complet ou relatif.

Résultat réel au 2026-07-26 :

```
158 pistes exportées
158 fichiers valides
0 chemin(s) invalide(s)
0 fichier(s) absent(s)
```

### Rechargement

- chargement au démarrage ;
- détection de modification par `mtimeMs` + taille ;
- scrutation périodique (`STORAGE_AGENT_INDEX_POLL_INTERVAL_MS`, timer `unref`) ;
- remplacement par **échange de référence** : le moteur étant mono-thread,
  aucune requête ne peut observer un index à moitié construit ;
- un fichier invalide ne remplace **jamais** un index valide en place ;
- une empreinte rejetée n'est pas mémorisée : un fichier corrigé sur place est
  rechargé au tour suivant ;
- le remplacement atomique par `rename` du CLI est suivi correctement (test
  dédié).

### Synchronisation VPS → PC : hors périmètre

Aujourd'hui l'index est déposé **manuellement** sur le PC. Le mécanisme de
synchronisation automatique (déclenchement, transport, authentification,
gestion des suppressions) sera traité dans une **phase ultérieure**, après la
Phase 3. Il n'existe volontairement aucun endpoint d'écriture d'index : le
Storage Agent ne peut pas se faire modifier son index par le réseau.

---

## 5. Authentification

### Modèle de menace

Trois barrières indépendantes, chacune supposant la précédente percée :

1. **WireGuard** — le port n'est joignable que par le tunnel (Phase 3) ;
2. **filtrage de l'IP source** — seule `10.8.0.1` est acceptée ;
3. **HMAC-SHA256 daté avec anti-rejeu** — même un attaquant qui voit passer les
   requêtes ne peut ni les rejouer, ni en forger.

### Chaîne canonique

```
METHOD \n PATH_WITH_QUERY \n TIMESTAMP \n NONCE \n CONTENT_SHA256
```

En-têtes : `X-HS-Timestamp`, `X-HS-Nonce`, `X-HS-Content-SHA256`,
`X-HS-Signature`, `X-Request-Id` (optionnel, repris tel quel s'il est
inoffensif).

- méthode normalisée en majuscules ;
- **query string incluse** : un paramètre ajouté ou retiré invalide la signature ;
- `CONTENT_SHA256` = SHA-256 du corps vide pour tout GET/HEAD
  (`e3b0c442…b855`), et l'agent **refuse** toute requête portant un corps ;
- timestamp epoch en secondes, fenêtre ±60 s par défaut ;
- nonce d'au moins 128 bits (22 caractères base64url minimum ; le client en
  génère 256) ;
- signature hexadécimale de 64 caractères, **taille validée avant**
  `timingSafeEqual` — qui lève sur des longueurs inégales.

Ordre des contrôles : présence → fraîcheur → format → empreinte de corps →
signature → anti-rejeu.

### Anti-rejeu

`Map` bornée (20 000 entrées) avec TTL = 2 × la fenêtre d'horloge. Purge amortie
sur les insertions, dans l'ordre d'insertion — donc dans l'ordre d'expiration :
aucun timer, rien à arrêter.

Point de conception important : **un nonce n'entre dans le cache qu'après
validation de la signature**. Sinon un tiers sans secret pourrait saturer le
cache avec des nonces inventés. Si le cache est plein malgré la purge, la
requête est refusée plutôt qu'une entrée évincée — une éviction rouvrirait la
fenêtre de rejeu.

### Réponses

| Situation | Statut | Code |
| --- | --- | --- |
| En-tête d'authentification absent | 401 | `AUTH_MISSING` |
| Signature, nonce, empreinte ou format invalide | 401 | `AUTH_INVALID` |
| Horloge désynchronisée | 401 | `AUTH_EXPIRED` |
| Nonce rejoué | 401 | `AUTH_REPLAY` |
| IP source refusée | 403 | `SOURCE_IP_DENIED` |

Les logs d'authentification ne contiennent **jamais** la signature, le secret ou
le nonce — seulement un motif court et fixe.

---

## 6. Filtrage de l'IP source

L'adresse est lue sur `request.socket.remoteAddress`, **pas** sur `request.ip` :
aucune confiance n'est accordée à `X-Forwarded-For` (et `trustProxy` reste
désactivé).

La normalisation :

- réduit la forme IPv4-mapped IPv6 (`::ffff:10.8.0.1` → `10.8.0.1`) ;
- retire crochets et zone-id ;
- canonicalise les octets à zéros initiaux (`010.008.000.001` → `10.8.0.1`) ;
- **n'élargit aucune plage** : `::1` reste `::1`, une autorisation IPv4 ne couvre
  pas IPv6, et aucun CIDR n'est accepté en configuration.

La comparaison est une égalité stricte sur une liste explicite. En tests,
`127.0.0.1` est autorisée **explicitement** dans la configuration de test ; ce
n'est jamais un défaut.

---

## 7. HEAD

- valide l'authentification, puis le `trackId`, puis l'index ;
- utilise **uniquement `stat`** ;
- **n'ouvre jamais de `ReadStream`** (test dédié avec compteur d'ouvertures) ;
- **ne consomme aucun emplacement** de streaming ;
- retourne un corps vide.

En-têtes renvoyés : `Accept-Ranges`, `Content-Type`, `Content-Length`
(taille **réelle**, ou taille de la plage en 206), `Last-Modified`,
`Content-Range` en 206, `X-Request-Id`.

La réponse est écrite en direct (`reply.hijack()`) : Fastify force sinon
`content-length: 0` sur toute réponse sans corps, ce qui rendrait le HEAD
inutile.

---

## 8. GET et Range

Statuts : `200` complet, `206` plage valide, `400` trackId invalide, `401` auth,
`403` IP, `404` piste hors index **ou** fichier absent, `416` plage
insatisfaisable, `503` saturation / index absent / racine indisponible, `500`
erreur interne sans détail.

Formes de Range gérées : absence, `bytes=N-`, `bytes=N-M`, `bytes=-N`, borne
supérieure dépassant la taille (ramenée), `start > end` → 416, `start >= size` →
416, fichier vide → 416 pour toute plage.

**Multi-range explicitement refusé.** `bytes=0-1,5-6` n'est jamais honoré :
l'agent ignore le Range et sert la représentation complète en 200, ce que la RFC
9110 autorise et ce que fait **déjà l'API publique** — aucun
`multipart/byteranges` n'existe nulle part dans HomeSpotify. La compatibilité
avec le comportement public actuel est ainsi préservée, et vérifiée par un jeu
de tests parallèle à `services/api/src/lib/range.test.ts`.

Le fichier n'est jamais chargé en mémoire : `createReadStream(path, {start, end})`
avec un `highWaterMark` de 256 Ko, identique au streaming de l'API.

---

## 9. Concurrence et backpressure

- 8 GET actifs par défaut, borne configurable ;
- **aucune file d'attente** : au-delà de la limite, refus immédiat. Une file non
  bornée transformerait une saturation disque en accumulation mémoire ;
- HEAD et `/health` ne consomment **aucun** emplacement — ce sont des opérations
  `stat`, elles doivent rester disponibles précisément quand le disque sature ;
- l'emplacement est réservé **après** toutes les validations et **avant**
  l'ouverture : un refus ne coûte aucun descripteur de fichier ;
- libération par un point **unique** — `close` de la réponse — qui survient dans
  tous les cas : fin normale, abandon client, erreur disque, fermeture Fastify,
  exception. La fonction de libération est idempotente ;
- la backpressure est préservée : le `Transform` compteur d'octets ne lit rien
  tant que la socket ne draine pas.

### Saturation : 503, pas 429 — décision

La limite protège une **ressource serveur** (disque + bande passante WireGuard) ;
elle ne sanctionne pas un client abusif — l'unique client légitime est le VPS.
`503 Service Unavailable` + `Retry-After: 1` exprime exactement « réessaie, ce
n'est pas ta faute ». `429 Too Many Requests` désignerait le client comme fautif
et induirait en erreur le futur `RemoteStorageProvider`.

---

## 10. Health check

`GET /internal/storage/health` — **authentifié comme les autres routes**.

Renvoie : `status`, `agentVersion`, `indexLoaded`, `indexVersion`,
`indexEntryCount`, `indexGeneratedAt`, `indexLoadedAt`,
`indexLastRejectionReason` (motif court), `musicRootAvailable`, `activeStreams`,
`maxConcurrentStreams`, `uptimeSeconds`.

Ne renvoie **jamais** : `MUSIC_ROOT`, un chemin, un nom de fichier, le secret, la
configuration ou les variables d'environnement. Un test vérifie l'absence de
chacun.

### Sans index valide : `unhealthy` — décision

| Situation | Statut | HTTP |
| --- | --- | --- |
| Index chargé, racine musicale accessible | `healthy` | 200 |
| Index chargé, racine musicale inaccessible | `degraded` | 200 |
| Aucun index valide | `unhealthy` | 503 |

Sans index, l'agent ne peut servir **aucune** piste : 100 % des requêtes
échoueraient. Ce n'est pas une dégradation, c'est une indisponibilité, et le
503 doit sortir l'agent d'un éventuel pool amont. À l'inverse, une racine
musicale momentanément absente (volume non monté) avec un index encore valide
est réversible sans intervention : `degraded` en 200, l'agent reste interrogeable
pour diagnostic.

---

## 11. Erreurs typées

`INVALID_TRACK_ID` (400) · `TRACK_NOT_INDEXED` (404) · `FILE_NOT_FOUND` (404) ·
`INVALID_RANGE` (416) · `AUTH_MISSING` / `AUTH_INVALID` / `AUTH_EXPIRED` /
`AUTH_REPLAY` (401) · `SOURCE_IP_DENIED` (403) · `INDEX_NOT_LOADED` (503) ·
`INDEX_INVALID` (503) · `MUSIC_ROOT_UNAVAILABLE` (503) ·
`STREAM_LIMIT_REACHED` (503) · `STREAM_READ_ERROR` (500) · `INTERNAL_ERROR` (500).

Corps de réponse unique : `{ error, message, requestId }`. Le message est
générique **par construction** — jamais dérivé d'une exception. Le champ
`detail` des erreurs internes ne sort jamais du processus.

Ces codes constituent le contrat interne PC ↔ VPS et sont prêts pour leur
mapping par le futur `RemoteStorageProvider`. **Le mapping public de l'API
principale n'est pas modifié par cette phase.**

Note de surface : une route inconnue renvoie 404 `TRACK_NOT_INDEXED`, comme une
piste inconnue. Un scan externe ne peut donc pas distinguer « cette route
existe » de « cette piste existe ».

---

## 12. Logs et diagnostics

Événements structurés : `STORAGE_AGENT_REQUEST_STARTED`,
`STORAGE_AGENT_REQUEST_COMPLETED`, `STORAGE_AGENT_REQUEST_ABORTED`,
`STORAGE_AGENT_AUTH_REJECTED`, `STORAGE_AGENT_INDEX_LOADED`,
`STORAGE_AGENT_INDEX_REJECTED`, `STORAGE_AGENT_LIMIT_REACHED`,
`STORAGE_AGENT_MULTI_RANGE_IGNORED`.

Champs : `requestId`, `method`, `route` (libellé **logique**, jamais l'URL brute),
`trackId`, `statusCode`, `durationMs`, `bytesSent`, `rangeRequested`,
`clientAborted`, `errorCode`, `activeStreams`.

Jamais journalisés : `Authorization`, signature HMAC, secret, nonce, chemin
absolu, chemin relatif musical, nom de fichier, contenu de l'index.

Le journal de requêtes intégré de Fastify est désactivé : il afficherait l'URL de
chaque requête et ferait doublon avec ces événements.

---

## 13. Procédure de test

```bash
pnpm --filter @homespotify/storage-agent test
pnpm --filter @homespotify/storage-agent typecheck
pnpm --filter @homespotify/storage-agent build
```

Les tests HTTP écoutent sur `127.0.0.1` avec un **port éphémère** (`port: 0`),
jamais 3100, jamais `0.0.0.0`, et chaque serveur est fermé en `afterEach` :
aucun processus ne reste en écoute.

Couverture : index (schéma, rejets, rechargement, atomicité), HMAC (signature,
secret, horloge, nonce, empreinte, query, méthode, tailles), IP (refus,
IPv4-mapped), HEAD (aucun `ReadStream`, en-têtes exacts, corps vide, Range),
GET (complet, 3 formes de Range, 416, multi-range, fichier vide, absent, abandon
client, erreur disque, absence de fuite de chemin), concurrence (8 acceptés,
9ᵉ refusé, libération après succès / abandon / erreur), health (nominal, sans
index, racine absente, flux actifs, absence de fuite).

Export CLI : `services/api/src/storage/storage-index-export.test.ts` (base lue en
readonly et inchangée octet à octet, atomicité, résumé exact, aucun chemin
affiché).

---

## 14. Lancer l'agent à la main (Phase 2)

```bash
pnpm --filter @homespotify/api storage-index:export
```

puis, après avoir créé `services/storage-agent/.env` depuis `.env.example` :

```bash
pnpm --filter @homespotify/storage-agent dev
```

L'agent écoute sur `127.0.0.1:3100`. **Aucun service permanent ne doit être
laissé démarré à l'issue de cette phase.**

---

## 15. Travail restant — Phase 3

1. Créer le compte Windows dédié non privilégié `HomeSpotifySA`.
2. Créer le fichier d'environnement protégé et y placer le secret partagé.
3. Basculer `STORAGE_AGENT_HOST` sur `10.8.0.2`.
4. **Remplacer la règle Windows générique Node.js**, aujourd'hui trop
   permissive, par une règle d'entrée dédiée : 3100/TCP, interface WireGuard,
   source `10.8.0.1` uniquement.
5. Installer le service via WinSW (`winsw/README.md`).
6. Vérifier `/health` depuis le VPS, puis un GET avec Range réel.
7. Définir le mécanisme de synchronisation de l'index.

Ensuite seulement : Phase 4 (`RemoteStorageProvider`) et Phase 5 (cache VPS).

---

## 16. Rollback

Le Storage Agent est **additif** : aucun composant existant n'en dépend en
Phase 2.

- **Annuler l'exécution** : arrêter le processus (Ctrl+C). L'API principale
  continue de servir les fichiers en local, exactement comme avant — son
  `AUDIO_STORAGE_MODE` reste `local`.
- **Annuler l'index** : supprimer `storage/storage-agent/index.json`. Aucun autre
  composant ne le lit.
- **Annuler le code** : supprimer `services/storage-agent/`, retirer l'entrée
  `storage-index:export` de `services/api/package.json` et les deux fichiers
  `storage-index-export*` de l'API. Rien d'autre n'a été modifié dans le
  backend.
- **Rien à annuler côté système** : aucun service, aucun compte, aucune règle de
  pare-feu, aucune modification de Caddy ni de WireGuard.
