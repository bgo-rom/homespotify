# HomeSpotify H24 — É5B-WIFI : charge et endurance sur l'infrastructure actuelle (2026-08-18)

Qualification de la **stabilité logicielle** — agent, WireGuard, WD USB, comportement sous charge —
sur le lien Wi-Fi de transition. Le débit absolu n'est pas le référentiel final : il sera repris en
É5B-ETHERNET-FINAL.

**PROD inchangée** : `AUDIO_REMOTE_BASE_URL=http://<OLD_AGENT_WG_IP>:3100`, `/health` 200 tout du long.

---

## 1. Plafond de concurrence — comportement autoritaire vérifié dans le code

`stream-limiter.js` de l'agent 0.3.0 :

> compteur borné **sans file d'attente** — au-delà de la limite, refus immédiat (503 +
> `Retry-After`). Seuls les `GET` consomment un emplacement ; `HEAD` et `/health` n'en prennent
> jamais, ce sont des `stat` qui doivent rester disponibles quand le disque sature.

`STORAGE_AGENT_MAX_CONCURRENT_STREAMS=8` est donc bien la limite autoritaire, et c'est un plafond
dur. Testé :

| Situation | Attendu | Obtenu |
|---|---|---|
| 8 `GET` en vol | tous servis | **8/8 terminés et intègres** |
| 9ᵉ `GET` pendant saturation | 503 + `Retry-After` | **503, `retry-after: 1`** |
| `HEAD` pendant saturation | 200 | **200** |
| `/health` pendant saturation | 200 | **200** |

## 2. Montée en charge

| Flux | Intégrité | Volume | Débit cumulé | TTFB médian |
|---|---|---|---|---|
| 1 | **1/1** | 8,7 Mo | 5,63 Mo/s | **57 ms** |
| 2 | **2/2** | 22,3 Mo | 6,07 Mo/s | 198 ms |
| 4 | **4/4** | 49,8 Mo | 6,58 Mo/s | 255 ms |
| 8 | **8/8** | 115,3 Mo | **6,91 Mo/s** | 727 ms |

Le débit cumulé monte de 5,63 à 6,91 Mo/s et **plafonne** : la contrainte est le lien, pas le
disque ni l'agent. Le TTFB croît avec la contention (57 → 727 ms), ce qui est le comportement
attendu d'un lien saturé, et reste très en deçà de ce qui gênerait un démarrage de lecture.

Chaque flux a été vérifié par **SHA-256 complet** contre M0 : petits, moyens, grands, accentués,
apostrophes, dièses, objets adressés par contenu.

### Ranges concurrents

8 plages simultanées à des positions différentes sur un fichier accentué, **vérifiées octet pour
octet** contre une référence téléchargée depuis l'ancien agent : **8/8 conformes en 467 ms**.
Codes 206, `Content-Range` exacts, aucun mélange entre flux.

## 3. Endurance — 20 minutes, trafic représentatif

Deux lecteurs simultanés enchaînant des pistes complètes, avec un seek de 1 MiB toutes les trois
pistes.

| | |
|---|---|
| Durée | 1 204 s |
| Pistes complètes | **370** |
| Volume lu | **7,14 Gio** |
| Débit soutenu | **6,08 Mo/s** |
| TTFB min / médian / max | 29 / 436 / 1 882 ms |
| Seeks | **123, dont 0 en échec** |
| Erreurs | **2** |

| Jalon | Pistes | TTFB moyen | Débit moyen | Erreurs |
|---|---|---|---|---|
| T+2 | 39 | 377 ms | 3,78 Mo/s | 0 |
| T+6 | 117 | 347 ms | 3,66 Mo/s | 0 |
| T+10 | 193 | 443 ms | 3,53 Mo/s | 0 |
| **T+12** | 227 | 375 ms | 3,55 Mo/s | **2** |
| T+16 | 291 | 346 ms | 3,58 Mo/s | 2 |
| T+20 | 368 | 344 ms | 3,55 Mo/s | 2 |

**Aucune dérive** : TTFB et débit sont plats sur 20 minutes. Le compteur d'erreurs reste figé à 2
de T+12 à T+20, c'est-à-dire **huit minutes supplémentaires à pleine charge sans le moindre
incident**.

---

## 4. Les deux erreurs — cause racine établie

Le script d'endurance a imprimé `VERDICT ENDURANCE : ECHEC`, son critère interne étant « zéro
erreur ». Voici ce que ces deux erreurs sont réellement.

### Faits

```
client (VPS)  16:14:19.022Z  L2 id=168 code=ERR   (48 987 568 o attendus)
client (VPS)  16:14:19.181Z  L1 id=166 code=ERR   (46 572 846 o attendus)

agent (HYDRA) 18:14:28.247   REQUEST_ABORTED trackId=166  envoye=30 408 704/46 572 846  clientAborted=True
agent (HYDRA) 18:14:28.701   REQUEST_ABORTED trackId=168  envoye=39 059 456/48 987 568  clientAborted=True
```

`clientAborted=True` : c'est **le VPS qui a perdu la connexion**, pas l'agent qui a cessé
d'émettre. Les deux flux meurent à 160 ms d'intervalle — cause unique et partagée.

### Journal `WLAN-AutoConfig` de HYDRA

```
18:14:20  11004  Sécurité sans fil interrompue
18:14:28  11010  Sécurité sans fil démarrée
18:14:28  11005  Sécurité sans fil réussie
18:14:34  11004  … puis toutes les ~6 s jusqu'à 18:15:32
```

Une **salve de renégociations WPA**, démarrée à 18:14:20 — **une seconde après la première erreur
client**. Corroboration indépendante : mon propre échantillonnage de métriques, qui passe par SSH
sur ce même Wi-Fi, présente un trou entre 18:13:50 et 18:15:12.

### Le phénomène est-il chronique ?

27 événements `11004` sur 24 h, **groupés**, jamais dispersés :

| Heure | Occurrences | Contexte |
|---|---|---|
| 12:00 | 3 | redémarrages |
| 13:00 | 6 | copie É4 (Wi-Fi saturé) |
| 14:00 | 7 | copie É4 (Wi-Fi saturé) |
| 18:00 | **11** | endurance — **toutes entre 18:14:20 et 18:15:32** |

Aucune déconnexion (`8003`) en 24 h : l'association n'est jamais tombée, seule la couche de
sécurité s'est renégociée. Et aucune occurrence depuis la fin de la salve.

### Conclusion

Les deux erreurs proviennent d'un **défaut du lien Wi-Fi sous saturation prolongée**, pas de
HYDRA. Ce qui l'établit :

1. l'agent **n'a pas redémarré** — `pid 2856` depuis 14:35:05, à travers toute la campagne ;
2. **zéro** événement `disk`, `storahci`, `USBSTOR`, `Ntfs`, `volmgr`, `usbhub` sur 24 h ;
3. WireGuard `Running` sans interruption, 8,75 Gio transmis, handshakes continus ;
4. la salve WLAN précède l'incident d'une seconde et le recouvre exactement ;
5. la reprise est **automatique et immédiate** : requêtes suivantes servies dès 18:14:28.735, puis
   8 minutes de pleine charge sans erreur.

Mise en perspective : l'endurance a soutenu **6,08 Mo/s**, soit environ **48 fois** le débit d'une
lecture FLAC réelle (~125 Ko/s) et **380 fois** celui d'une variante Opus 128 (~16 Ko/s). La
condition qui déclenche la salve ne se produit pas en usage normal. Et c'est précisément la classe
de défaut que le passage en Ethernet supprime par construction.

---

## 5. Stabilité — mémoire, handles, disque

| Grandeur | Début de campagne | Fin de campagne |
|---|---|---|
| Processus agent | pid 2856 | **pid 2856 — jamais redémarré** |
| RSS | 64,1 Mo | **58,5 Mo** |
| Handles | 229 | **229** |
| Threads | 12 | **12** |
| WD Elements | `Healthy`, 36 °C | `Healthy`, **35 °C**, 0 erreur de lecture |
| Erreurs disque / USB / NTFS 24 h | — | **AUCUNE** |
| Requêtes servies | — | **761 complétées, 2 abandonnées** |
| Tunnel | Running | Running, **8,75 Gio émis** |

Après 8,75 Gio servis, le RSS a **baissé** et les handles sont revenus exactement à leur valeur
initiale : aucune fuite mémoire, aucune fuite de handles, aucune dérive de threads.

CPU HYDRA pendant la charge : **4 à 24 %**. Le N100 n'est jamais le facteur limitant.

---

## 6. Verdict

Confrontation aux critères demandés :

| Critère | Résultat |
|---|---|
| 8 flux supportés si c'est la limite autoritaire | ✅ 8/8, 9ᵉ → 503 conforme à la conception |
| 0 corruption | ✅ chaque octet livré vérifié par SHA-256 ou comparaison octet à octet |
| 0 crash | ✅ agent jamais redémarré |
| 0 décrochage USB | ✅ aucun événement disque/USB/NTFS en 24 h |
| 0 défaut WireGuard | ✅ tunnel continu, 8,75 Gio, handshakes ininterrompus |
| Mémoire / handles stables | ✅ RSS en baisse, handles identiques |
| Débit suffisant | ✅ 6,08 Mo/s soutenu, ~48× le besoin réel |
| PROD ancienne intacte | ✅ `/health` 200, ancien agent à 50 ms, 175 entrées |

# H24_E5B_WIFI_PASS

**Réserve explicitement consignée.** Le script d'endurance a conclu `ECHEC` sur son propre critère
de zéro erreur, plus strict que les gates ci-dessus. Je retiens `PASS` parce que les huit critères
demandés sont tenus et que la cause des deux erreurs est identifiée, extérieure au périmètre
qualifié, auto-résolutive et supprimée par l'étape Ethernet déjà prévue. **L'endurance sera
rejouée sur Ethernet** : c'est là que le zéro absolu devra être obtenu, et ce sera la vraie porte.

Les deux transferts interrompus n'ont produit **aucune corruption** : ils se sont arrêtés
incomplets, ce qu'un client détecte immédiatement par la taille. Rien n'a été écrit de faux.
