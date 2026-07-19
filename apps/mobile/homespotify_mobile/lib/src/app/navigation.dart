import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../core/logging/app_logger.dart';
import '../features/library/domain/local_playlist.dart';
import '../features/library/presentation/library_albums.dart';
import '../features/library/presentation/library_artists.dart';

/// Pousse [path] seulement s'il n'est pas déjà au sommet de la pile.
///
/// `GoRouter.state` reflète la dernière route activée par `go`/`push` : cela
/// neutralise les double-taps et les push différés par un `await` (cf. L-016).
void _pushUnique(BuildContext context, String path) {
  final router = GoRouter.of(context);
  final current = router.state.uri.path;
  if (current == path) {
    logNavigation('push ignoré (déjà au sommet): $path');
    return;
  }
  logNavigation('push: $current → $path');
  router.push(path);
}

/// Ouvre le lecteur complet sans jamais empiler deux `/player`.
///
/// Seule action autorisée à ouvrir le lecteur : tap sur le mini-player ou
/// bouton lecteur explicite. Jamais automatiquement après un lancement de
/// lecture.
void openPlayer(BuildContext context) => _pushUnique(context, '/player');

/// Ouvre la liste des albums (anti-doublon).
void openAlbums(BuildContext context) => _pushUnique(context, '/albums');

/// Ouvre la liste des artistes (anti-doublon).
void openArtists(BuildContext context) => _pushUnique(context, '/artists');

/// Ouvre les pistes favorites locales (anti-doublon).
void openFavorites(BuildContext context) => _pushUnique(context, '/favorites');

/// Ouvre les playlists du compte courant (anti-doublon).
void openPlaylists(BuildContext context) => _pushUnique(context, '/playlists');

/// Ouvre les paramètres de l'application (anti-doublon).
void openSettings(BuildContext context) => _pushUnique(context, '/settings');

/// Ouvre la découverte par swipe (anti-doublon).
void openDiscover(BuildContext context) {
  final router = GoRouter.of(context);
  if (router.state.uri.path == '/discover') return;
  logNavigation('destination principale: /discover');
  router.go('/discover');
}

/// Ouvre la liste des demandes de musique du compte courant (anti-doublon).
void openMusicRequests(BuildContext context) =>
    _pushUnique(context, '/requests');

/// Ouvre la recherche catalogue multi-fournisseurs (anti-doublon).
void openCatalogSearch(BuildContext context) =>
    _pushUnique(context, '/catalog-search');

/// Ouvre la file unifiée sans interrompre la lecture en cours.
void openQueue(BuildContext context) => _pushUnique(context, '/queue');

String playlistDetailPath(String playlistId) {
  if (!isSafePlaylistId(playlistId)) return '/playlists/invalid-route';
  return '/playlists/$playlistId';
}

void openPlaylistDetail(BuildContext context, String playlistId) {
  if (!isSafePlaylistId(playlistId)) {
    logError('identifiant playlist refusé: "$playlistId"');
    return;
  }
  logNavigation('détail playlist demandé: id=$playlistId');
  _pushUnique(context, playlistDetailPath(playlistId));
}

/// Chemin du détail d'un album. La clé passe en base64Url ([albumRouteId]) :
/// aucun caractère réservé dans l'URI, donc aucun percent-encoding fragile.
String albumDetailPath(String albumKey) => '/albums/${albumRouteId(albumKey)}';

/// Ouvre le détail d'un album (anti-doublon).
void openAlbumDetail(BuildContext context, String albumKey) {
  logNavigation(
    'détail album demandé: clé brute="$albumKey" '
    'routeId="${albumRouteId(albumKey)}"',
  );
  _pushUnique(context, albumDetailPath(albumKey));
}

/// Ouvre le détail d'un album **depuis le lecteur complet** : remplace
/// `/player` au lieu d'empiler par-dessus, pour ne jamais avoir deux
/// PlayerScreen dans la pile (le mini-player du détail rouvrira le lecteur).
void openAlbumDetailFromPlayer(BuildContext context, String albumKey) {
  final router = GoRouter.of(context);
  final path = albumDetailPath(albumKey);
  logNavigation(
    'détail album depuis lecteur: clé="$albumKey" → $path (replace)',
  );
  if (router.canPop()) {
    router.replace(path);
  } else {
    router.go('/');
    router.push(path);
  }
}

/// Chemin du détail artiste, avec une clé base64Url et une section optionnelle.
String artistDetailPath(String artistKey, {bool focusAlbums = false}) {
  final basePath = '/artists/${artistRouteId(artistKey)}';
  return focusAlbums ? '$basePath?section=albums' : basePath;
}

/// Ouvre le détail d'un artiste depuis les écrans de bibliothèque.
void openArtistDetail(BuildContext context, String artistKey) {
  final routeId = artistRouteId(artistKey);
  logNavigation(
    'détail artiste demandé: clé brute="$artistKey" routeId="$routeId"',
  );
  _pushUnique(context, artistDetailPath(artistKey));
}

/// Ouvre la page artiste depuis le lecteur en remplaçant `/player`.
void openArtistDetailFromPlayer(BuildContext context, String artistKey) {
  _openArtistFromPlayer(context, artistKey, focusAlbums: false);
}

/// Ouvre directement la section albums de l'artiste depuis le lecteur.
void openArtistAlbumsFromPlayer(BuildContext context, String artistKey) {
  _openArtistFromPlayer(context, artistKey, focusAlbums: true);
}

void _openArtistFromPlayer(
  BuildContext context,
  String artistKey, {
  required bool focusAlbums,
}) {
  final router = GoRouter.of(context);
  final path = artistDetailPath(artistKey, focusAlbums: focusAlbums);
  logNavigation(
    '${focusAlbums ? 'albums artiste' : 'page artiste'} depuis lecteur: '
    'clé="$artistKey" routeId="${artistRouteId(artistKey)}" → $path '
    '(replace)',
  );
  if (router.canPop()) {
    router.replace(path);
  } else {
    router.go('/');
    router.push(path);
  }
}

/// Ferme le lecteur complet : retour à l'écran qui l'a ouvert (bibliothèque,
/// albums ou détail album), bibliothèque en dernier recours. `openPlayer`
/// garantit une seule instance de `/player`, donc un seul retour suffit
/// toujours. `GoRouter.pop()` pope directement (sans `maybePop`), donc pas de
/// réentrance avec le `PopScope` du PlayerScreen.
void closePlayer(BuildContext context) {
  final router = GoRouter.of(context);
  logNavigation(
    'fermeture lecteur (depuis ${router.state.uri.path}, '
    'canPop=${router.canPop()})',
  );
  if (router.canPop()) {
    router.pop();
  } else {
    router.go('/');
  }
}
