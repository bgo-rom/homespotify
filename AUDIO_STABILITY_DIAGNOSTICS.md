# Stabilité audio et diagnostic

État au 21 juillet 2026. Ce document décrit la correction locale et la procédure de validation. Aucun déploiement mobile, commit ou migration de production n'a été effectué.

## Diagnostic factuel

La cause déjà prouvée de l'arrêt vers 15 minutes reste celle de L-047 : les `AudioSource` conservaient un Bearer expiré, le fork Android tronquait la cause HTTP 401 et la récupération n'était autorisée qu'une fois par file. Cette chaîne était corrigée avant cette passe, mais elle manquait encore de preuves persistantes et de protection contre des callbacks concurrents.

Cette passe a établi quatre faits supplémentaires :

1. La configuration de chargement imposait `2 500 ms` avant lecture et `5 000 ms` après rebuffer, avec une fenêtre `30–120 s`. Elle créait un plancher de latence inutilement élevé.
2. Une même panne native pouvait arriver par deux chemins asynchrones et lancer plusieurs reconstructions de file en parallèle.
3. Les logs réels du service contiennent deux `stream closed prematurely` sur cinq requêtes stream observées : une réponse 200 et une 206. Des requêtes voisines 200/206 terminent après environ 11–13 secondes. L'ancien format ne permet pas d'attribuer ces deux fermetures au client, au réseau, au fichier ou au serveur.
4. Une session réelle `Back In Black` a atteint `position=duration=256000 ms`, puis est restée `ready/playing` plus de deux minutes sans `completed` ni changement d'index. Ce n'était pas une répétition : la timeline était figée à sa borne finale.

La correction rend les récupérations déterministes et produit désormais les éléments nécessaires pour trancher le troisième point lors d'une reproduction.

## Architecture retenue

### Mobile

- Un seul `HomeSpotifyAudioHandler`, un seul player Media3 et une seule file.
- Headers envoyés directement au serveur ; aucun proxy HTTP localhost de `just_audio`.
- Buffer : minimum 15 s, maximum 60 s, démarrage 750 ms, reprise 1 500 ms.
- Préflight du token à moins de 90 secondes de l'expiration, puis récupération réactive sur 401.
- Refresh auth single-flight ; reconstruction de toutes les sources avec les headers courants et reprise à l'index/position.
- Erreur non-401 single-flight, trois sauts consécutifs maximum et déduplication de deux signaux identiques pendant deux secondes.
- Auto-avance de secours unique sur `completed`, plus watchdog position/durée après deux secondes de fin figée en `ready/playing`, avec respect de repeat/shuffle.
- Événements de buffering, préparation, lecture, transition, seek, lifecycle, connectivité, récupération et dispose.

Les seuils de buffer sont une décision temporaire à valider en Wi-Fi et 5G. Le code ne promet pas qu'un réseau ou un téléphone lent démarrera en 750 ms.

### Frontière Android / Media3

Le fork propage une chaîne de causes bornée et ajoute des détails structurés sûrs : classe, code Media3, statut HTTP quand connu, type de source, hôte, classes de causes, index, position, buffer et caractère retryable. Les messages Logcat caviardent Bearer et URL ; les transitions Media3, changements de média, états et erreurs ont un événement stable.

### Backend

`GET /api/tracks/:id/stream` et `/download` gardent le même flux fichier et la même sémantique Range 200/206/416. Un `X-Request-Id` valide est propagé ; une valeur injectée ou trop longue est remplacée. Les événements suivants partagent cet identifiant :

- `STREAM_REQUEST_RECEIVED`, `STREAM_AUTH_*`, `STREAM_FILE_STAT_*` ;
- `STREAM_RANGE_*`, `STREAM_FILE_OPEN_*`, `STREAM_RESPONSE_HEADERS_SENT` ;
- `STREAM_FIRST_CHUNK_SENT`, `STREAM_COMPLETED` ;
- `STREAM_ABORTED`, `STREAM_CLIENT_DISCONNECTED`, `STREAM_FILE_ERROR`.

Une requête ne journalise qu'un seul événement terminal. Les logs ne contiennent ni Bearer, ni chemin audio absolu, ni query sensible.

## Journal mobile

Le diagnostic normal est disponible en debug ou avec `HOMESPOTIFY_AUDIO_DIAGNOSTICS=true`. Il conserve 2 000 événements en mémoire et cinq fichiers JSON Lines de 5 Mo. La trace, disponible seulement avec `HOMESPOTIFY_AUDIO_TRACE_AVAILABLE=true`, conserve 8 000 événements en mémoire, dix fichiers de 10 Mo et s'arrête après 15 minutes par défaut. Les écritures sont groupées toutes les 750 ms et ne sont jamais attendues par le chemin critique audio.

Chaque événement peut porter `appSessionId`, `playbackSessionId`, `queueRevisionId`, `sourceInstanceId`, `requestId`, `recoveryAttemptId`, index, trackId, position et durées monotones. Les valeurs sensibles sont caviardées avant la mémoire et avant le disque.

L'écran `/dev/audio-diagnostics`, réservé à OWNER ou au debug, expose l'état courant, les compteurs, la dernière erreur/récupération et les actions suivantes : activer le diagnostic, activer/désactiver la trace, marquer un problème, exporter, copier le résumé, effacer et lancer le test guidé.

## Collecte

Depuis la racine du dépôt :

```powershell
.\scripts\collect_android_audio_diagnostics.ps1 -ClearLogcat
```

Le script exige exactement un appareil ADB et produit des captures main/system/crash, un filtre HomeSpotify/ExoPlayer/Android/réseau et un snapshot device-idle/connectivité sous `diagnostics/android`.

Dans une autre console :

```powershell
.\scripts\collect_backend_audio_diagnostics.ps1
```

Le script suit les trois logs du service sans le redémarrer, extrait `STREAM_*`, requestId, 401/403/416, Range, timeout, reset, abort et erreurs, puis écrit sous `diagnostics/backend`. Arrêt propre par `Ctrl+C`.

## Validation automatisée effectuée

- Backend : 26 fichiers, 285 tests réussis ; `typecheck` et build TypeScript réussis.
- Streaming ciblé : 26 tests réussis, incluant 200/206/416, Range ouvert/suffixe, FLAC exact, téléchargement et requestId sûr.
- Flutter : `flutter analyze` sans erreur ; 294 tests réussis.
- Harnais longue session : 12 scénarios, file de 200 pistes, trois expirations 401 successives, erreur 404, limite de sauts, remplacement de file, déduplication et auto-avance prématurée.
- Android `just_audio` : compilation Java réussie et 7 tests réussis, dont propagation/redaction/bornage de la cause native.
- Collecteurs PowerShell : parsing syntaxique réussi pour les deux scripts.
- APK release diagnostic : build réussi avec Signalsmith et les deux flags de diagnostic.

Le test Gradle global `testDebugUnitTest` reste inutilisable tel quel sous cette topologie Windows : certains plugins Pub sont sur `C:` et le build centralisé sur `F:`, ce qui fait échouer la création de leurs tâches de test avant exécution. Le module modifié `:just_audio:testDebugUnitTest` a été exécuté séparément avec succès.

## APK diagnostic

- Chemin : `apps/mobile/homespotify_mobile/build/app/outputs/flutter-apk/HomeSpotify-audio-stability-diagnostic.apk`
- Taille : 62 927 275 octets (60,0 Mo affichés par Flutter).
- SHA-256 : `92E2E2027DDF9D370874FC2C6BA6666B9E8E2DAAFB782A22DAF454B10C9D208A`
- Signature : schéma APK v2, certificat debug Android existant du projet (`CN=Android Debug`), aucune nouvelle clé créée.
- API : `https://music.romainbegot.fr`.
- Moteur : `signalsmith`.
- Flags : diagnostics normal et trace disponible.

La configuration release actuelle utilise la clé debug existante. Elle est stable pour `adb install -r` seulement si l'application déjà installée a été signée par ce même certificat ; ce n'est pas une signature de distribution production. Aucun appareil ADB n'était connecté pendant la livraison, donc l'installation n'a pas pu être exécutée.

Installation quand le téléphone apparaît dans `adb devices` :

```powershell
F:\Android\Sdk\platform-tools\adb.exe install -r "F:\dev\homespotify\apps\mobile\homespotify_mobile\build\app\outputs\flutter-apk\HomeSpotify-audio-stability-diagnostic.apk"
```

Ne pas désinstaller l'application : une erreur `INSTALL_FAILED_UPDATE_INCOMPATIBLE` signifie que la signature déjà installée est différente et doit être résolue sans effacer les données à l'aveugle.

## Test manuel guidé

1. Installer l'APK avec `adb install -r`.
2. Ouvrir Réglages → Diagnostic audio et activer le diagnostic normal.
3. Démarrer les deux scripts de collecte.
4. Lancer une playlist d'au moins 20 pistes ; noter l'heure du tap et du premier son.
5. Verrouiller l'écran et laisser lire au moins 60 minutes.
6. À toute coupure ou latence anormale, utiliser immédiatement « Marquer maintenant comme problème ».
7. Répéter en Wi-Fi, en 5G, puis avec une bascule Wi-Fi → 5G pendant la lecture.
8. Tester pause/reprise, seek, suivant/précédent, repeat-one, repeat-all et shuffle.
9. Tester écran éteint, retour au premier plan, notification média, débranchement casque et Bluetooth si disponible.
10. Laisser une session de plusieurs heures si possible afin de franchir au moins trois expirations de token.
11. Exporter le diagnostic mobile, arrêter les scripts par `Ctrl+C`, puis rapprocher les événements par requestId et heure UTC.

Critères d'acceptation : aucune coupure silencieuse ; chaque erreur a un terminal explicite ; une expiration réussie reprend la piste sans saut ; aucune double récupération ; `STREAM_FIRST_CHUNK_SENT` précède toute lecture ; un abandon client est distingué d'une erreur fichier ; aucun secret dans les exports.

## À vérifier

- Attribuer les deux fermetures prématurées historiques : impossible avec les anciens logs, possible seulement après reproduction avec le nouvel APK et le backend instrumenté déployé.
- Mesurer sur téléphone tap → lecture, tap → premier son, nombre/durée des rebufferings, CPU Signalsmith, stabilité Bluetooth et comportement batterie.
- Exécuter une session réelle multi-heures ; le harnais accéléré ne remplace pas le temps mural, le modem, Doze, l'audio focus ou le routage Bluetooth.
- Vérifier `adb install -r` sur l'application existante et confirmer que son certificat correspond.
- Le backend local modifié n'a pas été déployé et le service Windows n'a pas été redémarré.

## Session réelle du 22 juillet 2026

Capture à 13:17, sans redémarrage ni modification du téléphone pendant le test :

- fenêtre observée : 09:33–13:17, soit 3 h 43 ;
- 73 sessions, 69 pistes distinctes, 67 complétions, 2 skips et 1 erreur client ;
- 203 requêtes de streaming : 189 terminées et 14 abandonnées par le client ;
- 0 erreur `STREAM_*`, 0 HTTP 401, 0 HTTP 5xx et 0 refresh d'authentification ;
- 513 lots de télémétrie acceptés par l'API ;
- huit sessions ont dépassé leur durée de plus de cinq secondes, dont deux agrégats historiques restés `ACTIVE` ;
- à 1,30x, `Billie Jean` a atteint la fin logique puis sa position est revenue à zéro sans transition de média.

Conclusion : le backend, les fichiers, HTTP Range et le TTL de 24 h ne sont pas la cause. Les défauts se situaient dans le filet de fin de piste et dans la clôture best-effort du tracker. Le garde périodique, la détection fin→0 et l'invariant serveur d'une seule session courante ont été ajoutés. Validation ciblée : 27 tests Flutter et 9 tests backend réussis ; typecheck TypeScript réussi.

Aucun fichier musical personnel n'est inclus. Aucun secret n'est journalisé intentionnellement. Aucune commande Git destructive et aucun commit n'ont été utilisés.
