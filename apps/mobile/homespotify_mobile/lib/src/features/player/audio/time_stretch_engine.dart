import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

/// Niveau de traitement sélectionné par la stratégie adaptative.
///
/// Ces valeurs restent internes : l'interface utilisateur ne présente pas le
/// nom d'un moteur ni une qualité non vérifiée sur l'appareil.
enum TimeStretchQualityMode {
  transparent,
  standard,
  enhanced,
  compatibilityFallback,
  safeFallback,
}

/// Contrat unique entre la file de lecture et le traitement de tempo.
///
/// Une implémentation native haute qualité peut remplacer le moteur de
/// compatibilité sans créer un second lecteur ni une file parallèle.
abstract interface class TimeStretchEngine {
  Future<void> initialize();

  bool get isAvailable;

  Future<void> setTempoRatio(double ratio);

  Future<double> getAppliedTempoRatio();

  Future<void> reset();

  Future<void> dispose();

  String get engineName;

  TimeStretchQualityMode get qualityMode;

  int get latencyMs;

  String? get lastError;
}

class TimeStretchEngineException implements Exception {
  const TimeStretchEngineException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Adaptateur du chemin Android actuellement fourni par just_audio/Media3.
///
/// `setSpeed` attend l'accusé de réception de la plateforme. La version
/// publique de just_audio ne fournit toutefois pas de lecture native séparée
/// de `ExoPlayer.getPlaybackParameters()`: [getAppliedTempoRatio] reflète donc
/// l'état confirmé par l'appel plateforme, sans prétendre être une mesure PCM.
class Media3TimeStretchEngine implements TimeStretchEngine {
  Media3TimeStretchEngine(this._player);

  static const _tolerance = 0.0001;

  final AudioPlayer _player;
  String? _lastError;
  var _qualityMode = TimeStretchQualityMode.transparent;

  @override
  Future<void> initialize() async {
    // Aucun chargement natif supplémentaire : just_audio initialise sa
    // plateforme paresseusement lors de la première lecture.
  }

  @override
  bool get isAvailable => true;

  @override
  Future<void> setTempoRatio(double ratio) async {
    final normalized = _validateRatio(ratio);
    try {
      // Always address this exact AudioPlayer instance, even when its cached
      // values already match. The Android fork uses setSpeed as the explicit
      // ownership handshake for the diagnostics/confirmation channel; skipping
      // it could leave a temporary audition player selected.
      await _player.setPitch(1);
      await _player.setSpeed(normalized);
      final applied = await getAppliedTempoRatio();
      if ((applied - normalized).abs() > _tolerance) {
        throw TimeStretchEngineException(
          'Le lecteur rapporte ${applied.toStringAsFixed(2)}x au lieu de '
          '${normalized.toStringAsFixed(2)}x.',
        );
      }
      _qualityMode = _media3Mode(normalized);
      _lastError = null;
    } catch (error) {
      _lastError = error.toString();
      rethrow;
    }
  }

  @override
  Future<double> getAppliedTempoRatio() async => _player.speed;

  bool get isPlaying => _player.playing;

  @override
  Future<void> reset() => setTempoRatio(1);

  @override
  Future<void> dispose() async {
    // Le HomeSpotifyAudioHandler reste propriétaire du lecteur.
  }

  @override
  String get engineName => 'Media3/Sonic';

  @override
  TimeStretchQualityMode get qualityMode => _qualityMode;

  @override
  int get latencyMs => 31;

  @override
  String? get lastError => _lastError;

  TimeStretchQualityMode _media3Mode(double ratio) {
    if ((ratio - 1).abs() <= 0.05) {
      return TimeStretchQualityMode.transparent;
    }
    return TimeStretchQualityMode.compatibilityFallback;
  }
}

enum HomeSpotifyStretchEngineMode { homeSpotifyStretch, media3Fallback }

class HomeSpotifyStretchStatus {
  const HomeSpotifyStretchStatus({
    required this.mode,
    required this.available,
    required this.active,
    required this.requestedRatio,
    required this.appliedRatio,
    required this.nativeAppliedRatio,
    required this.profile,
    required this.latencyMs,
    required this.pcmFramesProcessed,
    required this.averageDspMicros,
    required this.maximumDspMicros,
    required this.fallbackCount,
    required this.underrunCount,
    this.lastError,
  });

  factory HomeSpotifyStretchStatus.compatibility({
    double ratio = 1,
    String? lastError,
  }) => HomeSpotifyStretchStatus(
    mode: HomeSpotifyStretchEngineMode.media3Fallback,
    available: true,
    active: ratio != 1,
    requestedRatio: ratio,
    appliedRatio: ratio,
    nativeAppliedRatio: ratio,
    profile: 'COMPATIBILITY',
    latencyMs: 0,
    pcmFramesProcessed: 0,
    averageDspMicros: 0,
    maximumDspMicros: 0,
    fallbackCount: 0,
    underrunCount: 0,
    lastError: lastError,
  );

  factory HomeSpotifyStretchStatus.fromMap(Map<Object?, Object?> map) {
    double number(String key, [double fallback = 0]) =>
        (map[key] as num?)?.toDouble() ?? fallback;
    int integer(String key) => (map[key] as num?)?.toInt() ?? 0;
    final rawMode = map['engineMode']?.toString();
    final appliedRatio = number('appliedRatio', 1);
    return HomeSpotifyStretchStatus(
      mode: rawMode == 'HOMESPOTIFY_STRETCH'
          ? HomeSpotifyStretchEngineMode.homeSpotifyStretch
          : HomeSpotifyStretchEngineMode.media3Fallback,
      available: map['available'] as bool? ?? false,
      active: map['active'] as bool? ?? false,
      requestedRatio: number('requestedRatio', 1),
      appliedRatio: appliedRatio,
      nativeAppliedRatio: number('nativeAppliedRatio', appliedRatio),
      profile: map['profile']?.toString() ?? 'UNKNOWN',
      latencyMs: integer('latencyMs'),
      pcmFramesProcessed: integer('pcmFramesProcessed'),
      averageDspMicros: number('averageDspMicros'),
      maximumDspMicros: number('maxDspMicros'),
      fallbackCount: integer('fallbackCount'),
      underrunCount: integer('underrunCount'),
      lastError: map['lastError']?.toString(),
    );
  }

  final HomeSpotifyStretchEngineMode mode;
  final bool available;
  final bool active;
  final double requestedRatio;
  final double appliedRatio;
  final double nativeAppliedRatio;
  final String profile;
  final int latencyMs;
  final int pcmFramesProcessed;
  final double averageDspMicros;
  final double maximumDspMicros;
  final int fallbackCount;
  final int underrunCount;
  final String? lastError;
}

HomeSpotifyStretchStatus _latestHomeSpotifyStretchStatus =
    HomeSpotifyStretchStatus.compatibility();

HomeSpotifyStretchStatus get latestHomeSpotifyStretchStatus =>
    _latestHomeSpotifyStretchStatus;

String get currentTimeStretchQualityLabel {
  final status = _latestHomeSpotifyStretchStatus;
  return status.mode == HomeSpotifyStretchEngineMode.homeSpotifyStretch &&
          status.active &&
          status.pcmFramesProcessed > 0
      ? 'Qualité élevée'
      : 'Mode compatible';
}

/// Contrôle le pipeline Android Media3 unique. `AudioPlayer.setSpeed` conserve
/// le ratio logique dans just_audio, tandis que la chaîne native décide de
/// manière exclusive entre HomeSpotify Stretch et le fallback Media3.
class HomeSpotifyProductionTimeStretchEngine implements TimeStretchEngine {
  HomeSpotifyProductionTimeStretchEngine(
    AudioPlayer player, {
    this._channel = const MethodChannel('com.homespotify/stretch_engine'),
  }) : _transport = Media3TimeStretchEngine(player),
       super();

  static const _tolerance = 0.0001;
  static const _statusTimeout = Duration(milliseconds: 600);
  static const _pollInterval = Duration(milliseconds: 20);

  final Media3TimeStretchEngine _transport;
  final MethodChannel _channel;
  HomeSpotifyStretchStatus _status = HomeSpotifyStretchStatus.compatibility();

  bool get _usesAndroidNativePipeline =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<void> initialize() => _transport.initialize();

  @override
  bool get isAvailable => true;

  @override
  Future<void> setTempoRatio(double ratio) async {
    final normalized = _validateRatio(ratio);
    final previousPcmFrames = _status.pcmFramesProcessed;
    await _transport.setTempoRatio(normalized);
    if (!_usesAndroidNativePipeline) {
      _setStatus(HomeSpotifyStretchStatus.compatibility(ratio: normalized));
      return;
    }

    final deadline = DateTime.now().add(_statusTimeout);
    HomeSpotifyStretchStatus? observed;
    do {
      observed = await _readStatus(normalized);
      if (observed != null) {
        final configured =
            (observed.requestedRatio - normalized).abs() <= _tolerance &&
            (observed.appliedRatio - normalized).abs() <= _tolerance;
        final nativeConfirmed =
            (observed.nativeAppliedRatio - normalized).abs() <= _tolerance;
        final processedAfterRequest =
            observed.pcmFramesProcessed > previousPcmFrames;
        final canConfirmNative =
            normalized == 1 ||
            !_transport.isPlaying ||
            (processedAfterRequest && nativeConfirmed);
        if (configured &&
            (observed.mode == HomeSpotifyStretchEngineMode.media3Fallback ||
                canConfirmNative)) {
          _setStatus(observed);
          return;
        }
      }
      if (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(_pollInterval);
      }
    } while (DateTime.now().isBefore(deadline));

    if (observed != null &&
        observed.mode == HomeSpotifyStretchEngineMode.media3Fallback) {
      _setStatus(observed);
      return;
    }
    throw TimeStretchEngineException(
      'Le moteur Android n’a pas confirmé ${normalized.toStringAsFixed(2)}x.',
    );
  }

  Future<HomeSpotifyStretchStatus?> _readStatus(double ratio) async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>('getStatus');
      if (raw == null) return null;
      return HomeSpotifyStretchStatus.fromMap(raw);
    } on MissingPluginException catch (error) {
      return HomeSpotifyStretchStatus.compatibility(
        ratio: ratio,
        lastError: error.message,
      );
    } on PlatformException catch (error) {
      return HomeSpotifyStretchStatus.compatibility(
        ratio: ratio,
        lastError: error.message,
      );
    }
  }

  void _setStatus(HomeSpotifyStretchStatus value) {
    _status = value;
    _latestHomeSpotifyStretchStatus = value;
  }

  @override
  Future<double> getAppliedTempoRatio() async {
    if (_usesAndroidNativePipeline) {
      final refreshed = await _readStatus(_status.requestedRatio);
      if (refreshed != null) _setStatus(refreshed);
      return _status.appliedRatio;
    }
    return _transport.getAppliedTempoRatio();
  }

  @override
  Future<void> reset() => setTempoRatio(1);

  @override
  Future<void> dispose() => _transport.dispose();

  @override
  String get engineName =>
      _status.mode == HomeSpotifyStretchEngineMode.homeSpotifyStretch
      ? 'HomeSpotify Stretch Engine'
      : 'Media3 compatibility';

  @override
  TimeStretchQualityMode get qualityMode {
    if (_status.mode == HomeSpotifyStretchEngineMode.media3Fallback) {
      return _status.requestedRatio == 1
          ? TimeStretchQualityMode.transparent
          : TimeStretchQualityMode.compatibilityFallback;
    }
    return switch (_status.profile) {
      'TRANSPARENT' => TimeStretchQualityMode.transparent,
      'MUSICAL' => TimeStretchQualityMode.standard,
      _ => TimeStretchQualityMode.enhanced,
    };
  }

  @override
  int get latencyMs => _status.latencyMs;

  @override
  String? get lastError => _status.lastError;
}

/// Sélectionne un moteur faible latence près de 1.00x et, lorsqu'il est
/// réellement disponible, un moteur musical haute qualité hors de cette zone.
///
/// Le fallback est explicite : l'application ne qualifie jamais Sonic de
/// « haute qualité ». Une future implémentation native peut être injectée sans
/// modifier le handler, la queue ou la timeline.
class AdaptiveTimeStretchEngine implements TimeStretchEngine {
  AdaptiveTimeStretchEngine({
    required TimeStretchEngine lowLatencyEngine,
    this.highQualityEngine,
  }) : _lowLatencyEngine = lowLatencyEngine,
       _activeEngine = lowLatencyEngine;

  static const _transparentMin = 0.95;
  static const _transparentMax = 1.05;

  final TimeStretchEngine _lowLatencyEngine;
  final TimeStretchEngine? highQualityEngine;
  TimeStretchEngine _activeEngine;
  bool _initialized = false;
  String? _lastError;
  var _qualityMode = TimeStretchQualityMode.transparent;

  bool get isHighQualityAvailable => highQualityEngine?.isAvailable == true;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    await _lowLatencyEngine.initialize();
    _initialized = true;
  }

  @override
  bool get isAvailable => _lowLatencyEngine.isAvailable;

  @override
  Future<void> setTempoRatio(double ratio) async {
    final normalized = _validateRatio(ratio);
    await initialize();
    final preferred = _selectEngine(normalized);
    try {
      if (!identical(preferred, _activeEngine)) {
        await _activeEngine.reset();
        await preferred.initialize();
        _activeEngine = preferred;
      }
      await _activeEngine.setTempoRatio(normalized);
      _qualityMode = identical(_activeEngine, _lowLatencyEngine)
          ? _activeEngine.qualityMode
          : _highQualityMode(normalized);
      _lastError = null;
    } catch (error) {
      _lastError = error.toString();
      if (identical(preferred, _lowLatencyEngine)) rethrow;

      // Dégradation atomique : jamais deux traitements simultanés. En cas de
      // surcharge/échec du moteur renforcé, on le remet à zéro puis on revient
      // au chemin compatible au même ratio.
      await preferred.reset();
      _activeEngine = _lowLatencyEngine;
      await _lowLatencyEngine.setTempoRatio(normalized);
      _qualityMode = TimeStretchQualityMode.compatibilityFallback;
    }
  }

  @override
  Future<double> getAppliedTempoRatio() => _activeEngine.getAppliedTempoRatio();

  @override
  Future<void> reset() async {
    await initialize();
    if (!identical(_activeEngine, _lowLatencyEngine)) {
      await _activeEngine.reset();
      _activeEngine = _lowLatencyEngine;
    }
    await _lowLatencyEngine.reset();
    _qualityMode = TimeStretchQualityMode.transparent;
    _lastError = null;
  }

  @override
  Future<void> dispose() async {
    await highQualityEngine?.dispose();
    await _lowLatencyEngine.dispose();
  }

  @override
  String get engineName => _activeEngine.engineName;

  @override
  TimeStretchQualityMode get qualityMode => _qualityMode;

  @override
  int get latencyMs => _activeEngine.latencyMs;

  @override
  String? get lastError => _lastError ?? _activeEngine.lastError;

  TimeStretchEngine _selectEngine(double ratio) {
    final closeToOriginal =
        ratio >= _transparentMin && ratio <= _transparentMax;
    final highQuality = highQualityEngine;
    if (!closeToOriginal && highQuality?.isAvailable == true) {
      return highQuality!;
    }
    return _lowLatencyEngine;
  }

  TimeStretchQualityMode _highQualityMode(double ratio) {
    final moderate = ratio >= 0.85 && ratio <= 1.15;
    return moderate
        ? TimeStretchQualityMode.standard
        : TimeStretchQualityMode.enhanced;
  }
}

double _validateRatio(double ratio) {
  if (!ratio.isFinite || ratio < 0.7 || ratio > 1.3) {
    throw ArgumentError.value(
      ratio,
      'ratio',
      'La vitesse doit être comprise entre 0.70x et 1.30x.',
    );
  }
  return (ratio * 100).round() / 100;
}
