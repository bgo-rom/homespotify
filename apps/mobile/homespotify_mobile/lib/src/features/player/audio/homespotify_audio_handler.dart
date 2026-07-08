import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

final audioHandlerProvider = Provider<HomeSpotifyAudioHandler>((ref) {
  throw StateError('audioHandlerProvider must be overridden at startup.');
});

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
      subA = a.listen((v) {
        lastA = v;
        hasA = true;
        emit();
      }, onError: controller.addError);
      subB = b.listen((v) {
        lastB = v;
        hasB = true;
        emit();
      }, onError: controller.addError);
      subC = c.listen((v) {
        lastC = v;
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
    : _player = player ?? AudioPlayer() {
    _playbackEventSubscription = _player.playbackEventStream.listen(
      _broadcastPlaybackState,
      onError: _broadcastPlaybackError,
    );
    _playerStateSubscription = _player.playerStateStream.listen((_) {
      _broadcastPlaybackState(_player.playbackEvent);
    });
  }

  final AudioPlayer _player;

  late final StreamSubscription<PlaybackEvent> _playbackEventSubscription;
  late final StreamSubscription<PlayerState> _playerStateSubscription;

  Future<void> setTrack({
    required String trackId,
    required Uri streamUri,
    required String title,
    String? artist,
    String? album,
    Uri? artUri,
    Duration? duration,
    Map<String, String>? headers,
  }) async {
    final item = MediaItem(
      id: trackId,
      title: title,
      artist: artist,
      album: album,
      artUri: artUri,
      duration: duration,
      extras: {'streamUrl': streamUri.toString()},
    );

    mediaItem.add(item);
    await _player.setAudioSource(AudioSource.uri(streamUri, headers: headers));
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

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
    await _playbackEventSubscription.cancel();
    await _playerStateSubscription.cancel();
    await _player.dispose();
  }

  void _broadcastPlaybackState(PlaybackEvent event) {
    playbackState.add(
      playbackState.value.copyWith(
        controls: _controlsFor(_player.playing),
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1],
        processingState: _mapProcessingState(_player.processingState),
        playing: _player.playing,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: event.currentIndex,
      ),
    );
  }

  void _broadcastPlaybackError(Object error, StackTrace stackTrace) {
    playbackState.add(
      playbackState.value.copyWith(
        controls: const [MediaControl.play, MediaControl.stop],
        processingState: AudioProcessingState.error,
        playing: false,
        errorMessage: error.toString(),
      ),
    );
  }

  List<MediaControl> _controlsFor(bool playing) {
    return [
      if (playing) MediaControl.pause else MediaControl.play,
      MediaControl.stop,
    ];
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
}
