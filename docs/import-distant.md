# Import distant (acquisition Lucida)

Documentation de la fonctionnalité d'acquisition distante livrée par
HS-IMPORT-01 → 15. Décisions de référence :
**`TD-Remote-Acquisition-Lucida`**, **`TD-HS-IMPORT-15-Provider-Circuit`**
et **`TD-HS-IMPORT-16-Interactive-Verification`**
dans `TECH_DECISIONS.md`.

> La fonctionnalité sert uniquement à importer du contenu que le propriétaire
> est autorisé à récupérer. Elle est **désactivée par défaut** : sans
> `LUCIDA_SCRIPT_PATH`, aucune route n'est active et l'app affiche « import
> distant non activé ».

## 1. Prérequis

| Composant | Exigence | Vérification |
|---|---|---|
| Python | 3.10+ (validé en 3.10) | `python --version` |
| Playwright | paquet + Chromium installé | `python -m playwright install chromium` |
| ffprobe | dans le `PATH`, ou `FFPROBE_PATH` | `ffprobe -version` |
| Node.js | 22+ (backend) | `node --version` |

Le script refuse de démarrer sans Playwright et sort en code 5 avec un
événement `INTERNAL_ERROR` explicite.

## 2. Configuration

Variables lues par `loadDotEnv()` au démarrage du backend
(`services/api/.env`, modèle dans `.env.example`) :

| Variable | Rôle | Défaut |
|---|---|---|
| `LUCIDA_SCRIPT_PATH` | Chemin du script Python. **Vide ou absent ⇒ fonctionnalité entièrement désactivée.** | — |
| `LUCIDA_PYTHON_PATH` | Interpréteur Python | `python` (PATH) |
| `LUCIDA_PROCESS_TIMEOUT_SECONDS` | Timeout global d'un processus, entier 10–1800 | 300 |
| `LUCIDA_MAX_CONCURRENT_DOWNLOADS` | Téléchargements simultanés, entier 1–4 | 3 |
| `LUCIDA_CHALLENGE_COOLDOWN_SECONDS` | Pause initiale après challenge | 1800 |
| `LUCIDA_RATE_LIMIT_DEFAULT_COOLDOWN_SECONDS` | Pause 429 sans Retry-After valide | 900 |
| `LUCIDA_UNAVAILABLE_COOLDOWN_SECONDS` | Pause après seuil de pannes 5xx | 600 |
| `LUCIDA_MAX_COOLDOWN_SECONDS` | Borne de réouverture exponentielle | 21600 |
| `LUCIDA_PROVIDER_FAILURE_WINDOW_SECONDS` | Fenêtre de comptage des pannes | 600 |
| `LUCIDA_PROVIDER_FAILURE_THRESHOLD` | Pannes 5xx avant ouverture | 2 |
| `PLAYWRIGHT_BROWSERS_PATH` | Cache Chromium partagé | — |
| `HOMESPOTIFY_IMPORT_ROOT` | Racine des imports par compte | `../../storage/imports` |

**Sous service Windows, utiliser des chemins absolus** : le compte du service
et son `PATH` diffèrent de la session interactive. Le cache Chromium doit être
lisible par ce compte.

Le backend refuse de démarrer si `LUCIDA_SCRIPT_PATH` pointe vers un fichier
inexistant ou sans extension `.py` : une configuration fausse échoue au boot,
pas au premier import.

## 3. Chemins de stockage

```
storage/imports/<userId>_<username>/
├── inbox/       ← le script Python écrit ici, le watcher prend le relais
├── processed/
└── rejected/
storage/playwright-browsers/   ← cache Chromium (jamais versionné)
```

Le dossier de sortie est **imposé par le serveur** et confiné à la racine
d'import du compte. Aucune donnée utilisateur ne sert de chemin.

## 4. Endpoints

Toutes les routes exigent une authentification et sont filtrées par `userId`.

| Méthode | Route | Réponse | Codes |
|---|---|---|---|
| POST | `/api/imports/search` | `{results:[{index,title,artist,album,duration}]}` | 200, 400, 502, 504, 503 |
| POST | `/api/imports/jobs` | `202 {accepted,item}` | 202, 400, 409, 503 |
| GET | `/api/imports/jobs?limit&status` | `{items:[…]}` | 200, 400, 503 |
| GET | `/api/imports/provider-status` | état public du circuit | 200, 401, 503 |
| GET | `/api/imports/jobs/:id` | `{item}` | 200, 400, 404, 503 |
| POST | `/api/imports/jobs/:id/retry` | reprise manuelle du même job | 202, 409, 404 |
| DELETE | `/api/imports/jobs/:id` | `{accepted,jobId,status}` | 202 (annulé), 200 (rien à annuler), 404 |

Corps de création : `query` (≤ 200 car.), `resultIndex` (0–100), `service`
(`Qobuz` seul autorisé), `downloadTimeoutSeconds` (10–300, défaut 75),
`downloadRetries` (0–9, défaut 2).

**Jamais exposés** : chemin de fichier, commande Python, `stderr` brut, trace de
pile, clé de déduplication, identifiant d'un autre compte.

`503 feature_unavailable` signifie « non configuré sur ce serveur », pas
« en panne » : le client l'affiche distinctement.

## 5. États d'un job

```
QUEUED → SEARCHING → SELECTING → OPENING_RESULT → VERIFYING
       → DOWNLOADING ⇄ RETRYING → DOWNLOADED → IMPORTING → COMPLETED
       ↘ PAUSED_PROVIDER --reprise manuelle--> QUEUED
       ↘ MANUAL_VERIFICATION_REQUIRED --helper--> VERIFYING
```

États terminaux : `COMPLETED`, `FAILED`, `CANCELLED`, `INTERRUPTED`.
Tout job actif au démarrage du serveur repasse `INTERRUPTED`.
`PAUSED_PROVIDER` est persistant, annulable et n'est pas marqué
`INTERRUPTED` au redémarrage.
`MANUAL_VERIFICATION_REQUIRED` est également persistant et annulable. Il ne
porte aucun `retryAt` et ne déclenche jamais un navigateur headless.

## 6. Circuit breaker du fournisseur

Le circuit global Lucida est persisté dans SQLite (`provider_health`) :

- `CLOSED` : les jobs suivent la file FIFO normale ;
- `OPEN` : aucun nouveau processus Lucida n'est lancé. Les nouvelles demandes
  restent visibles en `PAUSED_PROVIDER`, ainsi que les jobs encore `QUEUED` ;
- `HALF_OPEN` : état atteint uniquement par une relance manuelle après
  `retryAt`. Un seul job global est réservé comme probe ; les autres restent
  suspendus ;
- `MANUAL_VERIFICATION_REQUIRED` : si
  `LUCIDA_INTERACTIVE_VERIFICATION_ENABLED=true`, un challenge réserve un job
  pour le helper humain, sans cooldown fictif. Tous les autres démarrages
  Lucida restent bloqués.

Politique exacte :

- `PROVIDER_CHALLENGE` ouvre dès le premier diagnostic pour 30 minutes ;
- `PROVIDER_RATE_LIMITED` ouvre selon `Retry-After` (60–86400 s), ou 15 minutes
  par défaut ;
- `PROVIDER_UNAVAILABLE` ouvre après 2 erreurs dans une fenêtre de 10 minutes,
  pour 10 minutes ;
- un nouvel échec après une probe double le délai précédent, avec jitter
  borné, sans dépasser 6 heures ;
- le succès réel de la probe jusqu'à `DOWNLOADED` ferme le circuit et remet le
  compteur à zéro ;
- une annulation libère la probe sans déclarer Lucida sain.

L'expiration de `retryAt` ne lance rien et ne ferme rien. Elle autorise
seulement le bouton **Réessayer**. Il n'existe ni timer backend de reprise, ni
boucle de retry de processus pour ces diagnostics.

Le script distingue les diagnostics publics suivants à l'ouverture initiale :

- `PROVIDER_CHALLENGE` : indicateur Cloudflare explicite ;
- `PROVIDER_RATE_LIMITED` : HTTP 429 ;
- `PROVIDER_UNAVAILABLE` : HTTP 500/502/503/504 ;
- `PROVIDER_HTTP_ERROR` : autre erreur HTTP sûre.

**HomeSpotify ne contourne pas les protections anti-bot. Lorsqu’un fournisseur
demande une vérification de sécurité, les acquisitions sont suspendues.**

### Vérification humaine interactive

Le mode Python `--interactive-verification` est désactivé par défaut et exige
`--visible`. Face à un challenge, le script garde Chromium ouvert, informe
l'utilisateur sur `stderr`, puis observe passivement la page pendant 30 à
600 secondes (120 par défaut). Il ne clique, ne remplit et ne recharge rien
pendant cette attente. La reprise exige deux observations consécutives,
espacées d'au moins une seconde, du formulaire Lucida visible et actif sur le
domaine attendu, sans marqueur de challenge.

Le service Windows n'emploie jamais `--visible` ni
`--interactive-verification`. Le helper doit être lancé dans la session du
compte Windows connecté :

```powershell
cd F:\dev\homespotify
.\tools\spotify-auth-spoof\run_interactive_verification.ps1 -JobId JOB_ID
```

Le helper demande un jeton API masqué — jamais un mot de passe — récupère un
contexte public borné, lance Chromium visible et transmet uniquement le
résultat métier (`verification_completed`, `cancelled`, `timeout` ou
`provider_error`). Il ne transmet ni cookie, ni HTML, ni profil Chromium, ni
en-tête fournisseur. Après un succès Python, le fichier WAV/FLAC passe par
`UserImportService`, sa déduplication et `import_jobs`. Le circuit ne revient à
`CLOSED` qu'après le succès réel de ce pipeline local.

**`COMPLETED` signifie que la piste est réellement en bibliothèque** :
la finalisation délègue à `UserImportService.processInboxFile`, qui reste
l'unique autorité de hash, d'analyse qualité et de déduplication. Un
`COMPLETED` porte toujours un `finalTrackId`.

Concurrence : **jusqu'à `LUCIDA_MAX_CONCURRENT_DOWNLOADS` téléchargements
actifs** (défaut 3, maximum 4), file FIFO partagée, index unique en base contre
les doublons actifs. Les recherches restent concurrentes.

### Limitation de débit — ce qui protège réellement du blocage

Un service distant bloque ce qui ressemble à un abus : des rafales simultanées
et un rythme régulier de machine. Trois mesures y répondent, **sans jamais
masquer l'origine des requêtes** :

1. **Plafond de parallélisme** borné à 4 par construction (`MAX_CONCURRENT_ACQUISITIONS`).
2. **Échelonnement des démarrages** : ~1,5 s entre deux lancements, plus un
   jitter aléatoire jusqu'à 1 s, pour ne jamais émettre N requêtes dans la même
   milliseconde ni produire une cadence régulière.
3. **Retry interne au script**, borné par `downloadRetries` (0–9, défaut 2) :
   le backend ne relance jamais un processus de lui-même et l'app ne relance
   jamais un job automatiquement.

Aucune rotation d'adresse IP, aucun proxy de contournement, aucune usurpation
d'identité réseau n'est mise en œuvre : ces techniques visent à contourner des
mesures anti-abus et sortent du périmètre autorisé par `CLAUDE.md` et
`TD-Remote-Acquisition-Lucida`.

## 7. Démarrage

```bash
pnpm --filter @homespotify/api run db:migrate
```

```bash
pnpm --filter @homespotify/api run dev
```

Côté mobile, trois points d'entrée :

| Accès | Route | Rôle |
|---|---|---|
| Recherche catalogue → icône ⤓ sur un titre | — | Installe le titre en un geste |
| Profil → « Importer une musique » | `/import` | Recherche distante manuelle |
| Profil → « File d'installation » | `/import/queue` | État temps réel de tous les imports |

Le suivi d'un job précis reste sur `/import/jobs/:jobId`.

**Repli sans acquisition** : si le serveur ne l'a pas configurée (503), l'icône
de la recherche catalogue retombe sur le comportement historique — créer une
`music_request`. Aucune installation ne perd de fonctionnalité.

**Repli manuel pendant une pause** : la file et la recherche catalogue
proposent l'import d'un fichier WAV ou FLAC. Le fichier est envoyé à la route
historique `/api/tracks` et passe par l'importateur local, l'analyse technique,
le hash et la déduplication existants. Aucun second pipeline n'est créé.

## 8. Test manuel autorisé

Script fourni : `tools/smoke/lucida-acquisition-smoke.ps1`
(voir `tools/smoke/README-lucida-smoke.md`).

Recherche seule, sans aucun téléchargement :

```powershell
.\tools\smoke\lucida-acquisition-smoke.ps1 -Username owner -Query "TITRE AUTORISE"
```

Import complet, à n'utiliser que pour un contenu que tu es autorisé à récupérer :

```powershell
.\tools\smoke\lucida-acquisition-smoke.ps1 -Username owner -Query "TITRE AUTORISE" -StartAcquisition -ResultIndex 0
```

## 9. Dépannage

| Symptôme | Cause probable | Action |
|---|---|---|
| `503 feature_unavailable` | `LUCIDA_SCRIPT_PATH` absent | Renseigner un chemin absolu, redémarrer |
| Backend refuse de démarrer, « fichier .py attendu » | Chemin faux dans `.env` | Corriger le chemin |
| `INTERNAL_ERROR` immédiat, code de sortie 5 | Playwright ou Chromium absent | `python -m playwright install chromium` |
| Échec sous service Windows, OK en console | `PATH` / compte du service | Chemins absolus + `PLAYWRIGHT_BROWSERS_PATH` lisible par le service |
| `504 search_timeout` | Recherche > 45 s | Réessayer ; vérifier l'accès réseau du serveur |
| `409 active_duplicate` | Import identique déjà actif | Attendre ou annuler l'existant |
| `PROVIDER_CHALLENGE` / bandeau de pause | Vérification anti-bot demandée | Ne pas insister ; attendre `retryAt`, puis utiliser une seule relance manuelle |
| `MANUAL_VERIFICATION_REQUIRED` | Challenge détecté et mode humain activé | Sur le PC serveur, lancer `run_interactive_verification.ps1 -JobId JOB_ID` |
| `PROVIDER_VERIFICATION_TIMEOUT` | Vérification non terminée dans le délai | Relancer explicitement un nouveau workflow ; aucune reprise automatique |
| `PROVIDER_RATE_LIMITED` | Limitation HTTP 429 | Respecter le compte à rebours et `Retry-After` |
| Circuit `HALF_OPEN` | Une probe manuelle est déjà en cours | Attendre son résultat ; aucune seconde probe n'est autorisée |
| `OUTPUT_FILE_INVALID` | Fichier produit hors format FLAC/WAV, vide, ou lien symbolique | Vérifier la sortie du script ; le refus est volontaire |
| Job `INTERRUPTED` après redémarrage | Serveur arrêté pendant l'import | Relancer via « Réessayer » (crée un nouveau job) |
| `LOCAL_IMPORT_REVIEW_REQUIRED` | Le pipeline local demande un arbitrage OWNER | Traiter dans Admin → Imports |

Commandes de diagnostic sans téléchargement réel :

```powershell
python -m unittest discover -s tools/spotify-auth-spoof/tests -p "test_*.py" -v
pnpm --filter @homespotify/api test -- provider-health-repository
```

Le déploiement **shadow VPS** conserve volontairement Lucida hors périmètre :
aucune variable `LUCIDA_*` ne doit être réintroduite dans sa configuration.
Les routes y restent en `503 feature_unavailable`, conformément au plan
Phase 6.

## 10. Limites connues

- **Non qualifié production.** Aucune exécution réelle de bout en bout n'est
  tracée à ce jour ; toute la couverture est mockée. Le gate produit reste
  ouvert tant qu'un import réel n'a pas été validé sur le serveur cible.
- Fournisseur unique : **Qobuz**. Aucun autre n'est accepté par l'API.
- Parallélisme plafonné à 4 : chaque unité = un processus Python + un Chromium.
- L'installation en un geste depuis la recherche catalogue prend le **premier
  résultat** (`resultIndex: 0`). La correspondance exacte reste vérifiée par le
  script, qui refuse les approximations — mais l'utilisateur ne choisit pas la
  version. Pour choisir, passer par « Importer une musique ».
- Le sondage mobile ne se met pas en pause en arrière-plan
  (`AppLifecycleState`) : à traiter si la consommation le justifie.
- L'entrée « Importer une musique » reste visible même si le serveur n'a pas
  configuré la fonctionnalité ; l'écran affiche alors le message dédié. Masquer
  l'entrée demanderait une sonde de capacité au démarrage.
- Les retries internes existants ne concernent que les erreurs bornées d'un
  téléchargement déjà lancé. Un challenge, un 429 ou une panne fournisseur
  reconnue ne déclenche jamais de retry automatique.
- La validation interactive nécessite une session graphique Windows ouverte.
  Elle n'est pas utilisable depuis un service Windows isolé ni depuis le
  shadow VPS.
