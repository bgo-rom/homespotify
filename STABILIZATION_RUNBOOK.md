# HomeSpotify — Runbook de stabilisation

## Objectif

Ce runbook couvre la persistance du lecteur, la reprise réseau, les sessions longues, la sauvegarde/restauration et la matrice de validation Android du lot Stabilisation.

## Session de lecture persistée

La session est enregistrée séparément pour chaque utilisateur :

- file d’attente, index et position ;
- répétition et lecture aléatoire ;
- vitesse active ;
- indication lecture/pause avant arrêt.

Les tokens Bearer ne sont jamais écrits dans cette sauvegarde. À la restauration, les sources sont reconstruites avec le token courant. Après un lancement manuel de l’application, la file et la position sont restaurées **en pause**. Une déconnexion explicite supprime la session persistée du compte.

Pendant une lecture active, le JWT court est renouvelé 90 secondes avant son expiration. Chaque rotation reconstruit immédiatement les sources Media3 avec le nouveau Bearer, sans changer de piste ni de position. Le refresh token ayant une expiration glissante à chaque rotation réussie, la session reste active sans durée maximale pratique tant que l'application continue de fonctionner, que le réseau revient après les coupures et que la session n'est pas révoquée côté serveur.

## Reprise réseau

- Une coupure temporaire ne déclenche plus le saut de plusieurs pistes.
- La piste et sa position sont conservées.
- Le lecteur retente sur retour de connectivité, puis avec un backoff plafonné à 30 secondes si le réseau semble disponible mais que le serveur reste inaccessible.
- Un 401 suit le circuit séparé de rotation du refresh token.
- Un fichier réellement absent ou invalide conserve la politique de saut borné existante.

## Sauvegarde

La sauvegarde standard contient :

- un snapshot SQLite en ligne créé par l’API native de `better-sqlite3` ;
- un `PRAGMA integrity_check` réussi ;
- une empreinte SHA-256 et un manifest versionné ;
- les pochettes ;
- aucun secret et, par défaut, aucun fichier audio.

Commande standard :

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\backup_homespotify.ps1
```

Sauvegarde complète sur un disque externe :

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\backup_homespotify.ps1 `
  -BackupRoot 'E:\HomeSpotifyBackups' `
  -IncludeMedia
```

Le dossier `backups/` du dépôt est ignoré par Git. Une sauvegarde locale sur le même disque ne protège pas d’une panne physique : au moins une copie complète doit vivre sur un autre support.

Les fichiers `.env`, clés et secrets ne sont volontairement pas inclus. Ils doivent être conservés séparément dans un coffre chiffré.

## Restauration

1. Arrêter le service API.
2. Choisir une sauvegarde dont le manifest et le SHA-256 seront vérifiés.
3. Exécuter la restauration avec la confirmation explicite.
4. Redémarrer le service et vérifier `/health` puis une lecture Range.

```powershell
Stop-Service -Name HomeSpotifyApi

powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\restore_homespotify.ps1 `
  -BackupPath 'E:\HomeSpotifyBackups\homespotify-20260721-220000' `
  -Confirm RESTORE `
  -RestoreMedia

Start-Service -Name HomeSpotifyApi
```

La base précédente est déplacée vers un fichier `.pre-restore-<date>` avant remplacement. Les pochettes et médias sont copiés sans supprimer les fichiers supplémentaires présents sur la cible.

## Matrice Android réelle obligatoire

À exécuter sur chaque modèle/ROM cible après installation de l’APK Release :

| Scénario | Durée | Résultat attendu |
|---|---:|---|
| Écran verrouillé, Wi-Fi stable | 4 h | Aucune pause, notification toujours présente |
| Application retirée de l’écran récent sans « Forcer l’arrêt » | 30 min | Lecture et contrôles multimédia actifs |
| Wi-Fi coupé puis 4G activée | 5 min | Reprise sur le même titre et à la même position |
| Mode avion 2 min puis retour réseau | 5 min | État d’attente explicite puis reprise automatique |
| Token d’accès expiré pendant lecture | 20 min minimum | Refresh transparent, aucun retour au login |
| Redémarrage de l’application | 2 min | File, position, vitesse, repeat/shuffle restaurés en pause |
| Casque Bluetooth déconnecté | 2 min | Pause immédiate, aucune sortie involontaire haut-parleur |
| Appel téléphonique / audio focus | 5 min | Pause puis reprise conforme au focus Android |
| Économie de batterie constructeur | 1 h | Notification et service présents, sinon documenter l’exception ROM |

Pour collecter les preuves :

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\collect_android_audio_diagnostics.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\collect_backend_audio_diagnostics.ps1
```

Joindre pour chaque échec : modèle, version Android, heure, réseau, piste, action effectuée et archive de diagnostic.

## Validation logicielle

```powershell
Push-Location services\api
pnpm.cmd test
pnpm.cmd typecheck
Pop-Location

Push-Location apps\mobile\homespotify_mobile
flutter analyze
flutter test
Pop-Location
```

Les validations physiques ne peuvent pas être remplacées par les tests unitaires : les politiques batterie et audio focus diffèrent selon les constructeurs.
