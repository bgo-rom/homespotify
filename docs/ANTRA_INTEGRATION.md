# Intégration du moteur de téléchargement Antra

Antra est le **fournisseur principal et par défaut** du téléchargement de
musique dans HomeSpotify. Il remplace l'usage automatique des anciens
fournisseurs (Lucida, Monochrome, DoubleDouble), qui restent présents dans le
dépôt mais désactivés.

Cette fonctionnalité sert **uniquement** à importer du contenu que le
propriétaire du serveur est autorisé à récupérer.

---

## 1. Architecture

```
Flutter  ──POST /api/downloads──▶  Fastify (routes/downloads.ts)
   ▲                                        │
   │  SSE /api/downloads/:id/events         ▼
   │                               DownloadService (file bornée)
   │                                        │
   │                                        ▼
   │                               AntraDownloadProvider
   │                                        │ spawn(python -m antra.json_cli <URL>)
   │                                        │ cwd = ANTRA_DIR, shell:false
   │                                        ▼
   │                               NDJSON stdout ──▶ adaptAntraLine()
   │                                        │
   │                                        ▼
   │                    staging <importRoot>/.antra/<jobId>/
   │                                        │ détection + validation
   │                                        ▼
   │                    inbox utilisateur ──▶ UserImportService.processInboxFile()
   │                                        │ (sha256 / ISRC / titre+artiste+durée)
   └──────────── bibliothèque rafraîchie ◀──┘
```

### Fichiers

| Fichier | Rôle |
| --- | --- |
| `services/api/src/download/download-url.ts` | Allowlist stricte, validation et normalisation des URL |
| `services/api/src/download/log-sanitizer.ts` | Masquage des secrets et des chemins locaux avant stockage/diffusion |
| `services/api/src/download/download-provider.ts` | Contrat interne `DownloadProvider` / `DownloadHandle` |
| `services/api/src/download/antra-event-adapter.ts` | NDJSON Antra → événements HomeSpotify + découpage de lignes |
| `services/api/src/download/antra-download-provider.ts` | `spawn`, lecture du flux, annulation Windows, contrôle de santé |
| `services/api/src/download/download-job-repository.ts` | Persistance SQLite `download_jobs` |
| `services/api/src/download/downloaded-file-detector.ts` | Détection et validation des fichiers produits |
| `services/api/src/download/download-service.ts` | File d'exécution, orchestration, import local, diffusion SSE |
| `services/api/src/routes/downloads.ts` | API HTTP + flux SSE |
| `apps/mobile/.../features/remote_download/` | Écran Flutter, modèles, contrôleur Riverpod, client Dio/SSE |

### Deux règles structurantes

1. **`import_jobs` reste créé et finalisé uniquement par `UserImportService`.**
   `download_jobs` suit le processus Python, puis pointe vers le vrai job local.
   Aucun second indexeur n'existe.
2. **Le reste de HomeSpotify ne dépend jamais du texte humain d'Antra.** Toute
   la traduction est concentrée dans `antra-event-adapter.ts`.

---

## 2. Variables d'environnement

À placer dans `services/api/.env` (jamais commité). Voir `.env.example`.

| Variable | Défaut | Rôle |
| --- | --- | --- |
| `ANTRA_DIR` | *(vide)* | Racine du dépôt Antra. **Vide = fonctionnalité désactivée**, `/api/downloads` répond 503. |
| `ANTRA_PYTHON` | *(obligatoire si `ANTRA_DIR`)* | Interpréteur Python du venv Antra. |
| `ANTRA_OUTPUT_DIR` | racine d'import | Racine de staging (`<dir>/.antra/<jobId>` par job). |
| `ANTRA_SOURCE` | `auto` | Préférence de source Antra. |
| `ANTRA_FORMAT` | `flac` | Format demandé au moteur. |
| `ANTRA_ALLOWED_EXTENSIONS` | `.flac,.wav` | Extensions acceptées après téléchargement. |
| `ANTRA_MAX_CONCURRENT` | `2` | Téléchargements simultanés (1 à 4). |
| `ANTRA_JOB_TIMEOUT_MS` | `900000` | Délai global d'un job ; au-delà, l'arbre de processus est tué. |
| `ANTRA_SLSKD_AUTO_BOOTSTRAP` | `false` | **Doit rester `false`.** Toute autre valeur fait échouer le démarrage. |
| `ANTRA_VERBOSE` | `false` | Relaie les logs `debug` du moteur. Débogage uniquement. |
| `ACQUISITION_LEGACY_ENABLED` | `false` | Réactive l'ancienne chaîne Lucida/Monochrome. |

Valeurs de référence sur la machine actuelle :

```
ANTRA_DIR=F:\dev\homespotify\tools\antra
ANTRA_PYTHON=F:\dev\homespotify\tools\antra\.venv\Scripts\python.exe
ANTRA_OUTPUT_DIR=F:\dev\homespotify\storage\imports
ANTRA_SOURCE=auto
ANTRA_FORMAT=flac
ANTRA_MAX_CONCURRENT=2
ANTRA_JOB_TIMEOUT_MS=900000
ANTRA_SLSKD_AUTO_BOOTSTRAP=false
```

---

## 3. Environnement Python

L'environnement est déjà installé. Pour le recréer :

```bash
cd F:/dev/homespotify/tools/antra && python -m venv .venv && ./.venv/Scripts/python.exe -m pip install -r requirements-runtime.txt
```

Vérification rapide :

```bash
F:/dev/homespotify/tools/antra/.venv/Scripts/python.exe -c "import antra; print('ok')"
```

---

## 4. Clé Premium — où elle vit, où elle ne va jamais

La clé Premium est enregistrée **uniquement** dans `tools/antra/.env`, sous la
clé `ANTRA_API_KEY`. Elle y reste.

Mécanisme : `antra.core.config` appelle `load_dotenv(override=False)`. Le
processus Python est lancé avec `cwd = ANTRA_DIR`, il charge donc ce `.env`
lui-même. HomeSpotify **supprime activement** `ANTRA_API_KEY` de
l'environnement transmis (`buildAntraCommand`) : même si le serveur a hérité
d'une valeur, elle ne prend jamais le dessus et ne transite jamais par le code
HomeSpotify.

Conséquences vérifiées par des tests :

- la clé n'apparaît dans aucune réponse API — `premiumKeyConfigured` est un
  **booléen strict**, sans valeur, longueur ni préfixe ;
- `sanitizeMessage()` masque toute forme `ANTRA_API_KEY=…`, `api_key: "…"`,
  `Bearer …`, cookie, mot de passe ou JWT avant tout stockage ou diffusion ;
- la clé n'est jamais journalisée, ni dans pino, ni dans SQLite, ni en SSE ;
- `tools/antra/.env` est ignoré par `tools/antra/.gitignore` **et** par le
  `.gitignore` racine.

Pour installer ou changer la clé, éditer directement `tools/antra/.env` :

```
ANTRA_API_KEY=<votre clé>
```

Aucune commande HomeSpotify ne lit ni n'affiche cette valeur.

---

## 5. Soulseek : toujours désactivé

Deux garde-fous cumulés :

1. **Point d'entrée** : HomeSpotify lance `python -m antra.json_cli`, jamais
   `python -m antra`. La CLI humaine appelle `ensure_slskd(cfg)`, qui peut
   demander une configuration Soulseek interactive ; la JSON CLI ne l'appelle
   jamais.
2. **Environnement imposé** : `SLSKD_AUTO_BOOTSTRAP=false`, `SLSKD_BASE_URL=""`,
   `SLSKD_API_KEY=""`, `SOULSEEK_SEED_AFTER_DOWNLOAD=false`.

`ANTRA_SLSKD_AUTO_BOOTSTRAP=true` **fait échouer le démarrage du backend** avec
un message explicite : une configuration interactive est impossible côté
serveur.

---

## 6. Contrôle de santé

```bash
curl -H "Authorization: Bearer <token>" http://127.0.0.1:3000/api/downloads/health
```

Réponse :

```json
{
  "available": true,
  "configured": true,
  "pythonFound": true,
  "antraImportable": true,
  "outputWritable": true,
  "premiumKeyConfigured": true,
  "soulseekDisabled": true,
  "detail": null,
  "checkedAt": "2026-08-01T09:00:00.000Z",
  "queued": 0,
  "active": 0
}
```

Le contrôle **ne lance aucun téléchargement** : il vérifie l'existence des
chemins, l'écriture dans le dossier de sortie et exécute
`<ANTRA_PYTHON> -c "import antra; print('ok')"`. Le résultat est mis en cache
60 s, car chaque appel démarre un interpréteur.

Si le moteur est indisponible, **le backend continue de fonctionner** : seules
les routes de téléchargement le signalent.

---

## 7. Lancement du backend

```bash
cd F:/dev/homespotify && pnpm dev
```

Production :

```bash
cd F:/dev/homespotify && pnpm build && pnpm start
```

Au démarrage, les jobs restés actifs après un arrêt brutal passent en
`interrupted` et peuvent être relancés explicitement.

---

## 8. Fonctionnement de la file

- Deux téléchargements simultanés au maximum (`ANTRA_MAX_CONCURRENT`, borné
  1–4). Les autres attendent en `queued`.
- Un job n'est jamais lancé deux fois : le worker relit son état avant de
  démarrer.
- Un doublon actif de la même URL pour le même compte est refusé par un **index
  unique partiel SQLite**, pas seulement par du code.
- Un job terminal ne redevient jamais actif ; seuls `failed` et `interrupted`
  sont relançables, **sur la même ligne** (aucun doublon créé).
- Chaque job écrit dans son propre dossier `<importRoot>/.antra/<jobId>` :
  c'est ce contexte, et non « le fichier le plus récent », qui rend la
  détection non ambiguë.
- La progression est persistée au plus une fois toutes les 400 ms.

### États

`queued` → `resolving` → `downloading` → `processing` → `importing` →
`completed` | `failed` | `cancelled` | `interrupted`

---

## 8 bis. Recherche musicale et repli entre sources

Antra **ne sait pas rechercher par texte** : son contrat qualifié est
`python -m antra.json_cli <URL>`. « Guala Lifestyles » doit donc devenir une
URL avant d'atteindre le moteur.

### Providers de recherche réellement utilisés

Aucun provider externe n'a été ajouté : la résolution réutilise le catalogue de
découverte déjà branché (`DiscoveryCatalogService`).

| Catalogue | Clé requise | Apporte |
| --- | --- | --- |
| **Deezer** | aucune | titre, artiste, album, durée, ISRC, pochette, URL `deezer.com` |
| **iTunes Search** | aucune | idem + URL `music.apple.com` |
| **Spotify** | `SPOTIFY_CLIENT_ID/SECRET` (présentes) | idem + URL `open.spotify.com` |
| **MusicBrainz** | `MUSICBRAINZ_USER_AGENT` (présent) | ISRC/MBID canoniques (aucune URL téléchargeable) |

### Classement des pistes

`TrackCandidateResolver` note chaque résultat, dans cet ordre :

1. **ISRC identique** → 100 ; un ISRC connu et *différent* → 0 (disqualifié) ;
2. **titre** normalisé ;
3. **artiste** normalisé ;
4. **durée** proche (±2 s, ±5 s, ±15 s ; au-delà, pénalité) ;
5. **album** compatible ;
6. **version studio** préférée : remix / live / instrumental pénalisés quand la
   requête ne les demande pas.

Un texte libre exige des tokens **dans le titre ET dans l'artiste** : c'est ce
qui écarte les homonymes qui ne partagent qu'un mot.

En dessous du seuil de confiance, ou quand deux pistes distinctes sont trop
proches, **aucun téléchargement n'est lancé** : la liste est renvoyée à
l'application pour un choix manuel.

### Ordre des candidats (`sourceRank`)

Fondé sur `tools/antra/antra/core/service.py` : l'URL soumise détermine la
stratégie de sources d'Antra.

| URL | `source_rule` | rang | Conséquence |
| --- | --- | --- | --- |
| `open.spotify.com` | *(aucune)* | 100 | Chaîne de résolution complète |
| `qobuz.com` | `prefer_hires` | 80 | Famille préférée, repli hi-res permis |
| `music.apple.com` | `prefer_hires` | 70 | idem |
| `tidal.com` | `exclusive` | 45 | Verrouillé sur un seul adaptateur |
| `deezer.com` | `exclusive` | 40 | idem |
| `music.amazon.*` | `exclusive` | 30 | idem |

### Repli automatique

Chaque candidat obtient **son propre dossier de staging**
(`.antra/<jobId>/<n>`). Un échec **technique** enchaîne sur le suivant :
`ATTEMPT_TIMEOUT`, `ANTRA_SUMMARY_ERROR`, `ANTRA_TRACK_FAILED`,
`ENGINE_EXIT_ERROR`, `NO_TRACK_DOWNLOADED`, `NO_FILE_DETECTED`,
`EXCERPT_TOO_SHORT`, `UNREADABLE`, `FORMAT_REJECTED`.

N'enchaînent **jamais** : `CANCELLED` (annulation utilisateur), `SPAWN_FAILED`,
`TIMEOUT` (délai global), `LOCAL_IMPORT_*` (le fichier existe — réessayer
risquerait un doublon).

Une même URL n'est jamais rejouée, le délai global est respecté et
l'annulation est vérifiée entre chaque tentative.

`download_jobs` conserve : `query`, `request_kind`, `candidates_json`,
`attempts_json` (ordre, provider, URL, issue, code d'échec),
`selected_provider`, `selected_url`. **Aucun credential ni token.**

## 9. API

Toutes les routes exigent un Bearer HomeSpotify et sont **cloisonnées par
compte** : un utilisateur ne voit que ses propres téléchargements. Un job
inconnu et un job appartenant à un autre compte répondent tous deux 404.

| Méthode | Route | Réponse |
| --- | --- | --- |
| `POST` | `/api/downloads/search` | `202` job créé, `200` choix à faire ou aucun résultat |
| `POST` | `/api/downloads` | `202 {jobId, status, item}` |
| `GET` | `/api/downloads?limit=&status=` | `200 {items[]}` |
| `GET` | `/api/downloads/:id` | `200 {item}` |
| `DELETE` | `/api/downloads/:id` | `202` (annulation enregistrée) ou `200` (déjà terminal) |
| `POST` | `/api/downloads/:id/retry` | `202 {jobId, status, item}` — uniquement `failed`/`interrupted` |
| `GET` | `/api/downloads/health` | `200` (voir §6) |
| `GET` | `/api/downloads/:id/events` | Flux SSE |

Corps de recherche (`/api/downloads/search`) — `query`, ou `title` + `artist` :

```json
{ "query": "Guala Lifestyles" }
```

Réponse `202` (piste évidente) :

```json
{
  "resolution": "queued",
  "jobId": "…",
  "status": "queued",
  "item": { "…": "job public" },
  "track": {
    "key": "deezer:track:3451087021",
    "title": "Lifestyles", "artist": "Guala", "album": "Lifestyles",
    "durationSeconds": 127, "isrc": "QZTBF2599924", "confidence": 90,
    "artworkUrl": "https://…",
    "downloadUrl": "https://open.spotify.com/track/…",
    "sources": ["spotify", "itunes", "deezer"]
  }
}
```

Réponse `200` (ambiguë) : `{ "resolution": "ambiguous", "candidates": [ … ] }`
— **aucun job n'est créé**. L'application relance ensuite son choix via
`POST /api/downloads { "url": <downloadUrl du candidat> }`.

Réponse `200` (rien trouvé) : `{ "resolution": "no_match", "candidates": [] }`.

Corps de création par lien direct (`/api/downloads`) — inchangé :

```json
{ "url": "https://...", "source": "auto", "format": "flac" }
```

`source` et `format` sont acceptés pour la compatibilité du contrat mais
**seule la configuration serveur décide** : l'application ne choisit jamais ce
que le moteur exécute.

### Codes d'erreur

| HTTP | `error` | Sens |
| --- | --- | --- |
| 400 | `bad_request` | URL invalide (avec `reasonCode` et `supportedServices`) |
| 401 | `unauthorized` | Jeton absent ou invalide |
| 404 | `job_not_found` | Job inconnu **ou** appartenant à un autre compte |
| 409 | `active_duplicate` | Ce lien est déjà en cours |
| 409 | `not_retryable` | Job non relançable |
| 503 | `feature_unavailable` | `ANTRA_DIR` non configuré |

### Flux SSE

Événements : `snapshot`, `progress`, `log`, `completed`, `failed`,
`cancelled`. Un commentaire `: ping` toutes les 15 s maintient la connexion.
Le flux se ferme de lui-même sur état terminal.

Les logs bruts du moteur ne sont **pas** renvoyés tels quels : ils sont
assainis puis traduits en messages français stables.

Côté Flutter, `RemoteDownloadApi.watchDownload` tente le SSE et **bascule
automatiquement sur un sondage** si le flux est indisponible (proxy, veille) :
l'utilisateur ne perd jamais le suivi.

### Services acceptés

`open.spotify.com`, `music.apple.com`, `music.amazon.*` (liste de TLD
explicite), `music.youtube.com`, `soundcloud.com`, `tidal.com`,
`listen.tidal.com`, `qobuz.com`, `open.qobuz.com`, `deezer.com`,
`deezer.page.link`.

`youtube.com` **sans** le sous-domaine `music` n'est pas géré par Antra : il est
volontairement absent de l'allowlist.

Refusés systématiquement : `http:`, `file:`, `javascript:`, `data:`, chemins
locaux, identifiants dans l'URL, valeurs commençant par `-`, domaines hors
allowlist. **Aucune valeur utilisateur ne traverse un shell** (`shell: false`,
URL passée en argument distinct).

---

## 10. Annulation

1. Le job est marqué `cancelRequested` (transaction SQLite).
2. S'il est encore en file, il est retiré et passe `cancelled` sans jamais
   lancer de processus.
3. S'il tourne, le processus reçoit un arrêt normal puis, après un court délai,
   **l'arbre de processus Windows** est terminé : `taskkill /PID <pid> /T /F`
   (Antra lance des enfants ffmpeg/yt-dlp qui survivent à un simple `kill`).
4. Seuls les fichiers temporaires (`.part`, `.tmp`, `.enc.m4a`, `.crdownload`…)
   sont supprimés. **Un fichier audio complet n'est jamais détruit.**

L'annulation est idempotente à tous les niveaux.

---

## 11. Détection et import du fichier

Le moteur n'expose pas le chemin final dans ses événements JSON : `emit_event`
de `json_cli.py` ne recopie pas `EngineEvent.file_path`. La détection repose
donc sur un contexte strict :

1. inventaire du staging **avant** lancement ;
2. après succès, seuls les **nouveaux** fichiers sont candidats ;
3. exclusion des fichiers temporaires et des extensions non autorisées ;
4. attente de stabilité (taille + date de modification) ;
5. lecture réelle par `analyzeAudioFile` (music-metadata) : le fichier doit
   avoir une piste audio et une durée exploitable ;
6. rejet d'un extrait (~30 s) quand la durée attendue est nettement supérieure ;
7. déplacement dans l'inbox du compte, puis `UserImportService.processInboxFile`.

La déduplication est celle du pipeline existant : SHA-256, puis ISRC, puis
titre + artiste + durée (±5 s). Une piste déjà présente n'est pas dupliquée —
elle est simplement rattachée à la bibliothèque du demandeur.

`completed` exige un `trackId` réel : jamais le seul code de sortie du moteur.

---

## 12. Dépannage

| Symptôme | Cause probable | Action |
| --- | --- | --- |
| `/api/downloads` répond 503 | `ANTRA_DIR` absent | Renseigner `ANTRA_DIR` et `ANTRA_PYTHON`, redémarrer |
| `health.pythonFound = false` | Chemin du venv erroné | Vérifier `ANTRA_PYTHON` |
| `health.antraImportable = false` | Dépendances Python manquantes | Réinstaller `requirements-runtime.txt` |
| `health.premiumKeyConfigured = false` | Clé absente | Vérifier `ANTRA_API_KEY` dans `tools/antra/.env` |
| `health.outputWritable = false` | Droits du service Windows | Donner l'écriture sur `ANTRA_OUTPUT_DIR` |
| Job `failed` / `NO_FILE_DETECTED` | Le moteur n'a rien produit d'exploitable | Vérifier la disponibilité du titre ; `ANTRA_VERBOSE=true` pour diagnostiquer |
| Job `failed` / `EXCERPT_TOO_SHORT` | Extrait au lieu de la piste | Source incorrecte : réessayer, éventuellement avec un autre lien |
| Job `failed` / `LOCAL_IMPORT_REVIEW_REQUIRED` | Rapprochement local ambigu | Traiter depuis « Imports utilisateurs » (OWNER) |
| Job `failed` / `TIMEOUT` | Délai global dépassé | Augmenter `ANTRA_JOB_TIMEOUT_MS` |
| Job bloqué après un arrêt serveur | Processus disparu | Il passe `interrupted` au démarrage ; le relancer explicitement |

Le backend n'écrit jamais de secret dans les logs. Pour un diagnostic
détaillé, activer `ANTRA_VERBOSE=true` **temporairement** — jamais en
production.

---

## 13. Mise à jour d'Antra

1. Sauvegarder `tools/antra/.env` **hors du dépôt**.
2. Mettre à jour les sources d'Antra.
3. Réinstaller les dépendances :
   `./.venv/Scripts/python.exe -m pip install -r requirements-runtime.txt`
4. Vérifier le contrat NDJSON dans `antra/json_cli.py` : si les noms
   d'événements (`playlist_loaded`, `event/track_*`, `progress`,
   `playlist_summary`, `done`) changent, adapter **uniquement**
   `antra-event-adapter.ts` — aucune autre couche n'en dépend.
5. Relancer les tests : `pnpm --filter @homespotify/api test`.
6. Contrôler `/api/downloads/health`.

Le code source d'Antra n'est pas modifié par HomeSpotify.

---

## 14. Limites de licence

- La clé Premium, les quotas et les mécanismes de licence d'Antra ne sont ni
  contournés, ni mis en cache, ni partagés. HomeSpotify se contente de lancer
  le moteur avec son propre `.env`.
- La concurrence est bornée (2 par défaut, 4 maximum) : aucune rafale n'est
  émise vers les services distants.
- Aucun CAPTCHA Cloudflare n'est résolu ni contourné.
- La fonctionnalité sert uniquement à importer du contenu que le propriétaire
  est autorisé à récupérer.

---

## 15. Retour arrière

Pour désactiver Antra sans rien supprimer :

1. Commenter `ANTRA_DIR` dans `services/api/.env` et redémarrer. Les routes
   répondent 503, l'écran Flutter affiche un bandeau explicite, le reste du
   backend est intact.
2. Pour rétablir l'ancienne chaîne : `ACQUISITION_LEGACY_ENABLED=true` avec un
   `LUCIDA_SCRIPT_PATH` valide.

La table `download_jobs` et l'historique sont conservés dans les deux cas —
aucune migration destructive n'est nécessaire. Pour un retour arrière complet
du code, la migration `0021_download_jobs.sql` est purement additive : elle
peut rester en place sans effet.

---

## 16. Test manuel de référence

### Étape 0 — configuration

Ajouter dans `services/api/.env` :

```
ANTRA_DIR=F:\dev\homespotify\tools\antra
ANTRA_PYTHON=F:\dev\homespotify\tools\antra\.venv\Scripts\python.exe
ANTRA_OUTPUT_DIR=F:\dev\homespotify\storage\imports
ANTRA_SOURCE=auto
ANTRA_FORMAT=flac
ANTRA_MAX_CONCURRENT=2
ANTRA_JOB_TIMEOUT_MS=900000
ANTRA_SLSKD_AUTO_BOOTSTRAP=false
```

### Étape 1 — lancer le backend

```bash
cd F:/dev/homespotify && pnpm dev
```

Attendu dans les logs : `migrations appliquées`, aucune ligne
`moteur de téléchargement Antra non configuré`, et
`acquisition historique Lucida/Monochrome désactivée` si `LUCIDA_SCRIPT_PATH`
est encore renseigné.

### Étape 2 — vérifier le moteur avant tout téléchargement

```bash
curl -H "Authorization: Bearer <token>" http://127.0.0.1:3000/api/downloads/health
```

Attendu : `available: true`, `pythonFound: true`, `antraImportable: true`,
`outputWritable: true`, `premiumKeyConfigured: true`, `soulseekDisabled: true`.

### Étape 3 — téléchargement réel

Application → **Profil → « Télécharger un lien »**, coller :

```
https://www.qobuz.com/us-en/album/lifestyles-guala/m7mqu37d7v1ka
```

**Ne pas relancer ce téléchargement plusieurs fois sans nécessité** : le fichier
peut déjà exister ; la déduplication le rattachera sans le retélécharger, mais
la sollicitation du service distant est inutile.

### Résultat attendu, point par point

| # | Vérification | Où regarder |
| --- | --- | --- |
| 1 | Le job est créé | Réponse `202`, carte visible à l'écran |
| 2 | Progression visible et étapes lisibles | « Recherche de la piste » → « Téléchargement » → « Finalisation » → « Ajout à la bibliothèque » |
| 3 | **Aucun message Soulseek** | Logs backend et écran — aucune demande de configuration |
| 4 | Le fichier FLAC est créé | `storage/imports/<userId>_<user>/processed/` |
| 5 | Le fichier est indexé | La piste apparaît dans la bibliothèque |
| 6 | La lecture HTTP fonctionne | Bouton « Voir dans la bibliothèque » puis lecture |
| 7 | **Aucune clé exposée** | Aucune occurrence de la clé dans les logs, la base ou les réponses API |
| 8 | Aucun terminal interactif | Le téléchargement se déroule sans intervention |

### Étape 4 — vérifier l'annulation

Relancer un second lien, puis appuyer sur **Annuler** pendant le
téléchargement. Attendu : statut `Annulé`, processus Python et ses enfants
terminés (vérifiable au gestionnaire des tâches), aucun FLAC complet supprimé.
