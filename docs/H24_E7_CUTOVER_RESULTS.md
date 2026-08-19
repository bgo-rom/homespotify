# HomeSpotify H24 — É7 : bascule de la PROD vers HYDRA (2026-08-19)

Bascule du stockage audio de production du gros PC (`<OLD_AGENT_WG_IP>`) vers le mini-PC H24 HYDRA
(`<HYDRA_WG_IP>`), exécutée après `H24_E5_PASS` et `H24_E6_PASS`, sur feu vert explicite du
propriétaire.

**Une seule variable a changé.** Player, DSP, JWT, Radio, Antra, UI, ranking, base de données,
Caddy, cache audio, index : rien n'a été touché.

---

## 1. État avant bascule — les 7 contrôles

| # | Contrôle | Résultat |
|---|---|---|
| 1 | Sauvegarde de `/etc/homespotify/api-shadow.env` | ✅ `/var/backups/homespotify-h24/api-shadow.env.20260819-181338.pre-h24`, SHA-256 identique à l'original (`f023992452c316a0…`) |
| 2 | Valeur courante enregistrée | ✅ ligne **36** : `AUDIO_REMOTE_BASE_URL=http://<OLD_AGENT_WG_IP>:3100` |
| 3 | Ancien agent healthy | ✅ `200` en **47,7 ms**, 175 entrées, `musicRootAvailable: true`, uptime 9 484 s |
| 4 | HYDRA healthy | ✅ `200` en **41,7 ms**, 175 entrées, `musicRootAvailable: true`, uptime 293 s |
| 5 | Snapshot final synchronisé | ✅ F2 : **177/177** path, taille, SHA-256 (cf. `H24_E6_FINAL_RESULTS.md`) |
| 6 | `/health` public | ✅ **200** en 68 ms |
| 7 | Rollback exécutable immédiatement | ✅ `sudo bash /var/backups/homespotify-h24/switch_agent.sh <OLD_AGENT_WG_IP>` — script installé **hors `/tmp`**, donc survivant à un redémarrage du VPS |

Compteurs WireGuard relevés juste avant, pour servir de référence :

```
<OLD_AGENT_WG_IP>  rx = 24 844 923 844 o
<HYDRA_WG_IP>  rx = 49 812 585 584 o
```

## 2. La modification

Un unique `sed` sur la ligne 36, précédé d'une copie horodatée, suivi d'un contrôle qui **annule
et restaure** si le diff porte sur autre chose que cette ligne.

```diff
36c36
< AUDIO_REMOTE_BASE_URL=http://<OLD_AGENT_WG_IP>:3100
---
> AUDIO_REMOTE_BASE_URL=http://<HYDRA_WG_IP>:3100
```

Diff complet du fichier contre la sauvegarde d'avant migration : **cette ligne, et rien d'autre.**

### Rechargement

`AUDIO_REMOTE_BASE_URL` est lu **une seule fois au démarrage** (`loadConfig` → `loadRemoteStorageConfig`),
via `EnvironmentFile=` de l'unité systemd. Un `reload` ne le relit pas : seul un redémarrage du
service API le prend en compte. C'est donc le strict minimum nécessaire, et rien de plus — ni
Caddy, ni la base, ni le cache, ni WireGuard, ni les agents.

```
systemctl restart homespotify-api-shadow
```

| | Avant | Après |
|---|---|---|
| `MainPID` | 239175 | **253475** |
| `ActiveEnterTimestamp` | — | **2026-08-19 19:16:14 CEST** |
| `systemctl is-active` | active | **active** |
| `AUDIO_REMOTE_BASE_URL` dans `/proc/<pid>/environ` | — | **`http://<HYDRA_WG_IP>:3100`** |
| `AUDIO_STORAGE_MODE` | `cached` | `cached` — inchangé |
| `AUDIO_CACHE_ROOT` | `/var/lib/homespotify-shadow/cache/audio` | inchangé |
| `127.0.0.1:3002/health` | — | **200 en 3 ms** |
| `/health` public | 200 | **200 en 202 ms** |

La valeur effective est lue **dans l'environnement du processus**, pas seulement dans le fichier :
c'est ce qui prouve que le redémarrage a bien pris la nouvelle configuration.

---

## 3. Smoke tests immédiats

16 vérifications, toutes passées :

| Vérification | Résultat |
|---|---|
| `/health` public | **200** en 71 ms |
| `HEAD` piste ASCII (2) | 200 |
| `HEAD` piste accentuée (7, `MA_TÊTE.flac`) | 200 |
| `HEAD` piste `#` + apostrophe (13, `'80s_Pop_#1's`) | 200 |
| `HEAD` objet content-addressed (166) | 200 |
| `HEAD` petit fichier (78) | 200 |
| `GET` complet 2 — 32 736 249 o | **200, SHA-256 OK**, TTFB 75 ms, 117,4 Mo/s |
| `GET` complet 7 — 14 254 943 o | **200, SHA-256 OK**, TTFB 69 ms, 96,5 Mo/s |
| `GET` complet 13 — 30 634 066 o | **200, SHA-256 OK**, TTFB 72 ms, 135,2 Mo/s |
| `GET` complet 166 — 46 572 846 o | **200, SHA-256 OK**, TTFB 91 ms, 119,3 Mo/s |
| `GET` complet 78 — 9 165 881 o | **200, SHA-256 OK**, TTFB 112 ms, 56,9 Mo/s |
| `Range` milieu 1 MiB sur 7 | **206**, 1 048 576 o |
| `Range` milieu 1 MiB sur 166 | **206**, 1 048 576 o |
| **Cache miss réel 69** | **200**, 30 327 166 o, TTFB 206 ms |
| **Cache miss réel 70** | **200**, 21 141 961 o, TTFB 146 ms |
| **Cache miss réel 71** | **200**, 16 450 163 o, TTFB 146 ms |

Le catalogue répond aussi : `GET /api/tracks` → **200**, `total: 169` pistes visibles (175 en base
moins 6 masquées) — la surface exposée est inchangée.

L'**import** n'a **pas** été testé : il écrirait dans la bibliothèque, ce que la consigne exclut.
L'**index** l'a été indirectement — l'agent le charge au démarrage (`indexEntryCount: 175`) et
chaque `trackId` résolu ci-dessus passe par lui.

### Les trois cache miss ne sont pas un artifice

Le cache audio du VPS contenait déjà 164 des 175 objets. Une lecture ordinaire ne touche donc
jamais le Storage Agent. Plutôt que de vider le cache — une suppression, même de données
régénérables — j'ai identifié dans la base les pistes dont l'objet **n'était pas encore en cache**
et lu celles-là. Le miss est donc **réel et non provoqué**, et rien n'a été détruit.

---

## 4. Preuve que la PROD passe réellement par `<HYDRA_WG_IP>`

### 4.1 Compteurs WireGuard, avant / après chaque cache miss

| Piste | Octets servis | `<HYDRA_WG_IP>` reçu | `<OLD_AGENT_WG_IP>` reçu |
|---|---|---|---|
| 69 | 30 327 166 | **+32,2 Mo** | **+0,0 Mo** |
| 70 | 21 141 961 | **+22,4 Mo** | **+0,0 Mo** |
| 71 | 16 450 163 | **+17,5 Mo** | **+0,0 Mo** |

### 4.2 Cumul depuis la bascule (≈ 13 minutes, dont 10 de charge soutenue)

| Pair | Delta reçu |
|---|---|
| **`<HYDRA_WG_IP>` (HYDRA)** | **+130 726 212 o** |
| `<OLD_AGENT_WG_IP>` (ancien) | **+2 920 o** |

2 920 octets sur 13 minutes, c'est le `PersistentKeepalive` du tunnel — **zéro octet applicatif**.

### 4.3 Journal de l'API — le chemin est explicite

```
CACHE_MISS                        trackId=70 contentHashPrefix=67402de602a1 operation=read
REMOTE_STORAGE_REQUEST_STARTED    trackId=70 method=HEAD operation=stat
REMOTE_STORAGE_REQUEST_COMPLETED  trackId=70 statusCode=200 durationMs=23.5
REMOTE_STORAGE_REQUEST_STARTED    trackId=70 method=GET  operation=read
STREAM_FIRST_CHUNK_SENT           trackId=70 timeToFirstChunkMs=85.2
REMOTE_STORAGE_REQUEST_COMPLETED  trackId=70 statusCode=200 durationMs=458.8 bytesReceived=21141961
CACHE_FILL_COMPLETED              trackId=70 bytesWritten=21141961
STREAM_COMPLETED                  trackId=70 bytesSent=21141961 aborted=false
```

**85 ms jusqu'au premier octet audio sur un cache miss complet**, alors même que la piste doit être
tirée du disque USB de HYDRA à travers le tunnel. 21,1 Mo transférés en 459 ms, soit 46 Mo/s.

### 4.4 État de l'ancien agent

`<OLD_AGENT_WG_IP>` est **toujours vivant** : `/health` **200** en 45,6 ms, 175 entrées, uptime 10 229 s,
tunnel `Running`, handshakes frais. Il n'est simplement **plus utilisé** par la production. C'est
exactement l'état voulu pour un rollback instantané.

---

## 5. Fenêtre d'observation — 10 minutes de trafic PROD réel

Trafic généré **par l'URL publique**, comme le ferait un client : pistes complètes enchaînées sur
tout le catalogue visible, seek de 1 MiB toutes les 3 pistes, chaque octet reçu vérifié par
SHA-256 contre le manifeste.

| | |
|---|---|
| Durée | **600 s** |
| Pistes complètes | **967** |
| **Vérifiées SHA-256** | **967 / 967** |
| Volume | **19,58 Go** |
| Débit | **32,61 Mo/s** |
| TTFB min / méd / p95 / max | **58 / 70 / 101 / 329 ms** |
| Seeks | **322, dont 0 en échec** |
| Échecs | **0** |
| **5xx** | **0** |
| **Timeouts** | **0** |

Journal de l'API sur toute la période post-bascule :

| Compteur | Valeur |
|---|---|
| `STREAM_COMPLETED` | **1 304** |
| Réponses 5xx | **0** |
| `BODY_TIMEOUT` | **0** |
| Logs niveau `error` / `fatal` | **0** |
| Flux `aborted: true` | **0** |
| `CACHE_MISS` | 12 |
| Appels à l'agent distant | 18 — **18 en `statusCode: 200`, aucun autre code** |

État de HYDRA pendant l'observation :

| Grandeur | Valeur |
|---|---|
| Processus agent | **pid 1368, inchangé** |
| RSS | **57 Mo, plat** |
| Handles | **229, plat** |
| CPU | 2 – 15 %, médiane 5 % |
| WD Elements | **43 °C, `ReadErrorsTotal = 0`** |
| File d'attente disque | **0** |
| Erreurs / rejets Ethernet | **0** |
| WireGuard | `Running` |

Journal du Storage Agent HYDRA depuis le redémarrage de 19:11 : **aucun `REQUEST_ABORTED`, aucun
`AUTH_REJECTED`, aucun `LIMIT_REACHED`, aucun `SHUTDOWN`**.

---

## 6. Rollback

Non déclenché — aucun défaut fonctionnel n'est apparu.

Il reste armé et immédiat :

```bash
sudo bash /var/backups/homespotify-h24/switch_agent.sh <OLD_AGENT_WG_IP>
```

Le script rejoue la même mécanique en sens inverse : sauvegarde horodatée, `sed` sur la seule
ligne 36, contrôle du diff avec restauration automatique s'il déborde, redémarrage du service,
attente du `200`. Il **ne supprime aucune donnée de HYDRA** : les 177 fichiers, le tunnel, l'agent
et le service restent en place.

Conservés intacts, comme demandé :

- l'ancienne bibliothèque sur `F:\dev\homespotify\storage\music` ;
- l'ancien Storage Agent `<OLD_AGENT_WG_IP>`, `Running`, healthy ;
- l'ancien pair WireGuard `<OLD_AGENT_WG_IP>`, handshakes frais ;
- les sauvegardes `/var/backups/homespotify-h24/` ;
- les snapshots F0 / F1 / F2 et le manifeste M0.

---

# H24_PROD_CUTOVER_PASS

| Critère | Résultat |
|---|---|
| `/health` public 200 | ✅ |
| API active | ✅ pid 253475, `active` |
| Storage Agent HYDRA reçoit les requêtes | ✅ 18 appels, tous en 200 |
| Ancien agent plus utilisé par la PROD | ✅ **+2 920 o en 13 min** = keepalive seul |
| Lecture d'une piste existante | ✅ 967 pistes, 967 SHA-256 conformes |
| `HEAD` / `GET` / `Range` | ✅ |
| Chemin Unicode | ✅ `MA_TÊTE.flac`, `'80s_Pop_#1's` |
| Objet content-addressed | ✅ piste 166 |
| Cache miss réel | ✅ 3 miss non provoqués, sans rien supprimer |
| Streaming complet | ✅ 19,58 Go |
| Import / index | index ✅ (chargé, 175 entrées, résolutions OK) — import volontairement non testé |
| Logs API | ✅ 0 erreur |
| Logs Storage Agent | ✅ 0 rejet, 0 abandon |
| Absence de 5xx | ✅ **0** |
| Absence de `BODY_TIMEOUT` | ✅ **0** |
| WireGuard stable | ✅ 2 pairs, handshakes frais |
| WD stable | ✅ 43 °C, 0 erreur de lecture |
| Preuve du chemin réseau | ✅ compteurs WireGuard + journal API |
| Rollback prêt | ✅ script durable, hors `/tmp` |

La production HomeSpotify est servie par **HYDRA**. L'ancien agent reste disponible pour rollback
pendant la période d'observation.
