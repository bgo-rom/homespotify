# HomeSpotify H24 — É5B-ETHERNET-FINAL : réseau nominal, charge et endurance (2026-08-19)

Qualification finale de HYDRA sur son réseau **définitif** : Ethernet gigabit vers le switch relié
à la Freebox. Reprend et remplace les chiffres de débit d'É5B-WIFI, dont seule la partie
« stabilité logicielle » restait acquise.

**PROD inchangée pendant toute cette étape** : `AUDIO_REMOTE_BASE_URL=http://<OLD_AGENT_WG_IP>:3100`,
`/health` public 200. Aucune suppression, double stockage maintenu.

---

## 0. Redémarrage à froid réel — la chaîne est-elle revenue seule ?

Le propriétaire a **éteint puis rallumé** HYDRA pour brancher le câble Ethernet. Cette extinction
est **volontaire et déclarée** : l'événement `Kernel-Power 41` qui en résulte n'est pas une panne.

```
08-19 17:01:18  Kernel-Power id=41   « redémarré sans s'arrêter correctement »
08-19 17:01:25  EventLog     id=6008 « arrêt système précédent à 16:46:10 non prévu »
```

Extinction 16:46:10, rallumage 17:01:17 — soit 15 minutes de coupure, exactement la fenêtre de
l'intervention physique. **Aucun autre `41` sur 24 h.**

Chaîne relevée après ce démarrage, sans aucune intervention :

| Contrôle demandé | Résultat |
|---|---|
| HYDRA accessible | ✅ SSH — **sur une nouvelle adresse**, voir §1 |
| `D:` présent | ✅ `Healthy` / `OK`, 3 726 Go, **175 fichiers, 3 585 487 704 o** |
| WD Elements | ✅ `Healthy`, bus USB, 40 °C, **0 erreur de lecture** (`ReadErrorsTotal=0`) |
| `sshd` | ✅ `Running / Automatic` |
| `Tailscale` | ✅ `Running / Automatic`, `BackendState=Running`, **`ForceDaemon=true`** (non surveillé) |
| WireGuard `HomeSpotify-VPS` | ✅ `Running / Automatic` |
| `<HYDRA_WG_IP>` présent | ✅ interface `HomeSpotify-VPS` |
| Handshake VPS frais | ✅ **8 s** au moment du relevé, 8,74 Gio reçus côté VPS |
| Storage Agent | ✅ `Running / Automatic`, compte `NT SERVICE\HomeSpotifyStorageAgent` |
| `<HYDRA_WG_IP>:3100` en écoute | ✅ pid 10544, **lié à la seule adresse du tunnel** |
| Health HMAC depuis le VPS | ✅ **200**, `agentVersion 0.3.0`, `indexEntryCount 175`, `musicRootAvailable true` |
| Index HYDRA cohérent | ✅ `indexGeneratedAt 2026-08-17T19:10:19.858Z` — **identique à l'ancien agent** |
| Problèmes USB / NTFS / disque | ✅ **AUCUN** événement `disk`, `storahci`, `USBSTOR`, `Ntfs`, `volmgr`, `usbhub`, `usbxhci`, `partmgr` sur 24 h |

L'agent s'est lié à `<HYDRA_WG_IP>` après montée du tunnel : la dépendance de service tient. Horloge
vérifiée contre le VPS — **HYDRA 15:50:53Z, VPS 15:51:23Z** : l'écart est très en deçà des 60 s
tolérés par `STORAGE_AGENT_HMAC_MAX_CLOCK_SKEW_SECONDS`.

**Ce démarrage à froid compte comme une preuve H24 réelle** : coupure secteur non planifiée du
point de vue de la machine, remontée complète et automatique de la chaîne, aucune session ouverte
nécessaire pour servir.

---

## 1. Bascule du réseau nominal vers Ethernet

### 1.1 Ce que le lien est réellement

Aucune ancienne adresse n'a été supposée. La machine avait **changé d'adresse** : `<HYDRA_WIFI_LAN_IP>`
(Wi-Fi) ne répondait plus. HYDRA a été retrouvée par balayage ARP + port 22 du `/24`.

| | |
|---|---|
| Carte | **Realtek PCIe GbE Family Controller** (`PCI\VEN_10EC&DEV_8168`), `ifIndex=10` |
| MAC | **`<HYDRA_ETHERNET_MAC>`** |
| IPv4 | **`<HYDRA_LAN_IP>/24`**, origine **DHCP** (bail restant 11 h 10 au relevé) |
| Passerelle | `<LAN_GATEWAY>` (Freebox `<WIFI_SSID>`) |
| DNS | `1.1.1.1`, `1.0.0.1` |
| Négociation | **auto → 1 Gbit/s, full duplex**, `MediaType=802.3` |
| Profil réseau | `<WIFI_SSID>`, catégorie **Public**, `IPv4Connectivity=Internet` |
| IP publique vue | `<HOME_PUBLIC_IP>` — identique à l'endpoint WireGuard vu par le VPS |

### 1.2 Ce qui a été changé

Baseline horodatée écrite avant modification :
`C:\ProgramData\HomeSpotify-H24\baseline-ethernet-20260819-175558.txt`

| Réglage | Avant | Après | Raison |
|---|---|---|---|
| Métrique Ethernet | 25 (auto) | **10 (fixe)** | ordre déterministe, plus soumis au recalcul automatique |
| Métrique Wi-Fi | 50 (auto) | **60 (fixe)** | garantit Ethernet < Wi-Fi quelles que soient les conditions |
| `PnPCapabilities` carte Ethernet | absent | **24** | « Autoriser l'ordinateur à éteindre ce périphérique » **décoché** ; le réglage était impossible tant que la carte était déconnectée (cf. É5A) |
| `SelectiveSuspend` Ethernet | `Enabled` | `Disabled` (`-NoRestart`) | appliqué sans couper le lien ; effectif au prochain reset de carte |
| Wi-Fi | actif | **actif, non désactivé** | conservé en secours, conformément à la consigne |

### 1.3 Routes et absence de conflit

```
iface=Ethernet   nexthop=<LAN_GATEWAY>  routeMetric=0    ifMetric=10  total=10
iface=Wi-Fi      nexthop=<LAN_GATEWAY>  routeMetric=0    ifMetric=60  total=60
iface=Radmin VPN nexthop=<RADMIN_VPN_GW>       routeMetric=9256 ifMetric=1   total=9257
```

Une seule route par défaut gagnante, l'Ethernet, avec 50 points d'écart. Les routes `/32` du
tunnel (`<VPS_WG_IP>`, `<HYDRA_WG_IP>`) et de Tailscale restent portées par leurs interfaces propres :
aucune ambiguïté.

### 1.4 Indépendance de WireGuard et Tailscale vis-à-vis de l'IP LAN

```ini
[Interface]
Address = <HYDRA_WG_IP>/32
[Peer]
Endpoint = <VPS_PUBLIC_IP>:51820     # IP publique du VPS
AllowedIPs = <VPS_WG_IP>/32
PersistentKeepalive = 25
```

La configuration du tunnel **ne référence aucune adresse LAN** : elle sort par la route par défaut,
quelle qu'elle soit. Tailscale de son côté a renégocié seul (`gateway and self IP changed:
gw=<LAN_GATEWAY> self=<HYDRA_LAN_IP>`), obtenu un mappage UPnP et un endpoint IPv4 public direct,
DERP le plus proche **Paris à 12,4 ms**. Un changement d'adresse LAN ne casse donc **ni PROD ni
l'accès de secours**.

Pare-feu inchangé et toujours minimal :

| Règle | Port | Autorisé depuis | Interface |
|---|---|---|---|
| `OpenSSH-Server-In-TCP` | 22 | `<LAN_SUBNET>` | toutes |
| `OpenSSH-Server-In-TCP-Tailscale` | 22 | 2 pairs Tailscale nommés | `Tailscale` |
| `HomeSpotify-StorageAgent-3100-WireGuard-VPS` | 3100 | **`<VPS_WG_IP>` uniquement** | toutes |

### 1.5 Alias SSH

`~/.ssh/config` mis à jour (sauvegarde `config.bak-h24-*` conservée) :
`homespotify-minipc` → **`<HYDRA_LAN_IP>`**. Testé : `HYDRA` répond.

### 1.6 Wi-Fi de secours — état exact

Le Wi-Fi est **déconnecté, pas désactivé**. C'est le comportement par défaut de Windows
(`fMinimizeConnections` absent ⇒ valeur 1, « soft disconnect ») : le Wi-Fi est libéré tant qu'un
lien filaire est présent, et repris s'il disparaît.

| Contrôle | Valeur |
|---|---|
| `AdminStatus` carte Wi-Fi | **`Up`** — jamais désactivée |
| Statut radio | **Matériel activé** |
| Profil `<WIFI_SSID>` | **connexion automatique** |
| Métrique | 60 — reprend la route par défaut si l'Ethernet tombe |

**Réserve explicite** : la bascule Ethernet → Wi-Fi n'a **pas** été déclenchée en vrai. La
provoquer (`Disable-NetAdapter Ethernet`) couperait mon propre accès sans filet, le client
Tailscale du gros PC étant hors ligne. Ce qui est établi est structurel — carte active, profil en
connexion automatique, métrique de repli correcte. Ce qui ne l'est pas : le temps de reprise.

### 1.7 Réservation DHCP

Le bail est stable et **PROD ne dépend pas de l'adresse LAN** : le trafic audio passe par
`<HYDRA_WG_IP>` dans le tunnel. La qualification n'est donc pas bloquée. La réservation demande
l'interface d'administration de la Freebox, non accessible depuis ici :

`ACTION_UTILISATEUR_MINIPC: créer une réservation DHCP pour MAC <HYDRA_ETHERNET_MAC> -> IP <HYDRA_LAN_IP>`

Sans elle, seul l'alias SSH d'administration serait à corriger si le bail changeait.

### 1.8 Validation des chemins

| Chemin | Résultat |
|---|---|
| SSH Ethernet (`<HYDRA_LAN_IP>`) | ✅ |
| Internet depuis HYDRA | ✅ DNS `nodejs.org`, TCP `1.1.1.1:443`, IP publique `<HOME_PUBLIC_IP>` |
| WireGuard | ✅ tunnel `Running`, handshake frais, ping VPS → `<HYDRA_WG_IP>` 18,6–19,3 ms, 0 % perte |
| VPS → Storage Agent HYDRA | ✅ `/health` HMAC **200** |
| SSH Tailscale | ⚠️ **non rejouable depuis ici** — voir ci-dessous |

Le client Tailscale du **gros PC** n'existe plus (aucun service, aucune entrée de désinstallation ;
le tailnet le voit `offline, last seen 23h ago`). Le chemin avait été prouvé de bout en bout en É6
le 2026-08-18 (SSH Tailscale utilisable 78 s après un démarrage à froid). Côté HYDRA tout est vert :
démon `Running`, `ForceDaemon=true`, nœud `Online=True`, `sshd` en écoute sur `0.0.0.0:22`, règle
pare-feu Tailscale intacte. Réinstaller un client Tailscale sur la machine principale du
propriétaire dépasse le périmètre de cette tâche.

---
