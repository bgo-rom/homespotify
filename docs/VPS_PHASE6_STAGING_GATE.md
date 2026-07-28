# Phase 6.2 — Préflight réel et staging sans activation

- **Date :** 2026-07-28
- **Branche :** `phase6/vps-shadow-deployment`
- **Socle de départ :** `a6fea6d7`
- **Release déposée :** `20260728T174900Z-b5b4d4d5-8f4b2c54`
- **Verdict :** **GO** pour la Phase 6.3, sous les réserves du §15.

Le staging a été **réellement exécuté**. Aucune API n'a été démarrée, aucun
service créé, aucun utilisateur système créé, le port 3002 est resté libre, et
Caddy / WireGuard / pare-feu / services Windows sont inchangés.

---

## 1. Verdict

**GO.** Les onze contrôles bloquants sont verts sur le réel :

| Contrôle | Résultat |
| --- | --- |
| Runtime gelé (Node/ABI/arch/glibc) | v22.18.0 · 127 · x64 · glibc 2.36 |
| Source du bundle Phase 4.5 | confirmée, inchangée après copie |
| Modules natifs chargés réellement | `require` + CRUD + `integrity_check` verts |
| Snapshot SQLite | `ok`, 0 violation FK, 18 migrations, source inchangée |
| Manifeste applicatif | 107 fichiers + manifeste, identique après transfert |
| Pochettes | 156 fichiers / 16 841 338 o, manifeste vérifié à l'octet |
| Environnement shadow | conforme, `0600`, deux secrets présents |
| Pistes de test | 2 pistes réelles, `HEAD 200` depuis le VPS |
| Port 3002 | libre |
| Service `homespotify-api-shadow` | absent |
| `/opt`, `/var/lib`, `/etc/homespotify` | absents |

**Trois défauts réels ont été trouvés et corrigés pendant cette phase** — voir
L-109, L-110, L-111. Le premier était latent depuis la Phase 6.1 et aurait
fait échouer la Phase 6.3 au premier `require`.

---

## 2. Source réelle du bundle — confirmée

`/home/debian/homespotify-phase45/api/node_modules`

| Propriété | Valeur |
| --- | --- |
| Propriétaire / mode | `debian:debian` · `755` |
| Entrées | 118 |
| Taille | 39 364 495 octets |
| `better_sqlite3.node` | `df9fbd0d061f360d81…de15719a` |
| `argon2.linux-x64-gnu.node` | `d63ed9772bfd7efe54…aa082349` |

Traité en **lecture seule** : copié, jamais déplacé. L'empreinte de la source
est relevée avant et après la copie, et le préflight la recompare à chaque
exécution. Mesurée après le staging : `39 364 495` octets, inchangée.

> Le Gate 0 annonçait « 125 Mio » : cette valeur portait sur l'arbre
> `homespotify-phase45` entier, pas sur `node_modules`. Le chiffre réel du
> bundle est **39,4 Mio**.

Les empreintes des deux `.node` n'avaient jamais été publiées (le Gate 0 les
renvoyait au « manifeste transporté »). Elles sont désormais **gelées** dans
`TECH_DECISIONS.md`.

### Disposition — corrigée

Le contenu vit sous `<bundle-id>/node_modules/`, pas directement sous
`<bundle-id>/`. Ce n'est pas cosmétique : Node ne résout les dépendances pairs
qu'à travers des répertoires nommés exactement `node_modules`. Déposé
autrement, `better_sqlite3.node` est présent, son empreinte est juste, et le
premier `require` échoue sur `Cannot find module 'bindings'` (**L-109**).

---

## 3. Gel du runtime — confirmé

Vérifié en lecture seule sur le VPS :

```
node -v                      → v22.18.0
process.versions.modules     → 127
process.arch                 → x64
ldd --version                → glibc 2.36 (Debian 12)
```

Aucun changement depuis le Gate 0. Tout écart est un **NO-GO**, pas un
avertissement : sans gcc, make ni node-gyp, aucun module natif n'est
recompilable sur place.

---

## 4. Contrat sécurisé des secrets

| Point | Mise en œuvre |
| --- | --- |
| Jamais en argument | aucun paramètre de secret ; rendu par **stdin** |
| Saisie masquée | `Read-Host -AsSecureString` (défaut) |
| Lecture de configuration | `-SecretsFromWindowsConfig` |
| Fichier temporaire | ACL réduite à l'utilisateur, supprimé en `finally` |
| Fichier final | `secrets/api-shadow.env` en `0600`, répertoire `0700` |
| Refus avant SSH | secret absent ou < 32 caractères → arrêt, 0 connexion |
| Publié | `secretPresent`, `lengthValid`, booléens |
| Jamais publié | valeur, préfixe, **empreinte** |

`secretsPrinted = 0` dans tous les rapports.

**Décision — le shadow n'hérite pas de la clé de signature.**
`AUDIO_REMOTE_SHARED_SECRET` est celui du Storage Agent : il est partagé par
construction, sinon rien n'est signé valablement. `AUTH_TOKEN_SECRET` est en
revanche **généré** pour le shadow (48 octets de CSPRNG). Le partager rendrait
les jetons du shadow — alimenté par une base jetable — valides en production.
`-ReuseProductionAuthSecret` existe, mais c'est un choix explicite.

> Un hash de secret est explicitement refusé dans les rapports : sur un secret
> court, il est attaquable par force brute, donc il en révèle la valeur.

---

## 5. Procédure SQLite réelle

**Source réelle :** `services/api/data/homespotify.db` — chemin dérivé du
service Windows `HomeSpotifyApi` (`workingdirectory` + défaut `./data/…` de
`config.ts`), et non d'une saisie. Le nom est `homespotify.db`, pas
`runtime.db` : ce dernier est le nom de la **destination** dans le shadow.

`VACUUM INTO`, jamais une copie de fichier — la base est en WAL et vivante
(L-095). Source ouverte en `readonly`, destination refusée si existante, copie
supprimée en cas d'échec de contrôle.

| Contrôle | Résultat |
| --- | --- |
| `integrity_check` | `ok` |
| `foreign_key_check` | 0 violation |
| `__drizzle_migrations` | 18 |
| Tables | 30 |
| `user_version` | 0 — **attendu**, Drizzle suit ses migrations en table |
| Taille du snapshot | 3 436 544 o (source : 3 579 904 o) |
| SHA-256 | `1b24d380e27986d7…8429edfe` |
| Source inchangée | oui (taille et empreinte re-mesurées) |

**Après transfert**, revérifié sur le VPS : SHA-256 identique, taille
identique, `integrity_check = ok`, `foreign_key_check` vide, 18 migrations —
lues par le module natif du bundle, en lecture seule.

`homespotify.db` de production n'est **jamais** ouverte depuis le VPS. Son
chemin complet n'apparaît dans aucun journal : seul le nom de fichier est
publié.

---

## 6. Procédure des pochettes — point 6.1 fermé

| Étape | Résultat |
| --- | --- |
| Inventaire | 157 entrées, dont 1 ignorée (`.gitkeep`) |
| Retenues | **156** fichiers, **16 841 338** octets |
| Refusées | 0 |
| Liens symboliques | 0 — refusés et jamais suivis |
| Chemins `..` | refusés |
| Manifeste | SHA-256 par fichier, chemins **relatifs** uniquement |
| Après transfert | 156 fichiers, manifeste revérifié à l'octet, 0 écart |

Sélection par **allowlist** d'extensions image. Aucun cache audio, import,
variante hors ligne, sauvegarde, journal, fichier temporaire ni secret n'entre
dans la charge — vérifié par test.

Un `COVERS_DIR` vide produit `{"ok":false,"error":"COVERS_ABSENTES",
"verdict":"NO-GO"}` et arrête le staging, plutôt que de laisser un répertoire
vide non documenté.

---

## 7. Pistes de test sélectionnées

158 pistes en base, **158 éligibles**, 8 candidats sondés, **8 `HEAD 200`**.

| Rôle | `trackId` | Taille | Préfixe de hash | HEAD agent |
| --- | --- | --- | --- | --- |
| MISS puis HIT (cache) | 119 | 18 619 182 o | `b953fbe920f6` | 200 |
| MISS hors ligne | 120 | 18 680 561 o | `0a2a094f54ce` | 200 |

Santé de l'agent : `200`. Sélection déterministe (taille proche de la médiane,
tri secondaire par identifiant) : deux exécutions proposent les mêmes pistes.

Les sondes `HEAD` signées partent **du VPS** : le Storage Agent filtre l'IP
source et n'accepte que `10.8.0.1`. Une sonde depuis Windows recevrait 403 et
ne prouverait que le filtrage.

Secours disponible si la sélection automatique échoue :
`-TrackIdCached <id> -TrackIdUncached <id>`.

---

## 8. Artefact et manifeste

| Propriété | Valeur |
| --- | --- |
| `releaseId` | `20260728T174900Z-b5b4d4d5-8f4b2c54` |
| Commit | `b5b4d4d5f9859bd33a6a3608e696d0ff106c8bf1` |
| Fichiers applicatifs | **107** + `manifest.json` = 108 |
| Octets | 1 032 800 |
| `manifestSha256` | `8f4b2c54bc98f357…f957d4fa` |
| `.map` | 0 (local **et** distant) |
| `.env` | 0 |
| `node_modules` Windows | 0 |
| Chemins absolus Windows | 0 |

107 fichiers : **identique** au compte de la Phase 6.1, aucune différence à
expliquer. Le manifeste ne dépend que du contenu — `manifestSha256` est
inchangé d'une phase à l'autre, seul l'horodatage et le commit diffèrent dans
le `releaseId`.

Vérifié **localement avant transfert**, puis **à nouveau sur le VPS** :
0 fichier en trop, 0 manquant, toutes les empreintes et tailles identiques.
Aucun `rename` vers `/opt`.

---

## 9. Contenu du staging

`/home/debian/homespotify-phase6-staging/` — 6 095 fichiers, 60 872 904 octets.

```
releases/20260728T174900Z-b5b4d4d5-8f4b2c54.staging/   108 fichiers
dependency-bundles/linux-x64-node22.18.0-abi127/node_modules/   118 entrées
data/covers/                                           156 fichiers
data/sqlite/runtime-shadow.db                          3 436 544 o
data/covers-manifest.json
secrets/api-shadow.env                                 0600 (répertoire 0700)
tools/                                                 8 outils
reports/
```

### Environnement shadow — vérifié sans afficher de valeur

`NODE_ENV=production` · `LOG_LEVEL=info` · `HOST=127.0.0.1` · `PORT=3002` ·
`AUDIO_STORAGE_MODE=cached` · cache 12 GiB · plancher libre 6 GiB ·
`BACKUP_ENABLED=false` · aucune variable `LUCIDA_*` · les cinq chemins
(`DB_PATH`, `COVERS_DIR`, `INCOMING_DIR`, `OFFLINE_CACHE_DIR`,
`AUDIO_CACHE_ROOT`) absolus et sous `/var/lib/homespotify-shadow`.

> Le fichier décrit les chemins du **futur service**, pas ceux du staging :
> c'est le fichier d'environnement définitif du shadow, déposé en avance. Il
> n'a **jamais** servi à démarrer quoi que ce soit.

> Rappel d'écart de nommage (Phase 6.1) : `config.ts` lit `AUDIO_CACHE_ROOT` et
> `OFFLINE_CACHE_DIR`, pas `AUDIO_CACHE_DIR` ni `OFFLINE_VARIANTS_DIR`.

### Les 1 011 `.map` du staging

Ils sont **dans le bundle**, jamais dans la release. Ils proviennent des
paquets npm amont et font partie de l'arbre qualifié en Phase 4.5. Les
supprimer altérerait un bundle dont l'immuabilité est précisément la garantie.
L'exigence « aucun `.map` » porte sur l'artefact applicatif : **0**, local et
distant.

---

## 10. Contrôles distants

Exécutés depuis le staging, sans service, sans listener, **sans exécuter
`dist/server.js`** :

- manifeste applicatif revérifié → 0 écart ;
- manifeste des pochettes revérifié → 0 écart ;
- bundle présent, `.node` aux empreintes attendues, source Phase 4.5 identique ;
- `require('better-sqlite3')` réel, CRUD sur base temporaire supprimée ensuite ;
- snapshot ouvert en lecture seule : `integrity_check`, `foreign_key_check`,
  migrations, compte de pistes ;
- `api-shadow.env` en `0600`, validé sans afficher de valeur ;
- port 3002 libre ; unité `homespotify-api-shadow` absente ;
- utilisateur `homespotify` absent ; `/opt` et `/var/lib` intacts ;
- `Caddyfile` : `a3b4ca2b441f311a`, identique avant et après.

`sshConnectionsOpened = 6`.

---

## 11. Commande `-StageOnly`

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File F:\dev\homespotify-phase6-shadow\scripts\phase6\run_phase6_shadow_deploy.ps1 -StageOnly -SecretsFromWindowsConfig -SourceDbPath "F:\dev\homespotify\services\api\data\homespotify.db" -SourceCoversPath "F:\dev\homespotify\storage\covers"
```

Sans `-SecretsFromWindowsConfig`, les secrets sont demandés en saisie masquée.
Le mode s'arrête après les contrôles de staging : rien n'est installé.

## 12. Commande `-CleanupStaging`

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File F:\dev\homespotify-phase6-shadow\scripts\phase6\run_phase6_shadow_deploy.ps1 -CleanupStaging
```

**Exécuté deux fois pendant cette phase**, vert les deux fois :
`rootRemoved=true`, `remainingStagingFiles=0`, `remainingSecretFiles=0`,
`remainingListeners=0`, `port3002Free=true`, `preservedProtectedPaths=4`,
`bundleSourcePresent=1`, `shadowServiceCount=0`.

Aucune cible n'est acceptée en argument : la racine est écrite en dur. Sont
refusés : chaîne vide, `/`, `/home`, `/home/debian`, `/opt`, `/var`,
`/var/lib`, `/etc`, tout chemin contenant `..`, une racine qui serait un lien
symbolique, et les arbres des Phases 4.5 et 5.

---

## 13. Résultats des tests

| Suite | Résultat |
| --- | --- |
| Outillage Phase 6.2 (`test_phase6_staging.py`) | **89/89** |
| Outillage Phase 6.1 (`test_phase6_tooling.py`) | **65/65** |
| **Total** | **154/154** |

Couverture des exigences : secrets absents → refus avant SSH · secrets jamais
en arguments · secrets jamais affichés · pochettes égales à leur manifeste ·
pochettes absentes → NO-GO explicite · liens symboliques refusés · pistes
synthétiques et périmées refusées · sélection automatique de deux pistes
réelles · bundle Phase 4.5 en lecture seule · `StageOnly` ne crée aucun
service · `StageOnly` ne lance jamais `server.js` · port 3002 libre · staging
borné à sa racine · `CleanupStaging` ne touche aucune autre phase · manifeste
local égal au staging · aucun `.map` · dry-run sans SSH.

Trois tests de la Phase 6.1 ont été **mis à jour**, non affaiblis : le mode
réel existe désormais, donc la garantie « le script ne contient aucun SSH »
est devenue « la branche dry-run n'en invoque aucun ».

Contrôles de syntaxe : 6 scripts `bash -n`, `py_compile` sur tous les modules,
3 scripts PowerShell `PARSE_OK`, `git diff --check` vert.

---

## 14. Commits

| Commit | Objet |
| --- | --- |
| `b5b4d4d` | `feat(vps): add safe shadow staging workflow` |
| *(ce document)* | `docs(vps): document shadow staging gate` |

Aucun push, aucun tag.

---

## 15. Informations encore manquantes

1. **Aucune information d'entrée ne manque plus.** Les cinq points ouverts de
   la Phase 6.1 sont fermés : chemin de `homespotify.db`, secrets, pistes de
   test, gel de Node, provenance du bundle.
2. **Décision à confirmer par le propriétaire** — `AUTH_TOKEN_SECRET` du
   shadow a été *généré*, pas repris de la production. Conséquence pratique :
   les sessions de production ne s'ouvriront pas sur le shadow, et il faudra
   s'y authentifier séparément. C'est voulu ; si la parité de session est
   souhaitée pour les tests, relancer avec `-ReuseProductionAuthSecret`.
3. **Non prouvé par cette phase** — que l'API démarre. Le staging qualifie le
   dépôt, pas l'exécution. Le premier démarrage réel appartient à la
   Phase 6.3, et c'est là que se constatera tout défaut d'exécution restant.
4. **Rappel de séquencement** — la Phase 6 ne peut être déclarée *terminée* ni
   *prête pour production* tant que le gate produit de la Phase 0 (session de
   4 h + restauration) n'est pas prouvé.

---

## 16. Confirmations

| Garantie | État |
| --- | --- |
| Aucune API démarrée | confirmé — `serverJsExecuted: false` |
| Aucun service créé | confirmé — `systemctl list-unit-files` : 0 |
| Aucun utilisateur système créé | confirmé — `getent passwd homespotify` : absent |
| Port 3002 resté libre | confirmé — avant, pendant et après |
| Aucune écriture sous `/opt`, `/var/lib`, `/etc` | confirmé — les trois absents |
| Caddy inchangé | confirmé — `a3b4ca2b441f311a` identique |
| WireGuard inchangé | confirmé — `wg-quick@wg0` actif, non touché |
| Pare-feu inchangé | confirmé — aucun script ne l'invoque |
| Services Windows inchangés | confirmé — les trois `Running`, aucun script ne les invoque |
| Production inchangée | confirmé — `homespotify.db` : taille et date de modification identiques |
| Aucun push, aucun tag | confirmé |
| Aucun autre worktree touché | confirmé — seul `homespotify-phase6-shadow` a des commits |

Écoutes du VPS après staging — inchangées :
`*:443 *:80 0.0.0.0:22 0.0.0.0:5355 127.0.0.1:2019 127.0.0.53%lo:53 127.0.0.54:53`.

---

## 17. Ne pas dépasser

**Aucune installation systemd ne doit commencer avant validation explicite de
ce rapport.** Les modes `-Deploy` et `-Rollback` restent désarmés dans le code
lui-même, pas seulement dans la procédure.
