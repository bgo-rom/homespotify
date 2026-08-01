# Phase 1.5 — Revue de l'abstraction et inventaire Windows

**Date :** 2026-07-25
**Nature :** mission de validation intermédiaire, **lecture seule** côté système.
**Verdict : GO** pour la Phase 2 (Storage Agent Windows), sous les réserves du §11.

Aucun service n'a été redémarré, aucune règle de pare-feu modifiée, aucun tunnel
touché, aucun déploiement effectué, aucun commit créé.

---

## 1. Revue de l'implémentation Phase 1

| # | Point vérifié | Résultat | Preuve |
|---|---|---|---|
| 1 | `serveTrackFile` n'accède plus à un chemin absolu | ✅ | Signature `(request, reply, provider, reference, contentType, disposition?)` ; plus aucun `absPath`, plus aucun `join(musicDir, …)` dans la fonction |
| 2 | Toute résolution physique passe par le provider | ✅ | `provider.stat()` et `provider.createReadStream()` ; `resolvePath()` est privé au provider local |
| 3 | Normalisation centralisée | ✅ | `toPortableRelativePath()` est le seul point de conversion ; `trackStorageReference()` est le seul constructeur depuis une ligne `tracks` |
| 4 | Anti-traversal correct | ✅ | Deux barrières : rejet de `..`/absolu/UNC à la construction, puis contrôle de confinement `candidate.startsWith(root + sep)` après `resolve()` — le `+ sep` élimine le piège du préfixe (`<root>-autre`) |
| 5 | La factory refuse les modes inconnus | ✅ | `parseAudioStorageMode()` lève `AudioStorageConfigError` ; aucun repli sur `local` |
| 6 | `remote` et `cached` échouent explicitement | ✅ | `createAudioStorageProvider()` lève, avec le numéro de phase dans le message |
| 7 | Absence de `AUDIO_STORAGE_MODE` → `local` | ✅ | `undefined`, `''` et `'   '` → `local` (testé) |
| 8 | `offlineVariantStorage` volontairement séparé | ✅ | Décoration distincte dans `app.ts`, racine `offline.derivedCacheDir` ; les dérivées ne transiteront jamais par l'agent distant |
| 9 | Aucun contrat HTTP changé | ✅ | Voir §3 : mêmes statuts, mêmes en-têtes, mêmes événements `STREAM_*` |
| 10 | Aucun fallback silencieux dangereux | ✅ | Voir la réserve ci-dessous |

### Réserve n° 1 — les erreurs de stockage sont toutes converties en 404

`serveTrackFile` transforme **toute** `AudioStorageError` en `404 not_found`, y
compris `PATH_TRAVERSAL`, `READ_FAILED` et le futur `STORAGE_OFFLINE`. Le code
d'erreur est bien journalisé (`STREAM_FILE_ERROR` avec `errorCode`), donc rien
n'est perdu pour le diagnostic, et ce comportement est **identique à celui
d'avant la Phase 1**. Ce n'est donc pas une régression.

C'est en revanche un **prérequis explicite de la Phase 4** : quand le PC Windows
est éteint, l'API doit répondre `503`, pas `404` — un 404 pousserait le client
mobile à considérer la piste comme supprimée. Le mapping code → statut devra
être introduit **avant** la mise en service du mode `remote`.

### Réserve n° 2 — `INVALID_REFERENCE` lève avant d'entrer dans `serveTrackFile`

`trackStorageReference(track)` est appelé **dans la route**, hors de tout
`try`. Une ligne `tracks` dont le `path` serait absolu ou vide ferait remonter
une exception → `500`, pas `404`. Aujourd'hui le risque est nul (158/158 chemins
relatifs Windows validés), mais un import futur produisant un chemin absolu
transformerait une piste isolée en erreur 500. Coût de correction : un `try`
autour de la construction. **Non corrigé dans cette mission** (hors périmètre :
c'est un changement de comportement, pas une vérification).

---

## 2. Transport du hash de la piste

**Question :** `serveTrackFile` recevait `track.hash` en paramètre explicite ;
où est-il passé ?

| Étape | Avant Phase 1 | Après Phase 1 |
|---|---|---|
| Source | `track.hash` (colonne `tracks.hash`, SHA-256) | identique, inchangée |
| Transport | 5ᵉ paramètre `hash: string` | champ `contentHash` de `TrackStorageReference` |
| Construction | `serveTrackFile(…, track.id, path, track.hash, …)` | `trackStorageReference(track)` → `{ trackId, relativePath, contentHash }` |
| Utilisation dans la route | `reply.header('etag', '"' + hash + '"')` | `const hash = reference.contentHash;` puis **la même ligne** |

Réponses précises aux questions posées :

- **Inclus dans `TrackStorageReference` ?** Oui — champ `contentHash`, obligatoire.
- **Retourné par `AudioFileInfo` ?** **Non**, et c'est délibéré : `AudioFileInfo`
  décrit le fichier physique (`sizeBytes`, `modifiedAt`, `source`), pas
  l'identité logique du contenu. Le hash vient de la base, jamais du stockage.
- **Encore utilisé par la route ?** Oui, exclusivement pour l'ETag.
- **La suppression du paramètre explicite a-t-elle changé un comportement ?**
  **Non.** L'ETag est bit-à-bit identique (`"<sha256>"`), et un test le verrouille
  désormais contre le champ `etag` exposé par `GET /api/tracks`.

Pour les variantes hors ligne, `offline.ts` construit la référence à la main avec
`contentHash: variant.sha256` : l'ETag reste le SHA-256 **de la dérivée**, comme
avant.

---

## 3. Parité des validateurs HTTP

Mesuré par test automatisé, pas déduit de la lecture.

| En-tête / mécanisme | Émis ? | Honoré en entrée ? | Avant Phase 1 | Statut |
|---|---|---|---|---|
| `etag` (`"<sha256>"`) | ✅ | — | ✅ identique | parité |
| `last-modified` (mtime du fichier) | ✅ | — | ✅ identique | parité |
| `accept-ranges: bytes` | ✅ | — | ✅ | parité |
| `cache-control: private, max-age=3600` | ✅ | — | ✅ | parité |
| `content-range`, `content-length` | ✅ | — | ✅ | parité |
| `If-None-Match` | — | ❌ **ignoré** → 200 complet | ❌ déjà ignoré | parité |
| `If-Modified-Since` | — | ❌ ignoré | ❌ déjà ignoré | parité |
| `If-Range` | — | ❌ **ignoré** → 206 même avec validateur périmé | ❌ déjà ignoré | parité |
| `If-Match` / `304` | — | ❌ | ❌ | parité |

**Conclusion : aucune revalidation conditionnelle n'existe sur les routes audio,
ni avant ni après la Phase 1.** La seule route du backend qui gère un `304` est
`/api/sync` (`routes/sync.ts`), sans rapport avec le streaming.

Le cas `If-Range` ignoré est un écart à la RFC 9110 : si le fichier changeait
entre deux requêtes, un client reprenant un téléchargement recevrait un 206
recollant deux contenus différents. Le risque réel est faible (un réimport change
le hash **et** le chemin), mais il devient concret dès que le cache VPS
(Phase 5) sert des octets d'une génération antérieure. **Signalé, non corrigé** :
la mission interdit d'introduire une fonctionnalité HTTP nouvelle.

Ces comportements sont désormais **verrouillés par des tests** (§9), pour que
l'écriture du Storage Agent ne les modifie pas par accident.

---

## 4. Comportement HEAD

**HEAD `/api/tracks/:id/stream` est supporté**, via `exposeHeadRoutes` (défaut
Fastify 5) : aucune route HEAD n'est déclarée explicitement dans le code, Fastify
en génère une pour chaque GET et supprime le corps de la réponse.

Mesures (harness de test `app.inject`, aucun token de production) :

| Cas | Statut | En-têtes | Corps |
|---|---|---|---|
| HEAD sans Bearer | **401** | `x-request-id` conservé | vide |
| HEAD authentifié, piste existante | **200** | `etag`, `last-modified`, `accept-ranges`, `content-length`, `content-type` — **identiques au GET** | vide |
| HEAD authentifié, piste absente | **404** | JSON d'erreur annoncé, corps supprimé | vide |
| HEAD + `Range: bytes=0-3` | **206** | `content-range: bytes 0-3/<size>`, `content-length: 4` | vide |
| HEAD + Range hors bornes | **416** | `content-range: bytes */<size>` | vide |
| HEAD `/download` | **200** | + `content-disposition` | vide |

- **Authentification exigée :** oui, le `preHandler` s'applique à la route HEAD
  générée (401 vérifié).
- **Corps réellement absent :** oui, `rawPayload.length === 0` dans les six cas.
- **Ouvre-t-elle un flux de fichier inutilement ?** **OUI.** `serveTrackFile`
  appelle systématiquement `provider.createReadStream()` avant de rendre la
  réponse ; sur HEAD, le flux est ouvert puis jeté. Sur disque local le coût est
  négligeable. **Sur le Storage Agent distant, ce sera une requête HTTP complète
  vers le PC Windows pour un corps qui sera jeté** — voir §10, prérequis P4.

---

## 5. Service Windows

| Champ | Valeur |
|---|---|
| Nom | `HomeSpotifyApi` (« HomeSpotify API ») |
| État | `Running` / `Status: OK` |
| Type de démarrage | `Auto` + `delayedAutoStart` |
| Compte d'exécution | **`LocalSystem`** |
| PID wrapper (WinSW) | 33160 — `HomeSpotifyApi.exe`, WS 18,3 Mo, 290 handles |
| PID Node | **34216** |
| Exécutable Node | `C:\Program Files\nodejs\node.exe` (lu dans `HomeSpotifyApi.xml`) |
| Arguments | `F:\dev\homespotify\services\api\dist\server.js` |
| Répertoire de travail | `F:\dev\homespotify\services\api` |
| Environnement service | `NODE_ENV=production`, `HOST=0.0.0.0`, `PORT=3000` |
| Politique d'échec | `restart` après 10 s, compteur remis à zéro après 1 h |
| Journaux | `infra\windows-service\homespotify-api\logs` (mode `roll`) |

`ExecutablePath` et `CommandLine` du processus Node sont **vides via WMI en
console non-administrateur** (processus `LocalSystem`) : la valeur ci-dessus vient
du fichier de configuration WinSW, pas d'une supposition. Pour l'obtenir depuis
le processus lui-même, relancer le script d'inventaire en PowerShell
**administrateur** (§7).

---

## 6. Mémoire et charge du processus Node

Relevé le 2026-07-25 à 18:47, service démarré le 2026-07-25 à 15:42:07
(~3 h 05 d'activité) :

| Métrique | Valeur |
|---|---|
| Working Set | **86,7 Mo** |
| Private Bytes | **131,1 Mo** |
| Handles | 279 |
| CPU cumulé | ~7,6 s (kernel 2,23 s + user 5,36 s) |
| Connexions actives sur 3000 | 0 |

Empreinte faible et stable : un Storage Agent Node séparé sur la même machine
n'entre pas en concurrence mémoire significative. **Note :** ce relevé est pris
au repos (aucun streaming en cours) ; il ne dit rien du pic mémoire sous charge.

---

## 7. Port 3000 — écoute et accessibilité

- **Socket d'écoute :** `0.0.0.0:3000` (PID 34216) → **toutes les interfaces**,
  conséquence directe de `HOST=0.0.0.0` dans la configuration WinSW.
- **Connexions actives :** aucune au moment du relevé.

Interfaces IPv4 de la machine :

| Interface | Adresse | Profil réseau Windows |
|---|---|---|
| Wi-Fi | 192.168.1.153/24 | **Public** |
| **HomeSpotify-VPS** (WireGuard) | **10.8.0.2/32** | **Public** |
| Radmin VPN | 26.0.244.248/8 | Public |
| Tailscale | 169.254.83.107/16 | Private |
| Ethernet, liens locaux | 169.254.x.x | — |
| Loopback | 127.0.0.1/8 | — |

### Règles de pare-feu pertinentes

| Nom | Act. | Dir. | Action | Profil | Proto | Port local | Adresse distante | Programme |
|---|---|---|---|---|---|---|---|---|
| **HomeSpotify API via WireGuard** | Oui | Entrant | Allow | Any | TCP | 3000 | **10.8.0.1** | Any |
| **HomeSpotify API 3000** | Oui | Entrant | Allow | **Private** | TCP | 3000 | Any | Any |
| **Node.js JavaScript Runtime** | Oui | Entrant | Allow | Private, Public | TCP | **Any** | Any | `C:\program files\nodejs\node.exe` |
| Node.js JavaScript Runtime | Oui | Entrant | Allow | Private, Public | UDP | Any | Any | idem |
| WireGuard — Ping depuis VPS | Oui | Entrant | Allow | Any | ICMPv4 | — | 10.8.0.1 | Any |

Les trois profils de pare-feu sont **activés**, `DefaultInboundAction` à
`NotConfigured` (= blocage entrant par défaut sous Windows).

### Accessibilité effective du port 3000

| Origine | Accessible ? | Par quelle règle |
|---|---|---|
| localhost (127.0.0.1) | ✅ | boucle locale, non filtrée |
| VPS via WireGuard (10.8.0.1 → 10.8.0.2) | ✅ | « HomeSpotify API via WireGuard » |
| LAN Wi-Fi (192.168.1.0/24) | ⚠️ **OUI** | **« Node.js JavaScript Runtime »**, profil Public, TCP tous ports |
| Toutes interfaces | ⚠️ **OUI** pour tout réseau où une interface est en profil Public ou Private | idem |

### Réserve n° 3 — la règle générique Node.js annule le cloisonnement

La règle nominative « HomeSpotify API 3000 » est limitée au profil **Private**,
et l'interface Wi-Fi est en profil **Public** : cette règle-là ne devrait donc
pas ouvrir le LAN. Mais la règle **« Node.js JavaScript Runtime » autorise
`node.exe` en entrée sur TCP/UDP, tous ports, profils Private ET Public** — et le
service tourne précisément avec `C:\Program Files\nodejs\node.exe`. Le port 3000
est donc joignable depuis le LAN Wi-Fi, quelle que soit l'intention des règles
nominatives.

Conséquence directe pour la Phase 2 : **une règle nominative limitée à 10.8.0.1
sur le port 3100 ne suffira pas à confiner le Storage Agent** s'il est lancé avec
le même `node.exe`. Il faudra soit désactiver la règle générique Node.js, soit
faire écouter l'agent uniquement sur `10.8.0.2` (bind d'adresse, pas `0.0.0.0`),
soit les deux. **Aucune modification n'a été faite dans cette mission.**

---

## 8. Interface WireGuard

| Champ | Valeur |
|---|---|
| Nom | **HomeSpotify-VPS** (`WireGuard Tunnel`, ifIndex 52) |
| État | **Up**, adresse `Preferred` |
| Adresse locale | **10.8.0.2/32** — confirmée |
| Route vers le pair | `10.8.0.1/32`, métrique de route 0, métrique d'interface 5 |
| Route locale | `10.8.0.2/32`, métrique 256 |
| Profil réseau Windows | **Public** |
| MTU rapporté | 2147483552 (valeur sentinelle du pilote, non exploitable) |
| Latence vers 10.8.0.1 | min 20 ms / moy 21,8 ms / max 25 ms |
| Stabilité sur 10 pings | **10/10 reçus, 0 % de perte** |

Aucune clé (PrivateKey, PresharedKey, PublicKey) n'a été lue ni affichée.

---

## 9. Script d'inventaire et tests

### Script

`scripts/windows_phase15_inventory.ps1` — strictement en lecture seule
(`Get-*` et `Test-Connection` uniquement ; aucune création/modification de règle,
aucun `Start`/`Stop`/`Restart`), caviardage des motifs `PrivateKey`,
`PresharedKey`, `PublicKey`, `secret`, `token`, `password`, `api_key` et des
clés base64 de 44 caractères.

Exécuté avec succès en console **non-administrateur** ; sortie :
`C:\Users\rtuyi\Desktop\HomeSpotify-Windows-Phase15.txt`.

Pour obtenir en plus `ExecutablePath`, `CommandLine` et `StartTime` du processus
Node (`LocalSystem`), relancer en **PowerShell administrateur** :

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File "F:\dev\homespotify\scripts\windows_phase15_inventory.ps1"
```

Deux pièges rencontrés et corrigés dans le script (voir `LESSONS.md`) :
le fichier doit porter un **BOM UTF-8** pour que PowerShell 5.1 ne lise pas les
accents en ANSI, et **l'apostrophe typographique `’` est un délimiteur de chaîne
valide en PowerShell** — elle casse le parsing dans un littéral.

### Tests ajoutés

8 tests ajoutés à `services/api/src/tracks.test.ts`
(`describe('HEAD /api/tracks/:id/stream et validateurs de cache')`) :
HEAD non authentifié → 401 ; HEAD authentifié → 200 avec en-têtes identiques au
GET et corps vide ; HEAD sur piste absente → 404 ; HEAD + Range → 206 ;
HEAD + Range hors bornes → 416 ; ETag = SHA-256 identique sur `stream` et
`download` ; `If-None-Match` non honoré ; `If-Range` non honoré.

Ces tests **verrouillent l'existant** ; aucun comportement HTTP n'a été ajouté ni
modifié.

| Vérification | Résultat |
|---|---|
| Suite backend complète | **427/427** (40 fichiers) — baseline Phase 1 : 419/419 |
| Typecheck (`tsc --noEmit`) | ✅ |
| Build (`tsc -p tsconfig.json`) | ✅ |
| `git diff --check` | ✅ aucun problème d'espaces |
| Flutter | **non exécuté** — aucun contrat partagé modifié |

---

## 10. Recommandations et prérequis exacts pour la Phase 2

| # | Prérequis | État |
|---|---|---|
| P1 | Interface `AudioStorageProvider` stabilisée (`stat`, `createReadStream(range)`, `healthCheck`) | ✅ acquis Phase 1 |
| P2 | Port de l'agent : **3100**, écoute **liée à 10.8.0.2** — pas `0.0.0.0` | à faire |
| P3 | Règle de pare-feu entrante TCP 3100 limitée à `RemoteAddress = 10.8.0.1` **et** neutralisation ou contournement de la règle générique « Node.js JavaScript Runtime » (§7, réserve 3) | à faire |
| P4 | Contrat `HEAD` de l'agent : le backend doit pouvoir obtenir taille + mtime **sans** ouvrir de flux — soit un court-circuit `HEAD` dans `serveTrackFile`, soit un endpoint `stat` distinct côté agent | à faire |
| P5 | Secret partagé `HOMESPOTIFY_STORAGE_SHARED_SECRET` ≥ 32 octets, hors Git, injecté par l'environnement du service | à faire |
| P6 | Mapping `AudioStorageErrorCode` → statut HTTP (`STORAGE_OFFLINE` → **503**, pas 404) avant activation du mode `remote` | à faire (Phase 4 au plus tard) |
| P7 | Le hash reste fourni par la base : l'agent **ne doit pas** être une source d'ETag | ✅ garanti par le contrat |
| P8 | Les variantes hors ligne restent servies par `offlineVariantStorage` local | ✅ acquis Phase 1 |

Recommandation d'ordre : P2 + P3 (réseau) avant tout code d'agent — c'est le
seul point où l'état actuel de la machine est plus permissif que ce que le plan
suppose.

---

## 11. Risques restants

1. **Cloisonnement réseau plus faible qu'attendu** (§7, réserve 3) : le port 3000
   est aujourd'hui joignable depuis le LAN Wi-Fi. À traiter avant d'ouvrir 3100.
2. **`STORAGE_OFFLINE` → 404** (§1, réserve 1) : dangereux à partir du mode
   `remote`, sans effet aujourd'hui.
3. **`INVALID_REFERENCE` → 500** (§1, réserve 2) : latent, dépend d'un futur
   import produisant un chemin absolu.
4. **`If-Range` ignoré** (§3) : sans conséquence en local, devient réel avec le
   cache VPS de la Phase 5.
5. **HEAD ouvre un flux inutile** (§4) : gaspillage négligeable en local, coût
   réseau réel une fois l'agent distant en place.
6. **Mémoire relevée au repos** (§6) : le pic sous streaming concurrent n'est pas
   connu.
7. **Détails du processus Node incomplets** sans console administrateur (§5).

---

## 12. Verdict

**GO pour la Phase 2.**

Les critères GO sont tous satisfaits : l'abstraction Phase 1 est correcte, le
hash et l'ETag sont préservés à l'identique, le comportement HEAD est désormais
connu et testé, le service Windows est identifié (`HomeSpotifyApi`, PID Node
34216, `LocalSystem`), la mémoire est relevée (WS 86,7 Mo / Private 131,1 Mo),
les règles du port 3000 sont inventoriées, l'adresse WireGuard `10.8.0.2` est
confirmée avec 0 % de perte, le port 3100 peut être restreint à `10.8.0.1`
(à condition de traiter la règle générique Node.js), et aucune information
sensible n'a été exposée.

Le GO est conditionné au traitement de **P2 et P3 avant toute exposition
réseau** du Storage Agent.
