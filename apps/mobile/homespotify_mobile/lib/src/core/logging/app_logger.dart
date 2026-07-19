import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Logger central HomeSpotify, basé sur `dart:developer`.
///
/// Actif en debug et profile uniquement ; silencieux en release. Ne jamais y
/// passer de données sensibles ni de contenu audio. Les catégories sont des
/// noms `homespotify.<catégorie>` filtrables dans la console Flutter.
const bool _loggingEnabled = kDebugMode || kProfileMode;

void _log(
  String category,
  String message, {
  Object? error,
  StackTrace? stackTrace,
}) {
  if (!_loggingEnabled) return;
  developer.log(
    message,
    name: 'homespotify.$category',
    error: error,
    stackTrace: stackTrace,
  );
}

/// Interactions UI (taps, menus, boutons).
void logUi(String message) => _log('ui', message);

/// Navigation (routes, push/pop, paramètres bruts/encodés/décodés).
void logNavigation(String message) => _log('nav', message);

/// Actions audio déclenchées par l'UI (play/pause/skip). Jamais la position
/// en continu — seulement les changements importants.
void logAudioAction(String message) => _log('audio', message);

/// Bibliothèque (chargement, recherche, tri, sélections).
void logLibrary(String message) => _log('library', message);

/// Réseau & session (jamais de token ni de mot de passe dans les messages).
void logNetwork(String message) => _log('network', message);

/// Erreurs, avec stacktrace complète.
void logError(String message, {Object? error, StackTrace? stackTrace}) =>
    _log('error', message, error: error, stackTrace: stackTrace);
