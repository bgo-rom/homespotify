# HomeSpotify — règles obligatoires

## Sécurité

- Ne jamais lire, afficher ou modifier les fichiers .env, clés, secrets ou mots de passe.
- Ne jamais lire ou modifier une base SQLite active sans autorisation explicite.
- Ne jamais parcourir les fichiers audio ou binaires.
- Ne jamais utiliser git reset --hard, git clean, force push ou une commande destructive.
- Ne jamais supprimer ou déplacer un fichier sans expliquer précisément pourquoi.
- Ne jamais travailler en dehors de la racine du dépôt.

## Méthode de travail

- Commencer par comprendre l’existant.
- Établir un plan avant toute modification.
- Ne modifier que les fichiers nécessaires à la tâche.
- Préserver l’architecture existante.
- Ne pas réécrire complètement un module lorsqu’une correction ciblée suffit.
- Après chaque modification, afficher un résumé clair des changements.
- Exécuter les tests ou vérifications adaptés après les modifications.
- Signaler explicitement toute incertitude.

## Backend

- Backend Fastify avec SQLite.
- Préserver le streaming audio HTTP Range.
- Préserver les endpoints existants et leur compatibilité.
- Utiliser des opérations SQLite transactionnelles lorsque plusieurs écritures sont liées.
- Valider les entrées et gérer proprement les erreurs.

## Flutter

- Préserver Riverpod, Dio, go_router, just_audio et audio_service.
- Respecter les providers et l’architecture actuelle.
- Éviter les contrôleurs ou références utilisés après leur destruction.
- Préserver le mini-player, le lecteur, les favoris et les playlists.

## Commandes

- Éviter les commandes récursives produisant des milliers de lignes.
- Ne jamais parcourir node_modules, build, .dart_tool ou les médias.
- Demander une autorisation avant toute installation de dépendance.