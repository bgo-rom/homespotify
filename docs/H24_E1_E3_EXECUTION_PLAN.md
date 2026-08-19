# HomeSpotify H24 — Plan d'exécution É1 → É3

Préparé après clôture d'É0. **Aucune étape ci-dessous ne touche PROD.**
`AUDIO_REMOTE_BASE_URL` reste sur `http://<OLD_AGENT_WG_IP>:3100` jusqu'à É7, hors périmètre de ce plan.
Aucun FLAC n'est copié dans É1–É3 : la copie est É4.

Invariants tenus à chaque étape :

- le pair `<OLD_AGENT_WG_IP>` (gros PC) n'est **jamais** interrompu ni supprimé ;
- la bibliothèque du gros PC n'est **jamais** modifiée ni déplacée ;
- chaque étape est réversible seule, sans défaire la précédente ;
- toute clé privée est générée **sur la machine qui l'utilise** et n'en sort pas.

---

## É1 — WireGuard sur HYDRA (`<HYDRA_WG_IP>/32`)

### Ce qui est fait

1. Installation du client WireGuard sur HYDRA (MSI officiel, empreinte SHA-256 vérifiée avant
   exécution, comme pour Node en Phase 2B).
2. Génération de la paire de clés **sur HYDRA**. La clé privée est écrite directement dans le
   fichier de configuration du tunnel ; elle ne transite ni par SSH, ni par le VPS, ni par un
   journal. Seule la **clé publique** est relevée.
3. Configuration du tunnel `HomeSpotify-VPS` :

```
[Interface]
PrivateKey = <genere sur HYDRA, jamais affiche>
Address    = <HYDRA_WG_IP>/32

[Peer]
PublicKey  = <VPS_WG_PUBLIC_KEY>
Endpoint   = <VPS_PUBLIC_IP>:51820
AllowedIPs = <VPS_WG_IP>/32
PersistentKeepalive = 25
```

   `AllowedIPs = <VPS_WG_IP>/32` **uniquement** : même choix strict que sur le gros PC. HYDRA ne
   route rien d'autre par le tunnel, et surtout pas `<OLD_AGENT_WG_IP>`.
   `PersistentKeepalive = 25` : HYDRA est derrière le NAT de la Freebox, la traduction doit
   rester ouverte pour que le VPS puisse initier une lecture.

4. Service de tunnel en démarrage **automatique**, avec reprise après échec 5 s / 10 s / 30 s,
   comme `sshd` et `Tailscale`.
5. ACL du répertoire de configuration WireGuard restreinte à SYSTEM + Administrateurs.

### Ce qui n'est pas fait

Aucune modification côté VPS. Le tunnel ne peut pas encore monter — c'est normal et attendu :
le pair n'existe pas encore en face.

### Preuves attendues

- clé publique HYDRA relevée, clé privée jamais lue ;
- service tunnel présent, `Automatic`, actions de reprise configurées ;
- `AllowedIPs` limité à `<VPS_WG_IP>/32`.

### Rollback

Désinstaller le tunnel (`wireguard.exe /uninstalltunnelservice HomeSpotify-VPS`) et supprimer le
fichier de configuration. Le VPS n'a pas bougé, donc rien à défaire en face.

---

## É2 — Pair `<HYDRA_WG_IP>` ajouté **à chaud** sur le VPS

### Pourquoi à chaud

`wg set` ajoute un pair sans recréer l'interface. `wg-quick down/up` la recréerait et
**interromprait la session du gros PC**, donc PROD. C'est la différence entre une opération
transparente et une coupure de service.

### Ce qui est fait

1. Sauvegarde datée de `/etc/wireguard/wg0.conf`.
2. Ajout à chaud :
   `sudo wg set wg0 peer <cle-publique-HYDRA> allowed-ips <HYDRA_WG_IP>/32`
3. Persistance : ajout du bloc `[Peer]` correspondant dans `wg0.conf`, **sans toucher au bloc du
   gros PC**, pour que le pair survive à un redémarrage du VPS.
4. Aucun changement de pare-feu : le port 51820/udp est déjà ouvert.

### Preuves attendues

- `wg show` liste **deux** pairs, celui du gros PC avec un handshake **récent** ;
- handshake établi avec HYDRA ;
- `ping <HYDRA_WG_IP>` depuis le VPS et `ping <VPS_WG_IP>` depuis HYDRA ;
- **PROD toujours servie par `<OLD_AGENT_WG_IP>`** : `/health` public à 200 et un `REMOTE_STORAGE_*`
  réussi vers le gros PC pendant l'opération ;
- `<OLD_AGENT_WG_IP>` : `latest handshake` inchangé dans sa continuité, aucune remise à zéro du compteur.

### Rollback

`sudo wg set wg0 peer <cle-publique-HYDRA> remove` puis retrait du bloc dans `wg0.conf`.
Moins d'une minute, sans impact sur le pair du gros PC.

---

## É3 — Storage Agent sur HYDRA

### Ce qui est fait

1. Déploiement de l'application agent **0.3.0**, la même version que celle en production sur le
   gros PC, sous `C:\ProgramData\HomeSpotify\StorageAgent\app`.
2. `agent.env` dédié :

```
STORAGE_AGENT_HOST=<HYDRA_WG_IP>
STORAGE_AGENT_PORT=3100
STORAGE_AGENT_MUSIC_ROOT=D:\HomeSpotifyStorage\music
STORAGE_AGENT_INDEX_PATH=C:\ProgramData\HomeSpotify\StorageAgent\data\index.json
STORAGE_AGENT_ALLOWED_REMOTE_IP=<VPS_WG_IP>
STORAGE_AGENT_SHARED_SECRET=<identique au gros PC>
```

   Le secret est **identique** à celui du gros PC : c'est ce qui permettra à É7 de n'être qu'un
   changement d'URL, sans rotation de secret simultanée. Le fichier est créé avec une ACL
   restreinte **dès l'écriture** — pas de fenêtre en 644 comme sur le gros PC.

3. Service Windows via WinSW, identité `NT SERVICE\HomeSpotifyStorageAgent`, démarrage
   `Automatic`, **dépendance explicite au service de tunnel WireGuard** : l'agent se lie à
   `<HYDRA_WG_IP>`, adresse qui n'existe pas tant que le tunnel n'est pas monté.
4. Runtime : chemin absolu vers `C:\ProgramData\HomeSpotify\runtime\node-v22.18.0-win-x64\node.exe`,
   **pas** le Node système v24.14.0.
5. ACL : ajout de `NT SERVICE\HomeSpotifyStorageAgent` en **lecture seule** sur
   `D:\HomeSpotifyStorage\music`, et en lecture sur `app` et `config`. L'écriture n'est accordée
   que sur `data` (index) et `logs`. La surface d'écriture durable exigée par l'agent 0.3.0 sera
   ouverte au moment d'É4, pas avant.
6. Règle de pare-feu : port 3100 entrant, `RemoteAddress = <VPS_WG_IP>` **uniquement**,
   `Profile = Any` — la leçon du profil `Private` de la Phase 2B est appliquée d'emblée.
7. Reprise après échec 5 s / 10 s / 30 s.
8. Index : copie de l'`index.json` actuel (173 entrées) **à titre de forme** — il référencera des
   fichiers absents tant qu'É4 n'a pas eu lieu. C'est voulu et attendu.

### Preuves attendues

- service `Running / Automatic`, dépendance au tunnel effective ;
- agent lié à `<HYDRA_WG_IP>:3100`, journal `STORAGE_AGENT_STARTED` ;
- depuis le VPS, requête HMAC signée sur `/internal/storage/health` → **200** ;
- requête depuis une autre IP que `<VPS_WG_IP>` → **403** ;
- `agent.env` illisible par un utilisateur non-administrateur ;
- **PROD inchangée** : `AUDIO_REMOTE_BASE_URL` toujours sur `<OLD_AGENT_WG_IP>`, `/health` public à 200.

### Rollback

`rollback_storage_agent.ps1` sur HYDRA, ou simplement arrêt et désactivation du service. Le gros
PC n'a jamais été touché et continue de servir PROD.

---

## Points de contrôle bloquants

| # | Condition | Si non tenue |
|---|---|---|
| 1 | Handshake `<OLD_AGENT_WG_IP>` intact pendant tout É2 | rollback immédiat du pair, analyse avant reprise |
| 2 | `/health` public à 200 en continu | arrêt du chantier, PROD prioritaire |
| 3 | Agent HYDRA répond 200 en HMAC depuis le VPS et 403 ailleurs | ne pas poursuivre vers É4 |
| 4 | Service agent remonte seul après redémarrage à froid | corriger la dépendance au tunnel avant É4 |

## Ce qui vient après, hors de ce plan

- **É4** copie additive des 173 FLAC par le LAN, vérification SHA-256 **et** égalité stricte des
  chemins relatifs (risque R1, chemins accentués type `MA_TÊTE.flac`) ;
- **É5** qualification complète depuis le VPS, PROD immobile ;
- **É6** deux redémarrages à froid ;
- **É7** bascule d'`AUDIO_REMOTE_BASE_URL`, rollback en moins d'une minute.
