# DISCOVERY_CATALOG.md — Recherche catalogue multi-fournisseurs

Dernière mise à jour : 2026-07-20.

Système de découverte de métadonnées musicales et de création de demandes.
Périmètre STRICT : DISCOVERY (métadonnées) → PREVIEW (extrait officiel) →
REQUEST (demande HomeSpotify). L'ACQUISITION est hors périmètre : **aucun
téléchargement musical n'existe dans ce module**, et aucun résultat de
catalogue ne mène directement à un fichier.

## Architecture

```
Flutter (features/catalog_search)
  └── /api/discovery/* (auth Bearer obligatoire)
        └── DiscoveryCatalogService (orchestration)
              ├── providers parallèles + timeout par provider
              ├── DiscoveryCache (table discovery_cache, TTL par opération)
              ├── merge.ts (déduplication déterministe + ranking)
              └── santé par provider (latence, erreur catégorisée)
```

Fichiers backend : `services/api/src/discovery/catalog/`
(`types.ts`, `itunes-discovery-provider.ts`, `spotify-catalog-provider.ts`, `musicbrainz-catalog-provider.ts`,
`apple-music-discovery-provider.ts`, `merge.ts`, `discovery-cache.ts`,
`discovery-catalog-service.ts`) + `routes/discovery-catalog.ts`.
Le registre des providers est construit dans `app.ts`
(`buildDiscoveryProviders`), injectable dans les tests.

## Fournisseurs

| Provider | État | Condition d'activation | Capacités |
|---|---|---|---|
| `deezer` | **Actif, enrichissement principal gratuit** | aucune clé ; désactivable par `DEEZER_DISCOVERY_ENABLED=false` | search track/artist/album, ISRC, discographie, tracklist, photos artiste, pochettes HD, preview officielle |
| `itunes` | **Actif, source gratuite de secours** | aucune clé ni compte | search track/artist/album, discographie, tracklist, liens, pochettes, preview officielle |
| `spotify` | Prêt, **désactivé sans credentials** | `SPOTIFY_DISCOVERY_ENABLED=true` + client id/secret | search track/artist/album/playlist, ISRC, discographie, tracklist, playlist, liens, marché |
| `musicbrainz` | Prêt, actif si User-Agent | `MUSICBRAINZ_USER_AGENT` renseigné | search track/artist/album, ISRC, discographie, tracklist, relations URL |
| `apple_music` | Prêt, actif si secrets MusicKit | `APPLE_MUSIC_*` + flag discovery | search, ISRC, discographie, tracklist, liens, **preview officielle** |
| `tidal` | **Désactivé** (`credentials_missing`) | app TIDAL enregistrée + credentials + flag | non implémenté ; les previews TIDAL exigeraient le SDK officiel |
| Bandcamp | Jamais d'appel direct | — | lien uniquement via relation URL MusicBrainz → `LINK_FOUND` |
| Qobuz | Jamais d'appel direct | — | idem Bandcamp ; sinon `UNKNOWN` |

Vérifications Phase 0 (documentation officielle, juillet 2026) :

- **Deezer** : le point d'accès public `api.deezer.com`, sans clé, est utilisé
  en lecture seule pour la découverte, les images et les extraits officiels.
  Aucune piste complète, aucun flux d'abonnement et aucun DRM n'est appelé.
  Vérification réelle du 2026-07-20 : `PARAFFINE — Ajna` fournit titre, album
  `L’HERMITE`, pochette, photo artiste et preview ; les 10 premiers artistes
  `Ajna` et albums `Antidote` testés possèdent tous une image.
- **iTunes Search** : API publique sans clé, storefront par pays, utilisée
  comme deuxième source pour les résultats illustrés. Les réponses sont
  normalisées puis mises en cache dans SQLite ; aucun fichier audio n'est acquis.
- **Spotify** : search/artists/albums/tracks restent ouverts aux nouvelles
  applications ; recommendations, related-artists, audio-features et
  playlists éditoriales/algorithmiques sont restreints (blog officiel du
  2024-11-27). `preview_url` est **déprécié** : jamais stocké, jamais requis,
  jamais utilisé comme source de preview. Flux Client Credentials, secret
  côté serveur uniquement, single-flight sur le refresh de token,
  `Retry-After` respecté sur 429.
  Depuis mars 2026, le Development Mode exige un compte Spotify Premium et
  borne `GET /search` à 10 résultats. Le panel OWNER utilise l'API officielle
  seulement quand les credentials sont configurés ; sinon il génère une URL
  `open.spotify.com/search/…` préremplie, sans scraping ni endpoint privé.
- **MusicBrainz** : queue globale 1 req/s (client existant réutilisé),
  User-Agent identifiable obligatoire, retry borné sur 503.
- **Apple Music** : réutilise le provider MusicKit existant (JWT ES256) —
  aucun second client de signature. L'attribut documenté `previews` fournit
  l'extrait officiel.
- **TIDAL** : plateforme développeur officielle existante (openapi.tidal.com,
  OAuth client credentials pour le catalogue) ; nécessite un enregistrement
  d'application → désactivé par défaut, interface conservée.

## Modèle unifié

`CatalogSearchResult` (canonicalKey, entityType, title, artists, album,
durationMs, releaseDate, explicit, images, isrc, upc, mbid,
providerReferences, externalLinks, preview, matchConfidence) + fiches
`CatalogArtist`, `CatalogAlbum` (tracklist ordonnée disque/piste),
`CatalogPlaylist`. Rien n'oblige une entité à posséder ISRC, image ou date.

## Statuts de disponibilité

Jamais de booléen : `CONFIRMED`, `LINK_FOUND`, `SEARCH_LINK_ONLY`,
`UNAVAILABLE_CONFIRMED`, `UNKNOWN`, `PROVIDER_DISABLED`, `PROVIDER_ERROR`.
Un provider coupé donne `PROVIDER_DISABLED` ; l'absence de preuve donne
`UNKNOWN` et l'UI n'affiche JAMAIS « indisponible » pour `UNKNOWN`.

## Déduplication et ranking

Ordre déterministe : 1. ISRC exact ; 2. MBID exact ; 3. UPC ;
4. identité visible normalisée (titre + artiste principal) + même empreinte de
version. Une divergence de durée ou un `explicit=false` isolé ne crée jamais
une seconde carte : la carte fusionnée conserve la preview, les images et les
références les plus riches. Jamais de fusion
original/remix, studio/live, explicite/censuré (regex de version partagée
avec le pipeline média). Les artistes de nom normalisé identique sont regroupés
pour éliminer les doublons MusicBrainz et agréger la photo ; les albums ne sont
regroupés que sur titre + artiste. Chaque fusion conserve toutes les références
et les images HTTPS distinctes. Ranking reproductible par signaux structurels
(exactitude titre/artiste, ISRC, multi-catalogue, image, preview, liens,
priorité provider) — jamais une
popularité propriétaire seule. Niveaux : EXACT / STRONG / POSSIBLE /
AMBIGUOUS (les ambigus restent séparés).
Pour une recherche `type=artist`, dès qu'un nom exact existe après fusion, les
variantes fuzzy sont retirées. Deezer corrobore en plus ses homonymes exacts
avec les titres retournés par la même requête : `Ajna` ID `1197134`, auteur de
`AJCENSION` et `PARAFFINE`, passe avant les homonymes sans preuve de titre.

## Cache

Table `discovery_cache` (migration 0017, additive et idempotente) :
unicité (provider, operation, query_hash, market), JSON **normalisé**
uniquement (jamais la réponse brute, jamais de secret/token, jamais d'URL de
preview persistée seule, jamais d'audio). TTL : recherche 4 h, ISRC 7 j,
fiches 3 j, playlist 30 min, erreur temporaire 45 s (negative cache).
Une page contenant une preview est limitée à 5 min ; si le fournisseur expose
une expiration signée (paramètre Deezer `hdnea`), le TTL s'arrête 60 s avant
cette expiration. La version V3 du schéma de cache invalide les anciennes pages
qui contenaient des URLs Deezer déjà périmées ou des cartes dupliquées par une
durée/statut explicite contradictoire.
Purge : entrées expirées + bornage `DISCOVERY_CACHE_MAX_ENTRIES`.

## Routes

- `GET /api/discovery/search?q&type&limit&cursor&market&providers`
- `GET /api/discovery/providers` (capacités publiques, jamais de secret)
- `GET /api/discovery/artists/:provider/:id` (+ `/albums`)
- `GET /api/discovery/albums/:provider/:id`
- `GET /api/discovery/playlists/:provider/:id`
- `POST /api/discovery/resolve` (isrc | title+artist → entité fusionnée)
- `GET /api/admin/discovery/health` (OWNER : latences, erreurs catégorisées, cache)
- `GET /api/admin/music-requests/:id/spotify-link` (OWNER : lien Spotify exact
  via Web API officielle, ou recherche Spotify préremplie en secours)

Toutes exigent l'authentification. Rate limit : 40 req/min/utilisateur.
Un provider en panne n'annule jamais les autres (statuts `OK/DEGRADED/
DISABLED` retournés avec la page).

## Sécurité

- Secrets fournisseurs côté serveur uniquement (ni Flutter, ni Git, ni logs).
- IDs externes validés (`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`), marché `[A-Z]{2}`.
- Aucune URL arbitraire de l'utilisateur n'est appelée ; hôtes fournisseurs
  fixés par la config, HTTPS obligatoire, liens externes retournés au client
  filtrés https + plateformes connues (relations MusicBrainz).
- Timeout connexion/total, taille maximale de réponse (2 Mo), validation
  Content-Type/JSON, retry uniquement sur erreurs temporaires, erreurs
  externes catégorisées (jamais le corps brut).

## Previews

- Descripteur éphémère (`PreviewDescriptor`) : streaming uniquement, aucun
  téléchargement, aucun cache binaire, aucune mise hors ligne.
- Flutter : `CatalogPreviewController` séparé du `HomeSpotifyAudioHandler` —
  un seul player de preview, pas de notification, pas de
  `listening_session`, pas d'historique. Quand la lecture principale joue,
  elle est mise en pause (queue et position conservées) et un bouton
  « Reprendre ma musique » apparaît ; **jamais de reprise automatique**.
- TIDAL (`requiresOfficialSdk`) : jamais lu par just_audio ; seul un lien
  « Ouvrir dans TIDAL » serait proposé.

## Demandes

Le système **existant** `music_requests` est réutilisé tel quel
(`POST /api/music-requests`) : TRACK/ALBUM/PLAYLIST, snapshots ordonnés
(`music_request_items` avec position, ISRC, durée), doublons, isolation par
compte, permissions OWNER, statuts COMPLETED/PARTIALLY_COMPLETED calculés
UNIQUEMENT par la réconciliation après attribution réelle. Aucune nouvelle
table de demandes, aucune colonne ajoutée (les champs existants suffisent :
`external_url`, `cover_url`, items ISRC/durée). Ajout unique côté service :
un ALBUM/PLAYLIST dont TOUS les titres sont déjà possédés est refusé
(`already_owned`) ; un snapshot partiellement possédé reste accepté.
Le userId vient exclusivement du Bearer ; tout `userId` de payload est ignoré.

## Flutter

`lib/src/features/catalog_search/` : `domain/catalog_models.dart`,
`data/catalog_search_api.dart`, `application/catalog_search_controller.dart`
(debounce 450 ms, annulation logique des réponses périmées, pagination),
`presentation/` (écran Rechercher avec onglets, fiches artiste/album,
`catalog_preview_controller.dart`, `request_from_catalog_sheet.dart`).
Routes : `/catalog-search`, `/catalog-search/artists/:provider/:id`,
`/catalog-search/albums/:provider/:id`. Entrée : icône loupe de l'écran
Découvrir et bouton catalogue de la Bibliothèque. Les anciens écrans
`/node-fetch` et `/remote-search` ont été supprimés. Dépendance ajoutée :
`url_launcher` (liens externes https).

## Procédures

**Activer Spotify** : créer une app sur developer.spotify.com, renseigner
`SPOTIFY_DISCOVERY_ENABLED=true`, `SPOTIFY_CLIENT_ID`,
`SPOTIFY_CLIENT_SECRET` dans `.env`, redémarrer. Vérifier
`GET /api/admin/discovery/health`.

**Activer Apple Music** : secrets MusicKit (`APPLE_MUSIC_TEAM_ID/KEY_ID/
PRIVATE_KEY_PATH`) ; `APPLE_MUSIC_DISCOVERY_ENABLED=true` (défaut).

**Désactiver un provider** : retirer ses credentials ou passer son flag à
false — il apparaît `DISABLED` avec une raison stable, les recherches
continuent avec les autres.

**Diagnostic** : `GET /api/admin/discovery/health` (statut, latence,
dernière erreur catégorisée, hit ratio du cache) ; logs structurés
`DISCOVERY_*` (jamais de token, jamais de réponse brute).

## Tests

- Backend : contrats iTunes/Deezer (mapping recherche, image, preview, album,
  erreurs), fusion enrichie (photo artiste, déduplication des homonymes,
  priorité aux résultats écoutables) + `discovery-catalog.test.ts` (25 tests :
  fusion, versions, cache, Spotify mocké 401/429/503, secrets) +
  `src/routes/discovery-catalog.test.ts` (16 tests : auth, validation,
  résultats partiels, rate limit, santé OWNER, demandes ALBUM/userId).
- Flutter : `catalog_search_controller_test.dart`,
  `catalog_preview_controller_test.dart`, `catalog_search_screen_test.dart`
  (27 tests : debounce, réponses périmées, UNKNOWN, pause/reprise du
  lecteur principal, TIDAL jamais lu, badges, modal sans userId).

## Limites connues / À vérifier

- Spotify et Apple Music non testés contre les API réelles (aucun credential
  configuré) : à valider au premier branchement via le health OWNER.
- L'API publique Deezer a été validée en réel sans clé le 2026-07-20, mais sa
  disponibilité future n'est pas garantie contractuellement : iTunes et
  MusicBrainz restent des secours indépendants et le flag permet de la couper.
- Les playlists ne sont servies que par Spotify (si activé) ; MusicBrainz et
  Apple n'exposent pas de playlists consommateur ici.
- La pagination fusionnée reprend le curseur du premier provider paginable ;
  les providers sans curseur ne contribuent qu'à la première page.
- MusicBrainz sans User-Agent → provider désactivé : renseigner
  `MUSICBRAINZ_USER_AGENT` en production.
