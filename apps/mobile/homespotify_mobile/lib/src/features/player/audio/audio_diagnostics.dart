import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

/// Journal audio structure, borne et exportable.
///
/// Le chemin critique de lecture n'attend jamais une ecriture disque : [log]
/// alimente un tampon memoire, puis un lot JSON Lines est vide en arriere-plan.
/// Les fichiers tournent automatiquement et aucune URL complete, aucun header
/// d'autorisation ni aucun token ne peut atteindre le journal.
class AudioDiagnostics with WidgetsBindingObserver {
  AudioDiagnostics._();

  static final AudioDiagnostics instance = AudioDiagnostics._();

  static const bool available =
      kDebugMode || bool.fromEnvironment('HOMESPOTIFY_AUDIO_DIAGNOSTICS');
  static const bool traceAvailable = bool.fromEnvironment(
    'HOMESPOTIFY_AUDIO_TRACE_AVAILABLE',
  );

  /// Compatibilite avec les ecrans developpeur existants.
  static bool get enabled => instance._enabled;

  static const int _normalCapacity = 2000;
  static const int _traceCapacity = 8000;
  static const int _normalMaxFiles = 5;
  static const int _traceMaxFiles = 10;
  static const int _normalMaxFileBytes = 5 * 1024 * 1024;
  static const int _traceMaxFileBytes = 10 * 1024 * 1024;
  static const Duration _flushInterval = Duration(milliseconds: 750);
  static const Duration _defaultTraceDuration = Duration(minutes: 15);
  static final RegExp _requestIdPattern = RegExp(r'^[A-Za-z0-9._:-]{1,96}$');
  static final RegExp _bearerPattern = RegExp(
    r'Bearer\s+[A-Za-z0-9._~+\-/]+=*',
    caseSensitive: false,
  );
  static final RegExp _embeddedUrlPattern = RegExp(
    r'https?://[^\s"<>]+',
    caseSensitive: false,
  );
  static final RegExp _windowsPathPattern = RegExp(r'[A-Za-z]:\\[^\s"<>]+');

  final Stopwatch _monotonicClock = Stopwatch()..start();
  final Random _random = Random.secure();
  final List<Map<String, Object?>> _buffer = <Map<String, Object?>>[];
  final List<String> _pendingLines = <String>[];
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  bool _enabled = available;
  bool _traceEnabled = false;
  int _sessionCounter = 0;
  int _queueRevisionCounter = 0;
  int _idCounter = 0;
  late final String appSessionId = nextId('app');
  String? _playbackSessionId;
  String? _queueRevisionId;
  Directory? _directory;
  Future<void>? _initialization;
  Future<void> _writeChain = Future<void>.value();
  Timer? _flushTimer;
  Timer? _traceTimer;

  bool get isTraceEnabled => _traceEnabled;
  int get sessionId => _sessionCounter;
  String? get playbackSessionId => _playbackSessionId;
  String? get queueRevisionId => _queueRevisionId;
  int get eventCount => _buffer.length;

  /// Appelee apres la premiere frame afin de ne jamais retarder le demarrage.
  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (!available) return;
    WidgetsBinding.instance.addObserver(this);
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}audio-diagnostics',
    );
    await directory.create(recursive: true);
    _directory = directory;
    log('APP_STARTED', {'diagnosticAvailable': available});
    await flush();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    log('APP_LIFECYCLE_CHANGED', {'state': state.name});
    if (state == AppLifecycleState.resumed) {
      log('APP_FOREGROUND');
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      log('APP_BACKGROUND', {'state': state.name});
      unawaited(flush());
    }
  }

  @override
  void didHaveMemoryPressure() {
    log('APP_MEMORY_PRESSURE');
    unawaited(flush());
  }

  int newSession() {
    _sessionCounter += 1;
    _playbackSessionId = nextId('playback');
    newQueueRevision();
    return _sessionCounter;
  }

  String newQueueRevision() {
    _queueRevisionCounter += 1;
    _queueRevisionId = 'queue-$_queueRevisionCounter-${_shortEntropy()}';
    return _queueRevisionId!;
  }

  String nextId(String prefix) {
    _idCounter += 1;
    return '$prefix-${_monotonicClock.elapsedMicroseconds.toRadixString(36)}-'
        '${_idCounter.toRadixString(36)}-${_shortEntropy()}';
  }

  String _shortEntropy() => _random.nextInt(0xFFFFFF).toRadixString(36);

  void setEnabled(bool value) {
    _enabled = available && value;
    if (!_enabled) {
      _traceEnabled = false;
      _traceTimer?.cancel();
      _traceTimer = null;
    }
    revision.value += 1;
  }

  void setTraceEnabled(
    bool value, {
    Duration duration = _defaultTraceDuration,
  }) {
    final canEnable = available && (kDebugMode || traceAvailable);
    _traceEnabled = value && canEnable;
    _traceTimer?.cancel();
    _traceTimer = null;
    if (_traceEnabled) {
      _enabled = true;
      _traceTimer = Timer(duration, () {
        _traceEnabled = false;
        log('AUDIO_TRACE_AUTO_DISABLED', {
          'durationMs': duration.inMilliseconds,
        });
        revision.value += 1;
      });
      log('AUDIO_TRACE_ENABLED', {'durationMs': duration.inMilliseconds});
    } else {
      log('AUDIO_TRACE_DISABLED');
    }
    revision.value += 1;
  }

  /// Enregistre un evenement sans jamais attendre le disque.
  void log(String event, [Map<String, Object?> fields = const {}]) {
    if (!_enabled) return;
    final normalizedEvent = event.trim().toUpperCase();
    final entry = <String, Object?>{
      'utc': DateTime.now().toUtc().toIso8601String(),
      'monotonicUs': _monotonicClock.elapsedMicroseconds,
      'level': _traceEnabled ? 'trace' : 'normal',
      'event': normalizedEvent,
      'appSessionId': appSessionId,
      if (_playbackSessionId != null) 'playbackSessionId': _playbackSessionId,
      if (_queueRevisionId != null) 'queueRevisionId': _queueRevisionId,
      'session': _sessionCounter,
      ..._sanitizeFields(fields),
    };
    _buffer.add(entry);
    final capacity = _traceEnabled ? _traceCapacity : _normalCapacity;
    if (_buffer.length > capacity) {
      _buffer.removeRange(0, _buffer.length - capacity);
    }
    final line = jsonEncode(entry);
    _pendingLines.add(line);
    _scheduleFlush();
    revision.value += 1;
    if (_traceEnabled || _shouldMirrorToConsole(normalizedEvent)) {
      debugPrint('[AUDIO] $line');
    }
  }

  static bool _shouldMirrorToConsole(String event) {
    return event.contains('ERROR') ||
        event.contains('FAILED') ||
        event.contains('ABORTED') ||
        event.contains('DISCONNECTED') ||
        event.contains('RECOVERY_STARTED') ||
        event == 'USER_MARKED_AUDIO_PROBLEM';
  }

  List<String> snapshot() => List<String>.unmodifiable(_buffer.map(jsonEncode));

  List<Map<String, Object?>> structuredSnapshot() =>
      List<Map<String, Object?>>.unmodifiable(
        _buffer.map((entry) => Map<String, Object?>.unmodifiable(entry)),
      );

  String export() => snapshot().join('\n');

  Map<String, Object?> summary() {
    final errors = _buffer.where((entry) {
      final event = entry['event']?.toString() ?? '';
      return event.contains('ERROR') ||
          event.contains('FAILED') ||
          event.contains('ABORTED');
    }).length;
    return <String, Object?>{
      'appSessionId': appSessionId,
      'playbackSessionId': _playbackSessionId,
      'queueRevisionId': _queueRevisionId,
      'diagnosticEnabled': _enabled,
      'traceEnabled': _traceEnabled,
      'eventCount': _buffer.length,
      'errorCount': errors,
      'monotonicMs': _monotonicClock.elapsedMilliseconds,
    };
  }

  /// Conserve le contexte deja present et force une trace de deux minutes afin
  /// de capturer egalement les evenements qui suivent le probleme.
  void markProblem({Map<String, Object?> context = const {}}) {
    log('USER_MARKED_AUDIO_PROBLEM', {
      'contextBeforeSeconds': 60,
      'contextAfterSeconds': 120,
      ...context,
    });
    if (kDebugMode || traceAvailable) {
      setTraceEnabled(true, duration: const Duration(minutes: 2));
    }
  }

  Future<String> exportToFile({
    Map<String, Object?> device = const {},
    Map<String, Object?> audioState = const {},
  }) async {
    await initialize();
    await flush();
    final directory = _directory;
    if (directory == null) {
      throw StateError('Le stockage des diagnostics est indisponible.');
    }
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}'
      'audio-diagnostic-export-$stamp.json',
    );
    final payload = <String, Object?>{
      'schemaVersion': 1,
      'generatedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'summary': summary(),
      'device': _sanitizeFields(device),
      'audioState': _sanitizeFields(audioState),
      'events': structuredSnapshot(),
    };
    await file.writeAsString(jsonEncode(payload), flush: true);
    return file.path;
  }

  Future<void> clear() async {
    _buffer.clear();
    _pendingLines.clear();
    final directory = _directory;
    if (directory != null && await directory.exists()) {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.startsWith('audio-diagnostics') ||
            name.startsWith('audio-diagnostic-export-')) {
          await entity.delete();
        }
      }
    }
    revision.value += 1;
  }

  void _scheduleFlush() {
    if (_directory == null || _flushTimer != null) return;
    _flushTimer = Timer(_flushInterval, () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  Future<void> flush() async {
    if (_directory == null || _pendingLines.isEmpty) return;
    final lines = List<String>.from(_pendingLines);
    _pendingLines.removeRange(0, lines.length);
    _writeChain = _writeChain.then((_) => _appendLines(lines));
    await _writeChain;
  }

  Future<void> _appendLines(List<String> lines) async {
    final directory = _directory;
    if (directory == null || lines.isEmpty) return;
    final encoded = '${lines.join('\n')}\n';
    final file = File(
      '${directory.path}${Platform.pathSeparator}audio-diagnostics.jsonl',
    );
    final maxBytes = _traceEnabled ? _traceMaxFileBytes : _normalMaxFileBytes;
    final currentBytes = await file.exists() ? await file.length() : 0;
    if (currentBytes + utf8.encode(encoded).length > maxBytes) {
      await _rotate(
        directory,
        _traceEnabled ? _traceMaxFiles : _normalMaxFiles,
      );
    }
    await file.writeAsString(encoded, mode: FileMode.append, flush: false);
  }

  Future<void> _rotate(Directory directory, int maxFiles) async {
    for (var index = maxFiles - 1; index >= 1; index--) {
      final sourceName = index == 1
          ? 'audio-diagnostics.jsonl'
          : 'audio-diagnostics.${index - 1}.jsonl';
      final targetName = 'audio-diagnostics.$index.jsonl';
      final source = File(
        '${directory.path}${Platform.pathSeparator}$sourceName',
      );
      if (!await source.exists()) continue;
      final target = File(
        '${directory.path}${Platform.pathSeparator}$targetName',
      );
      if (await target.exists()) await target.delete();
      await source.rename(target.path);
    }
  }

  static Map<String, Object?> _sanitizeFields(Map<String, Object?> fields) {
    final result = <String, Object?>{};
    for (final entry in fields.entries) {
      final key = entry.key;
      if (_isSecretKey(key)) {
        result[key] = '[redacted]';
        continue;
      }
      result[key] = _sanitizeValue(entry.value);
    }
    return result;
  }

  static bool _isSecretKey(String key) {
    final normalized = key.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    const safeTokenKeys = <String>{
      'tokenpresent',
      'tokenagems',
      'tokenexpiresinms',
      'authrefreshid',
    };
    if (safeTokenKeys.contains(normalized)) return false;
    return normalized == 'authorization' ||
        normalized.contains('accesstoken') ||
        normalized.contains('refreshtoken') ||
        normalized.contains('password') ||
        normalized.contains('cookie') ||
        normalized.contains('secret');
  }

  static Object? _sanitizeValue(Object? value) {
    if (value == null || value is num || value is bool) return value;
    if (value is Map) {
      return _sanitizeFields(
        value.map((key, nested) => MapEntry(key.toString(), nested)),
      );
    }
    if (value is Iterable) return value.map(_sanitizeValue).toList();
    var text = value.toString().replaceAll(_bearerPattern, 'Bearer [redacted]');
    text = text.replaceAllMapped(_embeddedUrlPattern, (match) {
      final uri = Uri.tryParse(match.group(0)!);
      return uri == null || uri.host.isEmpty
          ? '[url-redacted]'
          : '${uri.scheme}://${uri.host}/[redacted]';
    });
    text = text.replaceAll(_windowsPathPattern, '[path-redacted]');
    if (_requestIdPattern.hasMatch(text)) return text;
    final maxLength = instance._traceEnabled ? 1600 : 500;
    if (text.length > maxLength) text = '${text.substring(0, maxLength)}...';
    return text;
  }
}
