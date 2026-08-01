# VPS — Inventaire Phase 0

**Date :** 2026-07-25 · **Dépôt :** `F:\dev\homespotify` · branche `feature/lucida-import`
**Plan de référence :** [VPS_HYBRID_MIGRATION_PLAN.md](VPS_HYBRID_MIGRATION_PLAN.md)

**Périmètre :** relevé en lecture seule. Aucun service modifié, aucune base copiée, aucun secret affiché, aucun commit.

---

## 1. Informations vérifiées localement

### 1.1 Base SQLite

| Élément | Valeur mesurée |
|---|---|
| Chemin configuré | `services/api/data/homespotify.db` (défaut `config.ts` : `./data/homespotify.db`, cwd = `services/api`) |
| `DB_PATH` dans `.env` | **non défini** — le défaut s'applique |
| Fichier présent | oui |
| Taille | **3 387 392 octets (3,23 Mo)** |
| Dernière modification | 2026-07-25 15:42 |
| WAL | `homespotify.db-wal` — 2 039 432 o (1,95 Mo), modifié 16:01 |
| SHM | `homespotify.db-shm` — 32 768 o |
| `journal_mode` | **`wal`** |
| `PRAGMA quick_check` | **`ok`** |
| `page_size` | 4096 |
| `user_version` | 0 |

> Le WAL modifié à 16:01 alors que la base l'était à 15:42 indique que **le service tournait pendant l'audit**. Lecture effectuée en mode `readonly` — aucune écriture, aucun verrou bloquant.

**Comptages (référence pour la validation post-migration) :**

| Table | Lignes |
|---|---|
| `tracks` | **157** |
| `users` | 3 |
| `playlists` | 1 |
| `favorites` | 9 |
| `listening_sessions` | 443 |
| `music_requests` | 16 |
| `user_tracks` | 158 |

**Sauvegardes existantes :** `services/api/data/backups/` ; scripts `scripts/backup_homespotify.ps1` et `scripts/restore_homespotify.ps1` ; mécanisme applicatif `services/api/src/operations/server-backup.ts` utilisant la **SQLite Backup API**. Deux fichiers de sauvegarde ponctuels présents (`homespotify-before-speed-20260714-*`), dont un `.db-wal` orphelin de 4,1 Mo à nettoyer un jour.

### 1.2 Bibliothèque

| Élément | Valeur mesurée |
|---|---|
| Racine | `storage/music` (défaut `MUSIC_DIR=../../storage/music`) |
| Taille totale (disque) | **3,0 Go** |
| Taille totale (base) | **2,93 Go** |
| Fichiers FLAC | **157** |
| Fichiers WAV | **1** |
| Taille moyenne | **19,1 Mo** |
| Taille médiane | **17,8 Mo** |
| Taille maximale | 38,9 Mo |
| Pochettes (`storage/covers`) | **16 Mo** |
| Staging imports (`storage/imports`) | 3,3 Go |

### 1.3 ⚠️ Séparateurs de chemins — point bloquant

| Contrôle | Résultat |
|---|---|
| Chemins absolus dans `tracks.path` | **0 / 157** ✅ |
| Chemins contenant `\` (Windows) | **157 / 157** ⚠️ |
| Chemins contenant `/` (POSIX) | **0 / 157** |
| Structure | `Artiste\Album\Titre.flac`, longueurs 28 à 57 caractères |

**Conséquence :** sur Linux, `\` n'est pas un séparateur — `path.join('/var/music', 'A\\B\\C.flac')` désigne un fichier unique nommé `A\B\C.flac`, qui n'existe pas. **Sans normalisation, 100 % des lectures échoueraient.** Traitement défini au §18 du plan (normalisation dans le provider, sans modification des données).

### 1.4 Backend

| Élément | Valeur |
|---|---|
| Node requis | `>=22` (`package.json`) — local **v22.18.0** |
| Gestionnaire | **`pnpm@10.12.1`** (champ `packageManager`) |
| Build | `pnpm -r build` (racine) / `tsc -p tsconfig.json` (api) |
| Démarrage | `node dist/server.js` |
| Arrêt propre | `SIGINT` / `SIGTERM` → `app.close()` |
| Health | `GET /health` |
| Port | **3000** (WinSW) |
| Host | **`0.0.0.0`** ⚠️ (WinSW) |
| Compte de service | **`LocalSystem`** ⚠️ |
| Timeout d'arrêt | 20 s |
| **Dépendances natives** | **`better-sqlite3@^12.2.0`**, **`@node-rs/argon2@^2.0.2`** |

> Les deux dépendances natives imposent `build-essential` + `python3` sur Debian si aucun binaire précompilé n'existe pour l'architecture du VPS. **À vérifier lors de la Phase 6.**

**Variables définies dans `services/api/.env` (noms uniquement, aucune valeur lue) :**
`ACCESS_TOKEN_TTL_SECONDS`, `AUTH_TOKEN_SECRET`, `FFMPEG_PATH`, `FFPROBE_PATH`, `HOMESPOTIFY_IMPORT_ROOT`, `LASTFM_API_KEY`, `LUCIDA_PROCESS_TIMEOUT_SECONDS`, `LUCIDA_PYTHON_PATH`, `LUCIDA_SCRIPT_PATH`, `MUSICBRAINZ_USER_AGENT`, `PLAYWRIGHT_BROWSERS_PATH`, `SPOTIFY_CLIENT_ID`, `SPOTIFY_CLIENT_SECRET`, `SPOTIFY_DISCOVERY_ENABLED`.

`DB_PATH`, `MUSIC_DIR`, `COVERS_DIR`, `PORT`, `HOST` **ne sont pas définis** dans `.env` : les valeurs par défaut de `config.ts` et les variables WinSW s'appliquent.

**Utilisation mémoire :** INFORMATION À RELEVER — non mesurée pour ne pas perturber le service.

### 1.5 Streaming

| Élément | Valeur |
|---|---|
| Point d'entrée | `serveTrackFile` — [tracks.ts:50](../services/api/src/routes/tracks.ts) |
| Signature | `(request, reply, trackId, absPath, hash, contentType, disposition?)` |
| Appelants | `tracks.ts:371`, `tracks.ts:394`, `offline.ts:222` |
| Accès disque | `createReadStream(absPath, {start, end})` — **un seul point** |
| Parsing Range | `parseRangeHeader` — [lib/range.ts](../services/api/src/lib/range.ts), RFC 9110 |
| 416 | géré (`content-range: bytes */<size>`) |
| Multi-range | replié sur 200 (autorisé par la RFC) |
| Suffixe `bytes=-N` | géré |
| HEAD | INFORMATION À RELEVER — aucune route `app.head` explicite ; Fastify expose HEAD automatiquement pour les GET, **à confirmer par un test réel** |
| Diagnostics | `STREAM_RANGE_PARSED`, `STREAM_FILE_OPEN_STARTED`, `STREAM_FILE_OPEN_COMPLETED`, `STREAM_FIRST_CHUNK_SENT`, `STREAM_FILE_ERROR`, `STREAM_COMPLETED` |
| Abandon client | `request.raw.'aborted'` géré |
| Tests | `lib/range.test.ts`, `tracks.test.ts`, `routes/offline.test.ts` |

**`TrackStorageReference` actuel :** n'existe pas. L'identité d'une piste au moment du streaming est le triplet `(trackId, absPath, hash)` passé en arguments. C'est exactement ce que la Phase 1 remplacera par une structure unique.

### 1.6 Réseau local

| Élément | État |
|---|---|
| Adresse WireGuard du PC | **INFORMATION À RELEVER** — non documentée dans le dépôt |
| Port backend | 3000 |
| Règles pare-feu | **INFORMATION À RELEVER** — non documentées |
| Mécanisme VPS → PC | Caddy → WireGuard → `PC:3000` (déduit, **à confirmer**) |
| Keepalive | **INFORMATION À RELEVER** |
| Scripts de diagnostic WireGuard | **aucun** dans le dépôt |

**Scripts PowerShell existants :** `backup_homespotify.ps1`, `restore_homespotify.ps1`, `rotate_auth_secret.ps1`, `collect_android_audio_diagnostics.ps1`, `collect_backend_audio_diagnostics.ps1`, `monitor_android_long_session.ps1`.

---

## 2. Informations encore inconnues

| # | Information | Criticité | Où la relever |
|---|---|---|---|
| 1 | Espace disque réel du VPS (`df -h`) | **Bloquante** | script VPS §3 |
| 2 | RAM / vCPU du VPS | Élevée | script VPS |
| 3 | Version Debian et Node disponible | Élevée | script VPS |
| 4 | Présence de `build-essential` + `python3` | **Élevée** (deps natives) | script VPS |
| 5 | Adresses WireGuard, `AllowedIPs`, keepalive, port UDP | **Bloquante** | script VPS §7 |
| 6 | Contenu du `Caddyfile` | **Bloquante** | script VPS §6 |
| 7 | **Débit montant du domicile** | **Bloquante** | procédure §5 |
| 8 | Latence, gigue, perte PC ↔ VPS | Élevée | procédure §5 |
| 9 | Comportement HEAD sur `/api/tracks/:id/stream` | Moyenne | commande Windows §4 |
| 10 | Empreinte mémoire du backend en production | Moyenne | commande Windows §4 |
| 11 | Règles de pare-feu Windows sur le port 3000 | Élevée | commande Windows §4 |
| 12 | Politique de sauvegarde hors site souhaitée | Moyenne | décision utilisateur |
| 13 | Fenêtre de bascule acceptable | Moyenne | décision utilisateur |

---

## 3. Commandes VPS à exécuter

Le script est fourni : [`scripts/vps_phase0_inventory.sh`](../scripts/vps_phase0_inventory.sh).

**Transfert et exécution :**

```bash
scp F:/dev/homespotify/scripts/vps_phase0_inventory.sh <user>@<vps>:~/
```

```bash
ssh <user>@<vps> 'bash ~/vps_phase0_inventory.sh'
```

Certaines sections nécessitent des privilèges (Caddyfile, `wg show`, pare-feu). Relancer ensuite les compléments :

```bash
sudo cat /etc/caddy/Caddyfile
```

```bash
sudo wg show
```

```bash
sudo cat /etc/wireguard/wg0.conf | sed -E 's/(PrivateKey|PresharedKey)[[:space:]]*=.*/\1 = <REDACTED>/I'
```

**Le script est en lecture seule** : il n'installe rien, ne redémarre rien, ne modifie ni Caddy, ni WireGuard, ni le pare-feu. Toute clé rencontrée est caviardée avant écriture. Le rapport est écrit en `0600` dans le home.

**Vérification obligatoire avant de me le transmettre :**

```bash
grep -iE 'privatekey|presharedkey|secret|token|password' ~/homespotify-vps-inventory-*.txt
```

Toutes les correspondances doivent afficher `<REDACTED>`.

---

## 4. Commandes Windows à exécuter

Toutes en lecture seule. À lancer dans PowerShell **en administrateur** pour les règles de pare-feu.

**Service et port :**
```powershell
Get-Service HomeSpotifyApi | Format-List Name,Status,StartType
```

```powershell
Get-Process node | Select-Object Id,ProcessName,WorkingSet64,StartTime
```

```powershell
Get-NetTCPConnection -LocalPort 3000 -State Listen | Select-Object LocalAddress,LocalPort,OwningProcess
```

**Règles de pare-feu associées au port 3000 :**
```powershell
Get-NetFirewallPortFilter | Where-Object LocalPort -eq 3000 | Get-NetFirewallRule | Select-Object DisplayName,Enabled,Direction,Action,Profile
```

**Interfaces WireGuard du PC :**
```powershell
Get-NetIPAddress | Where-Object InterfaceAlias -like "*wg*" | Select-Object InterfaceAlias,IPAddress,PrefixLength
```

**Comportement HEAD (à valider — remplacer `<TOKEN>` par un access token de test, ne pas me le transmettre) :**
```powershell
curl.exe -s -o NUL -D - -X HEAD -H "Authorization: Bearer <TOKEN>" http://127.0.0.1:3000/api/tracks/1/stream
```

**Comportement Range (attendu : `206` et `Content-Range`) :**
```powershell
curl.exe -s -o NUL -D - -H "Range: bytes=0-1023" -H "Authorization: Bearer <TOKEN>" http://127.0.0.1:3000/api/tracks/1/stream
```

---

## 5. Procédure de mesure réseau

**Objectif :** déterminer si un cache miss est supportable. C'est le critère Go/No-Go le plus important.

**Ne jamais utiliser un fichier musical personnel comme charge de test.** Générer un fichier synthétique, puis le supprimer manuellement.

### A — Avec iperf3 déjà installé

Sur le VPS (serveur, port temporaire) :
```bash
iperf3 -s -p 5201 -1
```

Sur le PC, **PC → VPS** (sens critique : c'est l'upload du domicile) :
```powershell
iperf3.exe -c <IP_WG_VPS> -p 5201 -t 60 -i 5
```

Sens inverse, **VPS → PC** :
```powershell
iperf3.exe -c <IP_WG_VPS> -p 5201 -t 60 -i 5 -R
```

Stabilité sur 5 minutes :
```powershell
iperf3.exe -c <IP_WG_VPS> -p 5201 -t 300 -i 10
```

### B — Sans iperf3 (outils déjà présents)

**Latence, gigue et perte (100 paquets) :**
```powershell
ping -n 100 <IP_WG_VPS>
```
Relever : minimum / moyenne / maximum et le pourcentage de perte. La gigue s'estime par l'écart max − min.

**Débit PC → VPS avec un fichier synthétique de 200 Mo :**

Création (PC) :
```powershell
fsutil file createnew $env:TEMP\hs-speedtest.bin 209715200
```

Transfert chronométré :
```powershell
Measure-Command { scp $env:TEMP\hs-speedtest.bin <user>@<IP_WG_VPS>:/tmp/hs-speedtest.bin }
```

Débit (Mb/s) = 200 × 8 ÷ secondes écoulées.

Sens inverse :
```powershell
Measure-Command { scp <user>@<IP_WG_VPS>:/tmp/hs-speedtest.bin $env:TEMP\hs-speedtest-back.bin }
```

**Nettoyage manuel obligatoire :**
```powershell
Remove-Item $env:TEMP\hs-speedtest.bin, $env:TEMP\hs-speedtest-back.bin -ErrorAction SilentlyContinue
```
```bash
rm -f /tmp/hs-speedtest.bin
```

### Débit minimal recommandé

Une piste moyenne fait **19,1 Mo (153 Mbit)**.

| Débit montant du domicile | Temps de transfert d'une piste | Verdict |
|---|---|---|
| 10 Mb/s | ~15 s | ⚠️ Cache miss perceptible ; préchargement **indispensable** |
| 20 Mb/s | ~8 s | Acceptable avec préchargement |
| 50 Mb/s | ~3 s | Confortable |
| ≥ 100 Mb/s | ~1,5 s | Cache miss quasi transparent |

**Seuil de décision : 10 Mb/s montants.** En dessous, la première lecture d'une piste non préchargée reste pénible malgré le cache — il faudrait alors envisager un pré-remplissage complet du cache (possible : la bibliothèque entière tient dans 8 Go).

---

## 6. Configuration Caddy — lignes à traiter lors de la bascule

À compléter après réception du `Caddyfile`. Grille d'analyse :

| Élément | Action à la bascule |
|---|---|
| Bloc `music.romainbegot.fr` | **Conserver** |
| Certificats / ACME | **Conserver** (aucune intervention) |
| `reverse_proxy <IP_WG_PC>:3000` | **MODIFIER** → `127.0.0.1:3000` |
| Timeouts de transport | **MODIFIER** → `read_timeout 0`, `write_timeout 0` |
| `flush_interval` | **AJOUTER** → `-1` (obligatoire pour le streaming) |
| Compression `encode` | **MODIFIER** → exclure les chemins audio |
| `header_up X-Request-Id` | **AJOUTER** si absent (corrélation des diagnostics) |
| `request_body max_size` | **VÉRIFIER** — aligner sur `MAX_UPLOAD_MB` |
| Configuration des logs | **CONSERVER** |
| Toute directive liée au tunnel | **SUPPRIMER** après Phase 13 uniquement |

---

## 7. Configuration WireGuard — à relever

À compléter après réception. Éléments attendus : IP WireGuard du VPS, IP WireGuard du PC, `AllowedIPs` de chaque côté, `PersistentKeepalive`, port d'écoute UDP, dernier handshake, volume transféré, route vers le PC.

**`PrivateKey` et `PresharedKey` ne doivent jamais être reproduits.** Le script les caviarde automatiquement.

---

## 8. Sécurité Windows actuelle

| Constat | Valeur | Risque | Correction prévue |
|---|---|---|---|
| Compte du service | **`LocalSystem`** | Privilèges maximaux sur la machine | Après Phase 13, l'API disparaît du PC ; le Storage Agent tournera sous un **compte dédié à privilèges réduits** |
| `HOST` | **`0.0.0.0`** | Écoute sur **toutes** les interfaces (LAN inclus) | Sur le VPS : `127.0.0.1`. Sur le PC : l'agent écoutera **uniquement sur l'IP WireGuard** |
| Port 3000 | Ouvert | Exposition LAN probable | INFORMATION À RELEVER (§4) — restreindre à l'IP WireGuard du VPS |
| Règles de pare-feu | Non documentées | Inconnu | À relever puis durcir |

**Aucune modification effectuée** : ni le compte du service, ni `HOST`, ni le pare-feu n'ont été touchés.

---

## 9. Budget disque corrigé

La formulation précédente (« 31,5 Go utilisés sur 35 » **et** « 8 Go libres garantis ») était arithmétiquement incohérente : 31,5 + 8 = 39,5 > 35. Corrigée et recalculée sur les mesures réelles.

| Poste | Réservation | Base de calcul |
|---|---|---|
| Debian + paquets système | 4,0 Go | à confirmer par le script VPS |
| Node.js + store pnpm | 1,5 Go | |
| Application + `node_modules` | 1,5 Go | |
| SQLite (base + WAL) | 0,3 Go | mesuré 3,2 + 2,0 Mo |
| Sauvegardes SQLite (7 générations) | 0,5 Go | mesuré ≈ 23 Mo |
| Logs (rotation) | 1,0 Go | |
| Cache pochettes | 0,3 Go | mesuré 16 Mo |
| Staging import (plafonné) | 2,0 Go | |
| **A — Sous-total hors cache audio** | **11,1 Go** | |
| **B — Cache audio (seuil haut)** | **8,0 Go** | |
| **C = A + B — Occupation maximale** | **19,1 Go** | |
| **D = 35 − C — Marge libre garantie** | **15,9 Go** | |

**Vérification :** 11,1 + 8,0 = 19,1 · 35,0 − 19,1 = 15,9 ✅

**Seuil de désactivation du cache :** espace libre < **5 Go** → arrêt immédiat du remplissage, streaming direct maintenu. Ce seuil est un filet de sécurité contre une anomalie externe, pas un régime nominal.

> ⚠️ Ces chiffres restent **provisoires** tant que `df -h` n'a pas été relevé sur le VPS. Si l'espace réellement disponible est inférieur à 35 Go, le poste B (cache audio) est la variable d'ajustement.

### Estimation du nombre de pistes en cache

| Mesure | Valeur |
|---|---|
| Taille moyenne d'une piste | 19,1 Mo |
| Cache à 8 Go | **≈ 420 pistes** |
| Bibliothèque actuelle | **157 pistes (2,93 Go)** |
| Ratio de couverture | **2,7 ×** |

**Conséquence remarquable :** le cache peut contenir **l'intégralité de la bibliothèque actuelle**, avec 5 Go de marge de croissance. Tant que la bibliothèque reste sous ~420 pistes, un cache correctement préchauffé rend le PC quasi inutile en lecture — la dépendance au débit du domicile devient marginale après le premier passage.

---

## 10. Résultat Go/No-Go provisoire

### ✅ Favorable

- Base saine (`quick_check ok`), petite (3,2 Mo), transfert trivial.
- Aucun chemin absolu en base — pas de migration de schéma.
- Streaming centralisé en **un seul point** d'insertion.
- Outil de sauvegarde cohérent **déjà implémenté et testé**.
- Bibliothèque de 2,93 Go : **le cache peut tout contenir**.
- Volumétrie faible partout (157 pistes, 3 comptes, 443 sessions).

### ⚠️ Points de vigilance

- **Séparateurs `\` sur 157/157 chemins** — traité en Phase 1, mais **obligatoire**.
- Deux dépendances natives à compiler sur Debian.
- `LocalSystem` + `HOST=0.0.0.0` à corriger.
- Documentation d'architecture en retard sur la réalité.

### ⛔ Bloquants avant Phase 1

| # | Bloquant | Levée |
|---|---|---|
| 1 | Espace disque réel du VPS inconnu | Script VPS |
| 2 | Configuration Caddy inconnue | Script VPS + `sudo cat` |
| 3 | Configuration WireGuard inconnue | Script VPS + `sudo wg show` |
| 4 | **Débit montant du domicile non mesuré** | Procédure §5 |

**Verdict : NO-GO provisoire pour la Phase 1** — non pas à cause d'un défaut d'architecture, mais parce que quatre informations d'environnement manquent. Aucune n'est difficile à obtenir ; toutes conditionnent le dimensionnement.

---

## 11. Critères pour démarrer la Phase 1

- [ ] Rapport `vps_phase0_inventory.sh` reçu et relu (aucun secret)
- [ ] `df -h` du VPS connu, ≥ 20 Go réellement libres
- [ ] `Caddyfile` reçu, bloc `music.romainbegot.fr` identifié
- [ ] IP WireGuard des deux côtés connues, handshake confirmé actif
- [ ] **Débit montant du domicile mesuré** (≥ 10 Mb/s souhaitable)
- [ ] Latence PC ↔ VPS < 50 ms, perte < 1 %
- [ ] `build-essential` et `python3` présents sur le VPS (ou plan d'installation validé)
- [ ] Fenêtre de bascule choisie

> La Phase 1 (abstraction de stockage + normalisation des chemins) est **sans risque pour la production** : elle ne modifie rien tant que `AUDIO_STORAGE_MODE=local`. Elle pourrait techniquement démarrer avant la levée des bloquants — mais le dimensionnement du cache (Phase 5) dépend du disque réel, et l'agent (Phase 2) dépend des adresses WireGuard.

---

## 12. Risques bloquants identifiés

| Risque | Impact si ignoré | Levée |
|---|---|---|
| Séparateurs `\` | **100 % des lectures en 404 sur Linux** | Phase 1 + test des 157 chemins |
| Disque VPS < 20 Go | Cache inutilisable, migration sans bénéfice | Relevé `df -h` |
| Débit montant < 10 Mb/s | Cache miss pénible en permanence | Mesure §5 ; atténuation : préchauffage complet |
| Deux backends en écriture | **Divergence irréversible de la base** | Procédure de bascule §34 du plan |
| Compilation native impossible | Backend indémarrable sur le VPS | Vérification Phase 6 |

---

## 13. Informations sensibles à ne pas partager

Lors de la transmission des relevés, **ne jamais inclure** :

- `PrivateKey` ou `PresharedKey` WireGuard
- Contenu de `services/api/.env` ou `/etc/homespotify/api.env`
- `AUTH_TOKEN_SECRET`, `LASTFM_API_KEY`, `SPOTIFY_CLIENT_SECRET`
- Tout access token ou refresh token
- Clés privées TLS de Caddy
- Mots de passe ou hachages de comptes utilisateurs

**Peuvent être partagés sans risque :** noms de variables, adresses IP privées WireGuard, `AllowedIPs`, ports, tailles, versions, statuts de services, journaux caviardés, clés **publiques** WireGuard.

---

## 14. Confirmations Phase 0

- ✅ Aucun service démarré, arrêté ou redémarré
- ✅ Aucune base copiée, déplacée ou modifiée (lecture `readonly` uniquement)
- ✅ Aucun secret affiché (noms de variables seuls)
- ✅ Aucun fichier musical touché
- ✅ Ni Caddy ni WireGuard modifiés
- ✅ Aucun commit créé
- ✅ Seuls trois fichiers ajoutés : ce document, le plan, le script d'inventaire

---

## 15. CLÔTURE OFFICIELLE — verdict **GO**

**Date de clôture :** 2026-07-25 · Relevés VPS, réseau et domicile fournis par le propriétaire.

> Cette section est **ajoutée** après coup. Rien de ce qui précède n'a été
> réécrit : les sections 1 à 14 restent le relevé d'origine, y compris le NO-GO
> provisoire du §10 que cette clôture lève.

### 15.1 Relevés reçus

| Domaine | Valeur |
|---|---|
| VPS | Debian 12, 2 vCPU, 3,7 Gio RAM, **~37 Go disponibles** |
| Caddy | actif, `music.romainbegot.fr` → `10.8.0.2:3000` |
| WireGuard | VPS `10.8.0.1/24` · PC `10.8.0.2` |
| UFW | actif, entrant `deny` par défaut ; ouverts : 22/tcp, 80/tcp, 443/tcp, 51820/udp |
| Port 3000 public | **non exposé** ✅ |
| Tunnel | handshake récent, **0 % de perte**, latence **24,5 ms** |
| `GET 10.8.0.2:3000/health` | **200**, TTFB **47 ms** |
| Domicile — upload | 28,21 / 25,29 / **22,11** Mb/s (pire cas retenu) |
| Domicile — download | 31,12 / 39,36 / 37,60 Mb/s |
| Domicile — ping | ≈ 13 ms |

### 15.2 Levée des quatre bloquants

| Bloquant §10 | État | Preuve |
|---|---|---|
| Espace disque VPS inconnu | **Levé** | ~37 Go, soit 2 Go de plus qu'estimé |
| Configuration Caddy inconnue | **Levé** | reverse proxy `10.8.0.2:3000` identifié |
| Configuration WireGuard inconnue | **Levé** | `10.8.0.1` ↔ `10.8.0.2`, tunnel sain |
| **Débit montant non mesuré** | **Levé** | 22,11 Mb/s au pire |

### 15.3 Analyse du débit — le critère décisif

| Grandeur | Valeur |
|---|---|
| Upload disponible (pire cas) | 22,11 Mb/s |
| Débit requis pour lire un FLAC en temps réel | ≈ 0,64 Mb/s (19,1 Mo / ~4 min) |
| **Marge** | **≈ 34 ×** |
| Transfert d'une piste entière | 6,9 s |
| Préchauffage complet de la bibliothèque | **≈ 18 min** |

**Conclusion :** un cache miss n'est pas un problème de fluidité. Le relais
démarre en quelques dizaines de millisecondes et le débit dépasse de 34 × la
consommation temps réel. Le cache sert à réduire la latence de démarrage et à
survivre au PC hors ligne, pas à rendre la lecture possible.

### 15.4 Budget disque définitif — 37 Go

| Poste | Réservation |
|---|---|
| **A — Hors cache audio** (détail §9) | **11,1 Go** |
| **B — Cache audio (seuil haut)** | **8,0 Go** |
| **C = A + B — Occupation maximale** | **19,1 Go** |
| **D = 37 − C — Marge libre garantie** | **17,9 Go** |

Vérification : 11,1 + 8,0 = 19,1 · 37 − 19,1 = **17,9** ✅

Les 2 Go supplémentaires par rapport à l'estimation initiale vont intégralement
à la marge, **pas au cache**. Seuils : haut 8 Go → éviction jusqu'à 6 Go ;
réserve libre minimale 5 Go (arrêt du remplissage). Capacité ≈ 420 pistes, soit
**2,7 ×** la bibliothèque actuelle.

### 15.5 Analyse des erreurs Caddy

Les `broken pipe`, `connection reset by peer` et `context canceled` observés
lors de l'écriture **vers le client Android**, suivis de nouvelles requêtes
Range, sont la **signature normale d'ExoPlayer/Media3** : il ouvre une requête
Range, remplit son tampon, ferme délibérément la connexion, puis en rouvre une
plus loin. Le backend gère déjà ce cas (`request.raw.'aborted'` →
`STREAM_ABORTED` / `STREAM_CLIENT_DISCONNECTED`).

**Impact sur la migration : nul.** Trois conséquences pratiques :
1. Ne pas alerter dessus — une supervision les remontant produirait un bruit permanent.
2. **Figer le taux actuel comme référence** : une augmentation nette après bascule serait, elle, un vrai signal.
3. `flush_interval -1` est obligatoire — sans lui, Caddy tamponnerait et transformerait ce comportement normal en latence perceptible.

### 15.6 Décisions confirmées

- **Port 3000 du backend VPS : `127.0.0.1` uniquement** (`Environment=HOST=127.0.0.1`). Aucune règle UFW nécessaire.
- **Storage Agent : `10.8.0.2:3100` uniquement** — jamais `0.0.0.0`, jamais l'IP LAN ou publique. Pare-feu Windows entrant limité à `10.8.0.1`.
- **Aucune modification UFW requise** : la migration n'augmente pas la surface d'attaque.

### 15.7 Point non bloquant restant

**Le rapport Windows n'a pas été fourni** (marqueur non renseigné dans les
relevés). Trois éléments manquent : règles de pare-feu du port 3000,
comportement HEAD, empreinte mémoire.

Ce point **ne bloque pas la Phase 1** (qui ne touche ni au réseau ni au
pare-feu) mais **bloque la Phase 2**.

### 15.8 Chemin critique mis à jour

```
Phase 1 ──▶ 2 ──▶ 3 ──▶ 4 ──▶ 5 ──┐
                                   ├──▶ 9 ──▶ 10 ──▶ 11 ──▶ 12 ──▶ 13 ──▶ 14
Phase 6 ──▶ 7 ──▶ 8 ──────────────┘
```

Changement : les phases 6, 7 et 8 **ne sont plus en attente** — le VPS est
entièrement caractérisé. Elles peuvent démarrer en parallèle de la Phase 1.
Le chemin critique reste **1 → 2 → 3 → 4 → 5 → 9 → 10**.

**Suite :** [VPS_PHASE1_STORAGE_ABSTRACTION.md](VPS_PHASE1_STORAGE_ABSTRACTION.md)
