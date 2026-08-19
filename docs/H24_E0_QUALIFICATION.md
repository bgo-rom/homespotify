# HomeSpotify H24 — É0 : qualification avant WireGuard (2026-08-18)

Clôture d'É0 : fermeture de R8 (administration distante) et preuve de redémarrage autonome.
**PROD non touchée**, `AUDIO_REMOTE_BASE_URL` toujours sur `http://<OLD_AGENT_WG_IP>:3100`.
Aucun FLAC copié, aucun pair WireGuard créé.

---

## 1. Tailscale sur le gros PC — R8 fermé

### Cause réelle de l'absence de 52 jours

Le nœud n'était **pas** déconnecté du tailnet : `WantRunning: true`, `LoggedOut: false`. Le backend
restait bloqué en `NoState` parce que **l'interface graphique `tailscale-ipn.exe` n'était pas
lancée et n'était présente dans aucune clé de démarrage**. Sur Windows, sans mode non-surveillé,
`tailscaled` attend cette interface pour charger le profil.

Le service tournait donc bien, mais sans profil : d'où l'adresse APIPA `169.254.83.107` et le
message « Tailscale is starting ».

`Restart-Service` a échoué faute d'élévation — sans conséquence, ce n'était pas la bonne piste.
Le démarrage de `tailscale-ipn.exe` dans la session interactive a suffi.

### État après remise en service

| | |
|---|---|
| Version | 1.98.4 (identique à HYDRA) |
| Tailnet | `<TAILNET_ACCOUNT>` |
| `<GROS_PC_HOSTNAME>` | **`<TAILSCALE_ADMIN_IP>`** — en ligne |
| `hydra` | `<HYDRA_TAILSCALE_IP>` — en ligne |
| `xiaomi-14t-pro` | `<TAILSCALE_PHONE_IP>` — hors ligne depuis 77 j |

**L'adresse n'a pas changé** : `<TAILSCALE_ADMIN_IP>` est exactement celle déjà autorisée dans la règle
`OpenSSH-Server-In-TCP-Tailscale` créée en Phase 2B. **Aucune adaptation de la règle HYDRA n'a été
nécessaire.**

### Réserve — persistance

Le mode non-surveillé n'est **pas** activé sur le gros PC, et l'interface n'est dans aucune clé
`Run`. Après un redémarrage du gros PC, le nœud retombera en `NoState` tant que
`tailscale-ipn.exe` n'aura pas été lancé. Ce n'est pas bloquant pour le rôle recherché — quand
j'ai besoin du secours depuis ce poste, il est allumé et utilisé — mais c'est une action manuelle
à connaître. Correction possible en une ligne dans `HKCU\...\Run` ; **non appliquée**, c'est une
modification du démarrage de ta machine de travail, à ta main.

---

## 2. Preuve SSH via Tailscale

### Routage — aucune adresse LAN dans le chemin

```
Find-NetRoute -RemoteIPAddress <HYDRA_TAILSCALE_IP>
  interface sortante : Tailscale
  IP source utilisee : <TAILSCALE_ADMIN_IP>
  DestinationPrefix  : <HYDRA_TAILSCALE_IP>/32   InterfaceIndex 47
```

### Connexion

```
debug1: Connecting to <HYDRA_TAILSCALE_IP> [<HYDRA_TAILSCALE_IP>] port 22.
debug1: Offering public key: /c/Users/<WINDOWS_USER>/.ssh/homespotify-minipc ED25519 <ADMIN_SSH_KEY_FINGERPRINT> explicit
debug1: Server accepts key:  /c/Users/<WINDOWS_USER>/.ssh/homespotify-minipc ED25519 <ADMIN_SSH_KEY_FINGERPRINT> explicit
Authenticated to <HYDRA_TAILSCALE_IP> ([<HYDRA_TAILSCALE_IP>]:22) using "publickey".
Hydra
hydra\<WINDOWS_USER>
TAILSCALE_SSH_OK
```

| Exigence | Résultat |
|---|---|
| Connexion par `<HYDRA_TAILSCALE_IP>` | ✅ |
| Machine = `HYDRA` | ✅ `Hydra` |
| Utilisateur = `<WINDOWS_USER>` | ✅ `hydra\<WINDOWS_USER>` |
| Clé dédiée `homespotify-minipc` | ✅ seule clé proposée, empreinte conforme |
| Aucune adresse LAN utilisée | ✅ route et IP source entièrement Tailscale |

La règle qui a autorisé cette connexion est `OpenSSH-Server-In-TCP-Tailscale`
(`InterfaceAlias=Tailscale`, `RemoteAddress=<TAILSCALE_ADMIN_IP>,<TAILSCALE_PHONE_IP>`). La règle LAN, limitée
à `<LAN_SUBNET>`, ne pouvait pas s'appliquer.

**Précision honnête** : Tailscale a établi la liaison en direct sur le réseau local
(`direct <GROS_PC_LAN_IP>:41641`). Le chemin IP, la règle de pare-feu et la route sont bien ceux de
Tailscale — le test prouve donc l'indépendance vis-à-vis du VPS HomeSpotify — mais il **ne prouve
pas encore** le fonctionnement depuis l'extérieur du domicile, où le transport passerait par du
NAT traversal ou un relais DERP. Cette preuve-là demande un test depuis le téléphone en données
mobiles, hors tailnet local.

### Chemins d'administration établis

| Chemin | Alias | Portée |
|---|---|---|
| LAN | `homespotify-minipc` → `<HYDRA_WIFI_LAN_IP>` | nominal local |
| Tailscale | `homespotify-minipc-ts` → `<HYDRA_TAILSCALE_IP>` | secours, indépendant du VPS |
| Public | — | **aucun** : port 22 injoignable depuis Internet (vérifié depuis le VPS) |

Radmin VPN non utilisé.

---

## 3. Redémarrage #1

| Repère | Heure | Δ depuis T0 |
|---|---|---|
| T0 — `shutdown /r /t 0` (**sans `/f`**) | 13:47:36 | 0 s |
| Événement **1074** (arrêt initié) | 13:47:47 | +11 s |
| Coupure réseau (TCP 22 fermé) | 13:48:01 | **+25 s** |
| Événement **6006** (journal arrêté = arrêt propre) | 13:48:10 | +34 s |
| `LastBootUpTime` | 13:48:27 | +51 s |
| Événement **6005** (journal démarré) | 13:48:35 | +59 s |
| TCP 22 rouvert | 13:48:50 | +73 s |
| **SSH LAN utilisable** | 13:48:50 | **+74 s** |
| **SSH Tailscale utilisable** | 13:48:52 | **+76 s** |

Aucun événement **41** (arrêt inattendu). ICMP reste filtré par le pare-feu de HYDRA : la mesure
« premier ping » est remplacée par l'ouverture de TCP 22, plus significative ici.

### Contrôles après #1

`sessions ouvertes : []` · `sshd Running/Automatic` · `Tailscale Running/Automatic` ·
`ForceDaemon: true` · nœud en ligne · `D:\HomeSpotifyStorage\music` accessible ·
WD Elements `Healthy`, extinction toujours interdite · `USB\DisableSelectiveSuspend=1` ·
Wi-Fi Up · schéma `Utilisation normale` · `STANDBYIDLE=0` `DISKIDLE=0` `USB suspend=0` ·
`HiberbootEnabled=0` · `AutoEndTasks=1` · Node `v22.18.0` · 2 règles pare-feu actives ·
Defender temps réel actif.

---

## 4. Redémarrage #2

| Repère | Heure | Δ depuis T0 |
|---|---|---|
| T0 — `shutdown /r /t 0` | 13:55:27 | 0 s |
| Événement **1074** | 13:55:37 | +10 s |
| Coupure réseau | 13:55:38 | **+11 s** |
| Événement **6006** | 13:55:48 | +21 s |
| `LastBootUpTime` | 13:56:05 | +38 s |
| Événement **6005** | 13:56:13 | +46 s |
| TCP 22 rouvert | 13:56:27 | +60 s |
| **SSH LAN utilisable** | 13:56:28 | **+60 s** |
| **SSH Tailscale utilisable** | 13:56:29 | **+61 s** |

Aucun événement 41. Contrôles après #2 : **identiques à #1**, tous conformes, `sessions : []`.

### Comparaison

| | Blocage initial | #1 | #2 |
|---|---|---|---|
| Coupure | **~6 min** | 25 s | **11 s** |
| Retour SSH complet | ~7 min | 76 s | **61 s** |
| Événement 6006 | tardif | présent | présent |
| Session ouverte à la remontée | non | non | non |

**Aucune boucle de redémarrage** : deux cycles distincts, chacun suivi d'un fonctionnement stable,
horodatages `LastBootUpTime` cohérents et croissants.

---

## 5. Cause du shutdown lent — et sort d'`AutoEndTasks`

### Cause identifiée

Le blocage initial n'était pas un défaut de la machine mais une **condition de session** : une
session console `<WINDOWS_USER>` était ouverte, et l'arrêt lancé depuis une autre session a produit l'écran
« une application empêche l'arrêt », rendu par `LogonUI.exe`. Cet écran attend indéfiniment sur la
console. Les preuves convergent :

- 101 services encore `Running`, aucun 1076/6006 : la phase d'arrêt des services n'avait pas
  commencé — le blocage était en amont, côté session ;
- `LogonUI.exe` survivait en session 1 après la fermeture de session ;
- toutes les API d'arrêt renvoyaient 1115, le verrou étant déjà posé.

Les deux redémarrages suivants ont eu lieu **sans aucune session ouverte** — condition qui sera
celle du fonctionnement H24 — et se sont déroulés normalement.

### Effet réel d'`AutoEndTasks=1` : non démontré

Honnêtement : les deux redémarrages rapides ont eu lieu **sans session ouverte**, ce qui suffit à
elles seules à expliquer l'absence de blocage. `AutoEndTasks=1` était présent, mais **rien ne
prouve qu'il ait joué un rôle**. Les deux variables ont changé en même temps.

### Décision

Le réglage est **conservé**, pour trois raisons :

1. son risque est cerné : il ne concerne que la fermeture d'applications **graphiques** à l'arrêt,
   or HYDRA fonctionne sans session — en régime normal il n'a rien à fermer ;
2. il n'affecte **pas** l'arrêt des services : `WaitToKillServiceTimeout` reste à 5000 ms, valeur
   d'origine, et le Storage Agent conservera ses 30 s de `TimeoutStopSec` propres ;
3. il couvre précisément le seul scénario où le blocage est réapparu — une session ouverte par
   inadvertance lors d'une maintenance.

Ce n'est **pas** une configuration globale de raccourcissement d'arrêt : aucun délai système n'a
été réduit, aucune écriture n'est tronquée. Si une preuve isolée est souhaitée plus tard, il
suffira d'ouvrir une session console puis de relancer un redémarrage, avec et sans le réglage.

---

## 6. État au repos après stabilisation

Relevé à **uptime 11,7 min**, sans session ouverte, sans charge applicative.

| Grandeur | Valeur |
|---|---|
| Charge CPU (10 mesures / 3 s) | `4 8 5 7 4 8 0 9 8 6` → **médiane 7 %**, min 0 %, max 9 % |
| Processus au-dessus de 0 % | **aucun** à l'instant des relevés |
| Mémoire | **2,32 Go** / 15,75 Go |
| Température ACPI (carte/CPU) | **27,9 °C** |
| WD Elements | **35 °C**, `Healthy`, 4 h de fonctionnement |
| SSD système | **40 °C**, `Healthy`, 3634 h |
| Activité disque `D:` | **0 o/s en lecture et écriture**, file d'attente 0 |
| Activité disque `C:` | écriture ~8,2 Mo/s — analyse rapide Defender (`QuickScanAge = 0 j`) |
| Defender | temps réel actif, mode `Normal`, **aucune exclusion** |

Comparaison avec la mesure prise 8 minutes après le premier démarrage (médiane faussée, Defender
à 17 %) : après stabilisation, la machine est **réellement au repos**. Le disque `D:` est à zéro
tout en restant éveillé — c'est exactement le comportement recherché.

Les watts ne sont pas relevés : ce matériel n'expose aucun compteur d'énergie.

### Défauts système constatés — tous bénins

| Événement | Nature | Impact HomeSpotify |
|---|---|---|
| `TPM-WMI 1796` ×2 | « Le démarrage sécurisé n'est pas activé sur cet ordinateur » — Secure Boot désactivé dans le BIOS | **aucun** ; durcissement possible plus tard, hors périmètre |
| `Firewall 2042` | « Échec de lecture de la configuration » au démarrage du service pare-feu | **aucun** : les deux règles SSH sont vérifiées actives après chaque redémarrage |
| `SCM 7009` | délai de 45 s dépassé par `Intel(R) Platform License Manager Service` | **aucun** sur le service ; allonge le démarrage. Service Intel tiers, désactivable si l'on veut gagner du temps de boot — non touché |

**Aucune erreur `disk`, `storahci`, `USBSTOR`, `Ntfs` ou `volmgr` sur 24 h.**

---

## 7. Verdict É0

| Critère | Exigé | Constaté |
|---|---|---|
| Redémarrages propres et autonomes | 2/2 | **2/2** — 6006 présent, aucun 41, aucune session à la remontée |
| Temps de retour acceptable | — | **76 s** puis **61 s** jusqu'à l'administration complète |
| SSH LAN | PASS | **PASS** |
| SSH Tailscale après redémarrage sans session | PASS | **PASS** — +76 s et +61 s |
| WD 4 To | PASS | **PASS** — `Healthy`, `D:` accessible, extinction interdite conservée, 0 erreur |
| Défaut système significatif | aucun | **aucun** |
| Absence de boucle de redémarrage | oui | **oui** |
| PROD intacte | oui | **oui** — `/health` 200, `AUDIO_REMOTE_BASE_URL` sur `<OLD_AGENT_WG_IP>`, pair unique, handshake frais |

# H24_E0_PASS

### Réserves consignées, non bloquantes

1. Le chemin Tailscale a été prouvé **depuis le LAN** : Tailscale a choisi une liaison directe
   `<GROS_PC_LAN_IP>:41641`. L'indépendance vis-à-vis du VPS est acquise, l'accès **depuis
   l'extérieur du domicile** ne l'est pas encore — à prouver depuis le téléphone en données
   mobiles.
2. Le client Tailscale du gros PC ne redémarre pas seul : `tailscale-ipn.exe` doit être lancé
   après chaque ouverture de session. Correction possible en une entrée `HKCU\...\Run`, laissée à
   ta décision.
3. L'effet propre d'`AutoEndTasks=1` n'est pas démontré (voir §5) ; le réglage est conservé pour
   les raisons qui y sont exposées.
