# HomeSpotify H24 — É5B-ETHERNET-FINAL : performances, concurrence, endurance (2026-08-19)

Second volet d'É5B-ETHERNET-FINAL. Le premier volet (`H24_E5B_ETHERNET_RESULTS.md`) couvre le
démarrage à froid réel et la bascule du réseau nominal. Celui-ci mesure.

Toutes les mesures sont prises **depuis le VPS**, sur le chemin réellement utilisé en production :
`VPS → WireGuard → HYDRA → WD Elements USB`. Aucune n'est prise en local sur HYDRA.

**PROD inchangée** : `AUDIO_REMOTE_BASE_URL=http://<OLD_AGENT_WG_IP>:3100` pendant tout ce volet.

Matériel qualifié : **PELADN WI-6, Intel N100 (4 cœurs), 15,8 Go de RAM, Windows 11 Pro 26100**,
disque de service **WD Elements 2621 (USB, 3,7 To)**.

---

## 1. Montée en charge — rafales

Chaque flux est vérifié par **SHA-256 complet** contre le manifeste M0.

Jeu de pistes fixe, identique sur les deux agents, couvrant petits/moyens/grands fichiers, ASCII,
accents, apostrophes, `#`, parenthèses, et objets adressés par contenu :

| Niveau | Pistes | Volume |
|---|---|---|
| L1 | `7` (accentué) | 14,3 Mo |
| L2 | `78` (le plus petit), `168` (le plus grand) | 58,2 Mo |
| L4 | `7`, `13` (`#`+apostrophe), `2` (ASCII), `166` (content-addressed) | 124,2 Mo |
| L8 | `78`, `79`, `7`, `13`, `2`, `4`, `166`, `168` | 225,3 Mo |
| C8 | 8 pistes **jamais lues** de la campagne — cache disque froid | 180,0 Mo |

### HYDRA — Ethernet

| Niveau | Débit cumulé | Par flux | TTFB min/méd/max | Intégrité |
|---|---|---|---|---|
| 1 | **33,7 Mo/s** | 33,7 Mo/s | 81 / 81 / 81 ms | **1/1** |
| 2 | **51,5 Mo/s** | 25,8 Mo/s | 83 / 84 / 84 ms | **2/2** |
| 4 | **52,2 Mo/s** | 13,1 Mo/s | 81 / 81 / 81 ms | **4/4** |
| 8 | **43,4 Mo/s** | 5,4 Mo/s | 83 / 91 / 92 ms | **8/8** |
| **C8 (froid)** | **31,0 Mo/s** | 3,9 Mo/s | 802 / 929 / 1 065 ms | **8/8** |

### Ancien agent `<OLD_AGENT_WG_IP>` (gros PC, Wi-Fi) — même jeu, même instant

| Niveau | Débit cumulé | Par flux | TTFB méd | Intégrité |
|---|---|---|---|---|
| 1 | 2,9 Mo/s | 2,9 Mo/s | 101 ms | 1/1 |
| 2 | 3,2 Mo/s | 1,6 Mo/s | 117 ms | 2/2 |
| 4 | 3,4 Mo/s | 0,9 Mo/s | 195 ms | 4/4 |
| 8 | 3,4 Mo/s | 0,4 Mo/s | 202 ms | 8/8 |
| C8 (froid) | 3,4 Mo/s | 0,4 Mo/s | 211 ms | 8/8 |

**Le nouveau stockage est environ 10 à 15 fois plus rapide que celui qui sert la PROD aujourd'hui**,
et l'écart se creuse avec la concurrence : l'ancien agent plafonne dur à 3,4 Mo/s dès 2 flux,
HYDRA tient 43 à 57 Mo/s à 8 flux. L'intégrité est parfaite des deux côtés — c'est bien le débit,
pas la correction, qui change.

**Nuance honnête sur le cache** : HYDRA a 15,8 Go de RAM et la bibliothèque pèse 3,5 Go. Une piste
déjà lue est servie depuis le cache de pages de Windows. Le palier `C8`, sur 8 fichiers jamais
touchés, donne le plancher réel du disque USB : **31,0 Mo/s** et un TTFB de ~0,9 s le temps que la
tête se positionne sur huit fichiers à la fois. C'est le chiffre à retenir pour le pire cas.

## 2. Paliers tenus — métriques par niveau

Rafales de quelques secondes : trop court pour observer la machine. Chaque niveau est donc **tenu
45 secondes** en flux continus, sur toute la bibliothèque, avec échantillonnage HYDRA toutes les
5 s.

| Niveau | Requêtes | Intègres | Débit cumulé | Par flux | TTFB min/méd/max |
|---|---|---|---|---|---|
| 1 flux | 86 | **86/86** | **38,8 Mo/s** | 38,8 Mo/s | 75 / 80 / 100 ms |
| 2 flux | 117 | **117/117** | **50,1 Mo/s** | 25,1 Mo/s | 72 / 82 / 163 ms |
| 4 flux | 133 | **133/133** | **55,9 Mo/s** | 14,0 Mo/s | 73 / 112 / 267 ms |
| 8 flux | 134 | **134/134** | **57,3 Mo/s** | 7,2 Mo/s | 73 / 175 / 304 ms |

**470 requêtes, 470 intègres, 0 échec, 9,35 Go servis en 3 minutes.**

État de HYDRA relevé pendant chaque palier :

| Niveau | CPU méd / max | RSS agent | Handles | Threads | File disque | WD | Connexions :3100 | Erreurs réseau |
|---|---|---|---|---|---|---|---|---|
| 1 flux | 26 % / 46 % | 95,1 Mo | 231 | 12 | 0 | 42 °C | **1** | 0 |
| 2 flux | 28 % / 39 % | 95,8 Mo | 233 | 12 | 0 | 42 °C | **2** | 0 |
| 4 flux | 24 % / 44 % | 98,8 Mo | 237 | 12 | 0 | 42 °C | **4** | 0 |
| 8 flux | 30 % / 38 % | 101,7 Mo | 245 | 12 | 0 | 42 °C | **8** | 0 |

Le nombre de connexions établies sur `:3100` suit exactement le niveau demandé — la concurrence
est réelle, pas sérialisée. Le CPU du N100 reste sous 50 % au pire : **la machine n'est jamais le
facteur limitant**. Le nombre de threads ne bouge pas ; les handles montent avec la concurrence
puis **redescendent à 229**, leur valeur de repos.

## 3. Plafond de concurrence — comportement autoritaire

`STORAGE_AGENT_MAX_CONCURRENT_STREAMS=8`, compteur borné **sans file d'attente**.

| Situation | Attendu | Obtenu |
|---|---|---|
| 8 `GET` en vol | tous servis | **8/8 ouverts et servis** |
| 9ᵉ `GET` pendant saturation | 503 + `Retry-After` | **503 en 44 ms**, `retry-after: 1`, corps `STREAM_LIMIT_REACHED` |
| `HEAD` pendant saturation | 200 | **200 en 38 ms**, `content-length` exact |
| `/health` pendant saturation | 200 | **200 en 39 ms**, `activeStreams: 8`, `maxConcurrentStreams: 8` |

Le refus est immédiat et explicite ; `HEAD` et `/health` ne consomment jamais d'emplacement et
restent disponibles quand le disque sature. Journal de l'agent : exactement **1**
`STORAGE_AGENT_LIMIT_REACHED`, correspondant à ce test unique.

## 4. Ranges concurrents — vérification octet pour octet

8 plages simultanées à des positions différentes sur `MA_TÊTE.flac` (chemin accentué), chacune
comparée à la **même plage téléchargée depuis l'ancien agent** :

| Plage | Octets | Code | `Content-Range` | Contenu identique |
|---|---|---|---|---|
| début `0-262143` | 262 144 | 206 | exact | **OUI** |
| milieu | 262 144 | 206 | exact | **OUI** |
| fin `T-131072 … T-1` | 131 072 | 206 | exact | **OUI** |
| non alignée `12345-212344` | 200 000 | 206 | exact | **OUI** |
| petite `1000-1999` | 1 000 | 206 | exact | **OUI** |
| ~1 MiB | 1 048 576 | 206 | exact | **OUI** |
| reprise à 75 % | 65 536 | 206 | exact | **OUI** |
| dernier bloc | 65 536 | 206 | exact | **OUI** |

**8/8 conformes, les 8 plages servies en 168 ms.** Aucun mélange entre flux.

## 5. Équivalence de protocole ancien / nouveau

| Cas | HYDRA | Ancien | Verdict |
|---|---|---|---|
| Sans aucun en-tête | 401 | 401 | équivalent |
| Signature invalide | 401 | 401 | équivalent |
| Horodatage périmé (2 h) | 401 | 401 | équivalent |
| `x-hs-nonce` absent | 401 | 401 | équivalent |
| `x-hs-signature` absente | 401 | 401 | équivalent |
| **Rejeu de nonce** | 200 → **401** | 200 → **401** | équivalent |
| Piste inexistante | 404 | 404 | équivalent |

**7 cas sur 7 équivalents**, anti-rejeu compris.

## 6. Endurance — 45 minutes

Deux lecteurs simultanés enchaînant des pistes complètes sur toute la bibliothèque, avec un seek
de 1 MiB toutes les trois pistes, cadencés à ~5 Mo/s par lecteur. Le délai de lecture du client
est calé sur **`AUDIO_REMOTE_BODY_IDLE_TIMEOUT_MS=15000`** de la PROD : toute inactivité de plus
de 15 s serait comptée comme un `BODY_TIMEOUT`.

| | |
|---|---|
| Durée | **2 702 s** (45 min) |
| Pistes complètes vérifiées SHA-256 | **1 321** |
| Volume | **25,15 Gio** (27,0 Go) |
| Débit soutenu | **10,00 Mo/s** |
| TTFB min / méd / p95 / max | **73 / 81 / 257 / 1 071 ms** |
| Seeks | **440, dont 0 en échec** |
| **Erreurs** | **0** |
| **BODY_TIMEOUT** | **0** |

| Jalon | Pistes | TTFB moyen | Débit | Seeks KO | Erreurs |
|---|---|---|---|---|---|
| T+4 | 124 | 252 ms | 10,05 Mo/s | 0 | **0** |
| T+8 | 233 | 206 ms | 10,04 Mo/s | 0 | **0** |
| T+12 | 352 | 165 ms | 10,04 Mo/s | 0 | **0** |
| T+16 | 476 | 145 ms | 10,02 Mo/s | 0 | **0** |
| T+20 | 584 | 134 ms | 10,01 Mo/s | 0 | **0** |
| T+24 | 702 | 126 ms | 10,00 Mo/s | 0 | **0** |
| T+28 | 827 | 120 ms | 10,01 Mo/s | 0 | **0** |
| T+32 | 935 | 116 ms | 10,01 Mo/s | 0 | **0** |
| T+36 | 1 054 | 112 ms | 10,02 Mo/s | 0 | **0** |
| T+40 | 1 178 | 110 ms | 10,00 Mo/s | 0 | **0** |
| T+44 | 1 286 | 108 ms | 10,00 Mo/s | 0 | **0** |

Le TTFB moyen **descend** de 252 à 108 ms au fil de la campagne (le cache de pages se remplit) et
le débit ne bouge pas d'un centième. **Il n'y a aucune dérive** — ni de latence, ni de débit.

### Ce que la campagne Wi-Fi n'avait pas obtenu

| | Wi-Fi (2026-08-18, 20 min) | **Ethernet (2026-08-19, 45 min)** |
|---|---|---|
| Pistes | 370 | **1 321** |
| Volume | 7,14 Gio | **25,15 Gio** |
| Débit soutenu | 6,08 Mo/s | **10,00 Mo/s** (plafonné volontairement) |
| Erreurs | **2** (renégociations WPA) | **0** |
| BODY_TIMEOUT | 0 | **0** |

La réserve consignée en É5B-WIFI — « le zéro absolu devra être obtenu sur Ethernet, c'est là la
vraie porte » — **est levée** : zéro erreur sur 45 minutes et 25 Gio.

### Stabilité de la machine pendant l'endurance

| Grandeur | Début | Médiane | Fin |
|---|---|---|---|
| Processus agent | **pid 10544** | pid 10544 | **pid 10544 — jamais redémarré** |
| RSS | 61 Mo | 94 Mo | **96 Mo** |
| Handles | **229** | 229 | **229** |
| Threads | **12** | 12 | **12** |
| CPU | 6 % | 7 % | 3 % |
| WD Elements | 40 °C | 42 °C | 42 °C, **0 erreur de lecture** |
| File d'attente disque | 0 | 0 | max 2 |
| Erreurs / rejets réseau Ethernet | **0** | 0 | **0** |
| Service WireGuard | `Running` | `Running` | `Running` |
| Volume émis sur Ethernet | — | — | **30,0 Go** |

Trajectoire du RSS par huitième de campagne : 79 → 93 Mo pendant les dix premières minutes, puis
**93 – 95 Mo pendant les 35 suivantes**. C'est une montée en régime de V8 qui se stabilise, pas
une fuite : une fuite ne fait pas de palier. Les handles sont restés **exactement à 229** du début
à la fin.

### Journal de l'agent — lecture croisée

Le journal couvre `08-18 14:22` → `08-19 19:01`. Événements notables du 19 août :

| Heure | Événement | Nombre | Cause |
|---|---|---|---|
| 17:03 | `STORAGE_AGENT_STARTED` + `INDEX_LOADED` | 1 | démarrage après le rallumage physique |
| 17:47 | `AUTH_REJECTED` | 1 | mon premier `curl /health` sans signature |
| 18:07 | `LIMIT_REACHED` | 1 | le 9ᵉ `GET` du test de saturation |
| 18:07 | `REQUEST_ABORTED` | 9 | mes 8 flux lents volontairement abandonnés |
| 18:07 | `AUTH_REJECTED` | 6 | les 6 cas négatifs volontaires du §5 |

**Aucun `SHUTDOWN` depuis 17:03** : l'agent n'a pas redémarré une seule fois. Et surtout :
**de 18:08 à 19:01 — soit l'endurance entière et les quatre paliers — zéro `REQUEST_ABORTED`,
zéro `AUTH_REJECTED`, zéro `LIMIT_REACHED`.** Le client (VPS) et le serveur (HYDRA) rapportent
indépendamment le même zéro.

Débit de requêtes servies, tranches de 5 min pendant l'endurance : 146, 189, 193, 199, 200, 201,
189, 189, 194 — parfaitement plat.

## 7. Santé matérielle en fin de campagne

| Contrôle | Résultat |
|---|---|
| WD Elements | `Healthy`, 42 °C, **`ReadErrorsTotal=0`, `ReadErrorsUncorrected=0`** |
| SSD système | `Healthy`, 40 °C, 0 erreur |
| Événements `disk` / `storahci` / `USBSTOR` / `Ntfs` / `volmgr` / `usbhub` / `usbxhci` / `partmgr` sur 24 h | **AUCUN** |
| `D:` | `Healthy`, **175 fichiers, 3 585 487 704 o — inchangé au bit près** |
| Tailscale | `Running`, `ForceDaemon=true`, `Online=True` |
| WireGuard | `Running / Automatic` |
| Storage Agent | `Running / Automatic`, `NT SERVICE\HomeSpotifyStorageAgent` |
| PROD pendant toute la campagne | `/health` public **200**, `AUDIO_REMOTE_BASE_URL` sur `<OLD_AGENT_WG_IP>` |

Après **plus de 60 Go servis** au total dans la journée, le disque USB n'a pas produit une seule
erreur de lecture et aucun événement de décrochage.

---

## Verdict

| Critère demandé | Résultat |
|---|---|
| Débit / concurrence 1 → 8 | ✅ 33,7 → 57,3 Mo/s, 8 est bien la limite autoritaire |
| GET complets, Range concurrents, positions variées | ✅ |
| Fichiers petits / grands, Unicode, content-addressed | ✅ couverts à chaque niveau |
| Intégrité des octets | ✅ **SHA-256 sur chaque flux — 0 écart sur plus de 1 800 transferts vérifiés** |
| CPU / RSS / handles / threads relevés par niveau | ✅ |
| Température WD, activité disque, erreurs réseau | ✅ 42 °C stable, 0 erreur de lecture, 0 erreur Ethernet |
| Endurance révélant décrochage USB / reset WD / NTFS | ✅ 45 min, **aucun événement** |
| `BODY_TIMEOUT` | ✅ **0** |
| Crash Storage Agent | ✅ **0** — pid inchangé |
| Perte WireGuard | ✅ **0** |
| Fuite mémoire / handles | ✅ RSS en palier, handles identiques au début et à la fin |
| Dérive de latence | ✅ **aucune** — le TTFB s'améliore, le débit est plat |
| Comparaison ancien / nouveau, même jeu de fichiers | ✅ **10 à 15×** en faveur de HYDRA |
| PROD intacte | ✅ |

# H24_E5_PASS

Ethernet, stockage, agent et WireGuard sont **largement** assez rapides et assez stables pour la
production. Mise en perspective : une lecture FLAC temps réel consomme ~125 Ko/s et une variante
Opus 128 ~16 Ko/s. Le plancher mesuré à froid, 31 Mo/s, représente **environ 250 lectures FLAC
simultanées** — la contrainte réelle sera le plafond de 8 flux, pas le débit.
