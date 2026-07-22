import 'dart:async';
import 'dart:developer' as developer;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../data/playback_settings_api.dart';
import '../data/playback_session_store.dart';
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

  AudioSource toAudioSource({Map<String, String>? requestHeaders}) {
    return AudioSource.uri(
      streamUri,
      headers: requestHeaders ?? headers,
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
    this._currentAuthorizationExpiresIn,
    this._artworkResolver,
    this._artworkCacheClear,
    this._playbackSessionStore,
    DateTime Function()? clock,
    Duration recoveryCooldown = const Duration(seconds: 30),
    Duration endOfTrackGracePeriod = const Duration(seconds: 2),
    Duration playbackGuardInterval = const Duration(seconds: 1),
  }) : _clock = clock ?? DateTime.now,
       _authorizationRecoveryCooldown = recoveryCooldown,
       _endOfTrackGracePeriod = endOfTrackGracePeriod,
       _playbackGuardInterval = playbackGuardInterval,
       _player =
           player ??
           AudioPlayer(
             // Flux authentifiés : Android doit envoyer le header Bearer
             // directement au serveur HTTPS. Le proxy localhost de just_audio
             // exige du cleartext, bloqué en release (voir manifest debug).
             useProxyForRequestHeaders: false,
             audioLoadConfiguration: const AudioLoadConfiguration(
               androidLoadControl: AndroidLoadControl(
                 // L'ancien seuil imposait 2,5 s de media avant le premier
                 // son, meme sur un reseau rapide. Le prechargement natif de
                 // la piste suivante reste actif, avec un tampon de securite
                 // borne pour les FLAC/WAV distants.
                 minBufferDuration: Duration(seconds: 15),
                 maxBufferDuration: Duration(seconds: 60),
                 bufferForPlaybackDuration: Duration(milliseconds: 750),
                 bufferForPlaybackAfterRebufferDuration: Duration(
                   milliseconds: 1500,
                 ),
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
    _positionPersistenceSubscription = _player.positionStream.listen(
      _onPositionForPersistence,
    );
    _playbackGuardTimer = Timer.periodic(
      _playbackGuardInterval,
      (_) => _runPlaybackGuard(),
    );
    AudioDiagnostics.instance.log('AUDIO_HANDLER_CREATED');
    AudioDiagnostics.instance.log('PLAYER_CREATED', {
      'useProxyForRequestHeaders': false,
      'bufferForPlaybackMs': 750,
      'bufferAfterRebufferMs': 1500,
      'minBufferMs': 15000,
      'maxBufferMs': 60000,
    });
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
  final Duration? Function()? _currentAuthorizationExpiresIn;
  final Future<Uri?> Function(PlayerQueueItem item)? _artworkResolver;
  final Future<void> Function()? _artworkCacheClear;
  final PlaybackSessionStore? _playbackSessionStore;
  Future<void>? _playbackSetup;
  late final StreamSubscription<PlaybackEvent> _playbackEventSubscription;
  late final StreamSubscription<PlayerState> _playerStateSubscription;
  late final StreamSubscription<int?> _currentIndexSubscription;
  late final StreamSubscription<Duration> _positionPersistenceSubscription;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;

  final DateTime Function() _clock;
  final Duration _authorizationRecoveryCooldown;
  final Duration _endOfTrackGracePeriod;
  final Duration _playbackGuardInterval;

  int _loadRequest = 0;
  DateTime? _lastAuthorizationRecoveryAttemptAt;
  Future<bool>? _authorizationRecoveryInFlight;
  String? _loadedAuthorizationHeader;
  Future<bool>? _trackErrorRecoveryInFlight;
  bool _authorizationFailureHandling = false;
  Future<void>? _autoAdvanceInFlight;
  Timer? _endOfTrackWatchdog;
  int? _endOfTrackWatchdogIndex;
  late final Timer _playbackGuardTimer;
  Duration? _lastEndGuardPosition;
  int? _lastEndGuardIndex;
  DateTime? _ignorePositionWrapUntil;
  String? _lastHandledErrorFingerprint;
  DateTime? _lastHandledErrorAt;
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
  Stopwatch? _tapToPlaybackStopwatch;
  Stopwatch? _bufferingStopwatch;
  int _bufferingCount = 0;
  int _totalBufferingMs = 0;
  int _longestBufferingMs = 0;
  int? _playbackSessionUserId;
  int? _restoredPlaybackSessionUserId;
  bool _restoringPlaybackSession = false;
  Timer? _playbackPersistenceTimer;
  int _lastPersistedPositionMs = -1;
  Future<void>? _playbackPersistenceInFlight;
  bool _networkAvailable = true;
  bool _networkRecoveryPending = false;
  int _networkRecoveryAttempt = 0;
  int? _networkRecoveryIndex;
  Duration _networkRecoveryPosition = Duration.zero;
  Timer? _networkRecoveryTimer;
  Future<bool>? _networkRecoveryInFlight;

  static const Duration _positionPersistenceInterval = Duration(seconds: 5);
  static const Duration _networkRecoveryMaximumDelay = Duration(seconds: 30);
  static const Duration _endOfTrackPositionTolerance = Duration(
    milliseconds: 250,
  );
  static const Duration _endOfTrackWrapDestinationTolerance = Duration(
    seconds: 2,
  );

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

    _cancelEndOfTrackWatchdog();
    final request = ++_loadRequest;
    _tapToPlaybackStopwatch = Stopwatch()..start();
    _lastAuthorizationRecoveryAttemptAt = null;
    _authorizationRecoveryInFlight = null;
    _trackErrorRecoveryInFlight = null;
    _authorizationFailureHandling = false;
    _autoAdvanceInFlight = null;
    _lastHandledErrorFingerprint = null;
    _lastHandledErrorAt = null;
    _consecutiveErrorSkips = 0;
    _lastErrorSkipAt = null;
    _lastStartedIndex = null;
    AudioDiagnostics.instance.newSession();
    AudioDiagnostics.instance.log('AUDIO_QUEUE_BUILD_STARTED', {
      'queueLength': items.length,
      'currentIndex': initialIndex,
      'trackId': items[initialIndex].id,
      'mediaItemId': items[initialIndex].id,
      'repeatMode': _repeatMode.name,
      'shuffleMode': _player.shuffleModeEnabled,
      'processingState': _player.processingState.name,
      'playing': _player.playing,
    });
    ++_artworkRequest;
    _resolvedArtworkTrackId = null;
    _resolvedArtworkUri = null;
    _speedScheduledTrackId = null;
    final immutableItems = List<PlayerQueueItem>.unmodifiable(items);
    final initialItem = immutableItems[initialIndex];
    _playbackSessionUserId = _resolveQueueUserId(immutableItems);
    _restoredPlaybackSessionUserId = _playbackSessionUserId;

    try {
      await _ensurePlaybackReady();
      if (request != _loadRequest) return;
      await _refreshAuthorizationBeforeLoadIfNeeded(request);
      if (request != _loadRequest) return;

      _queueItems
        ..clear()
        ..addAll(immutableItems);
      _applyCurrentAuthorizationHeaders();
      _currentQueueIndex = initialIndex;
      _sourceReady = false;
      _publishedMediaKey = null;

      // audio_service expose la file complète au lockscreen/notification.
      _publishQueue();
      AudioDiagnostics.instance.log('AUDIO_QUEUE_BUILD_COMPLETED', {
        'queueLength': _queueItems.length,
        'currentIndex': initialIndex,
        'trackId': initialItem.id,
        'queueBuildMs': _tapToPlaybackStopwatch?.elapsedMilliseconds,
      });
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
        'trackId': initialItem.id,
        'currentIndex': initialIndex,
        'queueLength': immutableItems.length,
      });
      final sourcePrepareStopwatch = Stopwatch()..start();
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
        'trackId': initialItem.id,
        'sequenceLength': _player.sequence.length,
        'durationMs': loadedDuration?.inMilliseconds,
        'sourcePrepareMs': sourcePrepareStopwatch.elapsedMilliseconds,
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
      _schedulePlaybackPersistence(immediate: true);

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
      AudioDiagnostics.instance.log('AUDIO_QUEUE_BUILD_FAILED', {
        'trackId': initialItem.id,
        'error': error,
      });
      throw AudioPlaybackException(_friendlyAudioError(error));
    } catch (error, stackTrace) {
      if (request != _loadRequest) return;
      if (_isTransientNetworkFailure(error)) {
        _playbackRequested = true;
        _enterNetworkRecovery(request, error, stackTrace: stackTrace);
        return;
      }
      _recordPlaybackFailure(initialItem, error, stackTrace);
      AudioDiagnostics.instance.log('AUDIO_QUEUE_BUILD_FAILED', {
        'trackId': initialItem.id,
        'error': error,
      });
      if (error is AudioPlaybackException) rethrow;
      throw AudioPlaybackException(_friendlyAudioError(error));
    }
  }

  /// Restaure la dernière file du compte après authentification.
  ///
  /// La lecture reste volontairement en pause : un redémarrage volontaire de
  /// l'application ne doit jamais déclencher du son sans action utilisateur.
  /// Les headers Bearer ne sont jamais persistés ; ils sont reconstruits avec
  /// la session courante juste avant le chargement des sources.
  Future<bool> restorePlaybackSessionForUser(int userId) async {
    final store = _playbackSessionStore;
    if (store == null || userId <= 0) return false;
    if (_restoredPlaybackSessionUserId == userId && _queueItems.isNotEmpty) {
      return true;
    }
    PersistedPlaybackSession? persisted;
    try {
      persisted = await store.read(userId);
    } catch (error, stackTrace) {
      _debugAudioLog(
        'lecture de la session persistée impossible user=$userId',
        error: error,
        stackTrace: stackTrace,
      );
      AudioDiagnostics.instance.log('AUDIO_SESSION_RESTORE_FAILED', {
        'userId': userId,
        'stage': 'read',
        'error': error,
      });
      return false;
    }
    if (persisted == null) {
      _restoredPlaybackSessionUserId = userId;
      return false;
    }

    final items = persisted.queue
        .map((item) => _queueItemFromPersisted(item, userId))
        .toList(growable: false);
    final request = ++_loadRequest;
    _restoringPlaybackSession = true;
    _playbackSessionUserId = userId;
    _networkRecoveryPending = false;
    _networkRecoveryTimer?.cancel();
    try {
      await _ensurePlaybackReady();
      await _refreshAuthorizationBeforeLoadIfNeeded(request);
      if (request != _loadRequest) return false;
      _queueItems
        ..clear()
        ..addAll(items);
      _applyCurrentAuthorizationHeaders();
      _currentQueueIndex = persisted.currentIndex;
      _sourceReady = false;
      _playbackRequested = false;
      _publishedMediaKey = null;
      _publishQueue();
      queueTitle.add('File d’attente');
      _publishCurrentMediaItem(includeArtwork: false);
      _publishLoadingState(persisted.currentIndex);
      await _player.pause();
      final loadedDuration = await _setAudioSourcesWithAuthorizationRecovery(
        request: request,
        initialIndex: persisted.currentIndex,
        initialPosition: Duration(milliseconds: persisted.positionMs),
        preload: true,
      );
      if (request != _loadRequest) return false;
      _sourceReady = true;
      _currentQueueIndex = _player.currentIndex ?? persisted.currentIndex;
      await setRepeatMode(switch (persisted.repeatMode) {
        'one' => AudioServiceRepeatMode.one,
        'all' => AudioServiceRepeatMode.all,
        _ => AudioServiceRepeatMode.none,
      });
      await setShuffleMode(
        persisted.shuffleEnabled
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
      );
      final trackId = _currentTrackId;
      if (trackId != null) {
        _trackSpeedCache[trackId] = persisted.speedRatio;
      }
      await _applyConfirmedSpeed(persisted.speedRatio);
      _publishCurrentMediaItem(
        includeArtwork: true,
        resolvedDuration: loadedDuration,
      );
      _broadcastPlaybackState(_player.playbackEvent);
      _lastPersistedPositionMs = persisted.positionMs;
      _restoredPlaybackSessionUserId = userId;
      AudioDiagnostics.instance.log('AUDIO_SESSION_RESTORED', {
        'userId': userId,
        'queueLength': items.length,
        'currentIndex': persisted.currentIndex,
        'positionMs': persisted.positionMs,
        'repeatMode': persisted.repeatMode,
        'shuffleMode': persisted.shuffleEnabled,
        'wasPlayingBeforeRestart': persisted.wasPlaying,
      });
      return true;
    } catch (error, stackTrace) {
      _sourceReady = false;
      _playbackRequested = false;
      _debugAudioLog(
        'restauration lecteur impossible user=$userId',
        error: error,
        stackTrace: stackTrace,
      );
      AudioDiagnostics.instance.log('AUDIO_SESSION_RESTORE_FAILED', {
        'userId': userId,
        'stage': 'load',
        'error': error,
      });
      return false;
    } finally {
      _restoringPlaybackSession = false;
    }
  }

  int? _resolveQueueUserId(List<PlayerQueueItem> items) {
    final userIds = items
        .map((item) => item.userId)
        .whereType<int>()
        .where((id) => id > 0)
        .toSet();
    return userIds.length == 1 ? userIds.single : null;
  }

  PlayerQueueItem _queueItemFromPersisted(
    PersistedQueueItem item,
    int userId,
  ) => PlayerQueueItem(
    id: item.id,
    userId: item.userId ?? userId,
    streamUri: item.streamUri,
    title: item.title,
    artist: item.artist,
    album: item.album,
    artUri: item.artUri,
    duration: item.durationMs == null
        ? null
        : Duration(milliseconds: item.durationMs!),
    mimeType: item.mimeType,
    extension: item.extension,
    sampleRate: item.sampleRate,
    bitDepth: item.bitDepth,
    channels: item.channels,
    bitrate: item.bitrate,
    fileSize: item.fileSize,
    origin: item.origin,
    artistKey: item.artistKey,
    albumKey: item.albumKey,
    headers: _currentAuthorizationHeaders?.call(),
    artworkIdentity: item.artworkIdentity,
  );

  PersistedQueueItem _persistedQueueItem(PlayerQueueItem item) =>
      PersistedQueueItem(
        id: item.id,
        userId: item.userId,
        streamUri: item.streamUri,
        title: item.title,
        artist: item.artist,
        album: item.album,
        artUri: item.artUri,
        durationMs: item.duration?.inMilliseconds,
        mimeType: item.mimeType,
        extension: item.extension,
        sampleRate: item.sampleRate,
        bitDepth: item.bitDepth,
        channels: item.channels,
        bitrate: item.bitrate,
        fileSize: item.fileSize,
        origin: item.origin,
        artistKey: item.artistKey,
        albumKey: item.albumKey,
        artworkIdentity: item.artworkIdentity,
      );

  void _onPositionForPersistence(Duration position) {
    _observePositionWrapAtEnd(position);
    _observeEndOfTrack(position);
    if (_queueItems.isEmpty || _restoringPlaybackSession) return;
    if ((position.inMilliseconds - _lastPersistedPositionMs).abs() <
        _positionPersistenceInterval.inMilliseconds) {
      return;
    }
    _schedulePlaybackPersistence();
  }

  void _schedulePlaybackPersistence({bool immediate = false}) {
    if (_playbackSessionStore == null ||
        _restoringPlaybackSession ||
        _playbackSessionUserId == null ||
        _queueItems.isEmpty) {
      return;
    }
    _playbackPersistenceTimer?.cancel();
    if (immediate) {
      unawaited(_persistPlaybackSession());
      return;
    }
    _playbackPersistenceTimer = Timer(
      const Duration(milliseconds: 750),
      () => unawaited(_persistPlaybackSession()),
    );
  }

  Future<void> _persistPlaybackSession() async {
    final store = _playbackSessionStore;
    final userId = _playbackSessionUserId;
    final index = _activeQueueIndex;
    if (store == null ||
        userId == null ||
        index == null ||
        _queueItems.isEmpty ||
        _queueItems.length > maximumPersistedQueueLength) {
      return;
    }
    final previous = _playbackPersistenceInFlight;
    if (previous != null) {
      await previous;
      if (_playbackPersistenceInFlight != null) return;
    }
    final session = PersistedPlaybackSession(
      userId: userId,
      queue: _queueItems.map(_persistedQueueItem).toList(growable: false),
      currentIndex: index,
      positionMs: _player.position.inMilliseconds.clamp(0, 1 << 53).toInt(),
      repeatMode: _repeatMode.name,
      shuffleEnabled: _player.shuffleModeEnabled,
      speedRatio: _player.speed.clamp(0.7, 1.3).toDouble(),
      wasPlaying: _playbackRequested || _player.playing,
      updatedAt: _clock().toUtc(),
    );
    final operation = store.write(session);
    _playbackPersistenceInFlight = operation;
    try {
      await operation;
      _lastPersistedPositionMs = session.positionMs;
      AudioDiagnostics.instance.log('AUDIO_SESSION_PERSISTED', {
        'userId': userId,
        'queueLength': session.queue.length,
        'currentIndex': session.currentIndex,
        'positionMs': session.positionMs,
      });
    } catch (error, stackTrace) {
      _debugAudioLog(
        'persistance lecteur impossible user=$userId',
        error: error,
        stackTrace: stackTrace,
      );
      AudioDiagnostics.instance.log('AUDIO_SESSION_PERSIST_FAILED', {
        'userId': userId,
        'error': error,
      });
    } finally {
      if (identical(_playbackPersistenceInFlight, operation)) {
        _playbackPersistenceInFlight = null;
      }
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

  Duration? get currentAuthorizationExpiresIn =>
      _currentAuthorizationExpiresIn?.call();

  Map<String, Object?> get diagnosticState => <String, Object?>{
    'playing': _player.playing,
    'processingState': _player.processingState.name,
    'currentIndex': _activeQueueIndex,
    'queueLength': _queueItems.length,
    'trackId': _currentItem?.id,
    'positionMs': _player.position.inMilliseconds,
    'bufferedPositionMs': _player.bufferedPosition.inMilliseconds,
    'durationMs': _player.duration?.inMilliseconds,
    'repeatMode': _repeatMode.name,
    'shuffleMode': _player.shuffleModeEnabled,
    'playbackRequested': _playbackRequested,
    'sourceReady': _sourceReady,
    'tokenExpiresInMs': currentAuthorizationExpiresIn?.inMilliseconds,
    'bufferingCount': _bufferingCount,
    'totalBufferingMs': _totalBufferingMs,
    'longestBufferingMs': _longestBufferingMs,
    'authorizationRecoveryInFlight': _authorizationRecoveryInFlight != null,
    'trackRecoveryInFlight': _trackErrorRecoveryInFlight != null,
    'networkAvailable': _networkAvailable,
    'networkRecoveryPending': _networkRecoveryPending,
    'networkRecoveryAttempt': _networkRecoveryAttempt,
    'timeStretchEngine': currentTimeStretchEngineName,
    'timeStretchRatio': currentTrackSpeed,
    'timeStretchLatencyMs': currentTimeStretchLatencyMs,
  };

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
        _schedulePlaybackPersistence(immediate: true);
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
        _schedulePlaybackPersistence(immediate: true);
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
      if (_networkRecoveryPending) {
        _playbackRequested = true;
        final recovered = await _attemptNetworkRecovery();
        if (recovered) return;
      }
      // Une erreur native remet just_audio en idle. La file Dart existe
      // encore, mais appeler play() sur l'ancienne source ne peut pas la
      // ressusciter et peut réutiliser un Bearer périmé. Un appui sur Lecture
      // reconstruit donc la file au même index avec les headers courants.
      _playbackRequested = true;
      final index = (_activeQueueIndex ?? _currentQueueIndex ?? 0).clamp(
        0,
        _queueItems.length - 1,
      );
      final recovered = await _resumeAtIndexAfterError(_loadRequest, index);
      if (recovered) return;
      _playbackRequested = false;
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
  Future<void> pause() async {
    _playbackRequested = false;
    _networkRecoveryTimer?.cancel();
    _cancelEndOfTrackWatchdog();
    AudioDiagnostics.instance.log(
      'AUDIO_PLAY_PAUSED',
      _queueDiagnosticFields(),
    );
    await _player.pause();
    _schedulePlaybackPersistence(immediate: true);
  }

  @override
  Future<void> seek(Duration position) async {
    _ignorePositionWrapUntil = _clock().add(const Duration(seconds: 3));
    AudioDiagnostics.instance.log('AUDIO_SEEK_REQUESTED', {
      ..._queueDiagnosticFields(),
      'positionMs': position.inMilliseconds,
    });
    await _player.seek(position);
    AudioDiagnostics.instance.log('AUDIO_SEEK_COMPLETED', {
      ..._queueDiagnosticFields(),
      'positionMs': _player.position.inMilliseconds,
    });
    _schedulePlaybackPersistence(immediate: true);
  }

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
    AudioDiagnostics.instance.log('AUDIO_SHUFFLE_CHANGED', {
      ..._queueDiagnosticFields(),
      'enabled': enabled,
    });
    _schedulePlaybackPersistence(immediate: true);
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
    AudioDiagnostics.instance.log('AUDIO_REPEAT_CHANGED', {
      ..._queueDiagnosticFields(),
      'repeatMode': normalized.name,
    });
    _schedulePlaybackPersistence(immediate: true);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (!_sourceReady || index < 0 || index >= _queueItems.length) return;
    _cancelEndOfTrackWatchdog();
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
    AudioDiagnostics.instance.newQueueRevision();
    if (_sourceReady) {
      await _player.insertAudioSource(
        safeIndex,
        _createAudioSource(item, safeIndex, reason: 'insert'),
      );
    } else {
      await _player.setAudioSources(
        _createAudioSources(reason: 'insert-empty-player'),
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
    AudioDiagnostics.instance.log('AUDIO_QUEUE_APPENDED', {
      ..._queueDiagnosticFields(),
      'insertedIndex': safeIndex,
      'trackId': item.id,
    });
    _schedulePlaybackPersistence(immediate: true);
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
    AudioDiagnostics.instance.newQueueRevision();
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
    AudioDiagnostics.instance.log('AUDIO_QUEUE_REMOVED', {
      ..._queueDiagnosticFields(),
      'removedIndex': index,
      'trackId': removed.id,
    });
    _schedulePlaybackPersistence(immediate: true);
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
    AudioDiagnostics.instance.newQueueRevision();
    await _player.moveAudioSource(oldIndex, newIndex);
    _currentQueueIndex = _player.currentIndex ?? currentBefore;
    _publishQueue();
    AudioDiagnostics.instance.log('AUDIO_QUEUE_REORDERED', {
      ..._queueDiagnosticFields(),
      'oldIndex': oldIndex,
      'newIndex': newIndex,
      'trackId': item.id,
    });
    _schedulePlaybackPersistence(immediate: true);
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
    _networkRecoveryTimer?.cancel();
    _cancelEndOfTrackWatchdog();
    AudioDiagnostics.instance.log(
      'AUDIO_PLAY_STOPPED',
      _queueDiagnosticFields(),
    );
    await _player.stop();
    _broadcastPlaybackState(_player.playbackEvent);
    _schedulePlaybackPersistence(immediate: true);
  }

  /// Purge à la déconnexion : arrête la lecture, vide la file et le MediaItem
  /// courant. Aucune donnée du compte précédent ne subsiste dans le lecteur.
  Future<void> clearForLogout() => clearQueueAndStop(deletePersisted: true);

  /// Arrête la lecture et vide entièrement la file (déconnexion, suppression
  /// d'une piste de la bibliothèque). L'UI repart d'un lecteur vide, sans
  /// jamais réafficher un état périmé.
  Future<void> clearQueueAndStop({bool deletePersisted = true}) async {
    final persistedUserId = _playbackSessionUserId;
    _playbackPersistenceTimer?.cancel();
    _networkRecoveryTimer?.cancel();
    _cancelEndOfTrackWatchdog();
    _networkRecoveryPending = false;
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
    } catch (error, stackTrace) {
      _debugAudioLog(
        'purge lecteur au logout: échec',
        error: error,
        stackTrace: stackTrace,
      );
      AudioDiagnostics.instance.log('AUDIO_QUEUE_CLEAR_FAILED', {
        'error': error,
      });
    }
    _queueItems.clear();
    _currentQueueIndex = 0;
    _sourceReady = false;
    _playbackRequested = false;
    queue.add(const <MediaItem>[]);
    mediaItem.add(null);
    await _artworkCacheClear?.call();
    _broadcastPlaybackState(_player.playbackEvent);
    AudioDiagnostics.instance.newQueueRevision();
    AudioDiagnostics.instance.log('AUDIO_QUEUE_EMPTY');
    if (deletePersisted && persistedUserId != null) {
      try {
        await _playbackSessionStore?.delete(persistedUserId);
      } catch (error) {
        AudioDiagnostics.instance.log('AUDIO_SESSION_DELETE_FAILED', {
          'userId': persistedUserId,
          'error': error,
        });
      }
    }
    _playbackSessionUserId = null;
    _restoredPlaybackSessionUserId = null;
    _lastPersistedPositionMs = -1;
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
    AudioDiagnostics.instance.log('AUDIO_HANDLER_DISPOSED', diagnosticState);
    _playbackPersistenceTimer?.cancel();
    _networkRecoveryTimer?.cancel();
    _cancelEndOfTrackWatchdog();
    _playbackGuardTimer.cancel();
    await _persistPlaybackSession();
    await _interruptionSubscription?.cancel();
    await _becomingNoisySubscription?.cancel();
    await _playbackEventSubscription.cancel();
    await _playerStateSubscription.cancel();
    await _currentIndexSubscription.cancel();
    await _positionPersistenceSubscription.cancel();
    await _timeStretchEngine.dispose();
    await _player.dispose();
    AudioDiagnostics.instance.log('PLAYER_DISPOSED');
    await AudioDiagnostics.instance.flush();
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
    _networkRecoveryTimer?.cancel();
    final item = _currentItem;
    AudioDiagnostics.instance.log('AUDIO_PLAY_REQUESTED', {
      ..._queueDiagnosticFields(),
      'mediaItemId': item?.id,
    });
    _debugAudioLog(
      'play track=${item?.id ?? 'inconnu'} '
      'streamUri=${item?.streamUri ?? 'inconnue'} '
      'format=${item?.format ?? 'inconnu'} '
      'mimeType=${item?.mimeType ?? 'inconnu'} '
      'volume=${_player.volume} state=${_player.processingState.name} '
      'buffered=${_player.bufferedPosition}',
    );
    await _player.play();
    _schedulePlaybackPersistence(immediate: true);
  }

  List<AudioSource> _createAudioSources({required String reason}) {
    final stopwatch = Stopwatch()..start();
    _loadedAuthorizationHeader = _queueItems.isEmpty
        ? null
        : _queueItems.first.headers?['Authorization'];
    final sources = <AudioSource>[
      for (var index = 0; index < _queueItems.length; index++)
        _createAudioSource(_queueItems[index], index, reason: reason),
    ];
    AudioDiagnostics.instance.log('AUDIO_SOURCE_BATCH_CREATED', {
      ..._queueDiagnosticFields(),
      'reason': reason,
      'sourceCreationMs': stopwatch.elapsedMilliseconds,
      'sourceCount': sources.length,
    });
    return sources;
  }

  AudioSource _createAudioSource(
    PlayerQueueItem item,
    int index, {
    required String reason,
  }) {
    final diagnostics = AudioDiagnostics.instance;
    final sourceInstanceId = diagnostics.nextId('source');
    final requestId = diagnostics.nextId('request');
    final headers = <String, String>{
      ...?item.headers,
      'X-Request-Id': requestId,
      'X-App-Session-Id': diagnostics.appSessionId,
      if (diagnostics.playbackSessionId != null)
        'X-Playback-Session-Id': diagnostics.playbackSessionId!,
      if (diagnostics.queueRevisionId != null)
        'X-Queue-Revision-Id': diagnostics.queueRevisionId!,
      'X-Source-Instance-Id': sourceInstanceId,
    };
    diagnostics.log('AUDIO_SOURCE_CREATED', {
      ..._queueDiagnosticFields(currentIndex: index),
      'trackId': item.id,
      'mediaItemId': item.id,
      'sourceInstanceId': sourceInstanceId,
      'requestId': requestId,
      'hostname': item.streamUri.host,
      'route': '/api/tracks/:id/stream',
      'reason': reason,
      'tokenPresent':
          item.headers?['Authorization']?.startsWith('Bearer ') ?? false,
      'tokenExpiresInMs': currentAuthorizationExpiresIn?.inMilliseconds,
    });
    return item.toAudioSource(requestHeaders: headers);
  }

  Map<String, Object?> _queueDiagnosticFields({int? currentIndex}) =>
      <String, Object?>{
        'currentIndex': currentIndex ?? _activeQueueIndex,
        'previousIndex': _currentQueueIndex,
        'queueLength': _queueItems.length,
        'trackId': _currentItem?.id,
        'repeatMode': _repeatMode.name,
        'shuffleMode': _player.shuffleModeEnabled,
        'processingState': _player.processingState.name,
        'playing': _player.playing,
      };

  Future<void> _refreshAuthorizationBeforeLoadIfNeeded(int request) async {
    final expiresIn = currentAuthorizationExpiresIn;
    AudioDiagnostics.instance.log('AUDIO_TOKEN_STATE_CHECKED', {
      'tokenPresent':
          _currentAuthorizationHeaders?.call()['Authorization']?.startsWith(
            'Bearer ',
          ) ??
          false,
      'tokenExpiresInMs': expiresIn?.inMilliseconds,
    });
    if (expiresIn == null ||
        expiresIn > const Duration(seconds: 90) ||
        _authorizationRefresh == null ||
        request != _loadRequest) {
      return;
    }
    final refreshId = AudioDiagnostics.instance.nextId('auth-refresh');
    final stopwatch = Stopwatch()..start();
    AudioDiagnostics.instance.log('AUDIO_TOKEN_EXPIRY_APPROACHING', {
      'authRefreshId': refreshId,
      'tokenExpiresInMs': expiresIn.inMilliseconds,
    });
    AudioDiagnostics.instance.log('AUDIO_TOKEN_REFRESH_REQUESTED', {
      'authRefreshId': refreshId,
      'reason': 'preload',
    });
    final refreshed = await _authorizationRefresh();
    AudioDiagnostics.instance.log(
      refreshed
          ? 'AUDIO_TOKEN_REFRESH_COMPLETED'
          : 'AUDIO_TOKEN_REFRESH_FAILED',
      {
        'authRefreshId': refreshId,
        'refreshDurationMs': stopwatch.elapsedMilliseconds,
        'refreshResult': refreshed,
      },
    );
  }

  void _applyCurrentAuthorizationHeaders() {
    final headers = _currentAuthorizationHeaders?.call();
    final authorization = headers?['Authorization'];
    if (headers == null ||
        authorization == null ||
        !authorization.startsWith('Bearer ')) {
      return;
    }
    final refreshedItems = _queueItems
        .map((item) => item.copyWithHeaders(headers))
        .toList(growable: false);
    _queueItems
      ..clear()
      ..addAll(refreshedItems);
  }

  Future<Duration?> _setAudioSourcesWithAuthorizationRecovery({
    required int request,
    required int initialIndex,
    required Duration initialPosition,
    required bool preload,
  }) async {
    try {
      return await _player.setAudioSources(
        _createAudioSources(reason: 'queue-load'),
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

  /// Répercute immédiatement une rotation de JWT dans les sources Media3.
  ///
  /// Les headers HTTP d'une [AudioSource] sont immuables. Renouveler le token
  /// dans [AuthSessionManager] ne suffit donc pas : sans cette reconstruction,
  /// les lectures Range suivantes repartent avec l'ancien Bearer jusqu'au 401.
  Future<bool> handleAuthorizationChanged({
    String reason = 'session-change',
  }) async {
    final authorization = _currentAuthorizationHeaders?.call()['Authorization'];
    final hasUsableAuthorization =
        authorization != null && authorization.startsWith('Bearer ');
    final rotated =
        hasUsableAuthorization && authorization != _loadedAuthorizationHeader;
    AudioDiagnostics.instance.log('AUDIO_AUTHORIZATION_CHANGED', {
      ..._queueDiagnosticFields(),
      'reason': reason,
      'sourceReady': _sourceReady,
      'tokenPresent': hasUsableAuthorization,
      'rotated': rotated,
    });
    // Même si Media3 est actuellement en erreur/idle, la file en mémoire doit
    // immédiatement oublier l'ancien Bearer. La prochaine action Lecture la
    // reconstruira alors avec le jeton courant au lieu de rejouer les 401.
    if (hasUsableAuthorization) {
      _applyCurrentAuthorizationHeaders();
    }
    if (!rotated ||
        !_sourceReady ||
        _queueItems.isEmpty ||
        _activeQueueIndex == null) {
      return false;
    }
    final request = _loadRequest;
    final index = _activeQueueIndex!;
    final position = _player.position;
    final resumePlayback = _playbackRequested || _player.playing;
    final recovered = await _recoverAuthorization(
      request: request,
      initialIndex: index,
      initialPosition: position,
      resumePlayback: resumePlayback,
    );
    AudioDiagnostics.instance.log(
      recovered
          ? 'AUDIO_AUTHORIZATION_PROPAGATED'
          : 'AUDIO_AUTHORIZATION_PROPAGATION_FAILED',
      {
        ..._queueDiagnosticFields(),
        'reason': reason,
        'positionMs': position.inMilliseconds,
      },
    );
    return recovered;
  }

  /// Reçoit les transitions réseau du processus principal. `connectivity_plus`
  /// n'est qu'un signal : une interface disponible ne garantit pas que le
  /// serveur réponde, les erreurs natives restent donc le second déclencheur.
  Future<void> handleConnectivityChanged(bool hasNetwork) async {
    final changed = _networkAvailable != hasNetwork;
    _networkAvailable = hasNetwork;
    if (changed) {
      AudioDiagnostics.instance.log('AUDIO_NETWORK_STATE_CHANGED', {
        ..._queueDiagnosticFields(),
        'hasNetwork': hasNetwork,
        'recoveryPending': _networkRecoveryPending,
      });
    }
    if (!hasNetwork) {
      if (_playbackRequested && _currentItem != null) {
        _networkRecoveryPending = true;
        _networkRecoveryIndex = _activeQueueIndex;
        _networkRecoveryPosition = _player.position;
        _networkRecoveryTimer?.cancel();
        _schedulePlaybackPersistence(immediate: true);
      }
      return;
    }
    if (_networkRecoveryPending && _playbackRequested) {
      _scheduleNetworkRecovery(immediate: true);
    }
  }

  void _enterNetworkRecovery(
    int request,
    Object error, {
    StackTrace? stackTrace,
  }) {
    if (request != _loadRequest || _currentItem == null) return;
    _networkRecoveryPending = true;
    _networkRecoveryIndex = _activeQueueIndex;
    _networkRecoveryPosition = _player.position;
    _sourceReady = false;
    AudioDiagnostics.instance.log('AUDIO_NETWORK_RECOVERY_QUEUED', {
      ..._queueDiagnosticFields(),
      'positionMs': _networkRecoveryPosition.inMilliseconds,
      'httpStatus': _extractHttpStatus(error),
      'error': error,
    });
    if (stackTrace != null) {
      _debugAudioLog(
        'lecture suspendue en attente du réseau',
        error: error,
        stackTrace: stackTrace,
      );
    }
    playbackState.add(
      playbackState.value.copyWith(
        controls: const <MediaControl>[MediaControl.play, MediaControl.stop],
        processingState: AudioProcessingState.buffering,
        playing: false,
        updatePosition: _networkRecoveryPosition,
        queueIndex: _networkRecoveryIndex,
        errorMessage: 'Connexion interrompue, reprise automatique en attente.',
      ),
    );
    _schedulePlaybackPersistence(immediate: true);
    _scheduleNetworkRecovery(immediate: _networkAvailable);
  }

  void _scheduleNetworkRecovery({bool immediate = false}) {
    if (!_networkRecoveryPending || !_playbackRequested) return;
    _networkRecoveryTimer?.cancel();
    final exponent = _networkRecoveryAttempt.clamp(0, 4).toInt();
    final exponentialSeconds = 2 << exponent;
    final delay = immediate
        ? Duration.zero
        : Duration(
            seconds: exponentialSeconds
                .clamp(2, _networkRecoveryMaximumDelay.inSeconds)
                .toInt(),
          );
    AudioDiagnostics.instance.log('AUDIO_NETWORK_RECOVERY_SCHEDULED', {
      ..._queueDiagnosticFields(),
      'attempt': _networkRecoveryAttempt + 1,
      'delayMs': delay.inMilliseconds,
    });
    _networkRecoveryTimer = Timer(
      delay,
      () => unawaited(_attemptNetworkRecovery()),
    );
  }

  Future<bool> _attemptNetworkRecovery() {
    final active = _networkRecoveryInFlight;
    if (active != null) return active;
    if (!_networkRecoveryPending ||
        !_playbackRequested ||
        _queueItems.isEmpty) {
      return Future<bool>.value(false);
    }
    final operation = _performNetworkRecovery().whenComplete(() {
      _networkRecoveryInFlight = null;
    });
    _networkRecoveryInFlight = operation;
    return operation;
  }

  Future<bool> _performNetworkRecovery() async {
    final request = _loadRequest;
    final index = (_networkRecoveryIndex ?? _activeQueueIndex ?? 0).clamp(
      0,
      _queueItems.length - 1,
    );
    final position = _networkRecoveryPosition;
    _networkRecoveryTimer?.cancel();
    _networkRecoveryAttempt += 1;
    AudioDiagnostics.instance.log('AUDIO_NETWORK_RECOVERY_STARTED', {
      ..._queueDiagnosticFields(currentIndex: index),
      'attempt': _networkRecoveryAttempt,
      'positionMs': position.inMilliseconds,
    });
    try {
      await _refreshAuthorizationBeforeLoadIfNeeded(request);
      if (request != _loadRequest || !_playbackRequested) return false;
      _applyCurrentAuthorizationHeaders();
      await _setAudioSourcesWithAuthorizationRecovery(
        request: request,
        initialIndex: index,
        initialPosition: position,
        preload: true,
      );
      if (request != _loadRequest || !_playbackRequested) return false;
      _sourceReady = true;
      _currentQueueIndex = _player.currentIndex ?? index;
      _publishedMediaKey = null;
      _networkRecoveryPending = false;
      _networkRecoveryAttempt = 0;
      _publishQueue();
      _publishCurrentMediaItem(includeArtwork: true);
      _broadcastPlaybackState(_player.playbackEvent);
      _scheduleCurrentTrackSpeed();
      await _startPlayback();
      AudioDiagnostics.instance.log('AUDIO_NETWORK_RECOVERY_COMPLETED', {
        ..._queueDiagnosticFields(),
        'positionMs': position.inMilliseconds,
      });
      return true;
    } catch (error, stackTrace) {
      _sourceReady = false;
      _networkRecoveryPending = true;
      _networkRecoveryIndex = index;
      _networkRecoveryPosition = position;
      AudioDiagnostics.instance.log('AUDIO_NETWORK_RECOVERY_FAILED', {
        ..._queueDiagnosticFields(currentIndex: index),
        'attempt': _networkRecoveryAttempt,
        'error': error,
      });
      _debugAudioLog(
        'reprise réseau impossible, nouvelle tentative planifiée',
        error: error,
        stackTrace: stackTrace,
      );
      _scheduleNetworkRecovery();
      return false;
    }
  }

  static bool _isTransientNetworkFailure(Object error) {
    final status = _extractHttpStatus(error);
    if (status == 408 || status == 425 || status == 429) return true;
    if (status != null && status >= 500) return true;
    final message = error.toString().toLowerCase();
    return message.contains('timeout') ||
        message.contains('socket') ||
        message.contains('network') ||
        message.contains('connection') ||
        message.contains('unknown host') ||
        message.contains('host lookup') ||
        message.contains('temporarily unavailable');
  }

  void _handleAsynchronousPlaybackFailure(
    int request,
    Object error,
    StackTrace stackTrace,
  ) {
    // Sur Android, Media3 masque parfois InvalidResponseCodeException(401)
    // derrière le seul message "Source error". Si le gestionnaire de session
    // possède déjà un Bearer plus récent que la source native, cette rotation
    // est une preuve suffisante : reconstruire la même piste avant d'envisager
    // de la sauter.
    if (_isAuthorizationFailure(error) ||
        _authorizationHasRotatedSinceSourceCreation()) {
      if (_authorizationFailureHandling) {
        AudioDiagnostics.instance.log(
          'AUDIO_TOKEN_REFRESH_SINGLE_FLIGHT_JOINED',
          _queueDiagnosticFields(),
        );
        return;
      }
      _authorizationFailureHandling = true;
      final recoveryAttemptId = AudioDiagnostics.instance.nextId('recovery');
      AudioDiagnostics.instance.log('AUDIO_AUTH_RECOVERY_STARTED', {
        ..._queueDiagnosticFields(),
        'recoveryAttemptId': recoveryAttemptId,
        'httpStatus': _extractHttpStatus(error),
      });
      unawaited(
        _recoverAuthorization(
              request: request,
              initialIndex: _activeQueueIndex ?? 0,
              initialPosition: _player.position,
              resumePlayback: _playbackRequested,
            )
            .then((recovered) {
              AudioDiagnostics.instance.log(
                recovered
                    ? 'AUDIO_AUTH_RECOVERY_COMPLETED'
                    : 'AUDIO_AUTH_RECOVERY_FAILED',
                {
                  ..._queueDiagnosticFields(),
                  'recoveryAttemptId': recoveryAttemptId,
                },
              );
              if (recovered || request != _loadRequest) return;
              // Sans token valide, sauter de piste ne servirait à rien : l'échec
              // est publié tel quel (l'utilisateur voit l'erreur, rien n'est caché).
              final item = _currentItem;
              if (item != null) {
                _recordPlaybackFailure(item, error, stackTrace);
              }
            })
            .whenComplete(() => _authorizationFailureHandling = false),
      );
      return;
    }
    if (_isTransientNetworkFailure(error)) {
      _enterNetworkRecovery(request, error, stackTrace: stackTrace);
      return;
    }
    final item = _currentItem;
    if (item == null) return;
    final fingerprint =
        '${_activeQueueIndex ?? -1}|'
        '${_extractHttpStatus(error) ?? -1}|${error.runtimeType}|$error';
    final now = _clock();
    final duplicate =
        _lastHandledErrorFingerprint == fingerprint &&
        _lastHandledErrorAt != null &&
        now.difference(_lastHandledErrorAt!) < const Duration(seconds: 2);
    if (_trackErrorRecoveryInFlight != null || duplicate) {
      AudioDiagnostics.instance.log('AUDIO_DUPLICATE_ERROR_SUPPRESSED', {
        ..._queueDiagnosticFields(),
        'httpStatus': _extractHttpStatus(error),
        'recoveryInFlight': _trackErrorRecoveryInFlight != null,
      });
      return;
    }
    _lastHandledErrorFingerprint = fingerprint;
    _lastHandledErrorAt = now;
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
      'trackId': failedItem.id,
      'from': _activeQueueIndex,
      'to': target,
      'attempt': _consecutiveErrorSkips,
      'error': error.runtimeType,
      'recoveryAttemptId': AudioDiagnostics.instance.nextId('recovery'),
    });
    final recovery = _resumeAtIndexAfterError(request, target);
    _trackErrorRecoveryInFlight = recovery;
    unawaited(
      recovery
          .then((resumed) {
            if (!resumed && request == _loadRequest) {
              _recordPlaybackFailure(failedItem, error, StackTrace.current);
            }
          })
          .whenComplete(() {
            if (identical(_trackErrorRecoveryInFlight, recovery)) {
              _trackErrorRecoveryInFlight = null;
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
        _createAudioSources(reason: 'track-error-recovery'),
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
    final authorizationAlreadyRotated =
        _authorizationHasRotatedSinceSourceCreation();
    final now = _clock();
    final lastAttempt = _lastAuthorizationRecoveryAttemptAt;
    if (!authorizationAlreadyRotated &&
        lastAttempt != null &&
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
      // Le gestionnaire de session peut avoir renouvelé le JWT en amont alors
      // que Media3 lisait encore une source construite avec l'ancien Bearer.
      // Dans ce cas, reconstruire suffit : relancer /refresh consommerait à
      // tort une deuxième fois un refresh token rotatif.
      final authorizationAlreadyRotated =
          _authorizationHasRotatedSinceSourceCreation();
      final refreshed = authorizationAlreadyRotated
          ? true
          : await _authorizationRefresh!();
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
        _createAudioSources(reason: 'authorization-recovery'),
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
        'sourceRebuiltFromCurrentToken': authorizationAlreadyRotated,
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

  bool _authorizationHasRotatedSinceSourceCreation() {
    final authorization = _currentAuthorizationHeaders?.call()['Authorization'];
    return authorization != null &&
        authorization.startsWith('Bearer ') &&
        authorization != _loadedAuthorizationHeader;
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
    _cancelEndOfTrackWatchdog();
    _lastEndGuardIndex = index;
    _lastEndGuardPosition = Duration.zero;
    final previousIndex = _activeQueueIndex;
    AudioDiagnostics.instance.log('AUDIO_QUEUE_INDEX_CHANGED', {
      ..._queueDiagnosticFields(currentIndex: index),
      'previousIndex': previousIndex,
      'trackId': _queueItems[index].id,
      'sequenceLength': _player.sequence.length,
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
    _schedulePlaybackPersistence(immediate: true);
    if (previousIndex != null && previousIndex != index) {
      AudioDiagnostics.instance.log('AUDIO_TRACK_CHANGED', {
        ..._queueDiagnosticFields(currentIndex: index),
        'previousIndex': previousIndex,
        'trackId': _queueItems[index].id,
      });
    }
    if (_authorizationHasRotatedSinceSourceCreation()) {
      unawaited(handleAuthorizationChanged(reason: 'track-change'));
    }
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
      final tapStopwatch = _tapToPlaybackStopwatch;
      if (tapStopwatch != null) {
        _tapToPlaybackStopwatch = null;
        AudioDiagnostics.instance.log('AUDIO_PLAY_STARTED', {
          ..._queueDiagnosticFields(),
          'tapToPlaybackStartedMs': tapStopwatch.elapsedMilliseconds,
          'tapToFirstAudioMs': tapStopwatch.elapsedMilliseconds,
        });
      }
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
        errorCode: null,
        errorMessage: null,
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
    final previousState = _lastLoggedProcessingState;
    _lastLoggedProcessingState = state;
    final item = _currentItem;
    _debugAudioLog(
      'processingState track=${item?.id ?? 'inconnu'} '
      'state=${state.name} buffered=${_player.bufferedPosition}',
    );
    AudioDiagnostics.instance.log('AUDIO_PROCESSING_STATE_CHANGED', {
      'previousState': previousState?.name,
      'state': state.name,
      'playing': _player.playing,
      'currentIndex': _activeQueueIndex,
      'trackId': item?.id,
      'bufferedPositionMs': _player.bufferedPosition.inMilliseconds,
    });
    if (state == ProcessingState.buffering) {
      _bufferingStopwatch ??= Stopwatch()..start();
      _bufferingCount += 1;
      AudioDiagnostics.instance.log('AUDIO_SOURCE_BUFFERING_STARTED', {
        ..._queueDiagnosticFields(),
        'bufferingCount': _bufferingCount,
      });
    } else if (_bufferingStopwatch != null) {
      final durationMs = _bufferingStopwatch!.elapsedMilliseconds;
      _bufferingStopwatch = null;
      _totalBufferingMs += durationMs;
      if (durationMs > _longestBufferingMs) _longestBufferingMs = durationMs;
      AudioDiagnostics.instance.log('AUDIO_SOURCE_BUFFERING_ENDED', {
        ..._queueDiagnosticFields(),
        'bufferingDurationMs': durationMs,
        'totalBufferingMs': _totalBufferingMs,
        'longestBufferingMs': _longestBufferingMs,
      });
    }
    if (state == ProcessingState.completed) {
      _handleCompletedState(reason: 'native-completed');
    }
  }

  void _observeEndOfTrack(Duration position) {
    final current = _activeQueueIndex;
    final duration = _player.duration;
    final atLogicalEnd =
        duration != null &&
        duration > Duration.zero &&
        position >= duration - _endOfTrackPositionTolerance;
    final shouldWatch =
        _sourceReady &&
        !_restoringPlaybackSession &&
        _playbackRequested &&
        _player.playing &&
        _player.processingState == ProcessingState.ready &&
        _repeatMode != AudioServiceRepeatMode.one &&
        current != null &&
        atLogicalEnd;
    if (!shouldWatch) {
      _cancelEndOfTrackWatchdog();
      return;
    }
    if (_endOfTrackWatchdog != null && _endOfTrackWatchdogIndex == current) {
      return;
    }
    _cancelEndOfTrackWatchdog();
    _endOfTrackWatchdogIndex = current;
    AudioDiagnostics.instance.log('AUDIO_END_OF_TRACK_WATCHDOG_ARMED', {
      ..._queueDiagnosticFields(currentIndex: current),
      'positionMs': position.inMilliseconds,
      'durationMs': duration.inMilliseconds,
      'gracePeriodMs': _endOfTrackGracePeriod.inMilliseconds,
    });
    _endOfTrackWatchdog = Timer(_endOfTrackGracePeriod, () {
      _endOfTrackWatchdog = null;
      _endOfTrackWatchdogIndex = null;
      unawaited(_recoverStalledEndOfTrack(current, duration));
    });
  }

  void _runPlaybackGuard() {
    if (!_sourceReady || !_playbackRequested || _queueItems.isEmpty) return;
    final position = _player.position;
    _observePositionWrapAtEnd(position);
    _observeEndOfTrack(position);
  }

  void _observePositionWrapAtEnd(Duration position) {
    final current = _activeQueueIndex;
    final duration = _player.duration;
    final previous = _lastEndGuardIndex == current
        ? _lastEndGuardPosition
        : null;
    _lastEndGuardIndex = current;
    _lastEndGuardPosition = position;

    final ignoredUntil = _ignorePositionWrapUntil;
    if (ignoredUntil != null && _clock().isBefore(ignoredUntil)) return;
    final wrapped =
        current != null &&
        previous != null &&
        duration != null &&
        duration > Duration.zero &&
        previous.inMilliseconds >=
            (duration.inMilliseconds * 0.9).round() &&
        position <= _endOfTrackWrapDestinationTolerance;
    if (!wrapped ||
        !_sourceReady ||
        !_playbackRequested ||
        !_player.playing ||
        _repeatMode == AudioServiceRepeatMode.one) {
      return;
    }
    AudioDiagnostics.instance.log('AUDIO_END_OF_TRACK_POSITION_WRAPPED', {
      ..._queueDiagnosticFields(currentIndex: current),
      'previousPositionMs': previous.inMilliseconds,
      'positionMs': position.inMilliseconds,
      'durationMs': duration.inMilliseconds,
    });
    _handleCompletedState(reason: 'position-wrapped-at-logical-end');
  }

  void _cancelEndOfTrackWatchdog() {
    _endOfTrackWatchdog?.cancel();
    _endOfTrackWatchdog = null;
    _endOfTrackWatchdogIndex = null;
  }

  Future<void> _recoverStalledEndOfTrack(
    int expectedIndex,
    Duration expectedDuration,
  ) async {
    final duration = _player.duration;
    final stillAtEnd =
        duration != null &&
        duration > Duration.zero &&
        _player.position >= duration - _endOfTrackPositionTolerance;
    if (!_sourceReady ||
        !_playbackRequested ||
        !_player.playing ||
        _player.processingState != ProcessingState.ready ||
        _repeatMode == AudioServiceRepeatMode.one ||
        _activeQueueIndex != expectedIndex ||
        !stillAtEnd) {
      return;
    }

    AudioDiagnostics.instance.log('AUDIO_END_OF_TRACK_STALL_DETECTED', {
      ..._queueDiagnosticFields(currentIndex: expectedIndex),
      'positionMs': _player.position.inMilliseconds,
      'durationMs': duration.inMilliseconds,
      'expectedDurationMs': expectedDuration.inMilliseconds,
    });
    final target = _relativeQueueIndex(1);
    if (target == null) {
      await pause();
      _broadcastPlaybackState(_player.playbackEvent);
      AudioDiagnostics.instance.log('AUDIO_END_OF_TRACK_STALL_RECOVERED', {
        ..._queueDiagnosticFields(currentIndex: expectedIndex),
        'action': 'queue-ended',
      });
      return;
    }
    _handleCompletedState(reason: 'position-stalled-at-logical-end');
  }

  void _handleCompletedState({required String reason}) {
    _cancelEndOfTrackWatchdog();
    final current = _activeQueueIndex;
    final target = _repeatMode == AudioServiceRepeatMode.one
        ? current
        : _relativeQueueIndex(1);
    if (!_playbackRequested || current == null || target == null) {
      AudioDiagnostics.instance.log('AUDIO_QUEUE_ENDED', {
        ..._queueDiagnosticFields(),
      });
      return;
    }
    if (_autoAdvanceInFlight != null) {
      AudioDiagnostics.instance.log('AUDIO_QUEUE_AUTO_ADVANCE_EXPECTED', {
        ..._queueDiagnosticFields(),
        'targetIndex': target,
        'deduplicated': true,
      });
      return;
    }
    final recoveryAttemptId = AudioDiagnostics.instance.nextId('advance');
    AudioDiagnostics.instance.log('AUDIO_QUEUE_AUTO_ADVANCE_STARTED', {
      ..._queueDiagnosticFields(),
      'targetIndex': target,
      'recoveryAttemptId': recoveryAttemptId,
      'reason': reason,
    });
    final operation = _fallbackAutoAdvance(target, recoveryAttemptId);
    _autoAdvanceInFlight = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_autoAdvanceInFlight, operation)) {
          _autoAdvanceInFlight = null;
        }
      }),
    );
  }

  Future<void> _fallbackAutoAdvance(
    int target,
    String recoveryAttemptId,
  ) async {
    try {
      await skipToQueueItem(target);
      await _startPlayback();
      AudioDiagnostics.instance.log('AUDIO_QUEUE_AUTO_ADVANCE_COMPLETED', {
        ..._queueDiagnosticFields(),
        'targetIndex': target,
        'recoveryAttemptId': recoveryAttemptId,
      });
    } catch (error, stackTrace) {
      AudioDiagnostics.instance.log('AUDIO_QUEUE_AUTO_ADVANCE_FAILED', {
        ..._queueDiagnosticFields(),
        'targetIndex': target,
        'recoveryAttemptId': recoveryAttemptId,
        'error': error,
      });
      final item = _currentItem;
      if (item != null) _recordPlaybackFailure(item, error, stackTrace);
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
