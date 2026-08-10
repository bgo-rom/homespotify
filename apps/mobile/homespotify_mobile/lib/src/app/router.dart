import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../core/logging/app_logger.dart';
import '../core/theme/app_theme.dart';
import '../features/home/presentation/home_dashboard_screen.dart';
import '../features/profile/presentation/profile_screen.dart';
import 'home_shell.dart';
import 'route_observer.dart';
import '../features/admin/presentation/admin_dashboard_screen.dart';
import '../features/admin/presentation/admin_users_screen.dart';
import '../features/admin/presentation/admin_imports_screen.dart';
import '../features/admin/presentation/admin_recommendation_diagnostics_screen.dart';
import '../features/catalog_search/presentation/catalog_search_screen.dart';
import '../features/discovery/presentation/discover_screen.dart';
import '../features/library/domain/local_playlist.dart';
import '../features/library/presentation/album_detail_screen.dart';
import '../features/library/presentation/albums_screen.dart';
import '../features/library/presentation/artist_detail_screen.dart';
import '../features/library/presentation/artists_screen.dart';
import '../features/library/presentation/favorites_screen.dart';
import '../features/library/presentation/library_albums.dart';
import '../features/library/presentation/library_artists.dart';
import '../features/library/presentation/library_screen.dart';
import '../features/library/presentation/playlist_detail_screen.dart';
import '../features/library/presentation/playlists_screen.dart';
import '../features/player/presentation/player_screen.dart';
import '../features/player/presentation/audio_diagnostics_screen.dart';
import '../features/player/presentation/queue_screen.dart';
import '../features/player/presentation/stretch_lab_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/listening/presentation/listening_activity_screen.dart';
import '../features/offline/presentation/downloads_screen.dart';

/// Transition custom commune : fade + léger slide vertical, à la place de la
/// transition Material par défaut.
///
/// MIGRATION DIRECTION 33 : tant qu'un écran empilé n'est pas refondu, il est
/// figé dans le thème sombre historique par [LegacyDarkTheme]. Sinon, un
/// téléphone en mode clair rendrait illisibles les écrans qui s'appuient sur
/// les valeurs par défaut sombres. Chaque lot de refonte sortira son écran de
/// ce repli.
CustomTransitionPage<void> _darkTransitionPage({
  required LocalKey key,
  required Widget child,
}) {
  return CustomTransitionPage<void>(
    key: key,
    child: LegacyDarkTheme(child: child),
    transitionDuration: const Duration(milliseconds: 240),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    transitionsBuilder: _fadeSlide,
  );
}

/// Même transition, mais SANS repli sombre historique : réservée aux écrans
/// déjà refondus en Direction 33 (ils suivent alors le thème clair/sombre
/// système). Chaque écran migré passe de [_darkTransitionPage] à celle-ci.
CustomTransitionPage<void> _transitionPage({
  required LocalKey key,
  required Widget child,
}) {
  return CustomTransitionPage<void>(
    key: key,
    child: child,
    transitionDuration: const Duration(milliseconds: 240),
    reverseTransitionDuration: const Duration(milliseconds: 200),
    transitionsBuilder: _fadeSlide,
  );
}

Widget _fadeSlide(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
  return FadeTransition(
    opacity: curved,
    child: SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(0, 0.08),
        end: Offset.zero,
      ).animate(curved),
      child: child,
    ),
  );
}

/// Trace tous les push/pop du Navigator dans la catégorie `nav`.
class _LoggingNavigatorObserver extends NavigatorObserver {
  String _name(Route<dynamic>? route) =>
      route?.settings.name ?? route?.settings.runtimeType.toString() ?? '?';

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      logNavigation('didPush: ${_name(previousRoute)} → ${_name(route)}');

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      logNavigation('didPop: ${_name(route)} → ${_name(previousRoute)}');

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      logNavigation('didReplace: ${_name(oldRoute)} → ${_name(newRoute)}');
}

/// Clés de Navigator — créées UNE SEULE FOIS au niveau module (jamais dans un
/// `build`, sinon une nouvelle clé à chaque frame).
///
/// - [rootNavigatorKey] : l'UNIQUE Navigator racine du GoRouter principal. Sans
///   clé explicite, GoRouter en fabrique une en interne (`debugLabel: 'root'`)
///   dont l'identité n'est pas stable entre reconstructions du routeur → c'est
///   la clé qui apparaissait en double dans le crash.
/// - une clé DISTINCTE par branche du StatefulShellRoute : elle donne une
///   identité stable à chaque Navigator de branche, donc l'IndexedStack réutilise
///   les mêmes Navigators au lieu d'en reconstruire (et de dupliquer les clés)
///   quand une route hors shell (`/albums`) est empilée par-dessus.
///
/// Ces clés ne doivent JAMAIS être réutilisées par un Navigator enfant.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'root',
);
final GlobalKey<NavigatorState> homeNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'branch-home',
);
final GlobalKey<NavigatorState> libraryNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'branch-library',
);
final GlobalKey<NavigatorState> discoverNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'branch-discover');
final GlobalKey<NavigatorState> profileNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'branch-profile',
);

final GoRouter appRouter = GoRouter(
  initialLocation: '/',
  navigatorKey: rootNavigatorKey,
  // routeObserver : permet aux écrans `RouteAware` (Découvrir) de couper leur
  // média dès qu'une route est empilée par-dessus (visibilité, pas seulement pop).
  observers: [_LoggingNavigatorObserver(), routeObserver],
  // Route inconnue ou invalide : log + retour bibliothèque, jamais d'écran
  // rouge.
  onException: (context, state, router) {
    logError('route inconnue ou invalide: ${state.uri}', error: state.error);
    router.go('/');
  },
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) =>
          HomeShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          navigatorKey: homeNavigatorKey,
          routes: [
            GoRoute(
              path: '/',
              name: 'home',
              builder: (context, state) => const HomeDashboardScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          navigatorKey: libraryNavigatorKey,
          routes: [
            GoRoute(
              path: '/library',
              name: 'library',
              builder: (context, state) => const LibraryScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          navigatorKey: discoverNavigatorKey,
          routes: [
            GoRoute(
              path: '/discover',
              name: 'discover',
              // Pas encore migré en Direction 33 → thème sombre historique.
              builder: (context, state) =>
                  const LegacyDarkTheme(child: DiscoverScreen()),
            ),
          ],
        ),
        StatefulShellBranch(
          navigatorKey: profileNavigatorKey,
          routes: [
            GoRoute(
              path: '/profile',
              name: 'profile',
              // Pas encore migré en Direction 33 → thème sombre historique.
              builder: (context, state) =>
                  const LegacyDarkTheme(child: ProfileScreen()),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/albums',
      name: 'albums',
      pageBuilder: (context, state) =>
          _transitionPage(key: state.pageKey, child: const AlbumsScreen()),
    ),
    GoRoute(
      path: '/albums/:albumKey',
      name: 'album-detail',
      pageBuilder: (context, state) {
        // Le paramètre est un identifiant base64Url ([albumRouteId]) : jamais
        // de percent-encoding, donc aucun `Uri.decodeComponent` fragile ici.
        final rawParam = state.pathParameters['albumKey'] ?? '';
        final albumKey = albumKeyFromRouteId(rawParam);
        logNavigation(
          'route détail album: brut="$rawParam" '
          'décodé="${albumKey ?? '<illisible>'}"',
        );
        return _transitionPage(
          key: state.pageKey,
          // Clé illisible → clé vide qui ne matche aucun album : l'écran
          // affiche « Album introuvable » avec bouton retour.
          child: AlbumDetailScreen(albumKey: albumKey ?? ''),
        );
      },
    ),
    GoRoute(
      path: '/artists',
      name: 'artists',
      pageBuilder: (context, state) =>
          _transitionPage(key: state.pageKey, child: const ArtistsScreen()),
    ),
    GoRoute(
      path: '/artists/:artistRouteId',
      name: 'artist-detail',
      pageBuilder: (context, state) {
        final rawParam = state.pathParameters['artistRouteId'] ?? '';
        final artistKey = artistKeyFromRouteId(rawParam);
        final focusAlbums = state.uri.queryParameters['section'] == 'albums';
        logNavigation(
          'route détail artiste: brut="$rawParam" '
          'décodé="${artistKey ?? '<illisible>'}" '
          'section=${focusAlbums ? 'albums' : 'artiste'}',
        );
        return _transitionPage(
          key: state.pageKey,
          child: ArtistDetailScreen(
            artistKey: artistKey ?? '',
            focusAlbums: focusAlbums,
          ),
        );
      },
    ),
    GoRoute(
      path: '/favorites',
      name: 'favorites',
      pageBuilder: (context, state) => _transitionPage(
        key: state.pageKey,
        child: const FavoritesScreen(),
      ),
    ),
    GoRoute(
      path: '/playlists',
      name: 'playlists',
      pageBuilder: (context, state) => _transitionPage(
        key: state.pageKey,
        child: const PlaylistsScreen(),
      ),
    ),
    GoRoute(
      path: '/playlists/:playlistId',
      name: 'playlist-detail',
      pageBuilder: (context, state) {
        final rawId = state.pathParameters['playlistId'] ?? '';
        final playlistId = isSafePlaylistId(rawId) ? rawId : '';
        logNavigation(
          'route détail playlist: brut="$rawId" '
          'valid=${playlistId.isNotEmpty}',
        );
        return _transitionPage(
          key: state.pageKey,
          child: PlaylistDetailScreen(playlistId: playlistId),
        );
      },
    ),
    // UNIQUE écran de recherche distante : trouver un titre et l'installer.
    // Le job de téléchargement vit côté serveur et survit à la fermeture de
    // l'écran.
    GoRoute(
      path: '/catalog-search',
      name: 'catalog-search',
      pageBuilder: (context, state) => _transitionPage(
        key: state.pageKey,
        child: const CatalogSearchScreen(),
      ),
    ),
    GoRoute(
      path: '/admin',
      name: 'admin',
      pageBuilder: (context, state) => _darkTransitionPage(
        key: state.pageKey,
        child: const AdminDashboardScreen(),
      ),
    ),
    GoRoute(
      path: '/admin/users',
      name: 'admin-users',
      pageBuilder: (context, state) => _darkTransitionPage(
        key: state.pageKey,
        child: const AdminUsersScreen(),
      ),
    ),
    GoRoute(
      path: '/admin/imports',
      name: 'admin-imports',
      pageBuilder: (context, state) => _darkTransitionPage(
        key: state.pageKey,
        child: const AdminImportsScreen(),
      ),
    ),
    GoRoute(
      path: '/admin/recommendations',
      name: 'admin-recommendations',
      pageBuilder: (context, state) => _darkTransitionPage(
        key: state.pageKey,
        child: const AdminRecommendationDiagnosticsScreen(),
      ),
    ),
    // Téléchargements : entièrement local (manifeste SQLite), fonctionne sans
    // serveur — c'est l'écran pivot du mode hors connexion.
    GoRoute(
      path: '/downloads',
      name: 'downloads',
      pageBuilder: (context, state) => _darkTransitionPage(
        key: state.pageKey,
        child: const DownloadsScreen(),
      ),
    ),
    GoRoute(
      path: '/settings',
      name: 'settings',
      pageBuilder: (context, state) => _darkTransitionPage(
        key: state.pageKey,
        child: const SettingsScreen(),
      ),
    ),
    GoRoute(
      path: '/listening-activity',
      name: 'listening-activity',
      pageBuilder: (context, state) => _darkTransitionPage(
        key: state.pageKey,
        child: const ListeningActivityScreen(),
      ),
    ),
    GoRoute(
      path: '/player',
      name: 'player',
      pageBuilder: (context, state) =>
          _transitionPage(key: state.pageKey, child: const PlayerScreen()),
    ),
    GoRoute(
      path: '/queue',
      name: 'queue',
      pageBuilder: (context, state) =>
          _darkTransitionPage(key: state.pageKey, child: const QueueScreen()),
    ),
    // Écran développeur discret (accès par appui long sur le panneau « Mode
    // audio » de la feuille de vitesse) : comparaison A/B du moteur de
    // time-stretch sur la même piste et la même position.
    GoRoute(
      path: '/dev/stretch-lab',
      name: 'stretch-lab',
      pageBuilder: (context, state) => _darkTransitionPage(
        key: state.pageKey,
        child: const StretchLabScreen(),
      ),
    ),
    GoRoute(
      path: '/dev/audio-diagnostics',
      name: 'audio-diagnostics',
      pageBuilder: (context, state) => _darkTransitionPage(
        key: state.pageKey,
        child: const AudioDiagnosticsScreen(),
      ),
    ),
  ],
);
