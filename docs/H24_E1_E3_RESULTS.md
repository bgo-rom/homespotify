# HomeSpotify H24 — É1 → É3 : rapport d'exécution (2026-08-18)

HYDRA est prête comme second Storage Agent, **en parallèle** du gros PC.
**Aucune bascule.** `AUDIO_REMOTE_BASE_URL` reste sur `http://<OLD_AGENT_WG_IP>:3100`, aucun FLAC copié.

---

## É1 — WireGuard sur HYDRA

| Élément | Valeur |
|---|---|
| Paquet | `wireguard-amd64-1.1.msi`, 3,08 Mo, `sha256 6daa5d37…5566` |
| Signature | **Valide**, `CN=WireGuard LLC` (Sectigo EV) — vérifiée avant exécution |
| Installation | `msiexec /qn DO_NOT_LAUNCH=1`, code 0 |
| Adresse | `<HYDRA_WG_IP>/32` |
| `AllowedIPs` | `<VPS_WG_IP>/32` **uniquement** |
| `PersistentKeepalive` | 25 s (NAT Freebox) |
| Service | `WireGuardTunnel$HomeSpotify-VPS`, `Automatic`, reprise 5 s / 10 s / 30 s |
| Clé privée | générée sur HYDRA, jamais affichée, jamais transmise |
| Config | `C:\ProgramData\HomeSpotify-H24\wg\HomeSpotify-VPS.conf`, ACL SYSTEM + Administrateurs |

Le pair `<OLD_AGENT_WG_IP>` du gros PC n'a jamais été touché.

### Incident É1 — corrigé, avec une leçon

J'ai d'abord supprimé le fichier de configuration après installation du service, en supposant —
à tort — que WireGuard en conservait une copie chiffrée sous
`Program Files\WireGuard\Data\Configurations`, comme le fait l'installation par interface
graphique sur le gros PC.

**C'est faux pour `/installtunnelservice <chemin>`** : le service référence le **chemin d'origine**
(`BINARY_PATH_NAME … /tunnelservice C:\ProgramData\…\HomeSpotify-VPS.conf`) et ne recopie rien.
Le tunnel a continué de fonctionner tant qu'il tournait en mémoire, puis a échoué au redémarrage :
`id=7031`, service arrêté 12 fois de suite.

La clé privée n'existant nulle part ailleurs, elle a été **régénérée**, et le pair a été remplacé
côté VPS. Coût réel : une clé publique à mettre à jour. Aucun impact sur PROD.

Règle retenue : **le fichier `.conf` référencé par le service est la configuration vive ; il ne
doit jamais être supprimé.** Il est désormais protégé par ACL en place, pas effacé.

---

## É2 — Pair ajouté à chaud sur le VPS

| Contrôle | Avant | Après |
|---|---|---|
| `/health` public | **200** | **200** |
| Pairs sur `wg0` | 1 | **2** |
| Handshake gros PC | epoch `1787055188` | epoch `1787055188` — **identique** |
| Transfert gros PC | 22,48 Gio | 22,48 Gio — **compteurs préservés** |
| Handshake HYDRA | — | **7 s** après ajout |

Méthode : `wg set wg0 peer … allowed-ips <HYDRA_WG_IP>/32`, **jamais** `wg-quick down/up`. L'interface
n'a pas été recréée, donc la session du gros PC n'a pas été interrompue — le handshake à l'époque
inchangée le prouve formellement.

Persistance : bloc `[Peer]` **ajouté** en fin de `wg0.conf`. Le `diff` avec la sauvegarde
`wg0.conf.bak-20260818T141419Z` ne montre qu'un ajout de 5 lignes ; le bloc du gros PC est intact.
Syntaxe validée par `wg-quick strip` sans application.

Connectivité `<VPS_WG_IP> ↔ <HYDRA_WG_IP>` : **3/3 paquets**, RTT ~23 ms, dans les deux sens.

**Rollback < 1 min** : `/usr/local/sbin/h24-rollback-hydra-peer.sh` (root, 0700) — retire le pair à
chaud, supprime son bloc dans `wg0.conf`, ne touche jamais `<OLD_AGENT_WG_IP>`.

---

## É3 — Storage Agent sur HYDRA

| Élément | Valeur |
|---|---|
| Version | **0.3.0**, celle de PROD |
| Provenance | copie de `C:\ProgramData\HomeSpotify\StorageAgent\app` du gros PC |
| WinSW | binaire du dépôt, `sha256 05b82d46…a0da` — **identique au bit près** à celui en production |
| Runtime | `C:\ProgramData\HomeSpotify\runtime\node-v22.18.0-win-x64\node.exe` (**pas** le Node système v24.14.0) |
| Racine musicale | `D:\HomeSpotifyStorage\music` — hors Git, **vide** |
| Bind | `<HYDRA_WG_IP>:3100` |
| Identité | `NT SERVICE\HomeSpotifyStorageAgent`, compte virtuel sans mot de passe |
| Démarrage | `Automatic`, **différé**, dépendances `Tcpip` + `WireGuardTunnel$HomeSpotify-VPS` |
| Reprise | 15 s / 60 s / 120 s puis arrêt — bornée volontairement |
| Index | 0 entrée (aucune musique copiée) |

### Moindre privilège

| Chemin | Droit du compte de service |
|---|---|
| `…\StorageAgent\app` | ReadAndExecute |
| `…\StorageAgent\service` | ReadAndExecute |
| `…\StorageAgent\config\agent.env` | **Read** |
| `…\StorageAgent\data` | Modify |
| `…\StorageAgent\logs` | Modify |
| `D:\HomeSpotifyStorage\music` | **ReadAndExecute** (écriture ouverte seulement en É4) |
| `C:\ProgramData\HomeSpotify\runtime` | ReadAndExecute |

`agent.env` : SYSTEM + Administrateurs en contrôle total, compte de service en **lecture seule**.
Secret partagé identique à celui du gros PC — la bascule É7 restera un simple changement d'URL.
Le fichier a été transféré directement de config à config, sans jamais transiter par un journal,
un rapport ou une ligne de commande.

### Défaut rencontré et corrigé — ancrage des règles de pare-feu

Les règles avaient d'abord été liées à `InterfaceAlias 'HomeSpotify-VPS'`. Or WireGuard **recrée
l'adaptateur** à chaque démarrage du tunnel, avec un nouveau GUID : la liaison se perd et la règle
cesse de s'appliquer. Constaté immédiatement après la réinstallation du tunnel — le ping
VPS → HYDRA est retombé à 100 % de perte.

Les deux règles sont désormais ancrées sur les **adresses**, stables par construction :
`LocalAddress = <HYDRA_WG_IP>`, `RemoteAddress = <VPS_WG_IP>`. `<HYDRA_WG_IP>` n'existe que sur le tunnel et
`<VPS_WG_IP>` n'est joignable qu'au travers : la restriction est équivalente, sans la fragilité.

Sans cette correction, le port 3100 serait devenu injoignable au premier redémarrage — panne
silencieuse et différée.

---

## Qualification depuis le VPS

| Requête | Attendu | Obtenu |
|---|---|---|
| `GET /internal/storage/health` **sans signature** | refus | **401** `AUTH_MISSING` |
| idem, **signature invalide** | refus | **401** `AUTH_INVALID` |
| idem, **signature HMAC valide** | succès | **200** — `agentVersion 0.3.0`, `indexEntryCount 0` |
| gros PC `<OLD_AGENT_WG_IP>`, signature valide | succès | **200** — `indexEntryCount 175` |

Contrat HMAC vérifié conforme au backend : canonique
`MÉTHODE\nchemin\ntimestamp\nnonce\nsha256(corps)`, en-têtes `x-hs-timestamp`, `x-hs-nonce`,
`x-hs-content-sha256`, `x-hs-signature`.

### Isolation réseau du port 3100

| Origine | Résultat |
|---|---|
| LAN `<HYDRA_WIFI_LAN_IP>:3100` | **injoignable** |
| Tailscale `<HYDRA_TAILSCALE_IP>:3100` | **injoignable** |
| Internet `<HOME_PUBLIC_IP>:3100` | **injoignable** |
| WireGuard `<HYDRA_WG_IP>:3100` depuis `<VPS_WG_IP>` | **200 en HMAC signé** |

Une seule règle ouvre 3100 sur toute la machine.

---

## Remontée automatique après redémarrage

Redémarrage complet, sans session ouverte :

| Repère | Δ T0 |
|---|---|
| Coupure réseau | 11 s |
| SSH LAN | 63 s |
| SSH Tailscale | 77 s |
| Tunnel WireGuard | `Running / Automatic` |
| Storage Agent | `Running / Automatic`, écoute `<HYDRA_WG_IP>:3100` |
| Règles pare-feu | actives, ancrage adresse conservé |

Deux comportements notables :

1. **Le premier redémarrage a validé la dépendance de service** : le tunnel étant cassé (incident
   É1), l'agent est resté `Stopped` au lieu de démarrer sur une adresse inexistante. C'est
   exactement le comportement demandé — l'agent ne démarre jamais dans un état cassé.
2. **Le chemin de secours Tailscale a servi en conditions réelles** : le LAN a été
   momentanément injoignable après le redémarrage, et HYDRA a été administrée par
   `homespotify-minipc-ts`. Le Wi-Fi était bien `Up` — la coupure était transitoire.

---

## Gates

| # | Gate | Résultat |
|---|---|---|
| 1 | Ancien agent `<OLD_AGENT_WG_IP>` fonctionnel | ✅ 200, 175 entrées |
| 2 | Nouveau pair `<HYDRA_WG_IP>` stable | ✅ handshake continu, survit au redémarrage |
| 3 | Agent HYDRA joignable **uniquement** par le VPS | ✅ LAN, Tailscale et Internet bloqués |
| 4 | Services remontent automatiquement | ✅ tunnel puis agent, sans session |
| 5 | 0 conflit port / IP | ✅ 1 seule règle sur 3100, 1 seule écoute, 1 seule adresse 10.8.x |
| 6 | PROD `/health` 200 | ✅ à chaque étape |
| 7 | Aucun secret exposé | ✅ ACL strictes, aucun secret en journal, rapport ou Git |
| 8 | Aucune musique copiée | ✅ `D:` : 0 fichier, 3725,8 Go libres |
| 9 | Aucune bascule PROD | ✅ `AUDIO_REMOTE_BASE_URL=http://<OLD_AGENT_WG_IP>:3100` |

# H24_E1_E3_PASS

---

## Écart de périmètre à retenir pour É4

La bibliothèque n'est plus à 173 fichiers : **175**, en base comme dans l'index.

```
#175  winnterzuko - Rollo      2026-08-17T19:10:19.854Z
#174  winnterzuko - Trotski    2026-08-17T19:09:50.700Z
```

Ces deux pistes ont été acquises après l'audit de Phase 1. PROD est vivante : tout décompte figé
dans un document devient faux. Le manifeste M0 sera donc construit **au moment de la copie**, et
la vérification comparera HYDRA au manifeste, jamais à un nombre écrit à l'avance.

Détail dans [H24_E4_COPY_PLAN.md](H24_E4_COPY_PLAN.md).
