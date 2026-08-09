import 'package:flutter/widgets.dart';

/// Rayons « Direction 33 » : coins généreusement arrondis, aucune arête vive.
///
/// Les rayons historiques de `HomeDesign` (10/16/22) restent en place pour les
/// écrans non encore migrés ; les écrans refondus utilisent EXCLUSIVEMENT ceux
/// de cette classe.
abstract final class AppRadius {
  /// Pastilles, petits badges.
  static const double chip = 14;

  /// Pochettes et vignettes carrées.
  static const double artwork = 20;

  /// Cartes standard.
  static const double card = 24;

  /// Grandes tuiles sculptées (accès rapides, mini-player).
  static const double tile = 28;

  /// Barre de navigation en pilule.
  static const double pill = 34;

  static BorderRadius get chipRadius => BorderRadius.circular(chip);
  static BorderRadius get artworkRadius => BorderRadius.circular(artwork);
  static BorderRadius get cardRadius => BorderRadius.circular(card);
  static BorderRadius get tileRadius => BorderRadius.circular(tile);
  static BorderRadius get pillRadius => BorderRadius.circular(pill);
}

/// Rythme d'espacement horizontal des écrans refondus.
abstract final class AppLayout {
  /// Marge latérale des planches de référence.
  static const double gutter = 22;

  /// Largeur maximale du contenu sur grand écran.
  static const double maxContentWidth = 960;
}
