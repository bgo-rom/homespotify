/// Configuration réseau de l'application.
///
/// L'URL du serveur vient **exclusivement** de `--dart-define` — jamais d'IP
/// locale codée en dur :
///
///   flutter run --dart-define=HOMESPOTIFY_API_BASE_URL=http://192.168.1.153:3000
///
/// Accès distant (rien à changer dans le code, seul le define bouge) :
///
///   flutter run --dart-define=HOMESPOTIFY_API_BASE_URL=https://music.romainbegot.fr
///
/// La valeur réellement compilée reste la seule vérité affichée dans les
/// paramètres ; le code ne prétend jamais connaître l'état du déploiement.
abstract final class AppConfig {
  /// URL de base de l'API HomeSpotify.
  static const String apiBaseUrl = String.fromEnvironment(
    'HOMESPOTIFY_API_BASE_URL',
    // Défaut neutre (poste de dev) : le vrai téléphone et la prod passent
    // toujours par --dart-define.
    defaultValue: 'http://localhost:3000',
  );

  /// Message standard quand le serveur ne répond pas.
  static const String serverUnreachableMessage =
      'Serveur HomeSpotify inaccessible.';

  static Uri? get apiUri => Uri.tryParse(apiBaseUrl);

  static bool get usesTls => apiUri?.scheme.toLowerCase() == 'https';

  static bool get isLoopback {
    final host = apiUri?.host.toLowerCase();
    return host == null ||
        host.isEmpty ||
        host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1';
  }

  static bool get remoteAccessConfigured => usesTls && !isLoopback;
}
