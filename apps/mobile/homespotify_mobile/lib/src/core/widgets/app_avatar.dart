import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// Avatar sculpté du compte courant.
///
/// L'application ne stocke aucune photo de profil : l'initiale reste la seule
/// représentation possible (les planches de référence montrent une photo, la
/// donnée n'existe pas côté backend).
class AppAvatar extends StatelessWidget {
  const AppAvatar({
    super.key,
    required this.initial,
    this.size = 46,
    this.onTap,
    this.semanticLabel,
  });

  final String initial;
  final double size;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final content = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.accentSoft,
        shape: BoxShape.circle,
        boxShadow: colors.clayShadowSmall,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: Text(
                initial,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: colors.accent,
                  fontSize: size * 0.4,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return Semantics(
      button: onTap != null,
      label: semanticLabel,
      child: content,
    );
  }
}
