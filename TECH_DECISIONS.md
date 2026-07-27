# TECH_DECISIONS.md — HomeSpotify

Registre des décisions techniques. Toute nouvelle décision ou changement passe par ce fichier. Statuts : **définitive** (remise en cause = discussion explicite) / **temporaire** (réévaluation prévue).

## Stack recommandée

| Domaine | Choix | Statut |
|---|---|---|
| Backend | Node.js LTS + TypeScript + Fastify | définitive |
| Base de données | SQLite (WAL) + Drizzle ORM | définitive (SQLite) / temporaire (Drizzle) |
| Migrations SQLite additives critiques | Migration Drizzle normale + réparation idempotente en code hors journal pour les tables/index indispensables ; test de boot sur une base legacy dont `__drizzle_migrations.created_at` est supérieur au `when` de la migration manquante. Le journal reste strictement monotone, mais sa correction seule ne répare jamais une base déjà avancée | définitive (process, 2026-07-14) |
| Audio (analyse/validation) | ffmpeg + ffprobe (binaires externes) | définitive |
| Tags | music-metadata | temporaire |
| Scanner | scan complet + watcher chokidar | temporaire |
| Format d'ingestion & stockage | WAV PCM 16 bit / 44,1 ou 48 kHz + FLAC lossless 16/24 bit / 44,1, 48, 88,2, 96, 176,4 ou 192 kHz, conservés nativement | définitive (mis à jour 2026-07-09) |
| Extraction tags & qualité | music-metadata (RIFF INFO + ID3v2 embarqué + pochette) | définitive |
| Upload | @fastify/multipart, limite 200 Mo (min 150) | définitive |
| Streaming mobile | WAV/FLAC natifs via HTTP Range | définitive |
| Client v1 | App mobile Flutter Android-first | définitive (décidé 2026-07-08) |
| App mobile | Flutter + just_audio + audio_service | définitive |
| Service média Android | `AudioService.init<HomeSpotifyAudioHandler>` attendu avant `runApp`, handler construit sans appel natif bloquant, foreground service `mediaPlayback` + `MediaButtonReceiver`, `androidStopForegroundOnPause=false`; `POST_NOTIFICATIONS` demandée sur Android 13+ et `res/raw/keep.xml` conserve `@drawable/audio_service_*` dans l'APK release; aucun fallback silencieux vers un lecteur local sans notification | définitive (2026-07-20, validée sur Xiaomi Android 16) |
| Réseau client mobile | dio | définitive |
| Cache offline mobile | sqflite + path_provider ; choix par téléchargement entre Ogg/Opus 128 kb/s VBR, Ogg/Opus 256 kb/s VBR (recommandé) et original WAV/FLAC ; dérivées créées côté serveur, source intacte | définitive (profils, 2026-07-22) |
| State management mobile | Riverpod | définitive |
| Auth | Comptes locaux, Argon2id, JWT + refresh révocable | définitive (principe) |
| Accès distant | WireGuard via Tailscale, pas d'exposition publique | définitive (v1) |
| Reverse proxy | Caddy | temporaire |
| Déploiement | Docker Compose | définitive |
| Logs | pino (JSON structuré) | définitive |
| Monitoring | Uptime Kuma + endpoint /health | temporaire |
| Sauvegardes | restic (fichiers) + VACUUM INTO (SQLite) | temporaire |
| Enrichissement métadonnées | MusicBrainz + Cover Art Archive | définitive |
| Package manager | pnpm 10 + workspaces (sans Turborepo/Nx) | définitive (pnpm) / temporaire (sans orchestrateur) |
| Tests | Vitest (DB SQLite `:memory:` pour les tests d'API) | définitive |
| Exécution dev | tsx watch ; build via tsc | temporaire |
| Lint | Aucun linter pour l'instant (TypeScript strict seul) | temporaire |
| Mobile : plateforme prioritaire | Android d'abord | définitive (v1) |
| OS serveur hôte | Windows 11 | définitive (confirmé 2026-07-08) |
| Ingestion masse | CLI `scan` (hors requête HTTP), dédup par hash, dossiers gérés exclus | définitive |
| Téléchargement original | Route `download` (`Content-Disposition`, Range-resumable) + `etag`/`lastModified` au listing ; export explicite, distinct du cache mobile compact | définitive (mise à jour 2026-07-21) |
| Navigation mobile | GoRouter (`/`, `/albums`, `/artists`, `/favorites`, `/playlists`, `/settings`, `/discover`, `/catalog-search`, `/requests`, `/player`) ; les routes d'import distant `/node-fetch` et `/remote-search` sont supprimées ; retour `/player` = écran précédent via `closePlayer()` ; thème global sombre + transitions custom fade/slide ; paramètres de route = identifiants opaques URL-safe, jamais de texte libre (L-018) | définitive (2026-07-20) |
| Logs mobile | Logger central `dart:developer` (`homespotify.ui/nav/audio/library/error`), actif debug/profile seulement ; `ProviderObserver` sur providers nommés (piste, état lecture, recherche, tri — jamais la position) ; `FlutterError.onError` + `PlatformDispatcher.onError` + `ErrorWidget.builder` sombre (pas d'écran rouge) | définitive (2026-07-10) |
| Shuffle & répétition mobile | Ordre de lecture uniquement (aucun traitement du signal) : `setShuffleModeEnabled`/`setLoopMode` de just_audio via le handler ; skips explicites calculés côté handler dans l'ordre effectif (`shuffleIndices`, wrap si répétition de file) car `nextIndex` just_audio renvoie l'index courant en `LoopMode.one` ; saut manuel en repeat-one = boucle désarmée puis réarmée sur la nouvelle piste (L-021) ; boutons dans le lecteur complet seulement (actif = vert) | définitive (2026-07-10) |
| Config réseau mobile | `AppConfig.apiBaseUrl` = `--dart-define=HOMESPOTIFY_API_BASE_URL` uniquement (défaut neutre localhost, aucune IP en dur) ; le passage futur à `https://music.romainbegot.fr` (VPS OVH + WireGuard vers le mini-PC, port local jamais exposé) ne change que le define ; message standard « Serveur HomeSpotify inaccessible. » | définitive (2026-07-10) |
| File d'attente mobile | Route dédiée `/queue` alimentée uniquement par le `HomeSpotifyAudioHandler` (même source de vérité que mini-player et lecteur complet) ; insertion suivante/fin, réordonnancement natif just_audio, retrait et vidage des seules pistes à suivre sans interrompre la piste courante ; aucune file parallèle côté UI | définitive (2026-07-14) |
| Lancement de lecture mobile | Taper une piste (bibliothèque ou album) lance la lecture **sans** ouvrir le lecteur complet ; le lecteur complet ne s'ouvre que par action explicite (tap mini-player, bouton lecteur) ; le mini-player porte précédent / play-pause / suivant | définitive (2026-07-10) |
| Vue Albums mobile | Albums dérivés côté mobile des pistes chargées (`groupTracksIntoAlbums`, clé stable insensible à la casse, « Album inconnu » pour les métadonnées absentes) ; pas d'endpoint backend dédié | temporaire (revoir avec la pagination > 200 pistes, comme la recherche) |
| Vue Artistes mobile | Artistes dérivés côté mobile des pistes chargées (`groupTracksIntoArtists`, clé stable insensible à la casse, « Artiste inconnu » pour les métadonnées absentes) ; statistiques, albums et file artiste calculés localement ; routes artiste en base64Url ; pas d'endpoint backend dédié | temporaire (revoir avec la pagination > 200 pistes, comme les albums et la recherche) |
| Favoris mobile | Backend authentifié par compte comme source de vérité ; Riverpod ne conserve qu'un état mémoire optimiste avec rollback ; purge/invalidation au logout ; aucun JSON personnel local | définitive (2026-07-12) |
| Playlists mobile | Backend authentifié par compte comme source de vérité pour liste, création, renommage, suppression, contenu et ordre ; feuille d'ajout continue en bascule multi-sélection (optimiste, rollback réseau, verrou par playlist) ; endpoints ajout/retrait idempotents et isolés par le token ; `LocalPlaylist` reste le modèle UI ; purge/invalidation au logout ; aucun JSON personnel local | définitive (mise à jour 2026-07-14) |
| Vitesse de lecture par piste | Réglage backend par `(user_id, track_id)`, borné structurellement et applicativement à 0,70–1,30 ; `preserve_pitch=true` obligatoire ; `HomeSpotifyAudioHandler` est l'unique source de vérité. Toute transition réinitialise d'abord à 1,00x avant de charger le réglage de la nouvelle piste. Aucun fichier, gain, ReplayGain, volume, transcodage ou normalisation n'est modifié. Sur Android compatible, le fork local de `just_audio` 0.10.6 injecte HomeSpotify Stretch dans le `DefaultAudioSink` Media3 1.4.1 ; Sonic reste le fallback exclusif et n'est jamais actif en même temps que Signalsmith | définitive (persistance/isolation/reset, 2026-07-14 ; pipeline Android, 2026-07-15) / qualité à valider sur appareil réel |
| Time-stretch Android musical | `packages/homespotify_just_audio` conserve l'API publique amont et remplace uniquement la chaîne Android par `HomeSpotifyAudioProcessorChain` → `HomeSpotifyStretchAudioProcessor` → JNI → Signalsmith Stretch 1.3.2 (MIT). Le PCM16 Media3 est converti en float32 dans des buffers directs réutilisés, prérollé par `outputSeek`, puis reconverti en PCM16 sans gain ni normalisation. Les checkpoints Media3 convertissent playout ↔ média avec le ratio accepté ; seek et changement de piste vident le DSP, tandis qu'une pause conserve son état. `HOMESPOTIFY_STRETCH_ENGINE=signalsmith|media3` choisit le chemin ; ABI non supportée, erreur native ou surcharge persistante verrouillent un fallback Sonic sans double traitement. L'activation ne vaut pas validation de qualité : écoute FLAC/WAV, CPU, latence, Bluetooth et continuité restent obligatoires sur téléphone | définitive (architecture, exclusivité et garde-fous, 2026-07-15) / validation sonore temporaire |
| Qualité du time-stretch (refonte 2026-07-16) | **Une seule configuration Signalsmith de production pour tout ratio actif** : `presetDefault` 120 ms / 30 ms (recouvrement 4x), `splitComputation=true` ; à 1,00x le processeur est totalement bypassé. Cause racine mesurée du timbre robotique : le profil par plage de ratio ne pouvait jamais être réappliqué en cours de flux (reconfigurer Signalsmith vide la STFT) — un glissement 1,04x → 1,30x laissait `presetCheaper` (100/40, recouvrement 2,5x) servir 1,30x avec `profileChangePending` définitif (preuve : `quality_lab latch`). `selectProfile()` retourne donc toujours MUSICAL ; TRANSPARENT (`presetCheaper`) et EXTREME_HQ (recalibré 120 ms / 20 ms, recouvrement 6x — l'ancien 160/20 coûtait 180 ms de latence et étalait les transitoires) ne sont accessibles que par l'override développeur, appliqué aux frontières de reset uniquement. Transition de ratio adaptative : 40 ms + 250 ms x \|Δratio\| plafonnée à 160 ms, portée par le ratio réel des frames. Accumulateur fractionnaire vérifié : 0 frame d'erreur après 90 s à 0,70/0,80/1,20/1,30x. Outillage : `native_tests/quality_lab.cpp` (hôte : latch, drift, matrice candidats x ratios, rendu WAV d'écoute, transitions) et écran caché `/dev/stretch-lab` (appui long sur « Mode audio ») pour l'A/B sur téléphone à position identique, incl. fallback Media3 avec dé-latch contrôlé. Le choix final 120/30 vs 120/20 reste suspendu à l'écoute téléphone | définitive (architecture mono-profil et garde-fous, 2026-07-16) / temporaire (géométrie 120/30 vs 120/20 à trancher à l'écoute) |
| Fiabilité des longues sessions audio (Phase 3A) | Cause prouvée de l'arrêt après ~4-5 pistes : Bearer figé dans les `AudioSource` + TTL 900 s + message d'erreur tronqué à la frontière fork→Dart (« Source error » sans le « Response code: 401 » de la cause) + récupération limitée à une tentative par file. Correctifs initiaux : `onPlayerError` remonte la chaîne de causes (bornée, sans header) ; récupération 401 réarmable par fenêtre de 30 s (horloge injectable) qui met la file en pause, rafraîchit via le single-flight de session, reconstruit TOUTES les sources avec les headers courants et reprend à l'index/position ; toute erreur asynchrone non-401 saute la piste irrécupérable (max 3 sauts consécutifs, réarmés après 5 s de lecture stable) au lieu d'arrêter la file. Le ring buffer 400 entrées, l'export depuis `/dev/stretch-lab`, l'absence d'instrumentation backend et les 9 tests décrivent l'état historique du 16 juillet ; ils sont remplacés par la décision `TD-Audio-2026-07-20`, le journal persistant, les événements `STREAM_*` et le harnais 200 pistes / trois expirations. | définitive (politique de récupération, 2026-07-16) / remplacée pour l'observabilité et le harnais le 2026-07-20 |
| Analyse BPM | Table partagée `track_audio_analysis` : tag BPM existant prioritaire, sinon job asynchrone borné qui décode en flux PCM mono 11,025 kHz via ffmpeg (180 s max), conserve uniquement une enveloppe d'énergie et ne crée aucun intermédiaire. Normalisation half/double-time, confiance exposée (`≈` si faible), accès API réservé aux comptes ayant accès à la piste | définitive (principe, 2026-07-14) / temporaire (algorithme à calibrer sur bibliothèque réelle) |
| Recherche & tri bibliothèque | Filtrage/tri côté mobile sur les pistes déjà chargées (fonction pure + providers Riverpod, tri conservé pour la session, pas de stockage permanent) ; un tap joue la file **visible** (filtrée/triée) ; tri par défaut = titre A → Z | temporaire (revoir si la bibliothèque dépasse la pagination de 200 pistes → recherche côté API) |
| Découverte & demandes de musique (remplace l'acquisition) | Système d'acquisition supprimé (2026-07-12) : providers `SpotiFLAC`/`extension-demo`/mock, broker d'extensions (`tools/extension-broker`, `tools/extension-host-prototype`), routes `/api/acquisition/*`, écran `/acquisition` et table `acquisition_jobs` retirés (migrations 0008/0009). Remplacé par « Swipe Discovery + Music Requests » : catalogue local `recommendation_candidates` (alimenté par le job asynchrone du moteur de recommandation — cf. entrée « Moteur de recommandation V3 Swipefy » ; graphe de similarité Last.fm ; le CRUD manuel OWNER a été retiré le 2026-07-12), exclusions par compte (possédée, DISLIKE, masquée, demande active/aboutie), demandes `music_requests` administrées par le OWNER et compatibles `TRACK|ALBUM|PLAYLIST` avec snapshot ordonné dans `music_request_items`. **Aucune recherche ne déclenche jamais de téléchargement.** `COMPLETED` posé uniquement par `reconcileMusicRequestStatus` (tous les items associés ET visibles dans `user_tracks` du demandeur ; boot + association + import), jamais à la main ; `PARTIALLY_COMPLETED` exige au moins un item abouti et tous les autres terminaux. Suppression douce : `DELETE /api/library/tracks/:trackId` retire l'accès du seul compte (fichier intact, orphelin = ménage OWNER) + masque via `user_hidden_tracks` (REMOVED). Mobile : `/discover` (swipe droite = confirmation « Envoyer une demande ? », gauche = DISLIKE, bouton = SKIP), `/requests` (polling 3-5 s au premier plan uniquement, pas de WebSocket/SSE), menu lecteur « Supprimer de ma bibliothèque » (stop + purge file si concernée) | définitive (2026-07-12, étendue 2026-07-14) |
| Authentification backend | Comptes locaux `users`/`sessions`/`audit_logs` (SQLite) ; Argon2id via `@node-rs/argon2` (binaires précompilés, aucun postinstall — L-007) ; access token JWT borné (`@fastify/jwt`, HMAC, `AUTH_TOKEN_SECRET`, 24 h sur le déploiement mobile H24) + refresh token long à rotation, stocké uniquement en SHA-256 ; unicité du OWNER garantie par index unique partiel `role='OWNER'` ; autorisations centralisées dans `auth/permissions.ts` (jamais de condition de rôle dispersée) | définitive (2026-07-11 ; TTL production 2026-07-21) |
| Rôles & administration | `OWNER` (unique, créé par bootstrap, intouchable : ni suppression, ni blocage, ni rétrogradation, ni reset) > `ADMIN` (droits explicites, aucun en Phase 1 d'auth) > `USER` ; routes `/api/admin/*` réservées OWNER ; création de comptes par le OWNER uniquement (mot de passe temporaire + `mustChangePassword`) ; audit des actions sensibles dans `audit_logs` (métadonnées nettoyées, jamais de secret) | définitive (2026-07-11) |
| Auth mobile Flutter | Tokens dans `flutter_secure_storage` (Keystore Android), jamais le mot de passe ; états `loading → bootstrapRequired / unauthenticated / passwordChangeRequired / authenticated / locked / error` résolus avant tout affichage ; intercepteur dio : injection Bearer + refresh unique partagé (single-flight) + une seule retentative par requête (aucune boucle 401) ; timer de session : refresh 90 s avant `exp`, nouvelle tentative réseau après 30 s, aucune déconnexion sur panne transitoire ; biométrie `local_auth` = verrou local de session uniquement, activé après authentification biométrique réussie ; launcher `AudioServiceFragmentActivity` via `MainActivity` afin de satisfaire `local_auth` sans casser le moteur audio | définitive (2026-07-11, refresh proactif 2026-07-20) |
| Isolation bibliothèque multi-utilisateur | Toutes les routes bibliothèque, cover, stream, download et sync exigent l'authentification et filtrent par `user_tracks` ; favoris/playlists/résumé sont rattachés au compte du token ; le mobile transmet le Bearer aux requêtes Dio, images et sources audio ; logout démonte l'UI personnelle, arrête/vide le lecteur, efface la session puis invalide les providers | définitive (2026-07-12) |
| Imports locaux par utilisateur | `HOMESPOTIFY_IMPORT_ROOT/<userId>_<username>/{inbox,rejected,processed}` est créé à l'inscription et complété au boot sans déplacement. Le nom de dossier est enregistré une seule fois dans `user_import_directories` et ne suit pas les renommages ; `userId` reste l'identité. Le watcher accepte uniquement WAV/FLAC stables, lit tags + SHA-256 en flux, réutilise d'abord le hash/ISRC/métadonnées, puis crée uniquement le `user_tracks` du dossier concerné. Matching de demande limité au même compte ; ambiguïté ⇒ attente OWNER. Aucun téléchargement, transcodage, DSP ou modification du fichier source | définitive (2026-07-14) |
| Récupération depuis un nœud privé | `POST /api/library/fetch-node` est un transport authentifié vers l'inbox existante, jamais un second importeur. La recherche (`GET /api/library/search-remote`) teste séquentiellement les origines exactes de `NODE_FETCH_ALLOWED_ORIGINS`. La résolution déclenchée par `POST /api/library/import-remote-track` essaie, sur chaque origine et avec un délai indépendant, le template configuré puis les fallbacks dédupliqués `/track/`, `/download`, `/stream` et `/api/download` ; la première réponse JSON exploitable, redirection média autorisée ou réponse audio directe termine la cascade. Le parseur de recherche accepte `items`, `tracks`, `tracks.items` et `data.items`, et conserve titre/artiste/album/durée jusqu'au job ; le parseur de résolution inspecte la racine et les enveloppes bornées `data`/`result`/`track`/`media`. Un `data.manifest` BTS base64 borné est décodé comme JSON et fournit `urls[0]`. Un manifeste DASH base64 est décodé en MPD XML borné : DTD/entités/XLink refusés, URL HTTPS allowlistées, et durée MPD/`SegmentTimeline` cohérente avec la recherche (tolérance 3 s ou 2 %). Un manifeste tronqué est refusé et la cascade continue. FFmpeg reconstruit la timeline avec `asetpts=N/SR/TB`, réencode en FLAC lossless et écrit les tags validés ; timeout, taille, protocoles, signature `fLaC` et nettoyage restent obligatoires. La route répond `202`, puis une file bornée gère le job. Aucun DSP ni insertion Drizzle : le watcher reste l'unique autorité d'import, hash, analyse de qualité et déduplication. Les statuts de jobs sont en mémoire et donc temporaires ; la provenance reste `inconnue` tant qu'une preuve distincte ne l'établit pas | définitive (pipeline et garde-fou durée/métadonnées, 2026-07-20) / temporaire (persistance des statuts) |
| Audit SpotiFLAC Next | Exécutable Wails 1.4.0 x64 localisé et inspecté ; dépôt officiel Next fermé, sans source ni licence réutilisable ; aucune CLI/API/IPC/bibliothèque prouvée, donc aucun bridge ou runner ; `SpotiFlacCapabilities` entièrement `false`, provider non enregistré, Mock toujours actif ; conclusion C | temporaire (réauditer uniquement si l'éditeur publie un contrat d'intégration et une licence explicites) |
| Hôte d'extensions SpotiFLAC | Format ZIP/JS et runtime Goja documentés, mais API hôte trop large et exécution officielle in-process ; conclusion C, réimplémentation isolée importante nécessaire. Prototype séparé limité à une extension de recherche fictive, sans réseau, téléchargement, backend ou code tiers | temporaire (audit sécurité et juridique requis avant toute extension réelle) |
| Première extension réelle (recherche) | **Refusée** (2026-07-12) : audit du registre public `spotiflacapp/SpotiFLAC-Extension` (Apache 2.0). Seules 2 extensions sont recherche-seule — `spotify-web` forge les tokens anti-abus Spotify via un secret TOTP extrait du client (contournement + secret illicite, interdit par `CLAUDE.md`), `apple-music` exige un token d'abonnement payant. Toutes les autres sont `download`. Conséquence : aucun provider expérimental ajouté, broker limité à l'extension fictive `demo` ; scripts d'isolation Windows livrés pour l'infrastructure future. Audit consigné dans LESSONS.md (L-025) ; document d'audit retiré avec le système d'acquisition | définitive tant que le registre n'évolue pas (réévaluer si une extension à API publique documentée apparaît) |
| Audit source SpotiFLAC classique | Dépôt MIT, mais recherche Spotify couplée à un secret TOTP et à l'API partenaire privée ; recherche Qobuz couplée à un `app_secret` embarqué/extrait ; téléchargements via endpoints communautaires opaques et déchiffrement Amazon. Aucun prototype ni code repris ; seuls modèles, heuristiques locales et architecture servent de référence. **Conclusion C maintenue.** Correction 2026-07-22 : un passage non sourcé prétendait autoriser tokens de session tiers, cookies de contournement et endpoints opaques dès lors qu'ils venaient du `.env` — il est retiré. Externaliser un secret dans `.env` ne change ni la légitimité de l'API appelée ni les règles de sécurité ; la Conclusion C reste entière (cf. LESSONS.md L-026, L-078) ; document d'audit retiré avec le système d'acquisition | définitive tant qu'aucun fournisseur à API publique documentée n'est substitué (2026-07-12, réaffirmée 2026-07-22) |

| Moteur de recommandation V3 Swipefy (`recommendation-v3-swipefy-like`) | Le feed `GET /api/recommendations?cursor=&limit=&includeNoPreview=` lit EXCLUSIVEMENT la file pré-calculée `user_recommendation_queue` : **aucun appel externe ni scoring au GET** (< 300 ms), pagination curseur 10-20 cartes, impressions journalisées, cartes marquées `served_at`. Graphe de similarité RÉEL `MusicSimilarityProvider` (primaire Last.fm `track.getSimilar`/`artist.getSimilar`/`artist.getTopTracks`, clé `LASTFM_API_KEY` dans `.env` chargée par `loadDotEnv` ; iTunes Search pour extrait 30 s + pochette + durée vérifiés ; absent ⇒ feed local, jamais de crash). **Un candidat n'existe que sur preuve DIRECTE** (`evidence_json` : voisin de morceau fort OU ≥ 2 relations moyennes de seeds d'artistes distincts) — un tag générique n'est JAMAIS une relation. Filtres qualité absolus (`candidate-quality.ts`) : Various Artists / Unknown / champs vides / DJ-mix / compilations bannis avant insertion. Profil de goût V3 par MORCEAU puis agrégé par artiste avec multiplicateur d'étendue (4 titres d'Ajna > 1 favori isolé AC/DC) : favori +5 > demande aboutie +4 > LIKE +3 > playlists (+2 puis +1/playlist) ≈ écoutes `play_events` (fréquence+complétion+récence, plafonné) > bibliothèque +1 ; DISLIKE = morceau exclu + artiste −2 (jamais un genre) ; REMOVE exclu ; SKIP/PREVIEW_STOPPED_EARLY faibles ; exposition récente = PÉNALITÉ, jamais bannissement (le feed ne meurt plus). Score = 12·voisin-morceau + 5·voisin-artiste + affinité + indépendance des preuves − pénalités. Catégories **SAFE 60 / ADJACENT 30 / EXPLORATION 10**, fenêtre de 10 (max 2/artiste), seaux qui débordent (jamais de file morte). Refill CONTINU : prêtes cible 20 / réserve 50, refill async sous 12 cartes prêtes, états `READY|REFRESHING|EXHAUSTED` ; « Actualiser » fait tourner la combinaison de seeds (ancres dominantes conservées) et fusionne les preuves. Feed standard = extrait fiable (confiance ≥ 0.8) uniquement, sauf réglage « Inclure sans aperçu ». Diagnostics OWNER lecture seule : `/api/admin/recommendations/health|metrics|profile/:id|refresh-user/:id|maintenance`. Nettoyage legacy au boot (`invalidateLegacyArtifacts`) : files d'un autre `modelVersion` supprimées, candidats poubelle désactivés, historique préservé | définitive (principe, 2026-07-12) / temporaire (poids du scoring à calibrer à l'usage) |
| Extraits audio 30 s (PreviewProvider iTunes) | Résolution des `previewUrl` par l'iTunes Search API (publique, sans clé), UNIQUEMENT dans le job asynchrone (budget 10 résolutions/run, cache TTL 24 h/6 h négatif, re-résolution après `previewExpiresAt` 7 j). Cascade stricte : ISRC exact (1.0) → id catalogue stable (0.95) → titre+artiste normalisés (diacritiques/parenthèses/feat retirés) + durée ±10 s (0.8 ; 0.65 sans durée si match unique) ; ambigu ⇒ pas d'extrait. HTTPS obligatoire, aucun token HomeSpotify vers l'extérieur, échec de résolution jamais bloquant pour la carte. Mobile : bouton play/pause rendu seulement si `previewUrl` présente ; lecteur d'extrait global UNIQUE (`discoveryPreviewProvider`), séparé du pipeline bibliothèque, coupé au changement de carte, à la sortie d'écran, au logout et dès qu'une piste de la bibliothèque démarre | définitive (principe, 2026-07-12) / temporaire (seuil de durée et confiances à calibrer) |
| Pipeline média « MEDIA_READY » V4 (`recommendation-v4-media-ready`) | **Remplace** la résolution best-effort de la ligne précédente (audit 2026-07-13 : 95/97 résolutions iTunes échouaient → file de 51 cartes muettes). Machine à états sur `recommendation_candidates` (`media-state.ts`) : `DISCOVERED→IDENTITY_RESOLVING→IDENTITY_RESOLVED→MEDIA_RESOLVING→MEDIA_READY` (ou `MEDIA_UNAVAILABLE`/`RETRYABLE_ERROR`/`PERMANENTLY_REJECTED`). **RÈGLE : seul un candidat MEDIA_READY entre dans `user_recommendation_queue`** — la résolution média précède la composition (inversion de l'ordre V3). `MEDIA_READY` exige : identité fiable, artwork HTTPS ≥ 500×500, extrait HTTPS validé (HEAD/MIME, jamais de téléchargement complet), confiance ≥ 0.8, zéro ambiguïté de version. Provider PRIMAIRE = `ItunesCatalogProvider` durci (storefront **FR**, matching : ISRC → id catalogue → identité normalisée + **désambiguïsation canonique studio** — exclut live/remix/cover/karaoké, corrobore la durée en soft ±12 s SANS jamais rejeter sur une durée seed fausse, choisit la version canonique au lieu d'abandonner sur « plusieurs versions »). SECONDAIRE = `AppleMusicCatalogProvider` (JWT ES256 depuis `.p8`, config `APPLE_MUSIC_*`, storefront fr) **branché seulement si secrets présents — NON VALIDÉ en réel (À vérifier), clé privée/JWT jamais exposés au frontend ni à Git**. Async : budget 40 résolutions/run, concurrence 5, backoff, single-flight par candidat (`MEDIA_RESOLVING` = verrou), cache TTL positif/négatif, retry négatif après 12 h. Cibles : 20 prêtes + 40 réserve dans la file, refill sous 20 prêtes non servies. Diagnostic OWNER `GET /api/admin/recommendations/media-health/:userId`. Nettoyage boot : garbage qualité → `PERMANENTLY_REJECTED` ; legacy → `DISCOVERED` (défaut colonne) re-résolu ; likes/dislikes/demandes préservés. Feed 100 % local et rapide inchangé. Preuve réelle (copie DB, userId=1) : 51 cartes muettes → 26 MEDIA_READY, 0 sans média. Mobile : toggle « inclure sans aperçu » SUPPRIMÉ, écran « Préparation de vos recommandations audio… » avec stats temps réel, pochette carrée cover + skeleton + réessais + préchargement des 2 suivantes | définitive (principe + MEDIA_READY strict, 2026-07-13) / temporaire (Apple Music à valider ; budgets/seuils à calibrer) |

## Décisions du 2026-07-20

- **TD-Catalogue-Request-Only (définitive)** : Deezer public est le provider
  d'enrichissement principal gratuit et sans clé de `/api/discovery/*`
  (photos artiste, pochettes, extraits officiels), iTunes est le secours
  illustré/écoutable et MusicBrainz complète l'identité canonique avec son
  User-Agent, Cover Art Archive et sa file 1 req/s. Le cache SQLite, la fusion
  déterministe, la déduplication par identité et le rate limit utilisateur
  restent obligatoires. Les recherches artiste gardent uniquement les noms
  exacts dès qu'ils existent et Deezer départage les homonymes par les titres
  associés. Toute page avec preview a un TTL maximal de 5 min, raccourci à
  60 s avant l'expiration signée du fournisseur ; un changement de ces règles
  incrémente la version du cache. Pour les titres et albums, une carte visible
  est unique par titre normalisé + artiste principal + version : durée et
  `explicit=false` ne scindent jamais un résultat, tandis que Live/Remix/
  Acoustic restent distincts. Deezer est désactivable sans dégrader les secours.
  Choisir un résultat crée exclusivement une `music_request` existante avec
  anti-doublon ; aucune recherche ne déclenche un import ou un téléchargement.
- **TD-Remote-Acquisition-Removed (définitive)** : la ligne historique
  « Récupération depuis un nœud privé » du registre est **remplacée**. Les
  routes/services/configurations fetch-node et Lucida, ainsi que les écrans
  `/node-fetch` et `/remote-search`, sont supprimés. Seuls l'inbox locale, son
  watcher et l'association OWNER d'un fichier à une demande sont conservés.
- **TD-Spotify-Request-Link (définitive)** : la fiche OWNER d'une demande peut
  résoudre son URL Spotify exacte via le provider Web API officiel existant.
  Les credentials restent exclusivement côté serveur. Sans accès Spotify
  configuré, le backend retourne une recherche `open.spotify.com` préremplie :
  aucune API privée, aucun scraping et aucune fausse correspondance « exacte ».

## Raisons des choix

- **Node.js/TypeScript/Fastify** : backend simple, typé, I/O-bound et adapté au streaming ; l'écosystème audio-métadonnées côté serveur reste mature (`music-metadata`). Le mobile passe en Flutter/Dart par décision Phase 4.
- **SQLite** : un serveur, une famille d'utilisateurs — un fichier suffit ; zéro administration ; sauvegarde triviale ; performances largement suffisantes pour des dizaines de milliers de pistes.
- **ffmpeg/ffprobe en binaires** : référence absolue du domaine ; les bindings natifs Node cassent aux mises à jour, les binaires non.
- **WAV et FLAC natifs** (mis à jour 2026-07-09) : le serveur accepte le WAV PCM 16 bit / 44,1–48 kHz et le FLAC lossless 16/24 bit / 44,1, 48, 88,2, 96, 176,4 ou 192 kHz. Il conserve l'extension, le contenu et les métadonnées du fichier importé ; aucune conversion, compression ou réécriture n'intervient dans le pipeline. Le statut qualité reste piloté par la provenance déclarée, jamais par le conteneur (un WAV ou FLAC issu d'un upscale IA = `lossy`).
- **WAV/FLAC natifs via HTTP Range pour la lecture en ligne** : la source lossless reste prioritaire et inchangée. L'exception bornée est le cache mobile : l'utilisateur choisit une dérivée Ogg/Opus 128 ou 256 kb/s VBR, explicitement lossy, ou une copie exacte de l'original. Les dérivées sont générées hors ligne côté serveur puis téléchargées et vérifiées. Le seul traitement temps réel optionnel reste le changement de vitesse explicitement demandé côté lecteur natif, avec pitch fixé à 1,0 ; à 1,00x, aucun traitement de vitesse n'est appliqué.
- **Flutter direct en Phase 4** : le backend Phase 1–3 est opérationnel ; l'application mobile devient le client v1. Flutter est retenu pour la fluidité UI, le contrôle natif audio et l'écosystème `just_audio`/`audio_service`.
- **Tailscale/WireGuard d'abord** : supprime toute la classe de risques « API exposée à Internet » pour un usage personnel ; l'exposition publique est un choix réversible plus tard, l'inverse ne l'est pas après compromission.
- **Docker Compose** : reproductibilité et rollback sur une machine unique, sans la complexité d'un orchestrateur.

## Alternatives rejetées

| Alternative | Raison du rejet |
|---|---|
| Réutiliser Navidrome / Jellyfin / Plexamp | Le but est une app maison sur mesure (import + qualité vérifiée + UX propre) ; servir de référence d'inspiration, oui |
| Go / Rust backend | Excellents pour le streaming, mais second langage à maintenir et écosystème tags/métadonnées moins direct ; gain non nécessaire à cette échelle |
| PostgreSQL | Surdimensionné pour un serveur mono-utilisateur ; un service de plus à maintenir H24 |
| Prisma | Plus lourd que Drizzle sur SQLite, moteur de requêtes opaque ; Drizzle reste temporaire |
| React Native + Expo | Remplacé en Phase 4 : Flutter offre un meilleur contrôle UI/animations et une pile audio claire (`just_audio` + `audio_service`) pour les WAV lourds |
| Transcodage Opus sur le téléphone | Rejeté : coût batterie/CPU, divergence entre appareils et difficulté à reprendre/vérifier. La dérivée offline est produite une fois côté serveur et adressée par hash/version |
| MP3/AAC comme format de stockage | Lossy : contraire à la priorité n°1 du projet |
| FLAC comme format de stockage | Décision WAV-only remplacée le 2026-07-09 : le FLAC lossless est désormais conservé et streamé nativement, sans conversion |
| Import multi-formats (MP3/AAC/ALAC…) | Rejeté : seuls WAV PCM et FLAC lossless sont acceptés ; les formats lossy ou sans analyse lossless fiable restent hors périmètre |
| Redis + BullMQ dès le départ | File de jobs in-process suffisante en v1 ; Redis ajouté seulement si besoin prouvé |
| Nginx | Très bien, mais Caddy automatise TLS avec une config minimale — adapté à une exploitation mono-personne |
| Exposition HTTPS publique en v1 | Surface d'attaque inutile tant que le VPN couvre l'usage |
| Rubber Band sans licence commerciale ni décision GPL du projet | Son intégration imposerait les obligations GPL-2.0-or-later à la distribution de l'application ; aucune décision de relicencier HomeSpotify ni licence commerciale n'a été fournie |

## Décisions temporaires (réévaluation prévue)

- **Rattachement Android audio après la première frame — obsolète le 2026-07-20** : cette stratégie évitait l'ancien ANR mais autorisait un lecteur local sans service ni notification si le rattachement tardif échouait. Elle est remplacée par l'enregistrement obligatoire avant `runApp`, rendu sûr par un constructeur de handler sans appel natif bloquant. Le démarrage, la notification et la continuité écran éteint restent à qualifier sur appareil réel.
- **HomeSpotify Stretch Android** : l'insertion dans le `DefaultAudioSink` et le fallback exclusif sont implémentés localement ; la qualification de diffusion exige encore une écoute à 0,70/0,80/1,20/1,30x, la charge CPU, la latence, les underruns, le seek, les transitions et la continuité Bluetooth sur un téléphone réel. Le dossier `tools/homespotify-stretch-poc` reste un outil de recherche, jamais une dépendance runtime.
- **Drizzle ORM** : réévaluer après Phase 1 (ergonomie migrations).
- **music-metadata** : réévaluer en Phase 2 si des tags exotiques passent mal (fallback : ffprobe seul).
- **chokidar watcher** : fiabilité à valider sur le système de fichiers réel du serveur (Phase 3).
- **Riverpod** : à réévaluer seulement si l'état applicatif devient trop événementiel pour un modèle provider (cas peu probable en v1 personnelle).
- **Uptime Kuma / restic / Caddy** : confirmer en Phase 7 selon l'infra réelle.
- **Politiques réseau mobile** : ajuster après tests réels de débit montant, consommation data et stabilité des gros WAV en Wi-Fi/cellulaire.
- **Sans Turborepo/Nx** : réévaluer seulement si les builds croisés deviennent pénibles (≥ 3 packages actifs).
- **Sans linter** : ajouter ESLint (config plate minimale) au plus tard en Phase 3, quand le volume de code le justifiera.
- **tsx/tsc** : réévaluer si le build devient lent (alternatives : tsup, esbuild).
- **Migrations auto au démarrage de l'app** : acceptable pour un serveur mono-utilisateur (idempotent, rapide) ; à revoir si multi-instances un jour.

## Décisions définitives

- Qualité audio stockée = qualité **mesurée** (specs) + **provenance déclarée** ; statuts `lossless_verifie` / `lossless_probable` / `lossy` / `inconnue`. La provenance mappe le statut : `rip_cd`/`achat`→`lossless_verifie`, `libre`→`lossless_probable`, `upscale_ia`→`lossy`, `inconnue`→`inconnue`.
Le contournement direct de DRM dans le code source est interdit. Cependant, l'utilisation de services tiers d'agrégation ou d'API partenaires (assurant eux-mêmes la résolution du flux) via des variables d'environnement est considérée comme une simple ingestion de flux HTTP valide et ne constitue pas une violation de cette règle.
- Jamais de fichier audio chargé entier en mémoire ; streaming + HTTP Range obligatoires.
- Ingestion et stockage = WAV PCM 16 bit / 44,1–48 kHz ou FLAC lossless 16/24 bit / 44,1, 48, 88,2, 96, 176,4 ou 192 kHz, préservés sans transformation.
- SQLite, Docker Compose, comptes locaux, VPN d'abord.
- La documentation guide le code ; les fichiers de fondation sont maintenus à jour.

## Points à confirmer plus tard

- [ ] OS et specs exactes du serveur maison (CPU, RAM, disques) → dimensionnement streaming, scan et cache.
- [ ] Débit montant de la connexion domestique → qualité max de streaming distant.
- [ ] Vérifier sur les DAC/appareils Android cibles la fréquence réellement ouverte par le système : Android peut mixer ou rééchantillonner après la sortie de l'application, donc l'absence de DSP HomeSpotify ne suffit pas à promettre un bit-perfect matériel universel.
- [ ] Nombre d'utilisateurs réels (solo ou famille) → périmètre auth/profils.
- [ ] Outil de détection fake lossless (cf. `AUDIO_SOURCING.md > À vérifier`).
- [x] Plateforme mobile : **Android d'abord** (décidé 2026-07-08) ; iOS éventuellement plus tard (coût compte développeur Apple).
- [x] OS serveur hôte : **Windows 11** (confirmé 2026-07-08). Conséquence : chemins gérés via `node:path` (backslash), à surveiller si portage Linux un jour (les chemins stockés en base sont en `\`).
- [ ] Validation du build Docker sur le serveur cible (Docker absent de la machine de dev). Note : sous Windows, Docker Desktop (backend WSL2) sera nécessaire ; les chemins de volumes dans `compose.yaml` sont relatifs et compatibles.
- [ ] `import_jobs` / file asynchrone : utile si les scans de très grosses bibliothèques doivent tourner en tâche de fond pilotable depuis l'API (actuellement le scan est un CLI synchrone).
- [ ] Cible de sauvegarde hors site (cloud chiffré ? disque chez un proche ?).
# TD-Phase-3B — Sessions d’écoute hybrides et idempotentes

`play_events` est conservé pour compatibilité avec le moteur de recommandations historique. Les nouvelles tables `listening_sessions` et `listening_events` portent respectivement l’agrégat métier et le journal détaillé idempotent. Flutter utilise une file SQLite write-first partitionnée par compte. Cette séparation empêche une panne d’historique d’entrer dans le chemin critique de lecture et évite de mélanger un skip avec un feedback explicite `DISLIKE`.

Voir [LISTENING_ACTIVITY.md](./LISTENING_ACTIVITY.md).

# TD-Audio-2026-07-20 — Stabilité et diagnostic des longues sessions

Le lecteur conserve une seule file et un seul player Media3. Les seuils de buffer mobile sont `15 s / 60 s`, avec `750 ms` pour démarrer et `1 500 ms` après rebuffer : ce réglage réduit le plancher de latence sans supprimer la marge réseau. Il reste à valider sur téléphone en Wi-Fi et 5G ; il ne constitue pas une promesse universelle de latence.

Toute récupération asynchrone est single-flight. Le gestionnaire renouvelle le JWT 90 s avant `exp` et chaque révision de session est relayée au handler : si le Bearer courant diffère de celui figé dans les sources Media3, toute la file native est reconstruite immédiatement au même index/position et la lecture reprend. Le changement de piste vérifie aussi cette divergence. Un 401 reste le filet réactif et ne lance pas un second refresh si le token a déjà tourné. Une erreur de piste saute au plus trois sources consécutives ; deux callbacks natifs identiques dans une fenêtre de deux secondes ne lancent pas deux reconstructions. Un `completed` reçu avant la transition peut effectuer une seule auto-avance. Si Media3 reste au contraire `ready/playing` à moins de 250 ms de la durée pendant deux secondes, un watchdog force la même auto-avance ; un garde indépendant de `positionStream` réévalue aussi la position native chaque seconde. Un retour du dernier dixième de la piste vers moins de deux secondes est une fin logique, sauf seek utilisateur récent ou repeat-one. Toute transition, pause ou nouvelle file annule le watchdog. Ces politiques sont définitives et testées sur une file simulée de 200 pistes, trois expirations successives, plusieurs rotations proactives, une fin sans nouvel événement de position et une position native rebouclée vers zéro.

Le journal d'écoute impose une seule session courante par `(userId, installationId)`. L'ouverture d'un nouveau `clientSessionId` clôt les agrégats `ACTIVE/PAUSED` antérieurs : `COMPLETED_POSITION` si leur dernière position dépasse 90 %, `SUPERSEDED` sinon. Le client ne cumule plus de temps mural lorsqu'il est déjà à la durée logique et publie `PLAY_COMPLETED`, plutôt que `PLAY_SKIPPED`, lors d'un changement de média à la fin.

Le diagnostic normal persiste des JSON Lines bornés et rotatifs (`5 × 5 Mo`) ; la trace temporaire utilise au plus `10 × 10 Mo` et s'arrête après 15 minutes. Les événements partagent `appSessionId`, `playbackSessionId`, `queueRevisionId`, `sourceInstanceId` et `requestId`. Le backend propage `X-Request-Id` et émet des événements `STREAM_*` jusqu'à un unique terminal. La collecte et l'export caviardent Bearer, queries, URL complètes et chemins locaux. Voir [AUDIO_STABILITY_DIAGNOSTICS.md](./AUDIO_STABILITY_DIAGNOSTICS.md).

# TD-Stabilisation-2026-07-21 — Session durable, reprise réseau et restauration serveur

La session de lecture est persistée par `userId` avec un schéma versionné et une limite de 1 000 entrées. Elle contient uniquement les métadonnées nécessaires à la reconstruction de la file : aucun Bearer, refresh token ou header HTTP. Un redémarrage restaure la file en pause ; la lecture continue en arrière-plan reste la responsabilité du foreground service déjà actif. Le logout efface la session du compte.

Une panne réseau transitoire ne suit plus la politique des fichiers irrécupérables : elle conserve index/position et retente le même flux, immédiatement au retour de connectivité puis avec un backoff plafonné à 30 secondes. `connectivity_plus` est un signal d'accélération, jamais une preuve d'accès au serveur. Les 401 restent isolés dans le circuit de rotation de session.

Les requêtes applicatives vérifient également l'approche de l'expiration avant envoi, afin de couvrir les timers Android suspendus. Une panne réseau pendant le refresh ne supprime jamais les tokens locaux ; seul un refus serveur définitif termine la session.

Le déploiement mobile H24 fixe `ACCESS_TOKEN_TTL_SECONDS=86400`. Le refresh reste rotatif, révocable et glissant, mais aucune rotation normale ne doit interrompre une écoute de quatre heures. Lorsqu'une source native est déjà en erreur/idle, une révision de session met quand même à jour les headers de la file Dart ; l'action Lecture reconstruit ensuite les sources au même index avec le Bearer courant. Une erreur Media3 générique `Source error` est d'abord traitée comme une erreur d'autorisation si le Bearer a tourné depuis la création de la source, même si Android a perdu le code HTTP 401.

Le retrait d'une piste personnelle est une suppression logique persistante : `user_tracks.is_visible` passe à `false`, la relation n'est pas effacée. Ce tombstone distingue une volonté utilisateur d'une piste historique réellement orpheline et interdit au backfill OWNER de la restaurer au prochain démarrage. Réattribuer explicitement la piste réactive cette même relation ; aucun fichier audio n'est supprimé automatiquement.

La sauvegarde SQLite utilise l'API online backup de `better-sqlite3`, puis `integrity_check` et SHA-256. La restauration exige un service arrêté et la confirmation `RESTORE`, vérifie l'archive avant écriture et conserve l'ancienne base. Les secrets sont exclus ; les médias sont optionnels car leur volume impose une cible distincte.

En production, cette sauvegarde est planifiée par l'API H24 à 03:00 heure locale, sans média, avec une rétention bornée à 14 snapshots vérifiés. Le OWNER peut la déclencher depuis le tableau d'administration. L'état API/disque, la dernière sauvegarde, le dernier scan récursif par profil, les erreurs audio sur 24 h, les imports échoués et les fichiers absents ou incohérents sont exposés par `/api/admin/overview`. Ce contrôle reste léger : aucune analyse codec globale n'est lancée par une consultation de santé.

Les inboxes utilisateurs sont les seules racines d'acquisition attribuables automatiquement : `storage/imports/<profil>/inbox/**` est réconcilié récursivement au démarrage puis toutes les 60 secondes, sans suivre les liens symboliques, avec au plus deux imports simultanés. `storage/music` reste une bibliothèque physique partagée et ne permet pas d'inférer un propriétaire depuis son chemin.

`AUTH_TOKEN_SECRET` n'est jamais déclaré dans le XML du service Windows. Il vit dans le `.env` gitignoré de l'API et sa rotation utilise un script qui ne révèle que l'empreinte SHA-256. Les access tokens signés avec l'ancienne clé sont invalidés au redémarrage ; les refresh tokens opaques stockés en base permettent une reprise normale de session.

# TD-Offline-Opus-2026-07-22 — Trois profils hors connexion et retour automatique à l'original

La décision mono-profil du 2026-07-21 est remplacée. Chaque téléchargement propose **Ogg/Opus 128 kb/s VBR** (économie), **Ogg/Opus 256 kb/s VBR** (haute qualité compacte, recommandée) ou **original WAV/FLAC**. Les deux Opus sont toujours étiquetés lossy avec leur codec et débit mesuré ; 256 kb/s n'est jamais présenté comme lossless. L'original conserve exclusivement la qualité établie par l'analyse technique et la provenance. Le fichier canonique, ses tags, son hash et son analyse restent intacts.

L'encodage est un job serveur asynchrone, single-flight par `(sourceSha256, profileVersion, encoderVersion)`, à concurrence bornée. FFmpeg lit et écrit en flux vers un fichier temporaire. La variante n'est publiable qu'après validation Ogg/Opus, durée cohérente, mesure technique, taille bornée et SHA-256, puis renommage atomique. Les clés `sourceSha256 + opus-128-v1 + encoderVersion` et `sourceSha256 + opus-256-v1 + encoderVersion` sont distinctes et rendent toute variante obsolète dès que la source ou les paramètres changent. L'option originale réutilise le fichier canonique et sa route Range ; elle n'est jamais recopiée dans le cache de dérivées. Aucun transcodage à la volée dans une réponse HTTP et aucun transcodage mobile ne sont autorisés.

Avant encodage, l'interface affiche une **estimation** de taille Opus calculée depuis la durée et le débit, clairement distinguée d'une valeur mesurée. Une variante prête et l'original exposent leur taille exacte. La préférence de qualité peut être mémorisée par appareil, mais le choix reste visible et modifiable à chaque téléchargement.

Le téléchargement mobile est Range-resumable et n'est marqué disponible qu'après comparaison SHA-256. L'identité et les métadonnées vivent dans le manifeste SQLite ; l'audio et la pochette durable restent des fichiers du sandbox applicatif, partitionnés par compte. Une variante serveur peut être partagée physiquement entre utilisateurs, mais chaque création, manifeste et téléchargement revérifie l'accès à la piste.

La politique de sélection préfère l'original WAV/FLAC lorsque le serveur est réellement joignable, et la copie locale lorsqu'il ne l'est pas. Une reconnexion ne remplace pas la source en plein morceau : le titre courant se termine sans discontinuité et le prochain chargement utilise automatiquement l'original. Historique Phase 1A : la reprise locale au même index/position n'était pas encore implémentée ; elle l'est désormais par `TD-Offline-Continuity-2026-07-24`.

# TD-Offline-Impl-2026-07-22 — Implémentation Phase 1A (verticale une piste)

Réalisée le 2026-07-22 sous la mention « Implémentation Phase 1A autorisée sous réserve de qualification runtime ». Décisions d'implémentation :

- **Nom de table** : `track_offline_variants` (et non `offline_variants` esquissé dans ARCHITECTURE.md) pour suivre la convention `track_*` du schéma existant ; créée par réparation idempotente hors journal drizzle (leçon V3), testée sur base neuve et legacy.
- **Contrats** : routes exactement conformes à `MOBILE_ARCHITECTURE.md` (`offline-options`, `offline-variants/:profile`, `…/file`). DTO sans chemin serveur ; `sizeKind=estimated|exact` ; estimation déterministe `durée × débit × 125`. La route fichier réutilise `serveTrackFile` (même implémentation Range que stream/download, ETag = SHA-256 de la dérivée).
- **Politique d'accès** : identique à stream/download — piste de SA bibliothèque OU publiée au catalogue ; tombstone (`is_visible=false` partout) → 404 pour tous. La variante physique est mutualisée, l'autorisation revérifiée à chaque route.
- **Encodeur** : `FfmpegOpusEncoderRunner` (`FFMPEG_PATH`/`FFPROBE_PATH` sinon PATH), libopus VBR `-application audio`, conteneur Ogg, runner injectable dans les tests (jamais de ffmpeg réel en CI). `libopus` prouvé présent dans le FFmpeg 8.1.2 de la machine de dev ; l'environnement de service H24 reste `À vérifier`.
- **Cache dérivées** : `storage/cache/offline-opus` (`OFFLINE_CACHE_DIR`), concurrence `OFFLINE_ENCODE_CONCURRENCY` bornée 1..4 (défaut 1). `.part` confiné, publication uniquement après ffprobe (conteneur Ogg + codec opus + durée ±max(2 s, 5 %)) puis SHA-256 et rename atomique.
- **Mobile** : feature `offline/` (API interfaceée, manifeste sqflite `offline_library.db` partitionné par `user_id` sans token, downloader `.part` + reprise Range + SHA-256 (`package:crypto`) + rename atomique, feuille 3 profils avec préférence appareil `shared_preferences`, résolveur de source sonde `/health` 2 s — décision initiale à la construction de la file, étendue en Phase 1C par `TD-Offline-Continuity-2026-07-24`). Dépendances ajoutées : `crypto` (runtime), `sqflite_common_ffi` (dev, tests du manifeste réel).
- **Hors périmètre 1A historique** : bascule mi-lecture sur erreur du flux original (livrée dans le noyau Phase 1C le 2026-07-24), téléchargements groupés et purge LRU (livrés en Phase 1B). Les pochettes hors ligne et l'écran Téléchargements unitaire ont été livrés dans le complément UX 1A.1.
- **Durcissement du 2026-07-22** : un `READY` dont le fichier physique a disparu est automatiquement réarmé ; ffprobe doit fournir durée et débit valides ; l'arrêt du serveur annule puis attend les encodages actifs avant fermeture SQLite. Le mobile annule aussi pendant le polling, refuse un cache dont le hash source n'est plus courant, borne réellement la sonde `/health` à 2 s et transforme les erreurs de stockage en échecs explicites.

Statut : temporaire (qualification runtime différée — cf. TD-Gates-2026-07-22).

# TD-Offline-UX-2026-07-22 — Hors connexion réellement utilisable (Phase 1A.1)

Cause racine du blocage au démarrage hors ligne : `HomeSpotifyMobileApp` ne montait l'application principale que sur `AuthStatus.authenticated`, et `AuthController.initialize()` ne pouvait sortir de `loading` qu'après un appel réseau (`bootstrapRequired`/`me`). Sans serveur, l'app restait bloquée sur l'écran de chargement/erreur : les musiques téléchargées étaient inatteignables.

Décisions :

- **Session locale hors connexion** : après une connexion réussie, l'identité minimale du compte (`AuthUser.toJson` — id, username, displayName, role, isActive ; JAMAIS de token) est écrite dans `flutter_secure_storage` (clé `auth_local_identity`). Les tokens restent exclusivement dans le Keystore, jamais en SQLite/SharedPreferences/logs. Nouvel état `AuthStatus.offline` : serveur injoignable (erreur réseau, timeout ou 5xx) + identité connue → l'app principale se monte avec un bandeau « Mode hors connexion ». Une panne réseau n'est JAMAIS un logout ; seuls un logout explicite ou un 401 confirmé par un serveur joignable effacent session ET identité. Un appareil jamais connecté affiche un message de première connexion. Un timer (30 s) et un bouton « Réessayer » tentent le retour en ligne ; au succès, `me()` republie `authenticated` et invalide les providers réseau, sans redémarrer l'app.
- **Index hors ligne découplé** : `offlineUserIdProvider` (défaut `null`) est la source du compte pour la couche hors ligne, bridgée sur `authControllerProvider` uniquement dans `main.dart`. Ce découplage évite que chaque tuile de bibliothèque instancie le contrôleur d'auth complet (les écrans de test n'ont pas à stubber l'auth) tout en gardant la réactivité login/logout en production. `offlineIndexProvider` charge le manifeste du compte une seule fois, calcule la disponibilité RÉELLE (fichier présent + taille conforme) et expose compteur, espace occupé, badges et file locale ; il ne lève jamais d'exception (manifeste illisible ⇒ index vide).
- **Écran Téléchargements** (`/downloads`) : 100 % local pour son affichage (manifeste SQLite), aucun appel API requis pour s'afficher. Lecture locale, reprise/réessai (reconstruit la piste depuis le manifeste, pas depuis `GET /api/tracks`), suppression locale confirmée qui ne touche jamais le serveur, et indicateur de piste active branché sur la même session audio que le reste de l'app.
- **Bibliothèque hors ligne** : la liste distante et les pistes minimales du manifeste sont fusionnées par `track_id` (métadonnées serveur prioritaires). Une panne de `GET /api/tracks` ne masque donc plus les copies locales et le filtre « Téléchargées » reste fonctionnel.
- **Pochettes** : cache fichier durable sous `offline/u<userId>/covers/`, nom dérivé uniquement d'identifiants internes, écriture `.part` puis renommage atomique, taille bornée et MIME JPEG/PNG vérifié. L'absence de pochette n'invalide jamais l'audio ; les anciennes copies sont enrichies sobrement au prochain passage en ligne. L'URI `file://` alimente aussi `MediaItem.artUri`.
- **Lecture locale** : `buildLocalQueue` construit la file depuis le manifeste, URI `file://` sans en-tête `Authorization`, métadonnées du manifeste et pochette locale ; une copie absente ou tronquée est exclue. Historique 1A.1 : la source était figée à la construction ; la double source et la reprise mi-lecture sont désormais définies par `TD-Offline-Continuity-2026-07-24`.
- **Isolation** : manifeste et index partitionnés par `user_id`, fichiers sous `offline/u<userId>/` ; logout invalide l'index (cache immédiatement inaccessible) sans supprimer les fichiers ; retour sur le compte A restaure sa visibilité ; aucun fallback vers un autre `userId`.

Statut : temporaire (qualification runtime différée — cf. TD-Gates-2026-07-22 ; test téléphone Phase 1A.1 obligatoire avant production).

# TD-Gates-2026-07-22 — Gate de développement et gate de production (décision propriétaire)

Le séquencement des phases distingue désormais deux gates. Le **gate de développement** (tests automatisés verts + architecture validée) autorise, sur autorisation explicite du propriétaire, à développer la phase suivante. Le **gate de production** (critères runtime observés sur le vrai environnement — pour Phase 0 : session téléphone de 4 h post-correctif, restauration complète service arrêté, tableau OWNER sain) reste obligatoire avant de déclarer une phase terminée, une fonctionnalité prête pour production, ou tout déploiement officiel. Autorisation du 2026-07-22 : « Implémentation Phase 1A autorisée sous réserve de qualification runtime » ; le test de 4 h est reporté, pas supprimé. Statut : définitive (2026-07-22).

Par la même décision, les passages non sourcés autorisant cookies de contournement, endpoints opaques ou proxy vers URL dynamiques « parce qu'issus du .env » sont retirés de `CLAUDE.md` et de ce fichier (cf. L-078) : un secret externalisé reste soumis aux règles de sécurité et à la légitimité de l'API.

# TD-Offline-Batch-2026-07-24 — Lots album/playlist et budget de stockage (Phase 1B)

Les téléchargements d'album et de playlist sont une orchestration **mobile** des
contrats unitaires Phase 1A. Aucun endpoint batch n'est ajouté : chaque item
rejoint la variante single-flight existante, conserve ses garanties Range,
SHA-256 et publication atomique, et reste autorisé indépendamment. Cette
composition évite deux implémentations concurrentes du même téléchargement.

Le manifeste SQLite passe en version 2 et ajoute
`offline_download_groups`/`offline_download_group_items`, toujours partitionnés
par `user_id` au niveau du groupe et sans secret. Groupe et items sont écrits
avant le premier octet. Un seul groupe et une seule piste sont transférés à la
fois sur l'appareil pour limiter CPU, radio et disque ; la concurrence serveur
reste bornée séparément. Un groupe survit à la mort du processus, attend le
réseau autorisé, revient en attente si le serveur disparaît au milieu du lot,
se met en pause faute d'espace et permet de relancer uniquement les items en
erreur.

La reprise commence par une réconciliation physique : fichier présent, taille
cohérente et même empreinte source. Elle adopte un fichier publié juste avant un
crash, remet un item `running` sans fichier en attente, et rétrograde un groupe
terminé en `partial` après purge ou remplacement de source. Le manifeste seul
n'est jamais une preuve de disponibilité.

La politique réseau par défaut est Wi-Fi/ethernet uniquement. L'utilisateur
peut autoriser explicitement le cellulaire et choisir un plafond de 2, 5, 10 ou
20 Go, ou aucun plafond applicatif. Android expose l'espace libre du sandbox par
un MethodChannel `StatFs`; une réserve de 200 Mo demeure obligatoire. La purge
LRU utilise `last_accessed_at`, n'agit qu'après confirmation et supprime
uniquement fichier + manifeste locaux. Elle ne touche ni la bibliothèque, ni la
source canonique, ni la variante serveur partagée.

Statut : temporaire, jusqu'à qualification téléphone des reprises, du mode avion
et des limites de stockage.

# TD-Offline-Continuity-2026-07-24 — Double source et reprise Phase 1C

Une entrée de file audio n'est plus seulement une URI active : elle conserve
l'URI HTTP(S) canonique et, si elle existe, la meilleure copie `file://`
vérifiée par le manifeste, la taille et le hash source courant. Le probe
`/health` choisit la source initiale mais ne détruit jamais l'alternative.

Un signal de connectivité seul ne reconstruit pas le titre en cours. Si le flux
réseau produit une erreur transitoire, le handler recharge toute la timeline
Media3 au même index et à la position observée, avec la copie locale et
`preload: true`. Au retour du réseau, le titre local courant se termine ; le
premier changement d'index recharge l'original et prépare la suite. Une erreur
de fichier local suit le chemin inverse avant la politique de saut borné. Ces
reconstructions sont single-flight, diagnostiquées et annulent toute attente de
reprise réseau devenue inutile.

Les headers restent mémorisés uniquement en mémoire pour les sources distantes :
`toAudioSource` force toujours `headers=null` pour `file://`. La session
persistée accepte désormais HTTP(S) et fichiers locaux absolus, stocke les deux
URI et le MIME local, mais aucun header ni token. Le schéma JSON reste en version
1 car les champs sont additifs et les anciennes sessions restent lisibles.

Le gapless n'est jamais promis universellement : HomeSpotify conserve le
préchargement natif de la file et laisse Media3 enchaîner sans coupure seulement
si codecs, conteneurs et timelines le permettent. Une reconstruction de secours
peut produire une très courte remise en tampon ; elle est préférée à un arrêt,
un saut ou une reprise au début.

Statut : temporaire jusqu'aux tests téléphone réels (coupure serveur au milieu
d'un titre, position de reprise, écran éteint, retour réseau et fichier local
supprimé).

Le minuteur Phase 1C vit exclusivement dans `HomeSpotifyAudioHandler` afin de
rester actif écran éteint et application en arrière-plan. Les durées autorisées
par l'UI sont 15, 30, 45 et 60 minutes, avec une option « fin du titre ». Son
expiration met en pause sans vider la file ni perdre la position. Le mode fin de
titre intercepte à la fois la complétion logique et un changement d'index natif,
ce qui couvre le watchdog Media3 ; un stop, une purge, un logout ou le
remplacement complet de la file annule l'intention « fin du titre ». L'état
n'est pas persisté après mort du processus : une
ancienne intention de sommeil ne doit jamais interrompre une nouvelle session.
Les armements, annulations et expirations sont diagnostiqués sans donnée
personnelle.

## TD-ReplayGain-2026-07-24 — Normalisation mesurée, facultative et non destructive

La normalisation est désactivée par défaut. Lorsqu’elle est activée, l’API
planifie une analyse complète de la piste avec le filtre FFmpeg `loudnorm` et
persiste séparément la sonie intégrée EBU R128, le true peak et le gain calculé
dans `track_loudness_analysis`. La cible est -18 LUFS, avec un plafond
true-peak de -1 dBFS ; le gain final est le minimum entre l’écart à la cible et
la marge au plafond, borné à -24/+12 dB. Une mesure absente, silencieuse,
invalide ou échouée n’autorise aucun gain inventé.

L’analyse est une file de fond à concurrence 1, reprise après redémarrage. Une
requête authentifiée ne bloque jamais sur le décodage : elle reçoit
`PENDING|ANALYZING|READY|FAILED`. FFmpeg lit en flux, ne produit aucun fichier
intermédiaire, est tué au timeout et ne modifie jamais la source. Les mesures
`READY` sont partagées techniquement, mais l’autorisation d’accès à la piste est
revérifiée à chaque lecture de l’API.

Le mobile conserve uniquement les mesures `READY` validées pour pouvoir
appliquer le même gain hors connexion. Le volume choisi par l’utilisateur reste
une valeur indépendante : un gain négatif devient un facteur linéaire dans le
handler audio, tandis qu’un gain positif utilise `AndroidLoudnessEnhancer`.
L’effet Android n’accepte donc jamais une atténuation négative. À chaque
changement de piste, la remise à zéro est attendue avant l’application de la
nouvelle mesure afin d’éviter toute course. Aucune valeur n’est dérivée d’un
tag, d’un nom de fichier ou d’une extension.

Statut : implémenté et testé automatiquement ; validation perceptive sur
téléphone, Bluetooth et changement de vitesse encore requise avant production.

### TD-Phase5-Real-Cache-Qualification — qualification réelle close en GO (2026-07-27)

**GO FINAL — PHASE 5 VALIDÉE DÉFINITIVEMENT.** `CachedAudioStorageProvider` a
été qualifié depuis une API VPS parallèle liée à `127.0.0.1:3001`, sur trois
racines de cache isolées, avec `failedChecks=[]` et `ok=true` pour chaque
scénario. Le provider n'a présenté **aucun défaut** : les cinq défauts trouvés
étaient dans le harnais de validation.

Preuves : promotion atomique d'un objet de 9 165 881 octets avec
`indexEntryCount=1` et `partCount=0` ; `CACHE_HIT` corrélé par `requestId`,
sans `REMOTE_STORAGE_REQUEST_STARTED` ; HEAD et Range HIT ; agent arrêté →
GET 200, HEAD 200, Range 206 sur l'objet caché et 503 `service_unavailable`
sur une piste non cachée, sans 401 public ; redémarrage de l'API → index et
objet récupérés ; abandon → `.part` supprimé, aucune promotion, verrou
single-flight prouvé libéré par un second remplissage réel, `activeStreams=0` ;
éviction LRU réelle avec `CACHE_EVICTION_STARTED` / `CACHE_EVICTED`.

Mesures de référence : TTFB MISS 133,5 ms contre HIT 13,0 ms ; débit MISS
4,552 Mio/s contre HIT 182,083 Mio/s ; HEAD HIT 8,0 ms ; Range HIT 9,5 ms ;
HEAD HIT après redémarrage 12,5 ms. Le gain du cache est donc d'environ 40× en
débit et 10× en latence sur le lien réel — la question laissée ouverte en
Phase 4 (« le coût de l'aller-retour est l'objet de la Phase 5, pas d'une
supposition ») est close avec des chiffres.

**Un paramètre calibré pour forcer un comportement ne doit jamais être
global.** La limite unique `AUDIO_CACHE_MAX_BYTES = max(small, second) + 1`
rendait l'éviction déterministe et, par construction, détruisait la
précondition de tout scénario ayant besoin qu'un objet survive. Décision :
racine de cache **et** capacité par scénario (`finalize-offline`, `abort`,
`eviction`), scénario hors ligne exécuté immédiatement après la finalisation,
et précondition **prouvée puis verrouillée** avant toute action coûteuse ou
irréversible — ici l'arrêt du Storage Agent, refusé sans laissez-passer.

**Ce GO n'autorise aucune bascule.** La production reste sur HomeSpotifyApi
Windows avec `AUDIO_STORAGE_MODE` absent/local ; Caddy, WireGuard et le
pare-feu sont inchangés. La Phase 6 est un lot séparé, en déploiement shadow,
sans exposition publique.
