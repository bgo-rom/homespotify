/// Configuration réseau de l'application.
///
/// L'URL du serveur vient **exclusivement** de `--dart-define` — jamais d'IP
/// locale codée en dur :
///
///   flutter run --dart-define=HOMESPOTIFY_API_BASE_URL=http://192.168.1.153:3000
///
/// Accès distant prévu (rien à changer dans le code, seul le define bouge) :
///
///   flutter run --dart-define=HOMESPOTIFY_API_BASE_URL=https://music.romainbegot.fr
///
/// Architecture cible : mini-PC Windows (backend + SQLite + WAV/FLAC) derrière
/// un tunnel WireGuard privé vers un VPS OVH (reverse proxy HTTPS +
/// authentification) — aucun port local exposé sur la box. Non déployé pour
/// l'instant.
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
}
