import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/network/api_client.dart';
import '../data/library_api.dart';
import '../data/playlists_api.dart';
import '../domain/local_playlist.dart';
import '../domain/track.dart';

class PlaylistValidationException implements Exception {
  const PlaylistValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Playlists servies par le backend (source de vérité par compte). Au logout,
/// l'invalidation de ce provider vide les playlists de l'ancien compte.
final playlistsApiProvider = Provider<PlaylistsRepository>(
  (ref) => PlaylistsApi(ref.watch(apiClientProvider)),
);

class PlaylistsController extends AsyncNotifier<List<LocalPlaylist>> {
  final Set<String> _pendingMembershipChanges = <String>{};

  PlaylistsRepository get _api => ref.read(playlistsApiProvider);

  @override
  Future<List<LocalPlaylist>> build() async {
    final playlists = await _api.fetchAll();
    return List<LocalPlaylist>.unmodifiable(playlists);
  }

  Future<LocalPlaylist> create(String rawName) async {
    final trimmed = rawName.trim();
    if (trimmed.isEmpty) {
      throw const PlaylistValidationException(
        'Le nom de la playlist est obligatoire.',
      );
    }
    try {
      final created = await _api.create(trimmed);
      await _reload(
        'création playlist: id=${created.id} nom="${created.name}"',
      );
      return created;
    } on DioException catch (error) {
      throw PlaylistValidationException(_message(error, 'créer la playlist'));
    }
  }

  Future<bool> rename(String playlistId, String rawName) async {
    final trimmed = rawName.trim();
    if (trimmed.isEmpty) {
      throw const PlaylistValidationException(
        'Le nom de la playlist est obligatoire.',
      );
    }
    try {
      await _api.rename(playlistId, trimmed);
      await _reload('renommage playlist: id=$playlistId');
      return true;
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return false;
      throw PlaylistValidationException(
        _message(error, 'renommer la playlist'),
      );
    }
  }

  Future<bool> addTrack(String playlistId, int trackId) async {
    final current = state.asData?.value;
    if (current != null &&
        current.any(
          (playlist) =>
              playlist.id == playlistId && playlist.trackIds.contains(trackId),
        )) {
      return false;
    }
    if (!_pendingMembershipChanges.add(playlistId)) return false;
    final optimistic = _setTrackMembership(playlistId, trackId, present: true);
    try {
      final updated = await _api.addTrack(playlistId, trackId);
      _replacePlaylist(updated);
      logLibrary(
        'ajout piste playlist: playlistId=$playlistId trackId=$trackId',
      );
      return true;
    } on DioException catch (error) {
      if (optimistic) {
        _setTrackMembership(playlistId, trackId, present: false);
      }
      if (error.response?.statusCode == 404) return false;
      throw PlaylistValidationException(_message(error, 'ajouter la piste'));
    } finally {
      _pendingMembershipChanges.remove(playlistId);
    }
  }

  Future<bool> removeTrack(String playlistId, int trackId) async {
    final current = state.asData?.value;
    if (current != null &&
        current.any(
          (playlist) =>
              playlist.id == playlistId && !playlist.trackIds.contains(trackId),
        )) {
      return false;
    }
    if (!_pendingMembershipChanges.add(playlistId)) return false;
    final optimistic = _setTrackMembership(playlistId, trackId, present: false);
    try {
      final updated = await _api.removeTrack(playlistId, trackId);
      _replacePlaylist(updated);
      logLibrary(
        'retrait piste playlist: playlistId=$playlistId trackId=$trackId',
      );
      return true;
    } on DioException catch (error) {
      if (optimistic) {
        _setTrackMembership(playlistId, trackId, present: true);
      }
      if (error.response?.statusCode == 404) return false;
      throw PlaylistValidationException(_message(error, 'retirer la piste'));
    } finally {
      _pendingMembershipChanges.remove(playlistId);
    }
  }

  Future<bool> delete(String playlistId) async {
    try {
      await _api.delete(playlistId);
      await _reload('suppression playlist: id=$playlistId');
      return true;
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return false;
      throw PlaylistValidationException(
        _message(error, 'supprimer la playlist'),
      );
    }
  }

  Future<bool> reorder(String playlistId, List<int> trackIds) async {
    try {
      await _api.reorder(playlistId, List<int>.unmodifiable(trackIds));
      await _reload('réordonnancement playlist: id=$playlistId');
      return true;
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return false;
      throw PlaylistValidationException(
        _message(error, 'réordonner la playlist'),
      );
    }
  }

  /// Recharge la liste depuis le backend (source de vérité).
  Future<void> _reload(String logMessage) async {
    final playlists = await _api.fetchAll();
    state = AsyncData(List<LocalPlaylist>.unmodifiable(playlists));
    logLibrary(logMessage);
  }

  bool _setTrackMembership(
    String playlistId,
    int trackId, {
    required bool present,
  }) {
    final current = state.asData?.value;
    if (current == null) return false;
    final index = current.indexWhere((playlist) => playlist.id == playlistId);
    if (index < 0) return false;
    final playlist = current[index];
    final contains = playlist.trackIds.contains(trackId);
    if (contains == present) return false;
    final trackIds = present
        ? <int>[...playlist.trackIds, trackId]
        : playlist.trackIds.where((id) => id != trackId).toList();
    final updated = LocalPlaylist(
      id: playlist.id,
      name: playlist.name,
      trackIds: List<int>.unmodifiable(trackIds),
    );
    final next = List<LocalPlaylist>.of(current)..[index] = updated;
    state = AsyncData(List<LocalPlaylist>.unmodifiable(next));
    return true;
  }

  void _replacePlaylist(LocalPlaylist updated) {
    final current = state.asData?.value;
    if (current == null) return;
    final index = current.indexWhere((playlist) => playlist.id == updated.id);
    if (index < 0) return;
    final next = List<LocalPlaylist>.of(current)..[index] = updated;
    state = AsyncData(List<LocalPlaylist>.unmodifiable(next));
  }

  String _message(DioException error, String action) {
    final data = error.response?.data;
    if (data is Map && data['message'] is String) {
      return data['message'] as String;
    }
    return 'Impossible de $action.';
  }
}

final playlistsProvider =
    AsyncNotifierProvider<PlaylistsController, List<LocalPlaylist>>(
      PlaylistsController.new,
      name: 'playlists',
    );

final playlistByIdProvider = Provider.family<LocalPlaylist?, String>((
  ref,
  playlistId,
) {
  final playlists = ref.watch(playlistsProvider).asData?.value;
  if (playlists == null) return null;
  for (final playlist in playlists) {
    if (playlist.id == playlistId) return playlist;
  }
  return null;
});

final playlistTracksProvider = Provider.family<List<Track>, String>((
  ref,
  playlistId,
) {
  final playlist = ref.watch(playlistByIdProvider(playlistId));
  final tracks = ref.watch(libraryProvider).asData?.value ?? const <Track>[];
  if (playlist == null || tracks.isEmpty) return const <Track>[];
  final tracksById = <int, Track>{for (final track in tracks) track.id: track};
  return playlist.trackIds
      .map((id) => tracksById[id])
      .whereType<Track>()
      .toList(growable: false);
});
