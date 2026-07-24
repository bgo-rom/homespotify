import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../library/domain/track.dart';
import '../data/offline_manifest_store.dart';
import 'offline_index.dart';
import '../domain/offline_models.dart';

/// Source audio choisie pour UNE piste au moment du chargement de la file.
class ResolvedLocalSource {
  const ResolvedLocalSource({
    required this.uri,
    required this.profile,
    this.mimeType,
  });

  final Uri uri;
  final OfflineProfile profile;
  final String? mimeType;
}

class OfflinePlaybackSourceResolution {
  const OfflinePlaybackSourceResolution({
    required this.localSources,
    required this.serverReachable,
  });

  final Map<int, ResolvedLocalSource> localSources;
  final bool serverReachable;
}

/// Résolution de source offline :
///  - fichier local VÉRIFIÉ (présent, taille conforme, hash source courant) ;
///  - probe serveur utilisé uniquement pour choisir la source initiale ;
///  - l'original et la copie restent attachés ensemble pour la Phase 1C.
class OfflineSourceResolver {
  OfflineSourceResolver({
    required OfflineManifestStore store,
    required Future<String> Function() rootDirProvider,
    required Future<bool> Function() serverReachable,
  }) : _store = store,
       _rootDirProvider = rootDirProvider,
       _serverReachable = serverReachable;

  final OfflineManifestStore _store;
  final Future<String> Function() _rootDirProvider;
  final Future<bool> Function() _serverReachable;

  /// La meilleure copie locale par piste, UNIQUEMENT si le serveur est
  /// injoignable. Map vide = tout passe par l'original réseau.
  Future<Map<int, ResolvedLocalSource>> resolveLocalSources({
    required int userId,
    required List<Track> tracks,
  }) async {
    final resolution = await resolvePlaybackSources(
      userId: userId,
      tracks: tracks,
    );
    return resolution.serverReachable ? const {} : resolution.localSources;
  }

  /// Résout les copies locales disponibles sans les masquer quand le serveur
  /// répond. Le lecteur Phase 1C garde ainsi une solution de repli vérifiée.
  Future<OfflinePlaybackSourceResolution> resolvePlaybackSources({
    required int userId,
    required List<Track> tracks,
  }) async {
    final candidates = <int, ResolvedLocalSource>{};
    final root = await _rootDirProvider();
    final readyByTrack = <int, List<OfflineTrackRecord>>{};
    final records = await _store.listForUser(userId);
    for (final record in records) {
      if (record.status != OfflineDownloadStatus.ready) continue;
      readyByTrack.putIfAbsent(record.trackId, () => []).add(record);
    }
    for (final track in tracks) {
      final sourceSha256 = track.etag;
      if (sourceSha256 == null || sourceSha256.isEmpty) continue;
      final currentRecords =
          (readyByTrack[track.id] ?? const <OfflineTrackRecord>[])
              .where((record) => record.sourceSha256 == sourceSha256)
              .toList(growable: false);
      final best = _bestVerified(currentRecords, root);
      if (best != null) candidates[track.id] = best;
    }
    if (candidates.isEmpty) {
      return const OfflinePlaybackSourceResolution(
        localSources: {},
        serverReachable: true,
      );
    }
    // On ne sonde le serveur QUE s'il existe au moins une copie locale : en
    // ligne, l'original garde toujours la priorité.
    return OfflinePlaybackSourceResolution(
      localSources: Map.unmodifiable(candidates),
      serverReachable: await _serverReachable(),
    );
  }

  /// Ordre de préférence local : original (copie exacte) > opus_256 > opus_128.
  ResolvedLocalSource? _bestVerified(
    List<OfflineTrackRecord> records,
    String root,
  ) {
    const order = [
      OfflineProfile.original,
      OfflineProfile.opus256,
      OfflineProfile.opus128,
    ];
    for (final profile in order) {
      for (final record in records.where((r) => r.profile == profile)) {
        final relative = record.relativePath;
        if (relative == null) continue;
        final file = File('$root/offline/u${record.userId}/$relative');
        if (!file.existsSync()) continue;
        if (record.sizeBytes != null && file.lengthSync() != record.sizeBytes) {
          continue; // copie tronquée/corrompue : jamais servie
        }
        return ResolvedLocalSource(
          uri: Uri.file(file.path),
          profile: profile,
          mimeType: profile == OfflineProfile.original ? null : 'audio/ogg',
        );
      }
    }
    return null;
  }
}

/// Sonde de joignabilité RÉELLE : /health avec timeout court. connectivity_plus
/// n'est jamais une preuve d'accès au serveur (TD-Stabilisation-2026-07-21).
Future<bool> probeServerReachable(Dio dio) async {
  final cancelToken = CancelToken();
  final timer = Timer(
    const Duration(seconds: 2),
    () => cancelToken.cancel('health probe timeout'),
  );
  try {
    final response = await dio.get<dynamic>(
      '/health',
      options: Options(
        receiveTimeout: const Duration(seconds: 2),
        sendTimeout: const Duration(seconds: 2),
      ),
      cancelToken: cancelToken,
    );
    return (response.statusCode ?? 0) == 200;
  } on DioException {
    return false;
  } finally {
    timer.cancel();
  }
}

final offlineSourceResolverProvider = Provider<OfflineSourceResolver>((ref) {
  final dio = ref.watch(apiClientProvider);
  return OfflineSourceResolver(
    store: ref.watch(offlineManifestStoreProvider),
    // Même racine que l'index hors ligne (surchargée dans les tests).
    rootDirProvider: ref.watch(offlineRootDirProvider),
    serverReachable: () => probeServerReachable(dio),
  );
});
