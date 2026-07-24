import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/offline/application/offline_batch_download_manager.dart';
import 'package:homespotify_mobile/src/features/offline/application/offline_storage_policy.dart';
import 'package:homespotify_mobile/src/features/offline/application/offline_track_downloader.dart';
import 'package:homespotify_mobile/src/features/offline/data/offline_api.dart';
import 'package:homespotify_mobile/src/features/offline/data/offline_manifest_store.dart';
import 'package:homespotify_mobile/src/features/offline/domain/offline_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _UnusedOfflineApi implements OfflineApi {
  @override
  Uri downloadUri(int trackId, OfflineProfile profile) =>
      Uri.parse('https://invalid.local/$trackId/${profile.wire}');

  @override
  Future<List<OfflineOption>> fetchOptions(int trackId) =>
      throw UnimplementedError();

  @override
  Future<Response<ResponseBody>> openDownloadStream(
    int trackId,
    OfflineProfile profile, {
    int fromByte = 0,
    CancelToken? cancelToken,
  }) => throw UnimplementedError();

  @override
  Future<OfflineVariantState> requestVariant(
    int trackId,
    OfflineProfile profile, {
    CancelToken? cancelToken,
  }) => throw UnimplementedError();

  @override
  Future<OfflineVariantState> variantStatus(
    int trackId,
    OfflineProfile profile, {
    CancelToken? cancelToken,
  }) => throw UnimplementedError();
}

class _FakePreferencesStore implements OfflineDownloadPreferencesStore {
  _FakePreferencesStore(this.value);
  OfflineDownloadPreferences value;

  @override
  Future<OfflineDownloadPreferences> load() async => value;

  @override
  Future<void> save(OfflineDownloadPreferences preferences) async {
    value = preferences;
  }
}

class _FakeStorage implements OfflineStoragePlatform {
  _FakeStorage(this.bytes);
  int? bytes;

  @override
  Future<int?> freeBytes() async => bytes;
}

class _FakeDownloader extends OfflineTrackDownloader {
  _FakeDownloader(this.manifest)
    : super(
        api: _UnusedOfflineApi(),
        store: manifest,
        rootDirProvider: () async => '/unused',
      );

  final OfflineManifestStore manifest;
  final Set<String> ready = {};
  final Map<int, int> failuresRemaining = {};
  final Set<int> networkFailures = {};
  final List<int> calls = [];
  int active = 0;
  int maxActive = 0;

  String _key(
    int userId,
    int trackId,
    OfflineProfile profile,
    String sourceSha256,
  ) => '$userId:$trackId:${profile.wire}:$sourceSha256';

  @override
  Future<OfflineTrackRecord> download({
    required int userId,
    required Track track,
    required OfflineProfile profile,
    CancelToken? cancelToken,
    void Function(OfflineDownloadProgress progress)? onProgress,
  }) async {
    final sourceSha256 = track.etag ?? '';
    final existing = await manifest.find(userId, track.id, profile);
    if (ready.contains(_key(userId, track.id, profile, sourceSha256)) &&
        existing != null) {
      return existing;
    }
    active += 1;
    if (active > maxActive) maxActive = active;
    calls.add(track.id);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 8));
      if (networkFailures.remove(track.id)) {
        throw OfflineDownloadException(
          'réseau simulé',
          waitingForNetwork: true,
        );
      }
      if ((failuresRemaining[track.id] ?? 0) > 0) {
        failuresRemaining[track.id] = failuresRemaining[track.id]! - 1;
        throw OfflineDownloadException('échec simulé');
      }
      final record = OfflineTrackRecord(
        userId: userId,
        trackId: track.id,
        profile: profile,
        sourceSha256: sourceSha256,
        status: OfflineDownloadStatus.ready,
        receivedBytes: track.sizeBytes ?? 1000,
        sizeBytes: track.sizeBytes ?? 1000,
        relativePath: '${track.id}-${profile.wire}.ogg',
        title: track.title,
        artist: track.artist,
        album: track.album,
        durationSeconds: track.durationSeconds,
      );
      ready.add(_key(userId, track.id, profile, sourceSha256));
      await manifest.upsert(record);
      return record;
    } finally {
      active -= 1;
    }
  }

  @override
  Future<bool> isLocalReady(
    int userId,
    int trackId,
    OfflineProfile profile,
    String sourceSha256,
  ) async => ready.contains(_key(userId, trackId, profile, sourceSha256));

  @override
  Future<void> removeLocal(
    int userId,
    int trackId,
    OfflineProfile profile,
  ) async {
    ready.removeWhere(
      (key) => key.startsWith('$userId:$trackId:${profile.wire}:'),
    );
    await manifest.delete(userId, trackId, profile);
  }
}

Track _track(int id, {String? hash}) => Track(
  id: id,
  title: 'Titre $id',
  artist: 'Artiste',
  album: 'Album',
  hasCover: false,
  durationSeconds: 60,
  sizeBytes: 1000 + id,
  etag: hash ?? 'sha-$id',
  extension: '.flac',
  mimeType: 'audio/flac',
);

Future<OfflineDownloadGroup> _waitForStatus(
  OfflineManifestStore store,
  int userId,
  String groupId,
  Set<OfflineGroupStatus> statuses,
) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    final group = await store.findGroup(userId, groupId);
    if (group != null && statuses.contains(group.status)) return group;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw TestFailure('Le groupe $groupId n’a pas atteint $statuses.');
}

void main() {
  sqfliteFfiInit();

  late Directory root;
  late SqliteOfflineManifestStore store;
  late _FakeDownloader downloader;
  late _FakePreferencesStore preferences;
  late _FakeStorage storage;
  var connectivity = <ConnectivityResult>[ConnectivityResult.wifi];

  OfflineBatchDownloadManager manager() => OfflineBatchDownloadManager(
    store: store,
    downloader: downloader,
    preferencesStore: preferences,
    storagePlatform: storage,
    connectivityProvider: () async => connectivity,
    usedBytesProvider: (_) async => 0,
    activeUserProvider: () => null,
  );

  setUp(() {
    root = Directory.systemTemp.createTempSync('homespotify-phase1b-');
    store = SqliteOfflineManifestStore(
      factory: databaseFactoryFfi,
      databasePath: '${root.path}/offline.db',
    );
    downloader = _FakeDownloader(store);
    preferences = _FakePreferencesStore(OfflineDownloadPreferences.defaults);
    storage = _FakeStorage(20 * 1024 * 1024 * 1024);
    connectivity = <ConnectivityResult>[ConnectivityResult.wifi];
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows peut garder brièvement le handle SQLite après le test.
    }
  });

  test(
    'migration v1 → v2 conserve les pistes et crée les tables de groupes',
    () async {
      final legacyPath = '${root.path}/legacy.db';
      final legacy = await databaseFactoryFfi.openDatabase(
        legacyPath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute('''
            CREATE TABLE offline_tracks (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              user_id INTEGER NOT NULL,
              track_id INTEGER NOT NULL,
              profile TEXT NOT NULL,
              source_sha256 TEXT NOT NULL,
              expected_sha256 TEXT,
              status TEXT NOT NULL,
              received_bytes INTEGER NOT NULL DEFAULT 0,
              size_bytes INTEGER,
              relative_path TEXT,
              codec TEXT,
              container TEXT,
              lossy INTEGER,
              measured_bitrate_kbps INTEGER,
              title TEXT,
              artist TEXT,
              album TEXT,
              duration_seconds REAL,
              error_message TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              UNIQUE(user_id, track_id, profile)
            )
          ''');
            await db.insert('offline_tracks', {
              'user_id': 1,
              'track_id': 42,
              'profile': 'opus_256',
              'source_sha256': 'legacy',
              'status': 'ready',
              'received_bytes': 12,
              'created_at': '2026-07-24T00:00:00Z',
              'updated_at': '2026-07-24T00:00:00Z',
            });
          },
        ),
      );
      await legacy.close();

      final migrated = SqliteOfflineManifestStore(
        factory: databaseFactoryFfi,
        databasePath: legacyPath,
      );
      expect(
        (await migrated.find(1, 42, OfflineProfile.opus256))?.sourceSha256,
        'legacy',
      );
      await migrated.createGroup(
        OfflineDownloadGroup(
          id: 'migration-group',
          userId: 1,
          type: OfflineGroupType.album,
          sourceId: 'album',
          title: 'Album',
          profile: OfflineProfile.opus256,
          status: OfflineGroupStatus.queued,
          totalItems: 0,
          completedItems: 0,
          failedItems: 0,
          estimatedBytes: 0,
          exactBytes: 0,
          createdAt: DateTime.utc(2026, 7, 24),
          updatedAt: DateTime.utc(2026, 7, 24),
        ),
        const [],
      );
      expect(await migrated.findGroup(1, 'migration-group'), isNotNull);
    },
  );

  test('album dédupliqué, transféré séquentiellement et persisté', () async {
    final service = manager();
    final groupId = await service.createAndStart(
      userId: 7,
      type: OfflineGroupType.album,
      sourceId: 'album-1',
      title: 'Album',
      tracks: [_track(1), _track(1), _track(2), _track(3)],
      profile: OfflineProfile.opus256,
    );

    final group = await _waitForStatus(store, 7, groupId, {
      OfflineGroupStatus.completed,
    });
    expect(group.totalItems, 3);
    expect(group.completedItems, 3);
    expect(group.failedItems, 0);
    expect(downloader.calls, [1, 2, 3]);
    expect(downloader.maxActive, 1);
    expect((await store.listGroupItems(groupId)).length, 3);
  });

  test('deux groupes restent globalement séquentiels', () async {
    final service = manager();
    final first = await service.createAndStart(
      userId: 2,
      type: OfflineGroupType.album,
      sourceId: 'a',
      title: 'A',
      tracks: [_track(1), _track(2)],
      profile: OfflineProfile.opus128,
    );
    final second = await service.createAndStart(
      userId: 2,
      type: OfflineGroupType.playlist,
      sourceId: 'b',
      title: 'B',
      tracks: [_track(3), _track(4)],
      profile: OfflineProfile.opus128,
    );

    await _waitForStatus(store, 2, first, {OfflineGroupStatus.completed});
    await _waitForStatus(store, 2, second, {OfflineGroupStatus.completed});
    expect(downloader.maxActive, 1);
    expect(downloader.calls, [1, 2, 3, 4]);
  });

  test('politique Wi-Fi attend puis reprend sans perdre le groupe', () async {
    connectivity = <ConnectivityResult>[ConnectivityResult.mobile];
    final service = manager();
    final groupId = await service.createAndStart(
      userId: 3,
      type: OfflineGroupType.playlist,
      sourceId: 'p',
      title: 'Playlist',
      tracks: [_track(5)],
      profile: OfflineProfile.opus256,
    );
    final waiting = await _waitForStatus(store, 3, groupId, {
      OfflineGroupStatus.waitingNetwork,
    });
    expect(waiting.errorMessage, contains('Wi'));
    expect(downloader.calls, isEmpty);

    connectivity = <ConnectivityResult>[ConnectivityResult.wifi];
    await service.resumeForUser(3);
    final completed = await _waitForStatus(store, 3, groupId, {
      OfflineGroupStatus.completed,
    });
    expect(completed.completedItems, 1);
  });

  test('espace insuffisant met en pause avant le premier octet', () async {
    storage.bytes = 100;
    final groupId = await manager().createAndStart(
      userId: 4,
      type: OfflineGroupType.album,
      sourceId: 'full',
      title: 'Trop grand',
      tracks: [_track(6)],
      profile: OfflineProfile.opus256,
    );
    final paused = await _waitForStatus(store, 4, groupId, {
      OfflineGroupStatus.paused,
    });
    expect(paused.errorMessage, contains('Espace insuffisant'));
    expect(downloader.calls, isEmpty);
  });

  test(
    'serveur perdu au milieu du lot attend sans faire échouer la suite',
    () async {
      downloader.networkFailures.add(2);
      final service = manager();
      final groupId = await service.createAndStart(
        userId: 6,
        type: OfflineGroupType.album,
        sourceId: 'network',
        title: 'Network',
        tracks: [_track(1), _track(2), _track(3)],
        profile: OfflineProfile.opus128,
      );
      final waiting = await _waitForStatus(store, 6, groupId, {
        OfflineGroupStatus.waitingNetwork,
      });
      expect(waiting.completedItems, 1);
      expect(waiting.failedItems, 0);
      expect(downloader.calls, [1, 2]);

      await service.resumeForUser(6);
      final completed = await _waitForStatus(store, 6, groupId, {
        OfflineGroupStatus.completed,
      });
      expect(completed.completedItems, 3);
      expect(downloader.calls, [1, 2, 2, 3]);
    },
  );

  test(
    'échec partiel puis retry ne retélécharge que la piste en erreur',
    () async {
      downloader.failuresRemaining[2] = 1;
      final service = manager();
      final groupId = await service.createAndStart(
        userId: 5,
        type: OfflineGroupType.album,
        sourceId: 'retry',
        title: 'Retry',
        tracks: [_track(1), _track(2), _track(3)],
        profile: OfflineProfile.opus128,
      );
      final partial = await _waitForStatus(store, 5, groupId, {
        OfflineGroupStatus.partial,
      });
      expect(partial.completedItems, 2);
      expect(partial.failedItems, 1);

      await service.retryFailed(5, groupId);
      final completed = await _waitForStatus(store, 5, groupId, {
        OfflineGroupStatus.completed,
      });
      expect(completed.completedItems, 3);
      expect(downloader.calls, [1, 2, 3, 2]);
    },
  );

  test(
    'réconciliation répare un item READY supprimé et isole les comptes',
    () async {
      final service = manager();
      final groupId = await service.createAndStart(
        userId: 10,
        type: OfflineGroupType.album,
        sourceId: 'reconcile',
        title: 'Reconcile',
        tracks: [_track(8)],
        profile: OfflineProfile.opus256,
      );
      await _waitForStatus(store, 10, groupId, {OfflineGroupStatus.completed});
      await downloader.removeLocal(10, 8, OfflineProfile.opus256);
      await service.reconcileForUser(10);

      final partial = await store.findGroup(10, groupId);
      expect(partial?.status, OfflineGroupStatus.partial);
      expect(partial?.completedItems, 0);
      expect(
        (await store.listGroupItems(groupId)).single.status,
        OfflineGroupItemStatus.queued,
      );
      expect(await store.findGroup(11, groupId), isNull);
      expect(await store.listGroupsForUser(11), isEmpty);
    },
  );

  test(
    'suppression de groupe retire ses copies et ses items uniquement',
    () async {
      final service = manager();
      final groupId = await service.createAndStart(
        userId: 12,
        type: OfflineGroupType.playlist,
        sourceId: 'delete',
        title: 'Delete',
        tracks: [_track(9), _track(10)],
        profile: OfflineProfile.opus128,
      );
      await _waitForStatus(store, 12, groupId, {OfflineGroupStatus.completed});
      await service.removeGroupCopies(12, groupId);

      expect(await store.findGroup(12, groupId), isNull);
      expect(await store.listGroupItems(groupId), isEmpty);
      expect(await store.find(12, 9, OfflineProfile.opus128), isNull);
    },
  );
}
