import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'app_shapes.dart';
import 'app_typography.dart';

/// Thèmes de l'application — [light] / [dark] : « Direction 33 — Clay
/// Tactile Premium ». Ce sont les deux faces du MÊME design system,
/// sélectionnées par `ThemeMode.system`. Toute l'application s'y appuie,
/// du parcours d'authentification pré-connexion à `appRouter`.
abstract final class AppTheme {
  static final ThemeData light = _build(AppColors.light);
  static final ThemeData dark = _build(AppColors.dark);

  static ThemeData _build(AppColors colors) {
    final isDark = colors.brightness == Brightness.dark;
    final textTheme = AppTypography.textTheme(
      colors.textPrimary,
      colors.textSecondary,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: colors.brightness,
      fontFamily: AppTypography.fontFamily,
      fontFamilyFallback: AppTypography.fallback,
      scaffoldBackgroundColor: colors.background,
      canvasColor: colors.background,
      textTheme: textTheme,
      colorScheme: ColorScheme(
        brightness: colors.brightness,
        primary: colors.accent,
        onPrimary: colors.onAccent,
        primaryContainer: colors.accentSoft,
        onPrimaryContainer: colors.accent,
        secondary: colors.clayTerracotta,
        onSecondary: colors.clayTerracottaInk,
        tertiary: colors.clayBlue,
        onTertiary: colors.clayBlueInk,
        error: colors.danger,
        onError: colors.onAccent,
        surface: colors.surface,
        onSurface: colors.textPrimary,
        surfaceContainerHighest: colors.surfaceRaised,
        onSurfaceVariant: colors.textSecondary,
        outline: colors.textTertiary,
        outlineVariant: colors.surfaceSunken,
        shadow: colors.shadowDrop,
        scrim: colors.scrim,
        inverseSurface: colors.textPrimary,
        onInverseSurface: colors.surface,
        inversePrimary: colors.accent,
      ),
      // Aucune bordure Material dure : la séparation passe par le relief.
      dividerTheme: DividerThemeData(
        color: colors.surfaceSunken,
        thickness: 1,
        space: 1,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: colors.background,
        foregroundColor: colors.textPrimary,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.headlineSmall,
      ),
      iconTheme: IconThemeData(color: colors.textPrimary, size: 24),
      listTileTheme: ListTileThemeData(
        textColor: colors.textPrimary,
        iconColor: colors.textSecondary,
        subtitleTextStyle: textTheme.bodySmall,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.cardRadius),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: colors.accent,
          foregroundColor: colors.onAccent,
          minimumSize: const Size(48, 48),
          textStyle: textTheme.titleSmall,
          shape: RoundedRectangleBorder(borderRadius: AppRadius.chipRadius),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colors.link,
          textStyle: textTheme.labelLarge,
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.accent,
        linearTrackColor: colors.surfaceSunken,
        circularTrackColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: colors.surfaceRaised,
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: colors.textPrimary,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.chipRadius),
      ),
      splashColor: colors.accentSoft,
      highlightColor: isDark
          ? const Color(0x0DFFFFFF)
          : const Color(0x0A000000),
      visualDensity: VisualDensity.standard,
      extensions: <ThemeExtension<dynamic>>[colors],
    );
  }
}
