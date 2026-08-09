import 'package:flutter/material.dart';

/// Typographie officielle « Direction 33 » : **Sora**.
///
/// Trois graisses embarquées en asset local (`assets/fonts/`, licence OFL) :
/// Regular (400), Medium (500), SemiBold (600). Aucune graisse supérieure
/// n'est fournie : les titres des planches sont en SemiBold, pas en Bold.
abstract final class AppTypography {
  static const String fontFamily = 'Sora';

  /// Repli explicite : si Sora manquait à l'exécution, on retombe sur la
  /// police système plutôt que sur un carré vide.
  static const List<String> fallback = <String>['Roboto'];

  static TextTheme textTheme(Color primary, Color secondary) {
    TextStyle style({
      required double size,
      required FontWeight weight,
      required Color color,
      double height = 1.25,
      double letterSpacing = 0,
    }) {
      return TextStyle(
        fontFamily: fontFamily,
        fontFamilyFallback: fallback,
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
      );
    }

    return TextTheme(
      // « Accueil »
      displaySmall: style(
        size: 34,
        weight: FontWeight.w600,
        color: primary,
        height: 1.1,
        letterSpacing: -0.8,
      ),
      // « Bonjour Romain »
      headlineMedium: style(
        size: 26,
        weight: FontWeight.w600,
        color: primary,
        height: 1.15,
        letterSpacing: -0.5,
      ),
      headlineSmall: style(
        size: 21,
        weight: FontWeight.w600,
        color: primary,
        letterSpacing: -0.3,
      ),
      // Titres de section : « Écouté récemment »
      titleLarge: style(
        size: 18,
        weight: FontWeight.w600,
        color: primary,
        letterSpacing: -0.2,
      ),
      // Titre de carte : « Lofi Home »
      titleMedium: style(size: 15.5, weight: FontWeight.w600, color: primary),
      titleSmall: style(size: 14, weight: FontWeight.w500, color: primary),
      bodyLarge: style(
        size: 15,
        weight: FontWeight.w400,
        color: primary,
        height: 1.4,
      ),
      // « Que souhaitez-vous écouter aujourd'hui ? »
      bodyMedium: style(
        size: 14.5,
        weight: FontWeight.w400,
        color: secondary,
        height: 1.45,
      ),
      // « Playlist »
      bodySmall: style(
        size: 13,
        weight: FontWeight.w400,
        color: secondary,
        height: 1.35,
      ),
      // « Tout voir »
      labelLarge: style(size: 14, weight: FontWeight.w500, color: secondary),
      labelMedium: style(size: 12.5, weight: FontWeight.w500, color: secondary),
      labelSmall: style(size: 11, weight: FontWeight.w500, color: secondary),
    );
  }
}
