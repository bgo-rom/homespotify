# Phase 6 — Gate 0 : audit de préparation

**Date :** 2026-07-27
**Verdict :** **GO — Gate 0 franchi**, sous deux contraintes gérées (§B.7, §A.3)
**Nature :** audit et plan uniquement. Aucun déploiement, aucun `systemd`, aucun
service démarré, aucun fichier envoyé, aucune modification Caddy / WireGuard /
pare-feu / base de production, aucun commit.

Les mesures VPS de ce document proviennent de commandes **strictement en
lecture**, plus un smoke test `better-sqlite3` exécuté dans un répertoire
temporaire créé puis supprimé (§B.6). Aucune base HomeSpotify n'a été ouverte
en écriture.

---

## A. Périmètre Phase 5 figé

### A.1 Manifeste

Branche `feature/lucida-import`, HEAD `c1384cf3149d1248cb4df6fe2f0422589a5410e2`.
SHA-256 tronqué à 16 caractères pour la lisibilité ; recalculable par
`sha256sum`.

| Fichier | Taille | SHA-256 (16) | Git | Rôle | Phase 5 |
| --- | ---: | --- | --- | --- | --- |
| `scripts/run_phase5_cache_integration.ps1` | 14 216 | `2a5592c3723d556a` | `??` | orchestrateur hôte, isolation des scénarios | certaine |
| `scripts/vps_phase5_cache_test.py` | 43 333 | `2ad2c4ddfff27692` | `??` | scénarios et preuves | certaine |
| `scripts/vps_phase5_write_env.py` | 6 941 | `5049db6e33bed26e` | `??` | `.env` 0600, capacité par scénario | certaine |
| `scripts/vps_phase5_setup.sh` | 4 420 | `66ca9d0a26081840` | `??` | préparation API parallèle | certaine |
| `scripts/vps_phase5_switch_scenario.sh` | 3 551 | `93c5e5a1f573b7b8` | `??` | bascule de scénario isolé | certaine |
| `scripts/vps_phase5_cleanup.sh` | 1 208 | `d0076acff6b299ee` | `??` | nettoyage assertif | certaine |
| `scripts/vps_phase5_restart_api.sh` | 875 | `d6acee96635ff801` | `??` | redémarrage API, cache conservé | certaine |
| `scripts/phase5_track_selection.py` | 6 205 | `e6388fe6a3b6d9d3` | `??` | sélection de piste partagée | certaine |
| `scripts/phase5_log_reader.py` | 6 326 | `ae1929345447649e` | `??` | lecture robuste des journaux | certaine |
| `scripts/test_vps_phase5_harness.py` | 22 555 | `3d1ae1ca545ea51d` | `??` | régression harnais | certaine |
| `scripts/test_vps_phase5_proofs.py` | 19 224 | `6efaac2e365bee09` | `??` | régression des preuves | certaine |
| `scripts/test_vps_phase5_logging.py` | 9 559 | `05306425f043d9e0` | `??` | régression journalisation | certaine |
| `scripts/test_vps_phase5_isolation.py` | 20 059 | `2a61bb23b022eb29` | `??` | régression isolation (38 tests) | certaine |
| `docs/VPS_PHASE5_AUDIO_CACHE.md` | 15 064 | `2c3ab7a0848422a3` | `??` | doc Phase 5, GO final | certaine |
| `docs/VPS_PHASE6_SHADOW_DEPLOYMENT_PLAN.md` | 11 657 | `793c8461cf6dfaab` | `??` | plan Phase 6 | certaine |
| `docs/VPS_PHASE6_GATE0_READINESS_AUDIT.md` | — | — | `??` | ce document | certaine |
| `docs/VPS_HYBRID_MIGRATION_PLAN.md` | 39 679 | `abc6dfd5bf31ab8e` | `??` | **mixte** : plan global, 1 ligne Phase 5/6 ajoutée | partielle |
| `TECH_DECISIONS.md` | 87 859 | `59f3264c847faa54` | ` M` | **mixte** | partielle |
| `LESSONS.md` | 119 340 | `5fce5f9de9902418` | ` M` | **mixte** | partielle |

### A.2 Contenu antérieur mélangé

Les deux fichiers suivis contiennent des ajouts **antérieurs** à la Phase 5
(travaux Lucida/import et phases 1–4.5, jamais commités) :

| Fichier | Diff | Hunks | Lignes Phase 5 | Lignes antérieures |
| --- | --- | ---: | --- | --- |
| `TECH_DECISIONS.md` | +392 / −5 | 3 | 705–707 (note « condition levée »), 709–745 (`TD-Phase5-Real-Cache-Qualification`) | ~350 lignes, hunks 1 et 2 + début du hunk 3 |
| `LESSONS.md` | +381 / −0 | 1 | 815–889 (L-106, L-107, L-108) | ~306 lignes (L-0xx antérieures) dans le **même hunk** |
| `docs/VPS_HYBRID_MIGRATION_PLAN.md` | non suivi | — | 1 ligne « Avancement au 2026-07-27 » | tout le reste du document |

`LESSONS.md` est le cas le plus délicat : l'unique hunk de 381 lignes mêle des
leçons antérieures et les trois de la Phase 5. Un `git add` du fichier entier
embarquerait donc du travail non relu dans un commit « Phase 5 ».

### A.3 Plan de commit sélectif (à exécuter plus tard, pas maintenant)

**Fichiers Phase 5 sûrs — `git add` entier possible :** les 16 fichiers
`scripts/*phase5*` et `docs/VPS_PHASE5_*` / `VPS_PHASE6_*` du tableau A.1,
tous non suivis et créés intégralement pour cette phase.

**Fichiers mixtes — `git add -p` obligatoire :** `TECH_DECISIONS.md`,
`LESSONS.md`, `docs/VPS_HYBRID_MIGRATION_PLAN.md`. Pour les deux premiers, le
hunk doit être **découpé** (`s` puis `e` dans `git add -p`) : les ajouts
Phase 5 sont en fin de fichier, ce qui rend le découpage mécanique mais non
automatique.

**À exclure — sans rapport :** `apps/mobile/**`, `services/api/src/import/**`,
`ARCHITECTURE.md`, `CLAUDE.md`, `docs/import-*`, `ROADMAP.md`.

**À exclure — générés ou binaires :** `packages/homespotify_just_audio/android/.cxx/**`
(objets `.o`, `.a`, `.ninja_*`, `CMakeCache.txt`), `.pnpm-store/**`,
`storage/**`, `backups/**`.

Séquence proposée, en trois commits pour que la Phase 5 reste relisible :

1. `scripts/` Phase 5 (16 fichiers) ;
2. `docs/VPS_PHASE5_*`, `docs/VPS_PHASE6_*` + le hunk d'une ligne du plan de
   migration ;
3. hunks Phase 5 de `TECH_DECISIONS.md` et `LESSONS.md`, via `git add -p`.

### A.4 Contrôle des données sensibles

Scan du périmètre Phase 5 (15 fichiers) :

| Motif | Occurrences |
| --- | ---: |
| `BEGIN OPENSSH PRIVATE KEY`, `BEGIN RSA PRIVATE KEY`, `ssh-ed25519 AAAA` | 0 |
| JWT (`eyJhbGciOi`) | 0 |
| `SHARED_SECRET=<valeur>`, `AUTH_TOKEN_SECRET=<valeur>` | 0 |
| `Bearer <valeur>` | 3, **tous bénins** |

Les trois `Bearer` sont : deux fixtures de test (`"Bearer x"`, `"Bearer y"`)
servant de **contrôles négatifs** — elles vérifient que ces champs ne sont
jamais publiés — et une ligne de prose dans la doc Phase 5. Aucun `.env`,
`.db`, `.sqlite`, `.log`, `.key`, `.pem`, fichier audio, `node_modules`, cache
ou diagnostic runtime n'appartient au périmètre.

---

## B. Runtime Node et dépendances natives (mesuré)

### B.1 Système

| Élément | Valeur mesurée |
| --- | --- |
| Distribution | Debian GNU/Linux 12 (bookworm) |
| Architecture | `x86_64` / `x64` |
| glibc | 2.36 (`2.36-9+deb12u14`) |
| Node | **v22.18.0**, `/usr/local/bin/node` |
| NODE_MODULE_VERSION (ABI) | **127** |
| V8 | 12.4.254.21-node.27 |
| npm | 10.9.3 |
| pnpm | **absent** |
| Utilisateur courant | `debian` (uid 1000, gid 1000) |
| RAM | 3 831 Mio total, 3 411 Mio disponibles |
| Disque `/` (`/dev/sda1`) | 40 Gio total, 2,0 Gio utilisés, **36 Gio libres** (6 %) |

### B.2 Chaîne de compilation — constatation décisive

| Outil | État |
| --- | --- |
| `python3` | présent |
| `make` | **absent** |
| `gcc` | **absent** |
| `node-gyp` | **absent** |

**Aucun module natif ne peut être compilé sur le VPS.** Ce n'est pas un
blocage — le binaire nécessaire existe déjà et fonctionne (§B.6) — mais cela
transforme une commodité en **contrainte dure** : l'artefact de déploiement
doit embarquer `node_modules` avec ses `.node` prébuilts, et toute montée de
version de Node qui change l'ABI casserait l'API sans recours local.

### B.3 Arbre Linux existant

`/home/debian/homespotify-phase45` : **125 Mio** au total, `node_modules`
inclus. Construit lors de la Phase 4.5, déjà qualifié par les Phases 4.5 et 5,
et c'est **cet arbre** qui sert de base à l'artefact — il n'a jamais été
reconstruit sur le VPS, faute de compilateur.

### B.4 Modules natifs présents

| Fichier | Taille | Origine |
| --- | ---: | --- |
| `better-sqlite3/build/Release/better_sqlite3.node` | 2 118 144 | prébuilt `prebuild-install` |
| `@node-rs/argon2-linux-x64-gnu/argon2.linux-x64-gnu.node` | 631 032 | paquet plateforme, aucun script d'installation |

### B.5 Paquets à script d'installation

| Paquet | Version | Scripts |
| --- | --- | --- |
| `better-sqlite3` | 12.11.1 | `install: prebuild-install \|\| node-gyp rebuild --release`, `build-release` |
| `@node-rs/argon2` | 2.0.2 | aucun |

`better-sqlite3` 12.11.1 satisfait la contrainte `^12.2.0` du `package.json`.
Son script `install` tomberait sur `node-gyp` si le prébuilt manquait — donc
sur un échec, puisque `node-gyp` est absent. Raison de plus pour ne jamais
lancer `npm install` sur le VPS.

### B.6 Smoke test `better-sqlite3` — exécuté, vert

Exécuté sur le VPS via `stdin`, sans écrire de script sur disque, dans un
`mkdtemp` supprimé en `finally`. Aucune base HomeSpotify touchée.

```json
{ "node": "v22.18.0", "abi": "127", "arch": "x64", "moduleLoaded": true,
  "version": "12.11.1", "sqliteVersion": "3.53.2", "journalMode": "wal",
  "selected": "gate0", "integrity": "ok", "foreignKeys": 1,
  "ok": true, "tempRemoved": true }
```

Couverture : `require`, ouverture, `PRAGMA journal_mode = WAL`, `CREATE TABLE`,
`INSERT`, `SELECT`, `integrity_check`, `close`, suppression. Le module se
charge et fonctionne réellement sous Node 22.18.0 / ABI 127. Noter que
`foreign_keys` vaut **1 par défaut** avec ce module, en plus du `PRAGMA
foreign_keys = ON` explicite de `db/client.ts`.

### B.7 Stratégie d'artefact reproductible

L'artefact est le couple `dist` + `node_modules` **qualifié ensemble**. La
réutilisation d'un `node_modules` ne suffit pas : elle n'est légitime que si
quatre conditions sont vérifiées **avant** chaque promotion.

| Condition | Valeur de référence | Contrôle |
| --- | --- | --- |
| Version Node | `v22.18.0` | `node -v` sur le VPS |
| ABI | `127` | `node -p process.versions.modules` |
| Architecture | `x64` / `x86_64` | `node -p process.arch` |
| Empreinte des `.node` | SHA-256 des deux fichiers de §B.4 | manifeste transporté avec l'artefact |

Procédure : build local → `dist` transféré en staging → manifeste SHA-256 →
smoke test §B.6 exécuté **depuis le répertoire de release, hors service** →
`rename` atomique → bascule du symlink. Si une seule condition diverge, la
promotion est refusée : c'est un NO-GO d'artefact, pas un avertissement.

---

## C. Inventaire SQLite

### C.1 Configuration et comportement au démarrage

| Élément | Valeur |
| --- | --- |
| Chemin | `DB_PATH`, défaut `./data/homespotify.db` ; vide → erreur explicite |
| `journal_mode` | `WAL` (`db/client.ts:19`) |
| `foreign_keys` | `ON` (`db/client.ts:20`) |
| Migrations | `runMigrations()` au démarrage ; échec → **arrêt** de l'API |
| Registre de version | table `__drizzle_migrations`, **pas** `user_version` |

`user_version` vaut `0` : tout contrôle de version de schéma doit porter sur
`__drizzle_migrations` (18 lignes sur la copie auditée), sans quoi il ne
vérifierait rien.

### C.2 Copie SQLite auditée (Phase 4.5, sur le VPS, lecture seule)

| Mesure | Valeur |
| --- | --- |
| Taille | 3 387 392 octets (827 pages × 4 096) |
| `journal_mode` | `wal` |
| `integrity_check` | `ok` |
| `foreign_key_check` | 0 violation |
| Tables | 30 (2 vides) |
| `__drizzle_migrations` | 18 |

Volumes principaux : `listening_events` 7 452, `listening_sessions` 462,
`audit_logs` 304, `recommendation_impressions` 302,
`recommendation_candidates` 258, `import_jobs` 186, `user_tracks` 160,
`tracks` 159, `track_quality` 158, `user_recommendation_queue` 116,
`sessions` 44, `users` 3.

La base est **petite** (3,4 Mio) : la copie et le contrôle d'intégrité coûtent
quelques secondes, ce qui rend la fenêtre de bascule courte et le rollback
trivial.

### C.3 Writers — inventaire complet

**Au démarrage, inconditionnels** (`app.ts`) — ce sont eux qui tranchent la
stratégie :

| Writer | Effet |
| --- | --- |
| `runMigrations()` | applique les migrations Drizzle |
| `invalidateLegacyArtifacts()` | invalide des artefacts obsolètes |
| `repairOwnerBackfillLeak()` | révoque des pistes mal attribuées |
| `reconcileAllMusicRequests()` | réconcilie les demandes musicales |
| `mkdirSync()` × 5 | crée `musicDir`, `incomingDir`, `importRoot`, `coversDir`, `derivedCacheDir` |

**Au démarrage, conditionnels :**

| Writer | Condition | Neutralisation |
| --- | --- | --- |
| `importService.start()` (watcher) | actif sauf `NODE_ENV=test` | pointer `INCOMING_DIR` sur un répertoire vide jetable |
| `backupScheduler.start()` | `BACKUP_ENABLED` | `BACKUP_ENABLED=false` |
| services Discovery | `DISCOVERY_ENABLED` | `DISCOVERY_ENABLED=false` + fournisseurs à `false` |

⚠️ Le watcher d'import n'est désactivable que par `NODE_ENV=test` ou une option
de `buildApp`. Or `NODE_ENV=test` **désactive entièrement le logger** (L-108) :
on perdrait toute preuve. Le shadow tournera donc en `NODE_ENV=production`
avec un `INCOMING_DIR` vide et jetable — pas en mode test.

**Par requête** — routes mutantes : `auth`, `favorites`, `playlists`,
`playback-settings`, `play-events`, `sync`, `discovery`, `admin`.

**Services** : `user-library-service`, `import-service`, `user-import-service`
(+ `setInterval` de réconciliation), `acquisition-import-service`,
`acquisition-job-repository`, `lucida-process-runner`,
`musicbrainz-enrichment`, `recommendation-service`, `recommendation-engine`,
`preview-provider`, `music-request-service`, `discovery/catalog`,
`operations/server-backup`, `db/migrate`.

`storage/cache` écrit également, mais dans **son propre** index SQLite, séparé
de la base applicative (garantie Phase 5).

### C.4 Stratégie recommandée : **option B**

| Option | Verdict |
| --- | --- |
| A — shadow totalement en lecture seule | **impossible** sans modifier le code applicatif : les écritures de démarrage (§C.3) sont inconditionnelles et l'API s'arrête si les migrations échouent. Un montage en lecture seule empêcherait le démarrage. |
| C — endpoints d'écriture bloqués par configuration | **insuffisant** : ne neutralise pas les writers de démarrage ni les jobs de fond. Donnerait une fausse impression de sûreté. |
| **B — copie SQLite jetable autorisant les écritures** | **recommandée** : aucun changement de code, comportement identique à la production, et toute écriture est sans conséquence puisque la copie est détruite en fin de phase. |

**Windows reste le writer unique de la vérité** pendant toute la Phase 6. Les
écritures du shadow sont du bruit assumé, jamais réconciliées vers la
production. Cette asymétrie est la propriété de sûreté centrale de la phase.

### C.5 Procédure de copie cohérente (à exécuter par le propriétaire)

1. côté Windows : `VACUUM INTO` vers un fichier neuf (jamais `cp` d'une base
   vivante — L-095) ;
2. taille et SHA-256 **source** ;
3. transfert ;
4. SHA-256 **destination**, comparé à l'octet près ;
5. ouverture en lecture seule (`mode=ro`) ;
6. `PRAGMA integrity_check` → `ok` ;
7. `PRAGMA foreign_key_check` → 0 ligne ;
8. comptage de `__drizzle_migrations` comparé à la source ;
9. permissions `0640`, propriétaire = utilisateur de service.

Aucune de ces étapes n'écrit dans `runtime.db` de production : `VACUUM INTO`
lit la source et écrit un **nouveau** fichier.

---

## D. Données locales hors Storage Agent

| Chemin | Variable | Producteur | Consommateur | Mode | Taille (réf. Windows) | Requis en shadow | Stratégie Phase 6 |
| --- | --- | --- | --- | --- | ---: | --- | --- |
| Bibliothèque | `MUSIC_DIR` | scan/import | streaming | lecture | 3,0 Gio | **non** | reste sur Windows, servie par le Storage Agent |
| Pochettes | `COVERS_DIR` | import, enrichissement | UI | écriture | 17 Mio | oui (partiel) | **copier** — petit, nécessaire à la parité visuelle |
| Staging import | `INCOMING_DIR` / `HOMESPOTIFY_IMPORT_ROOT` | watcher, uploads | import | écriture | 3,3 Gio | non | **laisser vide** et jetable : le watcher tourne mais ne trouve rien |
| Variantes hors ligne | `OFFLINE_CACHE_DIR` | `OfflineVariantService` | `/offline` | écriture | 15 Mio | non | **laisser vide** : régénérable, `LocalFileStorageProvider` dédié |
| Sauvegardes | `BACKUP_ROOT` | `ServerBackupScheduler` | restauration | écriture | ≈ 23 Mio | non | **désactiver** (`BACKUP_ENABLED=false`) |
| Cache audio | `AUDIO_CACHE_ROOT` | Phase 5 | streaming | écriture | — | oui | **créer vide**, dimensionné §E |
| Journaux | journald | API | exploitation | écriture | — | oui | journald + rétention §F |

Points de non-parité assumés, à énoncer plutôt qu'à découvrir pendant les
tests :

- **imports et acquisitions non testables** en shadow (staging vide, Lucida
  hors périmètre) — la parité d'import sera qualifiée après la bascule ;
- **variantes hors ligne absentes** au départ : les premiers appels `/offline`
  déclencheront une génération, ou échoueront proprement ;
- `offlineVariantStorage` reste **toujours local** par décision Phase 4 : il ne
  passe jamais par le Storage Agent, et cette phase ne le change pas.

Aucune extension du Storage Agent n'est proposée ici : ce serait une décision
séparée, avec son propre lot de preuves.

---

## E. Dimensionnement du cache

Base de calcul : 40 Gio de disque, **36 Gio libres** mesurés ; bibliothèque de
**157 pistes / 2,93 Gio** (Phase 0), soit **≈ 19,1 Mio par piste**.

Réserve hors cache :

| Poste | Réserve |
| --- | ---: |
| Système Debian + croissance | 4,0 Gio |
| 3 releases API (125 Mio l'unité, mesuré) | 0,5 Gio |
| SQLite + sauvegardes | 0,5 Gio |
| Journaux (rotation) | 1,0 Gio |
| Pochettes | 0,3 Gio |
| Staging import plafonné | 2,0 Gio |
| **Total** | **8,3 Gio** |

Soit **≈ 27,7 Gio** théoriquement allouables au cache.

| Profil | `AUDIO_CACHE_MAX_BYTES` | `AUDIO_CACHE_MIN_FREE_BYTES` | Pistes ≈ | Couverture bibliothèque |
| --- | ---: | ---: | ---: | --- |
| Minimal prudent | 6 Gio | 8 Gio | 320 | 2,0× |
| **Équilibré (recommandé)** | **12 Gio** | **6 Gio** | **640** | **4,1×** |
| Cache large | 20 Gio | 4 Gio | 1 070 | 6,8× |

- **Seuil d'alerte** : 80 % de `AUDIO_CACHE_MAX_BYTES`, et espace libre
  descendant sous `MIN_FREE + 2 Gio`.
- **Réserve système minimale** : `MIN_FREE_BYTES` est un plancher dur ; le
  provider Phase 5 arrête de remplir et continue à servir en distant.
- **Politique LRU** : `AUDIO_CACHE_EVICTION_TARGET_RATIO = 0,90`, inchangée
  depuis la Phase 5.

Recommandation : **équilibré**. La bibliothèque entière tient dans le cache
avec un facteur 4 de croissance, tout en laissant 6 Gio de plancher — le cache
n'a alors quasiment jamais à évincer, ce qui rend le comportement en production
proche du cas nominal validé en Phase 5. Le profil « large » n'apporte rien
tant que la bibliothèque reste sous ~420 pistes.

Aucune valeur réelle n'a été modifiée.

---

## F. Design systemd (conception seule, aucun fichier créé)

### F.1 Arborescence et permissions

| Chemin | Propriétaire | Mode | Contenu |
| --- | --- | --- | --- |
| `/opt/homespotify-api/releases/<id>/` | `root:homespotify` | `0755` | `dist` + `node_modules` |
| `/opt/homespotify-api/current` → release | `root` | symlink | release active |
| `/opt/homespotify-api/previous` → release | `root` | symlink | rollback |
| `/var/lib/homespotify/data/` | `homespotify` | `0750` | SQLite shadow |
| `/var/lib/homespotify/cache/` | `homespotify` | `0750` | `AUDIO_CACHE_ROOT` |
| `/var/lib/homespotify/{imports,covers}/` | `homespotify` | `0750` | staging, pochettes |
| `/etc/homespotify/api.env` | `homespotify` | **`0600`** | secrets |

Utilisateur système `homespotify`, groupe dédié, `/usr/sbin/nologin`, sans
`sudo`. Les releases appartiennent à `root` : le service **lit** son propre
code sans pouvoir le réécrire.

### F.2 Unité

`Type=simple`, `WorkingDirectory=/opt/homespotify-api/current`,
`ExecStart=/usr/local/bin/node dist/server.js`,
`EnvironmentFile=/etc/homespotify/api.env`, `Restart=on-failure`,
`RestartSec=5`, `StartLimitIntervalSec=300` / `StartLimitBurst=5`,
`TimeoutStopSec=30`, `KillSignal=SIGTERM`, `LimitNOFILE=8192`, `UMask=0027`.

`TimeoutStopSec=30` et `SIGTERM` sont délibérés : le cache doit pouvoir
terminer ou abandonner proprement ses `.part` — un `SIGKILL` immédiat les
laisserait sur disque, où le nettoyage de démarrage les reprendrait (garantie
Phase 5, mais autant ne pas s'en servir à chaque redémarrage).

### F.3 Durcissement, avec les risques nommés

| Option | Valeur | Risque |
| --- | --- | --- |
| `NoNewPrivileges` | `yes` | aucun |
| `PrivateTmp` | `yes` | aucun — SQLite utilise le répertoire de la base |
| `PrivateDevices`, `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectControlGroups`, `RestrictSUIDSGID` | `yes` | aucun |
| `ProtectSystem` | `strict` | **casse tout sans `ReadWritePaths` correct** |
| `ReadWritePaths` | `/var/lib/homespotify` | omettre `cache/` ou `data/` = échec SQLite **et** cache |
| `ProtectHome` | `yes` | ⚠️ masque `/home/debian` : les arbres de harnais Phases 4.5/5 y résident. Sans effet si l'artefact vit sous `/opt`, mais **incompatible avec un service pointant vers `/home`** |
| `RestrictAddressFamilies` | `AF_INET AF_UNIX` | ⚠️ le Storage Agent est joint en IPv4 via WireGuard : `AF_INET` est **obligatoire**. Ajouter `AF_INET6` seulement si nécessaire |
| `CapabilityBoundingSet` | vide | sûr : le port 3002 est > 1024 |
| `MemoryMax` | 1,5 Gio | ⚠️ un plafond trop bas tue le processus **pendant** une écriture. WAL rend SQLite et le cache résistants au crash, mais une coupure répétée masquerait un vrai défaut : à ne poser qu'après le relevé RSS du soak |
| `TasksMax` | 256 | aucun à ce niveau |

Règle d'application : poser d'abord `ReadWritePaths` et vérifier le démarrage,
**avant** d'ajouter `MemoryMax`. Une option de durcissement qui casse SQLite
doit être identifiée isolément, jamais dans un lot.

### F.4 Journaux

`journald` avec `SystemMaxUse` borné et rétention par durée ; pas de logrotate
séparé, le service écrivant sur `stdout`/`stderr`. Les journaux applicatifs
sont déjà assainis (contrat Phase 4.5/5 : ni secret, ni `Authorization`, ni
nonce, ni signature, ni chemin musical). Un contrôle de non-régression sur ce
point figure dans la matrice de tests (T17).

---

## G. Réseau shadow

| Élément | État mesuré / imposé |
| --- | --- |
| Écoutes VPS actuelles | `*:443`, `*:80`, `0.0.0.0:22`, `0.0.0.0:5355`, `127.0.0.1:2019` (admin Caddy), `127.0.0.53:53`, `127.0.0.54:53` |
| Port 3001 | **libre** (harnais Phases 4.5/5, éphémère) |
| Port 3002 | **libre** → API shadow |
| Service `homespotify*` sur le VPS | **aucun** |
| Caddy | `active` — **non modifié, aucune modification prévue** |

L'API shadow écoute sur `127.0.0.1:3002` uniquement (`HOST=127.0.0.1`).
Conséquence : aucune règle de pare-feu à ajouter, aucun port Internet ouvert,
aucun DNS. L'accès de test se fait depuis le VPS, ou par tunnel SSH local
(`ssh -L 3002:127.0.0.1:3002`), qui n'ouvre rien côté serveur.

Le Storage Agent reste joint par WireGuard sur `10.8.0.2:3100`, à l'identique
des Phases 4.5 et 5 — aucun changement de tunnel.

Séparation des ports 3001/3002 : les harnais peuvent continuer à tourner
pendant que le shadow vit, sans collision ni arrêt de l'un pour l'autre.

---

## H. Matrice des tests shadow (à préparer, non exécutés)

Discipline héritée de la Phase 5 : **un statut HTTP ne prouve rien**. Tout HIT
exige un `CACHE_HIT` corrélé par `requestId`.

| # | Test | Précondition | Commande future | Attendu | GO / NO-GO | Cleanup |
| --- | --- | --- | --- | --- | --- | --- |
| T1 | Démarrage systemd | unité installée, `.env` 0600 | `systemctl start homespotify-api` | `active (running)` sous 10 s | NO-GO si `Restart` boucle | `systemctl stop` |
| T2 | Health localhost | T1 | `curl -s 127.0.0.1:3002/health` | 200, dépendances saines | NO-GO si 200 avec dépendance morte | — |
| T3 | Migrations | copie fraîche | journaux de démarrage | « migrations appliquées », `__drizzle_migrations` = source | NO-GO si écart de compte | — |
| T4 | Lecture SQLite | T2 | requête authentifiée bibliothèque | comptages = §C.2 | NO-GO si écart | — |
| T5 | Liste des pistes | T4 | `/api/tracks` | 159 pistes, chemins relatifs | NO-GO si chemin absolu | — |
| T6 | Streaming MISS | cache vide | GET complet | 200 + `CACHE_FILL_COMPLETED`, taille exacte | NO-GO sans promotion | — |
| T7 | Streaming HIT | T6 | GET complet | `CACHE_HIT`, aucun `REMOTE_STORAGE_REQUEST_STARTED` | NO-GO si upstream contacté | — |
| T8 | HEAD | T7 | HEAD | 200, corps vide, `Content-Length` exact | NO-GO sinon | — |
| T9 | Range | T7 | `Range: bytes=0-1023` | 206, 1 024 octets | NO-GO sinon | — |
| T10 | Cache après redémarrage API | T7 | `systemctl restart` puis HEAD | `CACHE_HIT`, index récupéré | NO-GO si reconstruction | — |
| T11 | Agent indisponible, HIT | T7, agent arrêté | GET/HEAD/Range piste cachée | 200/200/206, aucun accès distant | NO-GO sinon | redémarrer l'agent |
| T12 | Agent indisponible, MISS | idem | piste non cachée | **503**, jamais 401 | NO-GO si 401 public | redémarrer l'agent |
| T13 | Écritures (option B) | T2 | favori puis retrait | 200, écrit dans la copie | NO-GO si erreur SQLite | copie détruite en fin de phase |
| T14 | Imports isolés | `INCOMING_DIR` vide | démarrage + inspection | watcher actif, **0** job créé | NO-GO si job créé | vider le répertoire |
| T15 | Redémarrage complet du VPS | T2 | `reboot`, puis health | service relancé par systemd, health 200 | **NO-GO bloquant** si non relancé | — |
| T16 | Soak ≥ 2 h | T7 | lectures périodiques | aucune erreur, `activeStreams` → 0 | NO-GO si dérive | — |
| T17 | Surveillance | T16 | RSS, CPU, disque, `fd`, journaux | RSS stable, `fd` stables, **0 secret journalisé** | NO-GO si fuite ou secret | — |
| T18 | Cleanup et rollback | T15 | bascule `previous`, restart | ancienne release active, health 200 | **NO-GO bloquant** si rollback non prouvé | état restauré |

T15 et T18 sont bloquants par nature : un service qui ne survit pas à un reboot
n'est pas déployé, et un rollback jamais exécuté n'est pas un rollback.

---

## I. Stratégie de release et rollback

### I.1 Compatibilité de l'arborescence avec le code actuel

Vérifiée : `DB_PATH`, `MUSIC_DIR`, `INCOMING_DIR`, `HOMESPOTIFY_IMPORT_ROOT`,
`COVERS_DIR`, `OFFLINE_CACHE_DIR`, `BACKUP_ROOT` et `AUDIO_CACHE_ROOT` sont
**tous** surchargeables par variable d'environnement. Les valeurs par défaut
sont relatives (`./data/...`, `../../storage/...`) et ne conviennent pas à
`/opt` — elles seront donc **toutes** surchargées explicitement, aucune laissée
au défaut. `node_modules` doit résider **dans** le répertoire de release, la
résolution Node partant de l'emplacement de `dist/server.js`.

### I.2 Processus de promotion (futur)

1. transfert dans `releases/<id>.staging/` ;
2. vérification du manifeste SHA-256, y compris les deux `.node` (§B.7) ;
3. contrôle Node / ABI / architecture ;
4. smoke test `better-sqlite3` **hors service**, depuis la staging ;
5. `rename` atomique `staging` → `releases/<id>` ;
6. `previous` ← cible actuelle de `current` ; `current` ← `<id>` (symlink
   remplacé atomiquement) ;
7. `systemctl restart` ;
8. health ; en cas d'échec, **rollback automatique** : `current` ← `previous`,
   restart, health.

### I.3 Matrice de rollback

| Situation | Action | Perte |
| --- | --- | --- |
| Service défaillant | `systemctl stop` | aucune, production intacte |
| Artefact fautif | `current` → `previous`, restart | aucune |
| Copie SQLite corrompue | nouvelle copie depuis Windows | aucune |
| Cache suspect | suppression de `AUDIO_CACHE_ROOT`, mode `remote` | aucune, objets régénérables |
| Doute global | `systemctl disable --now`, suppression des répertoires | aucune |

Aucun rollback Phase 6 ne touche la production : c'est ce qui rend la phase
sûre.

---

## J. Verdict Gate 0

| # | Critère | État | Preuve |
| --- | --- | --- | --- |
| 1 | `better-sqlite3` compatible et testable | ✅ | §B.6, `ok: true`, ABI 127 |
| 2 | Stratégie SQLite shadow décidée | ✅ | §C.4, option B |
| 3 | Migrations comprises | ✅ | §C.1, `__drizzle_migrations`, arrêt sur échec |
| 4 | Writers identifiés | ✅ | §C.3, démarrage + routes + services |
| 5 | Répertoires locaux inventoriés | ✅ | §D, 7 chemins, stratégie par chemin |
| 6 | Espace disque suffisant | ✅ | 36 Gio libres pour 2,93 Gio de bibliothèque |
| 7 | Taille de cache proposée | ✅ | §E, 3 profils, recommandation 12 Gio |
| 8 | Design systemd compatible | ✅ | §F, risques `ProtectHome` / `MemoryMax` / `ReadWritePaths` nommés |
| 9 | Aucun besoin de Caddy | ✅ | §G, `127.0.0.1:3002` |
| 10 | Rollback défini | ✅ | §I.3, + T18 bloquant |
| 11 | Manifeste Phase 5 fiable | ✅ | §A.1, avec 3 fichiers mixtes signalés |
| 12 | Aucune donnée sensible détectée | ✅ | §A.4, 3 correspondances bénignes analysées |

**GO.** Deux contraintes gérées, non bloquantes :

- **C1 — aucun compilateur sur le VPS** (§B.2). L'artefact doit embarquer
  `node_modules` et ses prébuilts ; une montée de version de Node changeant
  l'ABI deviendrait un incident sans recours local. À traiter comme une
  décision explicite, pas comme un détail d'exploitation.
- **C2 — deux fichiers de documentation mixtes** (§A.2). `git add -p` avec
  découpage de hunk est obligatoire ; un `git add` global embarquerait du
  travail non relu.

Aucun blocker.

---

## K. Commandes propriétaire — informations hors de portée du sandbox

Ces relevés concernent la machine Windows de production, que ce poste ne doit
pas lire (secrets, configuration système). Résultats à reporter ici avant le
premier déploiement.

**K.1 — Chemins réels de production** (lecture seule, sans afficher les
secrets) :

```powershell
Get-Content 'C:\ProgramData\HomeSpotify\Api\config\api.env' | Where-Object { $_ -match '^(DB_PATH|MUSIC_DIR|COVERS_DIR|INCOMING_DIR|OFFLINE_CACHE_DIR|BACKUP_ROOT)=' }
```

**K.2 — Taille réelle de la base et de la bibliothèque** :

```powershell
Get-Item $env:HS_DB_PATH | Select-Object Length, LastWriteTime; Get-ChildItem $env:HS_MUSIC_DIR -Recurse -File | Measure-Object -Property Length -Sum
```

**K.3 — Copie cohérente pour le shadow** (crée un fichier neuf, ne modifie
jamais la source) :

```powershell
sqlite3 "$env:HS_DB_PATH" "VACUUM INTO 'F:\dev\homespotify\storage\shadow-copy.db'"; Get-FileHash 'F:\dev\homespotify\storage\shadow-copy.db' -Algorithm SHA256
```

**K.4 — Politique de mise à jour de Node sur le VPS** : confirmer que Node
reste figé en `v22.18.0` tant que l'artefact n'est pas reconstruit (contrainte
C1). À décider par le propriétaire, pas par défaut.

---

## L. Confirmations

- **Aucune implémentation** : aucun script Phase 6 écrit, aucune unité systemd
  créée, aucun service démarré, aucun fichier envoyé sur le VPS.
- **Aucune production modifiée** : Caddy `active` et intact, WireGuard et
  pare-feu inchangés, `runtime.db` de production jamais ouvert, HomeSpotifyApi
  et Storage Agent Windows non touchés. Les seules écritures de cet audit sont
  un `mkdtemp` dans `/tmp` du VPS, supprimé et vérifié supprimé.
- **Aucun commit**, aucun tag, aucun push.
- `CachedAudioStorageProvider` non modifié ; aucun test Phase 5 relancé.
