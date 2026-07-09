import 'dart:async';
import 'dart:developer' as developer;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

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

/// Métadonnées et URL natives d'une entrée de file audio.
///
/// Aucune donnée audio n'est conservée ici : [streamUri] est l'URL du fichier
/// original servi par le backend, que just_audio lit progressivement.
class PlayerQueueItem {
  const PlayerQueueItem({
    required this.id,
    required this.streamUri,
    required this.title,
    this.artist,
    this.album,
    this.artUri,
    this.duration,
    this.mimeType,
    this.extension,
    this.headers,
  });

  final String id;
  final Uri streamUri;
  final String title;
  final String? artist;
  final String? album;
  final Uri? artUri;
  final Duration? duration;
  final String? mimeType;
  final String? extension;
  final Map<String, String>? headers;

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
    Duration? resolvedDuration,
  }) {
    return MediaItem(
      id: id,
      title: title,
      artist: artist,
      album: album,
      artUri: includeArtwork ? artUri : null,
      duration: resolvedDuration ?? duration,
      extras: <String, dynamic>{
        'streamUri': streamUri.toString(),
        if (mimeType != null) 'mimeType': mimeType,
        if (extension != null) 'extension': extension,
        'format': format,
      },
    );
  }

  AudioSource toAudioSource() {
    return AudioSource.uri(streamUri, headers: headers, tag: toMediaItem());
  }
}

/// Erreur de lecture présentable sans exposer les détails natifs à l'UI.
class AudioPlaybackException implements Exception {
  const AudioPlaybackException(this.userMessage);

  final String userMessage;

  @override
  String toString() => userMessage;
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
  HomeSpotifyAudioHandler({AudioPlayer? player})
    : _player =
          player ??
          AudioPlayer(
            audioLoadConfiguration: const AudioLoadConfiguration(
              androidLoadControl: AndroidLoadControl(
                minBufferDuration: Duration(seconds: 30),
                maxBufferDuration: Duration(seconds: 120),
                bufferForPlaybackDuration: Duration(milliseconds: 2500),
                bufferForPlaybackAfterRebufferDuration: Duration(seconds: 5),
                prioritizeTimeOverSizeThresholds: true,
              ),
            ),
          ) {
    // Le gain applicatif démarre à l'unité. Il n'est jamais augmenté au-delà
    // de 1.0 et aucun effet DSP, ReplayGain ou normalisation n'est appliqué.
    _initialVolumeSetup = _player.setVolume(1.0);
    _audioSessionSetup = _configureAudioSession();
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
  final List<PlayerQueueItem> _queueItems = <PlayerQueueItem>[];

  late final Future<void> _initialVolumeSetup;
  late final Future<void> _audioSessionSetup;
  late final StreamSubscription<PlaybackEvent> _playbackEventSubscription;
  late final StreamSubscription<PlayerState> _playerStateSubscription;
  late final StreamSubscription<int?> _currentIndexSubscription;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSubscription;
  StreamSubscription<void>? _becomingNoisySubscription;

  int _loadRequest = 0;
  int? _currentQueueIndex;
  bool _sourceReady = false;
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
      queue.add(
        immutableItems
            .map((item) => item.toMediaItem())
            .toList(growable: false),
      );
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
      final loadedDuration = await _player.setAudioSources(
        immutableItems
            .map((item) => item.toAudioSource())
            .toList(growable: false),
        initialIndex: initialIndex,
        preload: true,
      );
      if (request != _loadRequest) return;

      _sourceReady = true;
      _currentQueueIndex = _player.currentIndex ?? initialIndex;
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

      await _startPlayback();
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

  Future<void> setVolume(double volume) {
    return _player.setVolume(volume.clamp(0.0, 1.0).toDouble());
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
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() async {
    final currentIndex = _activeQueueIndex;
    if (currentIndex == null || currentIndex >= _queueItems.length - 1) return;
    await skipToQueueItem(currentIndex + 1);
  }

  @override
  Future<void> skipToPrevious() async {
    final currentIndex = _activeQueueIndex;
    if (currentIndex == null || currentIndex <= 0) return;
    await skipToQueueItem(currentIndex - 1);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (!_sourceReady || index < 0 || index >= _queueItems.length) return;
    final item = _queueItems[index];
    _currentQueueIndex = index;
    _publishCurrentMediaItem(includeArtwork: false);
    _debugAudioLog(
      'saut queue track=${item.id} index=$index streamUri=${item.streamUri} '
      'format=${item.format} mimeType=${item.mimeType ?? 'inconnu'}',
    );
    try {
      await _player.seek(Duration.zero, index: index);
      _broadcastPlaybackState(_player.playbackEvent);
    } catch (error, stackTrace) {
      _recordPlaybackFailure(item, error, stackTrace);
      throw AudioPlaybackException(_friendlyAudioError(error));
    }
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    _broadcastPlaybackState(_player.playbackEvent);
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
    await _interruptionSubscription?.cancel();
    await _becomingNoisySubscription?.cancel();
    await _playbackEventSubscription.cancel();
    await _playerStateSubscription.cancel();
    await _currentIndexSubscription.cancel();
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
    await _initialVolumeSetup;
    await _audioSessionSetup;
  }

  Future<void> _startPlayback() async {
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

  void _onCurrentIndexChanged(int? index) {
    if (index == null || index < 0 || index >= _queueItems.length) return;
    _currentQueueIndex = index;
    _publishedMediaKey = null;
    _publishCurrentMediaItem(
      includeArtwork:
          _player.processingState == ProcessingState.ready ||
          _player.processingState == ProcessingState.completed,
    );
    _broadcastPlaybackState(_player.playbackEvent);
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
    if (item != null) {
      _recordPlaybackFailure(item, error, stackTrace, logError: false);
    }
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
    final key = '${item.id}|$includeArtwork|${duration?.inMilliseconds ?? -1}';
    if (key == _publishedMediaKey) return;
    _publishedMediaKey = key;
    mediaItem.add(
      item.toMediaItem(
        includeArtwork: includeArtwork,
        resolvedDuration: duration,
      ),
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
