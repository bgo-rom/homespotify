# Suivi — travaux sur le pipeline d'import

## T001 — INVALIDATED AND REVERTED

**Date d'annulation :** 2026-07-25 · **Annulé par :** HS-IMPORT-00R

Une implémentation d'import distant (`LucidaImportService`, routes
`/api/lucida/import`, configuration `LUCIDA_*`) avait été créée hors séquence.
Elle est retirée pour deux motifs distincts, chacun suffisant.

**1. Périmètre.** Elle réintroduisait une acquisition distante supprimée par
`TECH_DECISIONS.md` — **TD-Remote-Acquisition-Removed (définitive)** — et
interdite par `CLAUDE.md` § Interdictions. Voir `import-feature-audit.md` § E.

**2. Architecture invalide.** Indépendamment du périmètre, le code ne pouvait
pas fonctionner :

- `spawn()` ne recevait pas le chemin du script Python comme premier argument :
  la commande lancée était `python "<query>" --output <inbox>` ;
- une ligne `import_jobs` était créée avec un `filename` et un `relativePath`
  inventés, avant l'existence de tout fichier, en violation de l'invariant de
  la table et au risque de bloquer l'index unique actif ;
- le job passait à `IMPORTED` dès la fin du processus Python, sans que la piste
  soit en bibliothèque — `UserImportService` n'était jamais consulté ;
- le timeout global n'était jamais annulé à la terminaison normale ;
- aucun protocole d'échange structuré n'existait côté Python ; `stdout` était
  accumulé puis jamais analysé ;
- les routes ne vérifiaient pas l'appartenance du job à l'utilisateur, et
  `/active` exposait les identifiants de tous les comptes ;
- `service`, index, timeouts et retries n'étaient pas bornés ;
- les tests mockés ne détectaient pas l'absence du `scriptPath` dans les
  arguments de `spawn` ;
- les processus n'étaient pas arrêtés au shutdown du serveur ;
- la validation de query rejetait des titres légitimes.

**Aucun endpoint d'import distant n'est actif après récupération.**

## HS-IMPORT-00R — DONE

**Date :** 2026-07-25 · **Objectif :** retirer T001, préserver le reste, valider
la baseline.

### Fichiers supprimés

- `services/api/src/import/lucida-import-service.ts`
- `services/api/src/import/lucida-import-service.test.ts`
- `services/api/src/routes/lucida-imports.ts`

### Fichiers modifiés

- `services/api/src/config.ts` — retrait de `lucida?: LucidaConfig`, de
  l'interface `LucidaConfig`, de l'appel `loadLucidaConfig(env)`, du spread
  conditionnel et de la fonction `loadLucidaConfig()`. Le fichier est revenu
  **à l'identique de HEAD** (il n'apparaît plus dans `git status`), ce qui
  prouve que la totalité de ses modifications appartenait à T001.
- `services/api/src/app.ts` — retrait des deux imports Lucida, de la création
  conditionnelle de `lucidaService` et du bloc d'enregistrement des routes. Les
  ajouts `loudness-analysis` présents dans le même diff sont **conservés
  intacts**.
- `docs/import-feature-audit.md` — réécrit en audit strict de l'existant.
- `docs/import-feature-progress.md` — ce document.

### Fichiers confirmés non modifiés

- `services/api/src/db/schema.ts` — modifié dans l'arbre de travail, mais par
  les travaux `loudness-analysis` (migration `0018_track_loudness_analysis.sql`)
  antérieurs et sans rapport ; vérifié : aucune occurrence de « lucida ».
- `services/api/src/db/migrate.ts` — idem.
- `services/api/src/import/user-import-service.ts` — absent de `git status`.
- `services/api/src/routes/imports.ts` — absent de `git status`.
- `tools/spotify-auth-spoof/lucida_dl_final.py` — non touché ; toujours en v9,
  toujours sans mode `--json`.

Aucune table n'a été créée, aucune migration Drizzle n'a été modifiée.

### Commandes exécutées et résultats

| Commande | Résultat |
|---|---|
| `rg` sur les 10 symboles T001 dans `services/api/src` | 0 occurrence |
| `rg -i "lucida"` dans `services/api/src` | 0 occurrence |
| `git diff --check` | exit 0 |
| `pnpm --filter @homespotify/api run typecheck` | PASS |
| `pnpm --filter @homespotify/api run build` | PASS |
| `pnpm --filter @homespotify/api test` | 33 fichiers, 312/312 PASS |
| `python -m py_compile tools/spotify-auth-spoof/lucida_dl_final.py` | exit 0 |
| `python -m compileall -q tools/spotify-auth-spoof` | exit 0 |
| `python lucida_dl_final.py --help` | exit 0, usage affiché |

La baseline mémorisée était 306 tests backend ; elle est à 312. L'écart vient
des tests `loudness-analysis` ajoutés avant cette tâche, sans rapport avec T001.

### Problèmes restants

- Le retrait de T001 n'a introduit aucune erreur : typecheck, build et suite
  complète passent.
- L'arbre de travail contient d'autres travaux en cours non liés (Phase 1B hors
  ligne, `loudness-analysis`, `FLACidal-main/`) : ils n'ont pas été touchés.
- `tools/spotify-auth-spoof/qobuz_credentials.json` et `tidal_credentials.json`
  sont présents dans l'arbre de travail — vérifier leur exclusion de Git.

### Prochaine tâche autorisée

**HS-IMPORT-00A — audit final de baseline uniquement.** Non commencée.

Les tâches d'acquisition distante envisagées (protocole NDJSON Python, table
d'acquisition distante, runner Python) ne sont pas planifiées ici : elles
relèvent du périmètre écarté en § E de `import-feature-audit.md` et
nécessiteraient une décision tracée du propriétaire modifiant
`TECH_DECISIONS.md`.
