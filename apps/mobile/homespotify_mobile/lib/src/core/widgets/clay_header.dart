import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_shapes.dart';
import 'soft_surface.dart';

/// En-tête « Direction 33 » des écrans empilés et de détail : bouton retour
/// sculpté à gauche, titre (et sous-titre optionnel), actions sculptées à
/// droite. Aucune barre, aucune règle — le relief et l'espacement suffisent.
///
/// Réutilise [SoftCircle] pour le bouton retour et les actions ; le titre suit
/// la typographie Sora du thème (`displaySmall` par défaut, comme l'Accueil).
class ClayHeader extends StatelessWidget {
  const ClayHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.onBack,
    this.actions = const <Widget>[],
    this.titleStyle,
    this.padding = const EdgeInsets.fromLTRB(
      AppLayout.gutter,
      12,
      AppLayout.gutter,
      14,
    ),
  });

  final String title;
  final String? subtitle;

  /// Si non nul, un bouton retour sculpté est affiché à gauche.
  final VoidCallback? onBack;

  /// Boutons d'action sculptés à droite (déjà des [SoftCircle] ou équivalents).
  final List<Widget> actions;

  final TextStyle? titleStyle;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (onBack != null) ...[
            SoftCircle(
              size: 46,
              onTap: onBack,
              tooltip: 'Retour',
              semanticLabel: 'Retour',
              child: Icon(
                Icons.arrow_back_rounded,
                size: 21,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(width: 14),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: (titleStyle ?? theme.textTheme.displaySmall)?.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          for (final action in actions) ...[
            const SizedBox(width: 10),
            action,
          ],
        ],
      ),
    );
  }
}
