import 'package:flutter/material.dart';

/// Jetons visuels partagés par les surfaces principales HomeSpotify.
///
/// ÉTAT DE LA MIGRATION « Direction 33 » :
/// - Les COULEURS ci-dessous sont HISTORIQUES (thème sombre unique, accent vert
///   Spotify). Elles ne servent plus qu'aux écrans pas encore refondus, rendus
///   sous `AppTheme.legacyDark`. Interdit dans un écran migré : utiliser
///   `context.colors` (`AppColors`).
/// - Les ESPACEMENTS, DURÉES et COURBES restent valables partout : ils sont
///   indépendants du thème et n'ont pas été redéfinis.
/// - Les RAYONS historiques sont conservés pour les écrans non migrés ; les
///   écrans refondus utilisent `AppRadius`.
abstract final class HomeDesign {
  static const Color background = Color(0xFF0D0D10);
  static const Color surface = Color(0xFF17171D);
  static const Color surfaceRaised = Color(0xFF202028);
  static const Color surfaceMuted = Color(0xFF292932);
  static const Color accent = Color(0xFF1DB954);
  static const Color danger = Color(0xFFE57373);

  static const double space4 = 4;
  static const double space8 = 8;
  static const double space12 = 12;
  static const double space16 = 16;
  static const double space20 = 20;
  static const double space24 = 24;
  static const double space32 = 32;

  static const double radiusSmall = 10;
  static const double radiusMedium = 16;
  static const double radiusLarge = 22;
  static const double maxContentWidth = 960;

  static const Duration microAnimation = Duration(milliseconds: 160);
  static const Duration stateAnimation = Duration(milliseconds: 220);
  static const Duration pageAnimation = Duration(milliseconds: 260);
  static const Curve animationCurve = Curves.easeOutCubic;

  static Duration animationDuration(BuildContext context, Duration preferred) {
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return reduceMotion ? Duration.zero : preferred;
  }
}
