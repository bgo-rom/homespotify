import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'router.dart';

abstract final class HomeDestination {
  static const int home = 0;
  static const int library = 1;
  static const int discover = 2;
  static const int profile = 3;
}

/// Index de branche correspondant à une location, ou `null` si la location est
/// HORS du shell (route empilée par-dessus : `/albums`, `/player`, `/requests`…).
int? branchIndexForLocation(String location) {
  if (location == '/') return HomeDestination.home;
  if (location.startsWith('/library')) return HomeDestination.library;
  if (location.startsWith('/discover')) return HomeDestination.discover;
  if (location.startsWith('/profile')) return HomeDestination.profile;
  return null;
}

/// Location courante du routeur, tolérante à un routeur pas encore configuré.
String _currentLocation(GoRouter router) {
  try {
    return router.state.uri.path;
  } catch (_) {
    return '/';
  }
}

/// Onglet courant, **DÉRIVÉ de la route**.
///
/// Aucun widget n'écrit plus cet état : il est recalculé quand le routeur
/// notifie ses écouteurs, ce qui se produit depuis l'ACTION de navigation
/// (`onTap` → `goBranch`/`push`), phase où la mutation d'un provider est
/// légale. Auparavant, `HomeShell` le publiait depuis `build()` et depuis
/// `didPushNext()` — or GoRouter notifie ses observateurs PENDANT la
/// reconstruction du Navigator, d'où « Tried to modify a provider while the
/// widget tree was building ».
///
/// Quand une route hors shell couvre le shell, l'index est CONSERVÉ : la
/// branche reste sélectionnée dessous (cf. [mainShellVisibilityProvider]).
class MainNavigationIndex extends Notifier<int> {
  @override
  int build() {
    final router = appRouter;
    void listener() {
      final next = branchIndexForLocation(_currentLocation(router));
      if (next != null && state != next) state = next;
    }

    router.routerDelegate.addListener(listener);
    ref.onDispose(() => router.routerDelegate.removeListener(listener));
    return branchIndexForLocation(_currentLocation(router)) ??
        HomeDestination.home;
  }
}

final mainNavigationIndexProvider = NotifierProvider<MainNavigationIndex, int>(
  MainNavigationIndex.new,
);

/// `true` tant qu'AUCUNE route n'est empilée par-dessus le shell — dérivé de la
/// route, sans aucune écriture depuis un widget ni un observateur de routes.
class MainShellVisibility extends Notifier<bool> {
  @override
  bool build() {
    final router = appRouter;
    bool visible() => branchIndexForLocation(_currentLocation(router)) != null;
    void listener() {
      final next = visible();
      if (state != next) state = next;
    }

    router.routerDelegate.addListener(listener);
    ref.onDispose(() => router.routerDelegate.removeListener(listener));
    return visible();
  }
}

final mainShellVisibilityProvider = NotifierProvider<MainShellVisibility, bool>(
  MainShellVisibility.new,
);
