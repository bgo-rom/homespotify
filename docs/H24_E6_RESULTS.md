# HomeSpotify H24 — É6 : redémarrage à froid, rattrapage et revalidation (2026-08-18)

Exécuté immédiatement après É5B-WIFI, sans attendre le switch Ethernet.
**PROD inchangée** : `AUDIO_REMOTE_BASE_URL=http://<OLD_AGENT_WG_IP>:3100`. Aucune suppression.

---

## 1. Redémarrage à froid

Lancé à 18:28:06, sans session ouverte, après une campagne ayant servi 8,75 Gio.

| Repère | Δ T0 |
|---|---|
| Coupure réseau | 22 s |
| SSH LAN utilisable | **77 s** |
| SSH Tailscale utilisable | **78 s** |
| `LastBootUpTime` | 18:28:57 |

## 2. Remontée automatique — chaîne complète

| Composant | État |
|---|---|
| `sshd` | `Running / Automatic` |
| `Tailscale` | `Running / Automatic` |
| `WireGuardTunnel$HomeSpotify-VPS` | `Running / Automatic` |
| `HomeSpotifyStorageAgent` | `Running / Automatic` |
| Session console | **aucune** |
| Adresses | `<HYDRA_WG_IP>` (tunnel), `<HYDRA_WIFI_LAN_IP>` (Wi-Fi), `<HYDRA_TAILSCALE_IP>` (Tailscale) |
| Écoute | `<HYDRA_WG_IP>:3100` |
| `D:` | **175 fichiers**, 3,56 Go, `Healthy` |
| WD Elements | `Healthy`, 35 °C, **0 erreur de lecture** |
| Erreurs disque / USB / NTFS depuis le boot | **AUCUNE** |

Journal de l'agent au démarrage :

```
STORAGE_AGENT_INDEX_LOADED  entryCount=175  generatedAt=2026-08-17T19:10:19.858Z
STORAGE_AGENT_STARTED       host=<HYDRA_WG_IP>  port=3100  maxConcurrentStreams=8
```

L'ordre est respecté : tunnel monté, puis agent lié à une adresse qui existe. Aucune intervention.

## 3. Lecture réelle depuis le VPS après redémarrage

| | `<OLD_AGENT_WG_IP>` | `<HYDRA_WG_IP>` |
|---|---|---|
| `/health` | 200 · 54 ms | 200 · 72 ms |

Même piste, `Range bytes=0-2097151`, sur les deux agents :

| trackId | Ancien | Nouveau | Octets identiques |
|---|---|---|---|
| 7 (accentué) | 206 · 27 ms | 206 · 1 185 ms | **OUI** |
| 13 (dièse) | 206 · 51 ms | 206 · 32 ms | **OUI** |
| 168 (le plus grand) | 206 · 33 ms | 206 · 92 ms | **OUI** |
| 2 (ASCII) | 206 · 55 ms | 206 · 43 ms | **OUI** |

Contenu strictement identique dans les quatre cas. Les latences sont du même ordre ; le pic à
1 185 ms sur la première requête est un réveil de tête de lecture du disque USB, non reproduit sur
les suivantes.

## 4. Snapshot courant et delta

| | M0 (avant copie) | M2 (maintenant) |
|---|---|---|
| `indexGeneratedAt` | `2026-08-17T19:10:19.858Z` | **identique** |
| Entrées | 175 | **175** |
| Fichiers `.flac` sur le gros PC | 175 | **175** |

| Delta M0 → M2 | Nombre |
|---|---|
| Nouveaux | **0** |
| Modifiés | **0** |
| Disparus | **0** |

**La passe de rattrapage est sans objet** : aucune piste n'a été ajoutée ni modifiée depuis M0.
Je le constate explicitement plutôt que de sauter l'étape en silence. Une nouvelle passe restera
obligatoire juste avant É7, sur un snapshot régénéré à ce moment-là.

## 5. Revérification intégrale après redémarrage

Rejouée en entier sur HYDRA, après le redémarrage à froid **et** après les 7,14 Gio lus pendant
l'endurance :

```
=== VERIFICATION M0 -> HYDRA ===
  entrees manifeste : 175
  fichiers presents : 175
  paths exacts      : 175/175
  sizes exactes     : 175/175
  SHA-256 exacts    : 175/175
  manquants         : 0
  hors manifeste (non supprimes) : 0
  VERDICT VERIFICATION : PASS
```

Aucun octet n'a bougé.

## 6. Index — republication

L'index n'ayant pas changé, il n'y avait rien à republier. Vérification que les deux côtés portent
bien le même fichier :

| | SHA-256 |
|---|---|
| Gros PC | `8e3e3f477cd20790df62f780be0b18ef94e62e8418aeb9f7f77c6c08df0980f7` |
| HYDRA | **identique** |

## 7. État final

| | |
|---|---|
| PROD `/health` public | **200** |
| `api-shadow` | actif |
| `AUDIO_REMOTE_BASE_URL` | `http://<OLD_AGENT_WG_IP>:3100` — **inchangé** |
| Pairs WireGuard | 2, handshakes frais (5 s et 1 min 20) |
| Ancien agent + tunnel (gros PC) | `Running` |
| Nouvel agent + tunnel (HYDRA) | `Running` |

---

# H24_E6_PASS

Le double stockage survit à un redémarrage à froid : la chaîne remonte seule en 78 secondes,
l'intégrité des 175 fichiers est intacte au bit près, et les deux agents servent des octets
identiques.

---

## Reste à faire avant É7

| # | Élément | État |
|---|---|---|
| 1 | Switch Ethernet branché | **en attente de livraison** |
| 2 | É5B-ETHERNET-FINAL | bloqué par 1 |
| 3 | Test Tailscale depuis l'extérieur (4G/5G) | à faire |
| 4 | Dernière passe de rattrapage sur snapshot régénéré | à faire juste avant É7 |
| 5 | Sauvegarde de l'environnement PROD | à faire au moment d'É7 |
| 6 | Feu vert explicite | requis |

Rappel de cap : les fichiers sur HYDRA sont **temporaires**, pour qualification et rollback. Le
reset coordonné à zéro musique viendra après la bascule validée et une période de stabilité, avec
sauvegarde base + stockage + caches.
