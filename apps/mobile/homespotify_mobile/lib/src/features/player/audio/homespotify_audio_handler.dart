import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

final audioHandlerProvider = Provider<HomeSpotifyAudioHandler>((ref) {
  throw StateError('audioHandlerProvider must be overridden at startup.');
});

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
