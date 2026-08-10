# Mise à jour automatique privée — Android

HomeSpotify n'est pas publié sur le Play Store. Ce document décrit le système
qui remplace la copie manuelle d'APK : le serveur publie ses propres releases,
l'application les détecte, les télécharge, les vérifie, puis **demande** à
Android de les installer.

Aucune protection Android n'est contournée. La dernière étape est toujours
l'installateur du système, avec sa propre confirmation.

---

## 1. Architecture

```text
Poste de développement (Windows)                VPS (Debian)
────────────────────────────────                ─────────────────────────────
scripts/publish_android_update.ps1
  ├─ flutter analyze / flutter test
  ├─ versionCode = max(publié, réservé) + 1
  ├─ flutter build apk --release
  ├─ aapt2      → packageName, versionCode
  ├─ apksigner  → empreinte du certificat  ─┐
  ├─ SHA-256 + taille                       │ tout écart ⇒ ABORT
  └─ scp APK + manifeste ──────────────────►│
                                            ▼
                        scripts/android-update/vps_publish_android_update.sh
                          ├─ revalide taille + SHA-256 + entête ZIP
                          ├─ refuse un versionCode ≤ publié
                          ├─ mv -T  releases/homespotify-<vc>.apk
                          ├─ mv -T  metadata/<vc>.json
                          └─ mv -T  latest.json          ← EN DERNIER
                                            │
                                            ▼
                        API HomeSpotify (services/api)
                          GET /api/app-update/android/latest
                          GET /api/app-update/android/download/<versionCode>
                                            │
                                            ▼
Téléphone ─────────────────────────────────────────────────────────────────
  AppUpdateShell      démarrage + retour au premier plan (throttlé 30 min)
      │
      ▼
  AppUpdateController   idle → checking → available → downloading → verifying
      │                 → readyToInstall → (permissionRequired) → installing
      ▼
  AppUpdateService      taille + SHA-256 + packageName + versionCode + certificat
      │                 un seul écart ⇒ APK supprimée, installateur jamais ouvert
      ▼
  MainActivity (Kotlin) FileProvider → Intent.ACTION_VIEW → installateur Android
```

Le manifeste est un simple fichier sur disque : rien à migrer, rollback trivial,
aucune table SQL.

---

## 2. Signature Android — l'invariant du projet

Android refuse d'installer une mise à jour signée avec un autre certificat que
l'application déjà installée. **L'identité de signature est donc un invariant :
elle ne doit jamais changer**, sous peine d'imposer une désinstallation (et la
perte de la session, des préférences, du cache et de la base locale).

| | Valeur |
|---|---|
| `applicationId` | `com.homespotify.homespotify_mobile` |
| Sujet du certificat | `C=US, O=Android, CN=Android Debug` |
| Empreinte SHA-256 | `9d461189865d0d1f3774ae06a4bbf84f13c890c471b3e8d2082887006a5a78d6` |
| Empreinte SHA-1 | `0e9673b4ab9e96a923f24a94ec6f8f14429272e2` |
| Algorithme | SHA256withRSA, clé RSA 2048 bits |
| Validité | jusqu'au **30 juin 2056** |
| Schéma de signature | APK Signature Scheme v2 (minSdk 24) |

### Décision : conserver ce certificat (option A)

Le certificat provient de la keystore de débogage de la machine de
développement. C'est techniquement une clé de debug, mais elle est **valide
30 ans, en RSA 2048/SHA-256** : rien ne la rend inapte à signer une application
privée qui n'est distribuée nulle part.

En changer aurait imposé une désinstallation/réinstallation manuelle avec perte
de données locales — un coût réel, pour un bénéfice nul dans ce contexte. La
fragilité réelle n'était pas la clé elle-même mais son **emplacement** : un
fichier régénérable par Android Studio. Elle a donc été copiée hors de portée :

```text
F:\dev\homespotify-secrets\android\
  ├── homespotify-release.jks    ← la keystore, hors de TOUT arbre Git
  ├── key.properties             ← chemin + mots de passe
  └── publish-state.json         ← dernier versionCode construit localement
```

Ce dossier n'est dans aucun dépôt : aucun `git add -A`, sur aucune branche ni
aucun worktree, ne peut l'emporter par accident.

### Sauvegarde — à faire une fois

Copier `homespotify-release.jks` **et** `key.properties` sur un support hors
ligne. Sans eux, plus aucune mise à jour ne pourra s'installer par-dessus
l'application existante ; il faudrait repartir d'une désinstallation.

### Câblage Gradle

`android/app/build.gradle.kts` résout le fichier de propriétés dans cet ordre :

1. `HOMESPOTIFY_ANDROID_KEY_PROPERTIES` (variable d'environnement ou propriété
   Gradle) — c'est ce que positionne le script de publication ;
2. `android/key.properties` (ignoré par Git) ;
3. aucun des deux : repli sur la clé debug, pour que `flutter run --release`
   reste possible sur une machine sans secret.

La garantie n'est pas dans Gradle mais dans le script : **l'empreinte du
certificat de l'APK produite est comparée à la valeur attendue, et une
divergence interrompt la publication** (fail-closed).

---

## 3. Versioning

- `versionName` — lisible (`1.0.0`), lu depuis `pubspec.yaml` ou passé au script.
- `versionCode` — **strictement croissant**, seule référence de comparaison
  Android.

`pubspec.yaml` n'est plus édité à la main : le script passe
`--build-name` / `--build-number` à `flutter build apk`.

Le prochain numéro vaut `max(versionCode publié, dernier versionCode construit
localement) + 1`. La source de vérité **préférée est le serveur** ; le journal
local `publish-state.json` évite seulement qu'une build non publiée voie son
numéro réattribué à une autre build.

Trois garde-fous, tous fail-closed :

1. le script refuse un `versionCode ≤ celui publié` ;
2. le script refuse un `versionCode` déjà construit localement ;
3. le serveur refuse un `versionCode ≤ celui publié` **et** refuse d'écraser une
   release déjà présente.

---

## 4. Stockage sur le VPS

```text
/var/lib/homespotify-shadow/mobile-updates/android/
├── releases/
│   ├── homespotify-10.apk
│   └── homespotify-11.apk
├── metadata/
│   ├── 10.json
│   └── 11.json
└── latest.json          ← copie du metadata de la version publiée
```

`/var/lib/homespotify-shadow` est la **seule racine inscriptible** du service
(`ReadWritePaths` de l'unité systemd) et survit à chaque release backend. Les
APK ne sont surtout pas dans `/opt/homespotify-api-shadow/current`, qui change
à chaque déploiement.

Les anciennes APK sont conservées : diagnostic, et téléchargement direct d'une
version précise par son numéro.

---

## 5. API

### `GET /api/app-update/android/latest?currentVersionCode=<n>`

```json
{
  "updateAvailable": true,
  "latest": {
    "platform": "android",
    "packageName": "com.homespotify.homespotify_mobile",
    "versionCode": 11,
    "versionName": "1.0.0",
    "required": false,
    "minSupportedVersionCode": 1,
    "sizeBytes": 63457251,
    "sha256": "…",
    "signingCertSha256": "…",
    "releaseNotes": ["…"],
    "publishedAt": "2026-08-10T…",
    "downloadPath": "/api/app-update/android/download/11"
  }
}
```

- aucune publication → `200 {"updateAvailable": false, "latest": null}` ;
- service non configuré (`APP_UPDATE_ANDROID_DIR` absent) → `503` ;
- manifeste illisible → `500 manifest_invalid` (jamais un manifeste partiel).

### `GET /api/app-update/android/download/<versionCode>`

`application/vnd.android.package-archive`, `Content-Length`, `Accept-Ranges`,
ETag = SHA-256, `Range` géré (206/416).

**Le client n'envoie jamais de chemin.** Le seul paramètre est un entier ; le
nom de fichier est reconstruit côté serveur (`homespotify-<n>.apk`) et la
version doit exister au catalogue. `?path=…`, `../`, `11.apk` et les variantes
encodées sont refusés par construction.

Taille sur disque ≠ taille du manifeste → `500 release_corrupted`, aucun octet
servi.

### Authentification : ces deux routes sont publiques

C'est une décision, pas un oubli. Une version peut être obsolète **précisément
parce que** son format de jeton ou son contrat d'API n'est plus compatible :
exiger une session valide rendrait la mise à jour impossible dans le seul cas
où elle est indispensable.

Ce qui est exposé, c'est le manifeste de l'APK HomeSpotify et cette APK —
c'est-à-dire exactement ce que le propriétaire copiait auparavant à la main.
Aucune donnée utilisateur, aucun identifiant, aucun chemin serveur. Le reste de
l'API continue d'exiger un Bearer.

---

## 6. Publier

```powershell
./scripts/publish_android_update.ps1 -ReleaseNotes 'Recherche Deezer','Corrections du lecteur'
```

Étapes, dans l'ordre, toutes bloquantes :

1. worktree Git propre (sinon `-AllowDirty`) ;
2. `flutter pub get`, `flutter analyze`, `flutter test` ;
3. `versionCode` suivant ;
4. `flutter build apk --release` avec la keystore HomeSpotify ;
5. `aapt2` : `packageName`, `versionCode`, `versionName` de l'APK réelle ;
6. `apksigner` : empreinte du certificat comparée à la valeur attendue ;
7. SHA-256 + taille, écriture du manifeste ;
8. `scp` vers `/tmp`, publication atomique côté serveur ;
9. relecture de `latest.json` publié + `Range` de 1 Ko sur le téléchargement.

Options utiles :

| Option | Effet |
|---|---|
| `-BuildOnly` | construit et vérifie l'APK, ne publie rien (le numéro reste réservé) |
| `-Required` | `required: true` — l'application n'offre pas « Plus tard » |
| `-MinSupportedVersionCode <n>` | rend obsolète toute version antérieure |
| `-VersionName 1.1.0` | change le nom lisible |
| `-AllowDirty` | tolère un worktree sale (à éviter : l'APK ne correspond plus à un commit) |

---

## 7. Côté application

| Élément | Rôle |
|---|---|
| `core/platform/app_package_info.dart` | version installée, lue du paquet réel |
| `core/platform/app_update_installer.dart` | canal natif : permission, inspection APK, installation |
| `features/app_update/data/app_update_api.dart` | client HTTP **sans intercepteur d'auth** |
| `features/app_update/application/app_update_service.dart` | check / download / verify / requestInstall |
| `features/app_update/application/app_update_controller.dart` | machine à états + throttling |
| `features/app_update/presentation/app_update_shell.dart` | superposition, cycle de vie |
| `features/settings/presentation/settings_screen.dart` | section « Mise à jour » |

Vérifications avant d'ouvrir l'installateur : taille, SHA-256, puis identité
lue **dans l'archive** (`PackageManager.getPackageArchiveInfo`) — nom de paquet,
`versionCode`, empreinte du certificat. Un seul écart supprime le fichier et
l'installateur n'est jamais ouvert.

Quand vérifier : au démarrage, au retour au premier plan (au plus une fois
toutes les 30 minutes), et à la demande depuis Paramètres (sans throttling).

**Le service de mise à jour ne peut jamais empêcher HomeSpotify de démarrer.**
Serveur injoignable, DNS mort, JSON invalide, délai dépassé : la vérification
automatique échoue en silence et l'application se monte normalement. Une erreur
n'est affichée que si l'utilisateur a lui-même demandé la vérification.

---

## 8. Installation par-dessus l'application existante

Trois conditions, toutes vérifiées avant l'installateur :

1. même `applicationId` ;
2. même certificat de signature ;
3. `versionCode` strictement supérieur.

Elles étant réunies, Android met à jour **sans désinstaller** : session,
préférences, base locale et cache hors ligne sont conservés.

### Autorisation « Installer des applications inconnues »

`REQUEST_INSTALL_PACKAGES` ne suffit pas : Android exige que l'utilisateur
désigne explicitement HomeSpotify comme source autorisée. Si
`canRequestPackageInstalls()` est `false`, l'application explique la situation
et ouvre `Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES` positionné sur
HomeSpotify. Au retour au premier plan, l'installation reprend automatiquement
si l'autorisation a été accordée.

---

## 9. Rollback

**Android n'accepte pas un `versionCode` inférieur.** Republier une ancienne
APK telle quelle ne remettrait donc rien en état sur le téléphone.

Le rollback correct :

```text
revenir au code de la version saine
→ rebuild avec un versionCode SUPÉRIEUR
→ publier
```

Concrètement :

```powershell
git checkout <commit-sain>
./scripts/publish_android_update.ps1 -ReleaseNotes 'Retour à la version précédente'
```

Les anciennes APK restent au catalogue et téléchargeables par leur numéro :
c'est utile pour comparer ou diagnostiquer, jamais pour redescendre une version
sur un téléphone.

---

## 10. Bootstrap

La toute première APK contenant l'updater doit être installée **à la main** :
la version installée avant elle n'a aucun moyen de se mettre à jour. C'est la
dernière copie manuelle.

Après elle, une version supérieure est publiée sur le serveur, et
l'application propose la mise à jour à l'ouverture.

---

## 11. Dépannage

| Symptôme | Cause probable | Action |
|---|---|---|
| « Signature inattendue : mise à jour rejetée » | l'APK n'a pas été signée avec la keystore HomeSpotify | vérifier `key.properties` et relancer ; ne jamais publier une APK au certificat divergent |
| L'installateur Android ne s'ouvre pas | HomeSpotify n'est pas source autorisée | bouton « Ouvrir les réglages Android » de l'assistant |
| « L'application n'est pas installée » (écran Android) | certificat ou `applicationId` différents | comparer `apksigner verify --print-certs` avec l'empreinte de référence |
| `503 update_service_unconfigured` | `APP_UPDATE_ANDROID_DIR` absent de l'environnement du service | ajouter la variable et redémarrer le service |
| `500 release_corrupted` | APK et manifeste désynchronisés | republier ; ne pas éditer `latest.json` à la main |
| Le script refuse le `versionCode` | numéro déjà publié ou déjà construit | laisser le script choisir (ne pas forcer `-VersionCode`) |
| Aucune mise à jour proposée alors qu'une version est publiée | throttling de 30 minutes | Paramètres → « Rechercher une mise à jour » |
