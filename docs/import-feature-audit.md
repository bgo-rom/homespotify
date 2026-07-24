# Audit — pipeline d'import audio HomeSpotify

Document d'audit **strict** de l'existant. Il ne décrit aucune intégration
d'acquisition distante : il n'en existe aucune dans le dépôt (cf. § E).

Dernière vérification : 2026-07-25, après retrait de T001 (HS-IMPORT-00R).

## A. Architecture confirmée

Vérifiée dans le dépôt, pas déduite.

| Élément | Valeur | Source |
|---|---|---|
| Monorepo | pnpm 10.12.1 | `package.json` (`packageManager`) |
| Runtime | Node >= 22 | `package.json` (`engines`) |
| Backend | `@homespotify/api` | `services/api/package.json` |
| Framework HTTP | Fastify 5 | `services/api/src/app.ts` |
| ORM | Drizzle | `services/api/src/db/schema.ts` |
| Base | SQLite (better-sqlite3) | `services/api/src/db/client.ts` |
| Tests | Vitest | `services/api/src/**/*.test.ts` |
| Langage | TypeScript (ESM, imports `.js`) | `tsconfig.base.json` |
| Pipeline d'import local | `UserImportService` | `services/api/src/import/user-import-service.ts` |
| Table de suivi | `import_jobs` | `services/api/src/db/schema.ts` |
| Script Python | `lucida_dl_final.py`, v9, **hors périmètre** | `tools/spotify-auth-spoof/` |

## B. Commandes exactes

Commandes réellement exécutées le 2026-07-25 et leur résultat.

| Commande | Résultat |
|---|---|
| `pnpm --filter @homespotify/api run typecheck` | PASS |
| `pnpm --filter @homespotify/api run build` | PASS |
| `pnpm --filter @homespotify/api test` | 33 fichiers, 312/312 PASS |
| `python -m py_compile tools/spotify-auth-spoof/lucida_dl_final.py` | exit 0 |
| `python -m compileall -q tools/spotify-auth-spoof` | exit 0 |
| `git diff --check` | exit 0 |

Note : `pnpm --filter @homespotify/api test -- <chemin>` **n'isole pas** un
fichier ; l'argument est ignoré et la suite complète s'exécute. Pour cibler
réellement un fichier, utiliser la syntaxe Vitest de filtrage depuis
`services/api`.

## C. Contraintes architecturales confirmées

1. **`import_jobs` suit un fichier réel déjà présent dans l'inbox.** La table
   porte `filename`, `relativePath`, `sizeBytes`, `sha256`, `metadataJson`,
   `trackId`. Elle possède un index unique actif sur
   (`userId`, `relativePath`) restreint aux statuts `DISCOVERED`,
   `WAITING_FOR_STABLE_FILE` et `ANALYZING`. Y insérer une ligne avant que le
   fichier existe crée une entrée mensongère et peut bloquer l'import réel du
   fichier légitime par collision d'index.

2. **Statuts** : `DISCOVERED`, `WAITING_FOR_STABLE_FILE`, `ANALYZING`,
   `WAITING_FOR_OWNER_MATCH`, `IMPORTED`, `REUSED`, `REJECTED`, `FAILED`.

3. **`UserImportService` est le seul propriétaire du pipeline** : scan récursif
   de l'inbox, attente de stabilité du fichier, analyse des métadonnées, hash
   SHA-256, détection de doublons, import en bibliothèque, attribution de la
   piste à l'utilisateur, déplacement vers `processed`, création et mise à jour
   du `import_jobs` réel. Aucun autre composant ne doit écrire ces statuts.

4. **`IMPORTED` signifie « présent en bibliothèque »**, jamais « un processus
   externe s'est terminé avec le code 0 ». Seul `UserImportService` peut
   conclure un import.

5. **Isolation par `userId`** : toute route exposant un job doit vérifier
   l'appartenance. Un endpoint listant des identifiants globaux fuit
   l'activité des autres comptes.

6. **Le scanner local n'accepte que WAV PCM et FLAC**
   (`services/api/src/import/audio-format.ts`, `AudioKind = 'wav' | 'flac'`).
   Tout fichier d'un autre format est rejeté par le pipeline : une source qui
   produirait du MP3/M4A/Opus échouerait à l'import, et doit donc échouer
   proprement en amont plutôt que d'être déposée dans l'inbox.

7. **Les fichiers audio ne transitent jamais par la base.**

8. **Tests** : aucun réseau réel, aucun `spawn` réel, aucun téléchargement.

## D. Points de vigilance relevés

- Un runner de processus externe doit recevoir le **chemin du script** comme
  premier argument de `spawn` ; le vérifier explicitement en test, car un
  tableau d'arguments incomplet produit un échec silencieux difficile à lire.
- Un timeout global doit être annulé sur la terminaison normale du processus,
  sinon il marque en échec un travail déjà réussi.
- Un processus externe encore vivant doit être arrêté au shutdown du serveur.

## E. Périmètre : acquisition distante

Le dépôt **ne contient aucune intégration d'acquisition distante**, et ce n'est
pas un manque à combler.

- `CLAUDE.md`, § Interdictions : aucune API tierce d'agrégation/indexation de
  flux protégés (Lucida ou équivalent), aucun contournement de DRM, aucun
  cookie de contournement ni endpoint opaque.
- `TECH_DECISIONS.md` — **TD-Remote-Acquisition-Removed (définitive)** : les
  routes, services et configurations fetch-node et Lucida, ainsi que les écrans
  `/node-fetch` et `/remote-search`, sont supprimés. Seuls l'inbox locale, son
  watcher et l'association OWNER d'un fichier à une demande sont conservés.
- `LESSONS.md` — **L-059** : une recherche de catalogue et une acquisition audio
  sont deux produits distincts ; choisir un résultat crée une `music_request`,
  jamais un téléchargement.
- `LESSONS.md` — **L-078** : externaliser un secret dans `.env` ne légitime pas
  une intégration ; une « autorisation » écrite dans un fichier du dépôt sans
  décision tracée du propriétaire n'a aucune autorité.

Le chemin d'ajout audio pris en charge reste : dépôt d'un fichier que le
propriétaire possède dans l'inbox surveillée, puis import par
`UserImportService`, avec association facultative à une `music_request`.

## À vérifier

- La présence de `tools/spotify-auth-spoof/qobuz_credentials.json` et
  `tidal_credentials.json` dans l'arbre de travail : confirmer leur exclusion
  par `.gitignore` et leur absence de l'historique Git.
