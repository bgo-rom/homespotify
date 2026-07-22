import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_controller.dart';
import '../../offline/application/offline_source_resolver.dart';
import '../../player/audio/homespotify_audio_handler.dart';
import '../data/library_api.dart';
import '../domain/track.dart';
import 'library_albums.dart';
import 'library_artists.dart';

PlayerQueueItem playerQueueItemForTrack({
  required Track track,
  required LibraryApi api,
  required int userId,
  required Map<String, String> authorizationHeaders,
  String origin = 'Bibliothèque',
  // Copie locale VÉRIFIÉE à utiliser à la place du flux réseau (serveur
  // injoignable). Décidée AVANT le chargement de la file — jamais en cours de
  // titre (TD-Offline-Opus).
  ResolvedLocalSource? localSource,
}) => PlayerQueueItem(
  id: '${track.id}',
  userId: userId,
  streamUri: localSource?.uri ?? api.streamUri(track.id),
  headers: localSource != null || authorizationHeaders.isEmpty
      ? null
      : authorizationHeaders,
  artworkIdentity: track.etag,
  title: track.title,
  artist: track.artist,
  album: track.album.isEmpty ? null : track.album,
  artUri: track.hasCover ? api.coverUri(track.id) : null,
  duration: track.duration,
  mimeType: localSource?.mimeType ?? track.mimeType,
  extension: track.extension,
  sampleRate: track.quality?.sampleRate,
  bitDepth: track.quality?.bitDepth,
  channels: track.quality?.channels,
  bitrate: track.quality?.bitrate,
  fileSize: track.sizeBytes,
  origin: origin,
  artistKey: track.artist.trim().isEmpty
      ? null
      : artistKeyForName(track.artist),
  albumKey: track.album.trim().isEmpty ? null : albumKeyForTitle(track.album),
);

abstract interface class LibraryPlaybackController {
  Future<void> playQueue({
    required List<Track> tracks,
    required int initialIndex,
  });
}

class HomeSpotifyLibraryPlaybackController
    implements LibraryPlaybackController {
  const HomeSpotifyLibraryPlaybackController(
    this._api,
    this._handler,
    this._authorizationHeaders,
    this._userId,
    this._sourceResolver,
  );

  final LibraryApi _api;
  final HomeSpotifyAudioHandler _handler;
  final Map<String, String> _authorizationHeaders;
  final int _userId;
  final OfflineSourceResolver? _sourceResolver;

  @override
  Future<void> playQueue({
    required List<Track> tracks,
    required int initialIndex,
  }) async {
    // Sélection de source AVANT de charger la file : serveur joignable →
    // original réseau pour toutes les pistes ; injoignable → copies locales
    // vérifiées. Aucune bascule ensuite pendant un titre.
    var localSources = const <int, ResolvedLocalSource>{};
    final resolver = _sourceResolver;
    if (resolver != null) {
      try {
        localSources = await resolver.resolveLocalSources(
          userId: _userId,
          tracks: tracks,
        );
      } catch (_) {
        // Résolution locale en échec : on garde le comportement réseau existant.
        localSources = const {};
      }
    }
    return _handler.setQueueAndPlay(
      items: tracks
          .map(
            (track) => playerQueueItemForTrack(
              track: track,
              api: _api,
              userId: _userId,
              authorizationHeaders: _authorizationHeaders,
              localSource: localSources[track.id],
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
    ref.watch(mediaAuthorizationHeadersProvider),
    ref.watch(authControllerProvider.select((state) => state.user?.id)) ?? 0,
    ref.watch(offlineSourceResolverProvider),
  );
});
