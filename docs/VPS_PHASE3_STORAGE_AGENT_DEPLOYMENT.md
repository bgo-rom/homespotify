# Phase 3 — Déploiement Windows contrôlé du Storage Agent

**Date :** 2026-07-26 · **Dépôt :** `F:\dev\homespotify` · branche `feature/lucida-import`

**Verdict : GO — Phase 3 VALIDÉE DÉFINITIVEMENT.** Tous les critères
d'acceptation sont satisfaits, y compris les tests réels depuis le VPS et la
fermeture de la règle de pare-feu générique Node.js.

> **Historique du verdict.** Ce document a d'abord conclu **NO-GO partiel** le
> 2026-07-26 en début de journée : le compte de session n'était pas
> administrateur et aucun accès SSH au VPS n'était disponible. Le propriétaire
> a levé les deux blocages dans la même journée. Les sections qui suivent
> conservent le détail de la préparation — elle reste la référence de ce qui a
> été construit et pourquoi — et le **journal d'exécution finale est en §18**.

---

## 0. Résumé exécutif

| Périmètre | État |
| --- | --- |
| Artefact de déploiement isolé et reproductible | **FAIT et validé** |
| Index de production 158/158 | **FAIT et validé** |
| Secret HMAC ≥ 32 octets, ACL restreintes | **FAIT et validé** |
| Service `HomeSpotifyStorageAgent` installé | **FAIT** |
| Identité non privilégiée `NT SERVICE\HomeSpotifyStorageAgent` | **FAIT et vérifiée** |
| ACL minimales appliquées et revalidées | **FAIT** |
| Bind exact `10.8.0.2:3100`, aucun `0.0.0.0` | **FAIT et prouvé** |
| Filtrage d'IP source | **FAIT et prouvé** |
| Chaîne HMAC complète, en local puis **depuis le VPS** | **FAIT et prouvé** (23/23 des deux côtés) |
| Règles de pare-feu précises 3000 et 3100 | **FAIT** |
| Règle générique Node.js désactivée | **FAIT, avec revalidation complète** |
| Client de test Python pour le VPS | **FAIT et exécuté depuis 10.8.0.1** |
| Procédure de rafraîchissement d'index | **FAIT et exécutée avec succès** |
| Rollback | **écrit et relu ; non déclenché — aucun échec** |
| Backend 3000 et domaine public préservés | **FAIT — aucune interruption** |

### Chiffres clés

| Mesure | Valeur |
| --- | --- |
| Latence moyenne VPS → Storage Agent | **43,8 ms** |
| Contrôles du smoke test depuis le VPS | **23 OK / 0 échec** |
| Entrées d'index chargées | **158** |
| PID de `HomeSpotifyApi`, début → fin de mission | **16948 → 16948** |
| Interruptions du service public | **aucune** |

---

## 1. Prévol (Phase 3A)

### 1.1 Service HomeSpotifyApi

| Élément | Valeur relevée |
| --- | --- |
| État | `Running` |
| PID WinSW | `16948` |
| PID Node (enfant) | `13888` |
| Compte | `LocalSystem` |
| Démarrage du processus Node | 2026-07-26 10:36:14 |
| Port | 3000 |
| Adresse d'écoute | `0.0.0.0:3000` (toutes interfaces) |
| Binaire | `infra\windows-service\homespotify-api\HomeSpotifyApi.exe` |

> Le backend écoute sur `0.0.0.0`. Son exposition réelle est donc entièrement
> déterminée par le pare-feu — ce qui rend le traitement de la règle générique
> d'autant plus important.

### 1.2 Storage Agent avant intervention

- Aucun service `HomeSpotifyStorageAgent` déclaré.
- Aucun processus en écoute sur 3100.

### 1.3 WireGuard

| Élément | Valeur |
| --- | --- |
| Adresse PC | `10.8.0.2/32`, interface `HomeSpotify-VPS` (index 52) |
| Route vers `10.8.0.1` | `10.8.0.1/32` via `HomeSpotify-VPS` |
| Service tunnel | `WireGuardTunnel$HomeSpotify-VPS`, `Running`, PID 4564 |
| 10 pings vers 10.8.0.1 | **10/10, 0 % de perte** |
| Latence | min 19 ms · moy 40,2 ms · max 121 ms |

Profils réseau : `HomeSpotify-VPS` = **Public**, `Ethernet 3` = **Public**,
`Radmin VPN` = Public, `Tailscale` = Private.

### 1.4 Backend, temps de réponse

| Cible | Statut | Temps |
| --- | --- | --- |
| `http://127.0.0.1:3000/health` | 200 | 128 ms |
| `http://10.8.0.2:3000/health` | 200 | 15 ms |
| `https://music.romainbegot.fr/health` | 200 | 580 ms |
| Depuis le VPS vers `10.8.0.2:3000` | **non testé — pas d'accès SSH** | — |

### 1.5 Pare-feu — état avant

819 règles entrantes exportées. Les cinq règles pertinentes, identifiées par
leur **nom unique** et non par leur seul libellé :

| Name | DisplayName | Actif | Proto | Port | Programme | Profils | Distant |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `TCP Query User{526CE3ED-…}C:\program files\nodejs\node.exe` | Node.js JavaScript Runtime | Oui | TCP | **Any** | node.exe | **Private, Public** | **Any** |
| `UDP Query User{D77F8514-…}C:\program files\nodejs\node.exe` | Node.js JavaScript Runtime | Oui | UDP | **Any** | node.exe | **Private, Public** | **Any** |
| `{f06aa29e-90ed-471e-a1e4-17fb6867d93a}` | HomeSpotify API 3000 | Oui | TCP | 3000 | Any | Private | Any |
| `{7ea2228d-aaeb-4d07-aab2-41a399cdc2ee}` | HomeSpotify API via WireGuard | Oui | TCP | 3000 | Any | Any | **10.8.0.1** |
| `{69c89003-fafb-459b-a59f-2c82cf8a5d19}` | WireGuard - Ping depuis VPS | Oui | ICMPv4 | — | Any | Any | 10.8.0.1 |

**Constat important, non anticipé par la mission :** la règle
`HomeSpotify API via WireGuard` couvre **déjà** le port 3000 depuis 10.8.0.1
uniquement. Le port 3000 n'a donc pas besoin de la règle générique pour rester
joignable par le VPS. Cela réduit fortement le risque de la transition 3F.

### 1.6 Disque

| Volume | Libre au prévol | Après déploiement | Après libération par le propriétaire |
| --- | --- | --- | --- |
| `C:` | **7,75 Go** | **7,21 Go** | **32,64 Go** |
| `F:` | 136,86 Go | 136,96 Go | 136,95 Go |

> **Alerte levée.** `C:` était sous le seuil de 10 Go au prévol — signalé, sans
> nettoyage automatique. Le propriétaire a libéré de l'espace en cours de
> mission : `C:` est désormais à **32,64 Go**. C'était la cause directe de
> l'unique échec de la suite de tests du backend (§10) ; ce test devrait
> repasser au vert à la prochaine exécution, **à confirmer** (§17).
> Le déploiement Phase 3 consomme ~25 Mo sur `C:` (artefact 7,35 Mo +
> WinSW 17,4 Mo).

### 1.7 Sauvegardes créées

`F:\dev\homespotify\storage\phase3-backup-20260726-113150\`

| Fichier | Contenu |
| --- | --- |
| `firewall-inbound-before.json` | 819 règles entrantes, avec Name, filtres de port, programme, adresses |
| `advfirewall-profiles-before.txt` | politique des trois profils |
| `services-before.json` | services HomeSpotify et WireGuard |
| `listeners-before.json` | tous les ports en écoute |

`advfirewall-policy-before.wfw` n'a **pas** pu être produit :
`netsh advfirewall export` exige l'élévation. L'export JSON couvre le même
périmètre en lecture et suffit au rollback, qui procède règle par règle.

**Aucun secret n'a été écrit dans ce répertoire.**

---

## 2. Artefact de déploiement (Phase 3B)

### 2.1 Méthode retenue et pourquoi

`pnpm deploy --prod` a été **essayé et écarté**, pour deux raisons cumulatives :

1. pnpm 10.12.1 le refuse : `ERR_PNPM_DEPLOY_NONINJECTED_WORKSPACE`. Il
   faudrait soit poser `inject-workspace-packages=true` — modification de la
   configuration du monorepo entier pour un seul service —, soit `--legacy`.
2. **Rédhibitoire :** dans les deux cas l'arborescence produite est liée par
   **liens durs au store pnpm global de l'utilisateur interactif**. La mission
   interdit explicitement cette dépendance, et elle est réellement dangereuse :
   un service tournant sous une identité dédiée casserait si le profil de
   `rtuyi` ou son store étaient purgés.

**Méthode retenue — option 2 de la mission :** copie contrôlée de `dist`,
`package.json` de production réduit, et `node_modules` reconstruit par
`npm install --omit=dev`, qui **copie réellement** les fichiers.

Script : `scripts\deploy_storage_agent.ps1` — ne requiert aucun privilège.

```
pnpm --filter @homespotify/storage-agent build   compilation
pnpm --filter @homespotify/storage-agent test    147/147 avant publication
pnpm list fastify --depth 0 --json               version épinglée : 5.10.0
staging isolé dans %TEMP%
npm install --omit=dev                           49 paquets
contrôle : 0 lien symbolique / jonction résiduel
robocopy /MIR vers la cible                      purge les résidus
contrôles de présence dist\main.js et fastify
```

### 2.2 Résultat

| Répertoire | Contenu | Taille |
| --- | --- | --- |
| `C:\ProgramData\HomeSpotify\StorageAgent\app` | artefact (dist + node_modules) | 2040 fichiers, 7,35 Mo |
| `…\config` | `agent.env` | 490 octets |
| `…\data` | `index.json` | 13 Ko |
| `…\logs` | (vide, le service n'a pas tourné) | — |
| `…\service` | `HomeSpotifyStorageAgent.exe` + `.xml` | 17,40 Mo |

Aucune dépendance à `tsx`, Vitest, un watcher, le store pnpm, ni un port de
développement. `src\`, `vitest.config.ts` et `winsw\` ont été purgés de la
cible par `robocopy /MIR`.

### 2.3 Index de production

```
pnpm --filter @homespotify/api storage-index:export -- --out C:\ProgramData\HomeSpotify\StorageAgent\data\index.json
```

```
158 pistes exportées
158 fichiers valides
0 chemin(s) invalide(s)
0 fichier(s) absent(s)
```

Écriture atomique (`.tmp` + `rename`) faite par le CLI. `version = 1`,
158 entrées vérifiées après écriture. **Conforme à l'attendu.**
Aucun chemin de l'index n'apparaît dans ce document ni dans aucune sortie.

### 2.4 Une modification de code a été nécessaire

`services/storage-agent/src/main.ts`, une ligne :

```ts
loadDotEnv(process.env.STORAGE_AGENT_ENV_FILE ?? '.env');
```

**Pourquoi.** Le modèle WinSW de la Phase 2 suppose un élément `<envFile>`.
Or le binaire WinSW réellement installé est la **version 2.12.0**, et
`envFile` n'est pas un élément fiable de la configuration WinSW v2 — c'est un
apport de la v3. Trois options :

1. parier sur `envFile` en v2 : WinSW ignore silencieusement les éléments
   inconnus, donc l'échec ne se verrait qu'au démarrage du service ;
2. installer WinSW v3 pour ce seul service : deux versions de WinSW sur la
   machine, contre la consigne « même version que HomeSpotifyApi » ;
3. rendre le chemin du fichier d'environnement explicite via une variable
   d'environnement ordinaire, que WinSW v2 sait poser.

**Option 3 retenue.** `STORAGE_AGENT_ENV_FILE` ne transporte qu'un **chemin** :
il peut figurer dans le XML versionné sans exposer quoi que ce soit. Le secret
reste dans le seul `agent.env`. Comportement inchangé hors service : sans la
variable, `loadDotEnv('.env')` comme avant. 147/147 après modification.

---

## 3. Identité du service (Phase 3C)

### 3.1 Choix : compte de service virtuel, sans mot de passe

**Retenu : `NT SERVICE\HomeSpotifyStorageAgent`.**

Le compte local dédié `HomeSpotifySA` envisagé en Phase 2 est **écarté**. Il
imposerait de générer, transmettre et stocker un mot de passe. Un compte
virtuel n'en a **aucun** : Windows le matérialise automatiquement à partir du
SID de service. Il n'y a donc rien à protéger, rien à faire fuiter, rien à
faire tourner. Cela satisfait la clause d'arrêt immédiat « l'identité de
service nécessite un mot de passe en clair non protégé » de la manière la plus
forte possible : le mot de passe n'existe pas.

**Faisabilité vérifiée sur pièces, pas sur postulat.** WinSW 2.12 ne permet pas
de déclarer proprement un compte virtuel dans son XML. La séquence retenue,
codée dans `install_storage_agent_service.ps1`, contourne le problème sans
compromis :

```
HomeSpotifyStorageAgent.exe install          # installe sous LocalSystem
sc.exe sidtype HomeSpotifyStorageAgent unrestricted
sc.exe config  HomeSpotifyStorageAgent obj= "NT SERVICE\HomeSpotifyStorageAgent" password= ""
```

Le script **vérifie** ensuite que `Win32_Service.StartName` vaut bien
`NT SERVICE\HomeSpotifyStorageAgent` et échoue sinon. Le service ne tourne
jamais sous LocalSystem au-delà de cet instant d'installation, avant tout
démarrage.

Le XML ne contient **ni `<serviceaccount>`, ni `<password>`** — vérifié
programmatiquement avant installation.

> **Confirmé sur l'environnement réel.** La bascule a abouti :
> `Win32_Service.StartName = NT SERVICE\HomeSpotifyStorageAgent`,
> `SERVICE_SID_TYPE = UNRESTRICTED`. Le service tourne sous cette identité,
> sans qu'aucun mot de passe n'ait jamais existé.
>
> **Une correction a été nécessaire, voir L-096.** La première tentative
> passait par `Invoke-CimMethod Win32_Service Change` avec `StartPassword = ''`
> et retournait le **code 22, « paramètre invalide »**. Un compte virtuel exige
> un mot de passe **NULL**, pas vide : le paramètre doit être **omis**, pas
> neutralisé. `sc.exe config … password= ""` échoue pour une raison voisine —
> PowerShell supprime l'argument vide. La forme retenue est
> `sc.exe config <nom> obj= "NT SERVICE\<nom>"`, **sans aucun argument
> `password`**, suivie d'une relecture immédiate de `StartName` et d'un refus
> explicite de toute identité privilégiée.

### 3.2 ACL — état avant

Sur `C:\ProgramData\HomeSpotify\StorageAgent\config\agent.env`, ACL héritées
de `C:\ProgramData` à la création :

| Identité | Droits | Hérité |
| --- | --- | --- |
| `AUTORITE NT\Système` | FullControl | oui |
| `BUILTIN\Administrateurs` | FullControl | oui |
| `DESKTOP-H5OQ5AK\rtuyi` | FullControl | oui |
| **`BUILTIN\Utilisateurs`** | **ReadAndExecute** | oui |

L'entrée `BUILTIN\Utilisateurs` est exactement ce que la mission interdit :
tout utilisateur ordinaire de la machine pouvait lire le fichier.

### 3.3 ACL — état après (appliqué)

Héritage **rompu et non copié** (`AreAccessRulesProtected = True`) :

| Identité | Droits |
| --- | --- |
| `AUTORITE NT\Système` | FullControl |
| `BUILTIN\Administrateurs` | FullControl |
| `DESKTOP-H5OQ5AK\rtuyi` | **Read** (dégradé depuis FullControl) |

`BUILTIN\Utilisateurs` **supprimé**.

> L'entrée `rtuyi` en lecture est **transitoire** : elle a permis de valider
> l'agent avec la configuration réelle sans privilèges. Elle doit être retirée
> une fois le service installé — `install_storage_agent_service.ps1` ajoute
> l'identité du service, la commande de retrait est donnée en §11.

### 3.4 ACL prévues pour l'identité du service

Appliquées par `install_storage_agent_service.ps1`, **non encore exécutées** :

| Objet | Droits accordés à `NT SERVICE\HomeSpotifyStorageAgent` | Héritage |
| --- | --- | --- |
| `…\app` | `RX` lecture/exécution | `(OI)(CI)` |
| `…\config\agent.env` | `R` lecture seule | — |
| `…\data\index.json` | `R` lecture seule | — |
| `…\logs` | `M` modification | `(OI)(CI)` |
| `F:\dev\homespotify\storage\music` | `RX` lecture/exécution | `(OI)(CI)` |
| `F:\dev\homespotify\storage`, `F:\dev\homespotify`, `F:\dev`, `F:\` | `RX` **ce dossier seulement** | aucun |

Traversée minimale : `RX` sans `(OI)(CI)` sur les parents n'accorde que la
traversée et le listage de ce dossier précis, rien en dessous.

Interdits, et **contrôlés par le script** : aucune écriture sur la
bibliothèque musicale (le script inspecte l'ACL résultante et échoue si un ACE
porte `Write`, `Modify`, `FullControl` ou `Delete`), aucun droit sur la base
SQLite, aucune appartenance au groupe Administrateurs.

---

## 4. Secret HMAC (Phase 3D)

| Élément | Valeur |
| --- | --- |
| Emplacement | `C:\ProgramData\HomeSpotify\StorageAgent\config\agent.env` |
| Génération | `System.Security.Cryptography.RNGCryptoServiceProvider` (CNG / `BCryptGenRandom`) |
| Entropie | **32 octets**, encodés en 64 caractères hexadécimaux |
| Empreinte non réversible | `46c7cfc6611f4a7c` (SHA-256 salée, tronquée à 16 hex) |
| ACL | §3.3, héritage rompu |

L'empreinte est calculée sur `SHA-256("HS-AGENT-SECRET-FPR|" + secret)`. Elle
sert uniquement à vérifier que le PC et le VPS utilisent bien la même valeur.
Le client Python la recalcule et l'affiche — la comparaison des deux
empreintes suffit, sans jamais transporter ni afficher le secret.

Variables présentes dans `agent.env` (valeurs non secrètes) :

```
STORAGE_AGENT_HOST=10.8.0.2
STORAGE_AGENT_PORT=3100
STORAGE_AGENT_MUSIC_ROOT=<racine musicale réelle>
STORAGE_AGENT_INDEX_PATH=C:\ProgramData\HomeSpotify\StorageAgent\data\index.json
STORAGE_AGENT_SHARED_SECRET=<32 octets, jamais affiché>
STORAGE_AGENT_ALLOWED_REMOTE_IP=10.8.0.1
STORAGE_AGENT_MAX_CONCURRENT_STREAMS=8
STORAGE_AGENT_HMAC_MAX_CLOCK_SKEW_SECONDS=60
STORAGE_AGENT_LOG_LEVEL=info
STORAGE_AGENT_INDEX_POLL_INTERVAL_MS=5000
```

**Le secret n'a jamais été affiché, journalisé, ni écrit ailleurs.** Contrôle
exécuté sur les journaux produits pendant les tests : 0 occurrence de
`SHARED_SECRET`, 0 occurrence de `secret`, 0 chaîne hexadécimale de 64
caractères, 0 chemin `F:\`.

Le secret utilisé pour les tests fonctionnels (§7) était un **secret jetable
distinct**, généré pour l'occasion, jamais le secret de production.

---

## 5. Service WinSW (Phase 3E)

| Élément | Valeur |
| --- | --- |
| Binaire source | `infra\windows-service\homespotify-api\HomeSpotifyApi.exe` |
| Version | WinSW **2.12.0** (`2.12.0+eef5bade59fca0254e387ac73ed7625ba6aa7147`) |
| SHA-256 | `05B82D46AD331CC16BDC00DE5C6332C1EF818DF8CEEFCD49C726553209B3A0DA` |
| Copie | `…\service\HomeSpotifyStorageAgent.exe` — **SHA-256 identique, vérifié** |
| XML versionné | `services\storage-agent\winsw\HomeSpotifyStorageAgent.xml` |
| XML déployé | `…\service\HomeSpotifyStorageAgent.xml` |
| `id` | `HomeSpotifyStorageAgent` |
| `name` | `HomeSpotify Storage Agent` |

Le service `HomeSpotifyApi` n'a **pas** été modifié : son binaire, son XML et
son PID sont inchangés.

Configuration :

- démarrage `Automatic` + `delayedAutoStart` ;
- `<depend>Tcpip</depend>` et `<depend>WireGuardTunnel$HomeSpotify-VPS</depend>`
  — cette dépendance **peut** être déclarée de façon fiable, le nom de service
  ayant été relevé sur la machine ; elle est nécessaire car `10.8.0.2` n'existe
  pas tant que le tunnel n'est pas monté et que l'agent **refuse** de démarrer
  s'il ne peut pas s'y lier ;
- répertoire de travail explicite `…\app` ;
- logs rotatifs `roll-by-size`, 16 Mo × 8 fichiers ;
- arrêt gracieux : `stoptimeout` 30 s, `stopparentprocessfirst` ;
- redémarrages **bornés** : 15 s, 60 s, 120 s, puis `none` ; `resetfailure` 1 h.

### Contrôles pré-installation, tous passés

| Contrôle | Résultat |
| --- | --- |
| XML bien formé | OK (`id` et `name` relus) |
| Aucun `SHARED_SECRET` dans le XML | OK |
| Aucun `<password>` dans le XML | OK |
| `node.exe`, `dist\main.js`, `app`, `agent.env`, `logs`, racine musicale, `index.json` | tous présents |
| Port 3100 libre | OK (0 listener) |
| Bind exact `10.8.0.2` | **prouvé en exécution réelle** (§7.2) |

**Le service est installé et démarré** (§18).

### Dépendances de service — un piège de vérification

`WinSW 2.12` **n'enregistre pas** un `<depend>` dont le nom contient `$` :
après `winsw install`, seul `Tcpip` figurait dans la configuration du service.
Le tunnel `WireGuardTunnel$HomeSpotify-VPS` a donc été posé explicitement par
`sc.exe config <nom> depend= "Tcpip/WireGuardTunnel$HomeSpotify-VPS"`
(séparateur `/`, la liste est remplacée en entier).

La vérification qui a suivi a d'abord signalé un faux échec, pour deux raisons
cumulées — voir **L-097** :

| Source consultée | Résultat | Fiable |
| --- | --- | --- |
| Registre `DependOnService` | `Tcpip`, `WireGuardTunnel$HomeSpotify-VPS` | **oui** |
| `sc qc` filtré sur `DEPENDENCIES` | `Tcpip` seulement | non — les dépendances suivantes sont sur des lignes de continuation |
| `Win32_Service.ServicesDependedOn` | vide | non — l'association WMI ne résout pas un nom contenant `$` |

Le script lit désormais le **registre**, seule source de vérité ici. Les deux
dépendances sont bien enregistrées ; **aucun redémarrage n'a été nécessaire.**

---

## 6. Pare-feu (Phase 3F) — EXÉCUTÉ

Les deux règles précises ont été créées, puis les deux règles génériques
`Node.js JavaScript Runtime` ont été **désactivées** après revalidation
complète. Détail chronologique en §18.

Les deux règles précises sont définies dans
`scripts\install_storage_agent_service.ps1` :

| | Règle backend | Règle Storage Agent |
| --- | --- | --- |
| DisplayName | `HomeSpotify-API-3000-WireGuard-VPS` | `HomeSpotify-StorageAgent-3100-WireGuard-VPS` |
| Direction | Inbound | Inbound |
| Action | Allow | Allow |
| Protocole | TCP | TCP |
| LocalPort | 3000 | 3100 |
| LocalAddress | `10.8.0.2` | `10.8.0.2` |
| RemoteAddress | `10.8.0.1` | `10.8.0.1` |
| Profil | Public | Public |
| Programme | `C:\Program Files\nodejs\node.exe` | `C:\Program Files\nodejs\node.exe` |

Restriction par **programme** et non par service : WinSW lance `node.exe` en
processus enfant, une restriction `-Service` ne serait pas fiable.

Aucune règle n'autorise tous les ports, toutes les adresses distantes, tous les
profils, `0.0.0.0/0`, le LAN, ni l'IP publique du PC.

### Transition de la règle générique — automatisable sans SSH

`scripts\firewall_transition_generic_node.ps1` implémente l'ordre imposé par la
mission. Le point clé est la **validation** :

> Caddy sert `https://music.romainbegot.fr` en proxy vers `10.8.0.2:3000` à
> travers WireGuard. **Un 200 sur ce domaine prouve transitivement que le
> chemin VPS → WireGuard → backend Windows fonctionne.** Ce contrôle remplace
> le test SSH direct, et il est exécutable depuis le PC.

Séquence : contrôle des deux règles précises → baseline domaine public →
identification des règles génériques **sur critère structurel** (programme =
`node.exe`, port `Any`, distant `Any`) et non sur le libellé → export JSON de
leur état → désactivation → 5 contrôles du domaine public → **en cas d'échec,
réactivation immédiate, conservation du journal de diagnostic, sortie en
erreur**, sans improviser d'autre règle large.

Limite assumée et documentée : **rien ne proxifie le port 3100**, la règle 3100
reste donc non validée de bout en bout tant que
`vps_storage_agent_smoke_test.py` n'a pas été exécuté depuis le VPS. Cette
règle étant purement additive, un défaut de sa part ne peut pas couper le
service public.

### Effet de bord à connaître avant d'exécuter la transition

`Ethernet 3` est en profil **Public**. Aujourd'hui, c'est la règle générique
qui rend le port 3000 joignable depuis le LAN sur cette interface. Après
désactivation, 3000 ne sera plus joignable que depuis `10.8.0.1` et, en profil
Private, via la règle préexistante `HomeSpotify API 3000`. **Tout client qui
attaque directement l'IP LAN du PC en profil Public cessera de fonctionner.**
C'est l'objectif recherché, mais il faut l'avoir décidé.

**Vérification déjà acquise :** le port 3100 n'est joignable sur **aucune**
adresse LAN, y compris avec la règle générique encore active — parce que
l'agent ne s'y lie pas (§7.2). La contrainte « 3100 non autorisé sur l'adresse
LAN » est donc satisfaite au niveau du bind, indépendamment du pare-feu.

---

## 7. Tests réels (Phase 3H, partie PC)

### 7.1 Validation de l'artefact déployé

L'agent a été lancé **depuis l'artefact déployé** (`…\app\dist\main.js`), pas
depuis les sources, avec un secret jetable et `STORAGE_AGENT_ALLOWED_REMOTE_IP=127.0.0.1`,
sur `127.0.0.1:3199`.

```
STORAGE_AGENT_INDEX_LOADED  entryCount=158  indexVersion=1
Server listening at http://127.0.0.1:3199
STORAGE_AGENT_STARTED       host=127.0.0.1 port=3199 maxConcurrentStreams=8
```

Client `scripts\vps_storage_agent_smoke_test.py`, **23 contrôles, 0 échec** :

| # | Test | Résultat |
| --- | --- | --- |
| 1 | `/health` signé | 200, `healthy`, `indexLoaded=true`, `indexEntryCount=158`, `musicRootAvailable=true`, `activeStreams=0` |
| — | fuite de chemin ou de secret dans `/health` | **aucune** |
| 2 | HEAD signé | 200, `Content-Length` = 28 870 968, `Accept-Ranges: bytes`, corps vide (0 octet) |
| 3 | GET `Range: bytes=0-1023` | 206, `Content-Length: 1024`, `Content-Range: bytes 0-1023/28870968`, 1024 octets reçus |
| 4 | GET `Range: bytes=-512` (suffixe) | 206, `Content-Length: 512`, `Content-Range: bytes 28870456-28870967/28870968` |
| 5 | Range insatisfaisable | **416** |
| 6 | Requête sans signature | **401 `AUTH_MISSING`** |
| 7 | Signature invalide | **401 `AUTH_INVALID`** |
| 8 | Rejeu du nonce | 1ʳᵉ 200, rejeu **401 `AUTH_REPLAY`** |
| 9 | 5 × `/health` | 5/5 en 200 — total min 1,4 / moy 9,3 / max 16,0 ms ; TTFB min 1,4 / moy 9,2 / max 16,0 ms |

Volume téléchargé : **1536 octets au total**. Aucune donnée musicale affichée.

### 7.2 Validation du bind de production

L'agent a ensuite été lancé avec le **fichier `agent.env` de production réel**
(secret de production, `10.8.0.2:3100`, IP autorisée `10.8.0.1`) :

```
STORAGE_AGENT_INDEX_LOADED  entryCount=158
Server listening at http://10.8.0.2:3100
STORAGE_AGENT_STARTED       host=10.8.0.2 port=3100
```

`netstat -ano` : une seule ligne, `TCP 10.8.0.2:3100 LISTENING`.
**Aucun listener `0.0.0.0:3100`.**

Accessibilité du port 3100 par adresse :

| Adresse | Interface | 3100 accessible |
| --- | --- | --- |
| `10.8.0.2` | HomeSpotify-VPS | **oui** |
| `10.32.221.80` | Ethernet 3 | non |
| `192.168.1.153` | Wi-Fi | non |
| `26.0.244.248` | Radmin VPN | non |
| `127.0.0.1` | loopback | non |

**Filtrage d'IP source prouvé :** une requête non signée émise depuis le PC
vers `10.8.0.2:3100` reçoit **403**, corps vide — l'IP source `10.8.0.2` n'est
pas `10.8.0.1`, et la barrière IP est bien franchie avant l'authentification,
conformément à l'ordre annoncé en Phase 2.

L'agent a été **arrêté** après ces tests : aucun processus lancé manuellement
n'a été laissé en écoute (0 listener sur 3100 en fin de mission).

### 7.3 Absence de fuite dans les journaux

Sur l'ensemble des journaux produits (`stdout` + `stderr`, deux exécutions) :

| Motif recherché | Occurrences |
| --- | --- |
| `SHARED_SECRET` | 0 |
| `secret` (insensible à la casse) | 0 |
| chemin `F:\` | 0 |
| chaîne hexadécimale de 64 caractères (signature) | 0 |

### 7.4 Tests NON exécutés

Tous les tests VPS listés ici comme non exécutés **l'ont été depuis** — voir
§18. Restent non exécutés à la clôture de la Phase 3 :

| Test | Raison |
| --- | --- |
| Limite de 8 flux concurrents en réel | couverte par les tests unitaires (8 acceptés, 9ᵉ refusé, libération après succès / abandon / erreur) ; un test réel à huit flux complets est explicitement hors périmètre |
| Lecture depuis l'application mobile (démarrage, seek, piste suivante, écran verrouillé) | aucun changement n'affecte le chemin de lecture actuel : `AUDIO_STORAGE_MODE` reste `local` et l'application passe par `music.romainbegot.fr` |
| Suite de tests du backend après libération de `C:` | à rejouer pour confirmer le retour à 437/437 (§17) |

---

## 8. Client de test VPS (Phase 3G)

`scripts\vps_storage_agent_smoke_test.py` — **bibliothèque standard uniquement**,
validé sous Python 3.10.11, `py_compile` propre.

```bash
# sur le VPS
python3 vps_storage_agent_smoke_test.py http://10.8.0.2:3100 <trackId>
```

Conformité aux exigences :

| Exigence | Mise en œuvre |
| --- | --- |
| Protocole exact Phase 2 | `METHOD \n PATH_WITH_QUERY \n TIMESTAMP \n NONCE \n CONTENT_SHA256`, HMAC-SHA256 hex |
| Secret hors ligne de commande | `STORAGE_AGENT_SHARED_SECRET` **ou** `--secret-file` ; jamais un argument positionnel |
| Fichier de secret protégé | mode vérifié, **refus si les bits groupe/autres sont posés** (attendu 0600) |
| Nonce cryptographique | `secrets.token_urlsafe(32)` — 256 bits, bien au-delà des 128 exigés |
| Secret jamais affiché | seule une empreinte SHA-256 salée tronquée est imprimée |
| Signature jamais affichée | aucune signature n'est imprimée, même tronquée |
| Volume téléchargé | plafonné à 2048 octets par réponse |
| Résumé sans donnée musicale | seuls des compteurs, statuts et en-têtes |

Le script vérifie statuts, `Content-Length`, `Content-Range`, les codes
d'erreur applicatifs (`AUTH_MISSING`, `AUTH_INVALID`, `AUTH_REPLAY`), et
recherche activement une fuite de chemin dans `/health`.

**Exécuté depuis le VPS.** Le script a été copié sur `debian@135.125.101.79`,
le secret transféré directement dans le tunnel SSH sans jamais être rendu à
l'écran, utilisé, puis effacé. Résultats et traçabilité en §18.

---

## 9. Rafraîchissement de l'index (Phase 3I)

`scripts\refresh_storage_agent_index.ps1` — **exécuté avec succès** :

```
[index] contrôle de l'API locale
[index] API : 200
[index] base SQLite présente (3.2 Mo)
[index] index actuel généré le 2026-07-26T09:36:13.556Z
[index] export en lecture seule
[index] base SQLite toujours présente, aucune troncature
[index] résumé : 158 exportées / 158 valides / 0 invalides / 0 absentes
[index] index écrit : version 1, 158 entrées, généré le 2026-07-26T09:51:15.649Z
[index] service HomeSpotifyStorageAgent non démarré — rechargement non vérifiable
```

Le script vérifie l'API et la base, lance l'export readonly, contrôle le
résumé (échec si un chemin invalide ou un fichier absent est signalé),
contrôle que `generatedAt` a bien changé, puis **vérifie le rechargement à
chaud sans redémarrer le service**.

Deux décisions de conception :

1. **La vérification du rechargement lit le journal local de l'agent, pas une
   requête HTTP.** L'agent n'accepte que l'IP source `10.8.0.1` : une requête
   émise depuis le PC recevrait 403 même correctement signée. Lire le journal
   évite en outre que ce script ait besoin du secret.
2. **Aucune comparaison d'empreinte de la base.** Elle est ouverte en écriture
   par l'API en production, donc son contenu change légitimement pendant
   l'export — une comparaison produirait de fausses alertes. La garantie de
   non-écriture est plus forte et vient d'ailleurs : le CLI ouvre SQLite en
   `readonly` + `fileMustExist`, et `storage-index-export.test.ts` vérifie que
   la base est inchangée octet à octet.

> **PROCÉDURE À APPLIQUER : après chaque nouvel import, exécuter ce script**,
> tant que la synchronisation automatique VPS → PC n'est pas disponible. Sans
> cela, les pistes nouvellement importées restent invisibles pour le Storage
> Agent (404 `TRACK_NOT_INDEXED`) alors qu'elles sont lisibles par l'API locale.

Aucune tâche planifiée n'a été créée.

---

## 10. Tests de non-régression

| Suite | Résultat | Baseline |
| --- | --- | --- |
| `@homespotify/storage-agent` | **147/147** (6 fichiers) | 147/147 — conforme |
| `@homespotify/storage-agent` typecheck | 0 erreur | — |
| `@homespotify/api` | **436 passés / 1 échec** sur 437 | 436/437 — **conforme** |

L'unique échec est celui, préexistant et environnemental, déjà identifié :
`src/auth/auth.test.ts > administration OWNER > OWNER voit l'overview avec des
données réelles et sans secret`, avec
`AssertionError: expected 'critical' to be 'healthy'` — le contrôle d'espace
disque, déclenché par `C:` à 7,2 Go.

| Cible | Avant Phase 3 | Après Phase 3 |
| --- | --- | --- |
| `http://127.0.0.1:3000/health` | 200 (128 ms) | 200 (54 ms) |
| `http://10.8.0.2:3000/health` | 200 (15 ms) | 200 (16 ms) |
| `https://music.romainbegot.fr/health` | 200 (580 ms) | 200 (140 ms) |
| `HomeSpotifyApi` PID WinSW | 16948 | **16948** |
| `HomeSpotifyApi` PID Node | 13888 | **13888** |

**HomeSpotifyApi n'a pas été redémarré et n'a subi aucune interruption.**
`AUDIO_STORAGE_MODE` est inchangé. Aucun fichier audio, aucune base de données
n'a été modifié. Aucun commit n'a été créé.

Non exécuté : validation de lecture depuis l'application mobile (démarrage de
piste, seek, piste suivante, écran verrouillé). Aucun changement n'affecte le
chemin de lecture actuel — l'application continue d'utiliser le backend Windows
sur 3000, et le Storage Agent n'est ni installé ni démarré.

---

## 11. Reste à faire pour clore administrativement la Phase 3

Les trois étapes d'installation, de validation VPS et de transition pare-feu
**ont toutes été exécutées** (§18). Il subsiste deux actions mineures, aucune
n'étant bloquante pour la Phase 4.

**1. Retirer l'accès de lecture transitoire de `rtuyi` sur le secret**

Cette entrée a permis de valider l'agent avec la configuration réelle avant que
l'élévation soit disponible, puis de pousser le secret vers le VPS sans console
élevée. Elle n'a plus d'usage. Console **élevée** :

```powershell
icacls C:\ProgramData\HomeSpotify\StorageAgent\config\agent.env /remove:g "DESKTOP-H5OQ5AK\rtuyi"
```

Contrôle attendu après retrait — trois entrées seulement :

```powershell
(Get-Acl C:\ProgramData\HomeSpotify\StorageAgent\config\agent.env).Access |
  Select-Object IdentityReference,FileSystemRights
```

`AUTORITE NT\Système` FullControl · `BUILTIN\Administrateurs` FullControl ·
`NT SERVICE\HomeSpotifyStorageAgent` Read.

> Conséquence à connaître : après ce retrait, une nouvelle poussée du secret
> vers le VPS exigera une console élevée. C'est voulu.

**2. Rejouer la suite de tests du backend**

`C:` étant remonté à 32,64 Go, le contrôle d'espace disque devrait repasser au
vert et la suite revenir à 437/437 :

```bash
pnpm --filter @homespotify/api test
```

---

## 12. Rollback

`scripts\rollback_storage_agent.ps1`, trois périmètres combinables :

| Invocation | Effet |
| --- | --- |
| `-AgentOnly` | arrêt gracieux, suppression de la règle 3100, désinstallation du service |
| `-FirewallOnly` | réactivation des règles génériques depuis l'export JSON, contrôle du domaine public, suppression de la règle 3000 Phase 3 **si et seulement si** la règle préexistante `HomeSpotify API via WireGuard` est active |
| (par défaut) | les deux, dans l'ordre sûr : **le pare-feu d'abord** — on rétablit la voie de secours avant de retirer quoi que ce soit |
| `-RemoveApp` | supprime aussi l'artefact applicatif |
| `-RemoveSecret` | supprime le secret — **décision explicite requise** |

Conservés par défaut : index de production, journaux, secret.

Ne sont **jamais** touchés : `HomeSpotifyApi` (ni arrêt, ni redémarrage, ni
configuration), la règle `WireGuard - Ping depuis VPS`, les règles
préexistantes `HomeSpotify API via WireGuard` et `HomeSpotify API 3000`, Caddy,
WireGuard, la base SQLite, la bibliothèque musicale. **Aucun reset global du
pare-feu, en aucune circonstance.**

Le script réactive les règles génériques uniquement si l'export indique
qu'elles étaient actives avant, et vérifie le PID de `HomeSpotifyApi` en fin
d'exécution.

### État de vérification du rollback

Ce qui a été réellement défait pendant la mission, sans incident :

- les deux processus d'agent lancés manuellement ont été arrêtés — 0 listener
  résiduel sur 3100 et 3199 ;
- `HomeSpotifyApi` a conservé ses PID (16948 / 13888) du début à la fin.

Le **rollback automatique** du script de transition a été armé et n'a pas eu à
se déclencher : les dix contrôles post-désactivation sont passés du premier
coup. Son chemin de réactivation est donc écrit, relu et instrumenté, mais
**non exercé en conditions réelles**.

L'export nécessaire à ce rollback existe bien et a été vérifié :

```
C:\ProgramData\HomeSpotify\StorageAgent\backup\firewall-20260726-135201\generic-node-rules-before.json  (878 octets)
```

> **Limite honnête :** un rollback qui n'a jamais eu à s'exécuter n'est pas un
> rollback prouvé. Le déclencher volontairement couperait l'accès public le
> temps du test, ce qui n'a pas été jugé souhaitable. C'est le seul critère
> d'acceptation de la Phase 3 satisfait « sur pièces » plutôt que par
> exécution, et il est reporté en risque résiduel (§14).

---

## 13. Incidents rencontrés

| # | Incident | Résolution |
| --- | --- | --- |
| 1 | Pas d'accès SSH au VPS | Mission recentrée sur le côté Windows, avec accord du propriétaire |
| 2 | Compte de session non administrateur | Étapes privilégiées livrées en scripts, non exécutées |
| 3 | `netsh advfirewall export` refusé (élévation) | Export JSON exhaustif des 819 règles à la place |
| 4 | `pnpm deploy --prod` refusé par pnpm 10, et couplant au store global | Copie contrôlée + `npm install --omit=dev` |
| 5 | `pnpm deploy` avait déjà copié des fichiers avant d'échouer | `robocopy /MIR` purge la cible à chaque publication |
| 6 | WinSW 2.12 : `envFile` non fiable en v2 | `STORAGE_AGENT_ENV_FILE`, une ligne dans `main.ts` (§2.4) |
| 7 | PowerShell 5.1 lit les `.ps1` en ANSI : accents cassant l'analyse | Tous les scripts écrits en UTF-8 **avec BOM**, syntaxe validée par `PSParser` |
| 8 | `Set-StrictMode -Version Latest` + shims pnpm/npm → `PropertyNotFoundStrict` | StrictMode retiré, contrôles explicites à chaque étape |
| 9 | Le contrôle de fuite du client Python détectait `musicRootAvailable`, champ légitime | Contrôle réécrit sur clés exactes et motifs de chemin |
| 10 | `Get-FileHash` sur la base SQLite : fichier verrouillé par l'API | Comparaison d'empreinte abandonnée, avec justification (§9) |
| 11 | Avertissement Fastify `FSTDEP023` (`disableRequestLogging` déprécié) | Sans effet en Fastify 5 ; à traiter avant un passage à Fastify 6 |
| 12 | `Win32_Service.Change` avec `StartPassword = ''` → **code 22** | Un compte virtuel exige un mot de passe NULL, pas vide : `sc.exe config … obj=` **sans** argument `password` (L-096) |
| 13 | WinSW 2.12 n'enregistre pas un `<depend>` contenant `$` | Dépendance posée par `sc.exe config … depend=`, puis relue dans le **registre** (L-097) |
| 14 | Faux échec de vérification des dépendances : `sc qc` filtré et `ServicesDependedOn` mentaient tous les deux | Lecture du registre `DependOnService`, seule source de vérité |
| 15 | `debian@135.125.101.79` refuse mes deux clés publiques | Le propriétaire a exécuté lui-même la procédure VPS ; aucun mot de passe ne m'a été communiqué |

---

## 14. Risques restants

| Risque | Gravité | Note |
| --- | --- | --- |
| Chemin de rollback du pare-feu **non exercé** | Moyenne | Armé, instrumenté, export présent — mais jamais déclenché (§12) |
| Ordre de démarrage au **redémarrage machine** non observé | Moyenne | La dépendance au tunnel est enregistrée, mais aucun reboot n'a eu lieu depuis. Premier reboot à surveiller : l'agent doit démarrer après le tunnel, sinon il consommera ses trois relances bornées |
| Accès LAN direct au port 3000 en profil Public **supprimé** | Faible | Effet voulu, arbitré explicitement par le propriétaire : l'application mobile n'utilise que `music.romainbegot.fr` |
| Index manuel : toute nouvelle piste est invisible de l'agent jusqu'au rafraîchissement | Faible | Procédure §9 ; automatisation hors périmètre |
| Entrée ACL transitoire `rtuyi` sur `agent.env` | Faible | Lecture seule ; retrait en §11 |
| Suite backend à 436/437 tant qu'elle n'est pas rejouée | Faible | Cause disque levée ; simple confirmation à faire |

**Risques levés par cette phase**, mentionnés ici pour mémoire : la règle
générique Node.js n'est plus active ; `C:` n'est plus sous le seuil ; la
bascule vers le compte virtuel est prouvée ; la règle 3100 est validée de bout
en bout depuis le VPS.

---

## 15. Prérequis Phase 4 (`RemoteWindowsStorageProvider`)

| # | Prérequis | État |
| --- | --- | --- |
| 1 | Espace sur `C:` > 10 Go | **satisfait** — 32,64 Go |
| 2 | Smoke test VPS entièrement vert, empreinte concordante | **satisfait** — 23/23, `46c7cfc6611f4a7c` |
| 3 | Règle générique Node.js traitée, domaine public confirmé | **satisfait** |
| 4 | Service sous `NT SERVICE\HomeSpotifyStorageAgent`, ACL relevées | **satisfait** |
| 5 | Latence réelle VPS → agent mesurée | **satisfait** — 43,8 ms de moyenne |
| 6 | Mécanisme de synchronisation automatique de l'index | **non traité** — hors périmètre, procédure manuelle §9 |
| 7 | Lecture mobile validée après installation du service | **non requis en Phase 4** — le chemin de lecture reste local |

Les cinq premiers prérequis techniques sont levés. Le plan détaillé de la
Phase 4 est dans **`docs/VPS_PHASE4_REMOTE_STORAGE_PROVIDER_PLAN.md`**.

Le point 6 est le seul qui conditionne réellement la **mise en service** du
mode `remote` : tant que l'index est déposé à la main, une piste importée est
lisible en local mais invisible du Storage Agent. Ce n'est pas un obstacle à
l'écriture du provider, c'en est un à son activation.

---

## 16. Fichiers créés ou modifiés

| Fichier | Nature |
| --- | --- |
| `scripts/deploy_storage_agent.ps1` | créé — artefact reproductible, **exécuté** |
| `scripts/refresh_storage_agent_index.ps1` | créé — rafraîchissement d'index, **exécuté** |
| `scripts/vps_storage_agent_smoke_test.py` | créé — client HMAC, **exécuté en réel** |
| `scripts/install_storage_agent_service.ps1` | créé — idempotent et reprenable, **exécuté** |
| `scripts/firewall_transition_generic_node.ps1` | créé — rollback automatique intégré, **exécuté** |
| `scripts/rollback_storage_agent.ps1` | créé — **non exécuté** (aucun échec à annuler) |
| `services/storage-agent/winsw/HomeSpotifyStorageAgent.xml` | créé — XML actif, sans secret |
| `services/storage-agent/src/main.ts` | modifié — une ligne (§2.4) |
| `docs/VPS_PHASE3_STORAGE_AGENT_DEPLOYMENT.md` | ce document |
| `docs/VPS_PHASE4_REMOTE_STORAGE_PROVIDER_PLAN.md` | plan de la phase suivante |
| `TECH_DECISIONS.md` | `TD-Phase3-Storage-Agent-Deployment` |
| `LESSONS.md` | L-092 à L-097 |

Hors dépôt : `C:\ProgramData\HomeSpotify\StorageAgent\**`,
`F:\dev\homespotify\storage\phase3-backup-20260726-113150\` et
`C:\ProgramData\HomeSpotify\StorageAgent\backup\firewall-20260726-135201\`.

**Aucun commit n'a été créé. Aucune commande Git destructive n'a été employée.**

---

## 17. À vérifier

Points tranchés depuis la première rédaction : compte administrateur
(`rtuyi`, membre du groupe après correction par le propriétaire) · accès SSH
(`debian@135.125.101.79`) · bascule vers le compte virtuel (aboutie, L-096) ·
dépendance WinSW avec `$` (non enregistrée par WinSW, posée par `sc.exe`,
L-097) · accès LAN direct au port 3000 (aucun client concerné, arbitré par le
propriétaire).

Restent ouverts :

1. **Comportement au premier redémarrage machine** — l'ordre
   tunnel WireGuard → Storage Agent n'a jamais été observé en conditions
   réelles. À surveiller au prochain reboot.
2. **Le seuil exact d'espace disque** attendu par le contrôle de santé du
   backend, et la confirmation du retour à 437/437 (§11).
3. **La rotation du secret partagé** : aucune procédure n'existe encore pour
   le renouveler des deux côtés sans coupure. À traiter avec la Phase 4, qui
   fera du backend le second porteur du secret.
4. **La synchronisation automatique de l'index** (§15, point 6).

---

## 18. Journal d'exécution finale — 2026-07-26

Toutes les opérations système ont été exécutées par le propriétaire depuis une
console PowerShell élevée, sur la base des scripts de ce dépôt. Les états
avant/après ont été relevés indépendamment.

### 18.1 Installation du service

Deux passes ont été nécessaires.

**Passe 1 — interrompue à l'étape d'identité.** `Win32_Service.Change` avec
`StartPassword = ''` a retourné le **code 22**. Le script s'est arrêté avant
d'appliquer la moindre ACL, avant de créer la moindre règle, et sans démarrer
le service — le comportement attendu. Le propriétaire a appliqué la forme
correcte à la main :

```
sc.exe config HomeSpotifyStorageAgent obj= "NT SERVICE\HomeSpotifyStorageAgent"
```

Le script a été corrigé en conséquence, et rendu **idempotent et reprenable** :
un service existant qui pointe sur le bon binaire est adopté, jamais réinstallé
ni supprimé ; chaque étape constate l'état avant d'agir ; une **barrière de
validation des ACL** précède désormais tout démarrage.

**Passe 2 — succès complet.**

| Contrôle | Résultat |
| --- | --- |
| Service | `Running` |
| WinSW / Node | PID 35196 / PID 21416 |
| Identité | `NT SERVICE\HomeSpotifyStorageAgent` |
| SID de service | `UNRESTRICTED` |
| Démarrage | `AUTO_START (DELAYED)` |
| Dépendances (registre) | `Tcpip`, `WireGuardTunnel$HomeSpotify-VPS` |
| Bind | `10.8.0.2:3100` uniquement, aucun `0.0.0.0` |
| 3100 sur LAN / Wi-Fi / Radmin / loopback | injoignable partout |
| ACL | validées objet par objet, aucune écriture sur la bibliothèque, aucun droit sur la base SQLite |
| Règles pare-feu | 3000 et 3100 créées, profil Public, distant `10.8.0.1` |
| Index chargé | `entryCount = 158` |
| `HomeSpotifyApi` | `Running`, PID **16948** inchangé |
| Domaine public | 200 |

### 18.2 Validation depuis le VPS

Script copié sur `debian@135.125.101.79`. Secret poussé **directement dans le
tunnel SSH**, sans jamais être rendu à l'écran ni passer par la ligne de
commande, écrit en `umask 077` puis `chmod 600`.

| Contrôle | Résultat |
| --- | --- |
| Fichier de secret | mode **600**, 66 octets (64 hex + CRLF, retiré par le script) |
| Empreinte du secret | **`46c7cfc6611f4a7c`** — concordante avec le PC |
| `/health` signé | 200, `healthy`, 158 entrées |
| HEAD signé | 200, corps vide |
| GET `Range: bytes=0-1023` | **206** |
| Range suffixe | **206** |
| Range insatisfaisable | **416** |
| Sans signature | **401 `AUTH_MISSING`** |
| Signature invalide | **401 `AUTH_INVALID`** |
| Rejeu du nonce | **401 `AUTH_REPLAY`** |
| Latence moyenne VPS → agent | **43,8 ms** |
| Bilan | **23 contrôles OK, 0 échec** |

Nettoyage vérifié : fichier de secret effacé, aucune occurrence dans
`~/.bash_history`. Le script Python, qui ne contient aucun secret, a été laissé
sur le VPS.

Le journal de l'agent porte la trace de ces requêtes sous forme d'événements
`STORAGE_AGENT_REQUEST_*` avec `route` en libellé logique — aucune URL brute,
aucun chemin, aucun nom de fichier, `err.log` à 0 octet.

### 18.3 Transition du pare-feu

Ciblage **structurel** — programme `node.exe`, `LocalPort = Any`,
`RemoteAddress = Any` — et non par libellé. Deux règles retenues, quatre
épargnées.

```
CIBLEE   Node.js JavaScript Runtime  TCP  ports=Any  Private, Public
         TCP Query User{526CE3ED-2C4F-4F76-B918-7BDA34405974}C:\program files\nodejs\node.exe
CIBLEE   Node.js JavaScript Runtime  UDP  ports=Any  Private, Public
         UDP Query User{D77F8514-50C0-48B1-967A-9BB1CFBF3457}C:\program files\nodejs\node.exe

EPARGNEE HomeSpotify-API-3000-WireGuard-VPS            ports=3000  distant=10.8.0.1
EPARGNEE HomeSpotify-StorageAgent-3100-WireGuard-VPS   ports=3100  distant=10.8.0.1
EPARGNEE HomeSpotify API 3000                          programme=Any
EPARGNEE HomeSpotify API via WireGuard                 programme=Any
```

Ligne de base relevée juste avant, à 13:52:10 : `HomeSpotifyApi` PID 16948,
agent `Running`, `127.0.0.1:3000` 200 en 43 ms, `10.8.0.2:3000` 200 en 8 ms,
domaine public 200 en 125 ms.

Les dix contrôles post-désactivation sont **tous passés du premier coup** :
domaine public 200 sur 5/5 sondes, backend local 200, backend WireGuard 200,
agent `Running`, listener unique `10.8.0.2:3100`, règles précises 3000 et 3100
toujours actives, deux règles génériques désactivées, `HomeSpotifyApi`
`Running` avec PID 16948 inchangé. **Aucun rollback déclenché.**

### 18.4 État final vérifié — 13:55:24

| Règle | Actif | Profil |
| --- | --- | --- |
| `Node.js JavaScript Runtime` (TCP) | **False** | Private, Public |
| `Node.js JavaScript Runtime` (UDP) | **False** | Private, Public |
| `HomeSpotify-API-3000-WireGuard-VPS` | True | Public |
| `HomeSpotify-StorageAgent-3100-WireGuard-VPS` | True | Public |
| `HomeSpotify API via WireGuard` (préexistante) | True | Any |
| `HomeSpotify API 3000` (préexistante) | True | Private |
| `WireGuard - Ping depuis VPS` (préexistante) | True | Any |

```
HomeSpotifyApi           Running  LocalSystem                         PID 16948
HomeSpotifyStorageAgent  Running  NT SERVICE\HomeSpotifyStorageAgent  PID 35196
WireGuardTunnel$HomeSpotify-VPS   Running  LocalSystem                PID  4564

TCP  0.0.0.0:3000    LISTENING  13888
TCP  10.8.0.2:3100   LISTENING  21416

127.0.0.1:3000            200 ( 40 ms)
10.8.0.2:3000             200 (  8 ms)
music.romainbegot.fr      200 (153 ms)

C: 32,64 Go libres     F: 136,95 Go libres
```

### 18.5 Confirmations de clôture

- **Aucun secret exposé** : ni dans un journal, ni dans un script, ni dans un
  rapport, ni dans ce document. Seule l'empreinte non réversible
  `46c7cfc6611f4a7c` circule.
- **Caddy et WireGuard inchangés** : aucune commande ne les a visés.
- **`HomeSpotifyApi` jamais redémarré** : PID 16948 du début à la fin.
- **`AUDIO_STORAGE_MODE` inchangé** (`local`).
- **Aucun fichier audio, aucune base de données modifiés.**
- **Aucun commit créé**, aucune commande Git destructive employée.

---

## 19. VALIDATION POST-REDÉMARRAGE — 2026-07-26

**Verdict définitif : GO.** Le propriétaire confirme les validations manuelles
complémentaires ; la Phase 3 et son redémarrage sont clos.

| Contrôle | Résultat |
| --- | --- |
| Ordre | WireGuard → HomeSpotifyApi → HomeSpotifyStorageAgent |
| Services | trois services `Running`, démarrage automatique |
| Identité agent | `NT SERVICE\HomeSpotifyStorageAgent` |
| Dépendances registre | `Tcpip`, `WireGuardTunnel$HomeSpotify-VPS` |
| Listener agent | uniquement `10.8.0.2:3100` |
| API | `0.0.0.0:3000`, inchangée |
| Pare-feu | règles précises 3000/3100 actives ; génériques Node désactivées |
| Health | localhost 200 ; WireGuard 200 ; domaine public stable 200 |
| Tunnel | 10/10 pings, 0 % de perte |
| Index | 158 entrées |
| Journaux | un démarrage post-reboot, aucune boucle, aucune fuite |
| Tests agent | 147/147 |
| Tests API | 437/437 |
| Typechecks / builds | verts |
| Smoke VPS | 23/23, 0 échec, latence ≈ 44 ms |
| HMAC / HEAD / Range / rejeu / IP | validés |
| Mobile / ACL | validations manuelles déclarées satisfaisantes |

`AUDIO_STORAGE_MODE` reste `local`. Aucun service n'a été redémarré pendant la
validation, aucun changement Caddy/WireGuard/base/audio et aucun commit.
