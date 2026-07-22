# ROADMAP.md — Feuille de route officielle HomeSpotify

> Mise à jour : 2026-07-22. Cette feuille remplace l'ancienne numérotation
> « backend Phase 1–3 / mobile Phase 4 ». Les anciens lots livrés sont conservés
> plus bas comme historique, mais toute nouvelle mention de **Phase 1** désigne
> désormais « Hors connexion et lecture parfaite ».

## État officiel

| Phase produit | État | Condition suivante |
|---|---|---|
| Phase 0 — Stabilisation et vérité produit | **EN COURS — en attente de qualification physique** | APK/backend corrigés déployés, session réelle post-correctif de 4 h réussie et restauration complète prouvée |
| Phase 1 — Hors connexion et lecture parfaite | **1A EN COURS — développement autorisé, qualification runtime différée** (autorisation explicite du propriétaire, 2026-07-22) | Gate de production Phase 0 obligatoire avant toute déclaration « terminée » ou « prête pour production » |
| Phase 2 — Super-bibliothèque | À venir | Phase 1 qualifiée |
| Phase 3 — Découverte explicable | À venir | Phase 2 qualifiée |
| Phase 4 — Connect et social privé | À venir | Phase 3 qualifiée |
| Phase 5 — Plateformes et finitions | À venir | Phase 4 qualifiée |

Règle : une phase ne devient `TERMINÉE` que si ses critères ont été observés sur
le vrai environnement. Une suite de tests verte ne remplace pas un test runtime.

### Deux gates distincts (décision propriétaire, 2026-07-22)

- **Gate de développement** : tests automatisés verts et architecture validée.
  Il autorise, sur autorisation explicite du propriétaire, à développer la phase
  suivante. Statut : **atteint** le 2026-07-22 (backend 284/284, Flutter
  305/305, correctifs L-075 présents et testés).
- **Gate de production** : session téléphone réelle de 4 h post-correctif et
  restauration complète prouvée (détail ci-dessous). Il reste obligatoire avant
  de déclarer la Phase 0 terminée, la Phase 1A prête pour production, ou de
  publier/déployer officiellement le hors connexion. Statut : **non atteint**.
  Le test de 4 h est **reporté, pas supprimé**.

Implémentation Phase 1A autorisée sous réserve de qualification runtime.

## Gate de sortie de Phase 0

### Déjà livré

- Service média Android obligatoire avant toute lecture, notification et
  foreground service validés sur téléphone.
- Session, file, index, position, repeat/shuffle et vitesse persistés sans token.
- Refresh JWT proactif, propagation du Bearer aux sources Media3 et reprise réseau.
- Tombstones de suppression de bibliothèque, scanner récursif par profil,
  sauvegarde planifiée, scripts de restauration/rotation du secret et tableau de
  santé OWNER.
- Diagnostic audio corrélé mobile/backend et tests de longue file.
- Correctif local du 2026-07-22 : garde périodique fin de piste, détection
  fin→zéro, clôture des anciennes sessions d'une installation et nettoyage de
  l'erreur média après récupération.

### Preuves encore obligatoires

1. Déployer le backend corrigé et installer l'APK release contenant le correctif
   du 2026-07-22.
2. Réussir **4 h continues** sur téléphone réel, écran éteint et usage normal,
   sans arrêt, boucle, saut prématuré ni commande réseau/batterie intrusive.
3. Vérifier dans les logs : zéro 401 non récupéré, zéro 5xx audio, zéro session
   fantôme `ACTIVE/PAUSED`, aucune écoute comptée au-delà de la durée tolérée.
4. Réaliser une sauvegarde réelle puis une restauration complète service arrêté,
   avec `integrity_check`, hash et reprise du service.
5. Vérifier le tableau OWNER : API, disque, dernière sauvegarde, dernier scan,
   erreurs audio et fichiers suspects.

Le test du 2026-07-22 a duré environ 3 h 43 : il est utile mais **ne valide pas**
le gate. Son diagnostic et ses correctifs sont consignés dans
`AUDIO_STABILITY_DIAGNOSTICS.md`, `TECH_DECISIONS.md` et `LESSONS.md` L-075.

## Phase 1 — Hors connexion et lecture parfaite

### Objectif

Donner à chaque compte une bibliothèque réellement utilisable sans réseau, sans
modifier l'archive WAV/FLAC du serveur et sans fragiliser le lecteur en ligne.

### Qualités proposées à chaque téléchargement

| Profil | Usage | Taille affichée | Vérité qualité |
|---|---|---|---|
| `opus_128` — Opus 128 kb/s VBR | économie de stockage et de données | estimation avant encodage, taille exacte une fois prête | lossy |
| `opus_256` — Opus 256 kb/s VBR | haute qualité compacte, **recommandée** | estimation avant encodage, taille exacte une fois prête | lossy, jamais « lossless » |
| `original` — WAV/FLAC | copie exacte de l'archive | taille exacte du fichier source | qualité mesurée de la source |

Le choix est présenté pour chaque piste, album ou playlist et la préférence peut
être mémorisée par appareil. Une copie Opus est une dérivée : elle ne remplace,
ne renomme et ne réécrit jamais la source. Le mobile ne transcode rien.

### Phase 1A — Verticale complète sur une piste

> **État 2026-07-22** : implémentée et testée en automatique (backend 306/306
> dont 20 tests hors ligne + migrations neuve/legacy ; Flutter 343/343 ;
> typecheck propre ; analyze 0 erreur / 0 warning). NON qualifiée pour
> production : gate de production Phase 0 (session 4 h + restauration réelle)
> toujours obligatoire, et test manuel téléphone de la verticale à faire.
> Détails : TD-Offline-Impl-2026-07-22 et TD-Offline-UX-2026-07-22 (Phase 1A.1).

- Contrats versionnés `offline-options`, création/lecture de variante et fichier
  Range-resumable, tous authentifiés et isolés par `user_tracks` visible.
- Jobs serveur persistants et à concurrence bornée ; single-flight par
  `(sourceSha256, profileVersion, encoderVersion)`.
- Encodage serveur en flux vers `.part`, validation ffprobe (Ogg/Opus, durée,
  débit mesuré), calcul SHA-256 puis renommage atomique.
- L'original utilise la route Range existante et n'est jamais recopié dans le
  cache serveur des dérivées.
- Feuille mobile de choix des trois profils avec taille et caractère
  estimé/exact explicites ; progression, annulation, reprise et erreurs utiles.
- Manifeste SQLite mobile partitionné par compte ; `.part`, reprise HTTP Range,
  vérification SHA-256 et publication locale atomique.
- Sélection de source : original en ligne, fichier local vérifié hors ligne ;
  une reconnexion ne change jamais de source au milieu d'un titre.
- Tests métier critiques backend + Flutter avant tout travail album/playlist.

#### Phase 1A.1 — Hors connexion réellement utilisable (2026-07-22)

> **État** : implémentée ; baseline précédente backend 306/306 et Flutter
> 343/343 dont 19 tests d'utilisabilité hors connexion. Le complément
> bibliothèque/pochettes/indicateur ajoute 4 tests ciblés ; analyse statique
> propre (0 erreur, 0 warning) mais relance Flutter locale requise, le SDK de
> l'agent ne permettant pas d'écrire son lockfile. NON qualifiée pour
> production : test téléphone réel obligatoire (mode avion, redémarrage,
> isolation multi-comptes). Détails : TD-Offline-UX-2026-07-22.

Complète la verticale 1A pour la rendre exploitable au quotidien :

- **Session locale hors connexion** : identité minimale du compte (jamais de
  token) persistée dans `flutter_secure_storage` après une connexion réussie.
  Au démarrage, serveur injoignable + session connue → `AuthStatus.offline`
  (bandeau « Mode hors connexion », app accessible). Une panne réseau/timeout/
  5xx n'est jamais un logout ; seuls un logout explicite ou un 401 confirmé
  par un serveur joignable effacent session et identité. Retour serveur →
  reprise en ligne automatique sans redémarrage.
- **Écran Téléchargements** (`/downloads`) alimenté uniquement par le manifeste
  SQLite : liste par piste (profil, taille exacte, état, progression), lecture
  locale, reprise/réessai, suppression locale confirmée ; en-tête compteur +
  espace occupé ; filtres par état/profil ; état vide clair ; piste en cours
  mise en évidence depuis la source de vérité du lecteur.
- **Bibliothèque** : badge « téléchargé » + profil local par piste et filtre
  « Téléchargées », via un index mémoire chargé une fois (jamais une requête
  SQLite par piste), rafraîchi après téléchargement/suppression. Si le
  catalogue réseau est indisponible, les métadonnées du manifeste reconstruisent
  la liste locale au lieu de produire un filtre vide.
- **Lecture locale sans API** : file construite depuis le manifeste
  (titre/artiste/album/durée/chemin), URI `file://` sans Bearer ; une copie
  absente ou de taille incohérente est marquée indisponible, jamais lue.
- **Pochettes hors ligne** : copie durable, atomique et partitionnée par compte,
  réutilisée dans Bibliothèque, Téléchargements et la session média Android ;
  enrichissement non bloquant pour les anciennes copies au retour du serveur.
- **Isolation** : l'index et les copies sont partitionnés par compte ; un
  logout rend le cache immédiatement inaccessible sans supprimer les fichiers ;
  aucun fallback vers un autre `userId`.

### Phase 1B — Albums, playlists et gestion du stockage

- Téléchargements groupés avec état global et état par piste, reprise après mort
  du processus et échecs partiels relançables.
- Écran Téléchargements : filtres, espace utilisé, suppression locale, politique
  Wi-Fi/cellulaire, limite configurable et nettoyage LRU uniquement avec accord.
- Invalidation sûre lorsque le hash source ou la version d'encodeur change.
- Aucun autre profil implicite : le cache local connaît toujours son codec,
  conteneur, débit mesuré, taille, hash et source ETag.

### Phase 1C — Lecture parfaite online/offline

- Bascule réseau robuste sans coupure : le titre courant termine sur sa source,
  le suivant choisit la meilleure source autorisée par la politique réseau.
- Préchargement de la piste suivante et transitions gapless quand les formats et
  le lecteur le permettent, sans masquer une erreur de timeline.
- Reprise déterministe après redémarrage, perte réseau ou fichier local invalide.
- Minuteur de sommeil ; ReplayGain uniquement facultatif, mesuré et sans jamais
  réécrire les fichiers canoniques.

### Critères de fin Phase 1

- Un titre, un album et une playlist sont téléchargeables dans les trois profils.
- Mode avion : lecture locale, seek, suivant/précédent, queue et arrière-plan
  fonctionnent sans appel serveur.
- Interruption/reprise d'un téléchargement lourd validée avec hash final exact.
- Isolation multi-utilisateur prouvée ; logout ne permet aucun accès à l'audio
  local d'un autre compte.
- Quatre heures de lecture mixte online/offline sans arrêt, boucle, doublon de
  transition ni session fantôme.
- Aucune dérivée Opus n'est présentée comme lossless ; les tailles estimées sont
  distinguées des tailles mesurées.

## Phases suivantes

### Phase 2 — Super-bibliothèque

Édition contrôlée des métadonnées, collections intelligentes, filtres avancés,
historique riche, doublons, qualité et santé de bibliothèque, import/export de
playlists et outils OWNER de maintenance.

### Phase 3 — Découverte explicable

Recherche catalogue consolidée, recommandations explicables et réglables,
radios déterministes, profils de goût visibles et demandes musicales toujours
séparées de toute acquisition audio automatique.

### Phase 4 — Connect et social privé

Reprise multi-appareils, télécommande de session, écoute familiale privée,
activité et partage opt-in, avec permissions explicites.

### Phase 5 — Plateformes et finitions

iOS, desktop/web si justifiés, accessibilité, performance, localisation et
polish visuel après validation des invariants audio et hors connexion.

## Hors périmètre actif

- SpotiFLAC, extraction de services tiers, téléchargement automatique depuis une
  recherche et contournement de DRM : **reportés et non nécessaires à Phase 1**.
- Réseau social public, podcasts, livres et vidéo avant maîtrise de l'audio,
  du hors connexion et du multi-appareils.
- Transcodage sur le téléphone ou à la volée dans une réponse HTTP.

## Historique des anciens lots livrés

L'ancienne roadmap 0–7 a fourni le socle aujourd'hui exploité : documentation,
backend Fastify/SQLite, import et scanner WAV/FLAC, streaming Range, métadonnées,
client Flutter, authentification multi-utilisateur, bibliothèque, playlists,
découverte/demandes, lecteur Android de fond et premiers outils d'exploitation.
Cette numérotation est archivée pour éviter de confondre « ancien backend Phase
1 » avec la Phase 1 produit actuelle.
