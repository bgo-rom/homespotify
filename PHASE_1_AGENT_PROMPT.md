# Prompt autonome — Démarrage correct de la Phase 1 HomeSpotify

Copier tout le bloc ci-dessous dans la nouvelle tâche IA.

---

Tu travailles sur le dépôt **HomeSpotify** situé dans
`F:\dev\homespotify` sous Windows/PowerShell.

## Mission

Fermer proprement le gate de stabilisation restant, puis commencer la nouvelle
**Phase 1A — verticale hors connexion complète sur une piste**. Ne traite pas
les albums/playlists tant que la verticale unitaire n'est pas entièrement
testée. Ne travaille sur aucune intégration SpotiFLAC ni acquisition audio
distante.

## Lecture obligatoire avant toute action

Lis entièrement, dans cet ordre :

1. `CLAUDE.md`
2. `PROJECT.md`
3. `TECH_DECISIONS.md`
4. `ARCHITECTURE.md`
5. `ROADMAP.md`
6. `AUDIO_SOURCING.md`
7. `AGENTS.md`
8. `LESSONS.md`
9. `MOBILE_ARCHITECTURE.md`
10. `AUDIO_STABILITY_DIAGNOSTICS.md`
11. `STABILIZATION_RUNBOOK.md`
12. `PRODUCT_AUDIT_AND_ROADMAP_2026-07-21.md` (rapport détaillé ; en cas de
    divergence sur l'état des phases, `ROADMAP.md` fait autorité)

Ensuite, inspecte `git status --short` et les diffs. Le worktree contient déjà
beaucoup de changements légitimes de l'utilisateur : ne réinitialise, ne
supprime et n'écrase rien. N'utilise jamais `git reset --hard`, `git checkout --`
ou une réécriture globale. Ne touche qu'aux fichiers nécessaires.

## Gate Phase 0 obligatoire

La Phase 0 n'est pas officiellement terminée au 2026-07-22. La session réelle
la plus récente a duré environ 3 h 43 et a révélé un retour fin→0 sur certaines
pistes. Le correctif est implémenté et testé localement, mais sa qualification
sur l'APK/backend réellement déployés pendant 4 h n'est pas encore prouvée.

Avant tout code Phase 1 :

1. Vérifie que les correctifs décrits dans `LESSONS.md` L-075 et
   `TD-Audio-2026-07-20` sont présents et que leurs tests passent.
2. Vérifie les preuves du gate dans `ROADMAP.md` : déploiement du correctif,
   session post-correctif de 4 h, absence de boucle/arrêt/sessions fantômes,
   restauration complète réelle et tableau OWNER sain.
3. Ne prétends jamais que le gate est validé à partir des seuls tests simulés.
4. Si une preuve runtime exige le téléphone ou une confirmation humaine encore
   absente, arrête-toi avant le code Phase 1, donne les commandes/procédures
   exactes et demande la preuve manquante. Tu peux analyser et préparer un plan,
   mais pas contourner le gate.

Une fois le gate objectivement réussi, marque son état dans `ROADMAP.md` avec la
preuve et commence Phase 1A.

## Décisions Phase 1 non négociables

- Trois profils visibles à chaque téléchargement :
  - `opus_128` : Ogg/Opus 128 kb/s VBR, économie, lossy ;
  - `opus_256` : Ogg/Opus 256 kb/s VBR, haute qualité compacte, recommandé,
    mais toujours lossy ;
  - `original` : copie exacte du WAV/FLAC canonique, qualité issue uniquement de
    l'analyse technique existante.
- Une taille Opus avant encodage est marquée **estimée** ; une variante prête et
  l'original exposent une taille **exacte**.
- Les Opus sont des dérivées. Ils ne remplacent, ne renomment, ne modifient et ne
  réécrivent jamais le WAV/FLAC source.
- Aucun transcodage sur le téléphone, aucun transcodage pendant une réponse HTTP.
- FFmpeg produit la dérivée côté serveur en tâche asynchrone, en flux, avec
  concurrence sobre et bornée. Le fichier temporaire n'est publié qu'après
  validation ffprobe, cohérence de durée, taille, SHA-256 et renommage atomique.
- Single-flight distinct par
  `(sourceSha256, profileVersion, encoderVersion)` : 128 et 256 ne partagent
  jamais la même identité.
- L'original réutilise la route Range canonique ; il ne doit pas être dupliqué
  dans le cache serveur des dérivées.
- Toutes les routes sont authentifiées et vérifient l'accès visible à la piste.
  Une variante physique peut être mutualisée, jamais son autorisation.
- Aucun fichier audio complet en RAM : streams, HTTP Range et hash streaming.
- Au retour du réseau, ne change jamais la source au milieu d'un titre. Le titre
  courant se termine, le prochain privilégie l'original sauf politique
  cellulaire explicite.
- SpotiFLAC, Lucida, fetch-node, scraping, API privée et téléchargement audio
  automatique depuis la recherche sont hors périmètre.

## Périmètre exact Phase 1A

### 1. Audit de l'existant et plan

- Localise les routes fichier/Range, le schéma Drizzle, les réparations de
  migrations, la configuration ffmpeg/ffprobe, la DB mobile et le handler audio.
- Cherche d'abord les composants réutilisables. N'invente pas une seconde source
  de vérité ni un second lecteur.
- Publie un plan court avec une seule étape `in_progress`.

### 2. Contrats backend versionnés

Implémente des DTO stricts et des routes équivalentes aux contrats documentés :

- `GET /api/tracks/:id/offline-options`
- `POST /api/tracks/:id/offline-variants/:profile` pour `opus_128|opus_256`
- `GET /api/tracks/:id/offline-variants/:profile`
- `GET /api/tracks/:id/offline-variants/:profile/file`

Le nom final peut suivre les conventions existantes, mais toute divergence doit
être décidée dans `TECH_DECISIONS.md` et répercutée dans
`MOBILE_ARCHITECTURE.md`. La réponse d'options doit au minimum fournir : profil,
codec, conteneur, débit cible/mesuré, caractère lossy, état, taille en octets,
`sizeKind=estimated|exact`, hash lorsqu'il existe et identité/version de source.
Ne renvoie jamais un chemin absolu.

### 3. Jobs et stockage serveur

- Ajoute le modèle persistant minimal des variantes/jobs selon les conventions
  SQLite/Drizzle et la stratégie de réparation idempotente documentée.
- États explicites et transitions testables : au minimum préparation, prêt,
  échec et obsolète.
- Concurrence par défaut très basse (un encodage à la fois sur le serveur H24),
  configurable sans valeur illimitée.
- Fichier `.part` confiné sous le cache, nettoyage sur erreur/annulation et
  renommage atomique seulement après validation.
- Vérifie réellement la disponibilité de `libopus` dans le FFmpeg configuré.
  Si elle n'est pas prouvée dans l'environnement réel, classe ce point dans
  `À vérifier` et n'annonce pas l'encodage comme fonctionnel.
- Paramètres attendus à valider, pas à copier aveuglément : `libopus`, VBR,
  cible 128k/256k, application audio et conteneur Ogg. La qualité affichée vient
  de ffprobe, jamais de l'argument demandé.

### 4. Téléchargement mobile unitaire

- Ajoute une feuille propre affichant les trois options, leur qualité réelle et
  leur taille en Mo, avec le mot « estimée » si nécessaire.
- Opus 256 est présélectionné/recommandé ; la préférence peut être mémorisée par
  appareil sans cacher le choix.
- Télécharge vers `.part`, reprend par HTTP Range, vérifie SHA-256 puis publie le
  fichier local atomiquement.
- Le manifeste SQLite est partitionné par compte et inclut profil, hash source,
  hash attendu, taille, octets reçus, état et chemin confiné. Aucun token en DB.
- Gère progression, annulation, retry, 202, 304/404/416 et 5xx sans boucle.
- Ajoute la sélection de source : copie locale vérifiée quand le serveur est
  réellement indisponible ; original réseau sinon. Aucun switch en plein titre.
- Le logout ne doit jamais rendre lisible le cache d'un autre compte.

### 5. Tests obligatoires

Backend :

- isolation et auth de chaque route ;
- rejet des profils inconnus et chemins malveillants ;
- single-flight séparé 128/256 ;
- source remplacée → variante obsolète ;
- échec FFmpeg/ffprobe → aucun fichier publié ;
- durée incohérente → rejet ;
- Range complet, partiel, reprise et 416 ;
- calcul taille estimée déterministe et champ `estimated|exact` ;
- aucun chargement complet d'un gros fichier en mémoire.

Flutter :

- rendu et libellés des trois choix ;
- Opus 256 recommandé et 256 explicitement lossy ;
- reprise `.part`, hash valide/invalide, annulation et retry ;
- isolation par compte et purge logique au logout ;
- sélection online/offline sans switch au milieu d'un titre ;
- non-régression des longues sessions, notification et file audio.

Exécute les commandes de tests/typecheck/analyse réellement disponibles dans le
dépôt. N'affirme pas qu'un test a réussi s'il n'a pas été lancé. Les tests
manuels sur téléphone sont listés séparément des tests automatisés.

## Discipline de livraison

- TypeScript strict, pas de `any` gratuit, erreurs explicites, fonctions courtes.
- Utilise `apply_patch` pour les modifications manuelles et `rg` pour chercher.
- Mets à jour dans le même lot `ROADMAP.md`, `TECH_DECISIONS.md`,
  `ARCHITECTURE.md`, `MOBILE_ARCHITECTURE.md` et `LESSONS.md` si l'implémentation
  change une décision ou révèle une leçon.
- Ne commit, ne push, ne déploie et n'installe rien sans autorisation explicite
  de l'utilisateur pour cette action externe. Les changements locaux et tests
  proportionnés sont autorisés.
- À la fin, livre : résultat concret, fichiers modifiés, migrations/contrats,
  commandes et résultats de tests, risques, puis section `À vérifier` pour toute
  preuve runtime manquante.

Critère de réussite de cette tâche : Phase 1A fonctionne de bout en bout sur **une
piste** dans les trois profils et est testée, sans commencer Phase 1B et sans
régression de la lecture en ligne. Si le gate Phase 0 reste incomplet, le critère
devient un rapport de blocage précis et reproductible, sans faux démarrage de
Phase 1.

---
