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
- **Conséquence** : streams uniquement (upload, hash, envoi), HTTP Range 206 complet, WAV/FLAC natifs sans transcodage, cache hors ligne vérifié par hash. Règles gravées dans `AGENTS.md` et `ARCHITECTURE.md`.

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

### L-008 — Le statut lossless vient de la provenance, pas du conteneur (2026-07-08)
- **Contexte** : Phase 2, ingestion WAV-only ; un WAV upscalé par IA (AudioSR) a un conteneur PCM 16 bit identique à un rip CD.
- **Leçon** : un conteneur PCM/WAV ne prouve **rien** sur l'origine réelle du signal — l'upscale IA génère des hautes fréquences plausibles, ce n'est pas du lossless récupéré. Se fier au conteneur reproduirait le piège du « fake FLAC » (cf. [[L-002]]).
- **Conséquence** : le statut qualité est mappé depuis la **provenance déclarée** à l'import (`upscale_ia`→`lossy`, `rip_cd`/`achat`→`lossless_verifie`, etc.), jamais depuis l'extension ou le conteneur. Table de mapping dans `AUDIO_SOURCING.md` et `import-service.ts`.

### L-009 — WAV-only : simplicité payée en espace disque (2026-07-08)
- **Contexte** : décision utilisateur de n'ingérer que du WAV PCM 16 bit, remplaçant FLAC (qui était marqué « définitif »).
- **Leçon** : un WAV pèse ~2× un FLAC à qualité identique. Le choix privilégie un pipeline d'import trivial (un seul format, pas de transcodage à l'entrée) au prix de l'espace disque — arbitrage assumé, pas un oubli.
- **Conséquence** : import borné au WAV 44,1/48 kHz 16 bit (refus `422` sinon) ; FLAC gardé en réserve comme format d'archivage compressé si l'espace devient critique (`TECH_DECISIONS.md`). Une décision « définitive » peut changer sur demande explicite de l'utilisateur, à condition de tracer le pourquoi.
- **État** : décision remplacée le 2026-07-09 : les WAV PCM et FLAC lossless conformes sont désormais acceptés et préservés nativement, sans conversion.

### L-010 — curl Windows et chemins absolus dans `-F @` (2026-07-08)
- **Contexte** : smoke-test Phase 2 — `curl -F "file=@C:/…/smoke.wav"` n'envoyait aucune requête (corps vide, rien côté serveur).
- **Leçon** : le curl fourni sous Git Bash/Windows interprète mal `@C:/chemin` (le `:` du lecteur casse le parsing) ; l'upload échoue silencieusement sans erreur exploitable.
- **Conséquence** : pour les tests manuels d'upload, se placer dans le dossier (`cd`) et référencer le fichier en **chemin relatif** (`-F "file=@smoke.wav"`). Les tests automatisés utilisent `app.inject` + `form-data` et ne sont pas concernés.

### L-011 — Un scanner qui copie dans un dossier sous sa racine se re-scanne lui-même (2026-07-08)
- **Contexte** : validation du scanner Windows — en plaçant la bibliothèque gérée sous le dossier scanné, le re-scan voyait les copies gérées (7 fichiers au lieu de 4). La dédup par hash les rattrapait, mais au prix d'I/O inutile.
- **Leçon** : un scanner récursif qui écrit sa sortie sous sa propre racine d'entrée finit par ingérer ses propres copies. Non fatal ici grâce au hash, mais gaspilleur et déroutant.
- **Conséquence** : la marche exclut explicitement les dossiers gérés (`musicDir`/`incomingDir`/`coversDir`, comparés en chemins résolus). Toujours exclure les dossiers de destination d'un scan récursif.

### L-012 — Encodage des heredocs PowerShell et caractères accentués (2026-07-08)
- **Contexte** : création de fixtures WAV avec noms accentués (`Café Déjà`) via `Out-File -Encoding ascii` → les accents devenaient `?`, `writeFileSync` échouait (ENOENT).
- **Leçon** : sous PowerShell 5.1, écrire un script contenant des accents avec `-Encoding ascii` corrompt les caractères ; le défaut UTF-16 pose d'autres soucis à Node. Les accents dans les chemins/tags doivent transiter par un canal UTF-8 propre.
- **Conséquence** : le cas accentué est couvert par les **tests unitaires** (`app.inject`, sources en UTF-8) ; les validations manuelles Windows évitent les accents dans les scripts générés, ou utilisent un encodage UTF-8 explicite.
### L-013 — `pnpm` peut casser `node_modules` en sandbox sans réseau (2026-07-08)
- **Contexte** : validation Phase 3 MusicBrainz dans Codex sandbox ; `pnpm --filter ... test/typecheck` a tenté de recréer `node_modules`, puis l'installation a expiré car l'accès au registre npm est interdit (`EACCES`).
- **Leçon** : en environnement non interactif avec réseau restreint, ne pas relancer `pnpm install` implicitement si `node_modules` est jugé incohérent ; l'opération peut laisser des liens incomplets et empêcher les tests locaux.
- **Conséquence** : relancer `pnpm install` sur la machine utilisateur avec réseau autorisé avant les tests si le sandbox a purgé les liens ; en sandbox, privilégier les vérifications qui n'exigent pas de réinstallation.

### L-014 — Le démarrage audio mobile doit être atomique (2026-07-09)
- **Contexte** : passe runtime Flutter ; le tap piste declenchait preparation, lecture et navigation depuis l'UI, sans etat de chargement ni protection contre les doubles taps.
- **Leçon** : pour les flux WAV/FLAC lourds, l'UI ne doit pas appeler `setTrack()` puis `play()` de façon dispersée ; le handler doit préparer la source, attendre son chargement et seulement ensuite lancer la lecture.
- **Conséquence** : exposer `setQueueAndPlay()` comme méthode atomique, journaliser les états audio seulement en debug, afficher un état de préparation et empêcher les lancements concurrents.

### L-015 — L'absence de DSP applicatif ne garantit pas un bit-perfect matériel (2026-07-09)
- **Contexte** : audit du pipeline Flutter Android (`just_audio` + `audio_service`) pour des flux WAV/FLAC natifs.
- **Leçon** : HomeSpotify peut préserver le fichier servi, ne pas appliquer de gain automatique, de normalisation, d'égaliseur ou de transcodage ; Android peut néanmoins mixer ou rééchantillonner après la sortie de l'application selon l'appareil, le DAC et la route audio.
- **Conséquence** : ne jamais promettre un bit-perfect matériel universel sans mesure sur l'appareil cible. Les garanties du projet portent sur le flux HTTP original et l'absence de transformation dans HomeSpotify ; la fréquence de sortie Android reste à valider avec le matériel réel.
