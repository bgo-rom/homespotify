// ignore_for_file: prefer_initializing_formals

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import 'offline_index.dart';

/// Cache durable des pochettes liées aux copies hors ligne.
///
/// Le chemin est entièrement dérivé d'identifiants internes : aucune donnée
/// distante ne participe au nom de fichier. L'écriture passe par `.part` puis
/// un renommage atomique afin qu'une coupure ne publie jamais une image
/// tronquée.
class OfflineArtworkCache {
  OfflineArtworkCache({
    required Dio dio,
    required Future<String> Function() rootDirProvider,
  }) : _dio = dio,
       _rootDirProvider = rootDirProvider;

  static const _maxCoverBytes = 10 * 1024 * 1024;

  final Dio _dio;
  final Future<String> Function() _rootDirProvider;
  final Map<String, Future<bool>> _inFlight = {};

  Future<bool> ensureCover({required int userId, required int trackId}) {
    final key = '$userId:$trackId';
    return _inFlight.putIfAbsent(key, () async {
      try {
        return await _downloadCover(userId: userId, trackId: trackId);
      } finally {
        _inFlight.remove(key);
      }
    });
  }

  Future<bool> _downloadCover({
    required int userId,
    required int trackId,
  }) async {
    final root = await _rootDirProvider();
    final finalFile = File(offlineCoverPath(root, userId, trackId));
    if (finalFile.existsSync() && finalFile.lengthSync() > 0) return false;

    final directory = finalFile.parent;
    await directory.create(recursive: true);
    final partFile = File('${finalFile.path}.part');
    if (partFile.existsSync()) partFile.deleteSync();

    try {
      final response = await _dio.get<ResponseBody>(
        '/api/tracks/$trackId/cover',
        options: Options(
          responseType: ResponseType.stream,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
      if (response.statusCode != 200 || response.data == null) return false;

      final contentType = response.headers.value(Headers.contentTypeHeader);
      if (contentType == null ||
          (!contentType.startsWith('image/jpeg') &&
              !contentType.startsWith('image/png'))) {
        return false;
      }

      final sink = partFile.openWrite(mode: FileMode.write);
      var received = 0;
      try {
        await for (final chunk in response.data!.stream) {
          received += chunk.length;
          if (received > _maxCoverBytes) {
            throw const FormatException('Pochette trop volumineuse.');
          }
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (received == 0) return false;
      if (finalFile.existsSync()) finalFile.deleteSync();
      partFile.renameSync(finalFile.path);
      return true;
    } catch (_) {
      return false;
    } finally {
      if (partFile.existsSync()) partFile.deleteSync();
    }
  }

  /// Enrichit les téléchargements historiques, séquentiellement pour rester
  /// sobre sur le serveur personnel et éviter une rafale de requêtes.
  Future<bool> ensureMissingCovers(OfflineIndex index) async {
    final userId = index.userId;
    if (userId == null) return false;
    var changed = false;
    for (final trackId in index.availableTrackIds) {
      if (index.coverUriForTrack(trackId) != null) continue;
      changed = await ensureCover(userId: userId, trackId: trackId) || changed;
    }
    return changed;
  }
}

final offlineArtworkCacheProvider = Provider<OfflineArtworkCache>((ref) {
  return OfflineArtworkCache(
    dio: ref.watch(apiClientProvider),
    rootDirProvider: ref.watch(offlineRootDirProvider),
  );
});
