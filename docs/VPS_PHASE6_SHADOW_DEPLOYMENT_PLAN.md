# Phase 6 — Déploiement shadow de l'API sur le VPS (PLAN)

**Date :** 2026-07-27
**État :** **PLAN UNIQUEMENT — NON COMMENCÉ, AUCUN CODE ÉCRIT**
**Dépend de :** Phase 5 en GO final (`docs/VPS_PHASE5_AUDIO_CACHE.md`)

Cette phase couvre les étapes 6 à 9 du plan de migration
(`docs/VPS_HYBRID_MIGRATION_PLAN.md` §30–33) : préparation Debian + systemd,
copie test de SQLite, backend VPS sur port non public, tests de bout en bout
**sans bascule**. L'étape 10 (bascule Caddy) n'appartient **pas** à cette
phase.

## 0. Interdiction structurante

**Aucune modification de Caddy pendant toute la Phase 6.** Tant que les
preuves ne sont pas toutes vertes, le trafic public continue d'aller vers
HomeSpotifyApi Windows. Le déploiement shadow n'est joignable que sur
`127.0.0.1` du VPS, ou via WireGuard sur une adresse non publiée. Aucun
enregistrement DNS, aucun `reverse_proxy`, aucun port ouvert dans le pare-feu.

Corollaire : la Phase 6 ne peut pas « déraper » en bascule. Si une preuve
manque, on s'arrête, on ne bascule pas quand même.

## 1. Prérequis

| Prérequis | Vérification | Bloquant |
| --- | --- | --- |
| Phase 5 GO | `docs/VPS_PHASE5_AUDIO_CACHE.md` en GO final | oui |
| Phase 4.5 GO | `RemoteWindowsStorageProvider` qualifié | oui |
| Storage Agent Windows | service `Running`, listener `10.8.0.2:3100` | oui |
| WireGuard | tunnel actif, VPS → Windows joignable | oui |
| Node sur le VPS | version ≥ 22, alignée avec `engines` | oui |
| `better-sqlite3` | binaire natif **déjà compilé** pour ce Node/glibc | oui |
| Espace disque VPS | ≥ 3× `AUDIO_CACHE_MAX_BYTES` visé, marge de sécurité | oui |
| Sauvegarde SQLite production | copie fraîche et **restaurée avec succès** au moins une fois | oui |
| Baselines vertes | API 503/503, Agent 148/148, harnais 107/107 | oui |

Le prérequis `better-sqlite3` est le vrai risque : le module natif doit
correspondre au couple Node/glibc du VPS. C'est déjà le cas dans l'arbre
Phase 4.5 réutilisé par les harnais — c'est cet artefact qui sera promu, pas
une recompilation.

## 2. Architecture cible

État pendant la Phase 6 :

```text
Téléphone → Caddy VPS → WireGuard → HomeSpotifyApi Windows (PRODUCTION, inchangée)

Harnais   → 127.0.0.1:3002 → HomeSpotifyApi VPS (SHADOW)
                              → cached(RemoteWindowsStorageProvider)
                                → Storage Agent Windows 10.8.0.2:3100
                              → SQLite : copie isolée, jamais la production
```

État visé **après** la Phase 7 (bascule, hors périmètre) : Caddy pointe vers
l'API VPS, Windows ne conserve que le Storage Agent.

Port shadow **3002** et non 3001 : 3001 reste le port des harnais Phase 4.5/5,
et deux instances ne doivent jamais se disputer un port. Le service shadow est
permanent (systemd), les harnais sont éphémères.

## 3. Stratégie SQLite et writer unique

C'est le point le plus dangereux de toute la migration : deux backends qui
écrivent dans deux bases divergentes produisent une perte de données
silencieuse.

**Règle absolue : un seul writer à tout instant.** Pendant la Phase 6, le
writer est **Windows**. L'API shadow travaille sur une **copie**, et tout ce
qu'elle y écrit est jetable par construction.

- copie obtenue par `VACUUM INTO` ou `sqlite3 .backup`, jamais par `cp` d'une
  base vivante (L-095 : ne pas comparer l'empreinte d'une base vivante) ;
- la copie shadow vit dans son propre répertoire, avec son propre WAL ;
- toute divergence constatée entre copie et production est **attendue** et
  n'est jamais réconciliée dans ce sens ;
- les écritures shadow (historique de lecture, favoris de test) sont
  considérées comme du bruit et détruites à la fin.

**Synchronisation finale (conçue en Phase 6, exécutée en Phase 7) :** fenêtre
courte pendant laquelle Windows est mis en lecture seule ou arrêté, une copie
fraîche est transférée, un contrôle d'intégrité (`PRAGMA integrity_check`,
comptages par table, `user_version`) est comparé, puis le writer devient le
VPS. Aucune fusion bidirectionnelle : c'est un **remplacement**, pas un merge.
Toute autre stratégie serait une réconciliation d'écritures concurrentes, hors
budget de risque de ce projet.

## 4. Déploiement sans `npm install` en production

Méthode déjà éprouvée par les harnais Phase 4.5 et 5, à formaliser :

1. build local sur Windows : `pnpm --filter @homespotify/api build` ;
2. transfert du seul `dist` par `scp` ;
3. réutilisation de l'arbre `node_modules` déjà présent et déjà qualifié sur
   le VPS, avec son `better-sqlite3` compilé ;
4. aucune commande réseau exécutée sur le VPS pendant un déploiement ;
5. le déploiement est un **remplacement de répertoire atomique** (`rename`),
   avec le répertoire précédent conservé pour le rollback.

Justification : `npm install` en production introduit une dépendance réseau et
une recompilation native au pire moment, et rend le rollback non déterministe.
L-101 (« un build JavaScript n'est pas un artefact de déploiement complet »)
impose de traiter `dist` + `node_modules` qualifié comme un tout.

## 5. Secrets et permissions

- utilisateur système dédié, sans shell de connexion, sans droit `sudo` ;
- `.env` en `0600`, propriété de cet utilisateur, **hors du dépôt** ;
- `AUDIO_REMOTE_SHARED_SECRET` et `AUTH_TOKEN_SECRET` fournis par fichier,
  jamais en ligne de commande ni dans l'unité systemd (`ps` les exposerait) ;
- aucun secret dans les journaux : contrat déjà tenu par les événements
  `CACHE_*` et `REMOTE_STORAGE_*` ;
- rotation possible sans redéploiement : redémarrage du service suffit ;
- répertoires `AUDIO_CACHE_ROOT`, données et journaux appartenant à
  l'utilisateur de service, en `0750` au plus permissif.

## 6. Durcissement systemd

Unité `homespotify-api.service`, `Type=simple`, `Restart=on-failure` avec
`RestartSec` et un `StartLimit` pour éviter la boucle de crash rapide.
Durcissement visé :

```text
User=<service>            NoNewPrivileges=yes
ProtectSystem=strict      ProtectHome=yes
PrivateTmp=yes            PrivateDevices=yes
ProtectKernelTunables=yes ProtectKernelModules=yes
ProtectControlGroups=yes  RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_INET AF_UNIX
ReadWritePaths=<data> <cache> <logs>
MemoryMax=<borne>         LimitNOFILE=<borne>
```

`ProtectSystem=strict` avec un `ReadWritePaths` explicite est le point clé :
l'API ne doit pouvoir écrire que dans ses trois répertoires. `MemoryMax` borne
le risque le mieux mesuré de la Phase 5 (le cache streame sans charger de
piste complète, mais une régression doit tuer le service, pas le VPS).

## 7. Health checks

- `/health` interne, non exposé, vérifiant SQLite, la racine de cache, l'index
  de cache et la joignabilité du Storage Agent ;
- distinction explicite entre « API vivante » et « dépendances saines » : un
  Storage Agent éteint ne doit pas faire redémarrer l'API en boucle ;
- sonde systemd ou timer léger, avec seuils, sans alerte sur un simple 503 de
  piste non cachée — qui est un comportement **correct** (Phase 5 §10.3).

## 8. Tests shadow

Aucune preuve par statut seul : même discipline qu'en Phase 5 (événement
corrélé par `requestId`, condition terminale, preuve comportementale).

| # | Test | Preuve attendue |
| --- | --- | --- |
| 1 | Démarrage et migrations | migrations appliquées sur la copie, `user_version` attendu |
| 2 | Authentification | connexion réelle, jeton valide, aucun secret journalisé |
| 3 | Bibliothèque | comptages par table identiques à la copie source |
| 4 | Streaming MISS puis HIT | `CACHE_FILL_COMPLETED` puis `CACHE_HIT`, TTFB et débit relevés |
| 5 | HEAD et Range | 200 / 206, `Content-Length` exact |
| 6 | Agent arrêté | HIT servis, piste non cachée 503, aucun 401 public |
| 7 | Redémarrage service | index et objets récupérés, HIT immédiat |
| 8 | Éviction sous charge | LRU réelle, aucune lecture active cassée |
| 9 | Soak ≥ 2 h | RSS stable, pas de fuite de descripteurs, `activeStreams` revenu à 0 |
| 10 | Client mobile via WireGuard | lecture réelle sur endpoint non public, sans toucher Caddy |
| 11 | Redémarrage VPS complet | service relancé par systemd, health vert |

Le test 11 est indispensable : un service qui ne survit pas à un reboot n'est
pas déployé, il est simplement lancé.

## 9. Migration finale (conçue ici, exécutée en Phase 7)

1. gel des écritures Windows (arrêt de l'API Windows) ;
2. copie SQLite fraîche par `VACUUM INTO`, transfert, `integrity_check` et
   comparaison de comptages ;
3. démarrage de l'API VPS sur les données fraîches, health vert ;
4. **puis seulement**, bascule Caddy — hors périmètre Phase 6 ;
5. observation, puis désactivation différée de l'ancien backend.

La fenêtre visée est de 5 à 15 minutes, conforme au plan de migration. Elle
n'est pas ouverte tant que les onze tests shadow ne sont pas verts.

## 10. Rollback

| Situation | Action | Perte |
| --- | --- | --- |
| Service shadow défaillant | `systemctl stop`, aucune action côté production | aucune |
| Artefact `dist` fautif | `rename` du répertoire précédent conservé, redémarrage | aucune |
| Copie SQLite corrompue | reprise d'une copie fraîche depuis Windows | aucune |
| Cache VPS suspect | suppression de `AUDIO_CACHE_ROOT`, mode `remote` | aucune, objets régénérables |
| Doute global | désinstallation de l'unité, suppression des répertoires | aucune |

Aucun rollback de la Phase 6 ne touche à la production : c'est la propriété qui
rend cette phase sûre.

## 11. Critères GO / NO-GO

**GO exige toutes les conditions suivantes :**

- onze tests shadow verts, avec preuves corrélées et non des statuts seuls ;
- survie à un redémarrage complet du VPS ;
- soak ≥ 2 h sans dérive mémoire ni descripteurs fuités ;
- stratégie SQLite de bascule écrite, **et sa restauration testée** ;
- rollback documenté **et exécuté au moins une fois** en répétition ;
- aucun secret en clair, aucun secret journalisé, `.env` en `0600` ;
- production strictement inchangée pendant toute la phase ;
- baselines vertes maintenues : API 503/503, Agent 148/148, harnais 107/107.

**NO-GO immédiat si :** un test shadow échoue sans explication prouvée, le
module natif SQLite doit être recompilé sur le VPS, la production est touchée
de quelque manière, ou une preuve repose sur un statut HTTP sans événement
corrélé.

## 12. Commandes qui seront exécutées par le propriétaire

À préparer, **à ne pas exécuter avant validation du plan** :

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File F:\dev\homespotify\scripts\run_phase6_shadow_deploy.ps1 -PrepareOnly
```

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File F:\dev\homespotify\scripts\run_phase6_shadow_deploy.ps1 -ShadowTests
```

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File F:\dev\homespotify\scripts\run_phase6_shadow_deploy.ps1 -SoakTest
```

Comme en Phase 5, les modes ciblés existent pour itérer sans rejouer la
séquence complète, et chaque mode nettoie derrière lui.

## 13. Points à vérifier avant de commencer

- version exacte de Node sur le VPS et compatibilité du `better-sqlite3`
  déjà présent ;
- taille réelle de la bibliothèque et dimensionnement de
  `AUDIO_CACHE_MAX_BYTES` en production (la Phase 5 n'a dimensionné que pour
  des scénarios de test) ;
- politique de rétention des journaux sur le VPS ;
- où placera-t-on `COVERS_DIR`, `INCOMING_DIR` et les variantes hors ligne, qui
  restent locaux à l'API et **ne passent pas** par le Storage Agent.
