import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../player/audio/homespotify_audio_handler.dart';
import '../data/library_api.dart';
import '../domain/track.dart';

abstract interface class LibraryPlaybackController {
  Future<void> playQueue({
    required List<Track> tracks,
    required int initialIndex,
  });
}

class HomeSpotifyLibraryPlaybackController
    implements LibraryPlaybackController {
  const HomeSpotifyLibraryPlaybackController(this._api, this._handler);

  final LibraryApi _api;
  final HomeSpotifyAudioHandler _handler;

  @override
  Future<void> playQueue({
    required List<Track> tracks,
    required int initialIndex,
  }) {
    return _handler.setQueueAndPlay(
      items: tracks
          .map(
            (track) => PlayerQueueItem(
              id: '${track.id}',
              streamUri: _api.streamUri(track.id),
              title: track.title,
              artist: track.artist,
              album: track.album.isEmpty ? null : track.album,
              artUri: track.hasCover ? _api.coverUri(track.id) : null,
              duration: track.duration,
              mimeType: track.mimeType,
              extension: track.extension,
            ),
          )
          .toList(growable: false),
      initialIndex: initialIndex,
    );
  }
}

final libraryPlaybackControllerProvider = Provider<LibraryPlaybackController>((
  ref,
) {
  return HomeSpotifyLibraryPlaybackController(
    ref.watch(libraryApiProvider),
    ref.watch(audioHandlerProvider),
  );
});
