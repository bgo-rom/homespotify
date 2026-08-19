# HomeSpotify H24 — É6 final : redémarrage de confirmation, snapshot F0 et rattrapage (2026-08-19)

Exécuté après `H24_E5_PASS`, sur le réseau Ethernet définitif. Remplace et complète le premier É6
du 2026-08-18, qui avait été joué avant le passage en Ethernet.

**PROD encore inchangée à ce stade** : `AUDIO_REMOTE_BASE_URL=http://<OLD_AGENT_WG_IP>:3100`.
**Aucune suppression, aucun déplacement, aucun MIR, aucune purge.**

---

## 1. Deux redémarrages, pas un

| | Redémarrage 1 — **coupure physique** | Redémarrage 2 — **logiciel, contrôlé** |
|---|---|---|
| Nature | extinction secteur pour brancher l'Ethernet | `shutdown /r /t 0` déclenché à distance |
| Heure | arrêt 16:46:10 → boot 17:01:17 | 19:08:02 → boot **19:08:44** |
| Trace | `Kernel-Power 41` + `EventLog 6008` | `User32 1074` + `Kernel-Power 109` (`Power Action Reboot`) — **arrêt propre, aucun `41`** |
| Coupure réseau réelle | ~15 min (intervention) | **33 s** |
| SSH LAN utilisable | (nouvelle adresse, cf. É5B) | **T+57 s** |
| Storage Agent en écoute `:3100` | ✅ | **T+192 s** (`delayedAutoStart`) |
| `/health` HMAC 200 depuis le VPS | ✅ | **T+193 s** |

Le second redémarrage confirme le premier **et** vérifie que la configuration Ethernet appliquée
en É5B survit à un cycle complet.

### Remontée automatique, redémarrage 2

| Composant | État à T+2 min 42 s |
|---|---|
| `sshd` | `Running / Automatic` |
| `Tailscale` | `Running / Automatic` — `<HYDRA_TAILSCALE_IP>` remonté |
| `WireGuardTunnel$HomeSpotify-VPS` | `Running / Automatic` — `<HYDRA_WG_IP>` présent |
| `HomeSpotifyStorageAgent` | `Running / Automatic`, **pid 1368**, lié à `<HYDRA_WG_IP>:3100` |
| **Session console** | **AUCUNE** — la machine sert sans que personne ne soit connecté |
| Adresse LAN | **`<HYDRA_LAN_IP>` conservée** (bail DHCP stable au redémarrage) |
| Métriques | Ethernet **10**, Wi-Fi **60** — conservées |
| `D:` | `Healthy`, WD Elements `Healthy` |
| Événements disque / USB / NTFS depuis le boot | **AUCUN** |

Journal de l'agent au démarrage :

```
STORAGE_AGENT_SHUTDOWN     pid=10544 signal=SIGINT          (arrêt propre)
STORAGE_AGENT_INDEX_LOADED pid=1368  entryCount=175  generatedAt=2026-08-17T19:10:19.858Z
Server listening at http://<HYDRA_WG_IP>:3100
STORAGE_AGENT_STARTED      host=<HYDRA_WG_IP> port=3100 maxConcurrentStreams=8 indexEntryCount=175
```

L'ordre tient : arrêt propre, tunnel monté, puis liaison de l'agent à une adresse qui existe.

### Réserve : extinction de la carte Ethernet

`PnPCapabilities = 24` est bien écrit et **persiste après redémarrage**, mais le pilote Realtek
continue de rapporter `MSPower_DeviceEnable = True` et `SelectiveSuspend = Enabled`. Le réglage
n'a donc **pas visiblement pris**. Trois raisons de ne pas insister ici :

1. il est **inerte en pratique** — la veille système et l'hibernation sont désactivées, la mise en
   veille du disque aussi, et `PowerSavingMode = 0` sur la carte ;
2. les faits le confirment — **48 minutes de charge soutenue, 30 Go émis, zéro erreur, zéro rejet,
   zéro renégociation de lien** ;
3. forcer les propriétés restantes (`EnableGreenEthernet`, `PowerDownPll`) exige un **reset de la
   carte**, donc la coupure de la seule voie d'accès distante à la machine, juste avant une
   bascule de production. Reporté à une intervention avec présence physique.

---

## 2. Snapshot F0 — état **réel** de la bibliothèque source

Je ne suis parti d'aucune constante. Le manifeste M0 d'É4 comptait 175 entrées, mais il avait été
construit **depuis l'index** de l'agent. Un parcours **intégral du système de fichiers** de
`F:\dev\homespotify\storage\music` donne un autre chiffre :

| | Fichiers | Octets |
|---|---|---|
| M0 (index, 2026-08-18) | 175 | 3 585 487 704 |
| **F0 (parcours réel, 2026-08-19)** | **177** | **3 606 364 722** |

### Delta apparu depuis É4

| Sens | Nombre | Détail |
|---|---|---|
| Nouveaux | **2** | `.gitkeep` (0 o) et `Artiste_inconnu/Album_inconnu/Ajna___Britney_(All_Black).wav` (20 877 018 o, mtime 2026-07-09) |
| Modifiés | **0** | — |
| Disparus | **0** | — |

Le `.wav` **n'est catalogué nulle part** : la base PROD ne contient aucune ligne `tracks` pointant
vers un `.wav`, et l'index de l'agent ne le connaît pas. C'est un fichier orphelin, antérieur à
M0, que le manifeste bâti sur l'index ne pouvait pas voir. Il est copié quand même : le miroir
doit être exact, et la décision de l'intégrer ou non au catalogue est un autre sujet.

## 3. Rattrapage — **additif uniquement**

Les 2 fichiers ont été copiés vers `D:\HomeSpotifyStorage\music`, en créant les dossiers manquants
et **sans toucher à quoi que ce soit d'autre**. Aucun `MIR`, aucune purge, aucune suppression,
aucun déplacement.

### Vérification F1, immédiatement après la copie

```
=== VERIFICATION F1 : gros PC -> HYDRA ===
  source  : 177 fichiers, 3606364722 o
  HYDRA   : 177 fichiers, 3606364722 o
  paths exacts        : 177/177
  tailles exactes     : 177/177
  SHA-256 exacts      : 177/177
  NFC source / HYDRA  : 177/177 et 177/177
  manquants sur HYDRA : 0
  hors source (non supprimés) : 0
  chemins non-ASCII : 37, divergences d'encodage UTF-8 : 0
  VERDICT : PASS
```

Les 37 chemins non-ASCII (accents, `Ê`, `É`, apostrophes typographiques `’`, `#`, parenthèses)
sont **identiques octet pour octet en UTF-8** des deux côtés, et **tous en forme NFC**.

## 4. Dernière passe — snapshot F2, après le redémarrage

Rejouée intégralement après le redémarrage de confirmation, juste avant É7 :

```
=== F2 : SNAPSHOT FINAL APRES REDEMARRAGE ===
  source gros PC : 177 fichiers, 3606364722 o (2026-08-19T17:15:44Z)
  HYDRA          : 177 fichiers, 3606364722 o (2026-08-19T17:15:21Z)
  paths exacts    : 177/177
  tailles exactes : 177/177
  SHA-256 exacts  : 177/177
  manquants       : aucun
  hors source     : aucun
  HYDRA avant / après redémarrage : 0 octet modifié
```

**Aucun octet n'a bougé** entre F1 et F2 : le redémarrage n'a rien altéré. La bibliothèque n'a pas
évolué non plus côté source pendant l'opération — F0, F1 et F2 donnent le même total.

## 5. Index — publication et équivalence

L'index n'a **pas** été régénéré, et c'est délibéré : les 2 fichiers ajoutés ne sont pas des
pistes du catalogue (`.gitkeep` et un `.wav` orphelin). Régénérer l'index aurait modifié la
surface exposée par la PROD, ce qui sort du périmètre d'une migration de stockage.

Vérification que les deux agents portent **le même index** :

| | Gros PC `<OLD_AGENT_WG_IP>` | HYDRA `<HYDRA_WG_IP>` |
|---|---|---|
| Chemin | `C:\ProgramData\HomeSpotify\StorageAgent\data\index.json` | identique |
| Taille | 15 107 o | **15 107 o** |
| SHA-256 | `8e3e3f477cd20790df62f780be0b18ef94e62e8418aeb9f7f77c6c08df0980f7` | **identique** |
| `version` / `generatedAt` | 1 / `2026-08-17T19:10:19.858Z` | **identiques** |
| Entrées | 175 | **175** |
| `MUSIC_ROOT` | `F:\dev\homespotify\storage\music` | `D:\HomeSpotifyStorage\music` |
| Chargé par l'agent (`/health`) | `indexEntryCount: 175` | **`indexEntryCount: 175`** |

Le seul écart entre les deux configurations est la racine du stockage — exactement ce qui doit
différer.

---

## 6. État à la sortie d'É6

| | |
|---|---|
| `/health` public | **200** |
| `api-shadow` | actif |
| `AUDIO_REMOTE_BASE_URL` | `http://<OLD_AGENT_WG_IP>:3100` — **encore inchangé** |
| Agent `<OLD_AGENT_WG_IP>` | `/health` **200** en 48 ms, 175 entrées |
| Agent `<HYDRA_WG_IP>` | `/health` **200** en 42 ms, 175 entrées |
| Pairs WireGuard | 2, handshakes frais (1 min 51 s et 1 min 53 s) |
| Bibliothèque | **177/177 identiques au bit près des deux côtés** |

---

# H24_E6_PASS

| Critère demandé | Résultat |
|---|---|
| Cold boot du jour vérifié | ✅ (É5B §0) |
| Redémarrage logiciel supplémentaire | ✅ arrêt propre, remontée complète en 193 s |
| SSH LAN | ✅ T+57 s |
| SSH Tailscale | ⚠️ côté HYDRA vert ; client absent sur le gros PC (cf. É5B §1.8) |
| WireGuard | ✅ |
| Storage Agent | ✅ |
| `D:` | ✅ |
| Aucune session utilisateur nécessaire | ✅ **console vide** |
| Snapshot F0 sur l'état réel, pas sur 175 | ✅ **177 fichiers trouvés** |
| relativePath / taille / SHA-256 / UTF-8 / NFC | ✅ |
| Copie additive du delta | ✅ 2 fichiers, aucune suppression |
| N/N path, size, SHA après rattrapage | ✅ **177/177/177** |
| Index republié / équivalent | ✅ identique au SHA-256 près, 175 entrées des deux côtés |
| Dernière passe juste avant É7 | ✅ F2, **0 écart** |
