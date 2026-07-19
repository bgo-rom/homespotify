import 'dart:async';
import 'dart:developer' as developer;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../data/playback_settings_api.dart';
import 'audio_diagnostics.dart';
import 'time_stretch_engine.dart';

final audioHandlerProvider = Provider<HomeSpotifyAudioHandler>((ref) {
  throw StateError('audioHandlerProvider must be overridden at startup.');
});

void _debugAudioLog(String message, {Object? error, StackTrace? stackTrace}) {
  if (!kDebugMode) return;
  developer.log(
    message,
    name: 'homespotify.audio',
    error: error,
    stackTrace: stackTrace,
  );
}

void _traceArtwork(String message) {
  if (kDebugMode) debugPrint('[ARTWORK_TRACE] $message');
}

class _DefaultPlaybackSettingsRepository implements PlaybackSettingsRepository {
  const _DefaultPlaybackSettingsRepository();

  @override
  Future<TrackPlaybackSettings> fetch(int trackId) async =>
      TrackPlaybackSettings(
        trackId: trackId,
        speedRatio: 1,
        preservePitch: true,
        isDefault: true,
      );

  @override
  Future<TrackPlaybackSettings> save(int trackId, double speedRatio) async =>
      TrackPlaybackSettings(
        trackId: trackId,
        speedRatio: speedRatio,
        preservePitch: true,
        isDefault: false,
      );

  @override
  Future<void> reset(int trackId) async {}

  @override
  Future<TrackAudioAnalysis> fetchAnalysis(int trackId) async =>
      TrackAudioAnalysis(trackId: trackId, status: 'PENDING');
}

/// Métadonnées et URL natives d'une entrée de file audio.
///
/// Aucune donnée audio n'est conservée ici : [streamUri] est l'URL du fichier
/// original servi par le backend, que just_audio lit progressivement.
class PlayerQueueItem {
  const PlayerQueueItem({
    required this.id,
    required this.streamUri,
    required this.title,
    this.userId,
    this.artist,
    this.album,
    this.artUri,
    this.duration,
    this.mimeType,
    this.extension,
    this.sampleRate,
    this.bitDepth,
    this.channels,
    this.bitrate,
    this.fileSize,
    this.origin = 'Bibliothèque',
    this.artistKey,
    this.albumKey,
    this.headers,
    this.artworkIdentity,
  });

  final String id;
  final int? userId;
  final Uri streamUri;
  final String title;
  final String? artist;
  final String? album;
  final Uri? artUri;
  final Duration? duration;
  final String? mimeType;
  final String? extension;
  final int? sampleRate;
  final int? bitDepth;
  final int? channels;
  final int? bitrate;
  final int? fileSize;
  final String origin;
  final String? artistKey;
  final String? albumKey;
  final Map<String, String>? headers;
  final String? artworkIdentity;

  String get format {
    final normalizedExtension = extension?.replaceFirst('.', '').trim();
    if (normalizedExtension != null && normalizedExtension.isNotEmpty) {
      return normalizedExtension.toUpperCase();
    }
    return switch (mimeType) {
      'audio/wav' => 'WAV',
      'audio/flac' => 'FLAC',
      _ => 'inconnu',
    };
  }

  MediaItem toMediaItem({
    bool includeArtwork = true,
    Uri? artworkUri,
    Duration? resolvedDuration,
    double speedRatio = 1,
  }) {
    return MediaItem(
      id: id,
      title: title,
      artist: artist,
      album: album,
      artUri: includeArtwork ? (artworkUri ?? artUri) : null,
      duration: resolvedDuration ?? duration,
      extras: <String, dynamic>{
        'streamUri': streamUri.toString(),
        if (mimeType != null) 'mimeType': mimeType,
        if (extension != null) 'extension': extension,
        'format': format,
        if (sampleRate != null && sampleRate! > 0) 'sampleRate': sampleRate,
        if (bitDepth != null && bitDepth! > 0) 'bitDepth': bitDepth,
        if (channels != null && channels! > 0) 'channels': channels,
        if (bitrate != null && bitrate! > 0) 'bitrate': bitrate,
        if (fileSize != null && fileSize! > 0) 'fileSize': fileSize,
        'origin': origin,
        if (artistKey != null) 'artistKey': artistKey,
        if (albumKey != null) 'albumKey': albumKey,
        'speedRatio': speedRatio,
      },
    );
  }

  AudioSource toAudioSource() {
    return AudioSource.uri(
      streamUri,
      headers: headers,
      tag: toMediaItem(includeArtwork: false),
    );
  }

  PlayerQueueItem copyWithHeaders(Map<String, String>? value) {
    return PlayerQueueItem(
      id: id,
      userId: userId,
      streamUri: streamUri,
      title: title,
      artist: artist,
      album: album,
      artUri: artUri,
      duration: duration,
      mimeType: mimeType,
      extension: extension,
      sampleRate: sampleRate,
      bitDepth: bitDepth,
      channels: channels,
      bitrate: bitrate,
      fileSize: fileSize,
      origin: origin,
      artistKey: artistKey,
      albumKey: albumKey,
      headers: value == null || value.isEmpty ? null : value,
      artworkIdentity: artworkIdentity,
    );
  }
}

/// Erreur de lecture présentable sans exposer les détails natifs à l'UI.
class AudioPlaybackException implements Exception {
  const AudioPlaybackException(this.userMessage);

  final String userMessage;

  @override
  String toString() => userMessage;
}

/// Le lecteur n'a pas accepté ou confirmé le ratio demandé.
class TrackSpeedApplyException implements Exception {
  const TrackSpeedApplyException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// Le ratio est appliqué à l'écoute active, mais sa préférence n'a pas été
/// enregistrée. L'UI peut proposer un nouvel essai sans réappliquer l'audio.
class TrackSpeedPersistenceException implements Exception {
  const TrackSpeedPersistenceException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// Instantané combiné position / tampon / durée du lecteur.
///
/// `playbackState` n'émet une position que sur événement ; pour une barre de
/// progression fluide il faut le flux continu `positionStream` de just_audio.
class PlayerPositionData {
  const PlayerPositionData({
    required this.position,
    required this.bufferedPosition,
    required this.duration,
  });

  final Duration position;
  final Duration bufferedPosition;
  final Duration duration;

  static const PlayerPositionData zero = PlayerPositionData(
    position: Duration.zero,
    bufferedPosition: Duration.zero,
    duration: Duration.zero,
  );
}

/// combineLatest à 3 sources, sans dépendre de rxdart (non déclaré en direct).
/// Émet dès que les trois sources ont produit au moins une valeur.
Stream<R> _combineLatest3<A, B, C, R>(
  Stream<A> a,
  Stream<B> b,
  Stream<C> c,
  R Function(A, B, C) combine,
) {
  late StreamController<R> controller;
  late StreamSubscription<A> subA;
  late StreamSubscription<B> subB;
  late StreamSubscription<C> subC;

  A? lastA;
  B? lastB;
  C? lastC;
  var hasA = false;
  var hasB = false;
  var hasC = false;

  void emit() {
    if (hasA && hasB && hasC) {
      controller.add(combine(lastA as A, lastB as B, lastC as C));
    }
  }

  controller = StreamController<R>(
    onListen: () {
      subA = a.listen((value) {
        lastA = value;
        hasA = true;
        emit();
      }, onError: controller.addError);
      subB = b.listen((value) {
        lastB = value;
        hasB = true;
        emit();
      }, onError: controller.addError);
      subC = c.listen((value) {
        lastC = value;
        hasC = true;
        emit();
      }, onError: controller.addError);
    },
    onCancel: () async {
      await subA.cancel();
      await subB.cancel();
      await subC.cancel();
    },
  );

  return controller.stream;
}

class HomeSpotifyAudioHandler extends BaseAudioHandler with SeekHandler {
  HomeSpotifyAudioHandler({
    AudioPlayer? player,
    PlaybackSettingsRepository? playbackSettingsRepository,
    Future<void>? audioSessionSetup,
    TimeStretchEngine? timeStretchEngine,
    this._authorizationRefresh,
    this._currentAuthorizationHeaders,
    this._artworkResolver,
    this._artworkCacheClear,
    DateTime Function()? clock,
    Duration recoveryCooldown = const Duration(seconds: 30),
  }) : _clock = clock ?? DateTime.now,
       _authorizationRecoveryCooldown = recoveryCooldown,
       _player =
           player ??
           AudioPlayer(
             // Flux authentifiés : Android doit envoyer le header Bearer
             // directement au serveur HTTPS. Le proxy localhost de just_audio
             // exige du cleartext, bloqué en release (voir manifest debug).
             useProxyForRequestHeaders: false,
             audioLoadConfiguration: const AudioLoadConfiguration(
               androidLoadControl: AndroidLoadControl(
                 minBufferDuration: Duration(seconds: 30),
                 maxBufferDuration: Duration(seconds: 120),
                 bufferForPlaybackDuration: Duration(milliseconds: 2500),
                 bufferForPlaybackAfterRebufferDuration: Duration(seconds: 5),
                 prioritizeTimeOverSizeThresholds: true,
               ),
             ),
           ),
       _playbackSettingsRepository =
           playbackSettingsRepository ??
           const _DefaultPlaybackSettingsRepository(),
       _providedAudioSessionSetup = audioSessionSetup {
    _timeStretchEngine =
        timeStretchEngine ?? HomeSpotifyProductionTimeStretchEngine(_player);
    // Aucun appel natif dans le constructeur : volume/session ne sont
    // initialisés qu'à la première demande de lecture.
    _playbackEventSubscription = _player.playbackEventStream.listen(
      _broadcastPlaybackState,
      onError: _broadcastPlaybackError,
    );
    _playerStateSubscription = _player.playerStateStream.listen((_) {
      _broadcastPlaybackState(_player.playbackEvent);
    });
    _currentIndexSubscription = _player.currentIndexStream.listen(
      _onCurrentIndexChanged,
    );
  }

  final AudioPlayer _player;
  final PlaybackSettingsRepository _playbackSettingsRepository;
  late final TimeStretchEngine _timeStretchEngine;
  final List<PlayerQueueItem> _queueItems = <PlayerQueueItem>[];
  final Map<int, double> _trackSpeedCache = <int, double>{};
  final Map<int, double> _sessionOnlyTrackSpeeds = <int, double>{};
  final Set<int> _speedWritesInFlight = <int>{};

  final Future<void>? _providedAudioSessionSetup;
  final Future<bool> Function()? _authorizationRefresh;
  final Map<String, String> Function()? _currentAuthorizationHeaders;
  final Future<Uri?> Function(PlayerQueueItem item)? _artworkResolver;
  final Future<void> Function()? _artworkCacheClear;
  Future<void>? _playbackSetup;
  late final StreamSubscription<PlaybackEvent> _playbackEventSubscription;
  late final StreamSubscription<PlayerState> _playerStateSubscription;
  late final StreamSubscription<int?> _currentIndexSubscription;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;

  final DateTime Function() _clock;
  final Duration _authorizationRecoveryCooldown;

  int _loadRequest = 0;
  DateTime? _lastAuthorizationRecoveryAttemptAt;
  Future<bool>? _authorizationRecoveryInFlight;
  int _consecutiveErrorSkips = 0;
  DateTime? _lastErrorSkipAt;
  int? _lastStartedIndex;
  static const int _maxConsecutiveErrorSkips = 3;
  // Le compteur de sauts ne se réarme qu'après une lecture réellement stable :
  // sans ce délai, une file entièrement cassée en repeat-all (chaque piste
  // « démarre » puis meurt aussitôt) tournerait indéfiniment.
  static const Duration _errorSkipCounterResetDelay = Duration(seconds: 5);
  int _artworkRequest = 0;
  String? _resolvedArtworkTrackId;
  Uri? _resolvedArtworkUri;
  int _speedApplyRequest = 0;
  int? _speedScheduledTrackId;
  int? _currentQueueIndex;
  bool _sourceReady = false;
  bool _playbackRequested = false;
  AudioServiceRepeatMode _repeatMode = AudioServiceRepeatMode.none;
  ProcessingState? _lastLoggedProcessingState;
  String? _publishedMediaKey;

  /// Prépare puis démarre atomiquement une file de lecture.
  ///
  /// `setAudioSources` initialise seulement la piste demandée ; la file elle-
  /// même reste une liste de sources distantes, jamais des fichiers chargés en
  /// mémoire. Un second tap remplace proprement la demande précédente.
  Future<void> setQueueAndPlay({
    required List<PlayerQueueItem> items,
    required int initialIndex,
  }) async {
    if (items.isEmpty) {
      throw ArgumentError.value(
        items,
        'items',
        'La file ne peut pas être vide.',
      );
    }
    if (initialIndex < 0 || initialIndex >= items.length) {
      throw RangeError.index(initialIndex, items, 'initialIndex');
    }

    final request = ++_loadRequest;
    _lastAuthorizationRecoveryAttemptAt = null;
    _authorizationRecoveryInFlight = null;
    _consecutiveErrorSkips = 0;
    _lastErrorSkipAt = null;
    _lastStartedIndex = null;
    AudioDiagnostics.instance.newSession();
    AudioDiagnostics.instance.log('AUDIO_QUEUE_CREATED', {
      'size': items.length,
      'index': initialIndex,
      'track': items[initialIndex].id,
    });
    ++_artworkRequest;
    _resolvedArtworkTrackId = null;
    _resolvedArtworkUri = null;
    _speedScheduledTrackId = null;
    final immutableItems = List<PlayerQueueItem>.unmodifiable(items);
    final initialItem = immutableItems[initialIndex];

    try {
      await _ensurePlaybackReady();
      if (request != _loadRequest) return;

      _queueItems
        ..clear()
        ..addAll(immutableItems);
      _currentQueueIndex = initialIndex;
      _sourceReady = false;
      _publishedMediaKey = null;

      // audio_service expose la file complète au lockscreen/notification.
      _publishQueue();
      queueTitle.add('File d’attente');
      _publishCurrentMediaItem(includeArtwork: false);
      _publishLoadingState(initialIndex);

      _debugAudioLog(
        'préparation queue track=${initialItem.id} index=$initialIndex '
        'size=${immutableItems.length} streamUri=${initialItem.streamUri} '
        'format=${initialItem.format} mimeType=${initialItem.mimeType ?? 'inconnu'} '
        'volume=${_player.volume}',
      );

      await _player.pause();
      if (request != _loadRequest) return;

      _debugAudioLog(
        'début setAudioSources track=${initialItem.id} '
        'state=${_player.processingState.name} '
        'buffered=${_player.bufferedPosition}',
      );
      AudioDiagnostics.instance.log('AUDIO_SOURCE_LOAD_STARTED', {
        'track': initialItem.id,
        'index': initialIndex,
        'size': immutableItems.length,
      });
      final loadedDuration = await _setAudioSourcesWithAuthorizationRecovery(
        request: request,
        initialIndex: initialIndex,
        initialPosition: Duration.zero,
        preload: true,
      );
      if (request != _loadRequest) return;

      _sourceReady = true;
      _currentQueueIndex = _player.currentIndex ?? initialIndex;
      AudioDiagnostics.instance.log('AUDIO_SOURCE_LOAD_COMPLETED', {
        'track': initialItem.id,
        'seq': _player.sequence.length,
        'durationMs': loadedDuration?.inMilliseconds,
      });
      _publishCurrentMediaItem(
        includeArtwork: true,
        resolvedDuration: loadedDuration,
      );
      _debugAudioLog(
        'fin setAudioSources track=${initialItem.id} '
        'returnedDuration=${loadedDuration ?? initialItem.duration ?? 'inconnue'} '
        'state=${_player.processingState.name} '
        'buffered=${_player.bufferedPosition} '
        'volume=${_player.volume}',
      );
      _broadcastPlaybackState(_player.playbackEvent);
      _scheduleCurrentTrackSpeed();

      // Le Future de `AudioPlayer.play()` ne se résout qu'à la pause, au stop
      // ou à la fin de la piste — jamais au démarrage. L'attendre ici
      // suspendrait l'appelant (donc l'UI bibliothèque) pendant toute la
      // lecture. On démarre sans attendre ; les erreurs de démarrage suivent
      // le même chemin que les erreurs d'événement (voir L-017).
      unawaited(
        _startPlayback().catchError((Object error, StackTrace stackTrace) {
          if (request != _loadRequest) return;
          _handleAsynchronousPlaybackFailure(request, error, stackTrace);
        }),
      );
    } on PlayerInterruptedException catch (error, stackTrace) {
      if (request != _loadRequest) {
        _debugAudioLog(
          'préparation remplacée track=${initialItem.id}',
          error: error,
          stackTrace: stackTrace,
        );
        return;
      }
      _recordPlaybackFailure(initialItem, error, stackTrace);
      throw AudioPlaybackException(_friendlyAudioError(error));
    } catch (error, stackTrace) {
      if (request != _loadRequest) return;
      _recordPlaybackFailure(initialItem, error, stackTrace);
      if (error is AudioPlaybackException) rethrow;
      throw AudioPlaybackException(_friendlyAudioError(error));
    }
  }

  /// Volume interne du lecteur (0.0–1.0), sans boost applicatif.
  double get volume => _player.volume;

  Stream<double> get volumeStream => _player.volumeStream;

  double get currentTrackSpeed => _player.speed;

  double get currentPitch => _player.pitch;

  TimeStretchQualityMode get currentTimeStretchQualityMode =>
      _timeStretchEngine.qualityMode;

  String get currentTimeStretchEngineName => _timeStretchEngine.engineName;

  int get currentTimeStretchLatencyMs => _timeStretchEngine.latencyMs;

  HomeSpotifyStretchStatus get currentTimeStretchStatus =>
      latestHomeSpotifyStretchStatus;

  Future<void> setVolume(double volume) {
    return _player.setVolume(volume.clamp(0.0, 1.0).toDouble());
  }

  Future<void> setTrackSpeed(int trackId, double ratio) async {
    final normalized = _normalizeSpeedRatio(ratio);
    // Une action utilisateur invalide immédiatement le chargement paresseux
    // démarré au changement de piste : sa réponse 1.00x ne doit jamais écraser
    // le ratio qui vient d'être confirmé manuellement.
    ++_speedApplyRequest;
    if (!_speedWritesInFlight.add(trackId)) {
      throw const TrackSpeedPersistenceException(
        'Une application de vitesse est déjà en cours.',
      );
    }
    final currentId = _currentTrackId;
    try {
      if (currentId == trackId) {
        final previous = await _timeStretchEngine.getAppliedTempoRatio();
        _debugAudioLog(
          'vitesse application track=$trackId demandée=$normalized '
          'précédente=$previous active=true',
        );
        try {
          await _applyConfirmedSpeed(normalized);
        } catch (error, stackTrace) {
          _debugAudioLog(
            'application moteur impossible track=$trackId ratio=$normalized',
            error: error,
            stackTrace: stackTrace,
          );
          try {
            await _applyConfirmedSpeed(previous);
          } catch (rollbackError, rollbackStackTrace) {
            _debugAudioLog(
              'rollback vitesse impossible track=$trackId ratio=$previous',
              error: rollbackError,
              stackTrace: rollbackStackTrace,
            );
          }
          throw TrackSpeedApplyException(
            'La vitesse n’a pas pu être appliquée au lecteur.',
            cause: error,
          );
        }
      }

      try {
        final saved = await _playbackSettingsRepository.save(
          trackId,
          normalized,
        );
        if (!saved.preservePitch) {
          throw StateError('Contrat de réglage audio invalide.');
        }
        final persisted = _normalizeSpeedRatio(saved.speedRatio);
        if ((persisted - normalized).abs() > 0.0001) {
          throw StateError(
            'Le backend a enregistré un ratio différent ($persisted).',
          );
        }
        _trackSpeedCache[trackId] = persisted;
        _sessionOnlyTrackSpeeds.remove(trackId);
        _publishQueue();
        _debugAudioLog(
          'vitesse enregistrée track=$trackId ratio=$persisted '
          'active=${_currentTrackId == trackId} '
          'lecteur=${_player.speed}',
        );
      } catch (error, stackTrace) {
        if (_currentTrackId == trackId) {
          _sessionOnlyTrackSpeeds[trackId] = normalized;
          _debugAudioLog(
            'vitesse appliquée non enregistrée track=$trackId '
            'ratio=$normalized lecteur=${_player.speed}',
            error: error,
            stackTrace: stackTrace,
          );
        }
        throw TrackSpeedPersistenceException(
          _currentTrackId == trackId
              ? 'Vitesse appliquée, mais non enregistrée.'
              : 'La préférence de vitesse n’a pas pu être enregistrée.',
          cause: error,
        );
      }
    } finally {
      _speedWritesInFlight.remove(trackId);
    }
  }

  Future<void> resetTrackSpeed(int trackId) async {
    ++_speedApplyRequest;
    if (!_speedWritesInFlight.add(trackId)) {
      throw const TrackSpeedPersistenceException(
        'Une application de vitesse est déjà en cours.',
      );
    }
    final isActive = _currentTrackId == trackId;
    try {
      if (isActive) {
        final previous = await _timeStretchEngine.getAppliedTempoRatio();
        try {
          await _applyConfirmedSpeed(1);
        } catch (error) {
          try {
            await _applyConfirmedSpeed(previous);
          } catch (rollbackError, rollbackStackTrace) {
            _debugAudioLog(
              'rollback reset vitesse impossible track=$trackId '
              'ratio=$previous',
              error: rollbackError,
              stackTrace: rollbackStackTrace,
            );
          }
          throw TrackSpeedApplyException(
            'La vitesse n’a pas pu être réinitialisée dans le lecteur.',
            cause: error,
          );
        }
      }

      try {
        await _playbackSettingsRepository.reset(trackId);
        _trackSpeedCache.remove(trackId);
        _sessionOnlyTrackSpeeds.remove(trackId);
        _publishQueue();
      } catch (error) {
        if (isActive) _sessionOnlyTrackSpeeds[trackId] = 1;
        throw TrackSpeedPersistenceException(
          isActive
              ? 'Vitesse réinitialisée, mais préférence non enregistrée.'
              : 'La préférence de vitesse n’a pas pu être réinitialisée.',
          cause: error,
        );
      }
    } finally {
      _speedWritesInFlight.remove(trackId);
    }
  }

  /// Audition en mémoire uniquement : aucune persistance tant que l'utilisateur
  /// n'a pas confirmé la feuille de vitesse.
  Future<void> previewTrackSpeed(int trackId, double ratio) async {
    if (_currentTrackId != trackId) return;
    ++_speedApplyRequest;
    try {
      await _applyConfirmedSpeed(_normalizeSpeedRatio(ratio));
    } catch (error) {
      throw TrackSpeedApplyException(
        'La vitesse n’a pas pu être appliquée au lecteur.',
        cause: error,
      );
    }
  }

  /// Réinitialise d'abord à 1.00x, puis applique le réglage du compte courant.
  /// Le reset immédiat garantit qu'une piste sans réglage n'hérite jamais de
  /// la vitesse de la piste précédente.
  Future<void> applyCurrentTrackSpeed() async {
    final request = ++_speedApplyRequest;
    final trackId = _currentTrackId;
    await _applyConfirmedSpeed(1.0);
    if (request != _speedApplyRequest || trackId == null) return;

    double ratio;
    final cached = _trackSpeedCache[trackId];
    if (cached != null) {
      ratio = cached;
    } else {
      try {
        final setting = await _playbackSettingsRepository
            .fetch(trackId)
            .timeout(const Duration(seconds: 2));
        if (!setting.preservePitch) {
          throw StateError('Réglage sans préservation de tonalité refusé.');
        }
        ratio = _normalizeSpeedRatio(setting.speedRatio);
        _trackSpeedCache[trackId] = ratio;
        _publishQueue();
      } catch (error, stackTrace) {
        _debugAudioLog(
          'réglage vitesse indisponible track=$trackId, défaut 1.00x',
          error: error,
          stackTrace: stackTrace,
        );
        ratio = 1.0;
      }
    }
    if (request != _speedApplyRequest || _currentTrackId != trackId) return;
    await _applyConfirmedSpeed(ratio);
  }

  @override
  Future<void> play() async {
    if (_queueItems.isEmpty) return;
    await _ensurePlaybackReady();
    if (!_sourceReady) {
      throw const AudioPlaybackException('Source audio inaccessible.');
    }
    try {
      await _startPlayback();
    } catch (error, stackTrace) {
      final item = _currentItem;
      if (item != null) _recordPlaybackFailure(item, error, stackTrace);
      if (error is AudioPlaybackException) rethrow;
      throw AudioPlaybackException(_friendlyAudioError(error));
    }
  }

  @override
  Future<void> pause() {
    _playbackRequested = false;
    return _player.pause();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() async {
    final target = _relativeQueueIndex(1);
    if (target == null) return;
    await skipToQueueItem(target);
  }

  @override
  Future<void> skipToPrevious() async {
    final target = _relativeQueueIndex(-1);
    if (target == null) return;
    await skipToQueueItem(target);
  }

  /// Index de la piste à `offset` pas dans l'ordre de lecture **effectif** :
  /// ordre shuffle de just_audio si actif, séquentiel sinon ; boucle sur la
  /// file si répétition « toute la file ». Retourne null s'il n'y a rien à
  /// atteindre (bornes de la file sans répétition).
  ///
  /// Calculé ici plutôt que via `_player.nextIndex/previousIndex` : just_audio
  /// y renvoie l'index courant en `LoopMode.one`, ce qui casserait le
  /// précédent/suivant explicite pendant une répétition de piste.
  int? _relativeQueueIndex(int offset) {
    if (!_sourceReady) return null;
    final current = _activeQueueIndex;
    if (current == null || _queueItems.length < 2) return null;
    final order = _player.shuffleModeEnabled
        ? _player.shuffleIndices
        : List<int>.generate(_queueItems.length, (i) => i);
    final position = order.indexOf(current);
    if (position == -1) return null;
    var target = position + offset;
    if (target < 0 || target >= order.length) {
      if (_repeatMode != AudioServiceRepeatMode.all) return null;
      target %= order.length;
    }
    return order[target];
  }

  /// Active/désactive l'ordre aléatoire de la file courante. Ne change que
  /// l'ordre de lecture — aucun traitement du signal audio.
  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final enabled = shuffleMode != AudioServiceShuffleMode.none;
    _debugAudioLog('shuffle ${enabled ? 'activé' : 'désactivé'}');
    // Nouveau tirage à chaque activation (la piste courante reste en tête).
    if (enabled) await _player.shuffle();
    await _player.setShuffleModeEnabled(enabled);
    playbackState.add(
      playbackState.value.copyWith(
        shuffleMode: enabled
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
      ),
    );
  }

  /// Mode de répétition : aucune / toute la file / piste courante. Ne change
  /// que l'ordre de lecture — aucun traitement du signal audio.
  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    final normalized = switch (repeatMode) {
      AudioServiceRepeatMode.one => AudioServiceRepeatMode.one,
      AudioServiceRepeatMode.all ||
      AudioServiceRepeatMode.group => AudioServiceRepeatMode.all,
      AudioServiceRepeatMode.none => AudioServiceRepeatMode.none,
    };
    _repeatMode = normalized;
    _debugAudioLog('repeat mode: ${normalized.name}');
    await _player.setLoopMode(switch (normalized) {
      AudioServiceRepeatMode.one => LoopMode.one,
      AudioServiceRepeatMode.all => LoopMode.all,
      _ => LoopMode.off,
    });
    playbackState.add(playbackState.value.copyWith(repeatMode: normalized));
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (!_sourceReady || index < 0 || index >= _queueItems.length) return;
    final item = _queueItems[index];
    _currentQueueIndex = index;
    _publishCurrentMediaItem(includeArtwork: false);
    _debugAudioLog(
      'saut queue track=${item.id} index=$index streamUri=${item.streamUri} '
      'format=${item.format} mimeType=${item.mimeType ?? 'inconnu'} '
      'repeat=${_repeatMode.name} shuffle=${_player.shuffleModeEnabled}',
    );
    try {
      ++_speedApplyRequest;
      await _applyConfirmedSpeed(1.0);
      // Répétition de piste : désarmer la boucle le temps du saut manuel,
      // puis la réarmer sur la nouvelle piste. Sinon, selon l'état natif,
      // le lecteur peut rester ancré sur l'ancienne piste et la ramener en
      // boucle alors que l'UI affiche la nouvelle (L-021). Le mode repeat-one
      // reste actif : seule la piste répétée change.
      final repeatOne = _repeatMode == AudioServiceRepeatMode.one;
      if (repeatOne) await _player.setLoopMode(LoopMode.off);
      await _player.seek(Duration.zero, index: index);
      if (repeatOne) await _player.setLoopMode(LoopMode.one);
      // Resynchronise sur l'index effectif du lecteur puis republie
      // mediaItem + queueIndex : la piste répétée est bien la nouvelle.
      _currentQueueIndex = _player.currentIndex ?? index;
      _publishedMediaKey = null;
      _publishCurrentMediaItem(includeArtwork: false);
      _broadcastPlaybackState(_player.playbackEvent);
    } catch (error, stackTrace) {
      _recordPlaybackFailure(item, error, stackTrace);
      throw AudioPlaybackException(_friendlyAudioError(error));
    }
  }

  /// Insère une piste juste après la piste courante, sans interrompre ni
  /// redémarrer celle-ci. La file publiée par audio_service reste la source de
  /// vérité unique pour toutes les interfaces.
  Future<void> playNext(PlayerQueueItem item) async {
    final current = _activeQueueIndex;
    final index = current == null ? _queueItems.length : current + 1;
    await _insertQueueItem(index, item);
  }

  /// Ajoute une piste à la fin de la file sans lancer automatiquement l'audio.
  Future<void> addToQueue(PlayerQueueItem item) async {
    await _insertQueueItem(_queueItems.length, item);
  }

  Future<void> _insertQueueItem(int index, PlayerQueueItem item) async {
    final safeIndex = index.clamp(0, _queueItems.length);
    await _ensurePlaybackReady();
    _queueItems.insert(safeIndex, item);
    if (_sourceReady) {
      await _player.insertAudioSource(safeIndex, item.toAudioSource());
    } else {
      await _player.setAudioSources(
        _queueItems.map((entry) => entry.toAudioSource()).toList(),
        initialIndex: _currentQueueIndex ?? 0,
        preload: false,
      );
      _sourceReady = true;
    }
    final current = _activeQueueIndex;
    if (current != null && safeIndex <= current && _queueItems.length > 1) {
      _currentQueueIndex = current + 1;
    }
    _publishQueue();
    _broadcastPlaybackState(_player.playbackEvent);
  }

  /// Retire une piste **non courante** de la file d'attente. Ne modifie ni
  /// playlists, ni favoris, ni fichiers : uniquement la file en mémoire et la
  /// playlist native de just_audio.
  @override
  Future<void> removeQueueItemAt(int index) async {
    if (!_sourceReady || index < 0 || index >= _queueItems.length) return;
    final current = _activeQueueIndex;
    if (current != null && index == current) return;
    final removed = _queueItems.removeAt(index);
    if (current != null && index < current) {
      _currentQueueIndex = current - 1;
    }
    _debugAudioLog(
      'retrait queue track=${removed.id} index=$index '
      'reste=${_queueItems.length}',
    );
    try {
      await _player.removeAudioSourceAt(index);
    } catch (error, stackTrace) {
      _debugAudioLog(
        'échec retrait source index=$index',
        error: error,
        stackTrace: stackTrace,
      );
    }
    _publishQueue();
    _broadcastPlaybackState(_player.playbackEvent);
  }

  /// Retire toutes les occurrences non courantes d'une piste. Retourne false
  /// si cette piste est actuellement lue : l'appelant peut alors choisir un
  /// arrêt explicite plutôt qu'un saut implicite surprenant.
  Future<bool> removeQueuedTrackById(String trackId) async {
    final current = _activeQueueIndex;
    if (current != null && _queueItems[current].id == trackId) return false;
    final indexes = <int>[
      for (var index = 0; index < _queueItems.length; index++)
        if (_queueItems[index].id == trackId) index,
    ]..sort((a, b) => b.compareTo(a));
    for (final index in indexes) {
      await removeQueueItemAt(index);
    }
    return true;
  }

  /// Réordonne la file native et la file publiée dans la même opération.
  Future<void> reorderQueueItem(int oldIndex, int newIndex) async {
    if (!_sourceReady ||
        oldIndex < 0 ||
        oldIndex >= _queueItems.length ||
        newIndex < 0 ||
        newIndex >= _queueItems.length ||
        oldIndex == newIndex) {
      return;
    }
    final currentBefore = _activeQueueIndex;
    if (oldIndex == currentBefore || newIndex == currentBefore) return;
    final item = _queueItems.removeAt(oldIndex);
    _queueItems.insert(newIndex, item);
    await _player.moveAudioSource(oldIndex, newIndex);
    _currentQueueIndex = _player.currentIndex ?? currentBefore;
    _publishQueue();
    _broadcastPlaybackState(_player.playbackEvent);
  }

  Future<void> moveQueueItemNext(int index) async {
    final current = _activeQueueIndex;
    if (current == null || index == current || index == current + 1) return;
    await reorderQueueItem(index, current + 1);
  }

  Future<void> moveQueueItemToBottom(int index) async {
    if (_queueItems.isEmpty) return;
    await reorderQueueItem(index, _queueItems.length - 1);
  }

  /// Vide uniquement les pistes situées après la piste courante. Celle-ci
  /// reste chargée et sa lecture n'est jamais interrompue.
  Future<void> clearUpcoming() async {
    final current = _activeQueueIndex;
    if (current == null) return;
    for (var index = _queueItems.length - 1; index > current; index--) {
      await removeQueueItemAt(index);
    }
  }

  @override
  Future<void> stop() async {
    _playbackRequested = false;
    AudioDiagnostics.instance.log('AUDIO_PLAYER_STOPPED', {
      'index': _activeQueueIndex,
    });
    await _player.stop();
    _broadcastPlaybackState(_player.playbackEvent);
  }

  /// Purge à la déconnexion : arrête la lecture, vide la file et le MediaItem
  /// courant. Aucune donnée du compte précédent ne subsiste dans le lecteur.
  Future<void> clearForLogout() => clearQueueAndStop();

  /// Arrête la lecture et vide entièrement la file (déconnexion, suppression
  /// d'une piste de la bibliothèque). L'UI repart d'un lecteur vide, sans
  /// jamais réafficher un état périmé.
  Future<void> clearQueueAndStop() async {
    ++_loadRequest;
    ++_artworkRequest;
    _lastAuthorizationRecoveryAttemptAt = null;
    _authorizationRecoveryInFlight = null;
    _consecutiveErrorSkips = 0;
    _resolvedArtworkTrackId = null;
    _resolvedArtworkUri = null;
    ++_speedApplyRequest;
    _speedScheduledTrackId = null;
    _trackSpeedCache.clear();
    _sessionOnlyTrackSpeeds.clear();
    try {
      await _player.stop();
      await _applyConfirmedSpeed(1.0);
      await _player.setAudioSources(const [], preload: false);
    } catch (error) {
      _debugAudioLog('purge lecteur au logout: erreur ignorée ($error)');
    }
    _queueItems.clear();
    _currentQueueIndex = 0;
    _sourceReady = false;
    _playbackRequested = false;
    queue.add(const <MediaItem>[]);
    mediaItem.add(null);
    await _artworkCacheClear?.call();
    _broadcastPlaybackState(_player.playbackEvent);
    _debugAudioLog('lecteur purgé au logout (file et piste vidées)');
  }

  /// Flux combiné pour l'UI : position (continue), tampon et durée.
  Stream<PlayerPositionData> get positionDataStream => _combineLatest3(
    _player.positionStream,
    _player.bufferedPositionStream,
    _player.durationStream,
    (position, buffered, duration) => PlayerPositionData(
      position: position,
      bufferedPosition: buffered,
      duration: duration ?? Duration.zero,
    ),
  );

  Future<void> dispose() async {
    AudioDiagnostics.instance.log('AUDIO_PLAYER_DISPOSED');
    await _interruptionSubscription?.cancel();
    await _becomingNoisySubscription?.cancel();
    await _playbackEventSubscription.cancel();
    await _playerStateSubscription.cancel();
    await _currentIndexSubscription.cancel();
    await _timeStretchEngine.dispose();
    await _player.dispose();
  }

  /// Configure le focus Android avant tout chargement de source.
  ///
  /// Toute interruption, y compris un événement de ducking, met en pause au
  /// lieu de modifier le gain du fichier en cours de lecture.
  Future<void> _configureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());

      _becomingNoisySubscription = session.becomingNoisyEventStream.listen((_) {
        _debugAudioLog('sortie audio coupée, pause');
        unawaited(pause());
      });
      _interruptionSubscription = session.interruptionEventStream.listen((
        event,
      ) {
        if (event.begin && _player.playing) {
          _debugAudioLog('interruption ${event.type.name}, pause sans ducking');
          unawaited(pause());
        }
      });
    } catch (error, stackTrace) {
      _debugAudioLog(
        'échec configuration AudioSession',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _ensurePlaybackReady() async {
    final setup = _playbackSetup ??= _configurePlayback();
    await setup;
  }

  Future<void> _configurePlayback() async {
    // Le gain applicatif reste à l'unité. Aucun DSP, ReplayGain ou
    // normalisation n'est appliqué.
    await _player.setVolume(1.0);
    await (_providedAudioSessionSetup ?? _configureAudioSession());
  }

  Future<void> _startPlayback() async {
    _playbackRequested = true;
    final item = _currentItem;
    _debugAudioLog(
      'play track=${item?.id ?? 'inconnu'} '
      'streamUri=${item?.streamUri ?? 'inconnue'} '
      'format=${item?.format ?? 'inconnu'} '
      'mimeType=${item?.mimeType ?? 'inconnu'} '
      'volume=${_player.volume} state=${_player.processingState.name} '
      'buffered=${_player.bufferedPosition}',
    );
    await _player.play();
  }

  Future<Duration?> _setAudioSourcesWithAuthorizationRecovery({
    required int request,
    required int initialIndex,
    required Duration initialPosition,
    required bool preload,
  }) async {
    try {
      return await _player.setAudioSources(
        _queueItems.map((item) => item.toAudioSource()).toList(growable: false),
        initialIndex: initialIndex,
        initialPosition: initialPosition,
        preload: preload,
      );
    } catch (error, stackTrace) {
      if (!_isAuthorizationFailure(error) ||
          !await _recoverAuthorization(
            request: request,
            initialIndex: initialIndex,
            initialPosition: initialPosition,
            resumePlayback: false,
          )) {
        Error.throwWithStackTrace(error, stackTrace);
      }
      return _player.duration;
    }
  }

  void _handleAsynchronousPlaybackFailure(
    int request,
    Object error,
    StackTrace stackTrace,
  ) {
    if (_isAuthorizationFailure(error)) {
      unawaited(
        _recoverAuthorization(
          request: request,
          initialIndex: _activeQueueIndex ?? 0,
          initialPosition: _player.position,
          resumePlayback: _playbackRequested,
        ).then((recovered) {
          if (recovered || request != _loadRequest) return;
          // Sans token valide, sauter de piste ne servirait à rien : l'échec
          // est publié tel quel (l'utilisateur voit l'erreur, rien n'est caché).
          final item = _currentItem;
          if (item != null) {
            _recordPlaybackFailure(item, error, stackTrace);
          }
        }),
      );
      return;
    }
    final item = _currentItem;
    if (item == null) return;
    if (_tryScheduleErrorSkip(request, item, error)) return;
    _recordPlaybackFailure(item, error, stackTrace);
  }

  /// Politique de session longue : une piste irrécupérable (fichier absent,
  /// flux corrompu, 404…) ne doit pas arrêter toute la file. L'erreur reste
  /// journalisée dans les diagnostics ; la lecture reprend sur la piste
  /// suivante de l'ordre effectif (shuffle compris), avec une limite de
  /// sauts consécutifs pour ne jamais boucler si tout le réseau est tombé.
  bool _tryScheduleErrorSkip(
    int request,
    PlayerQueueItem failedItem,
    Object error,
  ) {
    if (request != _loadRequest || !_playbackRequested) return false;
    if (_queueItems.length < 2) return false;
    if (_consecutiveErrorSkips >= _maxConsecutiveErrorSkips) {
      AudioDiagnostics.instance.log('AUDIO_ERROR_SKIP_LIMIT_REACHED', {
        'attempts': _consecutiveErrorSkips,
        'track': failedItem.id,
      });
      return false;
    }
    final target = _relativeQueueIndex(1);
    if (target == null) return false;
    _consecutiveErrorSkips += 1;
    _lastErrorSkipAt = _clock();
    AudioDiagnostics.instance.log('AUDIO_TRACK_SKIPPED_AFTER_ERROR', {
      'track': failedItem.id,
      'from': _activeQueueIndex,
      'to': target,
      'attempt': _consecutiveErrorSkips,
      'error': error.runtimeType,
    });
    unawaited(
      _resumeAtIndexAfterError(request, target).then((resumed) {
        if (!resumed && request == _loadRequest) {
          _recordPlaybackFailure(failedItem, error, StackTrace.current);
        }
      }),
    );
    return true;
  }

  /// Après une erreur native, just_audio repasse en idle : recharger les
  /// sources (mêmes URI, headers d'autorisation courants si disponibles) puis
  /// reprendre sur [index]. Aucune donnée audio n'est modifiée.
  Future<bool> _resumeAtIndexAfterError(int request, int index) async {
    try {
      final headers = _currentAuthorizationHeaders?.call();
      final authorization = headers?['Authorization'];
      if (headers != null &&
          authorization != null &&
          authorization.startsWith('Bearer ')) {
        final refreshedItems = _queueItems
            .map((item) => item.copyWithHeaders(headers))
            .toList(growable: false);
        _queueItems
          ..clear()
          ..addAll(refreshedItems);
      }
      await _player.setAudioSources(
        _queueItems.map((item) => item.toAudioSource()).toList(growable: false),
        initialIndex: index.clamp(0, _queueItems.length - 1),
        initialPosition: Duration.zero,
        preload: true,
      );
      if (request != _loadRequest) return false;
      _sourceReady = true;
      _currentQueueIndex = _player.currentIndex ?? index;
      _publishedMediaKey = null;
      _publishQueue();
      _publishCurrentMediaItem(includeArtwork: true);
      _broadcastPlaybackState(_player.playbackEvent);
      _scheduleCurrentTrackSpeed();
      if (_playbackRequested) {
        unawaited(
          _startPlayback().catchError((Object error, StackTrace stackTrace) {
            if (request != _loadRequest) return;
            _handleAsynchronousPlaybackFailure(request, error, stackTrace);
          }),
        );
      }
      return true;
    } catch (error, stackTrace) {
      _debugAudioLog(
        'reprise après erreur de piste impossible (index=$index)',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<bool> _recoverAuthorization({
    required int request,
    required int initialIndex,
    required Duration initialPosition,
    required bool resumePlayback,
  }) {
    final current = _authorizationRecoveryInFlight;
    if (current != null) return current;
    if (request != _loadRequest ||
        _authorizationRefresh == null ||
        _currentAuthorizationHeaders == null) {
      return Future<bool>.value(false);
    }
    // Anti-boucle par fenêtre de temps, PAS par file : un access token court
    // (15 min) expire plusieurs fois pendant une session de plusieurs heures.
    // L'ancien verrou « une seule récupération par file » arrêtait la musique
    // à la deuxième expiration ; la fenêtre empêche seulement un martèlement
    // du refresh si le serveur répond 401 en continu.
    final now = _clock();
    final lastAttempt = _lastAuthorizationRecoveryAttemptAt;
    if (lastAttempt != null &&
        now.difference(lastAttempt) < _authorizationRecoveryCooldown) {
      AudioDiagnostics.instance.log('AUDIO_TOKEN_REFRESH_REFUSED', {
        'reason': 'cooldown',
        'sinceMs': now.difference(lastAttempt).inMilliseconds,
      });
      return Future<bool>.value(false);
    }
    _lastAuthorizationRecoveryAttemptAt = now;
    final recovery = _performAuthorizationRecovery(
      request: request,
      initialIndex: initialIndex,
      initialPosition: initialPosition,
      resumePlayback: resumePlayback,
    ).whenComplete(() => _authorizationRecoveryInFlight = null);
    _authorizationRecoveryInFlight = recovery;
    return recovery;
  }

  Future<bool> _performAuthorizationRecovery({
    required int request,
    required int initialIndex,
    required Duration initialPosition,
    required bool resumePlayback,
  }) async {
    _debugAudioLog(
      'autorisation audio expirée track=${_currentItem?.id ?? 'inconnu'}; '
      'rafraîchissement',
    );
    AudioDiagnostics.instance.log('AUDIO_TOKEN_REFRESH_STARTED', {
      'index': _activeQueueIndex,
      'track': _currentItem?.id,
    });
    try {
      await _player.pause();
      final refreshed = await _authorizationRefresh!();
      if (!refreshed || request != _loadRequest) {
        AudioDiagnostics.instance.log('AUDIO_TOKEN_REFRESH_FAILED', {
          'refreshed': refreshed,
        });
        return false;
      }
      final headers = _currentAuthorizationHeaders!();
      final authorization = headers['Authorization'];
      if (authorization == null || !authorization.startsWith('Bearer ')) {
        return false;
      }
      final refreshedItems = _queueItems
          .map((item) => item.copyWithHeaders(headers))
          .toList(growable: false);
      _queueItems
        ..clear()
        ..addAll(refreshedItems);
      await _player.setAudioSources(
        refreshedItems
            .map((item) => item.toAudioSource())
            .toList(growable: false),
        initialIndex: initialIndex.clamp(0, refreshedItems.length - 1),
        initialPosition: initialPosition,
        preload: true,
      );
      if (request != _loadRequest) return false;
      _sourceReady = true;
      _currentQueueIndex = _player.currentIndex ?? initialIndex;
      _speedScheduledTrackId = null;
      _publishedMediaKey = null;
      AudioDiagnostics.instance.log('AUDIO_TOKEN_REFRESH_COMPLETED', {
        'index': _currentQueueIndex,
        'resume': resumePlayback,
      });
      _publishQueue();
      _publishCurrentMediaItem(includeArtwork: true);
      _broadcastPlaybackState(_player.playbackEvent);
      _scheduleCurrentTrackSpeed();
      if (resumePlayback) {
        unawaited(
          _startPlayback().catchError((Object error, StackTrace stackTrace) {
            if (request != _loadRequest) return;
            final item = _currentItem;
            if (item != null) {
              _recordPlaybackFailure(item, error, stackTrace);
            }
          }),
        );
      }
      return true;
    } catch (error, stackTrace) {
      _debugAudioLog(
        'reprise audio après refresh impossible',
        error: error,
        stackTrace: stackTrace,
      );
      AudioDiagnostics.instance.log('AUDIO_TOKEN_REFRESH_FAILED', {
        'error': error,
      });
      return false;
    }
  }

  bool _isAuthorizationFailure(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('401') &&
        (message.contains('response') ||
            message.contains('http') ||
            message.contains('invalidresponsecode'));
  }

  static int? _extractHttpStatus(Object error) {
    final match = RegExp(
      r'response code[:\s]+(\d{3})',
      caseSensitive: false,
    ).firstMatch(error.toString());
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  void _onCurrentIndexChanged(int? index) {
    if (index == null || index < 0 || index >= _queueItems.length) return;
    AudioDiagnostics.instance.log('AUDIO_INDEX_CHANGED', {
      'index': index,
      'track': _queueItems[index].id,
      'queue': _queueItems.length,
      'seq': _player.sequence.length,
    });
    final previousTrackId = _currentTrackId;
    _currentQueueIndex = index;
    final nextTrackId = _currentTrackId;
    if (previousTrackId != null && previousTrackId != nextTrackId) {
      _sessionOnlyTrackSpeeds.remove(previousTrackId);
    }
    _publishedMediaKey = null;
    if (_resolvedArtworkTrackId != _currentItem?.id) {
      ++_artworkRequest;
      _resolvedArtworkTrackId = null;
      _resolvedArtworkUri = null;
    }
    _publishCurrentMediaItem(
      includeArtwork:
          _player.processingState == ProcessingState.ready ||
          _player.processingState == ProcessingState.completed,
    );
    _broadcastPlaybackState(_player.playbackEvent);
    _scheduleCurrentTrackSpeed();
  }

  void _scheduleCurrentTrackSpeed() {
    final trackId = _currentTrackId;
    if (trackId == null || _speedScheduledTrackId == trackId) return;
    _speedScheduledTrackId = trackId;
    unawaited(
      applyCurrentTrackSpeed().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        _debugAudioLog(
          'application vitesse différée impossible track=$trackId; défaut 1.00x',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  void _publishLoadingState(int index) {
    playbackState.add(
      playbackState.value.copyWith(
        controls: const <MediaControl>[MediaControl.stop],
        processingState: AudioProcessingState.loading,
        playing: false,
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        queueIndex: index,
      ),
    );
  }

  void _broadcastPlaybackState(PlaybackEvent event) {
    if (event.currentIndex != null) _currentQueueIndex = event.currentIndex;
    _logProcessingState();
    if (_player.processingState == ProcessingState.ready && _player.playing) {
      // Une piste joue réellement : la fenêtre de sauts d'erreur repart de
      // zéro, mais seulement après un délai de stabilité depuis le dernier
      // saut. L'événement de démarrage n'est journalisé qu'une fois par index.
      final lastSkip = _lastErrorSkipAt;
      if (_consecutiveErrorSkips > 0 &&
          (lastSkip == null ||
              _clock().difference(lastSkip) >= _errorSkipCounterResetDelay)) {
        _consecutiveErrorSkips = 0;
      }
      final index = _activeQueueIndex;
      if (index != null && index != _lastStartedIndex) {
        _lastStartedIndex = index;
        AudioDiagnostics.instance.log('AUDIO_TRACK_STARTED', {
          'index': index,
          'track': _currentItem?.id,
          'queue': _queueItems.length,
        });
      }
    }
    _publishCurrentMediaItem(
      includeArtwork:
          _sourceReady &&
          (_player.processingState == ProcessingState.ready ||
              _player.processingState == ProcessingState.completed),
    );

    final controls = _controlsFor(_player.playing);
    playbackState.add(
      playbackState.value.copyWith(
        controls: controls,
        systemActions: const <MediaAction>{
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: _compactActionIndices(controls),
        processingState: _mapProcessingState(_player.processingState),
        playing: _player.playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: _activeQueueIndex,
      ),
    );
  }

  void _broadcastPlaybackError(Object error, StackTrace stackTrace) {
    final item = _currentItem;
    _debugAudioLog(
      'erreur just_audio track=${item?.id ?? 'inconnu'} '
      'streamUri=${item?.streamUri ?? 'inconnue'} '
      'format=${item?.format ?? 'inconnu'} '
      'mimeType=${item?.mimeType ?? 'inconnu'}',
      error: error,
      stackTrace: stackTrace,
    );
    AudioDiagnostics.instance.log('AUDIO_SOURCE_ERROR', {
      'index': _activeQueueIndex,
      'track': item?.id,
      'http': _extractHttpStatus(error),
      'error': error,
    });
    if (item == null) return;
    // Toutes les erreurs asynchrones suivent la même politique : 401 →
    // récupération d'autorisation ; sinon saut borné de la piste
    // irrécupérable ; en dernier recours, échec visible.
    _handleAsynchronousPlaybackFailure(_loadRequest, error, stackTrace);
  }

  int? get _currentTrackId {
    final id = _currentItem?.id;
    return id == null ? null : int.tryParse(id);
  }

  Future<double> _applyConfirmedSpeed(double ratio) async {
    final normalized = _normalizeSpeedRatio(ratio);
    const tolerance = 0.0001;
    await _timeStretchEngine
        .setTempoRatio(normalized)
        .timeout(const Duration(seconds: 2));
    final applied = await _timeStretchEngine.getAppliedTempoRatio().timeout(
      const Duration(milliseconds: 500),
    );
    if ((applied - normalized).abs() > tolerance) {
      throw TimeStretchEngineException(
        'Ratio demandé ${normalized.toStringAsFixed(2)}x, '
        'ratio rapporté ${applied.toStringAsFixed(2)}x.',
      );
    }
    final stretchStatus = latestHomeSpotifyStretchStatus;
    _debugAudioLog(
      'time-stretch demandé=$normalized rapporté=$applied '
      'moteur=${_timeStretchEngine.engineName} '
      'mode=${_timeStretchEngine.qualityMode.name} '
      'latenceMs=${_timeStretchEngine.latencyMs} '
      'pcmFrames=${stretchStatus.pcmFramesProcessed} '
      'ratioNatif=${stretchStatus.nativeAppliedRatio} '
      'fallbacks=${stretchStatus.fallbackCount}',
    );
    if ((playbackState.value.speed - _player.speed).abs() > tolerance) {
      _broadcastPlaybackState(_player.playbackEvent);
    }
    return applied;
  }

  void _publishQueue() {
    queue.add(
      _queueItems
          .map((item) {
            final trackId = int.tryParse(item.id);
            final localArtwork = _resolvedArtworkTrackId == item.id
                ? _resolvedArtworkUri
                : null;
            return item.toMediaItem(
              includeArtwork: _artworkResolver == null || localArtwork != null,
              artworkUri: localArtwork,
              speedRatio: trackId == null
                  ? 1
                  : (_trackSpeedCache[trackId] ?? 1),
            );
          })
          .toList(growable: false),
    );
  }

  double _normalizeSpeedRatio(double ratio) {
    if (!ratio.isFinite || ratio < 0.7 || ratio > 1.3) {
      throw ArgumentError.value(
        ratio,
        'ratio',
        'La vitesse doit être comprise entre 0.70x et 1.30x.',
      );
    }
    return (ratio * 100).round() / 100;
  }

  void _recordPlaybackFailure(
    PlayerQueueItem item,
    Object error,
    StackTrace stackTrace, {
    bool logError = true,
  }) {
    if (logError) {
      _debugAudioLog(
        'échec audio track=${item.id} streamUri=${item.streamUri} '
        'format=${item.format} mimeType=${item.mimeType ?? 'inconnu'}',
        error: error,
        stackTrace: stackTrace,
      );
    }
    _sourceReady = false;
    _playbackRequested = false;
    AudioDiagnostics.instance.log('AUDIO_PLAYBACK_FAILED', {
      'track': item.id,
      'index': _activeQueueIndex,
      'http': _extractHttpStatus(error),
      'error': error,
    });
    playbackState.add(
      playbackState.value.copyWith(
        controls: const <MediaControl>[MediaControl.stop],
        processingState: AudioProcessingState.error,
        playing: false,
        errorMessage: _friendlyAudioError(error),
        queueIndex: _activeQueueIndex,
      ),
    );
  }

  void _publishCurrentMediaItem({
    required bool includeArtwork,
    Duration? resolvedDuration,
  }) {
    final item = _currentItem;
    if (item == null) return;
    final duration = resolvedDuration ?? _player.duration ?? item.duration;
    final trackId = int.tryParse(item.id);
    final speedRatio = trackId == null
        ? 1.0
        : (_trackSpeedCache[trackId] ?? 1.0);
    final usesPrivateArtwork = _artworkResolver != null;
    final localArtwork = _resolvedArtworkTrackId == item.id
        ? _resolvedArtworkUri
        : null;
    final canIncludeArtwork =
        includeArtwork && (!usesPrivateArtwork || localArtwork != null);
    if (includeArtwork && usesPrivateArtwork && item.artUri != null) {
      _scheduleArtworkResolution(item);
    }
    final key =
        '${item.id}|$canIncludeArtwork|${localArtwork ?? ''}|'
        '${duration?.inMilliseconds ?? -1}|$speedRatio';
    if (key == _publishedMediaKey) return;
    _publishedMediaKey = key;
    final currentMediaItem = mediaItem.valueOrNull;
    final currentSpeed = (currentMediaItem?.extras?['speedRatio'] as num?)
        ?.toDouble();
    final canCopyArtworkOnly =
        localArtwork != null &&
        currentMediaItem?.id == item.id &&
        currentMediaItem?.artUri != localArtwork &&
        currentMediaItem?.duration == duration &&
        currentSpeed == speedRatio;
    final updatedMediaItem = canCopyArtworkOnly
        ? currentMediaItem!.copyWith(artUri: localArtwork)
        : item.toMediaItem(
            includeArtwork: canIncludeArtwork,
            artworkUri: localArtwork,
            resolvedDuration: duration,
            speedRatio: speedRatio,
          );
    mediaItem.add(updatedMediaItem);
    if (item.artUri != null) {
      _traceArtwork(
        'E mediaItem trackId=${item.id} currentTrackId=${_currentItem?.id} '
        'oldArtUri=${currentMediaItem?.artUri ?? 'null'} '
        'newArtUri=${updatedMediaItem.artUri ?? 'null'} '
        'queueUpdate=pending streamPublished=yes subscribers=unavailable',
      );
    }
  }

  void _scheduleArtworkResolution(PlayerQueueItem item) {
    final dedupeKey =
        '${item.userId ?? 'none'}:${item.id}:'
        '${item.artworkIdentity ?? item.artUri?.path ?? 'none'}';
    if (_artworkResolver == null) {
      _traceArtwork(
        'B resolve trackId=${item.id} triggered=no reason=no_resolver '
        'dedupeKey=$dedupeKey generation=$_artworkRequest',
      );
      return;
    }
    if (_resolvedArtworkTrackId == item.id) {
      _traceArtwork(
        'B resolve trackId=${item.id} triggered=no '
        'reason=already_started_or_resolved dedupeKey=$dedupeKey '
        'generation=$_artworkRequest localUri=${_resolvedArtworkUri ?? 'null'}',
      );
      return;
    }
    _resolvedArtworkTrackId = item.id;
    final request = ++_artworkRequest;
    _traceArtwork(
      'A queueItem userId=${item.userId ?? 'null'} trackId=${item.id} '
      'coverUrl=${item.artUri == null ? 'absent' : 'present'} '
      'initialArtUri=${item.artUri ?? 'null'} generation=$request',
    );
    _traceArtwork(
      'B resolve trackId=${item.id} triggered=yes reason=current_track '
      'dedupeKey=$dedupeKey singleFlight=delegated generation=$request',
    );
    unawaited(
      _artworkResolver(item)
          .then((uri) {
            if (request != _artworkRequest || _currentItem?.id != item.id) {
              _traceArtwork(
                'E mediaItem trackId=${item.id} stale=yes '
                'requestGeneration=$request currentGeneration=$_artworkRequest '
                'currentTrackId=${_currentItem?.id ?? 'null'} resolvedUri=${uri ?? 'null'}',
              );
              return;
            }
            _resolvedArtworkUri = uri;
            _publishedMediaKey = null;
            _publishQueue();
            final queueUpdated = queue.value.any(
              (candidate) => candidate.id == item.id && candidate.artUri == uri,
            );
            _publishCurrentMediaItem(includeArtwork: true);
            _traceArtwork(
              'E mediaItem trackId=${item.id} stale=no resolvedUri=${uri ?? 'null'} '
              'queueUpdated=$queueUpdated currentPublishedArtUri='
              '${mediaItem.valueOrNull?.artUri ?? 'null'}',
            );
          })
          .catchError((Object error, StackTrace stackTrace) {
            _traceArtwork(
              'E mediaItem trackId=${item.id} error=${error.runtimeType} '
              'message=$error',
            );
            _debugAudioLog(
              'pochette notification indisponible track=${item.id}',
              error: error,
              stackTrace: stackTrace,
            );
          }),
    );
  }

  void _logProcessingState() {
    final state = _player.processingState;
    if (_lastLoggedProcessingState == state) return;
    _lastLoggedProcessingState = state;
    final item = _currentItem;
    _debugAudioLog(
      'processingState track=${item?.id ?? 'inconnu'} '
      'state=${state.name} buffered=${_player.bufferedPosition}',
    );
    AudioDiagnostics.instance.log('AUDIO_STATE', {
      'state': state.name,
      'playing': _player.playing,
      'index': _activeQueueIndex,
      'track': item?.id,
    });
    if (state == ProcessingState.completed) {
      AudioDiagnostics.instance.log('AUDIO_QUEUE_ENDED', {
        'index': _activeQueueIndex,
        'queue': _queueItems.length,
      });
    }
  }

  List<MediaControl> _controlsFor(bool playing) {
    if (!_sourceReady) return const <MediaControl>[MediaControl.stop];
    return <MediaControl>[
      if (_canSkipPrevious) MediaControl.skipToPrevious,
      if (playing) MediaControl.pause else MediaControl.play,
      if (_canSkipNext) MediaControl.skipToNext,
      MediaControl.stop,
    ];
  }

  List<int> _compactActionIndices(List<MediaControl> controls) {
    final compact = <int>[];
    for (
      var index = 0;
      index < controls.length && compact.length < 3;
      index++
    ) {
      if (controls[index].action != MediaAction.stop) compact.add(index);
    }
    return compact;
  }

  AudioProcessingState _mapProcessingState(ProcessingState state) {
    return switch (state) {
      ProcessingState.idle => AudioProcessingState.idle,
      ProcessingState.loading => AudioProcessingState.loading,
      ProcessingState.buffering => AudioProcessingState.buffering,
      ProcessingState.ready => AudioProcessingState.ready,
      ProcessingState.completed => AudioProcessingState.completed,
    };
  }

  String _friendlyAudioError(Object error) {
    final message = error.toString().toLowerCase();
    if (_isAuthorizationFailure(error)) {
      return 'Session expirée pendant la lecture. Reconnectez-vous.';
    }
    if (message.contains('404') ||
        message.contains('403') ||
        message.contains('416') ||
        message.contains('not found')) {
      return 'Source audio inaccessible.';
    }
    if (message.contains('unsupported') ||
        message.contains('decoder') ||
        message.contains('unrecognized') ||
        message.contains('format')) {
      return 'Format audio non pris en charge par cet appareil.';
    }
    if (message.contains('timeout') ||
        message.contains('network') ||
        message.contains('socket')) {
      return 'Erreur réseau pendant la lecture.';
    }
    if (message.contains('connection') ||
        message.contains('refused') ||
        message.contains('unknown host')) {
      return 'Serveur non joignable.';
    }
    return 'Erreur audio pendant la lecture.';
  }

  int? get _activeQueueIndex {
    final index = _currentQueueIndex ?? _player.currentIndex;
    if (index == null || index < 0 || index >= _queueItems.length) return null;
    return index;
  }

  PlayerQueueItem? get _currentItem {
    final index = _activeQueueIndex;
    return index == null ? null : _queueItems[index];
  }

  bool get _canSkipPrevious {
    final index = _activeQueueIndex;
    return _sourceReady && index != null && index > 0;
  }

  bool get _canSkipNext {
    final index = _activeQueueIndex;
    return _sourceReady && index != null && index < _queueItems.length - 1;
  }
}
