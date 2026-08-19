# HomeSpotify H24 — Phase 1 : audit de l'état réel (2026-08-17)

Audit **en lecture seule**. Aucun service modifié, aucun fichier PROD touché, aucune migration
amorcée. Mini-PC ÉTEINT : rien n'a pu être constaté dessus, tout ce qui le concerne est marqué
`À vérifier`.

---

## 1. État réel

### 1.1 Gros PC de travail — `<GROS_PC_HOSTNAME>`

| Élément | Valeur constatée | Requis H24 ? |
|---|---|---|
| Service `HomeSpotifyStorageAgent` | **Running / Automatic**, identité `NT SERVICE\HomeSpotifyStorageAgent`, WinSW → `C:\Program Files\nodejs\node.exe` `C:\ProgramData\HomeSpotify\StorageAgent\app\dist\main.js`, version **0.3.0** | **OUI** |
| Service `WireGuardTunnel$HomeSpotify-VPS` | **Running / Automatic**, `<OLD_AGENT_WG_IP>/32`, routes `<VPS_WG_IP>/32` + `<OLD_AGENT_WG_IP>/32` uniquement | **OUI** |
| Service `HomeSpotifyApi` | **Stopped / Manual**, `F:\dev\homespotify\infra\windows-service\homespotify-api\HomeSpotifyApi.exe` | NON — mort depuis D1 |
| Bind agent | `http://<OLD_AGENT_WG_IP>:3100` (PID node 18044), 173 entrées d'index chargées | **OUI** |
| Racine musicale | `F:\dev\homespotify\storage\music` — **173 `.flac` + 1 `.wav`, 3,4 Gio** | **OUI** |
| Index agent | `C:\ProgramData\HomeSpotify\StorageAgent\data\index.json`, v1, `generatedAt 2026-08-16T19:41:39Z`, 173 entrées `trackId → relativePath` | **OUI** |
| Config agent | `C:\ProgramData\HomeSpotify\StorageAgent\config\agent.env` (secret HMAC en clair, **mode 644**), `ALLOWED_REMOTE_IP=<VPS_WG_IP>`, 8 flux concurrents max | **OUI** |
| Tâches planifiées | **AUCUNE** liée à HomeSpotify | — |
| Règles pare-feu | `…-StorageAgent-3100-WireGuard-VPS` (remote `<VPS_WG_IP>`) ; + 3 règles **obsolètes** port 3000, dont une `remote=Any` | 1 sur 4 |
| Réseau | Wi-Fi `<GROS_PC_LAN_IP>` (Ethernet en APIPA = non branché) ; endpoint WG public vu du VPS : `<HOME_PUBLIC_IP>:44312` | — |
| Disque `F:` | 1,0 Tio, 817 Gio utilisés, **208 Gio libres** | — |
| Autres | Tailscale installé mais `NoState`, Radmin VPN présent | — |

Non requis au runtime : dépôt `F:\dev\homespotify` (sauf le sous-dossier `storage\music`),
`services/api/data/homespotify.db` (base locale morte), `storage\imports` (3,4 Gio, 272 fichiers),
`storage\covers` (164 fichiers — les pochettes PROD sont servies par le VPS), tous les
`scripts\*.ps1`, `F:\dev\homespotify-secrets\android` (keystore, build seulement).

**Fréquence de redémarrage constatée** : le journal WinSW montre un démarrage du service quasi
quotidien (11/08, 12/08, 13/08, 14/08, 15/08, 16/08, puis **deux fois** le 17/08 à 12:23 et 15:39).
Chaque redémarrage = fenêtre d'indisponibilité du stockage. C'est la preuve directe que la cible
H24 n'est pas tenable sur cette machine.

### 1.2 VPS — `<VPS_HOSTNAME>` (<VPS_PUBLIC_IP>)

| Élément | Valeur constatée |
|---|---|
| Hôte | Debian 12, noyau 6.1.0-50-cloud, 2 vCPU, 3,8 Gio RAM, `/` 40 Gio dont **29 Gio libres**, **up 32 jours** |
| `caddy.service` | active + enabled — `<PUBLIC_DOMAIN>` → `127.0.0.1:3002`, HSTS/nosniff/no-referrer |
| `homespotify-api-shadow.service` | **active + enabled**, `User=homespotify`, node `v22.18.0`, `ProtectSystem=strict`, seule racine inscriptible `ReadWritePaths=/var/lib/homespotify-shadow`, `RestrictAddressFamilies=AF_UNIX AF_INET` |
| `wg-quick@wg0` | enabled, `<VPS_WG_IP>/24`, port 51820, **1 seul peer** (`<OLD_AGENT_WG_IP>/32` = le gros PC), handshake < 10 s, 22,46 Gio reçus |
| Santé | `/health` local **200**, `https://<PUBLIC_DOMAIN>/health` **200**, uptime process 67 608 s |
| Base | `/var/lib/homespotify-shadow/data/runtime.db` — **173 tracks**, 2 users, 1 playlist, 38 tables ; WAL actif (4,1 Mio) |
| Release courante | `current → releases/20260814T190601Z-3553de1-antrahs-worker` ; `previous → …-radiometa2` ; 15 releases conservées |
| Antra | `/opt/homespotify-api-shadow/antra-hs/py311-antrahs-e6f29292-90e60604`, sorties `/var/lib/homespotify-shadow/antra/jobs`, **`ANTRA_MODE=cli`**, `ACQUISITION_LEGACY_ENABLED=false` |
| Cache audio | `/var/lib/…/cache/audio` — **167 fichiers, 3,2 Gio** (plafond 12 Gio, plancher libre 6 Gio) |
| Variantes Opus | `offline-variants` — 155 fichiers, 432 Mio (156 × `opus_128`, 2 × `opus_256` en base) |
| OTA Android | `mobile-updates/android` — 976 Mio |
| Pare-feu | ufw actif, deny in par défaut ; ouverts : 22, 80, 443, 51820 |
| Cron / timers | **AUCUN** job HomeSpotify (seulement apt/man-db/fstrim de Debian) |
| Sauvegardes | `BACKUP_ENABLED=false`. Uniquement des instantanés manuels : `runtime.db.pre-d1-…`, `data/pre-radio-…`, 6 `.env.bak-*`/`.pre-*` |

### 1.3 Activité réelle (24 dernières heures, journald)

`CACHE_HIT` 68 · `CACHE_MISS` 10 · `REMOTE_STORAGE_REQUEST_STARTED` 14 ·
**`REMOTE_STORAGE_WRITE_CONFIRMED` 2** · `STREAM_COMPLETED` 37 · `STREAM_ABORTED` 6.

---

## 2. Dépendances — ce qui casse si le gros PC s'éteint

**Une seule variable relie PROD au gros PC** : `AUDIO_REMOTE_BASE_URL=http://<OLD_AGENT_WG_IP>:3100`.
Tout le reste (API, DB, auth, Antra, Radio, Opus, OTA) tourne déjà sur le VPS.

Trois chemins d'appel en dépendent :

1. **Lecture avec cache miss** → `GET/HEAD /internal/storage/tracks/:trackId`. PC éteint = **échec de
   lecture** pour toute piste absente du cache VPS. Aujourd'hui 167/173 pistes sont en cache, donc
   l'impact immédiat serait faible — mais le cache est une **LRU volatile, pas une source de vérité**.
2. **Écriture d'une nouvelle piste** → `PUT /internal/storage/objects/:sha256` (événement
   `REMOTE_STORAGE_WRITE_CONFIRMED`, 2 occurrences en 24 h). PC éteint = **aucun import ni
   acquisition Antra ne peut aboutir**.
3. **Publication de l'index** → `/internal/storage/index`, poussé **par le VPS** (l'agent 0.3.0
   expose la route). Le script local `scripts\refresh_storage_agent_index.ps1` est **périmé** : il
   lit `services\api\data\homespotify.db` (base morte) et l'API locale `127.0.0.1:3000` (service
   arrêté). Il ne doit plus être exécuté.

Ce qui **ne** dépend **pas** du gros PC : domaine et TLS, authentification, base runtime,
recommandations, Smart Radio, variantes Opus, mises à jour OTA Android, Antra.

**Point de couplage à corriger pendant la migration** : la racine musicale est *à l'intérieur du
dépôt Git* (`F:\dev\homespotify\storage\music`). Sur le mini-PC elle doit vivre **hors de tout
arbre Git**, sur le disque 4 To.

---

## 3. Cartographie réelle

```
Android (Media3)
   │ HTTPS  <PUBLIC_DOMAIN>
   ▼
Caddy 443  ─────────────────────────────────┐  VPS OVH « <VPS_HOSTNAME> »
   │ 127.0.0.1:3002                         │  Debian 12 · 2 vCPU · 40 Gio
   ▼                                        │
homespotify-api-shadow (node 22.18.0)       │
   ├── runtime.db (SQLite, 173 pistes)      │
   ├── auth JWT                             │
   ├── Antra (py311, ANTRA_MODE=cli)        │
   ├── cache audio 12 Gio (167 fich.)       │
   ├── variantes Opus (155)                 │
   └── OTA Android (976 Mio)                │
   │                                        │
   │ WireGuard <VPS_WG_IP> → <OLD_AGENT_WG_IP>          │
   ▼                                        ┘
Storage Agent 0.3.0  (<OLD_AGENT_WG_IP>:3100, HMAC)  ── GROS PC DE TRAVAIL ── ⚠ redémarre ~1×/jour
   └── F:\dev\homespotify\storage\music (173 FLAC, 3,4 Gio)
```

| Composant | Machine aujourd'hui | Destination |
|---|---|---|
| Domaine, TLS, reverse proxy | VPS | **reste VPS** |
| API publique, auth, DB, Antra, Radio, Opus, OTA | VPS | **reste VPS** |
| Cache audio | VPS | **reste VPS** |
| Storage Agent + bibliothèque musicale | Gros PC | **→ mini-PC** |
| Pair WireGuard côté maison | Gros PC | **→ mini-PC** |
| Build / déploiement / APK / keystore | Gros PC | gros PC pour l'instant → mini-PC plus tard (hors périmètre) |
| Service `HomeSpotifyApi` Windows | Gros PC (arrêté) | **à supprimer du runtime** |
| Base locale `services/api/data/homespotify.db` | Gros PC | **à sortir du runtime** (archive dev) |
| `storage\imports` (3,4 Gio), `storage\covers` | Gros PC | dev seulement, ne migre pas |
| `scripts\refresh_storage_agent_index.ps1` | Gros PC | **à retirer** (périmé) |
| Dépôt, IDE, Claude/Codex, Git | Gros PC | **reste gros PC** |

---

## 4. Architecture cible

**VPS** — inchangé : API publique, domaine + Caddy, auth, `runtime.db`, orchestration Antra,
cache, Opus, OTA, WireGuard `<VPS_WG_IP>/24`, deuxième pair `<HYDRA_WG_IP>` pour le mini-PC.

**Mini-PC H24** — bibliothèque 4 To hors arbre Git, Storage Agent 0.3.0 en service Windows
auto-start sous compte virtuel `NT SERVICE\HomeSpotifyStorageAgent`, tunnel WireGuard
`<HYDRA_WG_IP>/32` en service auto-start avec **dépendance de service** agent → tunnel, pare-feu
restreint à `<VPS_WG_IP>:3100`, chemin d'administration distante indépendant, veille et redémarrage
automatique après coupure secteur désactivés/configurés. Plus tard seulement : runner CI/CD,
Flutter/Android, OTA, dashboard.

**Gros PC** — développement uniquement. Éteint = **aucun impact** sur HomeSpotify.

---

## 5. Risques

| # | Risque | Gravité | Parade |
|---|---|---|---|
| R1 | Copie des 173 FLAC : les chemins contiennent accents, parenthèses, `MA_TÊTE.flac`. Une **normalisation Unicode NFC/NFD** différente casse la résolution `relativePath` → 404 silencieux | **Élevée** | Comparaison SHA-256 **et** comparaison octet-à-octet des chemins relatifs avant bascule |
| R2 | Agent lié à `<HYDRA_WG_IP>` : si le tunnel n'est pas monté au démarrage, le bind échoue | Élevée | Dépendance de service + `Restart` WinSW, prouvée par 2 redémarrages à froid |
| R3 | Cache VPS pris pour un filet de sécurité (167/173 pistes) — c'est une LRU purgeable | Moyenne | Ne jamais s'appuyer dessus pour valider la bascule ; forcer des `CACHE_MISS` réels au test |
| R4 | Aucune sauvegarde automatisée de `runtime.db` (`BACKUP_ENABLED=false`) | Moyenne | Instantané vérifié avant toute action, y compris non destructive |
| R5 | Secret HMAC en clair, `agent.env` en mode 644 | Moyenne | Sur le mini-PC : ACL restreinte au compte de service + admins, dès l'installation |
| R6 | 3 règles de pare-feu obsolètes sur le gros PC, dont port 3000 `remote=Any` | Faible | Nettoyage après le retrait définitif du gros PC |
| R7 | `manifest.json` de `current` annonce `releaseId 20260810…` alors que la release est `20260814…` | Faible | Hygiène de release, à traiter au chantier CI/CD |
| R8 | Accès distant au mini-PC non établi (Tailscale `NoState` ici, Radmin non qualifié) | **Élevée** | À régler **avant** de dépendre du mini-PC — sinon un incident impose une présence physique |
| R9 | Le gros PC est en Wi-Fi ; si le mini-PC l'est aussi, les cache miss deviennent lents | Faible | Mini-PC en filaire |
| R10 | `AllowedIPs` du gros PC = `<VPS_WG_IP>/32` : pas de route directe PC ↔ mini-PC via le tunnel | Faible | La copie des 3,4 Gio se fait par le **LAN**, pas par WireGuard |

---

## 6. Plan de migration (à exécuter seulement après feu vert, mini-PC allumé)

Principe : **double lecture avant bascule**. Les deux agents coexistent ; la bascule est un
changement d'une seule variable d'environnement, réversible en moins d'une minute.

- **M0 — Sauvegardes vérifiées.** Instantané de `runtime.db` (arrêt propre ou `VACUUM INTO`),
  copie de `/etc/homespotify/api-shadow.env`, copie de `index.json`, empreinte SHA-256 des 173
  fichiers audio du gros PC. Rien ne commence tant que ces empreintes ne sont pas relues.
- **M1 — Mini-PC : socle.** Node 22.18.0 (version identique au VPS et au gros PC), WireGuard,
  disque 4 To monté, racine `…\HomeSpotifyStorage\music` **hors dépôt Git**, veille désactivée,
  redémarrage automatique après coupure, accès distant qualifié (R8).
- **M2 — Pair WireGuard `<HYDRA_WG_IP>`.** Nouveau couple de clés généré sur le mini-PC. Ajout du pair
  côté VPS **à chaud** (`wg set`, sans redémarrer l'interface) : le pair `<OLD_AGENT_WG_IP>` n'est pas
  interrompu. Preuve : handshake + ping bidirectionnel.
- **M3 — Copie de la bibliothèque par le LAN.** `robocopy` en mode miroir *lecture seule côté
  source*. Rien n'est supprimé nulle part. Vérification R1 : SHA-256 fichier par fichier +
  égalité stricte des 173 chemins relatifs de `index.json`.
- **M4 — Agent sur le mini-PC.** `install_storage_agent_service.ps1` (idempotent, reprenable,
  démarrage en dernier). `agent.env` avec le **même secret HMAC**, `HOST=<HYDRA_WG_IP>`,
  `MUSIC_ROOT` = nouvelle racine, ACL restreinte. Copie de `index.json`. Pare-feu : 3100 depuis
  `<VPS_WG_IP>` uniquement.
- **M5 — Qualification hors PROD.** Depuis le VPS, requêtes HMAC signées vers
  `<HYDRA_WG_IP>:3100` : `/health`, `HEAD` et `GET` avec `Range` sur au moins 5 pistes, dont une
  absente du cache VPS et une à chemin accentué. Comparaison des tailles et empreintes avec
  `<OLD_AGENT_WG_IP>`. **PROD ne bouge pas pendant cette étape.**
- **M6 — Deux redémarrages à froid du mini-PC.** Preuve que tunnel puis agent remontent seuls,
  sans session ouverte (R2).
- **M7 — Bascule.** `AUDIO_REMOTE_BASE_URL` → `http://<HYDRA_WG_IP>:3100`, sauvegarde datée de l'ancien
  `.env`, `systemctl restart homespotify-api-shadow`. Interruption attendue : quelques secondes.
- **M8 — Preuve PROD.** Lecture réelle depuis le téléphone d'une piste **volontairement évincée du
  cache**, donc servie par le mini-PC ; un import qui déclenche `REMOTE_STORAGE_WRITE_CONFIRMED`
  sur le mini-PC ; 24 h d'observation.
- **M9 — Retrait du gros PC.** Seulement après M8 : arrêt de l'agent (service laissé installé et
  désactivé, **fichiers audio conservés en l'état**), tunnel conservé jusqu'à la fin de la période
  d'observation. Aucune suppression de musique à ce stade — ni maintenant, ni en M9.

Chaque étape est réversible seule. Aucune n'écrase de fichier audio.

## 7. Plan de rollback

| Étape | Retour arrière | Délai |
|---|---|---|
| M7 (bascule) | Restaurer le `.env` sauvegardé (`AUDIO_REMOTE_BASE_URL=http://<OLD_AGENT_WG_IP>:3100`) + `systemctl restart` | < 1 min |
| M4 (agent mini-PC) | `rollback_storage_agent.ps1` sur le mini-PC ; le gros PC n'a jamais été touché | quelques min |
| M3 (copie) | Aucune action : la copie est additive, la source est intacte | — |
| M2 (pair WG) | `wg set wg0 peer <clé> remove` + retrait de la ligne dans `wg0.conf` ; le pair `<OLD_AGENT_WG_IP>` reste actif | < 1 min |
| M9 (retrait PC) | Redémarrer `HomeSpotifyStorageAgent` sur le gros PC et repointer l'env | < 5 min |

Condition d'abandon : tout écart d'empreinte en M3, tout `404 TRACK_NOT_INDEXED` en M5, tout
échec de remontée en M6 → on ne bascule pas, PROD reste sur `<OLD_AGENT_WG_IP>`.

## 8. À vérifier sur le mini-PC une fois allumé

Matériel et OS : édition et version de Windows, RAM, présence d'un SSD système distinct du 4 To,
état SMART du 4 To, lettre de lecteur, système de fichiers (NTFS attendu), espace libre réel.
Réseau : filaire ou Wi-Fi, adresse LAN, réservation DHCP, accès Internet sortant UDP 51820.
Exploitation : profil d'alimentation (veille/hibernation), comportement après coupure secteur,
compte utilisé pour la session, mises à jour Windows automatiques et redémarrage forcé.
Logiciel : Node.js (version), WireGuard installé, présence éventuelle d'un ancien agent
HomeSpotify, port 3100 libre, politique d'exécution PowerShell, droits d'administration.
Accès distant : quel chemin permet de reprendre la main sans présence physique (R8).
Sécurité : ACL du futur `agent.env`, antivirus susceptible de bloquer un service node.

## 9. Points ouverts

- Le chemin d'administration distante du mini-PC n'est pas décidé (R8) — bloquant pour H24.
- Le sort du gros PC comme machine de build n'est pas tranché : le chantier CI/CD est
  explicitement hors périmètre de cette phase.
- Aucune sauvegarde automatisée n'existe côté VPS ; à traiter comme chantier propre, hors H24.
