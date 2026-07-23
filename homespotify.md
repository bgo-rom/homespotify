# Règles HomeSpotify

## Sécurité

- Travailler uniquement dans le dossier HomeSpotify ouvert.
- Ne jamais lire ou afficher les fichiers .env.
- Ne jamais supprimer un dossier complet sans autorisation.
- Ne jamais modifier directement une base SQLite active.
- Ne jamais supprimer, déplacer ou convertir la bibliothèque musicale sans accord.
- Ne jamais exécuter git push, git reset --hard ou git clean.
- Ne jamais installer une dépendance sans expliquer son utilité.

## Méthode

- Analyser les fichiers concernés avant toute modification.
- Présenter un plan avant les modifications importantes.
- Attendre mon autorisation avant de modifier le projet.
- Faire des modifications petites et ciblées.
- Ne pas inventer de fichier, route, méthode, classe ou package.
- Vérifier les dépendances réellement installées.
- Donner la liste exacte des fichiers modifiés.
- Signaler toute incertitude.

## Backend

- Respecter l’architecture Fastify et SQLite existante.
- Préserver les routes API existantes.
- Préserver le streaming HTTP Range.
- Ne pas modifier les formats de données sans validation.
- Utiliser une transaction pour les écritures SQLite liées.
- Exécuter les tests disponibles.

## Flutter

- Respecter Riverpod, Dio, go_router, just_audio et audio_service.
- Préserver le lecteur, le mini-player et la file de lecture.
- Préserver les favoris et les playlists.
- Ne pas effectuer de changement visuel non demandé.
- Exécuter flutter analyze après les changements Dart.
- Exécuter flutter test lorsque pertinent.

## Validation

- Ne jamais prétendre qu’une commande a réussi sans lire son résultat.
- Afficher les erreurs et avertissements importants.
- Ne pas modifier des composants qui ne concernent pas la tâche.