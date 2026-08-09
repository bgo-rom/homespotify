import 'package:flutter/material.dart';

/// Jetons de couleur « Direction 33 — Clay Tactile Premium ».
///
/// SOURCE DE VÉRITÉ UNIQUE des couleurs des écrans refondus : aucune couleur
/// métier ne doit être écrite en dur dans un écran migré, tout passe par
/// `context.colors`.
///
/// Les valeurs sont approximées depuis les deux planches de référence
/// (Accueil clair / Accueil sombre). Les deux variantes forment le MÊME design
/// system : seule la luminosité change, jamais la structure ni les rayons.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceSunken,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.accentSoft,
    required this.onAccent,
    required this.link,
    required this.danger,
    required this.playSurface,
    required this.playInk,
    required this.claySand,
    required this.claySandInk,
    required this.clayBlue,
    required this.clayBlueInk,
    required this.clayTerracotta,
    required this.clayTerracottaInk,
    required this.clayMauve,
    required this.clayMauveInk,
    required this.shadowDrop,
    required this.shadowLift,
    required this.scrim,
  });

  final Brightness brightness;

  /// Fond de page.
  final Color background;

  /// Surface sculptée standard : cartes, barre de navigation, mini-player.
  final Color surface;

  /// Surface la plus haute : bouton de lecture rond, pastille d'onglet actif.
  final Color surfaceRaised;

  /// Creux : placeholder de pochette, rail de progression.
  final Color surfaceSunken;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  /// Accent argile/cuivre — remplace intégralement le vert Spotify historique.
  final Color accent;

  /// Accent en aplat très dilué (fond de pastille, halo d'icône).
  final Color accentSoft;

  /// Encre lisible posée sur [accent].
  final Color onAccent;

  /// Actions textuelles discrètes (« Tout voir »).
  final Color link;

  final Color danger;

  /// Bouton de lecture principal : crème en clair, argile en sombre.
  final Color playSurface;
  final Color playInk;

  /// Tuiles d'accès rapide, langage « clay » des planches de référence.
  final Color claySand;
  final Color claySandInk;
  final Color clayBlue;
  final Color clayBlueInk;
  final Color clayTerracotta;
  final Color clayTerracottaInk;
  final Color clayMauve;
  final Color clayMauveInk;

  /// Relief : une ombre portée chaude + une remontée lumineuse. Jamais de
  /// bordure dure — la séparation vient uniquement de ces deux ombres.
  final Color shadowDrop;
  final Color shadowLift;

  final Color scrim;

  /// Palette claire : crème chaude, encre espresso, accent argile rosé.
  static const AppColors light = AppColors(
    brightness: Brightness.light,
    background: Color(0xFFF4EDE5),
    surface: Color(0xFFFDF9F4),
    surfaceRaised: Color(0xFFFFFFFF),
    surfaceSunken: Color(0xFFE8DED2),
    textPrimary: Color(0xFF1B1512),
    textSecondary: Color(0xFF8C8079),
    textTertiary: Color(0xFFB0A69E),
    accent: Color(0xFFA96A63),
    accentSoft: Color(0x1FA96A63),
    onAccent: Color(0xFFFFF8F3),
    link: Color(0xFF8C8079),
    danger: Color(0xFFC05B4D),
    playSurface: Color(0xFFFFFFFF),
    playInk: Color(0xFF1B1512),
    claySand: Color(0xFFEFE3CE),
    claySandInk: Color(0xFF6E5B3A),
    clayBlue: Color(0xFFB7C7D8),
    clayBlueInk: Color(0xFF33414F),
    clayTerracotta: Color(0xFFC48A73),
    clayTerracottaInk: Color(0xFF4A2A1E),
    clayMauve: Color(0xFFE0CBCB),
    clayMauveInk: Color(0xFF6A4A49),
    shadowDrop: Color(0x1A2A170B),
    shadowLift: Color(0xCCFFFFFF),
    scrim: Color(0x662A170B),
  );

  /// Palette sombre : graphite/espresso, encre crème, accent argile cuivré.
  static const AppColors dark = AppColors(
    brightness: Brightness.dark,
    background: Color(0xFF131110),
    surface: Color(0xFF1E1B19),
    surfaceRaised: Color(0xFF272321),
    surfaceSunken: Color(0xFF0D0C0B),
    textPrimary: Color(0xFFF1E9E0),
    textSecondary: Color(0xFFA0968D),
    textTertiary: Color(0xFF6F675F),
    accent: Color(0xFFC4867C),
    accentSoft: Color(0x24C4867C),
    onAccent: Color(0xFF1B1512),
    link: Color(0xFFC08A6E),
    danger: Color(0xFFE08174),
    playSurface: Color(0xFFC89078),
    playInk: Color(0xFF241713),
    claySand: Color(0xFF7E6B4E),
    claySandInk: Color(0xFFF0E5D2),
    clayBlue: Color(0xFF414A55),
    clayBlueInk: Color(0xFFD6E0EA),
    clayTerracotta: Color(0xFF8E5B4C),
    clayTerracottaInk: Color(0xFFF7E5DC),
    clayMauve: Color(0xFF5E4645),
    clayMauveInk: Color(0xFFE7D5D4),
    shadowDrop: Color(0x73000000),
    shadowLift: Color(0x0FFFFFFF),
    scrim: Color(0x99000000),
  );

  /// Relief standard d'une carte sculptée.
  List<BoxShadow> get clayShadow => <BoxShadow>[
    BoxShadow(
      color: shadowDrop,
      blurRadius: 24,
      spreadRadius: -6,
      offset: const Offset(0, 10),
    ),
    BoxShadow(
      color: shadowLift,
      blurRadius: 16,
      spreadRadius: -8,
      offset: const Offset(0, -6),
    ),
  ];

  /// Relief resserré : pastilles, petits boutons ronds, tuiles compactes.
  List<BoxShadow> get clayShadowSmall => <BoxShadow>[
    BoxShadow(
      color: shadowDrop,
      blurRadius: 12,
      spreadRadius: -4,
      offset: const Offset(0, 5),
    ),
    BoxShadow(
      color: shadowLift,
      blurRadius: 8,
      spreadRadius: -5,
      offset: const Offset(0, -3),
    ),
  ];

  /// Relief flottant : barre de navigation en pilule, mini-player.
  List<BoxShadow> get clayShadowFloating => <BoxShadow>[
    BoxShadow(
      color: shadowDrop,
      blurRadius: 32,
      spreadRadius: -8,
      offset: const Offset(0, 14),
    ),
    BoxShadow(
      color: shadowLift,
      blurRadius: 18,
      spreadRadius: -10,
      offset: const Offset(0, -8),
    ),
  ];

  @override
  AppColors copyWith({
    Brightness? brightness,
    Color? background,
    Color? surface,
    Color? surfaceRaised,
    Color? surfaceSunken,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? accent,
    Color? accentSoft,
    Color? onAccent,
    Color? link,
    Color? danger,
    Color? playSurface,
    Color? playInk,
    Color? claySand,
    Color? claySandInk,
    Color? clayBlue,
    Color? clayBlueInk,
    Color? clayTerracotta,
    Color? clayTerracottaInk,
    Color? clayMauve,
    Color? clayMauveInk,
    Color? shadowDrop,
    Color? shadowLift,
    Color? scrim,
  }) {
    return AppColors(
      brightness: brightness ?? this.brightness,
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      surfaceSunken: surfaceSunken ?? this.surfaceSunken,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      onAccent: onAccent ?? this.onAccent,
      link: link ?? this.link,
      danger: danger ?? this.danger,
      playSurface: playSurface ?? this.playSurface,
      playInk: playInk ?? this.playInk,
      claySand: claySand ?? this.claySand,
      claySandInk: claySandInk ?? this.claySandInk,
      clayBlue: clayBlue ?? this.clayBlue,
      clayBlueInk: clayBlueInk ?? this.clayBlueInk,
      clayTerracotta: clayTerracotta ?? this.clayTerracotta,
      clayTerracottaInk: clayTerracottaInk ?? this.clayTerracottaInk,
      clayMauve: clayMauve ?? this.clayMauve,
      clayMauveInk: clayMauveInk ?? this.clayMauveInk,
      shadowDrop: shadowDrop ?? this.shadowDrop,
      shadowLift: shadowLift ?? this.shadowLift,
      scrim: scrim ?? this.scrim,
    );
  }

  @override
  AppColors lerp(covariant ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return AppColors(
      brightness: t < 0.5 ? brightness : other.brightness,
      background: mix(background, other.background),
      surface: mix(surface, other.surface),
      surfaceRaised: mix(surfaceRaised, other.surfaceRaised),
      surfaceSunken: mix(surfaceSunken, other.surfaceSunken),
      textPrimary: mix(textPrimary, other.textPrimary),
      textSecondary: mix(textSecondary, other.textSecondary),
      textTertiary: mix(textTertiary, other.textTertiary),
      accent: mix(accent, other.accent),
      accentSoft: mix(accentSoft, other.accentSoft),
      onAccent: mix(onAccent, other.onAccent),
      link: mix(link, other.link),
      danger: mix(danger, other.danger),
      playSurface: mix(playSurface, other.playSurface),
      playInk: mix(playInk, other.playInk),
      claySand: mix(claySand, other.claySand),
      claySandInk: mix(claySandInk, other.claySandInk),
      clayBlue: mix(clayBlue, other.clayBlue),
      clayBlueInk: mix(clayBlueInk, other.clayBlueInk),
      clayTerracotta: mix(clayTerracotta, other.clayTerracotta),
      clayTerracottaInk: mix(clayTerracottaInk, other.clayTerracottaInk),
      clayMauve: mix(clayMauve, other.clayMauve),
      clayMauveInk: mix(clayMauveInk, other.clayMauveInk),
      shadowDrop: mix(shadowDrop, other.shadowDrop),
      shadowLift: mix(shadowLift, other.shadowLift),
      scrim: mix(scrim, other.scrim),
    );
  }
}

/// Accès aux jetons depuis n'importe quel widget.
///
/// REPLI VOLONTAIRE : si l'extension n'est pas installée sur le thème courant
/// (widget monté isolément dans un test, `MaterialApp` nu), la palette est
/// déduite de la luminosité du thème. Un écran migré ne crashe donc jamais
/// hors de `AppTheme`.
extension AppColorsContext on BuildContext {
  AppColors get colors {
    final theme = Theme.of(this);
    return theme.extension<AppColors>() ??
        (theme.brightness == Brightness.dark
            ? AppColors.dark
            : AppColors.light);
  }
}
