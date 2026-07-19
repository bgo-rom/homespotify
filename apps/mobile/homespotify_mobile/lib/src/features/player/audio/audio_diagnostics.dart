import 'package:flutter/foundation.dart';

/// Journal audio structuré pour diagnostiquer les sessions longues.
///
/// - Aucun secret : jamais de token, de header ou d'URL signée — uniquement
///   des identifiants internes de pistes, des index, des états et des
///   messages d'exception.
/// - Faible volume : événements de cycle de vie uniquement, jamais la
///   position à chaque milliseconde.
/// - Double sortie : Logcat (via debugPrint, préfixe `[AUDIO]`) et un tampon
///   circulaire en mémoire lisible depuis l'écran développeur, exportable par
///   copie dans le presse-papiers.
/// - Activé en debug, et en release uniquement avec
///   `--dart-define=HOMESPOTIFY_AUDIO_DIAGNOSTICS=true`.
class AudioDiagnostics {
  AudioDiagnostics._();

  static final AudioDiagnostics instance = AudioDiagnostics._();

  static const bool enabled =
      kDebugMode || bool.fromEnvironment('HOMESPOTIFY_AUDIO_DIAGNOSTICS');

  static const int _capacity = 400;

  final List<String> _buffer = <String>[];
  int _sessionCounter = 0;

  /// Identifiant de session audio courant (incrémenté à chaque nouvelle file).
  int get sessionId => _sessionCounter;

  int newSession() => ++_sessionCounter;

  /// Enregistre un événement structuré : `event champ=valeur ...`.
  void log(String event, [Map<String, Object?> fields = const {}]) {
    if (!enabled) return;
    final buffer = StringBuffer()
      ..write(DateTime.now().toIso8601String())
      ..write(' s=')
      ..write(_sessionCounter)
      ..write(' ')
      ..write(event);
    for (final entry in fields.entries) {
      final value = entry.value;
      if (value == null) continue;
      buffer
        ..write(' ')
        ..write(entry.key)
        ..write('=')
        ..write(_sanitize(value.toString()));
    }
    final line = buffer.toString();
    _buffer.add(line);
    if (_buffer.length > _capacity) {
      _buffer.removeRange(0, _buffer.length - _capacity);
    }
    debugPrint('[AUDIO] $line');
  }

  /// Copie immuable du tampon (du plus ancien au plus récent).
  List<String> snapshot() => List<String>.unmodifiable(_buffer);

  String export() => _buffer.join('\n');

  void clear() => _buffer.clear();

  /// Défense en profondeur : aucun Bearer ne doit exister dans les messages,
  /// mais si un texte d'exception en contenait un, il est caviardé.
  static String _sanitize(String value) {
    var sanitized = value.replaceAll(
      RegExp('Bearer [A-Za-z0-9._~+/-]+=*', caseSensitive: false),
      'Bearer [caviardé]',
    );
    // Les espaces cassent le format clé=valeur ; on les remplace pour garder
    // des lignes greppables tout en restant lisibles.
    if (sanitized.length > 300) {
      sanitized = '${sanitized.substring(0, 300)}…';
    }
    return sanitized;
  }
}
