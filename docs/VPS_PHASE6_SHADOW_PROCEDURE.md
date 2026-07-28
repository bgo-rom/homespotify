# Phase 6 — Procédure de déploiement shadow

- **Date :** 2026-07-27
- **État :** **outillage construit et validé localement — AUCUN DÉPLOIEMENT EFFECTUÉ**
- **Branche :** `phase6/vps-shadow-deployment`, socle `033f4f51`

Aucune connexion SSH n'a été ouverte pendant la construction de cet outillage.
Aucun fichier n'a été transféré, aucun service créé, aucune base touchée.
Caddy, DNS, WireGuard, pare-feu et services Windows sont inchangés.

## 1. Ce que déploie la Phase 6

Une API HomeSpotify **shadow** sur le VPS, écoutant exclusivement sur
`127.0.0.1:3002`, alimentée par
`CachedAudioStorageProvider(RemoteWindowsStorageProvider)` à travers WireGuard,
sur une **copie jetable** de SQLite. Le port 3001 reste réservé aux harnais des
Phases 4.5 et 5 : les deux peuvent coexister.

Le shadow ne reçoit aucun trafic public. **Aucune bascule n'appartient à cette
phase.**

## 2. Outillage

| Étape | Script | Exécution |
| --- | --- | --- |
| A | `build_shadow_artifact.ps1` | Windows |
| B | `snapshot_sqlite_shadow.ps1` → `phase6_sqlite_snapshot.mjs` | Windows |
| C | `phase6_build_manifest.py` / `phase6_manifest.py` | Windows |
| D | `vps_phase6_preflight.sh` | VPS |
| E | `vps_phase6_install_release.sh` | VPS |
| F | `vps_phase6_systemd_setup.sh` | VPS |
| G | `vps_phase6_shadow_tests.py` | VPS |
| H | `vps_phase6_rollback.sh` | VPS |
| I | `vps_phase6_cleanup.sh` | VPS |
| — | `run_phase6_shadow_deploy.ps1` | orchestrateur, `-DryRun` |

Chaque étape distante reste un script séparé, lisible et testable isolément.
L'orchestrateur enchaîne, il ne cache aucune logique.

## 3. Artefact

Contenu : `dist/`, `package.json` réduit au runtime, migrations `drizzle/`,
`manifest.json`. Mesuré en dry-run : **107 fichiers, 1 032 800 octets**.

Exclusions appliquées par `phase6_manifest.is_excluded()` : `.env`, secrets,
bases SQLite et WAL, audio, journaux, clés, caches, `node_modules`, tests,
et **`.map`** — les source maps embarquent les chemins sources.

> **Défaut trouvé et corrigé pendant cette phase.** Le premier assemblage
> produisait 207 fichiers sur disque pour 107 déclarés : les `.map` étaient
> exclus du manifeste mais restaient copiés. Le transfert aurait été refusé
> sur le VPS en `EN_TROP`, après coup. `prune_excluded()` supprime désormais
> physiquement les exclusions, et le staging est égal au manifeste **par
> construction**. Un test verrouille ce comportement.

`release-id` = `<utc>-<commit8>-<manifest8>`, par exemple
`20260727T215602Z-033f4f51-8f4b2c54`. L'horodatage le rend unique et
ordonnable, l'empreinte le rend vérifiable. Le manifeste, lui, ne dépend que du
contenu : deux assemblages du même code donnent la même empreinte.

## 4. `node_modules` Linux — bundle immuable partagé

Le VPS n'a ni gcc, ni make, ni node-gyp : **aucun module natif n'y est
recompilable**. Le déploiement n'exécute donc jamais `npm install`.

Choix retenu : **bundle versionné, immuable et partagé**, sous
`/opt/homespotify-api-shadow/dependency-bundles/<bundle-id>`, référencé par le
manifeste (`dependencyBundleId`) et relié à chaque release par un symlink
`node_modules`. Identifiant : `linux-x64-node22.18.0-abi127`.

> **Correction Phase 6.2.** Le contenu du bundle vit sous
> `<bundle-id>/`**`node_modules/`**, et le symlink de release pointe ce
> sous-répertoire. Node ne résout les dépendances pairs qu'à travers des
> répertoires nommés exactement `node_modules` : déposé directement sous
> `<bundle-id>/`, `better_sqlite3.node` était présent, intact, et le premier
> `require` échouait sur `Cannot find module 'bindings'`. Le défaut était
> latent dans le préflight écrit en Phase 6.1 (L-109).

*Conséquence pour le rollback* — c'est la raison du choix : chaque release
pointe vers **son** bundle. Un rollback retrouve donc les dépendances avec
lesquelles la release précédente a été qualifiée, et non celles de la release
fautive. Une copie par release aurait aussi cette propriété mais dupliquerait
~125 Mio à chaque promotion ; le bundle partagé étant immuable, il n'y a aucun
risque de modification rétroactive.

Le préflight refuse la promotion si : le bundle est absent, un `.node` manque,
Node n'est pas exactement `v22.18.0`, l'ABI n'est pas `127`, l'architecture
n'est pas `x64`, une empreinte native diverge, ou si `require('better-sqlite3')`
suivi d'un CREATE/INSERT/SELECT sur une base temporaire échoue.

## 5. Snapshot SQLite

`VACUUM INTO`, jamais une copie de fichier : `runtime.db` est en WAL et vivant,
un `cp` capturerait un état qui n'a jamais existé (L-095).

Le script ouvre la source en **lecture seule**, refuse une destination
existante, écrit dans un staging hors production, puis contrôle
`integrity_check`, `foreign_key_check`, le compte de `__drizzle_migrations`,
la taille et le SHA-256. La source est re-mesurée après copie pour prouver
qu'elle est inchangée. **En cas d'échec, la copie est supprimée** — une base
non validée ne doit jamais pouvoir être promue.

Le chemin source n'est jamais publié en entier : seul son nom de fichier
apparaît.

> `user_version = 0` est **attendu**. Drizzle suit les migrations dans
> `__drizzle_migrations` ; un contrôle portant sur `user_version` ne
> vérifierait rien.

## 6. Chemins et environnement

| Variable réelle (`config.ts`) | Valeur |
| --- | --- |
| `DB_PATH` | `/var/lib/homespotify-shadow/data/runtime.db` |
| `AUDIO_CACHE_ROOT` | `/var/lib/homespotify-shadow/cache/audio` |
| `COVERS_DIR` | `/var/lib/homespotify-shadow/covers` |
| `INCOMING_DIR` | `/var/lib/homespotify-shadow/imports/incoming` |
| `OFFLINE_CACHE_DIR` | `/var/lib/homespotify-shadow/offline-variants` |

> **Écart de nommage à connaître.** Le cahier des charges nomme
> `AUDIO_CACHE_DIR` et `OFFLINE_VARIANTS_DIR`. Ces variables **n'existent pas**
> dans `config.ts`, qui lit `AUDIO_CACHE_ROOT` et `OFFLINE_CACHE_DIR`. Les
> employer laisserait s'appliquer les défauts relatifs — exactement le piège
> que la Phase 6 veut éviter. Les noms réels sont donc utilisés, la disposition
> des répertoires reste celle demandée, et un test le verrouille.

Stratégie : SQLite en copie jetable, covers copiés, incoming **vide**,
variantes hors ligne **vides**, sauvegardes et découverte **désactivées**,
musique **jamais copiée** (toujours via le Storage Agent).

`NODE_ENV=production` et non `test` : `NODE_ENV=test` désactive entièrement le
logger (L-108), donc toute preuve pendant les tests shadow. Le watcher d'import
tourne, mais sur un répertoire vide : il n'a rien à traiter.

Les deux secrets (`AUDIO_REMOTE_SHARED_SECRET`, `AUTH_TOKEN_SECRET`) sont des
marqueurs `__A_INJECTER__` dans le modèle versionné. Ils sont injectés au
déploiement dans `/etc/homespotify/api-shadow.env` en `0600`, jamais affichés,
jamais passés en ligne de commande.

## 7. Unité systemd

`homespotify-api-shadow.service`, utilisateur système `homespotify`,
`WorkingDirectory` sur le symlink `current`, `ExecStart=/usr/local/bin/node
dist/server.js`, `Restart=on-failure`, `RestartSec=5`, `TimeoutStopSec=30`,
`KillSignal=SIGTERM`, `UMask=0027`, `LimitNOFILE=8192`.

Durcissement : `NoNewPrivileges`, `PrivateTmp`, `PrivateDevices`,
`ProtectSystem=strict`, `ProtectHome`, `ProtectKernel*`, `RestrictSUIDSGID`,
`CapabilityBoundingSet=` vide, `TasksMax=256`.

Trois points nommés plutôt que subis :

- **`ReadWritePaths=/var/lib/homespotify-shadow`** est indispensable :
  `ProtectSystem=strict` rend tout le système en lecture seule, et sans cette
  ligne ni SQLite ni le cache ne peuvent écrire.
- **`RestrictAddressFamilies=AF_UNIX AF_INET`** : `AF_INET` est obligatoire, le
  Storage Agent étant joint en IPv4 sur `10.8.0.2:3100`.
- **`MemoryMax` volontairement absent** : un plafond posé avant le soak
  tuerait le processus pendant une écriture, et les redémarrages masqueraient
  un vrai défaut. À poser après la baseline RSS.

`ProtectHome=true` masque `/home/debian` : c'est voulu, le shadow n'a rien à y
lire — corollaire, ne jamais faire pointer une release vers `/home`.

`vps_phase6_systemd_setup.sh --verify-only` lance `systemd-analyze verify`
**avant** toute écriture dans `/etc`.

## 8. Promotion atomique

**Invariant : `current` ne pointe jamais vers un répertoire incomplet.**

1. transfert dans `staging` ;
2. `phase6_manifest_verify.py` : contenu == manifeste, à l'octet près ;
3. préflight ABI, modules natifs, hashes ;
4. smoke `better-sqlite3` réel ;
5. copie SQLite installée **si absente** (une base en place n'est jamais
   écrasée) ;
6. permissions : `chmod -R go-w`, le service lit son code sans le réécrire ;
7. `mv -T staging releases/<id>` — atomique ;
8. `previous` ← ancienne cible, puis `mv -T current.new current` — atomique ;
9. `systemctl restart` ;
10. health `127.0.0.1:3002` sous 60 s ;
11. rollback si health échoue.

Idempotent : une release déjà promue est détectée et l'opération ne refait
rien.

## 9. Rollback et cleanup

**Rollback** — `current` revient sur `previous`, redémarrage, health. La
release fautive est **conservée** : supprimer ce qu'on vient de constater
défaillant, c'est détruire la seule pièce à conviction.

**Cleanup** — arrêt, désactivation, suppression de l'unité et de son override,
puis des chemins shadow uniquement. Chaque suppression passe par `guard()`,
qui refuse tout chemin hors des deux racines shadow, toute remontée `..`, et
tout chemin protégé : `/home/debian/homespotify-phase45`,
`/home/debian/homespotify-phase5`, `/etc/caddy`, `/etc/wireguard`. Le rapport
final assère `remainingShadowPaths=0`, `remainingSecretFiles=0`,
`listeners3002=0`, et publie `preservedProtectedPaths`.

## 10. Tests shadow (à exécuter plus tard)

`vps_phase6_shadow_tests.py`, modes `health`, `read`, `cache`, `offline`.
Discipline Phase 5 : un statut HTTP ne prouve rien ; un HIT exige un
`CACHE_HIT` corrélé par `requestId`, lu dans journald. Les contrôles incluent
`upstreamNotContactedOnHit`, `uncachedReportsUnavailable` (503) et
`internal401NotExposed`.

## 11. Commandes

Dry-run — **exécuté, vert** :

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File F:\dev\homespotify-phase6-shadow\scripts\phase6\run_phase6_shadow_deploy.ps1 -DryRun
```

Staging sans activation (Phase 6.2) — **exécuté, vert**. Dépose une release
complète sous `/home/debian/homespotify-phase6-staging/` sans rien activer :

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File F:\dev\homespotify-phase6-shadow\scripts\phase6\run_phase6_shadow_deploy.ps1 -StageOnly -SecretsFromWindowsConfig -SourceDbPath "F:\dev\homespotify\services\api\data\homespotify.db" -SourceCoversPath "F:\dev\homespotify\storage\covers"
```

Nettoyage du staging — supprime cette racine et rien d'autre :

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File F:\dev\homespotify-phase6-shadow\scripts\phase6\run_phase6_shadow_deploy.ps1 -CleanupStaging
```

Déploiement réel (Phase 6.3) — **à ne lancer qu'après validation explicite du
rapport Phase 6.2** ; `-Deploy` et `-Rollback` sont désarmés dans le code tant
que cette validation n'a pas eu lieu :

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File F:\dev\homespotify-phase6-shadow\scripts\phase6\run_phase6_shadow_deploy.ps1 -Deploy -SourceDbPath "<chemin homespotify.db production>"
```

## 12. Validation locale

Outillage Phase 6 **65/65** · harnais Phase 5 **107/107** · API **488/488** ·
Storage Agent **148/148** · typechecks et builds verts · `py_compile` ·
`bash -n` sur 5 scripts · 3 scripts PowerShell `PARSE_OK` ·
`git diff --check` vert. Aucun test VPS Phase 5 rejoué.

## 13. Informations encore requises — **toutes fermées en Phase 6.2**

Les cinq points ci-dessous étaient ouverts à la fin de la Phase 6.1. Ils ont
été résolus sur le réel : voir `VPS_PHASE6_STAGING_GATE.md`.

1. ~~**chemin de `runtime.db` de production**~~ → `services/api/data/homespotify.db`,
   dérivé du service Windows `HomeSpotifyApi` et non d'une saisie. Le nom réel
   est `homespotify.db` ; `runtime.db` est le nom de la **destination** dans le
   shadow ;
2. ~~**secrets à injecter**~~ → `AUDIO_REMOTE_SHARED_SECRET` lu dans la
   configuration du Storage Agent ; `AUTH_TOKEN_SECRET` **généré** pour le
   shadow, jamais repris de la production (voir `TD-Phase6-Secrets-2026-07-28`) ;
3. ~~**identifiants de pistes**~~ → sélectionnés automatiquement depuis le
   snapshot et validés par `HEAD 200` réel : `119` (cache) et `120` (hors
   ligne) ;
4. ~~**gel de Node**~~ → confirmé en lecture seule : `v22.18.0`, ABI `127`,
   `x64`, glibc 2.36 ;
5. ~~**provenance du bundle Linux**~~ → confirmée :
   `/home/debian/homespotify-phase45/api/node_modules`, 118 entrées,
   39 364 495 octets, traité en lecture seule. Le contenu est déposé sous
   `<bundle-id>/**node_modules/**` — ce nom est un contrat d'exécution (L-109).

Point ouvert restant, de nature différente : le staging qualifie le **dépôt**,
pas l'**exécution**. Le premier démarrage réel de l'API appartient à la
Phase 6.3.
