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

# L-Phase-3B — Une position média n’est pas une durée écoutée

La différence entre deux positions est fausse dès qu’un utilisateur seek. La durée écoutée doit être cumulée avec une horloge monotone pendant les seuls intervalles réellement joués, puis envoyée comme maximum cumulatif idempotent. La file hors ligne doit être partitionnée par compte, sans jamais envoyer ce `userId` au serveur : le Bearer reste l’unique autorité.
