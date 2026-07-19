import 'package:dio/dio.dart';

import '../domain/local_playlist.dart';

abstract interface class PlaylistsRepository {
  Future<List<LocalPlaylist>> fetchAll();
  Future<LocalPlaylist> create(String name);
  Future<LocalPlaylist> rename(String playlistId, String name);
  Future<void> delete(String playlistId);
  Future<LocalPlaylist> addTrack(String playlistId, int trackId);
  Future<LocalPlaylist> removeTrack(String playlistId, int trackId);
  Future<LocalPlaylist> reorder(String playlistId, List<int> trackIds);
}

/// Accès backend aux playlists de l'utilisateur courant. Le userId vient du
/// token ; les IDs serveur (entiers) sont exposés en chaîne à l'UI existante
/// (`LocalPlaylist.id`, compatible `[a-z0-9_-]+`).
class PlaylistsApi implements PlaylistsRepository {
  PlaylistsApi(this._dio);

  final Dio _dio;

  LocalPlaylist _fromJson(Map<String, dynamic> json) {
    final rawTrackIds = json['trackIds'];
    final trackIds = rawTrackIds is List
        ? rawTrackIds.whereType<num>().map((value) => value.toInt()).toList()
        : <int>[];
    return LocalPlaylist(
      id: '${json['id']}',
      name: (json['name'] as String?)?.trim() ?? '',
      trackIds: List<int>.unmodifiable(trackIds),
    );
  }

  @override
  Future<List<LocalPlaylist>> fetchAll() async {
    final res = await _dio.get<Map<String, dynamic>>('/api/playlists');
    final items = res.data?['items'];
    if (items is! List) return const <LocalPlaylist>[];
    return items
        .whereType<Map<String, dynamic>>()
        .map(_fromJson)
        .toList(growable: false);
  }

  @override
  Future<LocalPlaylist> create(String name) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/api/playlists',
      data: {'name': name},
    );
    return _fromJson(res.data!);
  }

  @override
  Future<LocalPlaylist> rename(String playlistId, String name) async {
    final res = await _dio.patch<Map<String, dynamic>>(
      '/api/playlists/$playlistId',
      data: {'name': name},
    );
    return _fromJson(res.data!);
  }

  @override
  Future<void> delete(String playlistId) async {
    await _dio.delete<void>('/api/playlists/$playlistId');
  }

  @override
  Future<LocalPlaylist> addTrack(String playlistId, int trackId) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/api/playlists/$playlistId/tracks',
      data: {'trackId': trackId},
    );
    return _fromJson(res.data!);
  }

  @override
  Future<LocalPlaylist> removeTrack(String playlistId, int trackId) async {
    final res = await _dio.delete<Map<String, dynamic>>(
      '/api/playlists/$playlistId/tracks/$trackId',
    );
    return _fromJson(res.data!);
  }

  @override
  Future<LocalPlaylist> reorder(String playlistId, List<int> trackIds) async {
    final res = await _dio.put<Map<String, dynamic>>(
      '/api/playlists/$playlistId/order',
      data: {'trackIds': trackIds},
    );
    return _fromJson(res.data!);
  }
}
