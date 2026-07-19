import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/home_design.dart';
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
      child: Scaffold(
        backgroundColor: HomeDesign.background,
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
    return NavigationBar(
      key: const ValueKey('home-bottom-navigation'),
      height: 72,
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestinationSelected,
      backgroundColor: HomeDesign.surface,
      indicatorColor: HomeDesign.accent.withValues(alpha: 0.2),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      animationDuration: HomeDesign.animationDuration(
        context,
        HomeDesign.stateAnimation,
      ),
      destinations: const [
        NavigationDestination(
          key: ValueKey('destination-home'),
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home_rounded),
          label: 'Accueil',
          tooltip: 'Accueil',
        ),
        NavigationDestination(
          key: ValueKey('destination-library'),
          icon: Icon(Icons.library_music_outlined),
          selectedIcon: Icon(Icons.library_music_rounded),
          label: 'Bibliothèque',
          tooltip: 'Bibliothèque',
        ),
        NavigationDestination(
          key: ValueKey('destination-discover'),
          icon: Icon(Icons.explore_outlined),
          selectedIcon: Icon(Icons.explore_rounded),
          label: 'Découvrir',
          tooltip: 'Découvrir',
        ),
        NavigationDestination(
          key: ValueKey('destination-profile'),
          icon: Icon(Icons.person_outline_rounded),
          selectedIcon: Icon(Icons.person_rounded),
          label: 'Profil',
          tooltip: 'Profil',
        ),
      ],
    );
  }
}
