import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/domain/track.dart';
import 'offline_index.dart';
import '../data/offline_api.dart';
import '../data/offline_manifest_store.dart';
import '../domain/offline_models.dart';

/// Erreur de téléchargement présentable. `canRetry` guide l'UI.
class OfflineDownloadException implements Exception {
  OfflineDownloadException(
    this.message, {
    this.canRetry = true,
    this.waitingForNetwork = false,
  });
  final String message;
  final bool canRetry;
  final bool waitingForNetwork;
  @override
  String toString() => message;
}

/// Téléchargement d'UNE piste vers le cache hors ligne du compte.
///
/// Déroulé : (1) préparation de la variante serveur (202 → sondage borné),
/// (2) téléchargement `.part` repris par HTTP Range, (3) vérification SHA-256
/// en flux, (4) publication locale ATOMIQUE (rename) + manifeste `ready`.
/// Aucun transcodage mobile ; l'original vient de la route Range canonique.
class OfflineTrackDownloader {
  OfflineTrackDownloader({
    required OfflineApi api,
    required OfflineManifestStore store,
    required Future<String> Function() rootDirProvider,
    Duration pollInterval = const Duration(seconds: 2),
    int maxPollAttempts = 150,
  }) : _api = api,
       _store = store,
       _rootDirProvider = rootDirProvider,
       _pollInterval = pollInterval,
       _maxPollAttempts = maxPollAttempts;

  final OfflineApi _api;
  final OfflineManifestStore _store;
  final Future<String> Function() _rootDirProvider;
  final Duration _pollInterval;
  final int _maxPollAttempts;

  /// Dossier hors ligne CONFINÉ du compte : `<support>/offline/u<userId>`.
  Future<Directory> _userDir(int userId) async {
    final root = await _rootDirProvider();
    return Directory('$root/offline/u$userId').create(recursive: true);
  }

  Future<OfflineTrackRecord> download({
    required int userId,
    required Track track,
    required OfflineProfile profile,
    CancelToken? cancelToken,
    void Function(OfflineDownloadProgress progress)? onProgress,
  }) async {
    final report = onProgress ?? (OfflineDownloadProgress _) {};
    _throwIfCancelled(cancelToken);
    final target = await _resolveTarget(track, profile, report, cancelToken);
    final Directory dir;
    try {
      dir = await _userDir(userId);
    } on FileSystemException {
      throw OfflineDownloadException(
        'Impossible de préparer le stockage hors ligne. Vérifie l’espace disponible.',
      );
    }
    final extension = profile == OfflineProfile.original
        ? (track.extension ?? '.wav')
        : '.ogg';
    final relativePath = '${track.id}-${profile.wire}$extension';
    final finalFile = File('${dir.path}/$relativePath');
    final partFile = File('${finalFile.path}.part');
    final existing = await _store.find(userId, track.id, profile);
    if (existing != null &&
        existing.status == OfflineDownloadStatus.ready &&
        existing.sourceSha256 == target.sourceSha256 &&
        existing.expectedSha256 == target.expectedSha256 &&
        existing.relativePath == relativePath &&
        finalFile.existsSync() &&
        (existing.sizeBytes == null ||
            finalFile.lengthSync() == existing.sizeBytes)) {
      report(
        OfflineDownloadProgress(
          status: OfflineDownloadStatus.ready,
          receivedBytes: existing.sizeBytes ?? finalFile.lengthSync(),
          totalBytes: existing.sizeBytes,
        ),
      );
      return existing;
    }

    var record = OfflineTrackRecord(
      userId: userId,
      trackId: track.id,
      profile: profile,
      sourceSha256: target.sourceSha256,
      expectedSha256: target.expectedSha256,
      sizeBytes: target.sizeBytes,
      status: OfflineDownloadStatus.downloading,
      receivedBytes: 0,
      codec: target.codec,
      container: target.container,
      lossy: target.lossy,
      measuredBitrateKbps: target.measuredBitrateKbps,
      title: track.title,
      artist: track.artist,
      album: track.album,
      durationSeconds: track.durationSeconds,
    );

    // Reprise : le `.part` n'est réutilisé que si l'IDENTITÉ n'a pas changé
    // (même hash source et même hash attendu). Sinon repart de zéro.
    try {
      final previous = existing;
      var fromByte = 0;
      if (previous != null &&
          previous.sourceSha256 == target.sourceSha256 &&
          previous.expectedSha256 == target.expectedSha256 &&
          partFile.existsSync()) {
        fromByte = partFile.lengthSync();
      } else if (partFile.existsSync()) {
        partFile.deleteSync();
      }
      record = record.copyWith(receivedBytes: fromByte);
      await _store.upsert(record);

      final received = await _downloadToPart(
        track: track,
        profile: profile,
        partFile: partFile,
        fromByte: fromByte,
        totalBytes: target.sizeBytes,
        cancelToken: cancelToken,
        onBytes: (bytes) => report(
          OfflineDownloadProgress(
            status: OfflineDownloadStatus.downloading,
            receivedBytes: bytes,
            totalBytes: target.sizeBytes,
          ),
        ),
      );

      report(
        OfflineDownloadProgress(
          status: OfflineDownloadStatus.verifying,
          receivedBytes: received,
          totalBytes: target.sizeBytes,
        ),
      );
      await _verify(partFile, target, received);

      // Publication atomique : le fichier final n'existe qu'entièrement vérifié.
      partFile.renameSync(finalFile.path);
      record = record.copyWith(
        status: OfflineDownloadStatus.ready,
        receivedBytes: received,
        sizeBytes: received,
        relativePath: relativePath,
      );
      await _store.upsert(record);
      report(
        OfflineDownloadProgress(
          status: OfflineDownloadStatus.ready,
          receivedBytes: received,
          totalBytes: received,
        ),
      );
      return record;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        // Annulation : `.part` conservé pour reprise, état honnête.
        final kept = partFile.existsSync() ? partFile.lengthSync() : 0;
        await _store.upsert(
          record.copyWith(
            status: OfflineDownloadStatus.cancelled,
            receivedBytes: kept,
          ),
        );
        rethrow;
      }
      await _fail(
        record,
        partFile,
        'Téléchargement interrompu : ${error.type.name}.',
        keepPart: true,
      );
      throw OfflineDownloadException(
        'Téléchargement interrompu. Réessaie.',
        waitingForNetwork: true,
      );
    } on OfflineDownloadException catch (error) {
      await _fail(record, partFile, error.message, keepPart: error.canRetry);
      rethrow;
    } on FileSystemException catch (error) {
      await _fail(
        record,
        partFile,
        'Erreur de stockage local : ${error.osError?.message ?? error.message}',
        keepPart: true,
      );
      throw OfflineDownloadException(
        'Impossible d’écrire la musique sur cet appareil. Vérifie l’espace disponible.',
      );
    }
  }

  /// Vérifie la présence physique avant de considérer une copie comme déjà
  /// satisfaite dans un groupe. Le manifeste seul n'est jamais suffisant.
  Future<bool> isLocalReady(
    int userId,
    int trackId,
    OfflineProfile profile,
    String sourceSha256,
  ) async {
    final record = await _store.find(userId, trackId, profile);
    if (record == null ||
        record.status != OfflineDownloadStatus.ready ||
        record.sourceSha256 != sourceSha256 ||
        record.relativePath == null) {
      return false;
    }
    final dir = await _userDir(userId);
    final file = File('${dir.path}/${record.relativePath}');
    if (!file.existsSync()) return false;
    return record.sizeBytes == null || file.lengthSync() == record.sizeBytes;
  }

  /// Supprime la copie locale (fichier + manifeste). Jamais le serveur.
  Future<void> removeLocal(
    int userId,
    int trackId,
    OfflineProfile profile,
  ) async {
    final record = await _store.find(userId, trackId, profile);
    if (record?.relativePath != null) {
      final dir = await _userDir(userId);
      final file = File('${dir.path}/${record!.relativePath}');
      if (file.existsSync()) file.deleteSync();
    }
    await _store.delete(userId, trackId, profile);
    if ((await _store.readyForTrack(userId, trackId)).isEmpty) {
      final root = await _rootDirProvider();
      final cover = File(offlineCoverPath(root, userId, trackId));
      if (cover.existsSync()) cover.deleteSync();
    }
  }

  Future<void> _fail(
    OfflineTrackRecord record,
    File partFile,
    String message, {
    required bool keepPart,
  }) async {
    if (!keepPart && partFile.existsSync()) partFile.deleteSync();
    final kept = partFile.existsSync() ? partFile.lengthSync() : 0;
    await _store.upsert(
      record.copyWith(
        status: OfflineDownloadStatus.failed,
        receivedBytes: kept,
        errorMessage: message,
      ),
    );
  }

  /// Métadonnées de la cible : l'original vient de la piste elle-même, une
  /// dérivée Opus est demandée puis attendue (202 → sondage borné, sans boucle
  /// infinie).
  Future<_DownloadTarget> _resolveTarget(
    Track track,
    OfflineProfile profile,
    void Function(OfflineDownloadProgress) report,
    CancelToken? cancelToken,
  ) async {
    _throwIfCancelled(cancelToken);
    if (profile == OfflineProfile.original) {
      final etag = track.etag;
      if (etag == null || etag.isEmpty) {
        throw OfflineDownloadException(
          "Empreinte de l'original inconnue : resynchronise la bibliothèque.",
          canRetry: false,
        );
      }
      return _DownloadTarget(
        sourceSha256: etag,
        expectedSha256: etag,
        sizeBytes: track.sizeBytes,
        // Le modèle mobile n'expose pas codec/conteneur mesurés : on garde le
        // MIME réel de la source, jamais une valeur devinée.
        codec: track.mimeType,
        container: track.extension,
        lossy: switch (track.quality?.status) {
          null || 'inconnue' => null,
          'lossy' => true,
          _ => false,
        },
        measuredBitrateKbps: null,
      );
    }

    var state = await _api.requestVariant(
      track.id,
      profile,
      cancelToken: cancelToken,
    );
    var attempts = 0;
    while (!state.isReady) {
      if (state.isFailed) {
        throw OfflineDownloadException(
          "L'encodage serveur a échoué. Réessaie plus tard.",
        );
      }
      if (state.status == 'STALE') {
        state = await _api.requestVariant(
          track.id,
          profile,
          cancelToken: cancelToken,
        );
        continue;
      }
      attempts += 1;
      if (attempts > _maxPollAttempts) {
        throw OfflineDownloadException(
          "La préparation de la variante prend trop de temps. Réessaie plus tard.",
        );
      }
      report(
        OfflineDownloadProgress(
          status: OfflineDownloadStatus.waitingServer,
          receivedBytes: 0,
          totalBytes: state.sizeBytes,
          message: 'Préparation sur le serveur…',
        ),
      );
      await _waitForNextPoll(cancelToken);
      state = await _api.variantStatus(
        track.id,
        profile,
        cancelToken: cancelToken,
      );
    }
    final sha = state.sha256;
    if (sha == null) {
      throw OfflineDownloadException('Variante prête sans hash : refusée.');
    }
    return _DownloadTarget(
      sourceSha256: state.sourceSha256,
      expectedSha256: sha,
      sizeBytes: state.sizeBytes,
      codec: 'opus',
      container: 'ogg',
      lossy: true,
      measuredBitrateKbps: state.measuredBitrateKbps,
    );
  }

  Future<void> _waitForNextPoll(CancelToken? cancelToken) async {
    if (cancelToken == null) {
      await Future<void>.delayed(_pollInterval);
      return;
    }
    _throwIfCancelled(cancelToken);
    await Future.any<void>([
      Future<void>.delayed(_pollInterval),
      cancelToken.whenCancel.then<void>((error) => throw error),
    ]);
    _throwIfCancelled(cancelToken);
  }

  void _throwIfCancelled(CancelToken? cancelToken) {
    final error = cancelToken?.cancelError;
    if (error != null) throw error;
  }

  /// Écrit le flux HTTP dans le `.part` (append en reprise). Retourne la taille
  /// finale du `.part`. Gère 200 (reprise refusée → repart de zéro), 206, 404
  /// (variante disparue/obsolète), 416 (offset invalide → un seul restart) et
  /// 5xx (échec sans boucle).
  Future<int> _downloadToPart({
    required Track track,
    required OfflineProfile profile,
    required File partFile,
    required int fromByte,
    required int? totalBytes,
    required CancelToken? cancelToken,
    required void Function(int receivedBytes) onBytes,
    bool retriedAfter416 = false,
  }) async {
    final response = await _api.openDownloadStream(
      track.id,
      profile,
      fromByte: fromByte,
      cancelToken: cancelToken,
    );
    final status = response.statusCode ?? 0;

    if (status == 416) {
      if (retriedAfter416) {
        throw OfflineDownloadException('Reprise impossible (416 répété).');
      }
      if (partFile.existsSync()) partFile.deleteSync();
      return _downloadToPart(
        track: track,
        profile: profile,
        partFile: partFile,
        fromByte: 0,
        totalBytes: totalBytes,
        cancelToken: cancelToken,
        onBytes: onBytes,
        retriedAfter416: true,
      );
    }
    if (status == 404) {
      throw OfflineDownloadException(
        'La variante a expiré côté serveur. Relance le téléchargement.',
      );
    }
    if (status != 200 && status != 206) {
      throw OfflineDownloadException('Le serveur a répondu $status.');
    }

    // 200 sur une demande de reprise : le serveur renvoie tout — on repart de 0.
    var offset = fromByte;
    if (status == 200 && fromByte > 0) {
      if (partFile.existsSync()) partFile.deleteSync();
      offset = 0;
    }

    final body = response.data;
    if (body == null) {
      throw OfflineDownloadException('Réponse de téléchargement vide.');
    }
    final sink = partFile.openWrite(
      mode: offset > 0 ? FileMode.append : FileMode.write,
    );
    var received = offset;
    try {
      await for (final chunk in body.stream) {
        sink.add(chunk);
        received += chunk.length;
        onBytes(received);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return received;
  }

  /// Refuse toute copie dont la taille ou le SHA-256 ne correspond pas.
  Future<void> _verify(
    File partFile,
    _DownloadTarget target,
    int received,
  ) async {
    if (target.sizeBytes != null && received != target.sizeBytes) {
      throw OfflineDownloadException(
        'Taille inattendue ($received octets au lieu de ${target.sizeBytes}).',
      );
    }
    final digest = await sha256.bind(partFile.openRead()).first;
    if (digest.toString() != target.expectedSha256) {
      // Copie corrompue : inutilisable, on ne garde pas le .part.
      throw OfflineDownloadException(
        'Empreinte SHA-256 invalide : fichier rejeté.',
        canRetry: false,
      );
    }
  }
}

class _DownloadTarget {
  const _DownloadTarget({
    required this.sourceSha256,
    required this.expectedSha256,
    required this.sizeBytes,
    required this.codec,
    required this.container,
    required this.lossy,
    required this.measuredBitrateKbps,
  });

  final String sourceSha256;
  final String expectedSha256;
  final int? sizeBytes;
  final String? codec;
  final String? container;
  final bool? lossy;
  final int? measuredBitrateKbps;
}

final offlineTrackDownloaderProvider = Provider<OfflineTrackDownloader>((ref) {
  return OfflineTrackDownloader(
    api: ref.watch(offlineApiProvider),
    store: ref.watch(offlineManifestStoreProvider),
    // Même racine que l'index hors ligne (surchargée dans les tests).
    rootDirProvider: ref.watch(offlineRootDirProvider),
  );
});
