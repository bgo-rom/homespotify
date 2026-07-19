# Activité d’écoute — Phase 3B

## Architecture

HomeSpotify utilise une architecture hybride :

- `play_events` reste le signal historique minimal utilisé par les recommandations existantes ;
- `listening_sessions` stocke l’agrégat fiable d’une écoute ;
- `listening_events` conserve les événements détaillés et idempotents ;
- Flutter écrit d’abord chaque événement dans une file SQLite locale avant tout envoi réseau.

Le tracker observe les streams publics de `HomeSpotifyAudioHandler`, mais ne possède aucune commande de lecture. Il ne peut ni mettre en pause, ni remplacer la queue, ni modifier une source audio. Une erreur de stockage ou de réseau est capturée et reportée en diagnostic sans remonter au lecteur.

## Sessions et événements

Une session est identifiée par un UUID client unique pour un utilisateur. Une reconstruction de source après renouvellement du Bearer conserve cet UUID. Une fin naturelle clôt la session avec `PLAY_COMPLETED`; un changement de piste avant la fin produit `PLAY_SKIPPED`; une erreur définitive produit `PLAY_ERROR`. En repeat-one, chaque nouvelle lecture après une fin naturelle crée une nouvelle session.

Événements acceptés : `PLAY_STARTED`, `PLAY_RESUMED`, `PLAY_PROGRESS`, `PLAY_PAUSED`, `PLAY_SEEKED`, `PLAY_COMPLETED`, `PLAY_SKIPPED`, `PLAY_STOPPED`, `PLAY_ERROR` et `TRACK_CHANGED`.

Un heartbeat `PLAY_PROGRESS` est généré toutes les 30 secondes de lecture active. Une progression est aussi conservée à la mise en arrière-plan. Aucun événement n’est généré toutes les secondes.

## Durée réellement écoutée

`listenedMs` est cumulée côté Flutter avec une horloge monotone uniquement lorsque la piste est réellement en lecture. Elle ne dépend jamais de `position finale - position initiale`, donc un seek ne gonfle pas la durée. Le backend conserve le maximum cumulatif reçu pour une session : un retry ou un lot désordonné ne peut pas additionner deux fois le même intervalle.

Une écoute est qualifiée lorsque :

```text
listenedMs >= min(30 000 ms, 50 % de la durée)
```

Une complétion est enregistrée lors d’une fin naturelle signalée par le lecteur. Une session située à 90 % ou plus n’est pas proposée à la reprise. Un skip rapide ne devient jamais un `DISLIKE`.

## API et confidentialité

- `POST /api/play-events/batch` : lot transactionnel de 50 événements maximum ;
- `GET /api/me/listening-activity` : historique paginé par curseur ;
- `GET /api/me/resume-listening` : pistes inachevées pertinentes des 30 derniers jours ;
- `GET /api/me/tracks/:id/listening-state` : agrégats privés d’une piste ;
- `DELETE /api/me/listening-activity` : suppression des sessions et événements du compte courant.

Le `userId` vient exclusivement du Bearer. Un `userId` éventuellement injecté dans un payload est ignoré. Les identifiants d’installation sont des UUID aléatoires, sans Android ID, IMEI, MAC ou numéro de série. Aucun token, chemin physique ni adresse IP complète n’est stocké dans l’activité.

## File hors ligne

La file `pending_listening_events` est partitionnée localement par utilisateur. Le `userId` local ne fait pas partie du payload envoyé. Les événements sont supprimés uniquement après une réponse serveur acceptée. Le retry utilise un backoff exponentiel borné à cinq minutes. La file est limitée à 1 000 événements par compte ; les anciennes progressions redondantes sont compactées en premier, tandis que les démarrages et complétions sont préservés en priorité.

## Recommandations

Le profil de goût additionne désormais les anciennes entrées `play_events` et les nouvelles sessions qualifiées. Les sessions non qualifiées et skips rapides n’apportent aucun poids positif ou négatif. Les actions explicites Discover (`DISLIKE`, `LIKE`, etc.) restent dans leur modèle séparé.

## Migration

`0016_listening_activity.sql` est additive, utilise `CREATE TABLE/INDEX IF NOT EXISTS` et ne déplace ni ne modifie aucun fichier musical. Elle doit être appliquée par le migrateur HomeSpotify au déploiement ; elle n’a pas été appliquée directement à la base de production pendant le développement.

## Procédure de test téléphone

1. Lire une piste plus de 30 secondes puis la mettre en pause.
2. Ouvrir **Paramètres → Activité d’écoute** et vérifier la durée/position.
3. Fermer puis rouvrir l’application et reprendre la piste.
4. Terminer une piste, puis passer rapidement une autre piste et vérifier `terminé` contre `ignoré`.
5. Couper Internet, écouter quelques pistes, rétablir Internet et vérifier l’envoi différé.
6. Laisser ensuite une queue jouer au moins 45 minutes, avec écran éteint et un renouvellement de session si possible.

## Limites à vérifier sur appareil réel

- exactitude des événements de seek selon les cadences Media3 réelles ;
- livraison du dernier événement si Android tue brutalement le processus avant la fin de l’écriture SQLite ;
- comportement longue durée après plusieurs renouvellements de token ;
- reprise après changement Wi-Fi/5G et après redémarrage Android.
