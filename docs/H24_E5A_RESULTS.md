# HomeSpotify H24 — É5A : équivalence fonctionnelle de l'agent HYDRA (2026-08-18)

Qualification **fonctionnelle**, sur le réseau Wi-Fi actuel. La qualification de performance est
reportée à É5B, après passage en Ethernet.

**PROD inchangée** : `AUDIO_REMOTE_BASE_URL=http://<OLD_AGENT_WG_IP>:3100`, `/health` public 200.
Aucune suppression, double stockage maintenu.

---

## 1. Validation exhaustive

### HEAD sur les 175 entrées, sur les deux agents

| Agent | 200 + `content-length` exact | 404 | `content-length` KO | Autre |
|---|---|---|---|---|
| `<HYDRA_WG_IP>` (HYDRA) | **175 / 175** | 0 | 0 | 0 |
| `<OLD_AGENT_WG_IP>` (gros PC) | **175 / 175** | 0 | 0 | 0 |

Aucun 404, aucun écart de taille, aucune divergence de `relativePath` — chaque `trackId` résout
vers un fichier de taille identique à M0 sur les deux agents.

### GET complet + SHA-256 — 14 fichiers, 319,4 Mo

| Cas | trackId | Octets | SHA-256 | Durée |
|---|---|---|---|---|
| plus petit | 78 | 9 165 881 | ✅ | 1 475 ms |
| petit | 79 | 9 724 535 | ✅ | 1 297 ms |
| accent circonflexe `MA_TÊTE.flac` | 7 | 14 254 943 | ✅ | 1 940 ms |
| exclamation `IT_WAS_RIGHT!` | 64 | 14 806 357 | ✅ | 2 006 ms |
| objet récent | 175 | 16 481 222 | ✅ | 2 234 ms |
| objet récent | 174 | 17 602 626 | ✅ | 2 375 ms |
| moyen | 123 | 18 891 730 | ✅ | 2 631 ms |
| moyen | 54 | 18 915 969 | ✅ | 2 821 ms |
| apostrophe `I'm_Still_Standing` | 9 | 22 932 072 | ✅ | 3 096 ms |
| dièse `'80s_Pop_#1's` | 13 | 30 634 066 | ✅ | 4 176 ms |
| ASCII simple `AC_DC` | 2 | 32 736 249 | ✅ | 4 307 ms |
| parenthèses `1984_(Remastered)` | 4 | 33 231 759 | ✅ | 4 377 ms |
| grand (objet) | 166 | 46 572 846 | ✅ | 6 223 ms |
| plus grand (objet) | 168 | 48 987 568 | ✅ | 6 810 ms |

**14/14 conformes.** Petits, moyens et grands fichiers ; ASCII, accents, apostrophes, `#`,
parenthèses, `!` ; et objets adressés par contenu sous `.homespotify/objects`.

## 2. Ranges — comportement streaming

8 plages × 3 fichiers (accentué, ASCII, le plus grand) = **24/24 conformes**.

| Plage | Octets | Vérifié |
|---|---|---|
| début `0-262143` | 262 144 | 206 · `Content-Range` · contenu identique à l'ancien agent |
| milieu | 262 144 | idem |
| fin `T-131072 … T-1` | 131 072 | idem |
| non alignée `12345-212344` | 200 000 | idem |
| petite `1000-1999` | 1 000 | idem |
| ~1 MiB | 1 048 576 | idem |
| reprise à 75 % | 65 536 | idem |
| dernier bloc | 65 536 | idem |

Pour chaque plage : code **206**, `Content-Range: bytes d-f/T` exact, nombre d'octets exact, et
**empreinte du contenu identique à celle renvoyée par `<OLD_AGENT_WG_IP>` pour la même plage**. Le contenu
n'est donc pas seulement de la bonne taille : ce sont les mêmes octets.

## 3. Équivalence de protocole ancien / nouveau

| Cas | HYDRA | Gros PC | Verdict |
|---|---|---|---|
| Sans aucun en-tête | 401 | 401 | équivalent |
| Signature invalide | 401 | 401 | équivalent |
| Horodatage périmé (2 h) | 401 | 401 | équivalent |
| En-tête `x-hs-nonce` absent | 401 | 401 | équivalent |
| En-tête `x-hs-signature` absent | 401 | 401 | équivalent |
| **Rejeu de nonce** | 200 → **401** | 200 → **401** | équivalent |
| Piste inexistante | 404 | 404 | équivalent |

L'anti-rejeu fonctionne à l'identique : le même nonce accepté une fois est refusé ensuite, des
deux côtés.

## 4. Concurrence légère

4 flux simultanés de 2 MiB : **4/4** en 206, 2 097 152 octets chacun, **contenu identique à
l'ancien agent**, 1 366 ms cumulés. Aucun crash, aucune corruption, aucun mélange de flux.

## 5. Stabilité après campagne

| | |
|---|---|
| Storage Agent | `Running / Automatic` |
| Tunnel WireGuard | `Running / Automatic`, handshake frais |
| Processus `node` | 1 seul — **RSS 64,1 Mo**, 229 handles, 12 threads, 5,8 s CPU |
| WD Elements | `Healthy`, **36 °C**, 0 erreur de lecture |
| SSD | `Healthy`, 40 °C |
| Erreurs disque / USB / NTFS / usbhub sur 24 h | **AUCUNE** |
| Requêtes journalisées | 194 complétées, **0 abandonnée** |
| Avertissements | 9 × `STORAGE_AGENT_AUTH_REJECTED` |

Les 9 avertissements correspondent **exactement aux tests négatifs volontaires** du §3. Aucun n'est
un défaut : l'agent journalise les rejets d'authentification, ce qui est le comportement souhaité.

Le RSS a *baissé* pendant la campagne (76 Mo avant, 64 Mo après) : aucun signe de fuite après
319 Mo de lectures complètes, 24 plages et 4 flux concurrents.

**PROD** : `/health` 200, `api-shadow` actif, `AUDIO_REMOTE_BASE_URL` sur `<OLD_AGENT_WG_IP>`, deux pairs
avec handshakes frais. **Ancien agent** : `Running`, tunnel `Running`, requêtes servies
normalement pendant toute la campagne.

## 6. Correction sur le débit — le chiffre de 1,3 Mo/s était trompeur

En É4, la copie gros PC → HYDRA plafonnait à **1,3 Mo/s**. J'avais attribué cela au Wi-Fi. C'est
plus précis que cela : **les deux machines étaient sur le même Wi-Fi**, elles se partageaient donc
le temps d'antenne, chaque octet traversant la radio deux fois.

Le chemin réellement utilisé en production est différent — VPS → WireGuard → HYDRA — et il n'a
qu'un seul saut radio. Mesuré ici :

| Fichier | Taille | Durée | Débit |
|---|---|---|---|
| id 168 | 48 987 568 o | 6 810 ms | **7,2 Mo/s** |
| id 166 | 46 572 846 o | 6 223 ms | **7,5 Mo/s** |
| id 2 | 32 736 249 o | 4 307 ms | **7,6 Mo/s** |
| id 78 | 9 165 881 o | 1 475 ms | 6,2 Mo/s |

Soit environ **7 Mo/s ≈ 57 Mbit/s** sur le chemin de production, **déjà en Wi-Fi**. Pour
référence, un FLAC de la bibliothèque consomme ~125 Ko/s en lecture temps réel et une variante
Opus 128 environ 16 Ko/s : la marge actuelle est d'un facteur ~56 sur du FLAC.

Ce n'est pas la mesure finale — É5B la refera en Ethernet — mais cela retire l'inquiétude que le
chiffre d'É4 pouvait légitimement susciter.

---

## Verdict

| Critère | Résultat |
|---|---|
| HEAD exhaustif, `content-length` exact | ✅ 175/175 sur les deux agents |
| Aucun 404, aucun écart de chemin | ✅ |
| GET complet + SHA-256, cas représentatifs | ✅ 14/14 |
| Ranges (8 profils × 3 fichiers) | ✅ 24/24, contenu identique à l'ancien agent |
| Équivalence de protocole HMAC | ✅ 7 cas sur 7, anti-rejeu compris |
| Concurrence légère | ✅ 4/4, aucune corruption |
| Stabilité HYDRA | ✅ RSS stable, 0 erreur disque/USB, 0 flux abandonné |
| PROD intacte | ✅ |
| Ancien agent intact | ✅ |
| Échecs relevés par la campagne | **0** |

# H24_E5A_PASS

L'agent HYDRA est **fonctionnellement équivalent** à l'agent historique : mêmes codes, mêmes
tailles, mêmes octets, même protocole, mêmes erreurs.

---

## Ce qui reste à É5B — après Ethernet

1. Identification de l'interface Realtek et de sa nouvelle adresse.
2. Priorité Ethernet > Wi-Fi par métriques d'interface, sans routage ambigu.
3. Interdiction d'extinction sur la carte Ethernet — le réglage n'avait pas pris tant qu'elle
   était déconnectée.
4. Réservation DHCP stable.
5. Mise à jour de l'alias SSH LAN.
6. Vérification que WireGuard ne dépend pas de l'ancienne adresse Wi-Fi.
7. Revalidation SSH LAN, SSH Tailscale, WireGuard, agent, VPS → `<HYDRA_WG_IP>:3100`.
8. Puis charge (1 flux → plafond réel de 8), endurance dimensionnée pour détecter
   `BODY_TIMEOUT`, décrochage USB, reset USB, perte WireGuard, fuite mémoire ou handles.
9. Comparaison de latences ancien / nouveau sur le même jeu de pistes.

Restent ouverts par ailleurs : le test Tailscale **depuis l'extérieur du domicile** (avant É7) et
la passe de rattrapage finale de la bibliothèque.
