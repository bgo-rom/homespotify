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

### L-016 — Un `push` GoRouter différé par un `await` peut empiler des doublons (2026-07-10)
- **Contexte** : bug « double retour » sur vrai téléphone — quitter le PlayerScreen exigeait deux appuis. `_playQueue` poussait `/player` **après** l'attente réseau de préparation de la file ; si `/player` avait été ouvert entre-temps (icône Lecteur de l'AppBar, restée active pendant la préparation), deux PlayerScreen identiques s'empilaient et le premier retour popait vers un écran visuellement identique.
- **Leçon** : tout `context.push()` placé après un `await` peut s'exécuter alors que la route cible est déjà au sommet de la pile ; `context.mounted` ne protège pas de ça (l'écran appelant reste monté sous la route poussée).
- **Conséquence** : toute ouverture du lecteur passe par `openPlayer()` (`lib/src/app/navigation.dart`), qui vérifie `GoRouter.state.uri.path` avant de pousser ; le PlayerScreen porte un `PopScope` qui force tout retour (UI ou système) vers `/` via `go('/')`, immunisant contre tout doublon résiduel. Tests de non-régression dans `test/navigation_test.dart`.

### L-017 — Le Future de `AudioPlayer.play()` ne se résout qu'à la fin de la lecture (2026-07-10)
- **Contexte** : sur vrai téléphone, après un tap sur une piste, toute la bibliothèque restait bloquée (covers en placeholder, tiles désactivées) tant qu'on ne mettait pas pause. `setQueueAndPlay` se terminait par `await _player.play()`.
- **Leçon** : dans just_audio, le Future retourné par `play()` se complète à la **pause, au stop ou à la fin de la piste** — jamais au démarrage de la lecture. Tout code UI qui attend ce Future reste suspendu pendant toute la lecture. Effet domino : l'état « busy » permanent désactivait les boutons du mini-player, dont les taps traversaient alors vers l'InkWell parent et ouvraient le lecteur complet.
- **Conséquence** : `setQueueAndPlay` attend la préparation (`setAudioSources`) mais démarre la lecture avec `unawaited(play())` (erreurs rattrapées vers `_recordPlaybackFailure`). Règle : ne jamais `await` un `play()` just_audio dans un chemin qui bloque l'UI. Par ailleurs, les boutons d'un mini-player doivent être des **frères** de la zone tapable, jamais ses enfants : un `IconButton` désactivé laisse passer le tap au parent.

### L-018 — Jamais de texte libre dans un paramètre de route (2026-07-10)
- **Contexte** : écran rouge « Illegal percent encoding in URI » en ouvrant l'album « Upstairs at Eric's » depuis la grille Albums. La route `/albums/:albumKey` transportait le nom d'album percent-encodé, et le builder appelait `Uri.decodeComponent` sur le paramètre.
- **Leçon** : go_router **décode déjà** les `pathParameters` (via `Uri.decodeComponent`, `match.dart`). Tout `decodeComponent` supplémentaire est un double décodage qui lève `Illegal percent encoding` dès que la valeur décodée contient un `%` littéral (« Album 100% Hits ») — reproduit en test. Et même simple-encodé, un nom libre dans une URI reste fragile : apostrophes, `/`, `+` et l'aller-retour de l'URI par le moteur Android multiplient les cas invalides.
- **Conséquence** : les paramètres de route sont des identifiants **URL-safe par construction** : `albumRouteId()` = base64Url de la clé (alphabet sans aucun caractère réservé), décodé par `albumKeyFromRouteId()` qui retourne `null` au lieu de lever (→ écran « Album introuvable » avec bouton retour, jamais d'écran rouge). Interdit de mettre un nom brut dans un chemin de route. Tests de non-régression avec apostrophe/%/slash/accents dans `test/album_route_test.dart`.

### L-019 — Un dialogue doit posséder ses contrôleurs et son `ref` (2026-07-10)
- **Contexte** : créer ou annuler une playlist provoquait l'assertion Flutter `_dependents.isEmpty`. Le `TextEditingController` était créé hors du dialogue puis détruit dès la résolution de `showDialog`, alors que la route pouvait encore être montée pendant son animation de sortie ; le dialogue conservait aussi un `WidgetRef` fourni par l'écran ou la bottom sheet.
- **Leçon** : le `Future` de `showDialog` ne constitue pas une frontière sûre pour détruire les objets utilisés par les widgets de la route. Un dialogue asynchrone doit posséder son état, ses contrôleurs et son `ref`, et vérifier `mounted` après chaque `await`.
- **Conséquence** : les dialogues interactifs sont des `StatefulWidget`/`ConsumerStatefulWidget` autonomes ; leurs contrôleurs sont libérés dans `State.dispose()` et leur fermeture utilise leur propre `BuildContext`.

### L-020 — Un `pumpWidget` avec de nouveaux overrides ne réinitialise pas un ProviderScope monté (2026-07-10)
- **Contexte** : tests shuffle/repeat — un même `testWidgets` repompait l'arbre avec d'autres overrides (`playbackStateProvider` différent) ; l'UI gardait l'ancien état.
- **Leçon** : Riverpod ne lit les `overrides` d'un `ProviderScope` qu'au montage. Re-pomper un arbre identique réutilise l'élément existant et ignore les nouveaux overrides — le test valide silencieusement l'ancien état.
- **Conséquence** : règle de test : un scénario d'état = un `testWidgets` avec son propre pump. Ne jamais enchaîner deux `pumpWidget` à overrides différents dans le même test.

### L-021 — En LoopMode.one, un saut manuel doit réarmer la boucle sur la nouvelle piste (2026-07-10)
- **Contexte** : shuffle + repeat-one actifs, changement manuel de piste (suivant/précédent/file) — l'ancienne piste revenait parfois en boucle alors que l'UI affichait la nouvelle.
- **Leçon** : sous `LoopMode.one`, le lecteur natif peut rester ancré sur la piste répétée malgré un `seek(index:)` ; l'état publié (mediaItem/queueIndex avant seek) et l'état réel divergent alors silencieusement.
- **Conséquence** : `skipToQueueItem` désarme la boucle (`LoopMode.off`), fait le seek, réarme `LoopMode.one`, puis resynchronise `_currentQueueIndex` sur `_player.currentIndex` et republie mediaItem + playbackState. Le mode repeat-one reste actif ; seule la piste répétée change. Règle générale : après tout seek d'index, republier depuis l'état **réel** du lecteur, pas depuis l'intention.

### L-022 — `pnpm.onlyBuiltDependencies` dans package.json n'est plus lu (2026-07-11)
- **Contexte** : ajout de la dépendance Argon2 — chaque commande pnpm affiche `The "pnpm" field in package.json is no longer read by pnpm`.
- **Leçon** : le pnpm installé ignore désormais la clé `pnpm.onlyBuiltDependencies` de `package.json` (elle doit vivre dans `pnpm-workspace.yaml`). La protection posée en [[L-007]] est donc silencieusement inactive ; better-sqlite3 continue de fonctionner uniquement parce que son binaire est déjà construit dans `node_modules`.
- **Conséquence** : pour l'auth, choix de `@node-rs/argon2` (binaires N-API précompilés, aucun script postinstall) qui élimine la classe de problème. À la prochaine réinstallation complète, migrer `onlyBuiltDependencies` vers `pnpm-workspace.yaml`.

### L-023 — Un widget test ne voit pas les enfants non construits d'une ListView (2026-07-11)
- **Contexte** : ajout des sections Compte/Sécurité/Administration en tête de l'écran Paramètres — le test existant `find.text('WAV / FLAC')` a échoué alors que la section Audio existait toujours.
- **Leçon** : `ListView` construit ses enfants paresseusement : tout contenu poussé hors du viewport de test (800px par défaut) n'existe pas dans l'arbre et `find.text` le rate. Ajouter des éléments en tête d'une liste casse les tests qui cherchent les éléments de queue.
- **Conséquence** : les tests d'écrans à liste fixent une surface assez haute (`setSurfaceSize`) pour matérialiser toutes les sections vérifiées, ou scrollent explicitement (`scrollUntilVisible`) avant l'assertion.

### L-024 — `local_auth` exige une FragmentActivity réellement lancée (2026-07-11)
- **Contexte** : une empreinte était enregistrée sur le téléphone, mais HomeSpotify annonçait la biométrie non validée. `MainActivity` étendait bien `FlutterFragmentActivity`, tandis que le manifeste lançait directement `AudioServiceActivity`, basée sur `FlutterActivity`.
- **Leçon** : corriger une classe Kotlin inutilisée ne change rien au runtime. Avec `audio_service`, l'activité launcher doit être la classe applicative et étendre `AudioServiceFragmentActivity`, qui combine le moteur audio partagé et la FragmentActivity attendue par `local_auth`. Le thème Android doit aussi être AppCompat.
- **Conséquence** : vérifier ensemble manifeste, hiérarchie réelle de l'activité, thème et API exacte du plugin. La disponibilité accepte les types Android exposés (`fingerprint`, `face`, `strong`, `weak`, etc.) au lieu d'exiger uniquement `strong`.

### L-025 — Une extension « metadata_provider » peut quand même contourner un service (2026-07-12)
- **Contexte** : recherche d'une première extension SpotiFLAC réelle en recherche seule. `spotify-web` (Apache 2.0, type `metadata_provider`, aucun téléchargement) semblait idéal ; l'audit statique du `index.js` a révélé une table `TOTP_SECRETS` embarquée servant à forger le token anti-abus de l'API web privée de Spotify (`api-partner.spotify.com`).
- **Leçon** : le type déclaré (« recherche seule, pas de téléchargement ») ne dit rien de la **légitimité de l'accès**. Une extension inoffensive en apparence peut reposer sur un secret extrait d'un client tiers et le contournement d'une mesure de contrôle d'accès — interdit par `CLAUDE.md` (« Aucun contournement de DRM »). Toujours lire le code d'acquisition de session/token, pas seulement le manifeste et les capacités.
- **Conséquence** : audit consigné dans `EXTENSION_REGISTRY_AUDIT.md` (document retiré le 2026-07-12 avec le système d'acquisition ; verdict conservé ici et dans TECH_DECISIONS.md) ; NO-GO sur toutes les extensions recherche du registre (l'autre, `apple-music`, exige un token d'abonnement payant). Aucun provider réel ajouté ; le broker reste sur l'extension fictive. Conditions de GO documentées (API publique documentée, sans forge de token). Les scripts d'isolation Windows sont livrés indépendamment, pour l'infrastructure future.

### L-026 — Une licence permissive ne légitime pas l'accès aux services tiers (2026-07-12)
- **Contexte** : audit du code source MIT de SpotiFLAC classique. Les fonctions de recherche sont librement copiables au titre du copyright, mais leur transport forge des jetons Spotify via un secret TOTP et extrait/embarque un secret Qobuz ; les fournisseurs audio utilisent des endpoints communautaires opaques et du déchiffrement.
- **Leçon** : la licence du dépôt et l'autorisation d'utiliser une API ou un contenu sont deux questions indépendantes. Une couche « recherche seulement » reste interdite si son authentification contourne les mécanismes officiels.
- **Conséquence** : conclusion C dans `SPOTIFLAC_SOURCE_REUSE_AUDIT.md` (document retiré le 2026-07-12 avec le système d'acquisition ; verdict conservé ici et dans TECH_DECISIONS.md) ; aucun prototype. Les futurs providers exigent une API publique documentée et une revue séparée de ses conditions d'utilisation.

### L-027 — drizzle-kit generate devient interactif si une table est supprimée et d'autres créées dans le même diff (2026-07-12)
- **Contexte** : remplacement de `acquisition_jobs` par les tables découverte/demandes. `drizzle-kit generate` a demandé en TTY « est-ce un renommage ? » et a échoué en environnement non interactif.
- **Leçon** : le résolveur de renommage de drizzle-kit ne se déclenche que lorsqu'un même diff contient à la fois des tables supprimées et créées. En scindant le changement (migration 1 : créations, migration 2 : suppression), chaque génération est non ambiguë et passe sans prompt.
- **Conséquence** : pour tout remplacement de table, générer deux migrations successives plutôt qu'une seule.

### L-028 — MusicBrainz ne fournit pas une notion native de similarité (2026-07-12)
- **Contexte** : alimentation publique du catalogue de recommandations sans API privée ni scraping.
- **Leçon** : MusicBrainz fournit des identifiants, crédits, tags, sorties et enregistrements, mais pas un classement officiel « artistes similaires ». La V1 rapproche donc les artistes par tags communs et doit présenter ce résultat comme une découverte déterministe, pas comme une vérité éditoriale.
- **Conséquence** : le provider est abstrait et testable ; le score reste séparé du catalogue. La pertinence réelle doit être mesurée avant d'augmenter le volume ou la fréquence des appels.

### L-029 — Riverpod 3 interdit `ref` dans `State.dispose()` (2026-07-12)
- **Contexte** : refonte `/discover` — l'arrêt de l'extrait audio dans `dispose()` via `ref.read(...)` levait `Bad state: Using "ref" when a widget is about to or has been unmounted` dans tous les tests widget.
- **Leçon** : depuis flutter_riverpod 3, tout accès à `ref` pendant le démontage d'un `ConsumerStatefulWidget` est une erreur d'assertion. `ref.read` reste permis dans `initState`.
- **Conséquence** : tout notifier nécessaire au nettoyage est capturé dans un champ du `State` en `initState` (`_preview = ref.read(...notifier)`) et utilisé dans `dispose()`. Même famille que [[L-019]] (un dialogue possède ses contrôleurs) : le démontage ne doit dépendre d'aucun contexte.

### L-030 — Une garantie de fenêtre glissante meurt si le fallback réinjecte les items refusés (2026-07-12)
- **Contexte** : composition de la file de reco V2 — « max 2 pistes du même artiste par fenêtre de 10 ». Le premier algorithme glouton, à court de candidats conformes, replaçait les items refusés en fin de sélection : 5 cartes du même artiste dans les 10 premières, test rouge.
- **Leçon** : avec un stock biaisé (8 candidats sur 16 du même artiste), la contrainte est mathématiquement insatisfiable pour la file complète ; tout « fallback » qui finit par insérer les items violants annule silencieusement la garantie.
- **Conséquence** : quand plus aucun candidat ne respecte la fenêtre, la composition S'ARRÊTE (file plus courte) — la diversité prime sur la longueur. La garantie « ≥ 2 explorations » ne s'applique qu'aux fenêtres complètes de 10 pour ne pas déformer les petites files. Documenté dans `TECH_DECISIONS.md`.

### L-031 — Les migrations drizzle manuscrites (0010/0011) n'ont pas de snapshot (2026-07-12)
- **Contexte** : ajout de `user_recommendation_queue`/`recommendation_impressions` — la migration 0011 a été écrite à la main (SQL + `_journal.json`), comme 0010 avant elle, à cause du résolveur interactif de drizzle-kit ([[L-027]]).
- **Leçon** : le migrateur runtime ne lit que `_journal.json` + les `.sql`, mais `drizzle-kit generate` diffe contre le DERNIER snapshot (0009). Tout futur `generate` produira un diff faux (il croira que les tables 0010/0011 n'existent pas).
- **Conséquence** : avant le prochain `drizzle-kit generate`, régénérer un snapshot cohérent (ou continuer en migrations manuscrites). Vérifier chaque migration manuscrite par un boot de test (`:memory:`) — c'est couvert par la suite vitest.

### L-028 — Les tags WAV INFO perdent les accents dans les fixtures de test (2026-07-12)
- **Contexte** : tests backend de la reco par correspondance (titre|artiste) : des fixtures `makeWav` avec titres/artistes accentués (« Possédée », « Aimé ») ne matchaient plus après import, l'encodage des chunks LIST INFO WAV n'étant pas UTF-8 fiable.
- **Leçon** : la chaîne makeWav → import → music-metadata ne restitue pas les accents à l'identique ; toute logique comparant des métadonnées importées à des chaînes attendues doit être testée avec des fixtures ASCII (le comportement runtime réel sur FLAC/vrais tags n'est pas concerné de la même façon).
- **Conséquence** : fixtures ASCII dans les tests d'import/matching ; si un matching accent-sensible devient critique, normaliser (NFD, strip diacritiques) des deux côtés plutôt que d'espérer un encodage fidèle.

### L-032 — Exclure définitivement les cartes VUES tue le feed (cause racine « meurt après 5 dislikes ») (2026-07-12)
- **Contexte** : audit du feed reco sur les données réelles du OWNER. La V2 excluait tout candidat exposé dans les 14 derniers jours (`recommendation_impressions`) ET tout candidat disliké. Avec un catalogue de 42 candidats pollué (12 « Various Artists », 10 « [unknown] »), quelques swipes suffisaient à vider la file : chaque carte vue devenait définitivement inéligible.
- **Leçon** : dans un swipe infini, « déjà vu » doit être une **pénalité de score**, jamais une exclusion. Seuls les signaux DÉFINITIFS excluent (possédée, DISLIKE du morceau, REMOVE, demande active/aboutie). L'exposition récente rétrograde le rang mais la carte peut revenir.
- **Conséquence** : V3 sépare exclusion (permanente) et pénalité (réversible, plafonnée) ; refill continu (réserve 50, seuil 12) ; « une carte VUE n'est plus exclue » est un test de non-régression. [[L-030]] (diversité) reste, mais ne doit jamais raccourcir la file au point de la vider.

### L-033 — Un tag de genre n'est pas une relation de similarité (2026-07-12)
- **Contexte** : la V1/V2 rapprochait les artistes par tags MusicBrainz communs (« rap », « pop »). Résultat sur données réelles : des compilations et des artistes sans lien réel (Beatles, Rolling Stones) proposés à un profil rap FR (Ajna, Laylow).
- **Leçon** : un tag partagé est une co-occurrence de catégorie, pas une preuve de proximité musicale. Une reco crédible exige une relation DIRECTE et vérifiable (voisin de morceau Last.fm, ou artiste voisin confirmé par plusieurs seeds indépendantes), stockée comme preuve (`evidence_json`) et exigée avant insertion.
- **Conséquence** : V3 remplace le catalogue-par-tags par un `MusicSimilarityProvider` (Last.fm primaire) ; règle d'admission « ≥ 1 preuve forte OU ≥ 2 preuves moyennes de seeds distinctes » ; les filtres qualité (`candidate-quality.ts`) bannissent Various Artists / Unknown / DJ-mix AVANT insertion, donc la base ne se pollue plus.

### L-034 — Un `when` de journal hors-ordre fait sauter une migration à jamais (2026-07-12)
- **Contexte** : la base réelle était bloquée à l'état 0011 ; les colonnes V3 (`category`, `served_at`, `evidence_json`) de la migration 0012 manquaient. `__drizzle_migrations` comptait 12 lignes, `flutter`/serveur plantaient sur `no such column: category`.
- **Leçon** : le migrateur `drizzle-orm/better-sqlite3` décide quoi appliquer en comparant le `created_at` MAX déjà enregistré au `when` (folderMillis) de chaque entrée du journal. Comme 0010/0011 ont reçu des `when` fabriqués « futurs » (1783860000000 / 1783944000000) écrits à la main ([[L-031]]), le `when` RÉEL de 0012 (1783865256480, généré par `drizzle-kit`) est tombé AVANT 0011 → condition `maxApplied < entry.when` fausse → **0012 sautée définitivement**. Une base neuve ne voyait pas le bug (elle applique tout dans l'ordre idx). C'est la même famille de piège que [[L-031]].
- **Conséquence** : (1) réparation en CODE idempotente `ensureDiscoverV3Columns()` dans `runMigrations`, exécutée avant ET après `migrate()`, qui `ALTER TABLE ADD COLUMN` uniquement si la table existe et la colonne manque — sûre sur base ancienne/partielle/neuve, sans perte ; (2) migration `0013_repair_discover_v3` avec un `when` > tous les appliqués (index idempotent sur `served_at`) ; (3) 0010-0012 jamais modifiées. Règle : **ne jamais fabriquer de `when` à la main** dans `_journal.json` ; laisser `drizzle-kit generate` produire l'ordre, ou n'ajouter que des `when` strictement croissants. Toujours sauvegarder (copie brute + `VACUUM INTO`) avant de réparer une base de production.

### L-035 — Le matching d'extrait échouait par EXCÈS de rigueur, pas par manque de données (2026-07-13)
- **Contexte** : audit média sur la base réelle (userId=1) — 95/97 résolutions iTunes échouaient, la file de 51 cartes n'avait 0 extrait / 0 pochette. Sondage live iTunes : les classiques (Thriller, Dream On, Scorpions, GNR) ont 4-5 extraits disponibles. L'échec venait du code, pas du fournisseur.
- **Leçon** : la cascade V3 rejetait dès qu'iTunes renvoyait **plusieurs** versions exactes (« ambigu ⇒ null »), traitait la durée Last.fm (souvent fausse : 569 s pour Sweet Child) comme un **gate dur**, et exigeait l'égalité normalisée stricte sans storefront FR. Résultat : plus un morceau est catalogué, plus il échoue. La rigueur doit porter sur l'**identité** (titre+artiste), pas sur le **choix de version** : quand plusieurs versions légitimes existent, il faut DÉSAMBIGUÏSER vers la version canonique studio (exclure live/remix/cover, corroborer la durée en soft, prendre la plus populaire), jamais abandonner.
- **Conséquence** : `ItunesCatalogProvider` durci (storefront FR, désambiguïsation canonique, durée soft ±12 s jamais bloquante, rejet AMBIGUOUS seulement si studios distincts sans arbitre). Preuve : 51 muettes → 26 MEDIA_READY, 0 sans média. Corollaire architectural : la résolution média doit précéder la mise en file — **seul un MEDIA_READY entre dans `user_recommendation_queue`** (machine à états `media-state.ts`). Les morceaux vraiment absents (rap FR obscur) deviennent MEDIA_UNAVAILABLE et sont exclus proprement (ils n'apparaissent pas en carte muette). Voir [[L-033]].

### L-036 — Colonnes additives : réparation idempotente en code, pas une migration raw ALTER (2026-07-13)
- **Contexte** : la migration `0014` v4 (10 `ALTER TABLE ADD COLUMN`) plantait un test de réparation (`duplicate column name`) : quand `__drizzle_migrations` est rembobiné (scénario réel [[L-034]]), le migrateur re-joue 0014 alors que les colonnes existent déjà.
- **Leçon** : une migration drizzle en `ALTER ADD COLUMN` brut n'est PAS idempotente (SQLite n'a pas `ADD COLUMN IF NOT EXISTS`) et casse sur tout re-jeu. La leçon [[L-034]] s'applique aux ajouts additifs : les faire via une réparation en CODE (`ensureMediaReadyV4Columns`, ajoute la colonne seulement si la table existe et la colonne manque), exécutée AVANT et APRÈS `migrate()`, et NE PAS créer d'entrée de journal 0014.
- **Conséquence** : la migration 0014 a été supprimée (fichier + entrée `_journal.json`) ; les colonnes v4 (`media_resolution_status`, `canonical_*`, `isrc`, `apple_music_song_id`, `artwork_*`, `media_*`) sont posées par `ensureMediaReadyV4Columns` idempotent. Sûr sur base neuve (tables absentes avant migrate → posées après), réelle avancée (posées avant migrate) et rembobinée (colonnes présentes → skip). Règle générale : **tout ajout de colonne rétro-compatible passe par le mécanisme de réparation idempotent, jamais par un `ALTER ADD` de migration seul.**

### L-037 — Riverpod 3 : muter un provider observé est INTERDIT dans tout life-cycle, seul un événement de navigation est légal (2026-07-14)
- **Contexte** : quitter l'écran Découvrir pendant un extrait actif crashait en debug. `_preview.stop()` (mutation de `discoveryPreviewProvider`, observé par l'écran) était appelé dans `dispose()`.
- **Leçon** : Riverpod 3 pose TROIS gardes successives qu'il faut connaître : (1) `dispose()` → `markNeedsBuild` sur un élément `defunct` → assertion ; (2) `deactivate()` → l'élément est `inactive` mais le retrait se fait PENDANT une phase de build → « Tried to modify a provider while the widget tree was building » ; (3) `Provider.autoDispose` + `ref.onDispose(() => ...)` → « Cannot use Ref or modify other providers inside life-cycles » (`_debugCallbackStack != 0`), y compris en capturant le notifier au build puis en appelant `notifier.stop()` (l'accès à `.state` du notifier est lui aussi gardé). Donc AUCUN des trois life-cycles (widget dispose/deactivate, provider onDispose) ne permet de muter un provider. La seule phase légale est un **événement** (onPressed, onPopInvoked, observer de cycle de vie applicatif).
- **Conséquence** : arrêt de l'extrait + du sondage à la sortie d'écran via `PopScope(canPop: true, onPopInvokedWithResult: (didPop, _) { if (didPop) _onLeaveScreen(); })` — l'événement de pop est hors phase de build, la mutation est légale et immédiate. `dispose()` ne fait plus que `removeObserver`. Les autres déclencheurs restaient déjà événementiels : arrière-plan (`didChangeAppLifecycleState`), logout (`ref.invalidate(discoveryPreviewProvider)` → `ref.onDispose(_cleanup)` du lecteur), lecture bibliothèque (`ref.listen` du contrôleur d'extrait). Règle générale : **ne jamais muter un provider dans `dispose`/`deactivate`/`onDispose` ; router la logique vers un callback d'événement** (cf. message d'erreur Riverpod « move the logic outside of a widget life-cycle »). Test : simuler le retour système avec `tester.binding.handlePopRoute()` (déclenche `PopScope`), pas `Navigator.pop()`.

  - **Extension visibilité de route (2026-07-14)** : couper le média quand l'écran est masqué par une route empilée (`/requests`, `/player`) — et pas seulement au pop — passe par un `RouteObserver<ModalRoute<void>>` global (injecté dans `GoRouter.observers`) + le mixin `RouteAware`. `didPushNext()` (route empilée par-dessus) et `didPop()` (route dépilée, couvre `go`/pop programmatique que le `PopScope` ne capte pas toujours) sont des ÉVÉNEMENTS de navigation, PAS des life-cycles → mutation de provider légale (vérifié : aucun crash). `didPopNext()` (retour) NE force jamais la lecture : réarmement conditionnel uniquement (overlay inactif, app au premier plan, pas de piste bibliothèque, carte non swipée). Piège de typage : `RouteObserver<ModalRoute<void>>` ne matche QUE les routes `<void>` — les `showDialog<bool>` (`DialogRoute<bool>`) ne déclenchent donc PAS `didPushNext`, ce qui est le comportement voulu (le dialogue de confirmation gère déjà son extrait). Test : `navigatorObservers: [routeObserver]` + push d'une `MaterialPageRoute<void>` par-dessus.

### L-038 — `inactive` Android n'est pas un arrêt audio (2026-07-14)
- **Contexte** : ouvrir le volet de notifications Android émettait `AppLifecycleState.inactive` et coupait à tort l'extrait de Découvrir.
- **Leçon** : `inactive` est un état transitoire de perte de focus, pas la preuve que l'application est réellement masquée. L'audio ne doit être arrêté que sur `hidden`, `paused` ou `detached`, ou par un événement métier/navigation explicite.
- **Conséquence** : la transition `inactive → resumed` conserve le lecteur, sa position et ses temporisations ; `inactive → hidden → paused` arrête immédiatement l'extrait sans recréer de lecteur. Cette règle ne change ni le pipeline audio ni les paramètres de lecture.

### L-039 — UTF-8 valide ne signifie pas texte non corrompu (2026-07-14)
- **Contexte** : plusieurs libellés Flutter récents affichaient `Ã©`, `Â·` ou `â€™`, alors que tous les fichiers passaient un décodage UTF-8 strict.
- **Leçon** : le mojibake est souvent une chaîne UTF-8 valide dont les caractères ont déjà été décodés puis réencodés avec le mauvais jeu. La validation binaire seule ne suffit pas ; il faut aussi rechercher les marqueurs textuels typiques dans les sources et le rendu UI.
- **Conséquence** : audit combiné UTF-8 strict + recherche de motifs sur Dart/JSON/TypeScript/SQL, et test widget dédié qui vérifie les libellés français exacts ainsi que l'absence de marqueurs corrompus visibles.

### L-040 — Une vitesse par piste doit être remise à zéro avant toute résolution asynchrone (2026-07-14)
- **Contexte** : un réglage persistant à 1,30x peut arriver après une requête réseau, alors que la piste suivante a déjà commencé sans réglage.
- **Leçon** : attendre le GET de réglage avant de décider la vitesse laisse temporairement fuir la vitesse précédente. Le reset 1,00x doit être synchrone avec la transition ; la valeur persistée n'est appliquée qu'ensuite si la piste est toujours courante. Le pitch doit être réaffirmé à 1,0 lors de chaque application, pas supposé globalement.
- **Conséquence** : compteur de requête anti-course dans le handler, cache purgé au logout, reset préalable sur transitions manuelles et automatiques, puis publication de `PlaybackState.speed`. Tests dédiés A=1,30x → B sans réglage=1,00x et pitch toujours 1,0.

### L-041 — Aucun plugin natif ne doit précéder la première frame (2026-07-14)
- **Contexte** : Android signalait un ANR au lancement après l'ajout des réglages de vitesse. `main()` attendait `AudioService.init` avant `runApp`, tandis que le constructeur du handler lançait déjà `setVolume` et `AudioSession.instance`. Une attente native suffisait donc à laisser l'écran de lancement sans frame Flutter interactive.
- **Leçon** : les constructeurs d'infrastructure mobile restent sans effet natif ; la première frame est publiée avant tout rattachement de service facultatif. Les réglages distants d'une piste ne doivent jamais se trouver dans le chemin critique de lecture.
- **Conséquence** : handler local unique injecté immédiatement, rattachement `audio_service` après la première frame, volume/session paresseux à la première lecture, réglage de vitesse chargé en arrière-plan avec timeout et contrôle de piste active. Le lecteur local reste fonctionnel si le service de notification échoue.
  - **Mise à jour 2026-07-20** : la conclusion « aucun plugin natif avant la première frame » était trop large. La cause bloquante était le travail natif lancé par le constructeur du handler. Ce constructeur étant désormais paresseux, `AudioService.init` doit au contraire être attendu avant `runApp` : le service média est une condition de la lecture en arrière-plan, pas un enrichissement facultatif.

### L-042 — Une migration présente peut rester invisible à une base dont le journal est « dans le futur » (2026-07-14)
- **Contexte** : la base réelle avait déjà un `created_at` maximal à `1784050000000`, tandis que l'entrée 0014 des réglages de lecture et de l'analyse audio portait `when=1784037485683`. Drizzle a donc ignoré son SQL et les tables `user_track_playback_settings` et `track_audio_analysis` n'existaient pas, malgré la présence du fichier de migration.
- **Leçon** : corriger uniquement le SQL ou `_journal.json` ne répare pas les bases qui ont déjà mémorisé un horodatage supérieur. Toute évolution additive indispensable doit disposer d'une réparation idempotente en code, indépendante de la décision d'application du journal, dans la même famille que [[L-034]] et [[L-036]].
- **Conséquence** : le bootstrap vérifie et crée sans perte les tables/index additifs manquants hors journal ; un test démarre explicitement une base legacy dont le journal contient un horodatage futur et dont les tables 0014 sont absentes. Toute nouvelle entrée du journal reste strictement monotone, mais cette correction seule n'est jamais considérée comme la réparation de production.

### L-043 — `pitch=1.0` ne transforme pas Sonic en moteur musical haute qualité (2026-07-14)
- **Contexte** : audit du ralenti dégradé sur Android : `just_audio` 0.10.6 transmet les `PlaybackParameters` à Media3 1.4.1, dont le chemin audio par défaut utilise `SonicAudioProcessor`. Le pitch nominal reste à 1,0, mais les voix, transitoires et basses deviennent artificielles aux ratios éloignés de 1,00x.
- **Leçon** : préserver numériquement le pitch ne garantit ni les formants, ni la phase, ni la qualité musicale. Un plugin natif parallèle ne change rien au son du lecteur existant : le processeur spécialisé doit remplacer Sonic dans le `DefaultAudioSink` (ou posséder toute la chaîne PCM), avec position et file toujours pilotées par le lecteur unique.
- **Conséquence** : `TimeStretchEngine` devient une abstraction paresseuse et adaptative, avec fallback Media3 explicitement qualifié de compatible. Rubber Band n'est pas embarqué sans décision de distribuer sous GPL-2.0-or-later ou licence commerciale. Signalsmith Stretch (MIT) est retenu uniquement comme candidat de POC natif ; il ne sera déclaré intégré ou « haute qualité » qu'après build arm64-v8a, tests d'écoute musicale et mesures CPU/latence/continuité sur appareil réel.

### L-044 — L'identité d'un dossier utilisateur ne doit jamais dépendre d'un nom mutable (2026-07-14)
- **Contexte** : création d'inbox d'import distinctes pour chaque compte, avec un nom lisible `<userId>_<username>`.
- **Leçon** : recalculer ce chemin depuis le username courant après un renommage crée un second dossier et peut attribuer un fichier au mauvais cycle de traitement. Le chemin doit être créé une seule fois, enregistré en base et résolu sous une racine confinée ; le `userId` du token/dossier reste la seule identité d'autorisation.
- **Conséquence** : `user_import_directories` mémorise le nom initial, le boot ne crée que les sous-dossiers absents et ne déplace rien. Tous les chemins passent par `resolve` + contrôle de confinement ; le watcher n'accorde que le `user_tracks` de ce `userId`. La migration 0015 reste rejouable et laisse les ajouts de colonnes SQLite au réparateur idempotent, conformément à [[L-036]].

### L-047 — Un message d'erreur tronqué à la frontière native rend la récupération impossible (2026-07-16)
- **Contexte** : la lecture s'arrêtait silencieusement après ~4-5 pistes (≈ 15 min). Les `AudioSource` de la file embarquent le Bearer capturé au lancement ; `ACCESS_TOKEN_TTL_SECONDS` = 900. À l'expiration, la requête Range suivante reçoit 401 et ExoPlayer lève `TYPE_SOURCE` dont la CAUSE est `InvalidResponseCodeException: Response code: 401` — mais le fork n'envoyait à Dart que `exoError.getMessage()` = « Source error ». `_isAuthorizationFailure` ne matchait jamais → aucun refresh → arrêt. Second verrou : la récupération 401 était limitée à UNE tentative par file (`_authorizationRetriedRequest`), donc même détectée, une session > 2 expirations s'arrêtait.
- **Leçon** : (1) à chaque frontière (JNI, MethodChannel, plugin), transmettre la CHAÎNE de causes, pas le message du wrapper — un code HTTP invisible côté Dart rend toute politique de récupération aveugle ; (2) un anti-boucle « une fois par X » doit être dimensionné par rapport à la durée de vie de X : une file de lecture vit des heures, un access token 15 minutes — le garde-fou correct est une fenêtre de temps, pas un drapeau par file.
- **Conséquence** : `onPlayerError` remonte `describePlaybackError` (wrapper + causes, borné, sans header) ; récupération 401 réarmable (cooldown 30 s, horloge injectable) ; une piste irrécupérable est sautée (max 3 sauts consécutifs, réarmés après 5 s de lecture stable — sans ce délai, une file entièrement cassée en repeat-all bouclerait) ; journal `AudioDiagnostics` (ring buffer sans secret, exportable depuis `/dev/stretch-lab`, actif via `HOMESPOTIFY_AUDIO_DIAGNOSTICS=true`). Tests `long_session_test.dart` : 20 pistes, 404 isolé, sauts bornés, double expiration récupérée, anti-martèlement, refresh impossible.
  - **Mise à jour 2026-07-20** : le ring buffer initial et le harnais 20 pistes sont remplacés par le journal persistant rotatif, l'écran `/dev/audio-diagnostics`, les verrous single-flight/déduplication et le scénario 200 pistes / trois expirations décrit dans L-052/L-053 et `TD-Audio-2026-07-20`.

### L-046 — Un paramètre DSP qui exige un reset ne peut pas être piloté par une valeur continue (2026-07-16)
- **Contexte** : audit du timbre « robotique/métallique » des voix à 0,80x/1,20x/1,30x. La chaîne était saine (pas de formants, pas de freq map, pitch 1,0, Sonic neutre, une seule conversion PCM aller-retour, accumulateur fractionnaire exact à 0 frame sur 90 s). La cause mesurée (`quality_lab latch`) : le profil Signalsmith était sélectionné par plage de ratio, mais reconfigurer Signalsmith vide la STFT — impossible en cours de flux. Tout glissement du slider (1,04x → 1,30x) laissait donc le flux sur le profil du PREMIER ratio non-unitaire, `presetCheaper` 100/40 (recouvrement 2,5x), avec `profileChangePending=true` à jamais : l'utilisateur écoutait la pire config aux ratios extrêmes.
- **Leçon** : associer une configuration à reset obligatoire (géométrie STFT) à un paramètre modifiable en continu (ratio) garantit une désynchronisation silencieuse : la config suit le premier événement, jamais les suivants. Un « profil par plage » n'existe réellement que si chaque changement de plage passe par une frontière de flux — ce qu'un slider ne fait jamais. Corollaire : le nom d'un profil (« EXTREME_HQ ») ne dit rien de sa qualité perçue — 160 ms de bloc coûtaient 180 ms de latence et étalaient les transitoires vocaux.
- **Conséquence** : une seule configuration de production (`presetDefault` 120/30) pour tout le domaine 0,70–1,30x, bypass total à 1,00x ; les autres géométries ne sont accessibles que par l'override développeur appliqué aux frontières de reset (écran `/dev/stretch-lab`, seek sur place). Transition de ratio adaptative (40–160 ms selon \|Δ\|). Tests de non-régression : `exerciseStableProductionProfile` (aucun profil en attente après changement live), dérive fractionnaire, stéréo hard-pan, comptabilité post-rampe. Voir TECH_DECISIONS « Qualité du time-stretch ».

### L-045 — Un time-stretch Media3 doit remplacer la chaîne de tempo entière (2026-07-15)
- **Contexte** : ajouter un `AudioProcessor` à la chaîne par défaut aurait conservé le `SonicAudioProcessor` ajouté implicitement par Media3, donc appliqué deux fois la vitesse. Un traitement Signalsmith naïf ajoutait aussi sa latence à la durée totale et faussait la position au démarrage.
- **Leçon** : injecter une `AudioProcessorChain` complète dans `DefaultAudioSink`, rendre Signalsmith et Sonic mutuellement exclusifs, utiliser le préroll officiel `outputSeek`, puis fournir à Media3 la conversion playout ↔ média. Les compteurs entrée/sortie bruts ne sont pas une timeline valide pendant le préroll.
- **Conséquence** : le fork local de `just_audio` garde un lecteur, une queue et un `MediaItem` uniques ; le seek vide le STFT, le changement de piste force 1,00x, la pause conserve les buffers et toute panne native verrouille un fallback compatible sans oscillation.

### L-048 — Une source distante ne doit jamais court-circuiter l'inbox (2026-07-19)
- **Contexte** : importer directement les métadonnées d'un fichier téléchargé dans Drizzle aurait créé un second chemin d'ingestion, sans les garanties du watcher sur la stabilité du fichier, le hash, la déduplication et l'isolation par compte.
- **Leçon** : la récupération distante est uniquement un transport vers l'inbox. L'identité du dossier vient du Bearer, jamais d'un `userId` libre ; le réseau est limité à une liste d'origines HTTPS exactes, chaque redirection est revalidée, et le fichier reste invisible au watcher tant que le flux borné n'a pas été renommé atomiquement depuis `.part`.
- **Conséquence** : `/api/library/fetch-node` et `/api/library/import-remote-track` répondent `202`, exposent un statut sans révéler l'URL et n'écrivent aucune ligne métier en base. Une URL CDN résolue reste soumise à une allowlist exacte et le flux doit porter une vraie signature FLAC/WAV : un conteneur MP4 renommé `.flac` est refusé. Le watcher reste seul responsable du hash, de la déduplication et de l'import ; le mobile invalide la bibliothèque après la remise du fichier au watcher.

### L-049 — Un manifeste DASH annonçant le codec FLAC n'est pas un fichier FLAC (2026-07-20)
- **Contexte** : l'endpoint distant `/track/?id=...` répond `200` avec `{ version, data: { manifestMimeType, manifest, audioQuality, ... } }`. `data.manifest` est un XML DASH encodé en base64 ; ses modèles `initialization` et `media` servent des fragments `audio/mp4` dont la représentation annonce le codec `flac`.
- **Leçon** : le codec interne et le conteneur livré sont deux faits distincts. Des fragments fMP4 contenant du FLAC ne commencent pas par la signature `fLaC`, ne forment pas un `.flac` par simple concaténation et ne doivent jamais être renommés pour contourner la validation. Un log de diagnostic doit exposer seulement la structure (types et noms de champs), jamais le manifeste ou ses URL signées.
- **Conséquence** : le résolveur accepte plusieurs clés d'URL directe dans des enveloppes bornées. Un manifeste BTS JSON base64 peut fournir un fichier direct via `urls[0]`. Un manifeste DASH XML validé est confié à FFmpeg pour produire un véritable conteneur FLAC ; l'allowlist, la limite de taille et la vérification finale `fLaC` restent obligatoires. Le remux initial `-c:a copy` a ensuite été remplacé par la reconstruction lossless décrite dans L-054.

### L-050 — La résolution distante varie à la fois par instance et par chemin (2026-07-20)
- **Contexte** : selon l'instance Hi-Fi API, un même `trackId` peut être résolu par `/track/`, `/download`, `/stream` ou `/api/download`, sous forme de JSON, de flux direct ou de redirection HTTP.
- **Leçon** : la cascade doit couvrir le produit origines × chemins, dédupliquer le template configuré et borner chaque tentative. Capturer une redirection ne dispense jamais de valider sa cible HTTPS contre l'allowlist média, et les URL signées ne doivent pas apparaître dans les logs.
- **Conséquence** : le résolveur essaie le template `.env` en premier, puis quatre fallbacks connus sur chaque instance. Les réponses 301/302/303/307/308 fournissent une cible au worker sans précharger le média ; les flux et redirections restent soumis aux limites, à la revalidation et à la signature audio finale.

### L-051 — FFmpeg devient un client réseau lorsqu'il lit un MPD local (2026-07-20)
- **Contexte** : écrire un manifeste DASH dans un fichier temporaire puis lancer FFmpeg évite d'assembler les segments en Node.js, mais les URL du MPD sont alors téléchargées directement par le processus enfant.
- **Leçon** : l'allowlist doit être appliquée à toutes les références du MPD avant le lancement. Les DTD, entités externes, XLink, URL relatives et protocoles non HTTPS sont refusés ; FFmpeg reçoit en plus des listes de protocoles blanche/noire. Son stderr n'est jamais journalisé car il peut recopier des URL CDN signées.
- **Conséquence** : le MPD est borné et temporaire, FFmpeg est interrompu avec le job, la taille de sortie est surveillée, puis la signature `fLaC` est relue avant le renommage atomique. `FFMPEG_PATH` doit être visible depuis l'environnement réel du service, pas seulement depuis le terminal interactif.

# L-Phase-3B — Une position média n’est pas une durée écoutée

La différence entre deux positions est fausse dès qu’un utilisateur seek. La durée écoutée doit être cumulée avec une horloge monotone pendant les seuls intervalles réellement joués, puis envoyée comme maximum cumulatif idempotent. La file hors ligne doit être partitionnée par compte, sans jamais envoyer ce `userId` au serveur : le Bearer reste l’unique autorité.

### L-052 — Un callback d'erreur audio peut être livré plusieurs fois (2026-07-20)
- **Contexte** : le stream d'erreur et le callback asynchrone du player peuvent signaler la même panne native à quelques millisecondes d'intervalle. Les deux chemins lançaient alors une reconstruction de file concurrente.
- **Leçon** : une récupération doit avoir une identité, un verrou single-flight et une courte fenêtre de déduplication ; compter sur « un événement natif = une panne » n'est pas sûr.
- **Conséquence** : les erreurs 401 et non-401 ont des verrous distincts, un fingerprint borné et des événements `AUDIO_DUPLICATE_ERROR_SUPPRESSED`. Le test bloque volontairement la première reconstruction puis livre deux fois la même erreur et vérifie une seule reprise.

### L-053 — « Stream closed prematurely » n'identifie pas le fautif (2026-07-20)
- **Contexte** : les logs réels montrent deux fermetures prématurées sur `/api/tracks/:id/stream`, l'une en 200 et l'autre en 206, tandis que des requêtes voisines terminent après 11–13 secondes. L'ancien log ne contenait ni octets envoyés, ni premier chunk, ni événement d'abandon client corrélé.
- **Leçon** : un message terminal isolé ne permet pas de trancher entre fermeture du client, bascule réseau, erreur de fichier ou serveur. Il faut corréler auth, Range, ouverture, premiers octets, compteur d'octets et terminaison avec le même identifiant.
- **Conséquence** : le backend émet désormais les événements `STREAM_*` structurés avec un seul terminal et sans chemin sensible ; le mobile propage des identifiants de session/file/source. L'origine exacte des deux incidents historiques reste inconnue et doit être confirmée par un test téléphone avec la nouvelle instrumentation.

### L-054 — Remuxer un DASH/fMP4 conserve aussi ses horodatages défectueux (2026-07-20)
- **Contexte** : certains FLAC produits depuis des segments DASH démarraient vers 0:30 et exposaient une durée incohérente. Le mode `-c:a copy` recopiait les paquets et leurs PTS/DTS issus du streaming dans le conteneur final.
- **Leçon** : changer seulement de conteneur ne répare pas une chronologie cassée. `asetpts=PTS-STARTPTS` ne supprime que l'offset initial ; `asetpts=N/SR/TB` recalcule chaque PTS audio depuis le nombre d'échantillons et produit une timeline continue partant de zéro.
- **Conséquence** : le pipeline DASH décode les fragments, applique `asetpts=N/SR/TB`, puis réencode avec `-c:a flac`. Les échantillons PCM restent préservés par le codec lossless, mais le bitstream FLAC et son hash changent nécessairement.

### L-055 — Un lecteur local ne devient pas un lecteur d'arrière-plan après coup (2026-07-20)
- **Contexte** : HomeSpotify construisait et injectait son handler avant le rendu, puis tentait de le rattacher à `audio_service` après la première frame. Tout échec natif était absorbé et conservait le lecteur local : la musique fonctionnait au premier plan, mais Android ne voyait ni session média complète ni foreground service, aucune notification n'apparaissait et le processus pouvait être suspendu en arrière-plan. Le manifeste omettait aussi `MediaButtonReceiver`.
- **Leçon** : la notification média et la survie en arrière-plan ne sont pas des options UI ajoutables à un lecteur déjà actif. Le handler doit être construit par l'initialisation du service avant toute lecture ; un échec ne doit jamais dégrader silencieusement vers un mode qui promet une fonctionnalité qu'il ne peut pas assurer.
- **Conséquence** : `main()` attend désormais `AudioService.init<HomeSpotifyAudioHandler>` avant `runApp`; le constructeur reste sans appel natif bloquant, le manifeste déclare service et receiver, et `androidStopForegroundOnPause=false` maintient le service au premier plan jusqu'à `stop()`. L'expiration du JWT n'est pas supprimée : le refresh single-flight et la récupération 401 déjà testée conservent la session longue sans affaiblir l'authentification.

### L-056 — Une ressource Android résolue par son nom peut disparaître d'un APK release (2026-07-20)
- **Contexte** : malgré un handler correctement enregistré et un manifeste complet, aucune notification n'apparaissait et `dumpsys activity services` restait à `startForegroundCount=0`. Le téléphone répétait `IllegalArgumentException: You must specify an icon resource id to build a CustomAction`. Le rapport release marquait les drawables `audio_service_stop`, `pause`, `play_arrow`, `skip_next` et `skip_previous` comme « not reachable » : le resource shrinker les supprimait parce que `audio_service` les recherche dynamiquement depuis les chaînes `drawable/audio_service_*`.
- **Leçon** : la présence d'une ressource dans les sorties intermédiaires Gradle ne prouve pas sa présence dans l'APK final. Toute ressource atteinte uniquement par nom doit être protégée explicitement, puis vérifiée dans l'artefact produit et dans le journal du système réel.
- **Conséquence** : `android/app/src/main/res/raw/keep.xml` conserve `@drawable/audio_service_*`; le manifeste et `MainActivity` déclarent puis demandent `POST_NOTIFICATIONS`. L'APK release a été inspecté avec AAPT2 (cinq IDs présents), installé sans perte de données et validé sur Xiaomi Android 16 : `startForegroundCount=1`, `isForeground=true`, session `PLAYING`, notification visible, passage accueil réussi et transition vers la piste suivante après 45 s écran éteint en mode `Dozing`, sans nouvelle exception.

### L-057 — Renouveler le JWT après le 401 est trop tard pour une source audio longue (2026-07-20)
- **Contexte** : le service média et la notification restaient actifs sur téléphone, mais une requête Range de la piste suivante recevait 401 à l'expiration du JWT. Media3 fige le Bearer dans chaque `AudioSource`; même si la session applicative vient de tourner son token, la source native peut encore porter l'ancien.
- **Leçon** : une session audio longue exige deux niveaux complémentaires : renouveler avant `exp`, puis conserver une récupération 401 réactive. Quand le token courant diffère déjà de celui utilisé pour construire la source, il faut seulement reconstruire la file ; relancer `/refresh` consommerait inutilement une seconde fois un refresh token rotatif.
- **Conséquence** : `AuthSessionManager` planifie un refresh single-flight 90 s avant l'expiration et retente 30 s plus tard sur panne réseau sans déconnecter. Le handler mémorise uniquement l'en-tête utilisé par ses sources, ne le journalise jamais, détecte sa rotation et reprend au même index/position avec les headers courants. Les tests couvrent le timer et l'absence de double refresh.

### L-058 — Une recherche complète ne prouve pas que son manifeste contient le morceau complet (2026-07-20)
- **Contexte** : la recherche distante identifiait `PARAFFINE — Ajna`, album `L’HERMITE`, durée 134 s, mais la résolution du même identifiant livrait un MPD de 59,907 s (15 segments). Le pipeline ne transmettait que l'identifiant au job : le FLAC final perdait aussi titre, artiste et album, puis le watcher utilisait le numéro comme titre.
- **Leçon** : l'identité catalogue et l'intégrité média doivent être corrélées explicitement. Réencoder une timeline ne peut ni inventer les segments absents ni valider une durée ; accepter une signature `fLaC` seule garantit le conteneur, pas la complétude du morceau.
- **Conséquence** : titre/artiste/album/durée accompagnent désormais le `trackId`, sont validés, servent au nom lisible et aux tags FFmpeg. Avant le remux, la durée calculée depuis `SegmentTimeline` (ou celle déclarée par le MPD) doit correspondre à la recherche à 3 s/2 % près. Une source tronquée produit `source_duration_mismatch`, la cascade tente les autres chemins/origines et aucun faux morceau n'entre dans la bibliothèque.

### L-059 — Une recherche de catalogue et une acquisition audio sont deux produits distincts (2026-07-20)
- **Contexte** : le fetch distant multipliait les contrats fragiles (404 selon
  l'instance, manifests tronqués, métadonnées et timelines incohérentes), alors
  que le besoin utilisateur réel est de trouver vite un titre puis de le demander.
- **Leçon** : une recherche gratuite, rapide et fiable doit s'arrêter aux
  métadonnées officielles. La sélection devient une commande métier locale
  (`music_requests`), pas le début implicite d'un pipeline de téléchargement.
- **Conséquence** : iTunes Search est la source principale sans clé,
  MusicBrainz le complément canonique, et SQLite absorbe les recherches
  répétées. Le fetch-node/Lucida et leurs UIs sont retirés ; les leçons
  L-048–L-051, L-054 et L-058 sont conservées comme historique du pipeline
  supprimé. L'ajout audio reste un dépôt manuel dans l'inbox surveillée.

### L-060 — Une source canonique ne suffit pas à rendre un catalogue exploitable (2026-07-20)
- **Contexte** : MusicBrainz trouvait les entités rares, mais renvoyait plusieurs
  artistes homonymes sans photo, des albums sans pochette et aucune preview.
  iTunes seul laissait encore une part importante des recherches muettes.
- **Leçon** : identité, illustration et écoute sont trois capacités distinctes.
  La couverture utile vient d'une fusion de sources complémentaires, avec
  déduplication par identité et classement favorable aux résultats enrichis.
- **Conséquence** : Deezer public fournit photos, pochettes et previews ; iTunes
  reste un secours indépendant ; MusicBrainz et Cover Art Archive assurent le
  long tail canonique. Mesure réelle : `PARAFFINE — Ajna` est complet, et les
  10 premiers résultats `Ajna`/`Antidote` testés sont illustrés. Aucun de ces
  appels n'importe ou ne télécharge une piste complète.

### L-061 — Le premier homonyme d'une API artiste n'est pas forcément l'auteur recherché (2026-07-20)
- **Contexte** : `/search/artist?q=Ajna` plaçait en tête un homonyme à 9 fans,
  tandis que l'artiste de `AJCENSION` et `PARAFFINE` (ID Deezer `1197134`,
  22 408 fans) n'arrivait qu'en quatrième position.
- **Leçon** : une recherche artiste doit être corroborée par les titres portant
  réellement la requête. Le nom exact élimine le fuzzy ; le nombre de titres et
  leur rang départagent les homonymes avant le nombre de fans.
- **Conséquence** : Deezer lance en parallèle la recherche artiste et une
  recherche titres bornée, classe par preuve de titres puis popularité, et ne
  conserve que les noms exacts lorsqu'ils existent. Vérification réelle : la
  recherche `Ajna` place désormais l'ID `1197134` en premier et n'expose plus
  `ELIESG`, `NeS` ou les variantes sans rapport.

### L-062 — Une URL de preview signée ne peut pas partager le TTL des métadonnées (2026-07-20)
- **Contexte** : les résultats Deezer étaient mis en cache quatre heures avec leur URL `cdnt-preview`. Ces URLs portent un jeton `hdnea` expirant environ quinze minutes après la recherche ; le catalogue restait visible mais chaque bouton d'écoute réutilisait ensuite un lien mort. Le correctif artiste était lui aussi masqué par les pages de recherche V1 encore valides en cache.
- **Leçon** : la durée de vie d'une enveloppe cache doit être celle de son champ le plus éphémère. Modifier un algorithme de classement sans versionner son cache revient à continuer d'exécuter l'ancien algorithme en production.
- **Conséquence** : les pages contenant une preview vivent cinq minutes au maximum, ou jusqu'à soixante secondes avant l'expiration signée la plus proche. Deezer expose cette expiration dans `PreviewDescriptor.expiresAt` et `DISCOVERY_CACHE_SCHEMA_VERSION=2` invalide les résultats V1. Le filtre artiste exact est appliqué après la fusion de tous les fournisseurs, afin que les résultats fuzzy d'iTunes ou MusicBrainz ne réintroduisent pas le bruit supprimé par Deezer.

### L-063 — Une divergence de durée fournisseur n'est pas une nouvelle carte (2026-07-20)
- **Contexte** : `PARAFFINE — FAUVE` apparaissait une fois avec preview à 260 s et une seconde fois sans preview à 316 s ; `Paraffine — MyPollux` était aussi scindé parce qu'iTunes annonçait `explicit=false` tandis que MusicBrainz ne renseignait pas ce champ. Les identités visibles étaient identiques malgré des métadonnées contradictoires.
- **Leçon** : durée et indicateur explicite sont utiles pour corroborer une correspondance, mais trop hétérogènes entre catalogues pour servir de clé d'affichage. La version doit venir d'un marqueur sémantique visible (`Live`, `Remix`, `Acoustic`, etc.), pas de l'absence d'une donnée chez un fournisseur.
- **Conséquence** : titres et albums sont uniques par titre normalisé + artiste principal + empreinte de version. La fusion agrège preview, images, liens et références ; les œuvres homonymes d'artistes différents ainsi que les versions réellement nommées restent séparées. `DISCOVERY_CACHE_SCHEMA_VERSION=3` invalide les pages produites par l'ancienne règle.

### L-064 — Persister une file ne signifie jamais persister son Bearer (2026-07-21)
- **Contexte** : restaurer la file, l'index et la position après la mort du processus exige de sérialiser les sources, mais les `PlayerQueueItem` portent aussi les headers d'accès au flux.
- **Leçon** : une session de confort et une session d'authentification ont des cycles de vie différents. Copier l'objet runtime brut écrirait un secret expirant dans un stockage non prévu pour lui et pourrait mélanger deux comptes.
- **Conséquence** : le format persistant est un DTO explicite, versionné, lié à un seul `userId` et sans champ header. La restauration reconstruit les sources avec le token courant ; le logout efface la session locale.

### L-065 — Une panne réseau n'est pas une piste corrompue (2026-07-21)
- **Contexte** : la politique de longue session sautait une piste illisible, mais appliquée à une `SocketException`, elle pouvait parcourir trois titres puis arrêter toute la file alors que le problème concernait le réseau entier.
- **Leçon** : la décision de retry dépend de la classe d'échec. `connectivity_plus` accélère le retour, mais une interface Wi-Fi active ne garantit pas que le serveur soit joignable.
- **Conséquence** : timeout/socket/connexion, 408, 425, 429 et 5xx conservent la même piste et la même position. Le lecteur reprend au retour réseau et continue avec un backoff plafonné ; 404/416/décodage restent dans la politique de saut borné.

### L-066 — Une copie de fichier SQLite actif n'est pas une sauvegarde (2026-07-21)
- **Contexte** : SQLite fonctionne en WAL et le serveur tourne H24. Copier uniquement `.db` peut ignorer des transactions du WAL ou produire une restauration incohérente.
- **Leçon** : la sauvegarde doit utiliser l'API online backup, vérifier l'intégrité et porter sa propre preuve avant de devenir restaurable.
- **Conséquence** : le CLI crée un snapshot cohérent, exécute `PRAGMA integrity_check`, calcule SHA-256 et écrit un manifest. La restauration exige l'arrêt du service, revérifie la sauvegarde et garde une copie `.pre-restore-*` de la base remplacée.

### L-067 — Renouveler le token en mémoire ne modifie pas les sources Media3 déjà créées (2026-07-21)
- **Contexte** : les logs réels montrent un refresh réussi à 15:02:59, puis une lecture encore autorisée avec l'ancien JWT à 15:03:42. Dès l'expiration de cet ancien JWT, la même source `/api/tracks/12/stream` a produit 26 réponses 401 entre 15:05:17 et 15:06:26, sans nouvel appel au refresh. Le timer d'authentification fonctionnait ; la file native n'avait simplement jamais reçu le nouveau Bearer.
- **Leçon** : détecter une rotation seulement après une erreur 401 reste trop tard et dépend du moment où Media3 remonte son erreur après ses propres retries. Les headers d'une `AudioSource` étant immuables, la rotation de session doit être un événement explicitement propagé au lecteur.
- **Conséquence** : `main.dart` relaie chaque révision de session au handler. Si le Bearer courant diffère de celui de la file chargée, le handler reconstruit immédiatement toutes les sources au même index et à la même position, puis reprend si la lecture était demandée. Le changement de piste refait le même contrôle en filet de sécurité ; le 401 réactif reste seulement le dernier recours.

### L-068 — Supprimer une relation peut créer une piste « orpheline » que le boot restaure (2026-07-21)
- **Contexte** : retirer la dernière relation `user_tracks` masquait bien une piste dans l'instant, mais le backfill de démarrage la considérait ensuite comme un ancien fichier sans propriétaire et la réattribuait au OWNER. La piste revenait après redémarrage de l'application, du serveur ou installation d'un APK.
- **Leçon** : quand un mécanisme automatique adopte les entités sans relation, une suppression volontaire doit laisser une preuve durable distincte de l'absence historique de relation.
- **Conséquence** : `revokeTrack` conserve désormais la relation avec `is_visible=false`. Toutes les lectures métier restent filtrées sur les relations visibles, tandis que le backfill voit le tombstone et ne restaure jamais la piste. Un ajout explicite réactive la même relation et efface le masquage de recommandation.

### L-069 — `playing=true` ne garantit pas une timeline qui avance (2026-07-21)
- **Contexte** : la session réelle de `Back In Black` a atteint sa durée exacte (`256000 ms`), puis est restée plus de deux minutes sur cette position avec `playing=true` et un compteur d'écoute croissant. Media3 est resté en `ready` sans publier ni `completed` ni l'index suivant ; le mode répétition était désactivé.
- **Leçon** : l'auto-avance ne peut pas dépendre uniquement d'un changement d'état natif. Position, durée, index, intention de lecture et mode repeat doivent former un second signal indépendant, temporisé pour ne pas concurrencer une transition normale.
- **Conséquence** : un watchdog s'arme à moins de 250 ms de la fin lorsque la lecture reste `ready/playing`. Après deux secondes sur le même index, il force une seule auto-avance dans l'ordre effectif ; une transition, une pause, un changement de file ou repeat-one l'annule. Le dernier titre sans répétition est mis en pause proprement.

### L-070 — Un watcher seul ne garantit pas la détection récursive durable (2026-07-21)
- **Contexte** : les dépôts audio sont rangés par profil et peuvent contenir une arborescence artiste/album/disque. Un événement `fs.watch` peut être perdu pendant une veille, un redémarrage ou une rafale de copies, et son nom relatif n'est pas toujours fourni.
- **Leçon** : le watcher doit accélérer la détection, jamais constituer l'unique vérité. Une réconciliation récursive périodique, idempotente et single-flight est nécessaire ; le chemin du profil doit être établi avant le parcours pour ne jamais attribuer une piste au mauvais compte.
- **Conséquence** : chaque `storage/imports/<id>_<username>/inbox/**` est parcouru récursivement au démarrage, toutes les 60 secondes et à la demande du OWNER. Les liens symboliques, extensions non autorisées et suffixes temporaires sont ignorés. Une file bornée à deux analyses protège CPU, RAM et disque ; le tableau OWNER expose le dernier scan et l'activité de la file.

### L-071 — Un tableau de santé ne doit pas lancer une analyse audio lourde (2026-07-21)
- **Contexte** : le OWNER doit voir rapidement si l'API, le disque, les sauvegardes et les fichiers vont bien, mais exécuter `ffprobe` sur toute la bibliothèque à chaque ouverture rendrait le serveur H24 instable.
- **Leçon** : un écran de santé sert des faits déjà disponibles ou des vérifications de métadonnées peu coûteuses. Une corruption de contenu exige un job de fond distinct ; une absence ou une taille incohérente peut être signalée immédiatement comme fichier suspect sans inventer un diagnostic codec.
- **Conséquence** : l'overview compte les `PLAY_ERROR` sur 24 h, imports `FAILED`, chemins invalides, fichiers absents et tailles divergentes. Il expose aussi l'espace disque, le scheduler de sauvegarde et le scanner. Aucun fichier audio n'est chargé en mémoire et aucune qualité n'est déduite de son extension.

### L-072 — Une file Media3 en erreur conserve aussi ses anciens headers (2026-07-21)
- **Contexte** : pendant le test réel, le refresh continuait toutes les 13 minutes mais une file passée en `ERROR/idle` ne pouvait plus être reconstruite par l'observateur normal. Une reprise ultérieure a réutilisé son ancien Bearer et produit des 401 répétés sur `/api/tracks/8/stream`. Android ne remontait alors que `Source error`, sans code HTTP exploitable.
- **Leçon** : propager une rotation uniquement aux sources prêtes ne suffit pas. La représentation Dart doit toujours recevoir les nouveaux headers ; toute reprise depuis `idle` doit recréer la source native. La divergence entre Bearer courant et Bearer chargé est également un signal d'authentification plus fiable que le texte tronqué d'une exception Media3.
- **Conséquence** : `handleAuthorizationChanged` actualise la file même lorsqu'elle n'est plus prête, `play()` reconstruit la file au même index après une erreur, et une erreur générique avec Bearer tourné suit d'abord la récupération auth. Le TTL d'accès du déploiement H24 passe à 24 h pour qu'une session de quatre heures n'entraîne aucune reconstruction périodique ; le refresh rotatif et révocable reste actif.

### L-073 — Un arrêt apparent peut être une commande média injectée par le système (2026-07-21)
- **Contexte** : à 22:58:43, la lecture de `Billie Jean` s'est mise en pause sans erreur applicative, sans perte de focus audio, sans 401 et avec le service de premier plan encore actif. Les traces Android montrent un `KEYCODE_MEDIA_PAUSE` synthétique (`deviceId=-1`, `scanCode=0`) injecté dans la fenêtre `com.miui.home` par HyperOS 3, puis transmis à la session HomeSpotify. Le téléphone venait de revenir de Snapchat vers l'accueil et l'interface média Dynamic Island était active.
- **Leçon** : une session `PAUSED` n'est pas nécessairement causée par le lecteur, le réseau ou l'expiration d'une session. Les commandes média Android, les interruptions audio et les erreurs de source doivent être corrélées avant d'ajouter une reprise automatique qui annulerait aussi les vraies pauses utilisateur.
- **Conséquence** : HomeSpotify continue de respecter les commandes Pause explicites d'Android. Le moniteur longue durée sélectionne désormais le bloc de session `com.homespotify.homespotify_mobile` au lieu de prendre la dernière session de `dumpsys media_session`, qui pouvait être une session Google Cast inactive et produire de faux incidents `NONE`.

### L-074 — Le cache mobile n'a pas besoin de dupliquer l'archive lossless (2026-07-21)
- **Contexte** : télécharger chaque FLAC/WAV original sur le téléphone consommerait rapidement stockage et données mobiles, alors que le serveur H24 reste l'autorité de conservation et la source de qualité maximale en ligne.
- **Leçon** : archive canonique et copie d'usage mobile ont des objectifs distincts. Une dérivée Opus compacte est acceptable si elle est explicitement lossy, reproductible depuis le hash source et ne remplace jamais l'original. Transcoder sur le téléphone gaspillerait batterie/CPU et multiplierait les résultats non déterministes.
- **Conséquence** : décision initiale mono-profil Opus 128, remplacée le 2026-07-22 par L-076. Les invariants restent valides : génération serveur, Range, SHA-256, original intact et retour à l'original au titre suivant.

### L-075 — Un watchdog alimenté uniquement par la position peut rater la fin (2026-07-22)
- **Contexte** : une session réelle de 3 h 43 a enchaîné 69 pistes distinctes sans erreur serveur, mais huit lectures ont continué à être comptées plus de cinq secondes après leur durée. Deux sont restées `ACTIVE` dans l'historique. Sur `Billie Jean` à 1,30x, la position est passée de la fin vers zéro sans changement d'index, puis la même piste a continué. Le watchdog existant n'était appelé que par `positionStream` et pouvait donc ne jamais s'armer si Media3 cessait d'émettre ou rebouclait avant un échantillon dans les 250 dernières millisecondes.
- **Leçon** : le filet de sécurité de fin doit avoir sa propre horloge et reconnaître deux signatures indépendantes : position figée à la durée et retour fin vers zéro. La télémétrie serveur doit aussi garantir qu'une installation ne conserve pas plusieurs sessions actives si le client disparaît avant son événement terminal.
- **Conséquence** : un garde léger vérifie chaque seconde la position native, conserve le watchdog temporisé et force une auto-avance single-flight. Un retour d'au moins 90 % vers moins de deux secondes est traité comme une fin, sauf après un seek utilisateur ou en repeat-one. Le tracker cesse de cumuler à la durée et qualifie la transition naturelle en `PLAY_COMPLETED`. À l'ouverture d'une nouvelle session, l'API clôt les anciennes sessions `ACTIVE/PAUSED` de la même installation en `SUPERSEDED` ou `COMPLETED_POSITION`.

### L-076 — Une préférence de qualité hors ligne fait partie de l'identité du cache (2026-07-22)
- **Contexte** : le profil unique Opus 128 économisait l'espace mais ne laissait pas choisir entre compacité, haute qualité mobile et copie originale.
- **Leçon** : Opus 128, Opus 256 et l'original sont trois produits différents. Une taille Opus calculée avant encodage est une estimation, pas une mesure ; Opus 256 reste lossy. Le profil et la version d'encodeur doivent donc participer à la clé de variante et au manifeste local.
- **Conséquence** : Phase 1 propose les trois choix, recommande Opus 256, mémorise éventuellement la préférence par appareil et conserve une variante single-flight distincte pour chaque débit. L'original utilise son hash et sa taille exacts ; les Opus ne sont publiés qu'après ffprobe, durée, taille et SHA-256. Aucun profil ne remplace ni ne modifie la source canonique.

### L-077 — La première exécution à froid de la suite vitest complète peut produire de faux échecs (2026-07-22)
- **Contexte** : lors de la vérification du gate Phase 0, `pnpm vitest run` complet a échoué 10 tests sur 284 (8 fichiers) uniquement par `Hook timed out in 10000ms`, avec une phase de collecte de 177 s. Une relance immédiate, sans aucun changement de code, a donné 284/284 verts. Même schéma côté Flutter : `favorites_screen_test.dart` a échoué au chargement dans la suite complète puis est passé isolément et à la relance (305/305).
- **Leçon** : sur cette machine, la première exécution après démarrage/installation subit un coût de transformation/compilation qui dépasse les timeouts de hooks. Un rouge composé exclusivement de timeouts de hooks ou d'échecs `loading` n'est pas une régression tant qu'une relance ne le confirme pas.
- **Conséquence** : toujours relancer la suite avant de conclure à une régression ; ne jamais valider ou invalider un gate sur une seule exécution à froid.

### L-079 — Un démarrage qui exige le réseau rend le cache hors connexion inutilisable (2026-07-22)
- **Contexte** : la verticale hors connexion 1A était complète (téléchargement, manifeste, SHA-256, sélection de source locale), mais sur téléphone réel sans serveur l'application restait bloquée avant son interface. Cause racine : `HomeSpotifyMobileApp` ne montait l'app principale que sur `AuthStatus.authenticated`, et `AuthController.initialize()` ne quittait `loading` qu'après un appel réseau (`bootstrapRequired`/`me`). Aucune identité de compte n'était persistée : impossible de savoir « qui » sans le serveur. Les musiques téléchargées étaient donc inaccessibles précisément quand elles servent le plus.
- **Leçon** : une fonctionnalité hors connexion ne vaut que si le CHEMIN DE DÉMARRAGE fonctionne sans réseau. Il faut (1) une identité locale minimale persistée (jamais de token), (2) un état applicatif distinct « hors connexion » qui monte l'UI, (3) une frontière stricte entre panne de communication (réseau/timeout/5xx → jamais un logout) et refus d'authentification (401 confirmé serveur joignable → seule cause d'effacement).
- **Conséquence** : `AuthStatus.offline`, identité dans `flutter_secure_storage`, montage de l'app sur `authenticated` OU `offline`, bandeau « Mode hors connexion », reprise en ligne automatique. La source de compte de la couche hors ligne (`offlineUserIdProvider`) est découplée du contrôleur d'auth (bridge uniquement dans `main.dart`) pour éviter qu'un widget de bibliothèque instancie l'auth complète — ce qui cassait des tests widget qui ne stubbaient pas l'auth (une dépendance transitive nouvelle vers un provider « lançable au boot » doit rester optionnelle/injectable).

### L-080 — Une action de tap déclenchant de l'IO SQLite réel ne se règle pas sous fake-async (2026-07-22)
- **Contexte** : un test widget de l'écran Téléchargements tapait « Supprimer » puis vérifiait la disparition de la ligne du manifeste. Le handler de tap `await removeLocal()` fait de l'IO sqflite FFI réel ; sa continuation est liée à la zone fake-async de `testWidgets` et ne progresse jamais, même avec `pumpAndSettle` — le manifeste restait inchangé et le test échouait (ou pire, se figeait). Même famille de piège que L-016/fake-async déjà connue.
- **Leçon** : le contrat d'un widget dans un test fake-async, c'est l'UI (le dialogue de confirmation s'affiche, aucun appel serveur n'est émis), pas le résultat d'une IO réelle déclenchée par le tap. La correction sémantique (fichier + manifeste effacés, autre compte intact) se teste directement sur le service (`removeLocal`) hors zone widget, avec un store sqflite FFI attendu par `await`.
- **Conséquence** : test widget = dialogue + « jamais d'appel serveur » ; test unitaire du service = sémantique de suppression. Les préparations de manifeste dans les tests widget passent par `tester.runAsync` (IO réelle), jamais dans la zone figée.

### L-081 — Un filtre hors ligne ne peut pas filtrer une liste qui vient uniquement du réseau (2026-07-22)
- **Contexte** : les identifiants téléchargés étaient bien présents dans SQLite, mais `visibleTracksProvider` appliquait « Téléchargées » uniquement à `GET /api/tracks`. Hors connexion, la liste source était vide. Les pochettes restaient également des URL serveur et l'écran Téléchargements n'écoutait pas la session audio.
- **Leçon** : l'index hors ligne doit suffire à reconstruire une piste présentable et jouable. Tous les éléments nécessaires à l'expérience hors ligne — métadonnées minimales, fichier audio, pochette et état de lecture — doivent venir de sources locales ou de la session média, jamais d'un catalogue réseau supposé disponible.
- **Conséquence** : fusion locale/distante par `track_id`, catalogue distant prioritaire lorsqu'il existe, cache de pochette atomique partitionné par compte, `MediaItem.artUri` local et indicateur de lecture commun dans Téléchargements.

### L-078 — La provenance d'un secret ne légitime jamais une intégration (2026-07-22)
- **Contexte** : des passages non sourcés dans `CLAUDE.md` (proxy de téléchargement vers URL dynamiques, Lucida « explicitement autorisée », cookies de contournement « 100 % conformes » s'ils viennent du `.env`) et `TECH_DECISIONS.md` (« annule la Conclusion C pour les intégrations basées sur le .env ») contredisaient frontalement les audits SpotiFLAC, `ROADMAP.md` et les interdictions historiques du projet.
- **Leçon** : externaliser un token, un cookie ou une URL dans `.env` ne change ni la légitimité de l'API appelée, ni le caractère de contournement, ni les règles de sécurité. Une « autorisation » écrite dans un fichier du dépôt sans décision tracée du propriétaire n'a aucune autorité ; les documents qui pilotent le modèle doivent être relus avec la même vigilance que du code.
- **Conséquence** : passages retirés le 2026-07-22 sur instruction du propriétaire ; Conclusion C réaffirmée dans `TECH_DECISIONS.md`. Par la même décision, la règle de séquencement est amendée : le développement d'une phase suivante peut démarrer sur autorisation explicite du propriétaire (gate de développement), mais aucune phase n'est « terminée » ni « prête pour production » sans le gate de production de la phase précédente (session 4 h + restauration réelle pour Phase 0).

### L-079 — Un manifeste READY ne prouve pas que le fichier existe encore (2026-07-22)
- **Contexte** : la première implémentation hors ligne validait correctement chaque dérivée avant publication, mais ne réparait pas une ligne `READY` dont le fichier avait ensuite disparu. L'annulation mobile ne couvrait que le flux HTTP et la sélection locale ne comparait pas le hash mémorisé au hash courant de la piste.
- **Leçon** : la fiabilité d'un cache dépend de toute sa chaîne de vie. Il faut revérifier l'existence physique avant de servir, propager l'annulation à la préparation comme au transfert, conserver l'identité source jusqu'à la lecture et coordonner l'arrêt d'un processus externe avec la fermeture de la base.
- **Conséquence** : variante absente réarmée automatiquement, durée/débit ffprobe obligatoires, arrêt FFmpeg attendu avant SQLite, annulation du polling, erreurs disque explicites et rejet des copies locales liées à une ancienne empreinte source.

### L-082 — Un téléchargement groupé doit composer les jobs unitaires idempotents (2026-07-24)
- **Contexte** : album et playlist demandent progression globale, reprise et erreurs partielles, mais le backend possède déjà un contrat par piste avec single-flight, contrôle d'accès, Range et hash.
- **Leçon** : ajouter une seconde API batch ou un second pipeline d'encodage duplique les invariants les plus sensibles. Le groupe est une intention persistante côté appareil ; chaque item reste un job unitaire vérifiable.
- **Conséquence** : Phase 1B stocke groupe + items avant transfert, limite la concurrence mobile à un, réutilise `OfflineTrackDownloader` et relance uniquement les items non valides. Aucun nouveau contrat backend n'est nécessaire.

### L-083 — La reprise après crash exige une réconciliation physique, pas seulement un statut (2026-07-24)
- **Contexte** : le processus peut mourir après le renommage atomique du fichier mais avant le passage de l'item à `READY`, ou une purge peut retirer plus tard une copie appartenant à un groupe marqué terminé.
- **Leçon** : les deux sens de divergence existent. L'état persistant doit pouvoir adopter une copie valide comme rétrograder une copie absente ; existence, taille et empreinte source forment la vérité.
- **Conséquence** : chaque reprise et chaque purge réconcilient les items. Un `running` abandonné redevient `queued`, une copie publiée est adoptée, et un groupe privé d'une copie devient `partial` au lieu de mentir à l'interface.

### L-084 — Un fallback ne peut pas être inventé après la panne (2026-07-24)
- **Contexte** : la sélection Phase 1A remplaçait l'URI réseau par une URI locale
  uniquement lorsque `/health` échouait au chargement de la file. Une file
  créée en ligne perdait donc toute connaissance de sa copie locale ; après une
  panne, le handler ne pouvait que réessayer le même flux ou sauter la piste.
  La persistance rejetait en plus toute session dont la source active était
  `file://`.
- **Leçon** : les alternatives autorisées doivent faire partie de l'identité de
  chaque item avant l'incident. Une bascule fiable conserve source canonique,
  copie locale déjà vérifiée et position, sans reconstruire ces faits depuis le
  réseau au moment où celui-ci vient précisément de disparaître.
- **Conséquence** : la file et la session stockent les deux URI sans secret. Une
  vraie erreur réseau reprend localement au même index/position ; un simple
  signal de connectivité laisse finir le titre, et le retour réseau est appliqué
  à la transition suivante. Toute tentative de fallback qui échoue restaure la
  file précédente avant d'activer la récupération normale.

### L-085 — Un minuteur audio ne doit pas dépendre d'un écran (2026-07-24)
- **Contexte** : un `Timer` détenu par le lecteur visuel serait détruit dès que
  l'utilisateur revient à la bibliothèque ou qu'Android recrée la route, alors
  que la lecture continue dans le service de premier plan.
- **Leçon** : toute intention qui doit survivre écran éteint — sommeil, fin du
  titre, pause différée — appartient à la même autorité que la session média.
  L'UI ne fait qu'armer, afficher et annuler. Le mode « fin du titre » doit
  écouter la complétion logique ET le changement d'index natif, puisque Media3
  peut avancer avant que Dart traite l'état `completed`.
- **Conséquence** : `HomeSpotifyAudioHandler` possède le timer et son état
  observable. L'expiration conserve file/position, les purges l'annulent et
  aucune intention ancienne n'est restaurée après mort du processus.

### L-086 — Un effet d’amplification Android ne remplace pas un gain signé (2026-07-24)
- **Contexte** : ReplayGain peut demander aussi bien une atténuation qu’une amplification. `AndroidLoudnessEnhancer` expose un gain cible maximal pour augmenter le niveau ; l’utiliser comme si son domaine couvrait les valeurs négatives rendrait l’application dépendante d’un comportement non garanti et mélangerait le volume de l’utilisateur avec la normalisation.
- **Leçon** : un gain signé doit être séparé selon les capacités réelles du pipeline. La baisse se fait par multiplication linéaire du volume effectif, la hausse par l’effet Android, tandis que le volume affiché et choisi par l’utilisateur reste inchangé. La remise à zéro doit être sérialisée avant la mesure du titre suivant pour empêcher une ancienne opération asynchrone d’écraser le nouveau gain.
- **Conséquence** : HomeSpotify n’envoie jamais de valeur négative au `LoudnessEnhancer`, conserve une atténuation ReplayGain distincte dans le handler et teste explicitement la course changement de titre/remise à zéro. Sans mesure EBU R128 valide, aucun des deux chemins n’est activé.

### L-087 — Un script PowerShell d'inventaire doit être ASCII-sûr et porter un BOM (2026-07-25)
- **Contexte** : `scripts/windows_phase15_inventory.ps1` a d'abord produit un
  rapport aux accents corrompus, puis a refusé de s'analyser. Deux causes
  distinctes : PowerShell 5.1 lit un `.ps1` sans BOM comme de l'ANSI, et
  l'apostrophe typographique `’` est un délimiteur de chaîne **valide** en
  PowerShell — placée dans un littéral `'…n’est…'`, elle ferme la chaîne et
  décale le parsing jusqu'à une erreur lointaine et trompeuse.
- **Leçon** : tout script PowerShell du dépôt doit être écrit en UTF-8 **avec
  BOM**, et n'utiliser que l'apostrophe droite dans les littéraux. Les fichiers
  lus par le script doivent l'être avec `-Encoding UTF8` explicite, sans quoi un
  fichier UTF-8 sans BOM (ex. `HomeSpotifyApi.xml`) ressort doublement encodé.
- **Conséquence** : l'inventaire Windows produit un rapport lisible, et le
  script documente la contrainte en commentaire à l'endroit du piège.

### L-088 — Une règle de pare-feu par programme annule le cloisonnement par port (2026-07-25)
- **Contexte** : l'inventaire Phase 1.5 a montré une règle nominative
  « HomeSpotify API 3000 » correctement limitée au profil Private et une règle
  « HomeSpotify API via WireGuard » limitée à `10.8.0.1` — mais aussi une règle
  générique « Node.js JavaScript Runtime » autorisant `node.exe` en entrée sur
  **tous les ports**, profils Private ET Public. Le service tournant avec ce même
  `node.exe`, le port 3000 est joignable depuis le LAN Wi-Fi malgré l'intention
  des règles nominatives.
- **Leçon** : sous Windows, les règles entrantes sont une union d'autorisations.
  Une règle par programme couvrant tous les ports rend inutile toute restriction
  par port ou par adresse distante posée ailleurs pour le même exécutable. Le
  confinement doit être vérifié par l'ensemble des règles applicables, jamais par
  la seule règle que l'on vient d'écrire.
- **Conséquence** : le Storage Agent (port 3100) devra lier son écoute à
  `10.8.0.2` plutôt qu'à `0.0.0.0`, et la règle générique Node.js devra être
  traitée avant toute exposition réseau. Documenté dans
  `docs/VPS_PHASE15_WINDOWS_READINESS.md`.

### L-089 — Un HEAD utile ne peut pas passer par la réponse vide de Fastify (2026-07-26)
- **Contexte** : le Storage Agent doit répondre aux `HEAD` en annonçant la
  taille réelle de la piste sans jamais ouvrir de flux. Deux pièges se sont
  cumulés. D'une part, `exposeHeadRoutes` (actif par défaut) fabrique une route
  HEAD qui **rejoue le handler GET** et jette le corps : le `ReadStream` est bien
  ouvert, l'emplacement de concurrence consommé, le disque sollicité. D'autre
  part, `reply.send()` sans charge utile force `content-length: 0`, écrasant tout
  en-tête posé auparavant — un HEAD correct devenait impossible à écrire.
- **Leçon** : une route HEAD qui doit différer du GET se déclare explicitement,
  avec `exposeHeadRoutes: false`, et sa réponse s'écrit en direct via
  `reply.hijack()` + `reply.raw.writeHead()`. Vérifier l'absence d'ouverture de
  flux demande un test qui **compte les appels** à `createReadStream`, pas une
  simple lecture du code : le comportement provient d'une option par défaut du
  framework, pas du handler écrit.
- **Conséquence** : `services/storage-agent/src/server.ts` déclare HEAD à part et
  hijacke la réponse ; un test injecte un `createReadStream` compteur et exige
  zéro ouverture, un autre vérifie que le compteur de flux actifs reste à zéro.

### L-090 — Un compteur de concurrence doit se libérer sur un événement unique (2026-07-26)
- **Contexte** : un flux HTTP peut se terminer de cinq façons — fin normale,
  abandon client, erreur disque, fermeture par le framework, exception. Libérer
  l'emplacement dans chaque gestionnaire mène soit à une double libération
  (compteur négatif, limite contournée), soit à un oubli sur un chemin rare
  (fuite définitive : après huit incidents, l'agent refuse tout).
- **Leçon** : centraliser la libération sur l'événement `close` de la réponse,
  qui survient dans **tous** les cas, et rendre la fonction de libération
  idempotente. `writableFinished` distingue ensuite une fin normale d'un abandon
  pour le seul besoin du journal. Réserver l'emplacement après toutes les
  validations et avant l'ouverture du fichier : un refus ne coûte alors aucun
  descripteur.
- **Conséquence** : `StreamLimiter.acquire()` retourne une fonction de libération
  à usage unique, appelée uniquement depuis `reply.raw.once('close')`. Trois
  tests vérifient le retour à zéro après succès, après abandon client et après
  erreur disque.

### L-091 — Un doublon de clé JSON n'est pas observable après parsing (2026-07-26)
- **Contexte** : le schéma de l'index du Storage Agent devait refuser un
  « doublon d'identifiant ». Or `JSON.parse` applique la sémantique JavaScript :
  deux clés littéralement identiques sont silencieusement fusionnées, la
  dernière l'emportant. Aucune validation post-parsing ne peut les distinguer,
  et retrouver le doublon par analyse textuelle du JSON est fragile dès qu'un
  chemin contient un guillemet.
- **Leçon** : la seule forme de doublon réellement observable est l'**alias** —
  `"01"` et `"1"` désignant la même piste. Exiger une forme canonique stricte
  pour les clés (`^[1-9][0-9]*$`) supprime la classe entière d'ambiguïtés, au
  lieu de courir après une détection impossible.
- **Conséquence** : `parseStorageIndex` refuse toute clé non canonique, le CLI
  d'export n'émet que des clés canoniques, et la limite du parsing JSON est
  documentée dans `docs/VPS_PHASE2_STORAGE_AGENT.md` plutôt que masquée par un
  test qui prétendrait la couvrir.

### L-092 — `pnpm deploy` produit un artefact lié au store de l'utilisateur (2026-07-26)
- **Contexte** : préparer l'artefact de production du Storage Agent pour un
  service Windows tournant sous une identité dédiée. `pnpm deploy --prod` était
  le premier choix. pnpm 10.12.1 l'a refusé
  (`ERR_PNPM_DEPLOY_NONINJECTED_WORKSPACE`), et l'examen de la contrepartie a
  révélé un problème plus grave que le refus lui-même.
- **Leçon** : `pnpm deploy`, même en `--legacy`, matérialise `node_modules` par
  **liens durs vers le store pnpm global de l'utilisateur qui exécute la
  commande**. Un artefact « déployé » reste alors couplé à un profil
  utilisateur. Pour un service qui tourne sous une autre identité, c'est une
  dépendance invisible qui casse le jour où ce profil ou ce store est purgé.
  Un artefact de service doit être vérifiable : compter les liens résiduels et
  échouer s'il y en a.
- **Conséquence** : `scripts/deploy_storage_agent.ps1` reconstruit
  `node_modules` par `npm install --omit=dev` dans un staging isolé, contrôle
  qu'aucun lien symbolique ni jonction ne subsiste, puis publie par
  `robocopy /MIR`. 2040 fichiers, 7,35 Mo, 0 lien.

### L-093 — PowerShell 5.1 lit les `.ps1` en ANSI sans BOM (2026-07-26)
- **Contexte** : le premier script de déploiement, écrit en UTF-8 sans BOM et
  contenant des accents dans les chaînes et les commentaires, échouait à
  l'analyse syntaxique avec « Le terminateur " est manquant dans la chaîne » à
  une ligne parfaitement bien formée.
- **Leçon** : Windows PowerShell 5.1 décode un `.ps1` sans BOM avec la page de
  codes ANSI du système. Chaque caractère accentué devient deux octets, ce qui
  décale le contenu des chaînes et peut casser l'analyse à un endroit sans
  rapport avec la vraie cause. L'erreur pointe la conséquence, jamais l'origine.
- **Conséquence** : tout `.ps1` de ce dépôt est écrit en **UTF-8 avec BOM**, et
  la syntaxe est validée par
  `[System.Management.Automation.PSParser]::Tokenize()` avant toute exécution.
  Corollaire : `Set-StrictMode -Version Latest` est à proscrire dans les scripts
  qui appellent `pnpm` ou `npm` — leurs shims PowerShell déclenchent des
  `PropertyNotFoundStrict` sur des objets internes sans rapport avec le script.

### L-094 — Un contrôle anti-fuite sur sous-chaîne produit de faux positifs (2026-07-26)
- **Contexte** : le client de test HMAC vérifiait qu'aucun chemin ne fuitait
  dans `/health` en cherchant la sous-chaîne `musicRoot` dans la réponse. Le
  test a échoué. Or `/health` expose légitimement le booléen
  `musicRootAvailable`, dont le nom **contient** cette sous-chaîne. L'agent ne
  fuitait rien : c'est le contrôle qui était faux.
- **Leçon** : un contrôle de sécurité qui crie au loup sur un nom de champ perd
  sa valeur de signal — la réaction naturelle est de le désactiver, et la vraie
  fuite passe ensuite inaperçue. Un anti-fuite doit chercher la **donnée**
  (chemin absolu, nom de fichier audio, valeur du secret) et des **clés
  exactes**, jamais une sous-chaîne de nom de champ.
- **Conséquence** : `_detect_leaks()` teste des clés exactes (`"musicRoot":`,
  `"relativePath":`, `"entries":`) et des motifs de donnée (`[A-Za-z]:\\`,
  extensions audio), et rapporte la liste précise de ce qu'il a trouvé.

### L-095 — Ne pas comparer l'empreinte d'une base SQLite vivante (2026-07-26)
- **Contexte** : la procédure de rafraîchissement d'index devait prouver que
  l'export n'écrit pas dans la base. Premier réflexe : comparer le SHA-256 de
  `homespotify.db` avant et après. `Get-FileHash` a échoué — le fichier est
  ouvert en écriture par l'API. Le contournement par `FileShare.ReadWrite`
  fonctionne techniquement, mais aurait été pire : l'API écrit légitimement
  pendant l'export (historique de lecture, favoris), donc la comparaison aurait
  échoué au hasard, en production, sans qu'aucune anomalie n'existe.
- **Leçon** : un contrôle d'intégrité sur une ressource concurremment modifiée
  est un générateur de fausses alertes, pas une garantie. Quand la vraie
  garantie existe ailleurs et qu'elle est plus forte, il faut l'invoquer plutôt
  que d'en fabriquer une faible.
- **Conséquence** : `refresh_storage_agent_index.ps1` vérifie seulement la
  présence et l'absence de troncature de la base. La garantie de non-écriture
  vient du CLI, qui ouvre SQLite en `readonly` + `fileMustExist`, et de
  `storage-index-export.test.ts`, qui vérifie que la base est inchangée octet à
  octet après un export. Le raisonnement est écrit dans le script, pour que
  personne ne « rétablisse » le hash plus tard.

### L-096 — Un compte de service virtuel exige un mot de passe NULL, pas vide (2026-07-26)
- **Contexte** : bascule du service `HomeSpotifyStorageAgent` vers l'identité
  `NT SERVICE\HomeSpotifyStorageAgent`. `Invoke-CimMethod Win32_Service Change`
  avec `StartPassword = ''` retourne **le code 22, « paramètre invalide »**.
  L'alternative `sc.exe config … password= ""` ne marche pas davantage en
  PowerShell, qui supprime purement et simplement l'argument vide : `sc.exe`
  reçoit alors `password=` sans valeur.
- **Leçon** : « chaîne vide » et « absence de valeur » ne sont pas la même chose
  pour le SCM. Un compte virtuel n'a pas de mot de passe vide — il n'en a
  **aucun**, et le paramètre doit être **omis**, pas neutralisé. Aucune API qui
  force la présence du paramètre ne peut donc convenir, y compris WMI.
- **Conséquence** : `scripts/install_storage_agent_service.ps1` utilise
  `sc.exe config <nom> obj= "NT SERVICE\<nom>"` **sans aucun argument
  `password`**, puis relit `Win32_Service.StartName` immédiatement et échoue si
  la valeur appliquée diffère ou si elle correspond à une identité privilégiée.

### L-097 — WinSW 2.12 ignore silencieusement un `<depend>` contenant « $ » (2026-07-26)
- **Contexte** : le XML du Storage Agent déclare deux dépendances, `Tcpip` et
  `WireGuardTunnel$HomeSpotify-VPS`. Après `winsw install`, `sc qc` ne montre
  que `DEPENDENCIES : Tcpip`. Aucune erreur, aucun avertissement : la seconde
  dépendance a disparu. Or c'est précisément la plus importante — l'adresse
  `10.8.0.2` n'existe pas tant que le tunnel n'est pas monté, et l'agent refuse
  de démarrer s'il ne peut pas s'y lier.
- **Leçon** : une configuration acceptée sans erreur n'est pas une configuration
  appliquée. Tout élément de configuration qui porte une garantie
  opérationnelle doit être **relu depuis le système** après écriture, jamais
  supposé effectif parce que l'outil n'a rien dit.
- **Conséquence** : le script pose la liste explicitement via
  `sc.exe config <nom> depend= "Tcpip/WireGuardTunnel$HomeSpotify-VPS"` (le
  séparateur est `/` et la liste est remplacée en entier), puis relit
  `ServicesDependedOn` et avertit nommément si une dépendance manque encore.
  L'avertissement n'est pas bloquant : c'est une garantie d'ordre de démarrage,
  pas une propriété de sécurité, et les redémarrages bornés (15/60/120 s)
  couvrent un tunnel monté tardivement.

### L-098 — Un HEAD sans corps doit porter son code d'erreur en en-tête (2026-07-26)
- **Contexte** : le provider distant doit distinguer `TRACK_NOT_INDEXED` de
  `FILE_NOT_FOUND`. Les deux réponses de l'agent valent 404, et HTTP interdit
  tout corps utile sur HEAD : le JSON d'erreur n'arrive donc jamais au client.
- **Leçon** : si plusieurs erreurs partagent un statut sur une opération sans
  corps, leur discriminant stable doit vivre dans un en-tête dédié. Déduire le
  motif depuis `Content-Length`, le texte du message ou une seconde requête GET
  serait fragile et ouvrirait un flux précisément quand HEAD doit rester léger.
- **Conséquence** : l'agent ajoute `X-HS-Error-Code` à toutes ses erreurs. Le
  provider mappe `TRACK_NOT_INDEXED` vers 503 et `FILE_NOT_FOUND` vers 404. Un
  agent ancien sans l'en-tête produit par sécurité un 503 d'index suspect.

### L-099 — Une réponse HEAD complète n'est pas encore une socket réutilisable (2026-07-26)
- **Contexte** : le premier test keep-alive ouvrait deux ports clients malgré
  `Agent({keepAlive:true})`. Le code vérifiait `IncomingMessage.complete`, qui
  signifie que le message HTTP a été parsé, pas que l'événement `end` a rendu la
  socket au pool.
- **Leçon** : avant de considérer une réponse drainée, attendre
  `readableEnded`/`end`. Une optimisation de connexion se prouve côté serveur
  par la réutilisation effective du port, pas par la seule présence d'une option
  `keepAlive`.
- **Conséquence** : `stat()` reprend la socket seulement après la fin lisible du
  HEAD ; le test enchaîne deux HEAD et exige le même port client.
### L-100 — Un chemin HTTP direct doit répéter les headers contractuels (2026-07-26)
- **Contexte** : validation Phase 4.5 de `X-HS-Error-Code`. Les réponses 416
  HEAD et GET étaient écrites directement afin de préserver `Content-Range` et
  le corps vide ; elles contournaient donc le header centralisé dans
  `sendError`.
- **Leçon** : lorsqu'un handler utilise `reply.raw.writeHead`, `hijack` ou une
  réponse vide spécialisée, tout nouveau header contractuel doit être testé
  explicitement sur ce chemin.
- **Conséquence** : `INVALID_RANGE` est maintenant présent sur HEAD et GET 416,
  sans changer leur statut, leur corps ou leurs autres en-têtes.

### L-101 — Un build JavaScript n'est pas un artefact de déploiement complet (2026-07-26)
- **Contexte** : la première API parallèle Phase 4.5 quittait avant d'écouter.
  Son artefact contenait `dist/` et `package.json`, mais pas `drizzle/`.
  `migrate.ts` résout pourtant les migrations à l'exécution, relativement au
  JavaScript compilé. Les tests locaux passaient parce que l'arborescence source
  fournissait implicitement ces fichiers.
- **Leçon** : auditer toutes les lectures de fichiers effectuées à l'exécution
  avant d'assembler un artefact autonome. Compiler TypeScript ne copie ni les
  migrations, ni les templates, ni les autres ressources non TypeScript.
- **Conséquence** : l'artefact VPS inclut désormais `drizzle/` et le harnais
  refuse de transférer ou lancer une API sans `drizzle/meta/_journal.json`.
  Son préflight vérifie aussi les dépendances natives, SQLite, les permissions,
  les ports et la configuration avant le lancement.

### L-102 — Ne pas imbriquer du code interprété dans SSH depuis PowerShell (2026-07-26)
- **Contexte** : après correction de l'artefact, les deux API VPS ont démarré,
  mais la commande PowerShell → SSH → shell distant → `python3 -c` a perdu les
  guillemets entourant le code Python. Bash a tenté d'interpréter directement
  `import json; print(...)`.
- **Leçon** : chaque couche de shell possède ses propres règles de quoting.
  Une commande correcte dans un shell isolé devient fragile dès qu'elle traverse
  plusieurs parseurs. Les données structurées doivent être lues par un fichier
  exécutable transféré, avec chemins et clés passés comme arguments.
- **Conséquence** : les smoke tests et tests du provider sont désormais des
  scripts VPS autonomes. Un lecteur Python restreint extrait les quatre entiers
  autorisés de l'état JSON. Aucun `python3 -c` imbriqué ne subsiste, et un test
  de régression couvre notamment un chemin contenant des espaces.

### L-103 — Une preuve de log doit tolérer le buffering et parser le champ exact (2026-07-26)
- **Contexte** : les 36 contrôles distants Phase 4.5 étaient verts, mais le
  harnais concluait que `phase45-remote-propagation` manquait. Le journal WinSW
  contient pourtant 67 événements JSON avec cet identifiant, dont des
  `STORAGE_AGENT_REQUEST_COMPLETED` HEAD/GET réussis.
- **Leçon** : une recherche textuelle immédiate, filtrée par l'horodatage du
  fichier, confond visibilité différée du collecteur et absence fonctionnelle.
  Une preuve de corrélation doit employer un identifiant unique, parser le champ
  JSON exact, exiger un événement terminal réussi et réessayer pendant une
  fenêtre courte bornée.
- **Conséquence** : le harnais utilise désormais un requestId unique et un
  parseur dédié sur les journaux courants ou rotatifs. Il tente au maximum dix
  lectures espacées de 500 ms et exige méthode, trackId, événement terminal et
  statut 200/206. Un mode `-RequestIdOnly` permet de rejouer uniquement cette
  preuve, sans installation npm, flux complet, saturation ou arrêt de l'agent.
  L'exécution finale a retrouvé dès la première tentative le requestId
  `phase45-requestid-20260726T192509523-00ed8c22` dans un
  `STORAGE_AGENT_REQUEST_COMPLETED` HEAD 200 (`trackId=78`), puis a confirmé
  zéro secret et zéro listener résiduels. Cette preuve clôt la Phase 4.5 en GO.

### L-104 — Un cache audio sûr publie un objet, jamais un téléchargement (2026-07-26)
- **Contexte** : Phase 5 doit servir simultanément le client et le disque sans
  charger une piste entière en mémoire ni rendre visible un remplissage.
- **Leçon** : l'objet final est un résultat de transaction : fichier temporaire
  privé, backpressure sur chaque chunk, taille et SHA-256 validés, `fsync`, puis
  renommage atomique. Le nom final ou une ligne d'index ne suffisent pas seuls.
- **Conséquence** : les Range MISS bypassent, les `.part` ne sont jamais servis,
  l'abandon détruit l'amont, et l'index séparé ne référence que des objets
  complets. Les requêtes concurrentes bypassent plutôt que d'attendre un writer.

### L-105 — Une base de validation contient des données piégées : ne jamais y piocher « la première ligne » (2026-07-27)
- **Contexte** : le harnais Phase 5 choisissait sa piste d'abandon par
  `ORDER BY size_bytes ASC LIMIT 1`. La base de validation, copiée depuis la
  Phase 4.5, contient une piste **volontairement périmée** (`size_bytes = 4096`,
  `hash = "f" × 64`, absente de l'index du Storage Agent) servant à éprouver
  le chemin « index obsolète ». La plus petite piste réelle pesant ~9,2 Mo, la
  piste piégée était systématiquement retenue : l'agent répondait
  `404 TRACK_NOT_INDEXED` → `INDEX_STALE` → **503**, et le scénario
  d'abandon ne pouvait jamais démarrer.
- **Leçon** : un jeu de données de test contient par construction des entrées
  hostiles. Une sélection ordinale (« la plus petite », « la première ») y est
  un tirage au sort. Un critère de sélection doit énoncer ce que la donnée doit
  **être**, pas la place qu'elle occupe. Et la validation de forme ne suffit
  pas : `"f" × 64` est un SHA-256 parfaitement bien formé — seul un contrôle
  de **servabilité réelle** (un `HEAD` de bout en bout) écarte l'imposteur.
- **Conséquence** : `scripts/phase5_track_selection.py` centralise la
  sélection, avec plancher de taille, ordre déterministe et empreinte validée.
  `vps_phase5_write_env.py` (dimensionnement du cache) et
  `vps_phase5_cache_test.py` (choix de la piste) l'**importent tous les
  deux** : dimensionner pour une piste et tester avec une autre rendrait
  l'éviction non déterministe. Le test ajoute un `HEAD` obligatoire, et
  produit un **SKIP explicite** plutôt qu'un `ok=false` opaque si aucune
  candidate ne convient.
- **Corollaire sur les rapports** : un booléen d'acceptation agrégé sur dix
  conditions doit publier le détail de chacune. `ok=false` seul a coûté un
  aller-retour complet d'exécution VPS pour identifier laquelle avait cédé ;
  le harnais publie désormais `checks` et `failedChecks`.
### L-106 — Un harnais dont les scénarios partagent un état détruit ses propres préconditions (2026-07-27)
- **Contexte** : quatrième exécution réelle Phase 5. Les modes `-FinalizeOnly`
  et `-AbortOnly` étaient verts isolément, mais le mode complet échouait
  toujours sur le test hors ligne, en **503**. Les journaux donnent la
  séquence exacte : piste 78 promue (`contentHashPrefix=cf43ef5cb02c`,
  `objectCount=1`, `indexEntryCount=1`), puis scénario d'abandon sur la
  piste 79, puis `CACHE_EVICTION_STARTED` et
  `CACHE_EVICTED contentHashPrefix=cf43ef5cb02c sizeBytes=9165881`, puis
  `CACHE_FILL_ABORTED` avec `objectCount=0`, `indexEntryCount=0`. L'agent est
  ensuite arrêté et la piste 78 demandée : `CACHE_MISS` →
  `REMOTE_STORAGE_AGENT_UNAVAILABLE` → **503**.
- **Cause** : une limite unique, `AUDIO_CACHE_MAX_BYTES = max(small, second) + 1`,
  partagée par tous les scénarios. Cette valeur est **calibrée pour garantir
  l'éviction** — c'est ce qui rend le scénario d'éviction déterministe, et
  c'est exactement ce qui rend impossible tout scénario ayant besoin qu'un
  objet survive. Le 503 était le verdict **correct** du provider ; c'est le
  harnais qui avait supprimé ce qu'il s'apprêtait à tester.
- **Leçon** : un paramètre choisi pour forcer un comportement dans un scénario
  devient un piège dès qu'il est global. Des scénarios qui partagent une
  racine de cache, une limite ou un index ne sont pas des scénarios
  indépendants : ce sont les étapes d'un seul scénario, et l'ordre y devient
  une dépendance cachée. Corollaire : une précondition doit être **prouvée
  puis verrouillée** avant toute action irréversible ou coûteuse — ici,
  l'arrêt du Storage Agent.
- **Conséquence** : chaque scénario reçoit sa racine
  (`runtime/cache-finalize-offline`, `cache-abort`, `cache-eviction`) et sa
  capacité (large pour la finalisation et l'abandon, serrée pour la seule
  éviction), via `vps_phase5_switch_scenario.sh`. Le mode hors ligne s'exécute
  **immédiatement** après la finalisation, pendant que l'objet existe. Un mode
  `offline-precheck` bloquant écrit un laissez-passer uniquement si
  `objectCount == 1`, `indexEntryCount == 1`, l'objet, sa taille, son empreinte
  et un vrai `CACHE_HIT` sont tous prouvés ; sans ce fichier, le mode hors
  ligne **refuse de s'exécuter** au lieu d'interpréter un 503 ambigu. Chaque
  rapport publie désormais `scenario`, `cacheMaxBytes`, les compteurs avant et
  après, et `evictionsObserved`.

### L-107 — Une réponse HTTP terminée ne prouve pas que l'écriture disque est finie (2026-07-27)
- **Contexte** : le harnais Phase 5 comptait les objets du cache immédiatement
  après un GET MISS réussi et trouvait `objectCount=0`. Une exécution a même
  servi un second GET à 2,07 Mio/s là où la précédente donnait 118 Mio/s.
- **Cause** : `CacheFillStream` valide taille et empreinte, puis `fsync`,
  `close`, `rename` atomique, ligne d'index et enfin `CACHE_FILL_COMPLETED` —
  **tout cela après** que le dernier octet a été poussé vers le client. Comme
  la réponse porte un `content-length`, le client considère le corps terminé
  dès qu'il a reçu ce nombre d'octets, sans attendre le `end` du flux serveur.
- **Leçon** : la fin d'une réponse et la fin d'une transaction disque sont deux
  événements distincts. Mesurer l'état du disque juste après la réponse est une
  mesure fausse, pas un défaut du composant. Un test doit attendre une
  **condition terminale** — un événement de fin, ou l'objet final à la bonne
  taille — jamais un délai arbitraire, et jamais « tout de suite ».
- **Conséquence** : `wait_for_fill_terminal()` scrute par boucle bornée et
  accepte deux preuves indépendantes (événement, ou fichier final de taille
  exacte si la journalisation est muette). Corollaire de méthode : un `200`
  n'est pas un HIT. Un HIT n'est prouvé que par un `CACHE_HIT` portant le
  `requestId` exact de la requête ; sans journal exploitable, le verdict est
  `unknown`, jamais `false`.

### L-108 — Vérifier la capture des journaux au démarrage, pas à la fin du test (2026-07-27)
- **Contexte** : une exécution complète du harnais Phase 5 s'est déroulée
  jusqu'au bout avant qu'on découvre que `stdout` faisait zéro octet : aucun
  événement `CACHE_*` n'avait jamais été écrit, donc aucune preuve n'était
  possible. Cause : le `.env` du harnais portait `NODE_ENV=test`, et `app.ts`
  construit Fastify avec `logger: { enabled: config.nodeEnv !== "test" }`. Le
  logger était **entièrement inerte**, y compris les callbacks passés aux
  providers.
- **Leçon** : une exécution de validation coûteuse doit vérifier ses propres
  **instruments** avant de produire des mesures. Un harnais qui ne peut pas
  observer ne doit pas démarrer. Corollaire : un environnement de test n'est
  pas gratuit — `NODE_ENV=test` change le comportement observable du produit,
  donc une validation « réelle » doit tourner dans le mode réel
  (`production`), sans quoi elle qualifie autre chose que ce qui sera déployé.
- **Conséquence** : `vps_phase5_setup.sh` a une étape `verify_log_capture` qui
  échoue en sortie 3 si aucune ligne JSON structurée n'est capturée après que
  l'API répond, et publie les cibles réelles de `fd/1` et `fd/2`. Le `.env` du
  harnais est en `NODE_ENV=production`.

### L-109 — Une panne fournisseur doit suspendre la file, pas fabriquer des échecs (2026-07-29)
- **Contexte** : un challenge de sécurité ou un 429 était auparavant réduit à
  une erreur HTTP générique du processus. Chaque nouvelle demande pouvait donc
  relancer Chromium et aggraver le blocage.
- **Leçon** : l'état d'un fournisseur est global, persistant et distinct du
  cycle d'un job. Le cooldown ne constitue jamais une autorisation de relance :
  il rend seulement une probe manuelle possible.
- **Conséquence** : `provider_health` réserve une probe HALF_OPEN unique,
  `PAUSED_PROVIDER` garde les jobs visibles et dédupliqués, et les imports
  locaux déjà téléchargés continuent indépendamment. Les diagnostics stockés
  restent publics et bornés ; les preuves sensibles restent hors base et hors
  API.

### L-110 — Un test widget ne valide pas la compilation native d'un plugin (2026-07-29)
- **Contexte** : `file_picker 11.0.2` fonctionnait côté Dart et dans les tests,
  mais son module Android ne compilait pas ses sources Kotlin avec AGP 9.0.1.
  Le registrant Java référençait donc une classe native absente.
- **Leçon** : toute nouvelle dépendance Flutter native doit être qualifiée par
  un build de la variante réellement distribuée ; `flutter analyze` et
  `flutter test` ne compilent pas nécessairement son implémentation Android.
- **Conséquence** : le repli WAV/FLAC utilise désormais `file_selector`, plugin
  officiel compatible avec le Kotlin intégré d'AGP 9, et la validation inclut
  `flutter build apk --release` avec la configuration de production.

### L-111 — Une intervention humaine ne doit pas être simulée par le service (2026-07-30)

- **Contexte** : fermer immédiatement Chromium sur un challenge protège un
  service headless, mais empêche une personne connectée au serveur de terminer
  une vérification légitime dans une fenêtre visible.
- **Leçon** : séparer l'orchestration persistante du service et l'interaction
  graphique. Le service bloque et expose un état métier ; un helper explicite
  observe passivement le retour au formulaire normal sans automatiser le
  challenge.
- **Conséquence** : `MANUAL_VERIFICATION_REQUIRED` n'a ni compte à rebours ni
  retry headless. Le helper ne transmet que son résultat, et le circuit n'est
  déclaré sain qu'après le vrai import local.

### L-112 — Un état global d'intervention doit référencer son travail actif (2026-07-30)

- **Contexte** : migrer un ancien circuit challenge sans job éligible a produit
  un fournisseur demandant une intervention alors que l'interface ne pouvait
  présenter aucun import actif.
- **Leçon** : une transition distribuée entre une ligne fournisseur et une
  ligne de job doit être atomique et porter un invariant vérifiable.
- **Conséquence** : l'état manuel sans job actif cohérent est fermé
  automatiquement, sans ressusciter les échecs historiques.

### L-113 — Un fallback interactif doit séparer sélection, geste humain et preuve disque (2026-07-30)

- **Contexte** : proposer un second site après l'échec d'un provider crée trois
  risques distincts : sélectionner une homonymie, automatiser par accident le
  geste réservé à l'utilisateur, ou importer arbitrairement le dernier fichier
  d'un dossier partagé.
- **Leçon** : chaque frontière porte sa propre preuve. La ligne visible exige
  titre et artiste exacts ; le code ne possède aucune primitive de clic
  Download ; le fichier exige un snapshot antérieur, trois tailles stables et
  des métadonnées/durée compatibles. Une extension ou un nom de fichier ne
  constitue aucune de ces preuves.
- **Conséquence** : Monochrome reste un provider manuel distinct, avec holder
  global et statut actif. Le backend n'accepte son succès qu'après le pipeline
  local réel et un `trackId`, jamais sur le seul exit code du helper.

### L-114 — Une annulation doit être vérifiée à CHAQUE frontière asynchrone (2026-08-01)

- **Contexte** : le service de téléchargement marquait `cancelRequested`, puis
  demandait au moteur de s'arrêter. Mais entre la prise du job par le worker et
  l'appel réel à `provider.start()`, il y a plusieurs `await` (création des
  dossiers, inventaire du staging). Une annulation tombant dans cette fenêtre
  ordonnait l'arrêt d'un processus pas encore lancé — puis le processus
  démarrait quand même, et plus personne ne l'annulait : le job restait bloqué
  jusqu'au délai global.
- **Leçon** : marquer une intention d'annulation ne suffit pas. Toute étape
  asynchrone traversée entre la demande et le démarrage effectif doit relire
  cet état AVANT d'engager la ressource, et une seconde fois APRÈS l'avoir
  obtenue — car l'obtention est elle-même asynchrone.
- **Conséquence** : `processItem` contrôle l'annulation juste avant
  `provider.start()` (sortie immédiate en `cancelled`, aucun processus lancé)
  et juste après (arrêt immédiat du processus fraîchement démarré). Un test
  déterministe bloque la phase de préparation pour verrouiller la régression.

### L-115 — Une allowlist de domaines ne se décrit pas par un motif générique (2026-08-01)

- **Contexte** : Amazon Music étant régional, le motif
  `^music\.amazon\.[a-z]{2,}(\.[a-z]{2,})?$` semblait raisonnable. Il accepte
  `music.amazon.evil.com` — un sous-domaine que n'importe qui crée en quelques
  minutes sur son propre domaine.
- **Leçon** : un motif conçu pour couvrir « toutes les variantes légitimes »
  couvre aussi les variantes hostiles qui partagent le même préfixe. Pour une
  frontière de sécurité, seule une liste explicite d'hôtes est vérifiable.
- **Conséquence** : les TLD Amazon Music sont énumérés explicitement, côté
  backend ET côté Flutter, et un test couvre spécifiquement le sous-domaine
  trompeur. Même règle pour les suffixes : `endsWith('.qobuz.com')` et non
  `endsWith('qobuz.com')`, sans quoi `notqobuz.com` passerait.

### L-116 — Un moteur externe ne remonte pas forcément le chemin de son résultat (2026-08-01)

- **Contexte** : `EngineEvent` d'Antra porte bien un champ `file_path`, mais
  `emit_event` de sa JSON CLI ne le recopie pas dans la charge utile. Le chemin
  final n'est donc jamais visible depuis l'extérieur, alors que le champ existe
  dans le modèle interne.
- **Leçon** : la présence d'un champ dans le modèle d'un outil ne garantit pas
  sa présence dans son contrat de sortie. Lire l'émetteur, pas la structure.
- **Conséquence** : plutôt que de modifier Antra ou de ramasser « le fichier le
  plus récent », chaque job reçoit un dossier de staging dédié dont
  l'inventaire est relevé avant lancement. Le contexte remplace le chemin
  manquant, et la règle reste valable si une future version d'Antra publie
  enfin ce chemin.

### L-117 — L'URL soumise à un moteur détermine sa stratégie de sources (2026-08-01)

- **Contexte** : classer les URL candidates par « qualité du service » semblait
  naturel. La lecture de `core/service.py` d'Antra montre autre chose : une URL
  Deezer, Tidal ou Amazon applique `source_rule="exclusive"` et verrouille le
  moteur sur un unique adaptateur, tandis qu'une URL Spotify n'applique aucun
  `source_intent` et laisse toute la chaîne de résolution disponible.
- **Leçon** : dans une chaîne de repli, le premier candidat ne doit pas être
  « le meilleur service » mais « celui qui laisse le plus d'options au moteur ».
  Un service excellent mais verrouillé échoue en bloc ; un service moyen mais
  ouvert retombe sur ses pieds.
- **Conséquence** : `sourceRank` suit spotify > qobuz > apple > tidal > deezer >
  amazon, et le commentaire cite le fichier qui le justifie — sans quoi une
  relecture future prendrait cet ordre pour une préférence esthétique.

### L-118 — « Illisible » et « hors specs » sont deux diagnostics différents (2026-08-01)

- **Contexte** : le détecteur classait tout refus d'`analyzeAudioFile` en
  `unreadable`. Le test réel a montré deux sources livrant du FLAC 32 bits :
  fichiers parfaitement valides, simplement hors de la politique d'ingestion
  16/24 bits du projet. Le journal annonçait « fichier illisible » — on aurait
  cherché une corruption inexistante.
- **Leçon** : un code d'erreur qui agrège deux causes distinctes envoie le
  diagnostic dans la mauvaise direction, d'autant plus quand la cause réelle est
  une règle du projet et non un défaut du fichier.
- **Conséquence** : code `FORMAT_REJECTED` distinct, toujours éligible au repli,
  et test verrouillant le cas FLAC 32 bits.

### L-119 — Un staging par tentative doit être purgé à la fin du job (2026-08-01)

- **Contexte** : isoler chaque tentative dans son propre dossier a résolu
  l'ambiguïté de détection, mais le test réel a laissé deux FLAC de 37 Mo par
  job — ceux des sources rejetées — sans que rien ne les reprenne.
- **Leçon** : la règle « ne jamais détruire un enregistrement valide » protège
  ce qui n'a pas encore été traité, pas ce qui a été explicitement écarté. Les
  fichiers acceptés ayant été DÉPLACÉS vers l'inbox, ce qui reste dans le
  staging est du rebut par construction.
- **Conséquence** : purge de l'arborescence du job sur état terminal, SAUF
  après annulation — où un fichier complet peut exister sans avoir été jugé.

### L-120 — Un écran qui doit trancher entre deux parcours n'en a en réalité qu'un seul de légitime (2026-08-01)

- **Contexte** : l'installation d'un morceau passait par quatre entrées de
  profil (Mes demandes, Télécharger un lien, Importer une musique, File
  d'installation) et un écran de recherche à quatre onglets. Chaque bouton
  installait « un peu » : l'un créait une demande à valider, l'autre lançait un
  téléchargement direct, un troisième repliait sur une demande quand le moteur
  n'était pas configuré.
- **Leçon** : quand un même geste utilisateur peut aboutir à deux mécanismes
  différents selon l'état du serveur, ce n'est pas de la robustesse, c'est une
  ambiguïté de produit. L'utilisateur ne sait plus ce que « Installer » veut
  dire, et le code porte deux pipelines qu'il faut maintenir à l'identique.
- **Conséquence** : un seul écran, un seul bouton, un seul contrat
  (`POST /api/downloads/search`). Le système de demandes est supprimé, pas
  désactivé — un repli conservé « au cas où » aurait recréé la même ambiguïté.

### L-121 — Une confirmation ne peut pas être déclenchée par la fin de l'appel qui la provoque (2026-08-01)

- **Contexte** : l'écran annonçait le succès juste après `await install()`.
  Cet appel ne fait que **créer** le job ; son issue arrive plusieurs secondes
  plus tard par le SSE. La confirmation ne s'affichait donc jamais, et le test
  widget le prouvait dès la première exécution.
- **Leçon** : avec un travail qui vit côté serveur, la fin de la requête HTTP
  n'est pas la fin de l'action. Toute annonce doit s'accrocher à la
  **transition d'état** observée, pas au retour de la fonction qui l'a lancée.
- **Conséquence** : `ref.listen` sur l'état d'installation + un ensemble de
  clés déjà annoncées, pour qu'un état terminal réémis ne produise qu'une seule
  confirmation. Corollaire : un état simplement *retrouvé* au retour sur
  l'écran est pré-marqué comme annoncé — il s'affiche, il ne notifie pas.

### L-122 — Un indicateur de progression rend `pumpAndSettle` inutilisable (2026-08-01)

- **Contexte** : trois tests widgets de l'installation ont échoué en
  « pumpAndSettle timed out ». Rien n'était cassé : la carte affichait un
  `CircularProgressIndicator`, qui anime indéfiniment par construction.
- **Leçon** : `pumpAndSettle` attend l'absence de frame planifiée. Tout écran
  qui affiche un travail en cours ne se stabilise jamais ; l'échec ressemble à
  un blocage applicatif alors qu'il décrit l'état attendu.
- **Conséquence** : `pump()` (éventuellement répété avec un délai court) sur
  tout test traversant un état actif, et `pumpAndSettle` réservé aux états
  terminaux.

### L-123 — Dans `testWidgets`, toute E/S réelle doit passer par `runAsync` (2026-08-10)

- **Contexte** : deux tests widgets de l'assistant de mise à jour ne
  terminaient JAMAIS — ni succès, ni échec, ni même le `--timeout 30s`. Le
  processus `flutter_tester` tournait sans avancer.
- **Cause** : `testWidgets` exécute le corps du test dans une horloge figée.
  Un `await` sur une vraie E/S (SharedPreferences, HTTP, fichier) ne se résout
  jamais tant que l'horloge n'avance pas, et le délai du test étant lui-même
  porté par cette horloge, il ne se déclenche pas non plus. Le symptôme
  ressemble à un blocage applicatif alors qu'il n'y a aucune boucle.
- **Conséquence** : toute préparation asynchrone RÉELLE d'un test widget passe
  par `await tester.runAsync(() => …)`. Corollaire de diagnostic : un test qui
  ignore son propre `--timeout` accuse l'horloge de test, pas le code testé.

### L-124 — Un état Riverpod ne survit pas seul à un état déjà connu (2026-08-10)

- **Contexte** : l'assistant de mise à jour n'apparaissait pas alors que
  `shouldPrompt` était vrai juste avant le montage. Le `initState` de
  l'enveloppe déclenchait une vérification automatique qui repassait
  immédiatement l'état en `checking`, écrasant le résultat déjà obtenu.
- **Leçon** : un déclencheur « au montage » doit vérifier ce qui est DÉJÀ connu
  avant de repartir de zéro. Sinon le remontage d'un widget racine (bascule
  connexion → application) annule silencieusement un résultat valide, un
  « Plus tard » ou un téléchargement en cours.
- **Conséquence** : `AppUpdateState.updatePending` court-circuite la
  vérification automatique, l'instant de la dernière vérification est mémorisé
  pour les contrôles manuels AUSSI, et le contrôleur appelle `ref.keepAlive()`
  pour survivre au remontage de son observateur.

### L-125 — PowerShell traite l'apostrophe typographique comme un délimiteur de chaîne (2026-08-10)

- **Contexte** : `scripts/publish_android_update.ps1` refusait de se charger avec
  des erreurs de syntaxe absurdes (« l'opérateur < est réservé », accolade
  manquante) sur des lignes parfaitement valides, situées bien après la vraie
  cause.
- **Cause** : PowerShell accepte `’` (U+2019) et `‘` comme délimiteurs de chaîne
  au même titre que `'`. Une apostrophe typographique écrite DANS une chaîne
  simple la ferme prématurément — `'... de l’APK'` devient deux chaînes — et le
  parseur se désynchronise pour tout le reste du fichier.
- **Conséquence** : aucun caractère typographique dans un script PowerShell.
  Corollaire : un `.ps1` contenant des accents doit être écrit en **UTF-8 AVEC
  BOM**, sinon Windows PowerShell 5.1 le lit en ANSI. Contrôle rapide avant
  toute exécution :
  `[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$null,[ref]$errs)`.

### L-126 — Une même règle métier dupliquée en quatre motifs finit par diverger (2026-08-10)

- **Contexte** : demande d'installation `LONOWN — addiction` (version normale)
  depuis le téléphone. Le backend a téléchargé et proposé `addiction (Slowed)`,
  deux fois (jobs `b481f6e0…` et `9a394fd8…`, 2026-08-10 17:42 UTC).
- **Cause** : `normalizeForMatch` supprime les parenthèses, donc
  `addiction (Slowed)` et `addiction` ont la MÊME clé d'identité. Seule
  l'empreinte de version les sépare — et le motif `ALT_VERSION_RE` existait en
  **quatre copies divergentes** (`catalog/merge.ts`, `download/candidate-resolver.ts`,
  `discovery/preview-provider.ts`, `discovery/apple-music-catalog-provider.ts`).
  Celle de la FUSION ignorait `slowed`, `sped up` et `nightcore` : les deux
  pistes ont fusionné en une seule carte, les cinq URL (dont celle de la version
  normale) ont hérité du titre de la version ralentie, et la version normale est
  devenue **inatteignable** — aucun score en aval ne pouvait la rattraper.
- **Conséquence** : motif unique dans `services/api/src/lib/version-identity.ts`,
  interdiction d'en refaire une copie locale. Et surtout : une identité de
  version est une **barrière fail-closed** (le candidat est retiré du jeu), pas
  une pénalité de score — un score se rattrape, une identité non.

### L-127 — Le compte de service virtuel n'hérite d'aucun droit d'écriture sous `ProgramData` (2026-08-10)

- **Contexte** : `PUT /internal/storage/index` du Storage Agent répondait 500
  (`INDEX_WRITE_FAILED`) — et n'avait en réalité **jamais** abouti depuis sa mise
  en service (0 `STORAGE_AGENT_INDEX_PUBLISHED` dans tout le journal). Le
  symptôme côté téléphone : « SQLite est à jour mais l'index distant n'a pas été
  publié », alors que l'index servi était correct.
- **Cause** : le service tourne sous `NT SERVICE\HomeSpotifyStorageAgent`, qui
  n'a que les droits hérités de `BUILTIN\Utilisateurs` : `(RX)` sur
  `data\index.json`, et sur le dossier `(WD,AD,WEA,WA)` — donc **création
  autorisée, remplacement interdit**. L'écriture atomique
  (fichier `.part` → `rename` sur la cible) échoue au `rename`, faute de DELETE
  sur le fichier existant. L'index restait vivant uniquement parce que le script
  de rafraîchissement officiel l'écrit **en contexte élevé**, hors agent.
- **Conséquence** : un compte de service virtuel a besoin d'un ACE **explicite**
  `(M)` sur le dossier ET sur le fichier qu'il remplace ; l'héritage `ProgramData`
  ne suffit jamais. Corollaire : un `rename` atomique n'est pas testé tant qu'il
  n'a pas écrasé une cible EXISTANTE appartenant à quelqu'un d'autre.

### L-128 — Un checkpoint (SHA) ne désigne pas un worktree ; vérifier HEAD avant de lancer une vague (2026-08-10)

- **Contexte** : démarrage de la Vague 4 Direction 33, censée continuer depuis
  le checkpoint `1927db5`. Le worktree ouvert par défaut pour la tâche
  (`homespotify-cutover-d1-3eb1be`, branche `claude/wave-4-direction-33-a1f932`)
  était en réalité sur `f09cc53`, un ancêtre STRICT de `1927db5` — le design
  system Direction 33 (ClayHeader, SoftCard, AppColors…) et les vagues 1-3
  n'y existaient tout simplement pas.
- **Leçon** : un SHA de checkpoint est un point dans l'historique global du
  dépôt, pas une garantie sur l'état du worktree où l'agent démarre. Plusieurs
  worktrees peuvent référencer des branches ayant divergé bien avant ou après
  ce SHA (ici, fusionner `1927db5` aurait aussi ramené ~50 commits backend/
  Antra/VPS totalement hors sujet, interdits par `CLAUDE.md` dans ce
  worktree). Le bon réflexe : `git log --oneline -5` + `git merge-base HEAD
  <checkpoint>` AVANT toute lecture de code, pour confirmer que le worktree
  courant contient bien le travail attendu plutôt que de supposer que le SHA
  cité suffit à le prouver.
- **Conséquence** : la Vague 4 a été exécutée dans
  `homespotify-c2-db-handoff-66ad37` (déjà sur `1927db5`), pas dans le
  worktree ouvert par défaut. Toujours confirmer avec l'utilisateur avant de
  changer de worktree en cours de tâche plutôt que de merger/cherry-picker
  silencieusement pour combler l'écart.
