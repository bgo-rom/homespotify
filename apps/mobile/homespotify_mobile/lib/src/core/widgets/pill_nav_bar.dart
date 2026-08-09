import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_shapes.dart';
import '../theme/home_design.dart';

/// Destination de [PillNavBar].
@immutable
class PillNavDestination {
  const PillNavDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.itemKey,
  });

  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final Key? itemKey;
}

/// Barre de navigation en pilule flottante (Direction 33).
///
/// Remplace le `NavigationBar` Material : plus de barre pleine largeur, plus
/// d'indicateur Material, plus de teinte de surface — une seule surface
/// sculptée posée au-dessus du contenu, et une pastille douce sous l'onglet
/// actif.
class PillNavBar extends StatelessWidget {
  const PillNavBar({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  final List<PillNavDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: AppRadius.pillRadius,
            boxShadow: colors.clayShadowFloating,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Row(
              children: <Widget>[
                for (var index = 0; index < destinations.length; index++)
                  Expanded(
                    child: _PillNavItem(
                      destination: destinations[index],
                      selected: index == selectedIndex,
                      onTap: () => onDestinationSelected(index),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PillNavItem extends StatelessWidget {
  const _PillNavItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final PillNavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final duration = HomeDesign.animationDuration(
      context,
      HomeDesign.stateAnimation,
    );
    final foreground = selected ? colors.accent : colors.textSecondary;

    return Semantics(
      button: true,
      selected: selected,
      label: destination.label,
      child: InkWell(
        key: destination.itemKey,
        onTap: onTap,
        borderRadius: AppRadius.tileRadius,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: duration,
                curve: HomeDesign.animationCurve,
                width: 46,
                height: 30,
                decoration: BoxDecoration(
                  color: selected ? colors.accentSoft : Colors.transparent,
                  borderRadius: AppRadius.chipRadius,
                ),
                child: Icon(
                  selected ? destination.selectedIcon : destination.icon,
                  size: 21,
                  color: foreground,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                destination.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10.5,
                  color: foreground,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
