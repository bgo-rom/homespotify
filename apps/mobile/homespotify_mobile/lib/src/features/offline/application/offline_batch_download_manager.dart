// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../library/domain/track.dart';
import '../data/offline_manifest_store.dart';
import '../domain/offline_models.dart';
import 'offline_index.dart';
import 'offline_storage_policy.dart';
import 'offline_track_downloader.dart';

class OfflineBatchException implements Exception {
  const OfflineBatchException(this.message);
  final String message;
  @override
  String toString() => message;
}

class OfflineBatchLiveProgress {
  const OfflineBatchLiveProgress({
    required this.trackId,
    required this.progress,
  });

  final int trackId;
  final OfflineDownloadProgress progress;
}

/// Orchestre les téléchargements groupés sans dupliquer le pipeline unitaire.
///
/// Un seul groupe est transféré à la fois sur l'appareil. Le serveur conserve
/// sa propre concurrence bornée et son single-flight par variante. Les groupes
/// et items sont persistés avant le premier octet : un processus tué reprend
/// les items non READY au prochain lancement.
class OfflineBatchDownloadManager {
  OfflineBatchDownloadManager({
    required OfflineManifestStore store,
    required OfflineTrackDownloader downloader,
    required OfflineDownloadPreferencesStore preferencesStore,
    required OfflineStoragePlatform storagePlatform,
    required Future<List<ConnectivityResult>> Function() connectivityProvider,
    required Future<int> Function(int userId) usedBytesProvider,
    required int? Function() activeUserProvider,
    void Function()? onChanged,
    void Function(String groupId, OfflineBatchLiveProgress? progress)?
    onProgress,
  }) : _store = store,
       _downloader = downloader,
       _preferencesStore = preferencesStore,
       _storagePlatform = storagePlatform,
       _connectivityProvider = connectivityProvider,
       _usedBytesProvider = usedBytesProvider,
       _activeUserProvider = activeUserProvider,
       _onChanged = onChanged ?? _noop,
       _onProgress = onProgress ?? _noopProgress;

  final OfflineManifestStore _store;
  final OfflineTrackDownloader _downloader;
  final OfflineDownloadPreferencesStore _preferencesStore;
  final OfflineStoragePlatform _storagePlatform;
  final Future<List<ConnectivityResult>> Function() _connectivityProvider;
  final Future<int> Function(int userId) _usedBytesProvider;
  final int? Function() _activeUserProvider;
  final void Function() _onChanged;
  final void Function(String groupId, OfflineBatchLiveProgress? progress)
  _onProgress;
  final Map<String, CancelToken> _active = {};
  final Map<String, Completer<void>> _operations = {};
  final Map<String, Timer> _retryTimers = {};
  final Map<String, OfflineGroupStatus> _stopIntent = {};
  final Set<int> _resumingUsers = {};
  String? _runningGroupId;

  static void _noop() {}
  static void _noopProgress(String _, OfflineBatchLiveProgress? _) {}

  Future<String> createAndStart({
    required int userId,
    required OfflineGroupType type,
    required String sourceId,
    required String title,
    required List<Track> tracks,
    required OfflineProfile profile,
  }) async {
    if (tracks.isEmpty) {
      throw const OfflineBatchException('Aucune piste à télécharger.');
    }
    final uniqueTracks = <Track>[];
    final seen = <int>{};
    for (final track in tracks) {
      if (seen.add(track.id)) uniqueTracks.add(track);
    }
    final id = _newGroupId(userId);
    final now = DateTime.now().toUtc();
    final estimatedBytes = uniqueTracks.fold<int>(
      0,
      (sum, track) => sum + _estimateTrackBytes(track, profile),
    );
    final group = OfflineDownloadGroup(
      id: id,
      userId: userId,
      type: type,
      sourceId: sourceId,
      title: title,
      profile: profile,
      status: OfflineGroupStatus.queued,
      totalItems: uniqueTracks.length,
      completedItems: 0,
      failedItems: 0,
      estimatedBytes: estimatedBytes,
      exactBytes: 0,
      createdAt: now,
      updatedAt: now,
    );
    final items = <OfflineDownloadGroupItem>[
      for (var index = 0; index < uniqueTracks.length; index++)
        _itemFromTrack(id, index, uniqueTracks[index]),
    ];
    await _store.createGroup(group, items);
    _onChanged();
    unawaited(start(userId, id));
    return id;
  }

  Future<void> resumeForUser(int userId) async {
    if (!_resumingUsers.add(userId)) return;
    try {
      await reconcileForUser(userId);
      final groups = await _store.listGroupsForUser(userId);
      for (final group in groups) {
        if (group.status == OfflineGroupStatus.running ||
            group.status == OfflineGroupStatus.queued ||
            group.status == OfflineGroupStatus.waitingNetwork) {
          await start(userId, group.id);
        }
      }
    } finally {
      _resumingUsers.remove(userId);
    }
  }

  /// Réconcilie l'intention persistée avec les fichiers réellement présents.
  ///
  /// Couvre notamment un arrêt du processus entre la publication atomique
  /// d'une piste et la mise à jour de son item, ainsi qu'une purge LRU ou une
  /// suppression manuelle après la complétion d'un album.
  Future<void> reconcileForUser(int userId) async {
    final groups = await _store.listGroupsForUser(userId);
    for (final originalGroup in groups) {
      if (_active.containsKey(originalGroup.id)) continue;
      final items = await _store.listGroupItems(originalGroup.id);
      var completed = 0;
      var failed = 0;
      var exactBytes = 0;
      for (var item in items) {
        final ready = await _downloader.isLocalReady(
          userId,
          item.trackId,
          originalGroup.profile,
          item.sourceSha256,
        );
        if (ready) {
          completed += 1;
          final record = await _store.find(
            userId,
            item.trackId,
            originalGroup.profile,
          );
          exactBytes += record?.sizeBytes ?? 0;
          if (item.status != OfflineGroupItemStatus.ready) {
            item = item.copyWith(
              status: OfflineGroupItemStatus.ready,
              clearError: true,
            );
            await _store.updateGroupItem(item);
          }
        } else if (item.status == OfflineGroupItemStatus.ready ||
            item.status == OfflineGroupItemStatus.running) {
          item = item.copyWith(
            status: OfflineGroupItemStatus.queued,
            clearError: true,
          );
          await _store.updateGroupItem(item);
        } else if (item.status == OfflineGroupItemStatus.failed) {
          failed += 1;
        }
      }

      var status = originalGroup.status;
      if (completed == originalGroup.totalItems) {
        status = OfflineGroupStatus.completed;
      } else if (status == OfflineGroupStatus.completed) {
        status = OfflineGroupStatus.partial;
      } else if (status == OfflineGroupStatus.running) {
        status = OfflineGroupStatus.queued;
      }
      await _store.updateGroup(
        originalGroup.copyWith(
          status: status,
          completedItems: completed,
          failedItems: failed,
          exactBytes: exactBytes,
          updatedAt: DateTime.now().toUtc(),
        ),
      );
    }
    _onChanged();
  }

  Future<void> start(int userId, String groupId) async {
    if (_active.containsKey(groupId)) return;
    if (_runningGroupId != null) return;
    _runningGroupId = groupId;
    final operation = Completer<void>();
    _operations[groupId] = operation;
    try {
      await _startExclusive(userId, groupId);
    } finally {
      if (_runningGroupId == groupId) _runningGroupId = null;
      _operations.remove(groupId);
      if (!operation.isCompleted) operation.complete();
      unawaited(_startNextQueued(userId, exceptGroupId: groupId));
    }
  }

  Future<void> _startExclusive(int userId, String groupId) async {
    await reconcileForUser(userId);
    final foundGroup = await _store.findGroup(userId, groupId);
    if (foundGroup == null ||
        foundGroup.status == OfflineGroupStatus.completed ||
        foundGroup.status == OfflineGroupStatus.cancelled) {
      return;
    }
    var group = foundGroup;
    final connectivity = await _connectivityProvider();
    final preferences = await _preferencesStore.load();
    if (!preferences.allows(connectivity)) {
      await _saveGroup(
        group.copyWith(
          status: OfflineGroupStatus.waitingNetwork,
          updatedAt: DateTime.now().toUtc(),
          errorMessage:
              preferences.networkPolicy == OfflineNetworkPolicy.wifiOnly
              ? 'En attente du Wi‑Fi.'
              : 'En attente du réseau.',
        ),
      );
      return;
    }
    final remainingEstimate = max(0, group.estimatedBytes - group.exactBytes);
    final snapshot = OfflineStorageSnapshot(
      usedBytes: await _usedBytesProvider(userId),
      freeBytes: await _storagePlatform.freeBytes(),
      limitBytes: preferences.maxStorageBytes,
    );
    if (!snapshot.canFit(remainingEstimate)) {
      await _saveGroup(
        group.copyWith(
          status: OfflineGroupStatus.paused,
          updatedAt: DateTime.now().toUtc(),
          errorMessage: 'Espace insuffisant pour terminer ce téléchargement.',
        ),
      );
      return;
    }

    final cancelToken = CancelToken();
    _active[groupId] = cancelToken;
    _stopIntent.remove(groupId);
    group = group.copyWith(
      status: OfflineGroupStatus.running,
      updatedAt: DateTime.now().toUtc(),
      clearError: true,
    );
    await _saveGroup(group);

    try {
      final items = await _store.listGroupItems(groupId);
      for (final originalItem in items) {
        if (originalItem.status == OfflineGroupItemStatus.ready) continue;
        if (cancelToken.isCancelled) break;

        final transports = await _connectivityProvider();
        final currentPreferences = await _preferencesStore.load();
        if (!currentPreferences.allows(transports)) {
          await _saveGroup(
            group.copyWith(
              status: OfflineGroupStatus.waitingNetwork,
              updatedAt: DateTime.now().toUtc(),
              errorMessage:
                  currentPreferences.networkPolicy ==
                      OfflineNetworkPolicy.wifiOnly
                  ? 'En attente du Wi‑Fi.'
                  : 'En attente du réseau.',
            ),
          );
          return;
        }

        var item = originalItem.copyWith(
          status: OfflineGroupItemStatus.running,
          clearError: true,
        );
        await _store.updateGroupItem(item);
        _onChanged();
        try {
          final alreadyReady =
              group.profile == OfflineProfile.original &&
              await _downloader.isLocalReady(
                userId,
                item.trackId,
                group.profile,
                item.sourceSha256,
              );
          final record = alreadyReady
              ? await _store.find(userId, item.trackId, group.profile)
              : await _downloader.download(
                  userId: userId,
                  track: _trackFromItem(item),
                  profile: group.profile,
                  cancelToken: cancelToken,
                  onProgress: (progress) => _onProgress(
                    groupId,
                    OfflineBatchLiveProgress(
                      trackId: item.trackId,
                      progress: progress,
                    ),
                  ),
                );
          final exactSize = record?.sizeBytes ?? item.sizeBytes ?? 0;
          item = item.copyWith(
            status: OfflineGroupItemStatus.ready,
            clearError: true,
          );
          await _store.updateGroupItem(item);
          group = group.copyWith(
            completedItems: group.completedItems + 1,
            exactBytes: group.exactBytes + exactSize,
            updatedAt: DateTime.now().toUtc(),
          );
          await _saveGroup(group);
        } on DioException catch (error) {
          if (CancelToken.isCancel(error)) break;
          item = item.copyWith(
            status: OfflineGroupItemStatus.queued,
            clearError: true,
          );
          await _store.updateGroupItem(item);
          await _saveGroup(
            group.copyWith(
              status: OfflineGroupStatus.waitingNetwork,
              updatedAt: DateTime.now().toUtc(),
              errorMessage: 'Serveur injoignable. Reprise automatique.',
            ),
          );
          return;
        } on OfflineDownloadException catch (error) {
          if (error.waitingForNetwork) {
            item = item.copyWith(
              status: OfflineGroupItemStatus.queued,
              clearError: true,
            );
            await _store.updateGroupItem(item);
            await _saveGroup(
              group.copyWith(
                status: OfflineGroupStatus.waitingNetwork,
                updatedAt: DateTime.now().toUtc(),
                errorMessage: 'Serveur injoignable. Reprise automatique.',
              ),
            );
            return;
          }
          item = item.copyWith(
            status: OfflineGroupItemStatus.failed,
            errorMessage: error.message,
          );
          await _store.updateGroupItem(item);
          group = group.copyWith(
            failedItems: group.failedItems + 1,
            updatedAt: DateTime.now().toUtc(),
          );
          await _saveGroup(group);
        } catch (error) {
          item = item.copyWith(
            status: OfflineGroupItemStatus.failed,
            errorMessage: error.toString(),
          );
          await _store.updateGroupItem(item);
          group = group.copyWith(
            failedItems: group.failedItems + 1,
            updatedAt: DateTime.now().toUtc(),
          );
          await _saveGroup(group);
        } finally {
          _onProgress(groupId, null);
        }
      }

      if (cancelToken.isCancelled) {
        final intent = _stopIntent[groupId] ?? OfflineGroupStatus.paused;
        await _saveGroup(
          group.copyWith(
            status: intent,
            updatedAt: DateTime.now().toUtc(),
            errorMessage: intent == OfflineGroupStatus.cancelled
                ? 'Téléchargement annulé.'
                : null,
            clearError: intent == OfflineGroupStatus.paused,
          ),
        );
        return;
      }
      final finalStatus = group.failedItems > 0
          ? OfflineGroupStatus.partial
          : OfflineGroupStatus.completed;
      await _saveGroup(
        group.copyWith(
          status: finalStatus,
          updatedAt: DateTime.now().toUtc(),
          clearError: true,
        ),
      );
    } finally {
      _active.remove(groupId);
      _stopIntent.remove(groupId);
      _onProgress(groupId, null);
      _onChanged();
    }
  }

  Future<void> _startNextQueued(
    int userId, {
    required String exceptGroupId,
  }) async {
    if (_runningGroupId != null) return;
    final groups = await _store.listGroupsForUser(userId);
    for (final group in groups.reversed) {
      if (group.id != exceptGroupId &&
          (group.status == OfflineGroupStatus.queued ||
              group.status == OfflineGroupStatus.running)) {
        await start(userId, group.id);
        return;
      }
    }
  }

  Future<void> pause(int userId, String groupId) async {
    _stopIntent[groupId] = OfflineGroupStatus.paused;
    final active = _active[groupId];
    if (active != null) {
      active.cancel('pause groupe');
      return;
    }
    final group = await _store.findGroup(userId, groupId);
    if (group != null) {
      await _saveGroup(
        group.copyWith(
          status: OfflineGroupStatus.paused,
          updatedAt: DateTime.now().toUtc(),
          clearError: true,
        ),
      );
    }
  }

  Future<void> cancel(int userId, String groupId) async {
    _stopIntent[groupId] = OfflineGroupStatus.cancelled;
    final active = _active[groupId];
    if (active != null) {
      active.cancel('annulation groupe');
      return;
    }
    final group = await _store.findGroup(userId, groupId);
    if (group != null) {
      await _saveGroup(
        group.copyWith(
          status: OfflineGroupStatus.cancelled,
          updatedAt: DateTime.now().toUtc(),
          errorMessage: 'Téléchargement annulé.',
        ),
      );
    }
  }

  Future<void> retryFailed(int userId, String groupId) async {
    final group = await _store.findGroup(userId, groupId);
    if (group == null) return;
    final items = await _store.listGroupItems(groupId);
    var completed = 0;
    var exactBytes = 0;
    for (final item in items) {
      if (item.status == OfflineGroupItemStatus.ready) {
        completed += 1;
        final record = await _store.find(userId, item.trackId, group.profile);
        exactBytes += record?.sizeBytes ?? 0;
      } else {
        await _store.updateGroupItem(
          item.copyWith(
            status: OfflineGroupItemStatus.queued,
            clearError: true,
          ),
        );
      }
    }
    await _saveGroup(
      group.copyWith(
        status: OfflineGroupStatus.queued,
        completedItems: completed,
        failedItems: 0,
        exactBytes: exactBytes,
        updatedAt: DateTime.now().toUtc(),
        clearError: true,
      ),
    );
    await start(userId, groupId);
  }

  Future<void> removeGroupCopies(int userId, String groupId) async {
    final operation = _operations[groupId]?.future;
    await pause(userId, groupId);
    await operation;
    final group = await _store.findGroup(userId, groupId);
    if (group == null) return;
    final items = await _store.listGroupItems(groupId);
    for (final item in items) {
      await _downloader.removeLocal(userId, item.trackId, group.profile);
    }
    await _store.deleteGroup(userId, groupId);
    await reconcileForUser(userId);
  }

  Future<void> _saveGroup(OfflineDownloadGroup group) async {
    await _store.updateGroup(group);
    if (group.status == OfflineGroupStatus.waitingNetwork) {
      _scheduleRetry(group.userId, group.id);
    } else {
      _retryTimers.remove(group.id)?.cancel();
    }
    _onChanged();
  }

  void _scheduleRetry(int userId, String groupId) {
    if (_retryTimers.containsKey(groupId)) return;
    _retryTimers[groupId] = Timer(const Duration(seconds: 30), () {
      _retryTimers.remove(groupId);
      if (_activeUserProvider() != userId) return;
      if (_runningGroupId != null) {
        _scheduleRetry(userId, groupId);
        return;
      }
      unawaited(start(userId, groupId));
    });
  }

  static int _estimateTrackBytes(Track track, OfflineProfile profile) {
    if (profile == OfflineProfile.original) return track.sizeBytes ?? 0;
    final seconds = track.durationSeconds ?? 0;
    final bitrate = profile == OfflineProfile.opus256 ? 256 : 128;
    return (seconds * bitrate * 125).ceil();
  }

  static OfflineDownloadGroupItem _itemFromTrack(
    String groupId,
    int position,
    Track track,
  ) => OfflineDownloadGroupItem(
    groupId: groupId,
    position: position,
    trackId: track.id,
    status: OfflineGroupItemStatus.queued,
    title: track.title,
    artist: track.artist,
    album: track.album,
    sourceSha256: track.etag ?? '',
    durationSeconds: track.durationSeconds,
    sizeBytes: track.sizeBytes,
    mimeType: track.mimeType,
    extension: track.extension,
  );

  static Track _trackFromItem(OfflineDownloadGroupItem item) => Track(
    id: item.trackId,
    title: item.title,
    artist: item.artist,
    album: item.album,
    hasCover: false,
    durationSeconds: item.durationSeconds,
    sizeBytes: item.sizeBytes,
    etag: item.sourceSha256,
    mimeType: item.mimeType,
    extension: item.extension,
  );

  static String _newGroupId(int userId) {
    final random = Random.secure().nextInt(0x7fffffff);
    return 'g${userId}_${DateTime.now().microsecondsSinceEpoch}_$random';
  }
}

class OfflineGroupRevision extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state += 1;
}

final offlineGroupRevisionProvider =
    NotifierProvider<OfflineGroupRevision, int>(OfflineGroupRevision.new);

class OfflineBatchProgressController
    extends Notifier<Map<String, OfflineBatchLiveProgress>> {
  @override
  Map<String, OfflineBatchLiveProgress> build() => const {};

  void set(String groupId, OfflineBatchLiveProgress? progress) {
    final next = Map<String, OfflineBatchLiveProgress>.of(state);
    if (progress == null) {
      next.remove(groupId);
    } else {
      next[groupId] = progress;
    }
    state = Map.unmodifiable(next);
  }
}

final offlineBatchProgressProvider =
    NotifierProvider<
      OfflineBatchProgressController,
      Map<String, OfflineBatchLiveProgress>
    >(OfflineBatchProgressController.new);

final offlineBatchDownloadManagerProvider =
    Provider<OfflineBatchDownloadManager>((ref) {
      final store = ref.watch(offlineManifestStoreProvider);
      final rootProvider = ref.watch(offlineRootDirProvider);
      return OfflineBatchDownloadManager(
        store: store,
        downloader: ref.watch(offlineTrackDownloaderProvider),
        preferencesStore: ref.watch(offlineDownloadPreferencesStoreProvider),
        storagePlatform: ref.watch(offlineStoragePlatformProvider),
        connectivityProvider: Connectivity().checkConnectivity,
        activeUserProvider: () => ref.read(offlineUserIdProvider),
        usedBytesProvider: (userId) async {
          final root = await rootProvider();
          final directory = Directory('$root/offline');
          if (!directory.existsSync()) return 0;
          var total = 0;
          await for (final entity in directory.list(
            recursive: true,
            followLinks: false,
          )) {
            if (entity is File && !entity.path.endsWith('.part')) {
              total += await entity.length();
            }
          }
          return total;
        },
        onChanged: () {
          ref.read(offlineGroupRevisionProvider.notifier).bump();
          ref.invalidate(offlineIndexProvider);
        },
        onProgress: (groupId, progress) => ref
            .read(offlineBatchProgressProvider.notifier)
            .set(groupId, progress),
      );
    });

final offlineGroupsProvider = FutureProvider<List<OfflineDownloadGroup>>((
  ref,
) async {
  ref.watch(offlineGroupRevisionProvider);
  final userId = ref.watch(offlineUserIdProvider);
  if (userId == null) return const [];
  return ref.watch(offlineManifestStoreProvider).listGroupsForUser(userId);
});

final offlineConnectivityProvider = StreamProvider<List<ConnectivityResult>>((
  ref,
) async* {
  final connectivity = Connectivity();
  yield await connectivity.checkConnectivity();
  yield* connectivity.onConnectivityChanged;
});

final offlineBatchBootstrapProvider = FutureProvider.family<void, int>((
  ref,
  userId,
) async {
  ref.watch(offlineConnectivityProvider);
  await ref.watch(offlineBatchDownloadManagerProvider).resumeForUser(userId);
});
