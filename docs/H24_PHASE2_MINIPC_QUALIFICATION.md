# HomeSpotify H24 — Phase 2 : qualification du mini-PC HYDRA (2026-08-18)

Inventaire **en lecture seule**, réalisé à distance en SSH depuis `<GROS_PC_HOSTNAME>`.
Aucune migration, aucune modification de PROD, `AUDIO_REMOTE_BASE_URL` intact.
Seule modification faite sur HYDRA : la règle de pare-feu OpenSSH entrante (profil `Private` → `Any`),
nécessaire pour ouvrir l'accès d'administration.

> `<OTHER_LAN_HOSTNAME> / <LAN_OTHER_HOST>` **n'est pas** une machine du projet. Aucune action ne doit
> jamais la viser. Elle n'a subi que des lectures réseau.

---

## 1. Accès SSH — QUALIFIÉ

| Contrôle | Résultat |
|---|---|
| Alias | `homespotify-minipc` → `<HYDRA_WIFI_LAN_IP>:22`, `User <WINDOWS_USER>` |
| Authentification | `Authenticated to <HYDRA_WIFI_LAN_IP> using "publickey"` |
| Machine distante | `Hydra` |
| Compte distant | `hydra\<WINDOWS_USER>`, **jeton élévé** (`ELEVATION : True`) |
| Clés proposées | **1 seule**, `C:\Users\<WINDOWS_USER>\.ssh\homespotify-minipc` |
| Empreinte | `<ADMIN_SSH_KEY_FINGERPRINT>` |

Cause de l'échec initial : la règle `OpenSSH-Server-In-TCP` était limitée au profil **Private**
alors que le Wi-Fi `<WIFI_SSID>` est classé **Public**. Corrigée en `Profile=Any`,
`RemoteAddress=<LAN_SUBNET>`. Le profil réseau de la machine n'a **pas** été changé.

`HYDRA` est désormais l'identité autoritaire du mini-PC.

### Note d'exploitation SSH → Windows

Deux pièges rencontrés, à retenir pour tous les scripts de la suite :

1. `powershell -Command -` exécute le flux **ligne par ligne** : tout pipeline multi-lignes est
   tronqué silencieusement. Utiliser `-EncodedCommand` (base64 UTF-16LE).
2. La ligne de commande distante passe par `cmd.exe`, plafonnée à **8191 caractères** : un
   `-EncodedCommand` plus long échoue **sans aucun message**. Découper en lots < 6000 caractères.

---

## 2. Matériel et système

| | |
|---|---|
| Modèle | **PELADN WI-6**, BIOS AMI `100E` (2024-02-20) |
| CPU | **Intel N100** — 4 cœurs / 4 threads, 800 MHz base |
| RAM | **16 Go** DDR4-3200, 1 barrette (`Controller0-ChannelA-DIMM0`) |
| OS | Windows 11 Professionnel, build **26100**, 64 bits, installé le 2026-01-15 |
| Domaine | WORKGROUP |
| Session | `<WINDOWS_USER>` ouverte en **console**, active |
| Ouverture auto de session | **non configurée** (`AutoAdminLogon` vide) |

Le N100 est largement suffisant : le Storage Agent ne fait que du transfert de fichiers, aucun
transcodage — celui-ci reste sur le VPS.

## 3. Disques

### Disque système — PELADN 512 Go SATA (Disk 0)

| | |
|---|---|
| Santé | `Healthy`, `PredictFailure=False` |
| SMART | 40 °C, **3633 h** de fonctionnement, `Wear=0`, 0 erreur de lecture |
| `C:` | NTFS, 280,6 Go, **202,1 Go libres**, boot |
| Anomalie | **Partition 3 : 195,3 Go, `Basic`, sans lettre et sans système de fichiers** — espace RAW inutilisé |

### Disque de stockage — WD Elements 2621 (Disk 1)

| | |
|---|---|
| Interface | **USB** — disque externe, pas interne |
| Santé | `Healthy`, `OperationalStatus=OK` |
| SMART | 28 °C, **PowerOnHours = 2**, `Wear=0`, 0 erreur, 14 cycles start/stop → **disque quasi neuf** |
| `D:` | NTFS, label `Elements`, 3726 Go, **3725,8 Go libres → vide** |
| `PredictFailure` | non exposé (normal en USB) |
| BitLocker | désactivé sur `C:` et `D:` |
| ACL de `D:\` | **`Tout le monde : FullControl`** — permissions d'usine, à durcir |

Le disque étant vide, la copie de la bibliothèque ne met aucune donnée existante en danger.

## 4. Réseau

| Interface | Adresse | État |
|---|---|---|
| Wi-Fi | **<HYDRA_WIFI_LAN_IP>/24**, passerelle `<LAN_GATEWAY>` (Freebox) | Up, 144,4 Mbps |
| Ethernet | APIPA `169.254.18.185` | **Disconnected — câble non branché** |
| Tailscale | **<HYDRA_TAILSCALE_IP>/32** | Up |
| Radmin VPN | <RADMIN_VPN_IP>/8 | Up |

## 5. Alimentation — le point noir

| Paramètre | Valeur sur secteur | Verdict |
|---|---|---|
| Mode de gestion actif | `a1841308…` = **« Économie d'énergie »** | ❌ pire choix pour un serveur |
| Mise en veille système | `0x00000000` = **jamais** | ✅ |
| Arrêt du disque dur | `0x000004b0` = **1200 s = 20 min** | ❌ le WD Elements s'arrête toutes les 20 min d'inactivité |
| Suspension sélective USB | `0x00000001` = **activée** | ❌ cause classique de décrochage d'un disque USB |
| Démarrage rapide | `HiberbootEnabled = 1` | ❌ hibernation partielle, mauvaise remise en état de l'USB |
| États disponibles | S3, hibernation, veille hybride | — |

Les trois lignes rouges se combinent : disque USB + arrêt du disque à 20 min + suspension USB
autorisée = décrochages et latences de plusieurs secondes en début de lecture. C'est **le** risque
technique dominant de cette phase.

### Arrêts inattendus

```
18/08/2026 12:09  id=41   redémarrage sans arrêt propre (arrêt précédent 17/08 22:16, non prévu)
17/08/2026 20:16  id=41   redémarrage sans arrêt propre (arrêt précédent 12/07 22:33, non prévu)
```

**Deux coupures brutales en moins de 24 h.** À expliquer avant de confier le stockage à cette
machine : coupure secteur, arrêt physique manuel, ou instabilité matérielle. Non tranché.

Le redémarrage automatique après coupure secteur (`Restore on AC Power Loss`) est un réglage
**BIOS** : il n'est pas lisible depuis Windows et devra être vérifié à l'écran.

## 6. Windows Update

| | |
|---|---|
| `NoAutoUpdate` | **1** — mises à jour automatiques **désactivées par stratégie** |
| `AUOptions` | 1 |
| `wuauserv` | Stopped / Manual |
| Heures d'activité | 14 h → 21 h |

Bon pour la stabilité H24 (aucun redémarrage surprise), mais la machine ne recevra plus de
correctifs de sécurité. Arbitrage à trancher, hors périmètre immédiat.

## 7. Logiciels

| | |
|---|---|
| Node.js | `C:\Program Files\nodejs\node.exe` — **v24.14.0** |
| WireGuard | **NON installé** |
| Port 3100 | **libre** |
| Traces HomeSpotify | **aucune** (`C:\ProgramData\HomeSpotify` absent, aucun service) |

⚠ **Écart de version Node.** Le VPS et le gros PC tournent en **v22.18.0**, et le manifeste de
release exige `requiredNodeVersion: v22.18.0` / `requiredNodeAbi: 127`. HYDRA est en v24.14.0.
Le Storage Agent n'a pas de dépendance native, donc l'écart est probablement inoffensif — mais
« probablement » ne suffit pas pour un socle H24. Aligner sur **v22.18.0**.

### Services automatiques non-Microsoft

`chromoting` (Chrome Remote Desktop) · `Tailscale` · `RvControlSvc` (Radmin VPN) ·
`DSAService` / `DSAUpdateService` (Intel) · `ESRV_SVC_QUEENCREEK` / `SystemUsageReportSvc` (Intel) ·
`IntelGraphicsSoftwareService` · `WinDefend` / `MDCoreSvc`.

## 8. Sécurité

| | |
|---|---|
| Antivirus | Windows Defender seul, `AMRunningMode=Normal`, temps réel **actif** |
| Exclusions | **aucune** |
| BitLocker | désactivé sur `C:` et `D:` |
| ACL `D:\` | `Tout le monde : FullControl` |

Defender analysera chaque lecture et écriture sur la bibliothèque. Une exclusion ciblée sur la
future racine musicale sera à poser au moment de l'installation de l'agent — pas avant.

## 9. Tailscale — audit en lecture seule

| | |
|---|---|
| Version | **1.98.4** |
| Service | `Tailscale` — Running / **Automatic** |
| Tailnet | `<TAILNET_ACCOUNT>` (Romain BEGOT) |
| HYDRA | `<HYDRA_TAILSCALE_IP>` — **en ligne** |
| `<GROS_PC_HOSTNAME>` | `<TAILSCALE_ADMIN_IP>` — **hors ligne depuis 52 jours** |
| `xiaomi-14t-pro` | `<TAILSCALE_PHONE_IP>` — hors ligne depuis 77 jours |
| `WantRunning` / `LoggedOut` | `true` / `false` — nœud authentifié |
| `RunSSH` | `false` (Tailscale SSH désactivé — on garde OpenSSH) |
| `AutoUpdate` | `Check: true`, **`Apply: true`** — Tailscale se met à jour tout seul |
| **`UnattendedMode`** | **ABSENT du registre → mode non-surveillé NON activé** |

Deux conclusions décisives :

1. **Tailscale ne survivrait pas à un redémarrage sans ouverture de session.** Le nœud est en ligne
   parce que `<WINDOWS_USER>` a une session console active. Sans le mode non-surveillé, après un reboot non
   suivi d'une connexion, le tunnel ne remonte pas — l'accès de secours n'existerait donc pas au
   moment précis où on en aurait besoin.
2. **Le gros PC n'est plus sur le tailnet depuis 52 jours**, ce qui explique son état `NoState`.
   Tant qu'il n'y est pas revenu, je n'ai aucun chemin de secours utilisable depuis ce poste.

## 10. Proposition — administration SSH via Tailscale (à valider, non appliquée)

Objectif : conserver `LAN → <HYDRA_WIFI_LAN_IP>` comme chemin nominal, ajouter
`Tailscale → <HYDRA_TAILSCALE_IP>` comme chemin de secours, sans jamais ouvrir SSH à tout `100.64.0.0/10`.

Règle **distincte** de la règle LAN, restreinte **à la fois** par interface et par adresses sources
nominatives :

```powershell
New-NetFirewallRule -DisplayName 'OpenSSH via Tailscale (admin H24)' `
    -Name 'OpenSSH-Server-In-TCP-Tailscale' `
    -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 `
    -InterfaceAlias 'Tailscale' `
    -RemoteAddress <TAILSCALE_ADMIN_IP>,<TAILSCALE_PHONE_IP> `
    -Profile Any -Enabled True
```

- `-InterfaceAlias 'Tailscale'` : le trafic doit arriver par le tunnel, pas par le Wi-Fi.
- `-RemoteAddress` : **uniquement** le gros PC et le téléphone, pas la plage CGNAT entière.
- La règle LAN reste inchangée et indépendante ; chacune peut être désactivée seule.

À compléter côté tailnet par une ACL restreignant le port 22 de `hydra` à ces deux appareils,
et par l'activation du **mode non-surveillé**, sans lequel tout ceci reste théorique.

Radmin VPN n'est pas retenu : aucun besoin démontré, et il ajoute un troisième chemin d'accès à
surveiller. Chrome Remote Desktop est présent et actif — c'est un recours graphique de dernier
ressort, mais il dépend d'une session utilisateur et d'un service tiers, donc il ne remplace pas
Tailscale.

## 11. Bilan de qualification

| Domaine | Verdict |
|---|---|
| Accès SSH LAN | ✅ qualifié |
| CPU / RAM | ✅ largement suffisant |
| Disque système | ✅ sain, 202 Go libres |
| Disque 4 To | ✅ neuf et sain, vide, NTFS — ⚠ mais **USB** |
| Réseau | ⚠ Wi-Fi uniquement, Ethernet non branché |
| Alimentation | ❌ **3 réglages bloquants** (arrêt disque 20 min, suspension USB, démarrage rapide) |
| Stabilité | ❌ **2 arrêts brutaux en 24 h, inexpliqués** |
| Redémarrage après coupure | ❓ réglage BIOS, non vérifiable à distance |
| Node.js | ⚠ v24.14.0 au lieu de v22.18.0 |
| WireGuard | ⚠ absent, à installer |
| Port 3100 / traces | ✅ libre et vierge |
| Antivirus | ⚠ actif sans exclusion |
| ACL `D:` | ⚠ `Tout le monde : FullControl` |
| Tailscale | ⚠ fonctionnel mais **mode non-surveillé désactivé**, et gros PC hors tailnet |

**HYDRA n'est pas encore qualifiée pour H24.** Le matériel convient ; ce sont l'alimentation, la
stabilité et la voie de secours qui bloquent. Aucun de ces points ne justifie de changer de
machine.

## 12. Suite — préparation de la migration (rien n'est encore appliqué)

Ordre imposé, chaque étape restant réversible seule :

- **P1 — Élucider les deux arrêts brutaux.** Si c'est de l'instabilité matérielle, tout le reste
  est vain. Rien ne s'installe avant cette réponse.
- **P2 — Alimentation** : mode « Performances élevées », `DISKIDLE=0`, suspension sélective USB
  désactivée, démarrage rapide désactivé. Réversible par retour aux valeurs relevées ci-dessus.
- **P3 — BIOS** : `Restore on AC Power Loss = Power On`. À l'écran.
- **P4 — Secours** : mode non-surveillé Tailscale, retour du gros PC sur le tailnet, puis la règle
  de pare-feu du §10. C'est la clôture de **R8**.
- **P5 — Socle logiciel** : Node v22.18.0, WireGuard, racine `D:\HomeSpotifyStorage\music` **hors
  de tout arbre Git**, ACL de `D:` durcies, exclusion Defender ciblée.
- **P6 — Pair WireGuard `<HYDRA_WG_IP>`** ajouté à chaud côté VPS, sans interrompre `<OLD_AGENT_WG_IP>`.
- **P7 — Copie de la bibliothèque** par le LAN, additive, avec vérification SHA-256 et égalité
  stricte des 173 chemins relatifs.
- **P8 — Agent sur HYDRA**, qualifié depuis le VPS **sans toucher à PROD** (double lecture).
- **P9 — Deux redémarrages à froid**, preuve que tunnel puis agent remontent seuls.
- **P10 — Bascule** d'`AUDIO_REMOTE_BASE_URL`, rollback en moins d'une minute.

## 13. Points ouverts

- Cause des deux arrêts brutaux des 17 et 18 août — **bloquant**.
- Choix Ethernet vs Wi-Fi pour HYDRA.
- Arbitrage sur `NoAutoUpdate=1` (stabilité contre correctifs de sécurité).
- `AutoUpdate.Apply=true` de Tailscale : à laisser ou à figer sur un socle H24.
- Sort des 195,3 Go RAW de la partition 3 du disque système.
