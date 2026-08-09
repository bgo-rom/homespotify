import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_shapes.dart';

/// Surface sculptée « clay » : aplat doux + relief en deux ombres, JAMAIS de
/// bordure. C'est la brique de base de tous les écrans Direction 33.
class SoftCard extends StatelessWidget {
  const SoftCard({
    super.key,
    required this.child,
    this.color,
    this.radius,
    this.padding,
    this.onTap,
    this.onLongPress,
    this.shadows,
    this.clipContent = false,
    this.semanticLabel,
  });

  final Widget child;
  final Color? color;
  final double? radius;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Relief personnalisé ; par défaut `AppColors.clayShadow`.
  final List<BoxShadow>? shadows;

  /// Rogne le contenu au rayon de la carte (pochettes plein cadre).
  final bool clipContent;

  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final borderRadius = BorderRadius.circular(radius ?? AppRadius.card);

    Widget content = Padding(padding: padding ?? EdgeInsets.zero, child: child);
    if (clipContent) {
      content = ClipRRect(borderRadius: borderRadius, child: content);
    }

    Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? colors.surface,
        borderRadius: borderRadius,
        boxShadow: shadows ?? colors.clayShadow,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          borderRadius: borderRadius,
          child: content,
        ),
      ),
    );

    if (semanticLabel != null) {
      surface = Semantics(
        button: onTap != null,
        label: semanticLabel,
        child: surface,
      );
    }
    return surface;
  }
}

/// Pastille ronde sculptée : boutons d'en-tête, bouton de lecture, avatar.
class SoftCircle extends StatelessWidget {
  const SoftCircle({
    super.key,
    required this.size,
    required this.child,
    this.color,
    this.onTap,
    this.shadows,
    this.semanticLabel,
    this.tooltip,
  });

  final double size;
  final Widget child;
  final Color? color;
  final VoidCallback? onTap;
  final List<BoxShadow>? shadows;
  final String? semanticLabel;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? colors.surface,
        shape: BoxShape.circle,
        boxShadow: shadows ?? colors.clayShadowSmall,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: size,
            height: size,
            child: Center(child: child),
          ),
        ),
      ),
    );

    if (tooltip != null) {
      surface = Tooltip(message: tooltip!, child: surface);
    }
    if (semanticLabel != null) {
      surface = Semantics(
        button: onTap != null,
        label: semanticLabel,
        child: surface,
      );
    }
    return surface;
  }
}
