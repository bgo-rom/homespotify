# HomeSpotify H24 — Phase 2B : configuration de HYDRA (2026-08-18)

Modifications appliquées **à distance en SSH**, par lots, chaque lot précédé du relevé de ses
valeurs d'origine.

Base de rollback sur la machine : `C:\ProgramData\HomeSpotify-H24\baseline-20260818-123541.txt`

**Hors périmètre, non touché** : `AUDIO_REMOTE_BASE_URL`, PROD, bibliothèque du gros PC,
les 173 FLAC, toute copie vers `D:`, le Storage Agent, le pair WireGuard `<HYDRA_WG_IP>`.

---

## 1. Paramètres avant / après

### 1.1 Alimentation

| Paramètre (secteur) | Avant | Après | Pourquoi |
|---|---|---|---|
| Mode de gestion | `a1841308…` **Économie d'énergie** | `381b4222…` **Utilisation normale** | « Économie d'énergie » bride la fréquence en permanence et impose des délais d'inactivité agressifs. « Utilisation normale » conserve C-states et mise à l'échelle de fréquence — donc la sobriété au repos — sans plafonner le débit pendant une lecture. |
| Veille système | `0x0` (jamais) | `0x0` (jamais) | déjà correct, confirmé explicitement |
| Hibernation auto | `0x0` | `0x0` | idem |
| **Arrêt du disque dur** | `0x4b0` = **1200 s** | **`0x0` = jamais** | un disque USB qui s'arrête toutes les 20 min impose plusieurs secondes de réveil au premier octet lu, et multiplie les cycles start/stop. Choix assumé : quelques watts contre un disque toujours présent. |
| **Suspension sélective USB** | `0x1` **activée** | **`0x0` désactivée** | cause classique de disparition d'un disque externe |
| Extinction de l'écran | `0x0` (jamais) | `0x258` = **600 s** | seule économie sans effet sur le service |
| **Bouton d'alimentation** | `0x1` = **mise en veille** | **`0x3` = arrêt propre** | un appui accidentel endormait le serveur ; il provoque désormais un arrêt propre |
| CPU minimum | `5 %` | `5 %` inchangé | plancher bas conservé volontairement : pas de fréquence forcée au repos |
| CPU maximum | `100 %` | `100 %` inchangé | aucun bridage, le N100 monte quand il en a besoin |
| **Hibernation globale** | disponible | **désactivée** (`powercfg /h off`) | supprime `hiberfil.sys` **et** le démarrage rapide |
| `HiberbootEnabled` | `1` | **`0`** | le démarrage rapide laisse le matériel USB dans un état hérité au boot ; un serveur doit démarrer à froid |

### 1.2 USB et périphériques

| Élément | Avant | Après |
|---|---|---|
| `USB\DisableSelectiveSuspend` | absent | **`1`** |
| `USB\VID_1058&PID_2621` (**WD Elements**) | `Enable=True` | **`False`** |
| `USB\ROOT_HUB30` | `True` | **`False`** |
| `PCI\VEN_10EC&DEV_C822` (Wi-Fi Realtek 8822CE) | `True` | **`False`** |
| `PCI\VEN_10EC&DEV_8168` (Ethernet Realtek) | `True` | `True` — **non appliqué** |

`Enable=False` correspond à la case « Autoriser l'ordinateur à éteindre ce périphérique pour
économiser l'énergie ». Les trois périphériques critiques sont couverts : le disque lui-même, le
hub qui le porte, et la carte réseau par laquelle passe l'administration.

La carte Ethernet refuse le réglage tant qu'elle est déconnectée — à reprendre à l'arrivée du switch.

### 1.3 Tailscale

| | Avant | Après |
|---|---|---|
| `ForceDaemon` (mode non-surveillé) | **absent/false** | **`true`** |
| Service | Running / Automatic | inchangé |
| Reprise après échec | aucune | **redémarrage à 5 s / 10 s / 30 s** |
| `RunSSH` | `false` | `false` — on garde OpenSSH |

Appliqué par `tailscale set --unattended=true`. C'est `ForceDaemon` dans les préférences qui fait
foi côté démon, pas la clé de registre `UnattendedMode` de l'ancienne interface graphique.

### 1.4 Pare-feu SSH

| Règle | Port | Adresses autorisées | Interface |
|---|---|---|---|
| `OpenSSH-Server-In-TCP` | 22 | `<LAN_SUBNET>` | toutes |
| `OpenSSH-Server-In-TCP-Tailscale` **(nouvelle)** | 22 | **`<TAILSCALE_ADMIN_IP>`, `<TAILSCALE_PHONE_IP>`** | **`Tailscale` uniquement** |

Aucune règle port 22 avec `remote=Any`. Vérification externe faite **depuis le VPS** vers l'IP
publique du domicile : `<HOME_PUBLIC_IP>:22` et `:3100` **non joignables**.

### 1.5 Runtime Node

| | |
|---|---|
| Node système | `C:\Program Files\nodejs\node.exe` — **v24.14.0, inchangé** |
| Node HomeSpotify | `C:\ProgramData\HomeSpotify\runtime\node-v22.18.0-win-x64\node.exe` — **v22.18.0** |
| Source | `https://nodejs.org/dist/v22.18.0/node-v22.18.0-win-x64.zip`, 33,76 Mo |
| SHA-256 attendu | `c95d8a7e1c99e669cc08c9f1176e068c1f50847c37908fcb8c35b62482366511` |
| SHA-256 calculé | **identique** — vérifié contre `SHASUMS256.txt` officiel |

Installation **côte à côte**, pas de remplacement : rien d'autre sur la machine ne change de
runtime. Le futur service pointera sur le chemin absolu de la v22.18.0, comme le fait déjà WinSW
sur le gros PC. C'est aussi ce qu'exige le manifeste de release (`requiredNodeVersion v22.18.0`,
`requiredNodeAbi 127`).

### 1.6 ACL

| Chemin | Avant | Après |
|---|---|---|
| `D:\` | **`Tout le monde : FullControl`** + CREATEUR PROPRIETAIRE + SYSTEM | CREATEUR PROPRIETAIRE, **SYSTEM**, **Administrateurs** — `Tout le monde` **retiré** |
| `D:\HomeSpotifyStorage` (créé, vide) | — | héritage coupé, **SYSTEM + Administrateurs** seulement |
| `D:\HomeSpotifyStorage\music` (créé, vide) | — | hérité du parent |
| `C:\ProgramData\HomeSpotify` | — | héritage coupé, **SYSTEM + Administrateurs** seulement |

Le compte de service `NT SERVICE\HomeSpotifyStorageAgent` n'existe pas encore ; il sera ajouté au
moment de l'installation, avec le strict nécessaire. **Aucune musique copiée, aucun formatage,
aucun repartitionnement.**

### 1.7 Windows Update

| | Avant | Après |
|---|---|---|
| `NoAutoUpdate` | **`1`** (aucune mise à jour) | **`0`** |
| `AUOptions` | `1` | **`4`** — téléchargement + installation planifiée |
| `ScheduledInstallDay` | — | **`1`** (dimanche) |
| `ScheduledInstallTime` | — | **`5`** (05 h 00) |
| `NoAutoRebootWithLoggedOnUsers` | — | **`0`** |

Arbitrage : la machine était totalement gelée côté sécurité. Elle se met désormais à jour, mais le
redémarrage est confiné à un créneau connu — et les services remontent seuls, ce qui rend ce
redémarrage sans conséquence.

### 1.8 Services

`sshd` et `Tailscale` : `Automatic`, non différé, **reprise après échec 5 s / 10 s / 30 s**
(`reset` 24 h). Le futur service Storage Agent recevra le même traitement, plus une dépendance
explicite au tunnel.

### 1.9 Comportement d'arrêt (ajouté après l'incident du §2)

| Clé | Avant | Après | Portée |
|---|---|---|---|
| `AutoEndTasks` | absent | **`1`** | `HKU\.DEFAULT` **et** `HKCU` |
| `HungAppTimeout` | absent | **`5000`** | idem |
| `WaitToKillAppTimeout` | absent | **`5000`** | idem |
| `WaitToKillServiceTimeout` | `5000` | `5000` (figé) | `HKLM` |
| `AutoReboot` après incident | `1` | `1` (vérifié) | `HKLM\...\CrashControl` |

Sans `AutoEndTasks=1`, une application qui refuse de se fermer laisse Windows attendre
**indéfiniment** sur la console. C'est exactement ce qui s'est produit.

---

## 2. INCIDENT — la machine refuse de redémarrer

Le test de remontée automatique a mis au jour un défaut sérieux.

**Déroulé**

| Heure | Fait |
|---|---|
| 12:42:46 | `shutdown /r /t 3` — événement **1074** enregistré, redémarrage bien initié |
| 12:44 | session `<WINDOWS_USER>` fermée (`query user` → aucun utilisateur), aucune fenêtre applicative |
| 12:45 → 12:49 | machine **toujours en ligne et pleinement réactive** par SSH |
| — | `shutdown /a` → **1115** « un arrêt système est en cours » — non annulable |
| — | `shutdown /r /t 0 /f` → **1115** |
| — | `Win32Shutdown(6)` par WMI → **1115** |
| — | **101 services encore `Running`**, aucun événement 1076 / 6006 : la phase d'arrêt des services n'a jamais commencé |
| — | `LogonUI.exe` encore vivant en session 1 → console figée sur l'écran de blocage d'arrêt |
| — | `LogonUI` terminé de force → l'arrêt ne progresse **toujours pas**, 1115 persiste |

**Dénouement — la machine est repartie seule.**

| Heure | Fait |
|---|---|
| 12:49:29 | **redémarrage effectif** (`LastBootUpTime`) |
| 12:55:11 | SSH répond, `sshd` et `Tailscale` `Running`, uptime 5,7 min |
| — | `query user` → **aucune session ouverte** |

Délai total entre la commande et le retour en ligne : **environ 7 minutes**, dont ~6 minutes de
blocage. Aucune intervention physique n'a été nécessaire.

**Interprétation.** L'arrêt était retenu dans la phase de notification, avant l'arrêt des services,
par l'écran de blocage rendu par `LogonUI` sur la console. Le verrou empêchait toute nouvelle
commande d'arrêt (d'où les 1115 en cascade) mais un délai d'expiration interne a fini par
l'emporter. Ce n'est donc pas un gel définitif, mais **un redémarrage de 7 minutes au lieu de 40
secondes**, non prévisible et non interruptible.

**Portée pour H24.** Tolérable une fois compris, mais à corriger : sur un socle 24/7, un
redémarrage qui prend un temps indéterminé rend toute intervention à distance aveugle, et le
créneau Windows Update du dimanche 05 h 00 en hériterait.

**Correctif appliqué** : §1.9. `AutoEndTasks=1` ferme d'autorité les applications récalcitrantes
au lieu d'attendre. **Non encore prouvé** : le prochain redémarrage doit descendre à une durée
normale. À valider par **deux redémarrages consécutifs chronométrés** avant toute mise en service.

**Ce que l'incident ne remet pas en cause** : la machine est restée saine et réactive pendant tout
le blocage, puis est revenue **sans session ouverte**, avec tous les réglages intacts. `D:` présent,
Tailscale en ligne, SSH opérationnel. Ni le disque ni le matériel ne sont en cause.

### Validation après redémarrage — tout est conforme

| Contrôle | Résultat |
|---|---|
| Session console | **aucune** — exploitation sans écran prouvée |
| Schéma d'alimentation | `381b4222…` Utilisation normale |
| Veille / hibernation / arrêt disque | `0x0` / `0x0` / **`0x0`** |
| Suspension sélective USB | **`0x0`** |
| Bouton d'alimentation | `0x3` arrêt propre |
| `HiberbootEnabled` | `0` |
| `AutoEndTasks` (.DEFAULT) | `1` |
| `USB\DisableSelectiveSuspend` | `1` |
| WD Elements / hub USB / Wi-Fi | `Enable=False` — **survit au redémarrage** |
| WD Elements | `Healthy`, 37 °C, présent, `D:\HomeSpotifyStorage\music` accessible |
| SSD | `Healthy`, 40 °C |
| Node dédié / système | `v22.18.0` / `v24.14.0` intact |
| `sshd` / `Tailscale` | `Running / Automatic` |
| Tailscale | `ForceDaemon: true`, `WantRunning: true`, **nœud en ligne sans session** |
| Pare-feu | 2 règles, LAN et Tailscale, aucune ouverture `Any` |
| Defender | temps réel actif, **aucune exclusion** |
| ACL `D:\HomeSpotifyStorage` | SYSTEM + Administrateurs seulement |
| Windows Update | `NoAutoUpdate=0`, `AUOptions=4`, dimanche 05 h 00 |

---

## 3. Mesures au repos

Relevés **après le redémarrage**, machine sans session ouverte.

| Grandeur | Valeur |
|---|---|
| Consommateurs CPU réels | `MsMpEng` (Defender) **17 %**, `WmiPrvSE` **11 %** (mes propres sondes), **tout le reste à 0 %** |
| Charge instantanée `_Total` | très variable (12 → 100 %) — analyse Defender de post-démarrage en cours |
| Mémoire | **3,96 Go** / 15,75 Go |
| Processus | 173 |
| Température carte (ACPI TZ00) | **27,9 °C** |
| SSD système | 40 °C, 3633 h, `Healthy` |
| WD Elements | **37 °C**, 3 h, `Healthy`, maintenu éveillé |
| Écriture + lecture sur `D:` | **565 ms** (mesure d'avant redémarrage, incluait le réveil du disque) |

**La charge au repos n'est pas encore mesurable proprement** : la machine venait de démarrer et
Defender analysait le système. Le seul consommateur permanent identifié est Defender ; tout le
reste est à zéro. Une mesure valable demande un relevé après plusieurs heures de fonctionnement.

**La consommation en watts n'est pas mesurable à distance** : ni le WI-6 ni ses composants
n'exposent de compteur d'énergie. Un wattmètre sur la prise est le seul moyen d'obtenir un chiffre.
Ordre de grandeur attendu pour un N100 au repos avec un disque USB maintenu éveillé : ~10-15 W.

---

## 4. Ce qui restera à faire à l'arrivée du switch Ethernet

1. Brancher `Freebox → switch → HYDRA`, vérifier que la carte `Realtek 8168` passe `Up`.
2. Réservation DHCP sur la Freebox pour l'adresse MAC `<HYDRA_ETHERNET_MAC>` (Ethernet), afin
   d'obtenir une IP stable — l'actuelle `<HYDRA_WIFI_LAN_IP>` est celle du **Wi-Fi**, MAC `<HYDRA_WIFI_MAC>`.
3. Rejouer `MSPower_DeviceEnable = False` sur `PCI\VEN_10EC&DEV_8168` : le réglage n'a pas pris
   tant que la carte était déconnectée.
4. Mettre à jour `HostName` dans `~/.ssh/config` avec la nouvelle adresse.
5. Décider du sort du Wi-Fi : le garder en secours impose de vérifier les métriques d'interface
   pour que l'Ethernet soit bien la route préférée, sinon le trafic peut repartir en Wi-Fi.
6. Revalider SSH LAN, Tailscale, puis WireGuard une fois celui-ci installé.

---

## 5. Prochaine étape vers WireGuard `<HYDRA_WG_IP>` + Storage Agent + 4 To

Rien de tout cela ne touche PROD. Ordre et points de contrôle :

- **É1 — WireGuard sur HYDRA.** Installation du client, génération de la paire de clés
  **sur la machine** (la privée ne quitte jamais HYDRA), configuration `<HYDRA_WG_IP>/32`, peer = VPS,
  `AllowedIPs = <VPS_WG_IP>/32` uniquement, service en démarrage automatique.
- **É2 — Pair côté VPS, à chaud.** `wg set` sans redémarrage de l'interface : le pair `<OLD_AGENT_WG_IP>`
  du gros PC n'est pas interrompu. Preuve attendue : handshake + ping bidirectionnel, et PROD
  toujours servie par `<OLD_AGENT_WG_IP>`.
- **É3 — Agent installé sur HYDRA**, lié à `<HYDRA_WG_IP>:3100`, même secret HMAC, racine
  `D:\HomeSpotifyStorage\music`, runtime Node v22.18.0, service auto avec dépendance au tunnel,
  reprise après échec, pare-feu 3100 restreint à `<VPS_WG_IP>`.
- **É4 — Copie de la bibliothèque** par le LAN, **additive**, le gros PC restant intact.
  Vérification SHA-256 fichier par fichier **et** égalité stricte des 173 chemins relatifs de
  `index.json` — c'est le risque R1 (normalisation Unicode sur les chemins accentués).
- **É5 — Qualification depuis le VPS**, en signant des requêtes HMAC vers `<HYDRA_WG_IP>:3100` :
  `/health`, `HEAD`, `GET` avec `Range`, sur des pistes dont une absente du cache VPS et une à
  chemin accentué. Comparaison des tailles et empreintes avec `<OLD_AGENT_WG_IP>`. **PROD ne bouge pas.**
- **É6 — Deux redémarrages à froid** de HYDRA : tunnel puis agent doivent remonter seuls.
- **É7 — Bascule** d'`AUDIO_REMOTE_BASE_URL` vers `<HYDRA_WG_IP>`, avec sauvegarde datée du `.env` et
  rollback en moins d'une minute.

Le double stockage est conservé pendant toute la période d'observation : le gros PC garde ses 173
FLAC et son agent installé, prêts à reprendre le service.

---

## 6. Points ouverts

- Consommation réelle en watts : nécessite un wattmètre physique.
- Métrique d'interface Wi-Fi vs Ethernet à trancher quand le switch sera là.
- Exclusion Defender sur la racine musicale : **non posée**, faute de mesure. À décider après la
  copie, en comparant le débit de lecture avec et sans, sur des fichiers réels.
- `AutoUpdate.Apply=true` de Tailscale laissé actif : c'est le périmètre de sécurité de l'accès
  distant, je préfère qu'il se corrige seul.
- 195,3 Go RAW inutilisés sur le SSD système — sans usage prévu à ce stade.
