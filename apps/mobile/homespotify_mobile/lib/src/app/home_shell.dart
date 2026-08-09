import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/widgets/pill_nav_bar.dart';
import '../features/player/presentation/widgets/mini_player.dart';
import 'main_navigation_state.dart';

/// Coque de navigation principale (StatefulShellRoute.indexedStack).
///
/// Widget de RENDU PUR : il ne publie plus aucun état de navigation. L'onglet
/// courant et la visibilité du shell sont DÉRIVÉS de la route
/// (cf. main_navigation_state.dart) — c'est ce qui supprime la mutation de
/// provider pendant le build (GoRouter notifie ses observateurs pendant la
/// reconstruction du Navigator).
///
/// L'IndexedStack de GoRouter conserve l'état et le scroll de chaque branche.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  /// Action UTILISATEUR : seul point d'entrée du changement d'onglet. Un tap
  /// sur l'onglet déjà actif revient à sa racine (initialLocation).
  void _selectDestination(int index) {
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = navigationShell.currentIndex;
    return PopScope(
      canPop: currentIndex == HomeDestination.home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && currentIndex != HomeDestination.home) {
          _selectDestination(HomeDestination.home);
        }
      },
      // Le fond vient du thème (clair ou sombre selon le téléphone) : les
      // écrans encore en ancien design repeignent le leur par-dessus.
      child: Scaffold(
        body: navigationShell,
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const MiniPlayer(safeAreaBottom: false),
            HomeBottomNavigation(
              selectedIndex: currentIndex,
              onDestinationSelected: _selectDestination,
            ),
          ],
        ),
      ),
    );
  }
}

/// Les QUATRE destinations métier de l'application. Le design change, pas
/// l'architecture de navigation.
class HomeBottomNavigation extends StatelessWidget {
  const HomeBottomNavigation({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    return PillNavBar(
      key: const ValueKey('home-bottom-navigation'),
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestinationSelected,
      destinations: const [
        PillNavDestination(
          itemKey: ValueKey('destination-home'),
          icon: Icons.home_outlined,
          selectedIcon: Icons.home_rounded,
          label: 'Accueil',
        ),
        PillNavDestination(
          itemKey: ValueKey('destination-library'),
          icon: Icons.library_music_outlined,
          selectedIcon: Icons.library_music_rounded,
          label: 'Bibliothèque',
        ),
        PillNavDestination(
          itemKey: ValueKey('destination-discover'),
          icon: Icons.explore_outlined,
          selectedIcon: Icons.explore_rounded,
          label: 'Découvrir',
        ),
        PillNavDestination(
          itemKey: ValueKey('destination-profile'),
          icon: Icons.person_outline_rounded,
          selectedIcon: Icons.person_rounded,
          label: 'Profil',
        ),
      ],
    );
  }
}
