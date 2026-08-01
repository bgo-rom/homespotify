# Phase 4 — `RemoteWindowsStorageProvider` — plan détaillé

**Date :** 2026-07-26 · **Dépôt :** `F:\dev\homespotify` · branche `feature/lucida-import`
**État : PLAN. Aucune implémentation commencée.**

Prérequis Phase 3 : **satisfaits** — voir
`docs/VPS_PHASE3_STORAGE_AGENT_DEPLOYMENT.md` §15 et §18.

---

## 1. Objectif

Écrire la troisième implémentation de `AudioStorageProvider` : celle qui va
chercher les octets audio sur le Storage Agent du PC Windows, à travers
WireGuard, au lieu de les lire sur un disque local.

C'est la pièce qui rend le mode `AUDIO_STORAGE_MODE=remote` réel. Elle ne
l'active pas.

### Ce que la Phase 4 fait

1. `RemoteWindowsStorageProvider implements AudioStorageProvider` ;
2. un client HMAC TypeScript, miroir testé du protocole de la Phase 2 ;
3. la configuration associée, validée au démarrage ;
4. le câblage dans `createAudioStorageProvider` pour le mode `remote` ;
5. la correction du mapping d'erreurs HTTP, aujourd'hui incorrect pour un
   stockage distant (§8) ;
6. la couverture de tests.

### Ce que la Phase 4 ne fait PAS

- **`AUDIO_STORAGE_MODE` reste `local`.** Le mode `remote` devient disponible,
  il n'est pas activé. L'activation est une décision d'exploitation distincte,
  avec sa propre porte de validation (§13).
- Aucun cache — c'est la Phase 5, et l'absence de cache est une propriété
  assumée du provider de la Phase 4, pas un manque.
- Aucun déplacement du backend, de la base ou de la bibliothèque.
- Aucun changement Caddy, WireGuard, ni mobile.
- Aucune synchronisation automatique de l'index.
- Aucun changement du contrat public de l'API, hors les statuts d'erreur
  décrits en §8, qui sont aujourd'hui **faux** pour un stockage distant.

---

## 2. Ce sur quoi la phase s'appuie

### Contrat existant, inchangé — `services/api/src/storage/audio-storage.ts`

```ts
interface AudioStorageProvider {
  stat(reference: TrackStorageReference): Promise<AudioFileInfo>;
  createReadStream(reference: TrackStorageReference, range?: ByteRange): Promise<Readable>;
  healthCheck(): Promise<StorageHealth>;
}

interface TrackStorageReference { trackId: number; relativePath: string; contentHash: string }
interface ByteRange { start: number; end: number }            // inclusif, comme HTTP
interface AudioFileInfo { sizeBytes: number; modifiedAt: Date; source: 'local'|'cache'|'remote' }
```

Trois méthodes, aucune notion de HTTP. Le parsing du Range et les statuts
200/206/416 restent dans la couche HTTP. Le provider ne fait que fournir des
informations et des flux.

### Surface offerte par le Storage Agent (Phase 2, déployée en Phase 3)

| Route | Usage Phase 4 |
| --- | --- |
| `GET /internal/storage/health` | `healthCheck()` |
| `HEAD /internal/storage/tracks/:trackId` | `stat()` |
| `GET /internal/storage/tracks/:trackId` + `Range` | `createReadStream()` |

Authentification sur les trois : HMAC-SHA256 daté, anti-rejeu, filtrage d'IP
source. Mesuré en Phase 3 : **43,8 ms de latence moyenne** VPS → agent.

---

## 3. Décisions de conception

Sept points sont tranchés ici plutôt que laissés à l'implémentation.

### D1 — Adressage par `trackId`, pas par `relativePath`

Le provider reçoit un `relativePath` et ne l'utilise **pas**. Il appelle
`/internal/storage/tracks/:trackId`.

Ce n'est pas un choix de commodité : l'agent n'expose délibérément aucune route
prenant un chemin. Son index **est** la liste d'autorisation. Accepter un
chemin arbitraire rouvrirait exactement la surface que la Phase 2 a fermée.

**Conséquence à assumer et à instrumenter :** il existe désormais deux
résolutions `trackId → chemin`, celle de la base et celle de l'index de
l'agent. Elles peuvent diverger — c'est précisément ce que la procédure de
rafraîchissement d'index traite. Un `404 TRACK_NOT_INDEXED` sur une piste
présente en base n'est pas une piste manquante : c'est un index périmé, et le
journal doit le dire en ces termes (§7).

### D2 — `stat()` interroge l'agent, la base sert de contrôle de cohérence

La table `tracks` porte déjà `sizeBytes`. On pourrait s'en servir et
économiser un aller-retour de ~44 ms au démarrage de chaque piste.

**Rejeté comme source de vérité.** La taille en base décrit ce qui a été
importé ; `stat()` doit décrire ce qui est **servable maintenant**. S'en
remettre à la base ferait répondre 200 avec un `Content-Length` faux sur un
fichier remplacé, tronqué ou absent — une erreur qui se manifesterait comme
une lecture corrompue chez le client, au pire endroit possible.

Le `HEAD` fait donc autorité. `tracks.sizeBytes` sert de **contrôle croisé** :
un écart est journalisé en `warn` avec `trackId`, taille attendue et taille
observée. C'est un détecteur de dérive gratuit.

L'économie de l'aller-retour est le sujet de la Phase 5, par le cache — pas
par une supposition.

### D3 — Le client HMAC est un portage testé, pas un package partagé

Même arbitrage qu'en Phase 2 pour `path-safety.ts`, et pour les mêmes raisons :
un package partagé ajouterait un troisième workspace TypeScript pour ~80 lignes
de logique figée, et un import direct depuis `services/storage-agent`
introduirait une dépendance du backend vers l'agent — exactement l'inverse du
sens voulu.

Contrepartie rendue explicite et vérifiable : un **fichier de vecteurs de test
partagé**, `services/storage-agent/src/test/hmac-vectors.json`, contenant des
tuples `(secret, méthode, chemin, timestamp, nonce, signature attendue)`. Les
deux implémentations rejouent le même fichier. Toute divergence fait rougir les
deux suites, au lieu de dériver en silence jusqu'à un 401 en production.

### D4 — Aucune reprise automatique en Phase 4

Ni sur `503`, ni sur erreur réseau, ni sur timeout.

Un `503 STREAM_LIMIT_REACHED` signifie « les huit emplacements sont pris ».
Réessayer automatiquement ajoute de la charge au moment précis où la ressource
sature, et transforme une saturation courte en effondrement. Le client mobile
gère déjà ses reprises, et il est mieux placé pour décider.

Pour les erreurs réseau, la raison est différente : on ne sait pas encore à
quelle fréquence elles surviennent sur ce lien. Ajouter une reprise avant
d'avoir mesuré reviendrait à masquer le signal qu'on cherche à obtenir. La
question est **réouverte en Phase 5**, avec des chiffres.

### D5 — `STORAGE_BUSY` est ajouté au contrat d'erreurs

`AudioStorageErrorCode` gagne une valeur. « Le PC est éteint » et « huit flux
sont déjà en cours » produisent tous deux un 503, mais ce sont des situations
opérationnelles opposées : l'une demande d'aller rallumer une machine, l'autre
se résout seule en quelques secondes. Les confondre sous `STORAGE_OFFLINE`
rendrait les journaux inexploitables et le futur cache incapable de décider.

Ajout additif d'une valeur à une union ; aucun consommateur existant ne fait de
`switch` exhaustif dessus.

### D6 — Connexions persistantes, timeouts par phase

Un `http.Agent` avec `keepAlive` dédié au provider. Sur un lien à 44 ms de RTT,
rouvrir une connexion TCP à chaque requête ajouterait un aller-retour complet à
chaque `stat()` et à chaque `createReadStream()`.

Timeouts **par phase**, jamais un timeout global :

| Phase | Valeur proposée | Raison |
| --- | --- | --- |
| Connexion TCP | 3 s | le tunnel est monté ou il ne l'est pas |
| Réception des en-têtes | 10 s | l'agent ne fait qu'un `stat` avant de répondre |
| Inactivité du corps | 30 s | détecte un lien mort |
| Durée totale du corps | **aucune** | un fichier de 30 Mo peut légitimement prendre longtemps ; un timeout global couperait les grosses pistes |

### D7 — `offlineVariantStorage` reste local, sans condition

Déjà le cas et déjà commenté dans `app.ts` : les dérivées hors ligne sont
régénérables et vivent sur la machine qui exécute l'API. Elles ne figurent pas
dans l'index de l'agent et n'ont rien à y faire.

Le point est répété ici parce que c'est l'erreur la plus tentante de la
phase : `createAudioStorageProvider` ne doit **jamais** être appliqué à
`offlineVariantStorage`. Un test le verrouille (§12).

---

## 4. Architecture

```
services/api/src/storage/
├── audio-storage.ts              contrat — +1 code d'erreur (D5)
├── local-file-storage.ts         inchangé
├── provider-factory.ts           case 'remote' câblé
└── remote/
    ├── remote-windows-storage.ts   RemoteWindowsStorageProvider
    ├── storage-agent-client.ts     transport HTTP + keep-alive + timeouts
    ├── hmac-client.ts              signature canonique (D3)
    ├── agent-error-mapping.ts      codes agent -> AudioStorageErrorCode
    └── config.ts                   lecture et validation de la configuration
```

Séparation volontaire entre `remote-windows-storage.ts` (traduction du contrat)
et `storage-agent-client.ts` (transport). Le premier est testable sans réseau,
le second sans connaître `AudioStorageProvider`.

---

## 5. Configuration

Nouvelles variables, toutes validées au démarrage, aucun repli silencieux —
même politique que `parseAudioStorageMode`.

| Variable | Défaut | Contrainte |
| --- | --- | --- |
| `STORAGE_AGENT_BASE_URL` | — | obligatoire si mode `remote` ; `http://` sur IP privée uniquement |
| `STORAGE_AGENT_SHARED_SECRET` | — | obligatoire si mode `remote` ; ≥ 32 caractères |
| `STORAGE_AGENT_CONNECT_TIMEOUT_MS` | `3000` | 500–30000 |
| `STORAGE_AGENT_HEADERS_TIMEOUT_MS` | `10000` | 1000–60000 |
| `STORAGE_AGENT_BODY_IDLE_TIMEOUT_MS` | `30000` | 5000–300000 |
| `STORAGE_AGENT_MAX_SOCKETS` | `8` | 1–64 ; **doit rester ≤ la limite de l'agent** |

Trois règles fermes :

1. **Le secret n'est jamais journalisé**, ni en clair, ni tronqué, ni dans un
   message d'erreur de configuration. Test dédié, comme côté agent.
2. **`STORAGE_AGENT_BASE_URL` est refusée si l'hôte n'est pas une IP privée.**
   Le backend ne doit pas pouvoir être pointé vers une origine arbitraire par
   une variable d'environnement — c'est la règle d'allowlist de `CLAUDE.md`.
3. En mode `local`, aucune de ces variables n'est requise ni lue. Le mode
   `local` ne doit pas pouvoir échouer à cause de la configuration distante.

---

## 6. Mapping des erreurs

| Réponse de l'agent | `AudioStorageErrorCode` | Statut HTTP public | Journal |
| --- | --- | --- | --- |
| `200` / `206` | — | 200 / 206 | nominal |
| `404 TRACK_NOT_INDEXED` | `NOT_FOUND` | 404 | **`INDEX_STALE_SUSPECTED`** si la piste existe en base (D1) |
| `404 FILE_NOT_FOUND` | `NOT_FOUND` | 404 | fichier absent côté PC |
| `400 INVALID_TRACK_ID` | `INVALID_REFERENCE` | 500 | anomalie interne : le backend a émis un identifiant invalide |
| `401` (toutes causes) | `STORAGE_OFFLINE` | 503 | **`AUTH_FAILURE`** — secret désapparié ou horloges désynchronisées |
| `403 SOURCE_IP_DENIED` | `STORAGE_OFFLINE` | 503 | erreur de configuration réseau |
| `416 INVALID_RANGE` | `INVALID_REFERENCE` | 500 | le Range est calculé par la couche HTTP à partir d'un `stat()` : un 416 ici est un bug, pas une entrée utilisateur |
| `503 STREAM_LIMIT_REACHED` | **`STORAGE_BUSY`** | 503 + `Retry-After` | saturation normale |
| `503 INDEX_NOT_LOADED` / `INDEX_INVALID` / `MUSIC_ROOT_UNAVAILABLE` | `STORAGE_OFFLINE` | 503 | agent démarré mais inutilisable |
| `500 STREAM_READ_ERROR` / `INTERNAL_ERROR` | `READ_FAILED` | 500 | — |
| Connexion refusée, timeout, tunnel coupé | `STORAGE_OFFLINE` | 503 | — |

Deux points méritent d'être relevés parce qu'ils sont contre-intuitifs.

**Un 401 devient un 503, pas un 401.** Un échec d'authentification entre le
backend et l'agent n'a rien à voir avec l'utilisateur qui écoute de la musique.
Le lui répercuter en 401 le déconnecterait de l'application pour une panne
d'infrastructure. C'est une indisponibilité de stockage.

**Un 416 venant de l'agent devient un 500.** La couche HTTP calcule le Range à
partir d'une taille que `stat()` vient de fournir. Si l'agent le juge
insatisfaisable, c'est que les deux extrémités ne voient pas le même fichier —
un défaut interne, pas une requête client invalide.

---

## 7. Journalisation

Événements ajoutés, alignés sur les `STREAM_*` existants :

`REMOTE_STORAGE_STAT_STARTED` · `REMOTE_STORAGE_STAT_COMPLETED` ·
`REMOTE_STORAGE_STREAM_OPENED` · `REMOTE_STORAGE_STREAM_CLOSED` ·
`REMOTE_STORAGE_ERROR` · `REMOTE_STORAGE_HEALTH` ·
`REMOTE_STORAGE_SIZE_MISMATCH` (D2) · `REMOTE_STORAGE_INDEX_STALE_SUSPECTED` (D1)

Champs : `trackId`, `agentStatusCode`, `agentErrorCode`, `durationMs`,
`ttfbMs`, `bytesReceived`, `rangeRequested`, `attempt`.

**Jamais journalisés** : secret, signature, nonce, `Authorization`, chemin
absolu, chemin relatif musical, nom de fichier, URL brute. Même discipline que
l'agent, et test dédié.

`ttfbMs` est le chiffre à surveiller : c'est lui qui dira si la Phase 5 doit
précharger, et à quel horizon.

---

## 8. Correction requise dans la couche HTTP

`services/api/src/routes/tracks.ts`, fonction `serveTrackFile` : toute erreur
de `provider.stat()` est aujourd'hui convertie en **404**.

```ts
} catch (error) {
  // ...
  return reply.code(404).send({ statusCode: 404, error: 'not_found', ... });
}
```

Correct pour un disque local, où seule l'absence est plausible. **Faux dès que
le stockage est distant** : un PC éteint deviendrait « fichier introuvable ».
Un client raisonnable purge son cache et abandonne la piste sur un 404, alors
qu'un 503 l'invite à réessayer. C'est le commentaire déjà présent dans
`audio-storage.ts` qui l'annonce :

> « c'est la route qui décide qu'un `NOT_FOUND` devient un 404 et — à partir de
> la Phase 4 — qu'un `STORAGE_OFFLINE` devient un 503 plutôt qu'un 404 »

Changement : la route inspecte `AudioStorageError.code` et applique la colonne
« statut HTTP public » du §6. `STORAGE_BUSY` ajoute un en-tête `Retry-After: 1`,
repris de celui de l'agent.

**Ce changement est sans effet en mode `local`** : `LocalFileStorageProvider`
n'émet ni `STORAGE_OFFLINE` ni `STORAGE_BUSY`. Le comportement public actuel
est donc strictement préservé tant que `AUDIO_STORAGE_MODE=local`, ce qu'un
test vérifie explicitement.

La même correction s'applique à la route de fichier des variantes hors ligne,
qui partage `serveTrackFile`. Sans effet pour elle : son provider est local
(D7).

---

## 9. Streaming, Range et abandon

- `createReadStream(reference, range)` émet un `GET` avec
  `Range: bytes=<start>-<end>`, bornes inclusives des deux côtés — la
  sémantique de `ByteRange` et celle de HTTP coïncident déjà, aucune conversion.
- Sans `range`, aucun en-tête `Range` : représentation complète, `200`.
- Le corps de la réponse **est** le `Readable` retourné. Aucun tampon
  intermédiaire, aucune accumulation en mémoire : la contre-pression de la
  socket cliente se propage jusqu'à la socket de l'agent.
- **Abandon client** : la couche HTTP détruit déjà le flux. Le provider doit
  propager cette destruction en abandonnant la requête sortante, afin que
  l'agent libère son emplacement de streaming immédiatement. Sans cela, huit
  abandons successifs saturent l'agent pour rien. C'est le point de
  correction le plus facile à manquer, et un test dédié le couvre (§12).
- Vérification défensive à l'ouverture : le `Content-Range` renvoyé doit
  correspondre à la plage demandée. Un écart est un `READ_FAILED`, jamais un
  flux servi silencieusement de travers.
- Multi-range : sans objet. La couche HTTP ne demande jamais qu'une plage, et
  l'agent comme l'API publique refusent déjà le multi-range de la même manière.

---

## 10. `healthCheck()`

Appelle `/internal/storage/health` signé et traduit :

| Réponse de l'agent | `StorageHealth` |
| --- | --- |
| `200`, `status: healthy` | `{ status: 'online', source: 'remote', latencyMs }` |
| `200`, `status: degraded` | `{ status: 'degraded', reason: 'racine musicale indisponible' }` |
| `503`, `status: unhealthy` | `{ status: 'offline', reason: 'index non chargé' }` |
| `401` / `403` | `{ status: 'offline', reason: 'authentification refusée' }` |
| Injoignable | `{ status: 'offline', reason: 'agent injoignable' }` |

`latencyMs` est mesuré, pas estimé. Le champ `indexEntryCount` retourné par
l'agent est journalisé : un écart avec le nombre de pistes en base est le
signal d'index périmé le plus direct dont on dispose, et il ne coûte rien.

`reason` est un libellé court et fixe. Jamais un message d'exception, jamais un
chemin.

---

## 11. Ce qui ne change pas

- `LocalFileStorageProvider` : aucune ligne.
- `TrackStorageReference`, `ByteRange`, `AudioFileInfo`, `StorageHealth` :
  aucun changement. Seul `AudioStorageErrorCode` gagne une valeur.
- La base de données : aucun changement de schéma, aucune migration.
- L'ETag reste `tracks.hash`, calculé à l'import. L'agent ne fournit aucune
  empreinte et n'a pas à en fournir.
- Le mobile : aucun changement, ni de code, ni de configuration.
- Caddy, WireGuard, le Storage Agent lui-même : aucun changement.
- `AUDIO_STORAGE_MODE` : reste `local`.

---

## 12. Plan de tests

Aucun test ne doit joindre le vrai agent : tous montent un serveur HTTP local
sur port éphémère, sur le modèle de `services/storage-agent/src/test/harness.ts`.

**Client HMAC** — vecteurs partagés rejoués (D3) ; query string incluse dans la
signature ; méthode normalisée ; nonce ≥ 128 bits et distinct à chaque appel ;
horodatage en secondes ; secret absent de tout message d'erreur.

**Provider** — `stat()` sur HEAD 200 ; `createReadStream()` complet et avec
Range ; propagation des bornes ; vérification du `Content-Range` ; écart de
taille avec la base journalisé sans échec ; chaque ligne du tableau §6 ;
absence de reprise (D4) ; `healthCheck()` sur les cinq cas du §10.

**Abandon et ressources** — la destruction du flux retourné abandonne bien la
requête sortante ; aucune socket laissée ouverte après 50 ouvertures/abandons ;
le pool `keepAlive` est fermé au `onClose` de Fastify.

**Couche HTTP** — `STORAGE_OFFLINE` → 503, `STORAGE_BUSY` → 503 + `Retry-After`,
`NOT_FOUND` → 404, `INVALID_REFERENCE` → 500 ; et surtout : **en mode `local`,
les statuts publics sont identiques à aujourd'hui**, sur la suite `tracks`
existante inchangée.

**Fabrique et configuration** — `remote` construit le provider ; `cached` échoue
toujours ; URL publique refusée ; secret trop court refusé ; mode `local` sans
aucune variable distante démarre normalement.

**Verrou de périmètre** — `offlineVariantStorage` est un
`LocalFileStorageProvider` quel que soit `AUDIO_STORAGE_MODE` (D7).

**Non-régression** — la suite backend reste au vert : 437/437 attendus une fois
le seuil disque confirmé.

---

## 13. Découpage

| Lot | Contenu | Sortie vérifiable |
| --- | --- | --- |
| 1 | `hmac-client.ts` + vecteurs partagés | vecteurs rejoués des deux côtés |
| 2 | `storage-agent-client.ts` : transport, keep-alive, timeouts | tests sur serveur local |
| 3 | `agent-error-mapping.ts` + `STORAGE_BUSY` | tableau §6 couvert ligne à ligne |
| 4 | `remote-windows-storage.ts` | contrat `AudioStorageProvider` satisfait |
| 5 | Configuration + `case 'remote'` | démarrage en `remote` contre un faux agent |
| 6 | Correction des statuts HTTP (§8) | statuts inchangés en `local` |
| 7 | Documentation, `TECH_DECISIONS`, `LESSONS` | — |

Chaque lot est vert avant le suivant. Les lots 1 à 4 ne touchent aucun fichier
existant : le risque de régression n'apparaît qu'aux lots 5 et 6.

---

## 14. Mise en service — hors périmètre Phase 4

Pour mémoire, et pour que la porte soit explicite. Le passage effectif à
`AUDIO_STORAGE_MODE=remote` supposera :

1. la synchronisation automatique de l'index, ou une discipline de
   rafraîchissement manuel assumée (Phase 3 §9) ;
2. une écoute réelle depuis le téléphone : démarrage, seek, piste suivante,
   écran verrouillé ;
3. une session longue, pour observer le comportement du lien WireGuard sur la
   durée ;
4. le TTFB réel mesuré en conditions de lecture, pas seulement sur `/health` ;
5. une procédure de rotation du secret partagé, qui n'existe pas encore et
   devient nécessaire dès que le backend en devient le second porteur.

**Rollback de l'activation :** repasser `AUDIO_STORAGE_MODE` à `local` et
redémarrer le backend. Aucune donnée n'est déplacée par la Phase 4, aucune
migration n'est à annuler.

---

## 15. Risques

| Risque | Gravité | Traitement |
| --- | --- | --- |
| Divergence base ↔ index de l'agent | **Élevée** | D1 ; journal `INDEX_STALE_SUSPECTED` ; écart de comptage exposé par `healthCheck()` |
| Deux allers-retours (HEAD puis GET) à ~44 ms au démarrage de chaque piste | Moyenne | Accepté en Phase 4 (D2) ; c'est l'objet de la Phase 5 |
| Emplacements de streaming fuités sur abandon client | Moyenne | §9 ; test dédié |
| Désynchronisation d'horloge PC ↔ VPS → 401 en masse | Moyenne | Fenêtre de 60 s ; journal `AUTH_FAILURE` distinct ; à surveiller à l'activation |
| Divergence silencieuse des deux implémentations HMAC | Moyenne | Vecteurs partagés (D3) |
| Absence de reprise sur coupure brève du tunnel | Faible | Assumé (D4) ; réévalué en Phase 5 avec des mesures |
| PC éteint = bibliothèque entièrement indisponible | Faible | Propriété du modèle hybride, pas un défaut ; le cache Phase 5 y répond |

---

## 16. À vérifier

1. Le nombre exact d'allers-retours réellement observés au démarrage d'une
   piste depuis le mobile — la mesure de 43,8 ms porte sur `/health`, pas sur
   un `stat()` + ouverture de flux.
2. La dérive d'horloge réelle entre le PC et le VPS sur plusieurs jours, pour
   confirmer que la fenêtre de 60 s est confortable.
3. Le comportement de `undici` / `node:http` en `keepAlive` lorsque le tunnel
   WireGuard tombe puis remonte : les sockets du pool sont-elles correctement
   invalidées, ou faut-il un contrôle de vivacité ?
4. Si `tracks.sizeBytes` est fiable à 100 % sur les 158 pistes actuelles — le
   contrôle croisé de D2 le dira dès les premiers appels.

---

## 17. Implémentation réalisée — 2026-07-26

La Phase 4 est implémentée dans
[`VPS_PHASE4_REMOTE_STORAGE_PROVIDER.md`](VPS_PHASE4_REMOTE_STORAGE_PROVIDER.md).
Le plan reste conservé comme historique de conception. Écarts tranchés :

- variables finales `AUDIO_REMOTE_*` ;
- pool par défaut limité à 8 connexions, aligné sur l'agent, et non 16 ;
- transport `node:http.Agent` keep-alive, sans dépendance ni retry ;
- HMAC comparé directement aux fonctions serveur sur un vecteur déterministe,
  sans package partagé ;
- auth interne et réponse incohérente → 502 public, jamais 401 ;
- ajout contractuel de `X-HS-Error-Code`, nécessaire pour distinguer les erreurs
  HEAD sans corps ;
- HEAD public corrigé pour ne jamais ouvrir de GET/Readable.

`AUDIO_STORAGE_MODE` reste `local`. Aucun déploiement ni changement système
n'appartient à cette implémentation.
