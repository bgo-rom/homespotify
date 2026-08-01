# Smoke test Lucida / HomeSpotify

Ce script vérifie le flux réel suivant :

1. connexion JWT ;
2. recherche distante ;
3. création facultative d'un job ;
4. suivi jusqu'à un statut terminal ;
5. validation de `finalTrackId` lorsque le job est `COMPLETED`.

## Recherche seule

Depuis la racine du monorepo :

```powershell
.\tools\smoke\lucida-acquisition-smoke.ps1 `
  -Username owner `
  -Query "TITRE AUTORISÉ"
```

Le mot de passe est demandé sans être affiché. Aucun téléchargement n'est lancé.

## Test complet autorisé

Après avoir contrôlé l'index affiché :

```powershell
.\tools\smoke\lucida-acquisition-smoke.ps1 `
  -Username owner `
  -Query "TITRE AUTORISÉ" `
  -StartAcquisition `
  -ResultIndex 0
```

N'utilise le test complet que pour un contenu que tu possèdes ou es autorisé à
importer.

## Codes de sortie

- `0` : recherche validée ou import terminé ;
- `2` : aucun résultat ;
- `3` : acquisition/import en échec ;
- `4` : incohérence `COMPLETED` sans `finalTrackId` ;
- `5` : job annulé ;
- `6` : job interrompu ;
- `7` : délai global du smoke test dépassé.
