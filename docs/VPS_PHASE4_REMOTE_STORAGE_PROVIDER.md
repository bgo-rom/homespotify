# Phase 4 — Remote Windows Storage Provider

**Date :** 2026-07-26  
**Statut :** IMPLÉMENTÉ — activation de production interdite à ce stade  
**Plan :** [VPS_PHASE4_REMOTE_STORAGE_PROVIDER_PLAN.md](VPS_PHASE4_REMOTE_STORAGE_PROVIDER_PLAN.md)

## 1. Verdict

Le code de l'API sait désormais lire la bibliothèque par le Storage Agent
Windows. La production reste strictement en mode `local` : aucun `.env`, service,
pare-feu, tunnel, Caddy, fichier musical ou SQLite réel n'a été modifié.

```
API future sur VPS
  └─ RemoteWindowsStorageProvider
       ├─ HEAD /internal/storage/tracks/:trackId
       ├─ GET  /internal/storage/tracks/:trackId
       └─ GET  /internal/storage/health
              │ HTTP keep-alive + HMAC
              ▼
       Storage Agent Windows 10.8.0.2:3100
```

`relativePath`, `MUSIC_ROOT` et les noms de fichiers ne franchissent jamais le
réseau. Seul `trackId` apparaît dans l'URL. `contentHash` reste local à l'API et
continue de produire l'ETag public.

## 2. Fichiers créés

| Fichier | Rôle |
| --- | --- |
| `services/api/src/storage/remote/remote-config.ts` | validation conditionnelle de la configuration |
| `services/api/src/storage/remote/hmac-client.ts` | protocole HMAC côté API |
| `services/api/src/storage/remote/agent-error-mapping.ts` | codes agent → erreurs de stockage |
| `services/api/src/storage/remote/storage-agent-client.ts` | transport `node:http`, pool et timeouts |
| `services/api/src/storage/remote/remote-windows-storage.ts` | implémentation `AudioStorageProvider` |
| cinq fichiers `*.test.ts` dans le même dossier | tests contractuels, transport, mapping et câblage |
| ce document | compte rendu Phase 4 |

## 3. Fichiers modifiés

- `audio-storage.ts` : erreurs distantes typées, contexte `requestId`, taille
  SQLite attendue facultative et fermeture facultative du provider ;
- `provider-factory.ts` : mode `remote` réel, `cached` toujours refusé ;
- `config.ts` et `.env.example` : variables `AUDIO_REMOTE_*` ;
- `app.ts` : injection du provider, logger sûr, fermeture du pool ;
- `routes/tracks.ts` : mapping public, HEAD sans flux, annulation amont ;
- `audio-storage.test.ts` : factory Phase 4 ;
- `services/storage-agent/src/server.ts` et son test : en-tête additif
  `X-HS-Error-Code` sur les erreurs, indispensable aux réponses HEAD sans corps ;
- `TECH_DECISIONS.md`, `LESSONS.md` et le plan Phase 4.

L'agent Windows installé n'a pas été redéployé ni redémarré.

## 4. Configuration

```dotenv
AUDIO_STORAGE_MODE=local

# Obligatoire uniquement avec AUDIO_STORAGE_MODE=remote
AUDIO_REMOTE_BASE_URL=http://10.8.0.2:3100
AUDIO_REMOTE_SHARED_SECRET=<32+ caractères aléatoires>
AUDIO_REMOTE_CONNECT_TIMEOUT_MS=2000
AUDIO_REMOTE_HEADERS_TIMEOUT_MS=5000
AUDIO_REMOTE_BODY_IDLE_TIMEOUT_MS=15000
AUDIO_REMOTE_MAX_CONNECTIONS=8
```

- absence de mode → `local` ;
- `local` ne lit et n'exige aucune variable distante ;
- `remote` exige URL et secret valides ;
- URL limitée à `http://` sur IP privée littérale, sans credentials, query,
  fragment ou chemin ;
- tous les entiers sont bornés ;
- `cached` échoue explicitement avec la mention Phase 5 ;
- aucun message d'erreur ne reproduit le secret.

Le défaut du pool est 8, aligné sur les huit flux GET acceptés par l'agent. La
valeur 16 envisagée a été écartée : elle permettrait à l'API d'ouvrir deux fois
plus de connexions que la limite réellement servable.

## 5. HMAC

En-têtes :

`X-HS-Timestamp` · `X-HS-Nonce` · `X-HS-Content-SHA256` ·
`X-HS-Signature` · `X-Request-Id`.

Chaîne canonique inchangée :

```
METHOD
PATH_WITH_QUERY
TIMESTAMP
NONCE
CONTENT_SHA256
```

La méthode est mise en majuscules, la query est incluse, le timestamp est en
secondes Unix, le nonce fait 256 bits en base64url, le hash est celui du corps
vide et la signature est un HMAC-SHA256 hexadécimal minuscule. Un test
déterministe exécute les implémentations API et agent sur le même vecteur et
exige des chaînes, signatures et en-têtes identiques.

## 6. Stat distant

`stat(reference)` émet exclusivement :

```
HEAD /internal/storage/tracks/<trackId>
```

La réponse doit être 200 et fournir :

- `Content-Length` entier sûr et positif ou nul ;
- `Last-Modified` valide ;
- `Content-Type: audio/*` ;
- `Accept-Ranges: bytes` ;
- aucun `Content-Range` sans Range.

Le corps HEAD est drainé et doit rester vide. La fin lisible est attendue avant
de rendre la socket au pool. `expectedSizeBytes`, issu de SQLite, ne remplace
jamais HEAD : un écart produit `REMOTE_STORAGE_SIZE_MISMATCH`, sans écriture en
base et sans interrompre le flux.

## 7. Flux distant

`createReadStream(reference, range?)` émet un GET signé. Une plage est transmise
sans conversion :

```
Range: bytes=<start>-<end>
```

Le corps `IncomingMessage` est raccordé à un `Transform` de garde. Aucun audio
n'est accumulé globalement, recopié dans un fichier temporaire ou caché. La
garde :

- laisse la backpressure remonter jusqu'à la socket Windows ;
- compte les octets ;
- exige exactement `Content-Length` ;
- détecte `aborted`, erreur socket et troncature ;
- détruit immédiatement la réponse distante si le consommateur détruit le flux ;
- applique le timeout d'inactivité du body.

Aucun retry implicite n'existe, avant ou après les premiers octets.

## 8. HEAD public

`serveTrackFile` détecte maintenant `request.method === "HEAD"` après `stat` et
le parsing Range, mais avant `createReadStream`. Il écrit directement les
en-têtes sur la réponse brute pour préserver le vrai `Content-Length`, puis
termine avec un corps vide.

ETag, Last-Modified, Accept-Ranges, Content-Type, Content-Length et
Content-Range éventuel restent identiques au GET. Un test compteur exige zéro
ouverture de flux.

## 9. Range public

Le parsing public reste l'unique source des bornes :

- sans Range → 200 ;
- `N-M`, `N-`, `-N` → 206 ;
- insatisfaisable → 416 avant tout GET distant ;
- multi-range → comportement historique inchangé ;
- ETag = `contentHash` SQLite.

Les tests vérifient simultanément la plage reçue du mobile, celle transmise au
provider et les octets retournés.

## 10. Keep-alive et timeouts

Le client utilise `node:http.Agent` avec `keepAlive`, `maxSockets` et
`maxFreeSockets` bornés. Le pool est détruit par le hook `onClose` de Fastify.

Délais indépendants :

| Phase | Défaut | Code |
| --- | ---: | --- |
| connexion TCP | 2 s | `CONNECT_TIMEOUT` |
| réception des headers | 5 s | `HEADERS_TIMEOUT` |
| inactivité du body | 15 s | `BODY_TIMEOUT` |

Il n'existe aucun timeout global de piste : une grosse piste lente mais active
reste légitime.

## 11. Mapping d'erreurs

| Situation | Erreur interne API | HTTP public |
| --- | --- | ---: |
| `FILE_NOT_FOUND` confirmé | `NOT_FOUND` | 404 |
| `TRACK_NOT_INDEXED` | `INDEX_STALE` | 503 |
| agent/tunnel indisponible, timeouts | typée selon la phase | 503 |
| index/racine indisponible | code dédié | 503 |
| saturation | `STORAGE_BUSY` | 503 + `Retry-After: 1` |
| HMAC/IP interne refusé | `REMOTE_AUTH_FAILED` | 502, jamais 401 |
| réponse/en-têtes/Range incohérents | `REMOTE_INVALID_RESPONSE` | 502 |
| flux distant interrompu | `REMOTE_STREAM_INTERRUPTED` | socket interrompue |

Les réponses JSON publiques restent génériques et ne contiennent aucun détail
agent. L'en-tête interne `X-HS-Error-Code` permet de distinguer les erreurs sur
HEAD, dont le corps est obligatoirement vide.

## 12. Diagnostics

Événements ajoutés :

`REMOTE_STORAGE_REQUEST_STARTED` · `REMOTE_STORAGE_REQUEST_COMPLETED` ·
`REMOTE_STORAGE_REQUEST_FAILED` · `REMOTE_STORAGE_REQUEST_ABORTED` ·
`REMOTE_STORAGE_SIZE_MISMATCH` · `REMOTE_STORAGE_AGENT_UNAVAILABLE` ·
`REMOTE_STORAGE_INDEX_STALE`.

Champs sûrs : requestId, trackId, méthode, opération, statut, durée, bornes,
octets, aborted et code typé. Aucun secret, nonce, signature, URL brute, chemin
ou nom de fichier. Tous les événements `STREAM_*` existants sont conservés.

## 13. Health check

`healthCheck()` appelle le health signé, borne le JSON interne à 64 Kio et ne
retient que son statut :

- `healthy` → `online`, source `remote`, latence mesurée ;
- `degraded` → raison publique fixe ;
- refus/injoignable/invalide → `offline`, raison fixe.

Le contrat public `/health` n'a pas été modifié.

## 14. Tests

Baseline avant Phase 4 :

- Storage Agent : 147/147 ;
- API : 437/437 ;
- typechecks et builds verts.

Les nouveaux tests couvrent configuration/factory, HMAC croisé, HEAD, stat,
headers invalides, divergence de taille, GET complet, Range, troncature,
abandon, body timeout, keep-alive, health, mapping agent et mapping public.
Les suites existantes `tracks`, `offline` et stockage local restent incluses
dans la validation finale.

| Validation | Résultat |
| --- | --- |
| Tests ciblés API | 144/144 |
| Suite API complète | **490/490** (46 fichiers) |
| Suite Storage Agent complète | **147/147** (6 fichiers) |
| Typecheck API / agent | verts |
| Build API / agent | verts |
| `git diff --check` | vert |
| Flutter | non exécuté, aucun contrat mobile modifié |

## 15. Rollback

Rollback purement logiciel :

1. laisser `AUDIO_STORAGE_MODE` absent ou `local` ;
2. la factory construit `LocalFileStorageProvider` ;
3. `offlineVariantStorage` reste local dans tous les modes.

Aucune donnée, migration ou configuration système n'est à annuler.

## 16. Risques et travail restant

- Phase 4.5 a déployé et validé l'en-tête additif `X-HS-Error-Code` sur l'agent
  installé. Le risque de désynchronisation de ce contrat est fermé.
- Deux allers-retours HEAD + GET ajoutent environ deux RTT ; Phase 5 traitera le
  cache, pas Phase 4.
- Synchronisation d'index et rotation coordonnée du secret restent à réaliser.
- La chute/remontée de l'agent, le keep-alive, la saturation, la backpressure et
  l'abandon ont été qualifiés sur le VPS en Phase 4.5.
- La session mobile longue et la bascule de production restent hors Phase 4.5.

## 17. Avant activation réelle

Phase 4.5 a validé l'API parallèle, l'agent coordonné, le smoke 23/23 et le
provider réel sans bascule Caddy. Avant toute activation de production :

1. définir la stratégie de migration et de rollback de l'API et de SQLite ;
2. déposer les secrets de production avec ACL/modes stricts et rotation prévue ;
3. synchroniser l'index au moment de la bascule ;
4. rejouer seek, piste suivante, écran verrouillé et session mobile longue ;
5. seulement alors envisager `AUDIO_STORAGE_MODE=remote` en production.

La qualification Phase 4.5 est acquise. La Phase 5 pourra proposer un cache
décorateur borné sans altérer le provider distant validé, son adressage par
`trackId`, ses erreurs typées ni ses garanties de streaming.
