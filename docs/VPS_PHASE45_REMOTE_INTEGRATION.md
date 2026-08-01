# Phase 4.5 — Déploiement coordonné et intégration distante réelle

**Date :** 2026-07-26  
**État :** **GO — PHASE 4.5 VALIDÉE DÉFINITIVEMENT**  
**Périmètre :** synchronisation du Storage Agent installé et validation de
`RemoteWindowsStorageProvider` depuis une API parallèle sur le VPS.

La production reste inchangée :

```text
Téléphone
→ Caddy VPS
→ WireGuard
→ HomeSpotifyApi Windows 10.8.0.2:3000
→ AUDIO_STORAGE_MODE absent/local
```

Ce document ne valide ni le cache de Phase 5, ni une bascule de production.

## 1. État Git et baseline

- HEAD avant intervention :
  `c1384cf3149d1248cb4df6fe2f0422589a5410e2`.
- Dépôt déjà fortement modifié et non commité avant la Phase 4.5.
- `git diff --check` initial : vert, hors avertissements CRLF préexistants.
- API : **490/490** lors de la relance séquentielle.
- Storage Agent : **148/148** après ajout du test de corrélation structurée.
- Tests ciblés Remote/HMAC/mapping : **39/39**.
- Tests du parseur de journaux : **3/3**.
- Tests de régression du harnais : **3/3**.
- Typechecks API et Storage Agent : verts.
- Builds API et Storage Agent : verts.
- `git diff --check` final local : vert.
- Aucun test supprimé, ignoré ou neutralisé.

Une première exécution parallèle des deux suites a fait échouer la suite API
sans synthèse exploitable, alors que la relance séquentielle a donné 490/490.
Ce comportement est classé comme contention du harnais et non comme régression
fonctionnelle ; les validations finales doivent rester séquentielles.

## 2. Matrice de compatibilité

Comparaison binaire entre
`C:\ProgramData\HomeSpotify\StorageAgent\app\dist` et le build Phase 4 avant
déploiement :

| Élément | Agent installé avant | Code Phase 4.5 | Compatibilité |
| --- | --- | --- | --- |
| Fichiers `dist` | 20 | 20 | identique |
| Fichiers différents | `server.js` + source map | `server.js` + source map | attendu |
| Routes health/HEAD/GET | présentes | inchangées | compatible |
| Statuts HTTP | contrat Phase 3 | inchangés | compatible |
| Corps JSON d'erreur | contrat Phase 3 | inchangés | compatible |
| HMAC | Phase 3 | inchangé | compatible |
| HEAD sans corps | oui | oui | compatible |
| GET complet et Range | oui | inchangé | compatible |
| Health | oui | inchangé | compatible |
| `X-HS-Error-Code` | absent | ajouté | additif |

Le diff JavaScript initial ne contenait qu'une instruction fonctionnelle :

```text
reply.header('x-hs-error-code', code)
```

L'audit contractuel a ensuite trouvé deux réponses 416 construites directement,
hors de `sendError`. Le header `X-HS-Error-Code: INVALID_RANGE` a été ajouté
sur ces chemins HEAD et GET, sans modifier le statut 416, le corps vide,
`Content-Range` ou `Accept-Ranges`.

## 3. Empreintes avant déploiement

| Artefact | SHA-256 `dist/server.js` |
| --- | --- |
| Agent installé Phase 3 | `9C4750401266E12137A74C63951141CDF9B98BBA9A03F1CC90E7DD12D4101806` |
| Candidat Phase 4.5 | `35131B1935B1A336418E0893C8E38FF94BA8738C530D7681F163774D95EF6318` |

Le candidat et `services/storage-agent/dist/server.js` ont la même empreinte.

## 4. Sauvegarde et rollback

Une sauvegarde hors secret a été créée avant toute tentative élevée :

```text
storage/phase45-predeploy-backup-20260726-1533/
├── installed-app.zip
└── HomeSpotifyStorageAgent.xml
```

Contrôles :

- archive lisible : **2 047 entrées** ;
- `app\dist\main.js` présent ;
- `app\node_modules\fastify\package.json` présent ;
- XML WinSW présent ;
- aucun `agent.env` copié.

Le script élevé
`scripts/deploy_storage_agent_phase45.ps1` crée en complément, sous le dossier
de sauvegarde système :

- une copie exploitable de l'ancien `app` ;
- le XML WinSW ;
- uniquement longueur, dates, propriétaire, SDDL et état d'héritage de
  `agent.env` — jamais son contenu ;
- les métadonnées et l'empreinte de l'index, sans le modifier ;
- les PID et listeners avant intervention.

Le rollback arrête et redémarre uniquement `HomeSpotifyStorageAgent`. Il remet
l'ancien dossier `app` puis exige service, identité, listener et événements de
démarrage sains.

## 5. Nouvel artefact

Artefact construit avec la méthode Phase 3 :

```text
storage/phase45-artifact/
├── dist/
├── node_modules/       dépendances de production copiées
├── package.json        manifeste minimal
└── package-lock.json
```

- 2 040 fichiers ;
- 7,3 Mo ;
- Fastify 5.10.0 épinglé ;
- aucun lien vers le store pnpm ;
- aucun `tsx`, Vitest, watcher ou secret ;
- suite agent exécutée pendant la construction : 147/147.

Le premier essai a échoué avant publication car le compte sandbox ne pouvait
pas créer `D:\Node\npm-cache`. La relance a utilisé
`storage/phase45-npm-cache`, sans changer le contenu ni les versions.

## 6. Déploiement Windows

### État avant

| Élément | Valeur |
| --- | --- |
| WireGuard | Running, PID 4640 |
| HomeSpotifyApi | Running, PID WinSW 19504 |
| Storage Agent | Running, PID WinSW 15920 |
| Identité agent | `NT SERVICE\HomeSpotifyStorageAgent` |
| Dépendances | `Tcpip`, `WireGuardTunnel$HomeSpotify-VPS` |
| Listener API | `0.0.0.0:3000`, PID Node 7236 |
| Listener agent | uniquement `10.8.0.2:3100`, PID Node 17340 |
| Backend local | 200 |
| Domaine public | 200, vérifié avec `fetch` Node |

### État après déploiement coordonné

Le déploiement élevé a été exécuté par l'utilisateur. Les contrôles directs
post-déploiement ont confirmé :

- hash installé identique au candidat Phase 4.5 :
  `35131B1935B1A336418E0893C8E38FF94BA8738C530D7681F163774D95EF6318` ;
- `X-HS-Error-Code` présent dans l'artefact installé ;
- `HomeSpotifyStorageAgent` Running sous
  `NT SERVICE\HomeSpotifyStorageAgent` ;
- listener unique `10.8.0.2:3100` ;
- `HomeSpotifyApi` Windows restée Running ;
- backend local et domaine public à 200 ;
- aucun changement Caddy, WireGuard ou pare-feu.

## 7. Tests `X-HS-Error-Code`

La suite locale couvre explicitement :

| Code | Statut conservé | Header testé |
| --- | ---: | --- |
| `TRACK_NOT_INDEXED` | 404 | oui |
| `FILE_NOT_FOUND` | 404 | oui |
| `INDEX_NOT_LOADED` | 503 | oui |
| `MUSIC_ROOT_UNAVAILABLE` | 503 | oui |
| `STREAM_LIMIT_REACHED` | 503 | oui |
| `AUTH_INVALID` | 401 interne | oui |
| `INVALID_RANGE` | 416 | oui, HEAD et GET |

HEAD reste sans corps. Les tests existants d'absence de fuite de chemin, nom
de fichier et secret restent actifs.

L'agent réellement installé a confirmé les codes représentatifs
`INVALID_RANGE`, `TRACK_NOT_INDEXED` et `AUTH_INVALID`. La suite locale couvre
également `FILE_NOT_FOUND`, `INDEX_NOT_LOADED`, `MUSIC_ROOT_UNAVAILABLE` et
`STREAM_LIMIT_REACHED`, sans changement des statuts ni exposition de détail
système.

## 8. Accès VPS et smoke test

L'authentification SSH non interactive par clé fonctionne depuis la session
utilisateur Windows :

```text
ssh -o BatchMode=yes debian@135.125.101.79
```

Le sandbox Codex n'a volontairement aucun accès à la clé privée. Le harnais est
donc exécuté depuis la session PowerShell administrateur de l'utilisateur, sans
lecture ni copie de la clé par Codex.

Validations obtenues :

- smoke test réel `scripts/vps_storage_agent_smoke_test.py` : **23/23** ;
- headers d'erreur représentatifs validés contre l'agent installé ;
- secret temporaire créé en mode 600, absent de la commande et de
  l'historique, puis supprimé.

## 9. API parallèle VPS et copie SQLite

### Premier lancement et incident

La première exécution réelle a transféré l'artefact, créé les fichiers secrets
en mode 600 et installé 125 dépendances, puis l'API 3001 a quitté avant son
health check. Le nettoyage a confirmé zéro secret et zéro listener résiduel.

Cause identifiée dans l'assemblage : le code compilé
`dist/db/migrate.js` résout `../../drizzle`, mais l'artefact ne contenait pas
ce dossier. Drizzle lève dans cette situation :

```text
Can't find meta/_journal.json file
```

Le premier harnais redirigeait stdout et stderr vers un seul `api.log`, puis
retournait seulement `API_3001_EXITED` sans relire ce fichier.

### Correction du harnais

- ajout des 31 fichiers `drizzle/` à l'artefact ;
- prérequis local et VPS explicite sur `drizzle/meta/_journal.json` ;
- stdout/stderr séparés pour les ports 3001 et 3002 ;
- PID, état du processus, code de sortie et listener consignés ;
- préflight Node/npm, point d'entrée, hash, syntaxe, package, migration,
  chargement natif `better-sqlite3`, SQLite RW/intégrité, permissions WAL,
  ports et noms de variables ;
- diagnostic limité aux 200 dernières lignes, après expurgation des secrets,
  tokens, signatures, nonces et chemins Windows ;
- trap Bash : diagnostic d'abord, puis arrêt des processus et suppression des
  `.env` et du secret ;
- rapatriement en liste blanche sous
  `.phase45-diagnostics/<horodatage>/`, dossier ignoré par Git.

L'exécution suivante a validé le démarrage effectif des deux API parallèles.
Cet incident est clos.

### Incident de quoting au second lancement

La seconde exécution a confirmé que les deux API parallèles démarrent avec
l'artefact corrigé. Elle s'est ensuite arrêtée avant le smoke test : le code
Python passé dans `python3 -c` a perdu ses guillemets entre PowerShell, SSH et
le shell distant. Le cleanup a de nouveau confirmé zéro secret et zéro
listener.

Correction :

- `vps_phase45_state_value.py` lit une clé entière autorisée depuis le JSON ;
- `vps_phase45_run_smoke.sh` exécute le smoke depuis un vrai fichier ;
- `vps_phase45_run_provider_test.sh` exécute les tests full/offline ;
- aucun `TRACK_ID` ni code JSON n'est construit dans la commande SSH ;
- smoke borné à 180 s, provider full à 240 s, offline à 60 s ;
- chaque requête HTTP est bornée à 20 s et le flux complet à 120 s ;
- sorties Python non bufferisées et marqueurs de progression explicites ;
- traps Bash avec script, ligne, étape, commande et code de sortie non sensible.

La validation finale a respecté :

- bind `127.0.0.1:3001` ;
- aucun bloc Caddy et aucun port public ;
- copie SQLite produite par la Backup API existante, jamais par copie brute du
  fichier actif ;
- base de validation séparée ;
- imports, acquisition, tâches planifiées et sauvegardes automatiques
  désactivés ;
- aucune écriture vers la bibliothèque ou la base Windows de production ;
- configuration distante dans un fichier mode 600 ;
- `AUDIO_REMOTE_MAX_CONNECTIONS=8`.

## 10. Tests réels et métriques

La troisième exécution réelle a validé :

- smoke Storage Agent : **23/23**, index 158, latence health moyenne 37,1 ms ;
- provider distant : **36 contrôles OK, 0 échec, 3 skips sûrs** ;
- HEAD, GET complet de 9 165 881 octets et hash exact ;
- Range 0-1023, N-, suffixe et Range invalide 416 ;
- fichier SQLite absent 404, index périmé 503, HMAC interne 502 ;
- aucun 401 interne ni header interne exposé publiquement ;
- `INVALID_RANGE`, `TRACK_NOT_INDEXED`, `AUTH_INVALID` côté agent ;
- keep-alive, abandon propagé, `activeStreams=0` après abandon ;
- saturation `STREAM_LIMIT_REACHED=503`, puis zéro slot occupé ;
- RSS API : environ +1 052 Kio ;
- mémoire maximale Storage Agent : 61,7 Mio ;
- TTFB HEAD 54,0 ms, Range 52,2 ms, GET complet 49,6 ms ;
- débit complet : 28,895 Mio/s ;
- cleanup : zéro secret et zéro listener parallèle.

Le seul échec était le contrôle final du requestId. L'audit ultérieur du journal
réel a trouvé **67 événements JSON exacts** avec
`phase45-remote-propagation`, dont des événements
`STORAGE_AGENT_REQUEST_COMPLETED` HEAD/GET réussis. Le header avait donc bien
traversé route publique, provider, client HMAC et `genReqId` Fastify.

Cause : le harnais effectuait une seule recherche textuelle immédiatement après
le test, avec un filtre `LastWriteTime`. L'écriture WinSW est devenue visible
après ce contrôle.

Correction :

- requestId unique par exécution ;
- parsing JSON exact du champ `requestId` ;
- événement terminal réussi et statut 200/206 obligatoires ;
- support des logs courants/rotatifs et préfixes WinSW ;
- dix tentatives maximum, espacées de 500 ms ;
- mode ciblé `-RequestIdOnly`, une seule API localhost et une seule HEAD,
  sans `npm install`, saturation, flux complet ou arrêt de l'agent.

### Contrôle ciblé requestId final

Le mode ciblé a ensuite été exécuté avec succès :

- domaine public avant test : 200 ;
- API parallèle liée uniquement à `127.0.0.1:3001` ;
- aucun `npm install` ;
- HEAD distant : 200, corps vide ;
- TTFB ciblé : **86,4 ms** ;
- `responseRequestIdMatched=true` ;
- `internalHeaderExposed=false` ;
- requestId :
  `phase45-requestid-20260726T192509523-00ed8c22` ;
- corrélation confirmée dès la première tentative dans
  `HomeSpotifyStorageAgent.out.log` ;
- événement terminal réel `STORAGE_AGENT_REQUEST_COMPLETED`, méthode HEAD,
  `trackId=78`, `statusCode=200` ;
- cleanup : `remainingSecretFiles=0`, `remainingListeners=0` ;
- production intacte.

Cette preuve ferme le dernier défaut du harnais : le requestId public traverse
bien la route, `RemoteWindowsStorageProvider`, le client HMAC et Fastify, puis
est persisté dans un événement terminal structuré de l'agent.

## 11. Nettoyage

À la fin des tests :

- API parallèle arrêtée ;
- zéro listener 3001/3002 restant ;
- zéro secret temporaire restant ;
- seuls des journaux non sensibles ont été conservés ;
- Caddy, WireGuard, le pare-feu, HomeSpotifyApi Windows et la production locale
  sont restés inchangés.

## 12. Risques et verdict

| Risque | État |
| --- | --- |
| Agent installé encore antérieur au header | fermé |
| Rollback agent | prêt et artefact précédent sauvegardé |
| SSH VPS non interactif | disponible depuis la session utilisateur |
| Artefact API sans migrations | corrigé et validé sur le VPS |
| Chaîne fonctionnelle distante | validée, 36/36 |
| Corrélation requestId | validée dès la tentative 1 sur un événement terminal réel |
| Provider sur le vrai tunnel | validé, 36/36 avec 3 skips volontaires documentés |
| API parallèle et base cohérente isolée | validées pendant l'exécution réelle, puis arrêtées et nettoyées |
| Production basculée par erreur | absent — elle reste locale |

## 13. Verdict définitif

**GO — PHASE 4.5 VALIDÉE DÉFINITIVEMENT**

`RemoteWindowsStorageProvider` est validé en conditions réelles à travers
WireGuard avec HMAC, HEAD, GET, Range, keep-alive, backpressure, abandon client,
saturation réelle et mappings 404/416/502/503. Aucun 401 interne ni
`X-HS-Error-Code` n'est exposé au client public. La corrélation requestId est
prouvée dans un événement terminal réel de l'agent.

La production n'a pas été basculée : `AUDIO_STORAGE_MODE` reste absent/local,
HomeSpotifyApi continue de fonctionner sur Windows et Caddy continue de cibler
`10.8.0.2:3000`. Aucun secret, listener parallèle ou processus de validation
ne subsiste. Aucun changement Caddy, WireGuard ou pare-feu n'a été effectué.
Aucun commit n'a été créé.

## 14. Préparation de la Phase 5 — sans implémentation

Objectif proposé : ajouter un cache audio borné comme décorateur du provider
distant afin de réduire le coût des HEAD/GET répétés, sans changer le contrat
public ni l'adressage exclusivement par `trackId`.

Prérequis proposés :

1. définir les limites disque, l'éviction et la validation par `contentHash` ;
2. conserver streaming, Range, backpressure et annulation de bout en bout ;
3. garantir qu'un échec du cache ne masque jamais une erreur distante typée ;
4. mesurer le gain sur TTFB, débit, mémoire et charge Windows avec le même
   protocole Phase 4.5 ;
5. prévoir un rollback logiciel vers `remote` ou `local` sans mutation de
   données ni changement réseau.

La Phase 5 n'est pas commencée par cette clôture.
