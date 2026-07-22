# HomeSpotify — Audit produit complet et feuille de route

> **Addendum du 2026-07-22** : ce document reste le rapport d'audit détaillé.
> `ROADMAP.md` est désormais l'unique autorité sur l'état des phases. La Phase 0
> reste ouverte jusqu'à une session réelle post-correctif de 4 h et une
> restauration complète prouvée. La Phase 1 propose par téléchargement
> `opus_128`, `opus_256` (recommandé) ou `original`, avec taille estimée ou
> exacte explicitement distinguée. SpotiFLAC et toute acquisition automatique
> restent hors périmètre actif.

**Date :** 21 juillet 2026  
**Périmètre audité :** dépôt `F:\dev\homespotify`, application Android Flutter, API Fastify, base SQLite, lecteur Android natif et documentation d’architecture.  
**Objectif :** faire de HomeSpotify une application musicale meilleure que Spotify sur un périmètre réaliste et assumé : la bibliothèque personnelle et familiale, la qualité audio vérifiable, le contrôle, la confidentialité et la découverte explicable.

---

## 1. Synthèse exécutive

HomeSpotify n’est plus un prototype. Le dépôt contient déjà les fondations d’un vrai service musical privé : comptes isolés, streaming WAV/FLAC avec HTTP Range, lecture Android en arrière-plan, favoris, playlists, historique fiable, recommandations, recherche de catalogue multi-fournisseurs, demandes musicales, imports contrôlés et administration.

Le produit a toutefois un décalage important entre la richesse de son backend et l’expérience perçue : plusieurs fonctions sont difficiles à découvrir, certaines informations affichées sont obsolètes, la recherche/découverte dépend encore fortement de fournisseurs externes fragiles, le mode hors connexion utilisateur n’est pas livré, et il manque les fonctions qui rendent un lecteur musical quotidiennement irremplaçable : gapless, reprise multi-appareils, téléchargements, playlists intelligentes, métadonnées éditables, contrôle de la recommandation, paroles, égalisation/normalisation facultative et écosystème d’appareils.

### Verdict

- **Socle technique : solide et différenciant.** Le streaming, l’authentification, l’isolation multi-utilisateur et la télémétrie d’écoute sont bien plus avancés que l’interface ne le laisse penser.
- **Produit actuel : utilisable, mais encore incomplet pour remplacer Spotify au quotidien.** Le point bloquant principal est l’absence de véritable mode hors connexion, suivi par le manque de continuité entre appareils et de finition de la bibliothèque.
- **Différenciation possible : forte.** HomeSpotify peut devenir meilleur que Spotify pour une famille ou un petit groupe qui possède ses fichiers et veut maîtriser ses données, sa qualité et ses règles de recommandation.
- **Limite structurelle : le catalogue mondial.** Sans accords de licence, HomeSpotify ne peut ni légalement ni économiquement égaler le catalogue à la demande de Spotify. Le produit doit gagner par l’expérience autour d’une bibliothèque possédée, pas promettre un catalogue commercial gratuit.

### Priorités absolues

1. Livrer un vrai mode hors connexion Android.
2. Rendre la lecture irréprochable : gapless, reprise, préchargement, récupération réseau et file persistante.
3. Transformer la bibliothèque en outil puissant : recherche instantanée, playlists intelligentes, tags, crédits, édition et contrôle des doublons.
4. Rendre la découverte explicable et pilotable par l’utilisateur.
5. Construire « HomeSpotify Connect » pour le passage et le contrôle entre appareils.
6. Industrialiser sauvegardes, restauration, observabilité et distribution des mises à jour.

---

## 2. Méthode et niveau de preuve

L’audit s’appuie sur :

- les routes réellement enregistrées dans l’application Flutter ;
- les routes HTTP, services métier, migrations et tables réellement présents dans l’API ;
- les écrans, contrôleurs Riverpod, repositories et clients locaux ;
- la couche Android de lecture audio et les diagnostics ;
- les documents de fondation du dépôt ;
- un inventaire statique des tests ;
- les pages officielles Spotify disponibles au 21 juillet 2026.

Légende utilisée :

| État | Signification |
|---|---|
| ✅ Opérationnel | Parcours et code présents de bout en bout |
| 🟡 Présent à consolider | Fonction présente, mais validation réelle, UX ou exploitation à renforcer |
| 🟠 Fondation seulement | Backend ou modèle présent, sans parcours utilisateur complet |
| ⚪ Absent | Fonction non trouvée dans le produit actuel |
| ⛔ Hors périmètre volontaire | Fonction à ne pas faire sans cadre juridique ou produit adapté |

L’inventaire des tests trouve **28 fichiers de tests backend pour environ 279 cas**, **45 fichiers Flutter pour environ 286 cas**, et **4 fichiers de tests natifs**. Ces nombres proviennent d’une analyse statique du dépôt, pas d’une exécution complète effectuée pendant cet audit.

---

## 3. Architecture actuelle

### 3.1 Vue d’ensemble

```text
Application Android Flutter
  ├─ navigation GoRouter + état Riverpod
  ├─ bibliothèque locale légère et file d’événements SQLite
  ├─ audio_service / audio_session / just_audio personnalisé
  └─ moteur Android Signalsmith avec repli Sonic
                 │ HTTPS + Bearer JWT
                 ▼
API Fastify / Node.js
  ├─ comptes, sessions, autorisations et audit
  ├─ catalogue personnel, favoris et playlists
  ├─ streaming HTTP Range et téléchargement
  ├─ découverte, recommandations et demandes
  ├─ imports, métadonnées et analyses audio
  └─ SQLite / Drizzle + fichiers audio sur disque
                 │
                 ├─ Deezer, iTunes, MusicBrainz et fournisseurs optionnels
                 └─ ffmpeg/ffprobe et analyse locale
```

### 3.2 Qualités architecturales

- Les fichiers audio restent sur disque et sont envoyés en flux ; ils ne transitent pas par la base.
- La déduplication physique repose sur le SHA-256 calculé en streaming.
- L’accès logique d’un utilisateur à une piste est séparé du fichier physique via `user_tracks`.
- La vérité audio mesurée est séparée de l’enrichissement descriptif externe.
- Les événements d’écoute mobiles sont mis en file localement puis synchronisés de façon idempotente.
- Les fonctions de découverte externes sont normalisées, mises en cache et protégées des réponses brutes.
- Le lecteur Android possède une instrumentation détaillée des changements d’état, du réseau et du moteur de time-stretch.

### 3.3 Risques architecturaux

- SQLite convient encore au périmètre familial, mais les tâches de fond, la recherche et les caches doivent rester bornés pour éviter la contention.
- Le catalogue de découverte dépend de fournisseurs externes dont les couvertures, aperçus et quotas ne sont pas garantis.
- L’état de déploiement réel du serveur et certaines options affichées par l’application ne sont pas alignés avec le code.
- La stratégie de sauvegarde/restauration et la supervision H24 ne sont pas démontrées de bout en bout.
- Android est la seule plateforme cliente livrée ; il n’existe pas encore de couche de contrôle multi-appareils.

---

## 4. Inventaire complet des fonctionnalités présentes

### 4.1 Comptes, sécurité et multi-utilisateur

| Fonction | État | Analyse |
|---|---:|---|
| Création initiale du propriétaire | ✅ | Bootstrap du premier compte OWNER |
| Connexion locale | ✅ | Identifiant/mot de passe, Argon2id côté serveur |
| Rôles OWNER / ADMIN / USER | ✅ | Contrôles serveur et écrans conditionnels |
| JWT d’accès + refresh token rotatif | ✅ | Renouvellement préventif et réactif |
| Stockage sécurisé des jetons | ✅ | `flutter_secure_storage` |
| Biométrie locale | ✅ | Activation facultative dans les paramètres |
| Changement obligatoire du mot de passe | ✅ | Parcours prévu après réinitialisation |
| Blocage/réactivation d’un compte | ✅ | Administration utilisateur |
| Révocation des sessions | ✅ | Action d’administration et rotation de session |
| Journal d’audit | ✅ | Traces des opérations sensibles |
| Bibliothèques isolées par compte | ✅ | Relation `user_tracks`, favoris, playlists, historique et demandes propres |
| Export des données personnelles | ⚪ | À ajouter |
| Suppression autonome du compte | ⚪ | À ajouter avec garde-fous OWNER |
| Double authentification | ⚪ | Utile surtout pour OWNER distant |

**Appréciation : 8/10.** Le socle est sérieux. Il faut conserver des jetons courts et un refresh transparent plutôt que supprimer toute expiration : une session fluide ne doit pas devenir un accès éternel volable.

### 4.2 Accueil et navigation

| Fonction | État | Analyse |
|---|---:|---|
| Accueil personnalisé | ✅ | Salutation et identité utilisateur |
| Recherche accessible depuis l’accueil | ✅ | Accès au catalogue distant |
| Carte de lecture en cours | ✅ | Reprise du média actif |
| Accès rapides | ✅ | Favoris, playlists, albums et artistes |
| Nouveautés du catalogue interne | ✅ | Ajout direct à la bibliothèque personnelle |
| Résumé de bibliothèque | ✅ | Nombre de titres, albums et artistes |
| Accueil réorganisable | ⚪ | Aucun système de widgets/sections configurables |
| Reprise serveur multi-appareils | ⚪ | La carte actuelle reflète surtout le lecteur local |

**Appréciation : 6,5/10.** L’accueil couvre les bases, mais il doit devenir contextuel, personnalisable et réellement continu entre appareils.

### 4.3 Bibliothèque musicale

| Fonction | État | Analyse |
|---|---:|---|
| Liste des titres personnels | ✅ | Recherche, filtrage et tri |
| Albums regroupés | ✅ | Vues liste et détail |
| Artistes regroupés | ✅ | Vues liste et détail |
| Favoris par utilisateur | ✅ | Optimisme UI avec retour arrière en cas d’erreur |
| Playlists personnelles | ✅ | Création, renommage, suppression, ordre des titres et lecture |
| Ajout/retrait de la bibliothèque | ✅ | Suppression logique sans effacer le fichier partagé |
| Lecture de la sélection visible | ✅ | Construction de file depuis la vue filtrée |
| Détail technique du fichier | ✅ | Métadonnées et qualité disponibles selon analyse |
| Recherche serveur plein texte | 🟡 | Plusieurs recherches restent locales ou simples ; pas de FTS riche démontré |
| Playlists intelligentes | ⚪ | Absentes |
| Tags personnels | ⚪ | Absents |
| Éditeur de métadonnées | ⚪ | Absent |
| Gestion des éditions/doublons | ⚪ | Déduplication fichier oui, centre UX non |
| Vue dossiers | ⚪ | Absente |
| Crédits complets | ⚪ | Modèle d’enrichissement partiel seulement |
| Paroles synchronisées | ⚪ | Absentes |

**Appréciation : 7/10.** La bibliothèque est fonctionnelle mais pas encore assez expressive pour valoriser une collection personnelle mieux que Spotify.

### 4.4 Lecteur et qualité audio

| Fonction | État | Analyse |
|---|---:|---|
| Lecture/pause, précédent/suivant et seek | ✅ | Commandes écran, notification et verrouillage |
| File d’attente | ✅ | Consultation, réordonnancement et lecture |
| Aléatoire et répétition | ✅ | États gérés par le lecteur |
| Volume | ✅ | Contrôle exposé |
| Lecture en arrière-plan Android | ✅ | Service média, notification, casque et audio focus |
| Notification multimédia | ✅ | Architecture présente ; à maintenir dans les tests réels de marque Android |
| Streaming HTTP Range | ✅ | 200/206/416, ETag et flux sans chargement complet |
| WAV / FLAC natifs sans transcodage | ✅ | Source originale diffusée |
| Qualité audio mesurée | ✅ | Codec, fréquence, profondeur, canaux, statut et provenance séparés |
| Vitesse 0,70–1,30 par titre | ✅ | Pitch préservé, Signalsmith et repli Sonic |
| BPM | 🟡 | Tag prioritaire, analyse ffmpeg asynchrone avec confiance |
| Diagnostic longue session | ✅ | JSONL, export, marqueurs et écran propriétaire/debug |
| Reprise après coupure réseau | 🟡 | Instrumentation présente, résilience réelle à éprouver sur plusieurs réseaux |
| Gapless | ⚪ | Non identifié comme fonction utilisateur livrée |
| Crossfade / transitions | ⚪ | Absent |
| Normalisation ReplayGain facultative | ⚪ | Absente |
| Égaliseur | ⚪ | Absent |
| Préchargement intelligent du prochain titre | ⚪ | Non démontré |
| Minuteur de sommeil | ⚪ | Absent |
| Boucle A–B et marqueurs | ⚪ | Absents |
| Choix de sortie / contrôle distant | ⚪ | Pas de HomeSpotify Connect |

**Appréciation : 7,5/10.** Le moteur et les diagnostics sont une force rare. La priorité n’est pas d’ajouter des effets gadgets, mais d’obtenir une lecture gapless, persistante et récupérable dans toutes les conditions.

### 4.5 Historique et activité d’écoute

| Fonction | État | Analyse |
|---|---:|---|
| Sessions d’écoute identifiées | ✅ | UUID client, installation et statut |
| Événements détaillés | ✅ | Start, resume, progress, pause, seek, complete, skip, stop, error et changement de titre |
| Temps écouté monotone | ✅ | Protégé des retries et événements désordonnés |
| Qualification d’une écoute | ✅ | Seuil basé sur durée écoutée |
| File locale hors connexion | ✅ | SQLite mobile, backoff, compactage et retry |
| Reprendre l’écoute | ✅ | Position récente par titre |
| Historique paginé | ✅ | Consultation et suppression |
| Statistiques personnelles | ⚪ | Pas de tableau de bord hebdo/mensuel complet |
| Scrobbling externe facultatif | ⚪ | Absent |
| Export d’historique | ⚪ | Absent |

**Appréciation : 8/10.** La collecte est meilleure que l’exploitation produit. Les données existent déjà pour construire un « Wrapped permanent » privé et transparent.

### 4.6 Découverte, recherche distante et recommandations

| Fonction | État | Analyse |
|---|---:|---|
| Recherche titres/artistes/albums/playlists | ✅ | Agrégation de plusieurs fournisseurs |
| Deezer, iTunes et MusicBrainz | ✅ | Fournisseurs de base |
| Spotify et Apple optionnels | 🟡 | Dépendent de clés et de configuration |
| Normalisation et fusion | ✅ | Modèle commun, classement et cache |
| Déduplication | 🟡 | Présente et récemment renforcée ; nécessite des tests de cas réels |
| Filtrage artiste exact | 🟡 | Présent ; la pertinence dépend encore des données fournisseurs et du cache |
| Couvertures et photos | 🟡 | Enrichissement multi-source, disponibilité non garantie |
| Aperçus audio | 🟡 | Fallbacks présents, mais aucune API gratuite ne garantit un extrait pour tout le catalogue |
| Pages artiste et album distantes | ✅ | Navigation dédiée |
| Swipe de recommandations | ✅ | Like, dislike, skip, ouverture et demande |
| Pré-calcul des recommandations | ✅ | File utilisateur et impressions |
| Similarité Last.fm / résolution iTunes | 🟡 | Pipeline documenté et dépendances externes |
| Explication « pourquoi ce titre » | ⚪ | Absente ou insuffisante côté utilisateur |
| Contrôle du profil de goût | ⚪ | Absent |
| Radio à partir d’un titre/artiste | ⚪ | Absente |
| Recherche en langage naturel | ⚪ | Absente |
| Embeddings audio locaux | ⚪ | Absents |

**Appréciation : 6/10.** La plomberie multi-fournisseurs est ambitieuse. Pour progresser, il faut moins dépendre d’un aperçu distant et davantage exploiter la bibliothèque locale, l’historique réel et des explications visibles.

### 4.7 Demandes musicales et imports

| Fonction | État | Analyse |
|---|---:|---|
| Demande de titre, album ou playlist | ✅ | Création depuis la découverte et suivi utilisateur |
| Snapshot des éléments demandés | ✅ | Suivi partiel d’un album/playlist |
| Annulation utilisateur | ✅ | Selon statut |
| Administration des demandes | ✅ | Filtres, détail, statut et rapprochement |
| Recherche/lien Spotify pour l’admin | ✅ | Lien exact ou résultat de recherche selon configuration |
| Association à une piste importée | ✅ | Réconciliation demande/import |
| Progression partielle | ✅ | Compteur d’éléments réalisés |
| Inbox d’import par utilisateur | ✅ | Dossier immuable et surveillance |
| Stabilisation avant analyse | ✅ | Évite les fichiers partiellement copiés |
| Validation WAV/FLAC | ✅ | Métadonnées, hash et règles de qualité |
| Réutilisation d’un fichier existant | ✅ | Déduplication physique |
| File de validation propriétaire | ✅ | Attente de rapprochement et actions admin |
| Vote/priorité communautaire | ⚪ | Absent |
| Discussion demandeur/admin | ⚪ | Absente |
| Notifications de progression | ⚪ | Absentes |
| Import par lot avec assistant | ⚪ | Dossier surveillé oui, UX guidée non |

**Appréciation : 8/10.** C’est l’une des fonctions les plus originales du produit. Elle peut devenir un véritable workflow familial, bien plus clair qu’une messagerie informelle.

### 4.8 Administration et exploitation

| Fonction | État | Analyse |
|---|---:|---|
| Tableau de bord propriétaire | ✅ | Accès aux principaux outils |
| Gestion des utilisateurs | ✅ | Création, rôle, statut, mot de passe, sessions et suppression |
| Gestion des demandes | ✅ | Liste, filtres, détails et actions |
| Gestion des imports | ✅ | Suivi, retry, rejet, rapprochement et attribution |
| Diagnostics recommandations | ✅ | Statut fournisseurs, maintenance et rafraîchissement |
| Diagnostic audio | ✅ | Temps réel, trace et export |
| Test de connexion serveur | ✅ | Disponible dans les paramètres |
| Santé serveur | 🟡 | Endpoint présent ; supervision externe non démontrée |
| Sauvegarde automatique | 🟠 | Intentions documentées, exécution/restauration non prouvées |
| Restauration testée | ⚪ | Aucun parcours opérationnel démontré |
| Alertes proactives | ⚪ | Absentes |
| Mise à jour/rollback automatisé | ⚪ | Absent |
| Tableau de capacité disque | ⚪ | Absent |

**Appréciation : 6/10.** Les outils métier existent, mais l’exploitation H24 doit être traitée comme un produit à part entière.

### 4.9 Hors connexion et plateformes

| Fonction | État | Analyse |
|---|---:|---|
| Route serveur de téléchargement | 🟠 | Fondation disponible |
| Manifeste de synchronisation | 🟠 | Fondation disponible |
| File locale des événements d’écoute | ✅ | Fonctionne sans réseau |
| Téléchargement utilisateur d’un titre/album/playlist | ⚪ | Aucun module mobile hors connexion complet trouvé |
| Gestion du stockage hors connexion | ⚪ | Absente |
| Reprise de téléchargement | ⚪ | Absente |
| Android | ✅ | Plateforme principale |
| iOS | ⚪ | Absent |
| Web/PWA | ⚪ | Absent |
| Desktop | ⚪ | Absent |
| TV / automobile / montre | ⚪ | Absents |

**Appréciation : 2,5/10.** C’est le plus gros trou fonctionnel face à Spotify et le chantier P0.

---

## 5. Parcours utilisateur évalués

### Parcours qui sont déjà cohérents

1. Se connecter, déverrouiller par biométrie et conserver une session renouvelée.
2. Parcourir sa bibliothèque, lancer un titre, gérer la file et continuer en arrière-plan.
3. Ajouter un favori ou créer/ordonner une playlist.
4. Consulter son activité d’écoute et reprendre une piste.
5. Rechercher une œuvre externe, écouter un aperçu disponible et envoyer une demande.
6. Pour le propriétaire : retrouver la demande, obtenir un lien Spotify, importer le fichier légalement obtenu et l’associer au bon utilisateur.

### Parcours encore cassés ou incomplets

1. Prendre le métro ou l’avion et continuer à écouter sans réseau.
2. Commencer sur le téléphone puis reprendre exactement sur un ordinateur, une TV ou une enceinte.
3. Corriger proprement les métadonnées d’un album ou fusionner deux éditions.
4. Comprendre pourquoi un titre est recommandé et modifier les règles de recommandation.
5. Trouver instantanément « mes titres jazz 2024 jamais écoutés, en 24 bits ».
6. Recevoir une notification lorsqu’une demande change d’état ou devient disponible.
7. Restaurer le service après perte du disque ou corruption de la base avec une procédure éprouvée.

---

## 6. Dette produit et incohérences observées

### 6.1 Documentation obsolète

- `MOBILE_ARCHITECTURE.md` se présente encore comme un cadrage « sans code d’interface », alors que l’application est largement développée.
- `MULTI_USER_DATA_MODEL.md` contient des introductions qui ne reflètent plus complètement `user_tracks` et les fonctions livrées.
- `ROADMAP.md` sous-estime plusieurs fonctions déjà présentes et ne représente plus la priorité réelle du mode hors connexion.
- Certains documents audio décrivent un backend non déployé ou un service non redémarré ; cet état doit être daté et remplacé par un statut exploitable.

### 6.2 Interface contradictoire

L’écran Paramètres indique actuellement :

- « DSP : Aucun », alors qu’un time-stretch Signalsmith/Sonic est intégré ;
- « accès distant non encore configuré », alors que l’URL `music.romainbegot.fr` est utilisée dans les builds et les journaux fournis ;
- une version applicative codée en dur, susceptible de diverger du paquet réellement installé.

Ces éléments réduisent la confiance. Les paramètres doivent afficher des valeurs calculées : moteur audio actif, version du build, URL effective, statut HTTPS, mode diagnostic et disponibilité serveur.

### 6.3 Fonctions techniques peu visibles

La qualité mesurée, la provenance, le BPM, la résilience de session et les diagnostics sont des différenciateurs, mais ils restent secondaires dans l’expérience. Il faut les exposer sans transformer l’application en outil d’ingénieur : un badge clair, puis le détail sur demande.

### 6.4 Dépendance aux aperçus externes

Les aperçus gratuits sont contractuellement et techniquement instables. L’application doit distinguer :

- extrait distant disponible ;
- extrait absent mais œuvre identifiable ;
- titre déjà présent dans la bibliothèque, donc lecture locale possible ;
- fournisseur indisponible ou quota dépassé.

Un « taux d’aperçu de 100 % » n’est pas un objectif garantissable sans catalogue licencié. Le bon objectif est **100 % d’états expliqués**, avec des fallbacks légaux et une surveillance par fournisseur.

---

## 7. Benchmark Spotify au 21 juillet 2026

Le benchmark se limite aux fonctionnalités confirmées par des sources officielles Spotify.

| Domaine | Spotify actuel | Situation HomeSpotify |
|---|---|---|
| Catalogue | Catalogue mondial licencié, musique, podcasts, livres audio et vidéo | Bibliothèque possédée + découverte de métadonnées ; ne peut pas égaler légalement le catalogue |
| Qualité | FLAC jusqu’à 24 bits/44,1 kHz sur Premium et appareils compatibles | WAV/FLAC originaux, profondeur/fréquence variables et qualité mesurée ; potentiel de meilleure transparence |
| Hors connexion | Jusqu’à 10 000 titres par appareil sur cinq appareils, avec reconnexion périodique | Fondations serveur seulement |
| Transitions | Crossfade, gapless et Automix | Absents |
| Multi-appareils | Spotify Connect | Absent |
| Découverte | DJ, Discover Weekly, contrôle de genres, profil de goût | Swipe et multi-fournisseurs, mais moins pilotable et moins explicable |
| Création assistée | Prompted Playlist en langage naturel, actualisation quotidienne/hebdomadaire et justification par titre | Absente |
| Connaissance musicale | SongDNA : auteurs, producteurs, collaborations, samples, reprises | Enrichissement MusicBrainz partiel |
| Social | Blend, Jam, messages et partage | Presque absent |
| Statistiques | Snapshot hebdomadaire et Wrapped | Données riches présentes, restitution absente |
| Vidéo et formats longs | Vidéos musicales, podcasts vidéo, livres audio et articles audio | Hors périmètre actuel |
| Confidentialité/contrôle | Service centralisé et profil algorithmique propriétaire | Avantage HomeSpotify : serveur privé et règles potentiellement inspectables |

### Ce qu’il faut copier

- L’excellence du parcours hors connexion.
- La continuité multi-appareils.
- Le gapless et les transitions facultatives.
- La simplicité de création de playlists.
- Le contrôle explicite du goût et les explications de recommandation.
- Les statistiques personnelles agréables à consulter.

### Ce qu’il ne faut pas copier

- La dilution de l’application musicale dans tous les formats possibles dès maintenant.
- Les mécaniques d’engagement opaques ou les recommandations impossibles à expliquer.
- La dépendance à un compte cloud central pour accéder à une collection possédée.
- L’affichage d’une qualité « lossless » sans expliquer le fichier source, le chemin de sortie et les limites Bluetooth.

Sources officielles : [qualité Lossless Spotify](https://support.spotify.com/cy/article/lossless-audio-quality/), [écoute hors connexion](https://support.spotify.com/fr/article/listen-offline/), [transitions entre titres](https://support.spotify.com/is-en/article/tracks-transitions/), [bilan des fonctions Spotify 2025](https://newsroom.spotify.com/2025-12-29/year-in-features/), [Prompted Playlist](https://newsroom.spotify.com/2026-02-23/prompted-playlist-prompts-to-try/), [Talk to Spotify](https://newsroom.spotify.com/2026-07-14/talk-to-spotify-announcement-beta/) et [SongDNA / profil de goût](https://newsroom.spotify.com/2026-04-28/spotify-q1-2026-earnings/).

---

## 8. Positionnement recommandé

### Promesse produit

> **Toute votre musique, dans sa vraie qualité, organisée selon vos règles, disponible partout et recommandée sans boîte noire.**

### Cinq piliers

1. **Posséder et durer** — les fichiers restent sous le contrôle de l’utilisateur, avec sauvegarde et export.
2. **Prouver la qualité** — distinguer format, analyse, provenance et chemin de restitution.
3. **Expliquer la découverte** — chaque recommandation doit avoir une raison et un contrôle.
4. **Servir le foyer** — comptes privés, demandes, playlists partagées et écoute collective consentie.
5. **Fonctionner partout** — hors connexion, reprise et contrôle entre appareils.

### Définition réaliste de « meilleur que Spotify »

HomeSpotify sera meilleur si, pour sa cible, il obtient :

- une lecture plus fiable de la collection possédée ;
- plus de contrôle sur les métadonnées, le son et la recommandation ;
- plus de transparence sur la qualité ;
- une expérience familiale privée sans publicité ni profilage commercial ;
- aucune disparition arbitraire d’un titre possédé ;
- une capacité d’exporter et restaurer toutes les données.

Il ne sera pas meilleur par le nombre de titres disponibles tant qu’il ne dispose pas de licences de diffusion.

---

## 9. Mise à niveau des fonctions existantes

### 9.1 Lecteur « zéro interruption »

- Rendre la file persistante après redémarrage du processus ou du téléphone.
- Restaurer titre, position, vitesse, mode aléatoire et répétition.
- Précharger uniquement les métadonnées et premiers octets du titre suivant, avec budget RAM borné.
- Implémenter le gapless natif, testé sur albums live et conceptuels.
- Ajouter un crossfade facultatif de 0 à 12 secondes, désactivé par défaut.
- Ajouter ReplayGain/R128 facultatif et non destructif ; ne jamais modifier le fichier source.
- Afficher clairement le chemin audio réel : fichier, codec, résolution, moteur DSP, sortie et limite Bluetooth éventuelle.
- Ajouter récupération réseau graduelle, messages compréhensibles et reprise au bon timestamp.
- Ajouter minuteur de sommeil, boucle A–B, signets et raccourcis casque configurables.

### 9.2 Bibliothèque « collection de référence »

- Passer à SQLite FTS5 côté serveur pour titre, artiste, album, genre, année, ISRC et crédits.
- Ajouter filtres combinables, vues enregistrées et tri multi-critères.
- Créer des playlists intelligentes dynamiques.
- Ajouter tags personnels, notes, notation et statut « à écouter ».
- Construire un éditeur de métadonnées avec prévisualisation, historique et annulation.
- Détecter doublons acoustiques, éditions, remasters, pistes manquantes et albums incomplets.
- Ajouter crédits complets : auteur, compositeur, producteur, interprètes et labels lorsqu’ils sont légalement disponibles.
- Ajouter paroles locales `.lrc`/tags et fournisseur licencié optionnel.
- Ajouter intégrité périodique : fichier manquant, hash modifié, cover cassée et durée incohérente.

### 9.3 Découverte « utilisateur aux commandes »

- Afficher « recommandé parce que… » sur chaque carte.
- Permettre d’ajuster familiarité, nouveauté, énergie, décennie, genre et répétition.
- Demander une raison facultative au dislike : déjà connu, mauvais artiste, humeur, répétitif ou jamais ce genre.
- Créer radio de titre, artiste, album, playlist et humeur.
- Exploiter d’abord la bibliothèque locale et l’historique qualifié, puis compléter avec les fournisseurs.
- Calculer localement des descripteurs audio sobres en tâche de fond : tempo, énergie, dynamique et similarité, sans envoyer le son à un tiers.
- Mettre en évidence la santé des fournisseurs et l’origine de chaque donnée.
- Dédupliquer par ISRC puis identité normalisée, et conserver la meilleure variante : aperçu valide, meilleure cover, métadonnées complètes et popularité pertinente.

### 9.4 Demandes « workflow familial »

- Ajouter priorité, votes et nombre de personnes intéressées.
- Ajouter messages courts entre demandeur et propriétaire.
- Ajouter notifications : reçue, en cours, précision requise, disponible ou rejetée.
- Fusionner automatiquement les demandes identiques.
- Ajouter traitement par lot, assignation admin, date cible et notes privées.
- Afficher la correspondance proposée avant association et un score de confiance.
- Générer liens de recherche vers plusieurs services sans aspirer ni contourner leurs protections.
- Produire statistiques : délai médian, demandes en attente, taux de réussite et fournisseurs problématiques.

### 9.5 Administration « exploitation sereine »

- Unifier santé API, base, disque, fournisseurs, files de jobs et versions dans un seul cockpit.
- Ajouter sauvegardes chiffrées planifiées et test de restauration guidé.
- Ajouter alertes sur disque faible, fichiers manquants, fournisseur en panne, erreurs de lecture et sauvegarde échouée.
- Ajouter mode maintenance, migration contrôlée et rollback applicatif.
- Ajouter quotas par utilisateur et visualisation du stockage logique/physique.
- Corriger automatiquement les textes de paramètres depuis la configuration réelle.

---

## 10. Backlog massif de nouvelles fonctionnalités

### A. Lecture et audio

1. Gapless vérifié au sample près lorsque les formats le permettent.
2. Crossfade réglable et règles par playlist.
3. ReplayGain/R128 facultatif par album ou piste.
4. Égaliseur paramétrique par appareil.
5. Profils casque/enceinte.
6. Préampli et protection anti-clipping.
7. File persistante et historique des files.
8. Sauvegarde de file comme playlist.
9. File collaborative pour une session de groupe.
10. Boucle A–B.
11. Signets horodatés et notes.
12. Minuteur de sommeil avec fin de titre/album.
13. Réveil musical local.
14. Fondu pause/reprise facultatif.
15. Commandes casque personnalisables.
16. Onde audio et chapitres pour longs fichiers.
17. Choix de sortie et diagnostic du chemin audio.
18. Mode économie de données avec transcodage **optionnel à la volée**, sans remplacer l’original.
19. Préchargement adaptatif selon réseau.
20. Reprise automatique après changement Wi-Fi/4G.

### B. Bibliothèque et métadonnées

21. Recherche FTS avec fautes de frappe et accents.
22. Filtres avancés enregistrables.
23. Playlists intelligentes dynamiques.
24. Tags, notes, étoiles et couleurs personnels.
25. Vue par dossiers physiques.
26. Vue chronologique d’ajout.
27. Centre des doublons et éditions.
28. Détection d’albums incomplets.
29. Éditeur unitaire et par lot.
30. Historique/annulation des métadonnées.
31. Crédits détaillés et graphe des collaborations.
32. Paroles locales et synchronisées.
33. Booklets PDF locaux liés à l’album.
34. Covers multiples et choix manuel.
35. Collections/étagères en plus des playlists.
36. Épingles et raccourcis personnels.
37. Import/export M3U, M3U8 et JSON.
38. Export complet de bibliothèque et préférences.
39. Vérification périodique d’intégrité.
40. Journal des changements de fichiers.

### C. Découverte et intelligence locale

41. Radio de titre/artiste/album.
42. Profil de goût visible et éditable.
43. Curseurs nouveauté/familiarité/énergie.
44. Explication de chaque recommandation.
45. Raisons de rejet structurées.
46. Limite de répétition configurable.
47. Mode « trésors oubliés » de la bibliothèque.
48. Mode « jamais écouté ».
49. Mode « même époque, autre genre ».
50. Nouveautés des artistes suivis.
51. Calendrier de sorties et demandes en un geste.
52. Similarité audio calculée localement.
53. Playlist en langage naturel sur les données locales.
54. Actualisation quotidienne/hebdomadaire des playlists intelligentes.
55. Résumé explicable de l’évolution des goûts.
56. Comparaison de profils avec consentement.
57. Suggestions basées sur le contexte choisi, jamais déduit silencieusement.
58. Mode découverte sans titres déjà entendus.
59. Exploration par crédits, samples et reprises lorsque les données sont licenciées.
60. Tableau qualité des fournisseurs et couverture des aperçus.

### D. Hors connexion et mobilité

61. Téléchargement d’un titre, album ou playlist.
62. Téléchargement automatique des favoris récents.
63. « Sauvegarde hors connexion » des titres récemment écoutés.
64. File de téléchargement reprenable.
65. Wi-Fi uniquement / données mobiles autorisées.
66. Limite de stockage et nettoyage LRU explicable.
67. Choix stockage interne/carte SD.
68. Vérification de hash après téléchargement.
69. Mise à jour différentielle par manifeste.
70. Filtre « disponible hors connexion ».
71. Mode hors connexion forcé.
72. Synchronisation différée de l’historique et des modifications.

### E. Social privé et foyer

73. Playlists collaboratives avec rôles.
74. Session d’écoute synchronisée type Jam.
75. Vote sur la prochaine piste.
76. Demandes musicales votées.
77. Activité d’amis strictement opt-in.
78. Réactions et commentaires sur playlists.
79. Partage interne d’un titre/album.
80. Profil enfant géré et filtres explicites.
81. Mode invité temporaire et révocable.
82. Blend familial généré de façon explicable.
83. Confidentialité par section : historique, activité et playlists.
84. Modération et journal des actions partagées.

### F. Multi-appareils et plateformes

85. HomeSpotify Connect : voir et contrôler les lecteurs actifs.
86. Transfert de lecture sans perdre la position.
87. Web/PWA responsive.
88. Application desktop Windows/macOS/Linux.
89. Client iOS.
90. Android Auto.
91. CarPlay après client iOS.
92. Chromecast/Google Cast.
93. AirPlay là où la plateforme l’autorise.
94. UPnP/DLNA facultatif sur le réseau local.
95. Application TV simplifiée.
96. Compagnon montre pour commandes essentielles.

### G. Statistiques et bien-être

97. Bilan hebdomadaire et mensuel.
98. « Wrapped » privé générable à tout moment.
99. Temps par artiste, album, genre et période.
100. Taux de complétion et titres souvent ignorés.
101. Carte de redécouverte des anciennes périodes.
102. Objectifs facultatifs sans mécanique addictive.
103. Export CSV/JSON des statistiques.
104. Session privée exclue des recommandations et statistiques.

### H. Administration, fiabilité et confidentialité

105. Sauvegarde chiffrée automatique base + covers + configuration.
106. Assistant de restauration et exercice périodique.
107. Tableau santé disque, base, jobs et fournisseurs.
108. Alertes push/email facultatives pour le propriétaire.
109. File de tâches persistante avec retry borné.
110. Quotas et politiques de rétention.
111. Rapport d’intégrité de la bibliothèque.
112. Déploiement avec rollback.
113. Feature flags serveur.
114. Export et suppression des données personnelles.
115. 2FA propriétaire.
116. Journal d’audit consultable et exportable.
117. Masquage systématique des secrets et jetons dans les diagnostics.
118. Page statut privée.

### I. Extensions à considérer plus tard

119. Podcasts RSS privés et publics, avec téléchargement.
120. Livres audio possédés avec chapitres, signets et vitesse étendue.
121. Vidéos musicales locales possédées et synchronisation audio/vidéo.
122. Concerts proches via fournisseur autorisé et consentement de localisation.
123. Scrobbling ListenBrainz/Last.fm facultatif.
124. API personnelle documentée et clés révocables.

Ces extensions ne doivent commencer qu’après la maîtrise de la musique, du hors connexion et du multi-appareils.

---

## 11. Priorisation recommandée

### P0 — Indispensable pour remplacer Spotify au quotidien

| Initiative | Valeur | Effort | Risque | Critère de fin |
|---|---:|---:|---:|---|
| Hors connexion Android | Très forte | Fort | Moyen | Titre/album/playlist téléchargeables, reprise, hash, limite de stockage et lecture sans réseau |
| Lecture fiable et file persistante | Très forte | Moyen | Moyen | Redémarrage et coupure réseau sans perdre la file ni la position |
| Gapless + préchargement | Très forte | Moyen | Moyen | Albums tests sans trou audible, mémoire bornée |
| Sauvegarde/restauration | Très forte | Moyen | Faible | Restauration chronométrée sur machine propre |
| Paramètres et documentation alignés | Forte | Faible | Faible | Plus aucune information codée en dur contradictoire |
| Recherche locale FTS | Forte | Moyen | Faible | Résultat pertinent sous 150 ms sur bibliothèque cible |
| Monitoring H24 | Forte | Moyen | Faible | Alertes disque/API/jobs/sauvegarde |

### P1 — Différenciation immédiate

- Playlists intelligentes et filtres enregistrés.
- Métadonnées éditables avec historique.
- Centre qualité/doublons/intégrité.
- Recommandations expliquées et profil de goût réglable.
- Statistiques personnelles continues.
- Notifications des demandes.
- Paroles locales `.lrc` et crédits enrichis.
- ReplayGain facultatif, minuteur et boucle A–B.

### P2 — Avantage réseau privé

- HomeSpotify Connect.
- Web/PWA.
- Playlists collaboratives.
- Sessions d’écoute synchronisées et votes.
- Profils enfant/guest et confidentialité fine.
- Blend familial explicable.

### P3 — Écosystème

- Desktop, iOS, automobile, Cast et TV.
- Playlist en langage naturel locale.
- Similarité audio locale.
- Podcasts RSS et livres audio possédés.
- API personnelle stable.

---

## 12. Feuille de route réaliste

Hypothèse : un développeur principal assisté, infrastructure personnelle, priorité à la stabilité. Une équipe de deux à trois personnes peut paralléliser, mais ne doit pas réduire les critères de qualité.

### Phase 0 — Stabilisation et vérité produit, 2 à 4 semaines

- Corriger les textes et versions dynamiques dans Paramètres.
- Mettre à jour les documents de fondation et la roadmap.
- Établir un état de déploiement reproductible.
- Ajouter tableau de santé minimal et sauvegarde automatisée.
- Exécuter une matrice Android réelle : marques, verrouillage, économie de batterie, Wi-Fi/4G et session de quatre heures.
- Définir les SLO et un jeu de données de référence pour recherche/déduplication.

**Sortie :** on sait exactement quelle version tourne, on peut la surveiller et la restaurer.

### Phase 1 — Offline et lecture parfaite, 6 à 10 semaines

- Cache audio mobile chiffré ou protégé par sandbox applicative.
- Téléchargement titre/album/playlist avec choix Opus 128, Opus 256 ou original,
  taille affichée, reprise Range et vérification SHA-256.
- Manifeste différentiel et synchronisation de métadonnées.
- File persistante, reprise après redémarrage et récupération réseau.
- Gapless et préchargement borné.
- Minuteur, ReplayGain facultatif et diagnostic du chemin audio.

**Sortie :** HomeSpotify remplace le lecteur quotidien même sans réseau.

### Phase 2 — Super-bibliothèque, 6 à 8 semaines

- FTS5, filtres composables et vues enregistrées.
- Playlists intelligentes.
- Éditeur de métadonnées et historique.
- Centre doublons/éditions/intégrité.
- Paroles locales, crédits et covers multiples.
- Import/export de playlists et données.

**Sortie :** la collection est plus contrôlable et durable que dans Spotify.

### Phase 3 — Découverte explicable, 6 à 10 semaines

- Profil de goût visible.
- Raisons et contrôles de recommandations.
- Radios et modes de redécouverte.
- Descripteurs audio locaux en jobs sobres.
- Playlist en langage naturel limitée à la bibliothèque possédée.
- Dashboard qualité des fournisseurs et fallback explicite.

**Sortie :** l’utilisateur comprend, corrige et pilote l’algorithme.

### Phase 4 — HomeSpotify Connect et social privé, 8 à 12 semaines

- Registre de lecteurs actifs et commandes distantes.
- Handoff de lecture.
- PWA de contrôle et lecture.
- Playlists collaboratives, sessions de groupe et votes.
- Confidentialité fine et profils gérés.

**Sortie :** continuité multi-appareils et expérience de foyer supérieure.

### Phase 5 — Plateformes et contenus possédés, 3 à 6 mois

- Desktop puis iOS.
- Android Auto, Cast, CarPlay et TV selon priorité réelle.
- Podcasts RSS et livres audio possédés si les usages le justifient.
- API personnelle et intégrations domotiques.

**Horizon réaliste :** 12 à 18 mois pour l’ensemble prioritaire avec une seule personne, hors catalogue/licences et hors maintenance courante.

---

## 13. Indicateurs de succès

### Fiabilité

- Sessions Android de 4 heures sans arrêt involontaire : **≥ 99,5 %**.
- Démarrage de lecture p95 : **< 1 s en LAN**, **< 2,5 s à distance**.
- Reprise après changement réseau p95 : **< 5 s**.
- Crash-free users : **≥ 99,8 %**.
- Échec de synchronisation d’historique après retry : **< 0,1 %**.

### Recherche et découverte

- Bon résultat dans le top 3 sur le jeu de référence : **≥ 95 %**.
- Doublons visibles après fusion : **< 1 %**.
- Chaque résultat sans aperçu possède un état et une raison explicites : **100 %**.
- Recommandations avec justification visible : **100 %**.
- Taux de « mauvais artiste » sur les requêtes exactes : **< 2 %**.

### Hors connexion

- Téléchargements vérifiés par hash : **100 %**.
- Reprise après interruption : **≥ 99 %**.
- Lecture de tout contenu marqué téléchargé sans réseau : **100 %**.
- Aucune suppression automatique inexpliquée : **100 %**.

### Exploitation

- Sauvegarde réussie quotidienne : **≥ 99,5 %**.
- RPO cible : **24 h maximum**.
- RTO cible : **2 h maximum**.
- Exercice de restauration : **trimestriel**.
- Aucune donnée secrète dans logs/exports : **0 occurrence**.

### Produit

- Temps médian pour lancer un titre connu : **< 10 s depuis l’accueil**.
- Temps médian de traitement d’une demande : suivi automatiquement.
- Utilisateurs actifs qui emploient une fonction différenciante chaque semaine : **≥ 60 %**.
- Satisfaction « je préfère HomeSpotify pour ma bibliothèque » : **≥ 8/10**.

---

## 14. Recommandations techniques structurantes

1. **Conserver le monolithe modulaire.** Le périmètre familial ne justifie pas des microservices ; isoler les domaines dans le code suffit.
2. **Ajouter une file de jobs persistante SQLite.** Enrichissement, BPM, waveform, ReplayGain, intégrité et sauvegarde doivent être reprenables et bornés.
3. **Adopter FTS5.** La recherche de la bibliothèque doit être locale, rapide et indépendante des fournisseurs.
4. **Versionner les contrats client/serveur.** L’offline et Connect nécessitent des manifests et événements rétrocompatibles.
5. **Séparer état de lecture et commandes.** Un modèle `playback_devices`/`playback_sessions` permettra contrôle distant et handoff sans coupler les lecteurs.
6. **Mesurer avant d’optimiser.** Conserver les diagnostics actuels, mais ajouter des agrégats anonymisés et bornés plutôt que multiplier les logs verbeux.
7. **Dégrader proprement les fournisseurs.** Circuit breaker, timeout, quota, cache stale-while-revalidate et origine visible.
8. **Ne jamais altérer l’original.** Analyses, normalisation et transcodage mobile restent dérivés et supprimables.
9. **Automatiser les migrations et le rollback.** Sauvegarde cohérente avant migration, vérification après démarrage et retour documenté.
10. **Tester sur vraies conditions.** Réseau instable, gros FLAC, batterie faible, écran verrouillé, Bluetooth, interruptions téléphone et reprise du processus.

---

## 15. Sécurité, légalité et vie privée

- Ne jamais télécharger ni contourner la protection d’un service de streaming tiers.
- Les APIs Spotify et autres servent à identifier, lier ou enrichir ; elles ne donnent pas un droit de redistribuer l’audio.
- Les paroles, vidéos, photos d’artistes et certaines covers nécessitent des droits ou un fournisseur dont les conditions autorisent l’usage prévu.
- Les fichiers ajoutés doivent être possédés ou utilisés avec autorisation par l’administrateur.
- Les recommandations locales doivent rester facultatives, explicables et supprimables.
- La localisation, l’activité sociale et le partage d’historique doivent être opt-in.
- Les exports de diagnostic doivent supprimer jetons, mots de passe, chemins privés inutiles et données d’autres utilisateurs.
- Le propriétaire distant devrait disposer d’un second facteur, sans dégrader la session quotidienne des utilisateurs.

---

## 16. Décisions recommandées maintenant

### À faire immédiatement

1. Déclarer officiellement le mode hors connexion comme prochain grand lot.
2. Geler les gros ajouts de catalogue externe jusqu’à fiabilisation des résultats, previews et caches existants.
3. Corriger les informations obsolètes des paramètres et documents.
4. Écrire un plan de sauvegarde/restauration exécutable.
5. Construire un corpus de 100 à 300 recherches réelles pour mesurer pertinence et déduplication.
6. Définir une matrice de tests Android longue durée.

### À ne pas faire maintenant

- Refaire toute l’architecture en microservices.
- Ajouter podcasts, livres, vidéos et réseau social avant l’offline et Connect.
- Promettre tous les aperçus sonores via des APIs gratuites.
- Supprimer l’expiration de sécurité des jetons ; rendre le renouvellement invisible et robuste.
- Dépenser du CPU au démarrage pour analyser toute la bibliothèque.
- Appeler « lossless » un fichier uniquement parce qu’il porte l’extension FLAC.

---

## 17. À vérifier

Les points suivants ne peuvent pas être affirmés uniquement depuis le code :

- version exacte actuellement déployée derrière `music.romainbegot.fr` ;
- redémarrage effectif du service après les derniers correctifs de découverte ;
- notification média et survie en arrière-plan sur chaque téléphone/ROM Android cible ;
- disponibilité et validité actuelles des clés Spotify/Apple/Last.fm dans le service déployé ;
- exécution réelle des sauvegardes et réussite d’une restauration complète ;
- performance avec la taille finale attendue de bibliothèque ;
- statut légal précis des fichiers, covers, paroles et aperçus utilisés ;
- résultats d’une exécution complète de toutes les suites de tests dans l’environnement de release ;
- compatibilité gapless actuelle implicite du moteur : aucune fonction produit ou validation dédiée n’a été trouvée.

---

## 18. Conclusion

HomeSpotify possède déjà le plus difficile : une architecture privée cohérente, une lecture audio instrumentée, une vraie isolation multi-utilisateur et un workflow original de demandes/imports. Son prochain saut de qualité ne viendra pas de dix nouvelles APIs de recherche, mais de la transformation de ce socle en expérience quotidienne infaillible.

La stratégie gagnante est claire : **offline d’abord, lecture parfaite ensuite, super-bibliothèque, découverte explicable, puis multi-appareils et social privé**. En suivant cet ordre, HomeSpotify ne cherchera pas à devenir une copie plus petite de Spotify. Il deviendra un produit que Spotify ne peut pas facilement être : un lecteur familial privé, durable, transparent et entièrement gouverné par ses utilisateurs.
