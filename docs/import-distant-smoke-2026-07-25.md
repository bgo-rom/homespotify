# Validation réelle de l’import distant

Date : 25 juillet 2026
Environnement : Windows 11, service Windows HomeSpotifyApi
Utilisateur : rbego
Provider : Qobuz
Résultat : succès

## Parcours validé

- authentification JWT ;
- recherche distante réelle ;
- lancement de Python ;
- lancement de Playwright/Chromium ;
- téléchargement d’un contenu autorisé ;
- validation FLAC/WAV ;
- import local ;
- attribution à la bibliothèque utilisateur ;
- statut final COMPLETED ;
- finalTrackId présent ;
- lecture depuis l’application validée.

Aucun credential, cookie, chemin sensible ou token n’est consigné.