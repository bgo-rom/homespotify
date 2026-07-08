# LESSONS.md — Leçons du projet HomeSpotify

## Règle de mise à jour

Ce fichier **doit** être mis à jour dès qu'est découverte : une erreur commise, une décision importante, ou une contrainte durable. La mise à jour fait partie de la tâche en cours, pas d'un nettoyage ultérieur. Consulter ce fichier avant toute décision technique.

## Format d'entrée recommandé

```markdown
### L-NNN — Titre court (AAAA-MM-JJ)
- **Contexte** : où/comment le point a été découvert.
- **Leçon** : le fait ou la règle à retenir.
- **Conséquence** : ce que ça change dans le projet (code, doc, process).
```

## Leçons

### L-001 — YouTube n'est pas une source lossless (2026-07-08)
- **Contexte** : cadrage initial de la stratégie d'acquisition audio.
- **Leçon** : YouTube sert de l'audio déjà compressé (Opus/AAC ~130–160 kbps). Aucune extraction n'en fera de la qualité CD, et une conversion en FLAC ne récupère rien.
- **Conséquence** : toute piste d'origine lossy est étiquetée `lossy` avec son débit source ; les vraies sources lossless sont listées dans `AUDIO_SOURCING.md`.

### L-002 — Une extension `.flac` ne garantit pas du lossless (2026-07-08)
- **Contexte** : conception de la détection de qualité.
- **Leçon** : n'importe quel MP3 peut être réencapsulé en FLAC (« fake lossless »). L'extension et les tags ne prouvent rien.
- **Conséquence** : la qualité en base provient exclusivement d'une analyse (ffprobe + détection spectrale) ; statut `inconnue` par défaut, jamais supposé.

### L-003 — Les gros fichiers audio imposent une discipline stricte (2026-07-08)
- **Contexte** : conception du streaming et de l'import.
- **Leçon** : avec des FLAC de 20–60 Mo, tout chargement complet en mémoire finit en saturation RAM ; le seek exige HTTP Range complet ; le mobile exige cache et streaming progressif.
- **Conséquence** : streams uniquement (upload, hash, envoi), HTTP Range 206 complet, transcodage à la volée pour le cellulaire, cache hors ligne vérifié par hash. Règles gravées dans `AGENTS.md` et `ARCHITECTURE.md`.

### L-004 — Simple avant beau (2026-07-08)
- **Contexte** : définition des priorités du projet.
- **Leçon** : une fonctionnalité stable et laide vaut mieux qu'une belle et fragile ; l'esthétique est la priorité 5 sur 5.
- **Conséquence** : la PWA minimale précède l'app native ; chaque phase de la roadmap a des critères de stabilité avant tout travail visuel.

### L-005 — La documentation guide le code, pas l'inverse (2026-07-08)
- **Contexte** : mise en place des fichiers de fondation (Phase 0).
- **Leçon** : coder puis documenter produit des docs mortes et des décisions implicites ; l'inverse maintient la cohérence.
- **Conséquence** : toute implémentation se conforme à `ARCHITECTURE.md` et `TECH_DECISIONS.md` ; tout écart impose la mise à jour du document dans le même lot de travail.

### L-006 — Windows impose une discipline de fins de ligne (2026-07-08)
- **Contexte** : premier commit — git a averti de conversions LF→CRLF sur tous les fichiers.
- **Leçon** : sans `.gitattributes`, un dépôt édité sous Windows accumule des diffs parasites de fins de ligne, et les fichiers binaires (audio, sqlite) risquent une corruption par conversion.
- **Conséquence** : `.gitattributes` à la racine force LF sur le texte et `binary` sur audio/images/DB ; toute nouvelle extension de fichier doit y être classée.

### L-007 — pnpm 10 bloque les scripts de build natifs par défaut (2026-07-08)
- **Contexte** : Phase 1 — `better-sqlite3` installé sans son binaire natif, erreur « Could not locate the bindings file » seulement au premier test.
- **Leçon** : pnpm ≥ 10 ignore les scripts postinstall non approuvés ; un module natif peut sembler installé mais être inutilisable, et `pnpm rebuild` seul ne suffit pas toujours (il a fallu `pnpm install --force` après approbation).
- **Conséquence** : les modules natifs autorisés sont déclarés dans `package.json > pnpm.onlyBuiltDependencies` (versionné) ; vérifier le binaire par un test réel après tout ajout de dépendance native.
