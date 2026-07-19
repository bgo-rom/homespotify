import 'package:homespotify_mobile/src/features/library/data/favorites_api.dart';
import 'package:homespotify_mobile/src/features/library/data/playlists_api.dart';
import 'package:homespotify_mobile/src/features/library/domain/local_playlist.dart';

class FakeFavoritesRepository implements FavoritesRepository {
  FakeFavoritesRepository([Set<int> initial = const <int>{}])
    : ids = Set<int>.of(initial);

  Set<int> ids;

  @override
  Future<Set<int>> fetch() async => Set<int>.of(ids);

  @override
  Future<void> add(int trackId) async => ids.add(trackId);

  @override
  Future<void> remove(int trackId) async => ids.remove(trackId);
}

class FakePlaylistsRepository implements PlaylistsRepository {
  FakePlaylistsRepository([
    List<LocalPlaylist> initial = const <LocalPlaylist>[],
  ]) : playlists = List<LocalPlaylist>.of(initial);

  List<LocalPlaylist> playlists;
  int _nextId = 1000;

  @override
  Future<List<LocalPlaylist>> fetchAll() async => List.of(playlists);

  @override
  Future<LocalPlaylist> create(String name) async {
    final playlist = LocalPlaylist(
      id: '${_nextId++}',
      name: name,
      trackIds: const <int>[],
    );
    playlists.add(playlist);
    return playlist;
  }

  @override
  Future<LocalPlaylist> rename(String playlistId, String name) async =>
      _replace(playlistId, name: name);

  @override
  Future<void> delete(String playlistId) async {
    playlists.removeWhere((playlist) => playlist.id == playlistId);
  }

  @override
  Future<LocalPlaylist> addTrack(String playlistId, int trackId) async {
    final current = _find(playlistId);
    if (current.trackIds.contains(trackId)) return current;
    return _replace(playlistId, trackIds: <int>[...current.trackIds, trackId]);
  }

  @override
  Future<LocalPlaylist> removeTrack(String playlistId, int trackId) async {
    final current = _find(playlistId);
    return _replace(
      playlistId,
      trackIds: current.trackIds.where((id) => id != trackId).toList(),
    );
  }

  @override
  Future<LocalPlaylist> reorder(String playlistId, List<int> trackIds) async =>
      _replace(playlistId, trackIds: trackIds);

  LocalPlaylist _find(String id) =>
      playlists.firstWhere((playlist) => playlist.id == id);

  LocalPlaylist _replace(String id, {String? name, List<int>? trackIds}) {
    final index = playlists.indexWhere((playlist) => playlist.id == id);
    final current = playlists[index];
    final next = LocalPlaylist(
      id: id,
      name: name ?? current.name,
      trackIds: trackIds ?? current.trackIds,
    );
    playlists[index] = next;
    return next;
  }
}
