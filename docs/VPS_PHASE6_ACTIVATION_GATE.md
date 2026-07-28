# Phase 6.3 — Installation et première activation shadow

- **Date :** 2026-07-28
- **Branche :** `phase6/vps-shadow-deployment`
- **HEAD au moment de l'activation :** `353a918dfbc78af7f12d215094aae9435a75e7ea`
- **Release installée :** `20260728T185714Z-88a6d12f-f09a54cf`
- **Verdict :** **GO**

Le shadow tourne sur `127.0.0.1:3002`. Aucune bascule publique n'a eu lieu.

> **La release nommée dans la commande de phase, `20260728T174900Z-b5b4d4d5-8f4b2c54`,
> était INCOMPLÈTE et est définitivement écartée.** Elle ne contenait aucun des
> douze fichiers de `dist/storage/`. Voir §2.

---

## 1. Verdict

**GO.** Les treize critères sont verts sur le réel.

| Critère | Résultat |
| --- | --- |
| Installation atomique | `current` créé en dernier, après vérification |
| Unité systemd valide | `systemd-analyze verify` avant écriture dans `/etc` |
| Service actif sans boucle | `active/running`, PID 64749, **0 redémarrage** |
| Écoute | **127.0.0.1:3002 uniquement** — 0 wildcard, 0 IPv6, 0 WireGuard |
| Health | 200 |
| Authentification shadow | jeton forgé avec le secret du shadow, jamais affiché |
| SQLite et pochettes | `integrity_check=ok`, 18 migrations, 156 pochettes servies |
| MISS / HIT / HEAD / Range | T5–T8 verts, HIT prouvé par événement corrélé |
| Cache après redémarrage | T10 vert, `CACHE_HIT` immédiat, 0 contact distant |
| Écriture jetable persistante | T11 vert, puis annulée |
| Production inchangée | base, services Windows, Caddy, domaine : identiques |
| Staging nettoyé | racine supprimée, 0 secret résiduel |
| Surveillance initiale saine | 900 s, 0 erreur, 0 warning, PID stable |

**Cinq défauts réels ont été trouvés et corrigés** — L-112 à L-116. Le premier
rendait l'artefact inexécutable et était invisible à tous les contrôles
d'intégrité de la Phase 6.2.

---

## 2. Release installée — et pourquoi ce n'est pas celle annoncée

La release `20260728T174900Z-b5b4d4d5-8f4b2c54`, qualifiée en Phase 6.2, a
échoué au premier démarrage réel :

```
Error [ERR_MODULE_NOT_FOUND]: Cannot find module '…/dist/storage/local-file-storage.js'
```

`phase6_manifest.is_excluded()` écartait tout segment de chemin nommé
`storage` — un nom de répertoire de **données** à la racine du dépôt, mais un
nom de **module applicatif** sous `dist/`. Les douze fichiers de
`dist/storage/` — la couche de stockage audio, c'est-à-dire précisément l'objet
de la Phase 6 — n'étaient jamais partis.

Rien ne pouvait le voir en amont : le manifeste était cohérent avec lui-même,
le transfert exact à l'octet près, les empreintes justes, le préflight vert.
Tous ces contrôles portent sur *ce qui est présent* ; aucun sur *ce qui
manque*. C'est exactement la réserve posée au §15 du rapport 6.2 — « le staging
qualifie le dépôt, pas l'exécution ».

| | Ancienne | Installée |
| --- | --- | --- |
| `releaseId` | `20260728T174900Z-b5b4d4d5-8f4b2c54` | `20260728T185714Z-88a6d12f-f09a54cf` |
| Fichiers applicatifs | 107 (**incomplet**) | **119** |
| Octets | 1 032 800 | 1 095 066 |
| `manifestSha256` | `8f4b2c54…` | `f09a54cf44d4ec6a…` |
| Commit | `b5b4d4d5` | `88a6d12f` |

Un second défaut du même ordre a été corrigé dans la foulée : le
`package.json` généré portait un **BOM UTF-8** (`Set-Content -Encoding utf8`
sous Windows PowerShell 5.1), et `dist/routes/admin.js` en fait un
`JSON.parse` au chargement. Également invisible à tout contrôle d'intégrité.

**Le garde d'activation ne se contente pas du nom de la release** : il vérifie
que `services/api` n'a pas bougé depuis le commit de la release, **et** que
l'empreinte du manifeste déposé est bien celle portée par le `releaseId`. Cette
seconde preuve est indépendante des chemins.

---

## 3. Utilisateur et chemins créés

Utilisateur système `homespotify` (uid 994, gid 993), `/usr/sbin/nologin`,
sans home.

| Chemin | Propriétaire | Mode |
| --- | --- | --- |
| `/opt/homespotify-api-shadow` | `root:homespotify` | `0750` |
| `└─ releases/20260728T185714Z-88a6d12f-f09a54cf` | `root:homespotify` | `u=rwX,g=rX,o=` |
| `└─ dependency-bundles/linux-x64-node22.18.0-abi127/node_modules` | `root:homespotify` | `u=rwX,g=rX,o=` (118 entrées) |
| `└─ current` → la release | symlink | — |
| `└─ tools/` | `root:homespotify` | `0750` |
| `/var/lib/homespotify-shadow` | `homespotify:homespotify` | `0750` |
| `└─ data/runtime.db` | `homespotify:homespotify` | `0640` |
| `└─ covers/` (156 fichiers) | `homespotify:homespotify` | `u=rwX,g=rX,o=` |
| `└─ cache/audio/`, `imports/incoming/`, `offline-variants/` | `homespotify:homespotify` | `0750`, créés **vides** |
| `/etc/homespotify` | `root:root` | `0750` |
| `└─ api-shadow.env` | `root:root` | `0600` |

Aucun chemin hors de ces racines. Le symlink `node_modules` de la release
pointe sous `/opt` — vérifié par `readlink -f`, refus explicite s'il en sortait.

---

## 4. Contrôles manifeste / bundle / SQLite / pochettes

Effectués **avant** la promotion, depuis `releases/.incoming-<id>` :

- manifeste revérifié à l'octet près → 0 écart ;
- Node `v22.18.0`, ABI `127`, `x64` ;
- `better_sqlite3.node` et `argon2.linux-x64-gnu.node` aux empreintes gelées ;
- `require('better-sqlite3')` réel **depuis la disposition de destination**,
  puis CREATE/INSERT/SELECT sur une base temporaire supprimée ensuite.

Après installation :

| Contrôle | Résultat |
| --- | --- |
| `integrity_check` | `ok` |
| `foreign_key_check` | 0 violation |
| `__drizzle_migrations` | **18** (avant le premier démarrage) |
| `tracks` | 158 |
| Taille / SHA-256 SQLite | 3 436 544 o · `1b24d380e27986d7…` (identique au snapshot) |
| Pochettes | **156**, manifeste revérifié → 0 écart |
| Cache / incoming / variantes | **0 fichier** chacun |

---

## 5. Unité systemd effective

`systemd-analyze verify` exécuté **avant** toute écriture dans `/etc`.

`User=homespotify` · `Group=homespotify` ·
`WorkingDirectory=/opt/homespotify-api-shadow/current` ·
`EnvironmentFile=/etc/homespotify/api-shadow.env` ·
`ExecStart=/usr/local/bin/node dist/server.js` · `Restart=on-failure` ·
`RestartSec=5` · `UMask=0027` · `NoNewPrivileges=true` · `PrivateTmp=true` ·
`PrivateDevices=true` · `ProtectSystem=strict` · `ProtectHome=true` ·
`ProtectKernel*` · `RestrictSUIDSGID=true` ·
`ReadWritePaths=/var/lib/homespotify-shadow` ·
`RestrictAddressFamilies=AF_UNIX AF_INET` · `CapabilityBoundingSet=` (vide) ·
`TasksMax=256` · **`MemoryMax` absent**.

**`systemctl start`, jamais `enable`** : `is-enabled` = `disabled`. Un service
activé au boot reviendrait seul après un redémarrage du VPS — un shadow non
qualifié se relancerait sans que personne l'ait décidé.

---

## 6. État du service et écoute

| Champ | Valeur |
| --- | --- |
| `ActiveState` / `SubState` | `active` / `running` |
| `MainPID` | 64749 |
| `NRestarts` | **0** |
| `/health` | 200 |
| `127.0.0.1:3002` | **1** listener |
| `0.0.0.0:3002`, `[::]:3002`, `10.8.0.x:3002` | **0** |
| Boot | `disabled` |
| Erreurs journald | 0 |

Écoutes du VPS, avant et après — seule `127.0.0.1:3002` s'ajoute :

```
*:443  *:80  0.0.0.0:22  0.0.0.0:5355  127.0.0.1:2019
127.0.0.1:3002  127.0.0.53%lo:53  127.0.0.54:53  [::]:22  [::]:5355
```

---

## 7. Méthode d'authentification shadow

Jeton **forgé** avec le secret du shadow, selon le contrat exact de
`signAccessToken()` : HS256 sur `{sub, username, role, type:'access'}`.

Aucun jeton ni secret de production n'intervient — `productionSecretUsed: false`.
Le compte retenu est actif et sans changement de mot de passe imposé, sinon le
garde le refuserait et le test ne prouverait rien.

| Publié | Valeur |
| --- | --- |
| `userId` / `role` | 1 / `OWNER` |
| `visibleTracks` | 147 |
| `tokenBytes` | 208 |
| `tokenPrinted` / `secretPrinted` / `usernamePrinted` | `false` |

Écrit en `0600` par `openSync(path, 'w', 0o600)` — le fichier naît avec ses
permissions. Passé aux tests par `--token-file`, jamais en argument. **Supprimé
en fin de phase** (`tokenRemoved: true`).

**Preuve qu'aucun jeton de production n'est requis** : le secret du shadow est
généré, distinct de celui de production, et il suffit à obtenir 200 sur toutes
les routes authentifiées.

---

## 8. Résultats T1 à T11 — **40 contrôles, 40 verts**

| Test | Mesure | Verdict |
| --- | --- | --- |
| **T1** Health | 200, 1 listener loopback | ✅ |
| **T2** SQLite | `ok`, 0 FK, 18 migrations, 158 pistes | ✅ |
| **T3** Liste | 200, **147** pistes visibles pour l'utilisateur 1 (cohérent : 158 en base, 147 visibles) | ✅ |
| **T4** Pochette | 200, 83 224 o, `image/jpeg`, **empreinte présente au manifeste** | ✅ |
| **T5** MISS | 200, **18 619 182 o exacts**, **SHA-256 exact**, TTFB 314,9 ms, `CACHE_FILL_STARTED` + `CACHE_FILL_COMPLETED`, agent contacté | ✅ |
| **T6** HIT | 200, taille et empreinte identiques, **TTFB 11,6 ms** (27× plus rapide), `CACHE_HIT`, **0 contact distant** | ✅ |
| **T7** HEAD | 200, **corps vide**, `CACHE_HIT`, 0 contact distant | ✅ |
| **T8** Range | **206**, 1 024 o, `Content-Range: bytes 0-1023/18619182`, `CACHE_HIT`, 0 contact distant | ✅ |
| **T9** 2ᵉ piste | piste 120, HEAD 200, 18 680 561 o, hash SHA-256 valide, non synthétique | ✅ |
| **T10** Après redémarrage | restart du **seul** shadow, 200, **`CACHE_HIT` immédiat** (TTFB 18,8 ms), contenu identique, 0 contact distant | ✅ |
| **T11** Écriture jetable | favori `POST` 201, visible, **persiste après redémarrage**, puis supprimé (204) | ✅ |

Discipline Phase 5 respectée : un HIT n'est un HIT que si un `CACHE_HIT` porte
le `requestId` de la requête, lu dans journald. Les tailles et empreintes
attendues sont **lues dans la copie jetable**, jamais codées en dur — le test
compare le service à sa propre source de vérité.

Aucun import réel, aucune acquisition, aucun courriel, aucun traitement externe.

---

## 9. Surveillance initiale — 900 s, 30 échantillons

| Métrique | min | max | final |
| --- | --- | --- | --- |
| RSS | 94 372 Ko | **126 224 Ko** | 100 180 Ko |
| Descripteurs | 29 | 29 | 29 |
| Threads | 11 | 11 | 11 |
| Cache | 18 705 326 o | 18 705 326 o | 18 705 326 o |

CPU cumulé **2,0 s** · `runtime.db` 3 436 544 o · WAL 12 392 o · SHM 32 768 o ·
`NRestarts` **0** · PID stable · **0 erreur**, **0 warning** journald ·
anomalies de listener loopback **0**, publiques **0** · santé publique 200.

Le RSS redescend de 126 Mo (pic pendant le streaming) à 100 Mo : pas de fuite
visible sur cette fenêtre. **Ce contrôle court ne remplace pas le soak de deux
heures de la Phase 6.4** — le rapport le porte explicitement
(`soakReplaced: false`).

---

## 10. État du cache après redémarrage

1 objet audio, 18 705 326 o, 4 fichiers au total (objet + index SQLite). Après
`systemctl restart`, la piste 119 est servie en **`CACHE_HIT`** à 18,8 ms
**sans aucun contact** avec le Storage Agent : l'index et l'objet sont
retrouvés sur disque.

---

## 11. État du staging

**Supprimé.** `rootRemoved: true`, `remainingStagingFiles: 0`,
`remainingSecretFiles: 0`, `preservedProtectedPaths: 4`,
`bundleSourcePresent: 1`. Aucun secret dupliqué sous `/home/debian`.

Les outils nécessaires à la Phase 6.4 (tests, sonde, surveillance) ont été
installés sous `/opt/homespotify-api-shadow/tools/` **avant** le nettoyage.

`remainingListeners: 1` et `port3002Free: false` dans ce rapport sont
**attendus** : c'est le shadow lui-même, qui doit rester démarré.

---

## 12. État Caddy et production

| Contrôle | Avant | Après |
| --- | --- | --- |
| Caddy | `active` | `active` |
| SHA-256 `Caddyfile` | `a3b4ca2b441f311a9970…` | **identique** |
| `music.romainbegot.fr/health` | 200 | **200** |
| `music.romainbegot.fr/` | 404 (par conception) | **404** |
| WireGuard | `active` | `active` |
| Storage Agent (10.8.0.2:3100) | joignable | joignable |
| `homespotify.db` Windows | 3 579 904 o | **identique, mtime inchangé** |
| Services Windows | `HomeSpotifyApi=Running`, `HomeSpotifyStorageAgent=Running` | **identiques** |

Aucun port Internet ajouté, aucune règle de pare-feu, aucun DNS touché.

---

## 13. Fichiers et scripts corrigés

| Fichier | Correction |
| --- | --- |
| `phase6_manifest.py` | exclusions de données **ancrées au premier niveau** (L-112) |
| `build_shadow_artifact.ps1` | `package.json` écrit en UTF-8 **sans BOM** |
| `run_phase6_shadow_deploy.ps1` | mode `-Activate`/`-RollbackInstall` ; collision `$activate`/`$Activate` (L-113) ; `-AsRoot` (L-114) ; `Get-LastJson` recolle les fragments, plus d'`Out-String` (L-116) ; idempotence explicite ; message d'état factuel |
| `vps_phase6_activate_shadow.sh` | **nouveau** — installation immuable ; modes posés (L-115) ; lisibilité prouvée sous l'identité du service |
| `vps_phase6_start_shadow.sh` | **nouveau** — démarrage contrôlé, refus de listener public, sans réessai aveugle |
| `vps_phase6_preinstall_check.sh` | **nouveau** — extrait d'un here-string PowerShell où `$4` d'`awk` et `:3002$` étaient interpolés : **le contrôle du port renvoyait toujours zéro** |
| `vps_phase6_monitor.sh` | **nouveau** — surveillance min/max/final, lecture seule |
| `phase6_shadow_token.mjs` | **nouveau** — jeton shadow forgé, jamais affiché |
| `vps_phase6_shadow_tests.py` | suite T1–T11, jeton par fichier |
| `vps_phase6_systemd_setup.sh` | `0750` au lieu de `0755` ; `enable` derrière `--enable` |
| `vps_phase6_preflight.sh`, `vps_phase6_install_release.sh` | `node_modules` (L-109, corrigé en 6.2) |
| `.gitignore` | `__pycache__/`, `*.pyc` |

---

## 14. Tests locaux ajoutés

| Suite | Résultat |
| --- | --- |
| `test_phase6_tooling.py` (6.1) | 65/65 |
| `test_phase6_staging.py` (6.2) | 96/96 |
| `test_phase6_activation.py` (6.3) | **73/73** |
| **Total outillage Phase 6** | **234/234** |
| API | **488/488** |
| Storage Agent | **148/148** |

Régressions ajoutées pour chaque défaut : couche `storage` présente dans
l'artefact · aucun BOM en tête d'un fichier d'artefact · aucune variable
homonyme d'un paramètre · lectures privilégiées en root · permissions posées et
lisibilité prouvée sous l'identité du service · sortie distante jamais repliée ·
défauts `systemctl` qui ne se concatènent pas · `.ps1` en UTF-8 avec BOM ·
`.sh` sans `\r` · parseur PowerShell sur les trois scripts.

Contrôles de syntaxe : `bash -n` sur 9 scripts, `py_compile`, 3 `.ps1`
`PARSE_OK`, `git diff --check` vert.

---

## 15. Commits

| Commit | Objet |
| --- | --- |
| `353a918` | `feat(vps): activate shadow API service` |
| *(ce document)* | `docs(vps): document shadow activation gate` |

Aucun push, aucun tag.

---

## 16. Éléments restant pour la Phase 6.4

1. **Soak de 2 h** — la surveillance de 900 s détecte une fuite grossière, rien
   de plus. Le rapport le déclare (`soakReplaced: false`).
2. **`MemoryMax`** — à poser après la baseline RSS du soak. Pic mesuré :
   126 Mo pendant le streaming.
3. **Test hors ligne (mode `offline`)** — Storage Agent arrêté, `CACHE_HIT`
   servi et `503` sur une piste non cachée. Non exécuté ici : il exige
   d'arrêter un service Windows de production, ce que la Phase 6.3 interdit.
4. **Éviction du cache** — 1 objet sur 12 Gio ne l'exerce pas.
5. **Décision d'`enable` au boot** — appartient à la bascule, pas à la
   qualification.
6. **Gate produit Phase 0** (session 4 h + restauration) — toujours non prouvé,
   et il conditionne toute déclaration de « prêt pour production ».

---

## 17. Confirmations

| Garantie | État |
| --- | --- |
| Aucun port public ajouté | confirmé — écoutes identiques hors `127.0.0.1:3002` |
| Aucune bascule | confirmé — `cutoverPerformed: false`, Caddy inchangé |
| Service non activé au démarrage | confirmé — `is-enabled` = `disabled` |
| VPS non redémarré, Caddy non rechargé | confirmé |
| Aucun service Windows touché | confirmé — les deux `Running` |
| Base de production inchangée | confirmé — taille et mtime identiques |
| Aucune musique copiée sur le VPS | confirmé — seul le cache, alimenté par streaming |
| Aucun `npm install` sur le VPS | confirmé |
| Aucun `node_modules` Windows | confirmé |
| Aucun secret ni jeton affiché | confirmé — `secretsPrinted: 0`, `tokenPrinted: 0` |
| Aucun push, aucun tag | confirmé |
| Aucun autre worktree touché | confirmé |

Connexions SSH ouvertes : **12**.

---

## 18. Ne pas dépasser

**Ne pas activer le service au démarrage automatique. Ne pas redémarrer le VPS
avant la Phase 6.4.** Le shadow doit rester démarré et non `enabled` pour le
soak.
