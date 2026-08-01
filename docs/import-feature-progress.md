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

## HS-IMPORT-17 — Monochrome manual fallback provider

**Date :** 2026-07-30 · **État :** implémenté hors réseau, essai visible non
lancé.

- Contrat Python `AcquisitionProvider`, résultat typé, adaptateur Lucida et
  provider `MONOCHROME_MANUAL` séparé.
- Rapprochement visible strict, surlignage CSS local et absence de clic
  Download verrouillés par tests.
- Snapshot du dossier Downloads, stabilité, ffprobe, tags et durée avant
  staging.
- État backend `WAITING_MANUAL_DOWNLOAD`, holder global SQLite, ownership
  OWNER, anti-rejeu et import exclusif par `UserImportService`.
- Flutter : instructions, vrai UUID, copie, annulation, import WAV/FLAC et
  attente sans fausse progression.
- Helper : `run_monochrome_fallback.ps1`, token masqué jamais transmis en ligne
  de commande, mode `--dry-run-monochrome`.

Le diagnostic visible `Lifestyles — Guala` reste volontairement non exécuté :
Chromium ne sera ouvert qu'après annonce explicite au propriétaire.

> **Note du 2026-07-25.** La décision manquante a été prise :
> `TD-Remote-Acquisition-Lucida` révoque `TD-Remote-Acquisition-Removed`.
> Les tâches HS-IMPORT-01 à 09 ont été réalisées sur `feature/lucida-import`
> (commits `d23906f` → `1368c39` + arbre de travail) **sans être consignées
> ici** : ce document reste incomplet entre HS-IMPORT-00R et HS-IMPORT-10.

## HS-IMPORT-10 — DONE

**Date :** 2026-07-25 · **Objectif :** couche données Flutter de l'acquisition
distante (modèles, client API, providers Riverpod). **Aucune UI.**

### Fichiers créés

- `apps/mobile/homespotify_mobile/lib/src/features/acquisition/domain/acquisition_models.dart`
- `apps/mobile/homespotify_mobile/lib/src/features/acquisition/data/acquisition_api.dart`
- `apps/mobile/homespotify_mobile/lib/src/features/acquisition/application/acquisition_search_controller.dart`
- `apps/mobile/homespotify_mobile/test/acquisition_data_test.dart`

### Fichiers modifiés

Aucun. La couche est strictement additive : ni `api_client.dart`, ni le routeur,
ni un écran existant n'ont été touchés.

### Commandes exécutées et résultats

| Commande | Résultat |
|---|---|
| `dart format lib/src/features/acquisition test/acquisition_data_test.dart` | 4 fichiers formatés |
| `flutter analyze lib/src/features/acquisition test/acquisition_data_test.dart` | No issues found |
| `flutter test test/acquisition_data_test.dart` (×2) | 41/41 PASS, identique aux deux exécutions |
| `flutter analyze` (projet) | 12 infos, **toutes préexistantes** — aucune ne cite `acquisition` |
| `flutter test` (projet) | 415/415 PASS |

### Décisions techniques

- **Nom de la feature : `acquisition`, pas `imports`.** `imports` désigne déjà
  le pipeline local (inbox, `admin_imports_screen.dart`) ; réutiliser le mot
  aurait rendu les deux indistinguables. Les *routes* restent `/api/imports/*`.
- **Modèles Dart manuels**, sans `freezed` : convention des features
  `catalog_search` et `discovery`, aucun fichier généré à maintenir.
- **Statut `unknown` local.** Un statut serveur non reconnu ne lève pas et est
  traité comme **actif** — croire à tort qu'un job est fini est le pire des deux
  échecs. Il n'est jamais renvoyé au serveur comme filtre.
- **Pas de debounce sur la recherche.** Contrairement au catalogue, chaque
  recherche lance un vrai processus Python : elle est explicite, jamais à la
  frappe.
- **Dates toutes nullables.** Une date illisible ne doit pas empêcher
  d'afficher l'état d'un job.
- **Aucun polling** : périmètre de HS-IMPORT-12.

### Problèmes rencontrés et corrigés

Le Dio partagé est configuré avec `validateStatus: status < 500`. Les réponses
**4xx** arrivent donc sans `DioException` (un 404 aurait été lu comme un succès
au corps vide), tandis que les **5xx** arrivent *en* `DioException` avec la
réponse attachée. La première version ne traitait que le premier chemin et
perdait le code et le message backend des 502/503/504 — précisément les codes
significatifs de cette fonctionnalité. Détecté par les tests, corrigé : les deux
chemins produisent désormais la même `AcquisitionException`.

### Problèmes restants

- Aucune UI : la couche n'est appelée par aucun écran (HS-IMPORT-11 à 13).
- Aucune route `go_router` déclarée — volontaire, hors périmètre.
- Testée uniquement contre un backend mocké ; jamais contre le vrai serveur.

### Prochaine tâche autorisée

**HS-IMPORT-11 — Écran Flutter de recherche et sélection.**

## HS-IMPORT-11 — DONE

**Date :** 2026-07-25 · **Objectif :** écran « Importer une musique » —
recherche, états, sélection d'un résultat. **Pas de suivi de job.**

### Fichiers créés

- `apps/mobile/homespotify_mobile/lib/src/features/acquisition/presentation/acquisition_search_screen.dart`
- `apps/mobile/homespotify_mobile/test/acquisition_search_screen_test.dart`

### Fichiers modifiés

- `.../presentation/acquisition_search_screen.dart` — correction interne (voir
  « Problèmes rencontrés »). Aucun fichier préexistant du projet n'a été touché :
  ni routeur, ni thème, ni écran existant.

### Commandes exécutées et résultats

| Commande | Résultat |
|---|---|
| `flutter analyze lib/src/features/acquisition test/acquisition_search_screen_test.dart` | No issues found |
| `flutter test test/acquisition_search_screen_test.dart` | 19/19 PASS |
| `flutter test` (ciblés 10 + 11, seconde exécution) | 60/60 PASS |
| `flutter test` (projet) | 434/434 PASS |
| `flutter analyze` (projet) | 12 infos, toutes préexistantes, aucune sur `acquisition` |

### Décisions techniques

- **Confirmation obligatoire avant création** (`AlertDialog`) : un import lance
  un vrai téléchargement côté serveur, un appui accidentel ne doit pas suffire.
- **Double garde anti-double-clic** : l'état `submitting` désactive TOUS les
  boutons « Importer » (pas seulement celui touché, puisqu'un seul job actif est
  autorisé), et `_confirmAndImport` revérifie l'état avant d'ouvrir le dialogue.
- **`onJobCreated` en callback**, pas de `context.push` : la navigation est le
  périmètre de HS-IMPORT-13 ; l'écran reste testable et non couplé au routeur.
- **503 `feature_unavailable` a son propre écran**, distinct de l'erreur : une
  fonctionnalité non configurée n'est pas une panne.
- **Durée absente = rien d'affiché**, jamais « 0:00 » qui passerait pour une
  information vérifiée.

### Problèmes rencontrés et corrigés

Un échec de création (409 doublon, 503) posait `error` dans l'état, ce qui
basculait tout le corps de l'écran en état d'erreur et **effaçait la liste des
résultats** : l'utilisateur devait relancer toute la recherche pour essayer une
autre version. Corrigé — l'erreur ne remplace le contenu que si la liste est
vide ; sinon elle passe uniquement par SnackBar et les résultats restent. Le
test le vérifie explicitement.

Deux finders de test étaient faux (`find.descendant` alors que la clé est portée
par le bouton lui-même) : corrigés côté test, pas côté code.

### Problèmes restants

- L'écran n'est atteignable par aucune route : HS-IMPORT-13.
- Aucun suivi de progression après la création : HS-IMPORT-12.
- Jamais exécuté contre le vrai backend, uniquement contre un dépôt factice.

### Prochaine tâche autorisée

**HS-IMPORT-12 — Suivi du job : polling, progression, retry et annulation.**

## HS-IMPORT-12 — DONE

**Date :** 2026-07-25 · **Objectif :** suivi d'un job après sa création —
sondage, progression, messages français, annulation, relance.

### Fichiers créés

- `.../lib/src/features/acquisition/application/acquisition_job_tracker.dart`
- `.../lib/src/features/acquisition/domain/acquisition_messages.dart`
- `.../lib/src/features/acquisition/presentation/acquisition_job_screen.dart`
- `.../test/acquisition_job_tracking_test.dart`

### Fichiers modifiés

Aucun fichier préexistant du projet. Les couches HS-IMPORT-10 et 11 sont
réutilisées sans modification.

### Commandes exécutées et résultats

| Commande | Résultat |
|---|---|
| `flutter analyze lib/src/features/acquisition test/acquisition_job_tracking_test.dart` | No issues found |
| `flutter test test/acquisition_job_tracking_test.dart` | 29/29 PASS |
| `flutter test` (3 fichiers acquisition, seconde exécution) | 89/89 PASS |
| `flutter test` (projet) | 463/463 PASS |
| `flutter analyze` (projet) | 12 infos, toutes préexistantes, aucune sur `acquisition` |

### Décisions techniques

- **Sondage à 1500 ms**, backoff ×2 plafonné à 6 s, abandon après
  **5 échecs consécutifs** (`kAcquisitionMaxConsecutiveFailures`). Sonder
  indéfiniment un serveur injoignable viderait la batterie sans rien apprendre.
- **Tracker non-`family`** : le backend n'autorise qu'un téléchargement actif à
  la fois. Un tracker unique rend impossible l'oubli d'un minuteur derrière un
  identifiant abandonné.
- **Trois barrières contre les fuites** : `_inFlight` (jamais deux requêtes en
  parallèle), `stop()` au `dispose` de l'écran, `ref.onDispose` sur le provider.
- **404 = arrêt immédiat** : un job introuvable ne reviendra pas, le backoff n'a
  pas de sens.
- **Une erreur réseau transitoire n'écrase pas l'état affiché** ; elle n'est
  montrée qu'après épuisement des tentatives, ou si aucun état n'est encore
  connu.
- **Progression indéterminée tant que `progress == 0`** : une barre à 0 %
  laisserait croire que rien ne se passe.
- **`retry()` crée un NOUVEAU job** et bascule le suivi dessus ; jamais
  automatique, jamais proposé sur un job réussi ou sans `resultIndex`.
- **Table de messages alignée sur les codes réels** (script Python, runner,
  service). Le plan mentionnait `FETCH_ERROR` et `DOWNLOAD_TIMEOUT` : ces codes
  **n'existent pas** dans le script livré ; les codes réels ont été mappés à la
  place. Priorité : table locale → message backend → texte générique. Aucun code
  brut n'est jamais affiché — un test le vérifie sur toute la table.

### Problèmes rencontrés et corrigés

`ref.read` dans `State.dispose()` lève `Bad state: Using "ref" when a widget is
about to or has been unmounted` sous Riverpod 3 — 7 tests widget en échec.
Corrigé : le notifier est capturé dans un champ à l'`initState` et réutilisé
au `dispose`. Le provider n'étant pas auto-disposé, la référence reste valide.

### Problèmes restants

- Aucune route : l'écran n'est atteignable que par instanciation directe.
- `onOpenTrack` et `onBackToLibrary` sont des callbacks non branchés — le
  raccordement au lecteur et à la bibliothèque est HS-IMPORT-13.
- Le sondage ne se met pas en pause quand l'application passe en arrière-plan
  (`AppLifecycleState`) — à traiter si la consommation le justifie.
- Jamais exécuté contre le vrai backend.

### Prochaine tâche autorisée

**HS-IMPORT-13 — Navigation go_router et rafraîchissement de la bibliothèque.**

## HS-IMPORT-13 — DONE

**Date :** 2026-07-25 · **Objectif :** brancher la fonctionnalité dans
l'application et rafraîchir la bibliothèque après succès.

### Fichiers créés

- `.../lib/src/features/acquisition/presentation/acquisition_routes.dart`
- `.../test/acquisition_navigation_test.dart`

### Fichiers modifiés (premiers fichiers préexistants touchés)

- `lib/src/app/router.dart` — 1 import + 2 `GoRoute` (`acquisition-import`,
  `acquisition-job`). Aucune route existante modifiée.
- `lib/src/features/profile/presentation/profile_screen.dart` — 1 import,
  1 `_ProfileAction` dans « Mon espace », et `super.key` ajouté au constructeur
  privé `_ProfileAction` (il n'acceptait pas de clé, nécessaire pour le test).
- `.../acquisition/application/acquisition_job_tracker.dart` — invalidation de
  `libraryProvider` à l'entrée en `COMPLETED`.

### Commandes exécutées et résultats

| Commande | Résultat |
|---|---|
| `flutter analyze` (projet) | 12 infos, toutes préexistantes ; aucune sur `acquisition`, `router` ou `profile_screen` |
| `flutter test test/acquisition_navigation_test.dart` | 11/11 PASS |
| `flutter test` (projet) | 474/474 PASS |

### Décisions techniques

- **Point d'accès unique : Profil → « Mon espace »**, pas l'AppBar
  Bibliothèque. Celle-ci porte déjà 3 boutons ; un 4ᵉ écrase le titre sur un
  écran de 320 px. Le Profil regroupe déjà les accès secondaires (« Mes
  demandes »).
- **`pushReplacement` après création du job** : revenir en arrière depuis le
  suivi ramène à la bibliothèque, jamais sur une liste de résultats déjà
  consommée — c'est ce qui produirait une boucle recherche → job → recherche.
  Un test le vérifie.
- **`go('/library')` pour « Retour à la bibliothèque »** : l'écran de suivi est
  adressable par lien direct (`/import/jobs/:jobId`) et peut n'avoir aucune pile
  derrière lui.
- **Seul `libraryProvider` est invalidé.** `albumsProvider` et `artistsProvider`
  en dérivent par `ref.watch` et se recalculent seuls ; les invalider en plus
  serait redondant. Un test le prouve plutôt que de le supposer. Aucune seconde
  source de vérité n'est créée.
- **Lecture via `libraryPlaybackControllerProvider.playQueue`**, le même chemin
  que depuis la bibliothèque : ni file parallèle, ni modification du lecteur.

### Problème rencontré et corrigé

`await ref.read(libraryProvider.future)` **ne se complète jamais** si le
provider est invalidé pendant la lecture — situation banale ici, puisque
l'import qui vient d'aboutir déclenche justement cette invalidation. Le bouton
« Écouter la piste » serait resté sans effet et sans message. Corrigé par une
attente bornée (`kImportedTrackLookupTimeout`, 10 s) qui retombe sur
« Bibliothèque indisponible ». Découvert par le test, pas en production.

### Problèmes restants

- Le sondage ne se met pas en pause en arrière-plan (`AppLifecycleState`) —
  reporté depuis HS-IMPORT-12, toujours ouvert.
- L'entrée Profil est visible même si le serveur n'a pas configuré
  l'acquisition : l'écran affiche alors son message « non activé » (503). Le
  masquage en amont demanderait une sonde de capacité au démarrage.
- Rien n'a encore tourné contre le vrai backend : le gate de HS-IMPORT-14.

### Prochaine tâche autorisée

**HS-IMPORT-14 — Audit final, tests globaux et documentation.**

## HS-IMPORT-14 — DONE (avec réserve produit)

**Date :** 2026-07-25 · **Objectif :** audit final, validations globales,
documentation. Aucune nouvelle fonctionnalité.

### Fichiers créés

- `docs/import-distant.md` — documentation d'exploitation complète.

### Fichiers modifiés

- `services/api/src/import/acquisition-import-service.test.ts` — ajout du
  scénario d'intégration exigé (échec réseau → retry → success → COMPLETED),
  qui n'était couvert par aucun test.
- `docs/import-feature-progress.md` — ce document.

### Audit de code

| Recherche | Résultat |
|---|---|
| `shell: true` | **0** (les `exec` trouvés sont `sqlite.exec` et `RegExp.exec`) |
| commande concaténée / `child_process.exec` | **0** — `spawn` + tableau d'arguments uniquement |
| `TODO` / `FIXME` / `HACK` dans le code livré | **0** |
| chemins absolus codés en dur (`F:\`, `C:\`, `/home/`, `/Users/`) | **0** hors `.env.example` (commentés) et tests |
| secrets / cookies dans le code d'acquisition | **0** |
| `print()` vers stdout en mode `--json` | **0** — les 7 `print` stdout sont dans `print_audio_info`, gardé par `if not args.json` |
| `console.log` oubliés | **0** (2 `console.error` délibérés, alignés sur `user-import-service`) |
| fichiers générés modifiés à la main | **0** |
| fichiers temporaires laissés par l'audit | **0** (bases temporaires et script d'inspection supprimés) |

### Validations exécutées

| Commande | Résultat |
|---|---|
| `python -m py_compile tools/spotify-auth-spoof/lucida_dl_final.py` | exit 0 |
| `python -m compileall -q tools/spotify-auth-spoof` | exit 0 |
| `python lucida_dl_final.py --help` | exit 0, `--json` documenté |
| `python -m pytest tools/spotify-auth-spoof/tests -q` | **7/7 PASS** |
| `pnpm --filter @homespotify/api run typecheck` | PASS |
| `pnpm --filter @homespotify/api run build` | PASS |
| `npx vitest run` (backend complet) | **378/378 PASS** (39 fichiers) |
| `npx tsx src/db/migrate-cli.ts` sur base vierge | table créée, 26 colonnes, 5 index, 7 CHECK |
| `node dist/server.js` (base temporaire) | 19 migrations appliquées, `acquisition_jobs` créée ; **bind 127.0.0.1:3000 refusé par l'environnement d'exécution (EACCES)**, pas par le code |
| `dart format --output=none --set-exit-if-changed` (fichiers touchés) | **0 changement** |
| `flutter analyze` | 12 infos, **toutes préexistantes**, aucune sur le code livré |
| `flutter test` | **474/474 PASS** |

**Total : 859 tests verts** (378 backend + 474 Flutter + 7 Python).

### Vérifications fonctionnelles

- **Transitions d'état** : 13 statuts, machine testée, transitions invalides
  rejetées ; jobs actifs → `INTERRUPTED` au redémarrage.
- **Annulation** : en file (sans lancer Python) et active (AbortSignal) ;
  idempotente ; `200` distingue « rien à annuler » de `202`.
- **Timeout** : global configurable 10–1800 s, SIGTERM puis SIGKILL.
- **Retry** : interne au script ; **désormais couvert** par le scénario complet.
- **Doublon** : index unique partiel en base + `409 active_duplicate`.
- **Rollback / autorité d'import** : `COMPLETED` délègue à `UserImportService` ;
  aucun second scanner, aucune insertion Drizzle directe.
- **Rafraîchissement Flutter** : `libraryProvider` invalidé à l'entrée en
  `COMPLETED` ; `albumsProvider`/`artistsProvider` en dérivent (prouvé par test).
- **Nettoyage** : aucun processus enfant ni minuteur survivant (3 barrières
  testées côté mobile, arrêt au shutdown côté serveur).

### Constats d'audit NON corrigés (hors périmètre, décision requise)

1. **23 fichiers `__pycache__/*.pyc` sont versionnés** dans
   `tools/spotify-auth-spoof/`. Binaires générés, à retirer du suivi Git et à
   ajouter au `.gitignore`. Antérieur à cette série de tâches.
2. **15 fichiers `HS-IMPORT-*.patch` traînent à la racine** du dépôt, non
   versionnés. Résidus de la méthode de travail, à supprimer.
3. **`tools/spotify-auth-spoof/spclient_raw.json` est versionné** : inspecté,
   il ne contient que des métadonnées publiques d'un morceau (aucun secret de
   compte), mais c'est un artefact de debug qui n'a rien à faire dans le dépôt.
4. **4 fichiers Dart préexistants ne passent pas `dart format`** (`admin_api`,
   `admin_dashboard_screen`, `auth_controller`,
   `listening_activity_tracker_test`). Non touchés : les reformater polluerait
   le diff de cette série.
5. **Aucun script `lint`** n'existe dans le dépôt (`services/api/package.json`).
   La validation « lint » exigée par le plan n'a donc pas d'équivalent réel ;
   `typecheck` + `build` en tiennent lieu.

### Réserve produit — la fonctionnalité n'est PAS qualifiée production

Toute la couverture est **mockée** : aucun `spawn` réel, aucun appel Lucida,
aucun Playwright, aucun téléchargement. `tools/smoke/lucida-acquisition-smoke.ps1`
existe mais **aucune exécution réelle de bout en bout n'est tracée**.

Conformément à `CLAUDE.md` § Séquencement, la fonctionnalité est **développée et
validée en test**, mais ne peut pas être déclarée prête pour production tant
qu'un import réel n'a pas été exécuté et consigné sur le serveur cible.

### Limites restantes

Voir `docs/import-distant.md` § 9 : fournisseur unique Qobuz, un seul
téléchargement simultané, sondage mobile non suspendu en arrière-plan, entrée
Profil visible même si le serveur n'est pas configuré.

### Prochaine tâche autorisée

**Aucune.** Implémentation terminée (HS-IMPORT-01 → 14).
Prochaine étape hors plan : exécution du smoke réel et consignation du résultat.
