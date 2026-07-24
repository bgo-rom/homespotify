import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../domain/offline_models.dart';

/// Manifeste local des téléchargements hors ligne.
///
/// Invariants (TD-Offline-Opus / MULTI_USER_DATA_MODEL) :
///  - CHAQUE requête est partitionnée par `user_id` : un logout ne rend jamais
///    lisible le cache d'un autre compte, la purge est logique et par compte ;
///  - aucun Bearer, refresh token ni header HTTP en base ;
///  - `relative_path` est confiné au dossier hors ligne du compte, jamais absolu.
abstract interface class OfflineManifestStore {
  Future<void> upsert(OfflineTrackRecord record);
  Future<OfflineTrackRecord?> find(
    int userId,
    int trackId,
    OfflineProfile profile,
  );
  Future<List<OfflineTrackRecord>> listForUser(int userId);
  Future<List<OfflineTrackRecord>> readyForTrack(int userId, int trackId);
  Future<void> delete(int userId, int trackId, OfflineProfile profile);
  Future<void> touch(int userId, int trackId, OfflineProfile profile);
  Future<void> createGroup(
    OfflineDownloadGroup group,
    List<OfflineDownloadGroupItem> items,
  );
  Future<void> updateGroup(OfflineDownloadGroup group);
  Future<List<OfflineDownloadGroup>> listGroupsForUser(int userId);
  Future<OfflineDownloadGroup?> findGroup(int userId, String groupId);
  Future<List<OfflineDownloadGroupItem>> listGroupItems(String groupId);
  Future<void> updateGroupItem(OfflineDownloadGroupItem item);
  Future<void> deleteGroup(int userId, String groupId);
}

class SqliteOfflineManifestStore implements OfflineManifestStore {
  /// `factory`/`databasePath` injectables : les tests utilisent sqflite FFI
  /// sur un fichier temporaire, l'app la base du sandbox applicatif.
  SqliteOfflineManifestStore({DatabaseFactory? factory, String? databasePath})
    : _factory = factory,
      _databasePath = databasePath;

  final DatabaseFactory? _factory;
  final String? _databasePath;
  Database? _database;
  Future<Database>? _opening;

  Future<Database> _db() {
    final current = _database;
    if (current != null) return Future.value(current);
    return _opening ??= _open();
  }

  Future<Database> _open() async {
    final path =
        _databasePath ??
        '${(await getApplicationSupportDirectory()).path}/offline_library.db';
    final factory = _factory;
    final db = await (factory != null
        ? factory.openDatabase(
            path,
            options: OpenDatabaseOptions(
              version: 2,
              onCreate: _onCreate,
              onUpgrade: _onUpgrade,
            ),
          )
        : openDatabase(
            path,
            version: 2,
            onCreate: _onCreate,
            onUpgrade: _onUpgrade,
          ));
    _database = db;
    _opening = null;
    return db;
  }

  Future<void> _onCreate(Database database, int _) async {
    await database.execute('''
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
            last_accessed_at TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            UNIQUE(user_id, track_id, profile)
          )
        ''');
    await database.execute(
      'CREATE INDEX offline_tracks_user_idx ON offline_tracks(user_id, status)',
    );
    await _createGroupTables(database);
  }

  Future<void> _onUpgrade(
    Database database,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      final columns = await database.rawQuery(
        'PRAGMA table_info(offline_tracks)',
      );
      final hasLastAccessed = columns.any(
        (column) => column['name'] == 'last_accessed_at',
      );
      if (!hasLastAccessed) {
        await database.execute(
          'ALTER TABLE offline_tracks ADD COLUMN last_accessed_at TEXT',
        );
      }
      await _createGroupTables(database);
    }
  }

  Future<void> _createGroupTables(Database database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS offline_download_groups (
        id TEXT PRIMARY KEY,
        user_id INTEGER NOT NULL,
        type TEXT NOT NULL,
        source_id TEXT NOT NULL,
        title TEXT NOT NULL,
        profile TEXT NOT NULL,
        status TEXT NOT NULL,
        total_items INTEGER NOT NULL,
        completed_items INTEGER NOT NULL DEFAULT 0,
        failed_items INTEGER NOT NULL DEFAULT 0,
        estimated_bytes INTEGER NOT NULL DEFAULT 0,
        exact_bytes INTEGER NOT NULL DEFAULT 0,
        error_message TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await database.execute(
      'CREATE INDEX IF NOT EXISTS offline_groups_user_idx '
      'ON offline_download_groups(user_id, updated_at DESC)',
    );
    await database.execute('''
      CREATE TABLE IF NOT EXISTS offline_download_group_items (
        group_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        track_id INTEGER NOT NULL,
        status TEXT NOT NULL,
        title TEXT NOT NULL,
        artist TEXT NOT NULL,
        album TEXT NOT NULL,
        source_sha256 TEXT NOT NULL,
        duration_seconds REAL,
        size_bytes INTEGER,
        mime_type TEXT,
        extension TEXT,
        error_message TEXT,
        PRIMARY KEY(group_id, track_id),
        FOREIGN KEY(group_id) REFERENCES offline_download_groups(id)
          ON DELETE CASCADE
      )
    ''');
    await database.execute(
      'CREATE INDEX IF NOT EXISTS offline_group_items_order_idx '
      'ON offline_download_group_items(group_id, position)',
    );
  }

  Map<String, Object?> _toRow(OfflineTrackRecord record, String now) => {
    'user_id': record.userId,
    'track_id': record.trackId,
    'profile': record.profile.wire,
    'source_sha256': record.sourceSha256,
    'expected_sha256': record.expectedSha256,
    'status': record.status.name,
    'received_bytes': record.receivedBytes,
    'size_bytes': record.sizeBytes,
    'relative_path': record.relativePath,
    'codec': record.codec,
    'container': record.container,
    'lossy': switch (record.lossy) {
      null => null,
      true => 1,
      false => 0,
    },
    'measured_bitrate_kbps': record.measuredBitrateKbps,
    'title': record.title,
    'artist': record.artist,
    'album': record.album,
    'duration_seconds': record.durationSeconds,
    'error_message': record.errorMessage,
    'last_accessed_at': record.lastAccessedAt?.toUtc().toIso8601String(),
    'updated_at': now,
  };

  OfflineTrackRecord _fromRow(Map<String, Object?> row) => OfflineTrackRecord(
    userId: row['user_id'] as int,
    trackId: row['track_id'] as int,
    profile: OfflineProfileWire.parse(row['profile'] as String),
    sourceSha256: row['source_sha256'] as String,
    expectedSha256: row['expected_sha256'] as String?,
    status: OfflineDownloadStatus.values.byName(row['status'] as String),
    receivedBytes: (row['received_bytes'] as int?) ?? 0,
    sizeBytes: row['size_bytes'] as int?,
    relativePath: row['relative_path'] as String?,
    codec: row['codec'] as String?,
    container: row['container'] as String?,
    lossy: switch (row['lossy'] as int?) {
      null => null,
      0 => false,
      _ => true,
    },
    measuredBitrateKbps: row['measured_bitrate_kbps'] as int?,
    title: row['title'] as String?,
    artist: row['artist'] as String?,
    album: row['album'] as String?,
    durationSeconds: (row['duration_seconds'] as num?)?.toDouble(),
    errorMessage: row['error_message'] as String?,
    updatedAt: DateTime.tryParse((row['updated_at'] as String?) ?? ''),
    lastAccessedAt: DateTime.tryParse(
      (row['last_accessed_at'] as String?) ?? '',
    ),
  );

  @override
  Future<void> upsert(OfflineTrackRecord record) async {
    final db = await _db();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('offline_tracks', {
      ..._toRow(record, now),
      'created_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<OfflineTrackRecord?> find(
    int userId,
    int trackId,
    OfflineProfile profile,
  ) async {
    final db = await _db();
    final rows = await db.query(
      'offline_tracks',
      where: 'user_id = ? AND track_id = ? AND profile = ?',
      whereArgs: [userId, trackId, profile.wire],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  @override
  Future<List<OfflineTrackRecord>> listForUser(int userId) async {
    final db = await _db();
    final rows = await db.query(
      'offline_tracks',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'updated_at DESC',
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  @override
  Future<List<OfflineTrackRecord>> readyForTrack(
    int userId,
    int trackId,
  ) async {
    final db = await _db();
    final rows = await db.query(
      'offline_tracks',
      where: 'user_id = ? AND track_id = ? AND status = ?',
      whereArgs: [userId, trackId, OfflineDownloadStatus.ready.name],
    );
    return rows.map(_fromRow).toList(growable: false);
  }

  @override
  Future<void> delete(int userId, int trackId, OfflineProfile profile) async {
    final db = await _db();
    await db.delete(
      'offline_tracks',
      where: 'user_id = ? AND track_id = ? AND profile = ?',
      whereArgs: [userId, trackId, profile.wire],
    );
  }

  @override
  Future<void> touch(int userId, int trackId, OfflineProfile profile) async {
    final db = await _db();
    await db.update(
      'offline_tracks',
      {'last_accessed_at': DateTime.now().toUtc().toIso8601String()},
      where: 'user_id = ? AND track_id = ? AND profile = ?',
      whereArgs: [userId, trackId, profile.wire],
    );
  }

  Map<String, Object?> _groupToRow(OfflineDownloadGroup group) => {
    'id': group.id,
    'user_id': group.userId,
    'type': group.type.name,
    'source_id': group.sourceId,
    'title': group.title,
    'profile': group.profile.wire,
    'status': group.status.name,
    'total_items': group.totalItems,
    'completed_items': group.completedItems,
    'failed_items': group.failedItems,
    'estimated_bytes': group.estimatedBytes,
    'exact_bytes': group.exactBytes,
    'error_message': group.errorMessage,
    'created_at': group.createdAt.toUtc().toIso8601String(),
    'updated_at': group.updatedAt.toUtc().toIso8601String(),
  };

  OfflineDownloadGroup _groupFromRow(Map<String, Object?> row) =>
      OfflineDownloadGroup(
        id: row['id'] as String,
        userId: row['user_id'] as int,
        type: OfflineGroupType.values.byName(row['type'] as String),
        sourceId: row['source_id'] as String,
        title: row['title'] as String,
        profile: OfflineProfileWire.parse(row['profile'] as String),
        status: OfflineGroupStatus.values.byName(row['status'] as String),
        totalItems: row['total_items'] as int,
        completedItems: row['completed_items'] as int,
        failedItems: row['failed_items'] as int,
        estimatedBytes: row['estimated_bytes'] as int,
        exactBytes: row['exact_bytes'] as int,
        errorMessage: row['error_message'] as String?,
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );

  Map<String, Object?> _groupItemToRow(OfflineDownloadGroupItem item) => {
    'group_id': item.groupId,
    'position': item.position,
    'track_id': item.trackId,
    'status': item.status.name,
    'title': item.title,
    'artist': item.artist,
    'album': item.album,
    'source_sha256': item.sourceSha256,
    'duration_seconds': item.durationSeconds,
    'size_bytes': item.sizeBytes,
    'mime_type': item.mimeType,
    'extension': item.extension,
    'error_message': item.errorMessage,
  };

  OfflineDownloadGroupItem _groupItemFromRow(Map<String, Object?> row) =>
      OfflineDownloadGroupItem(
        groupId: row['group_id'] as String,
        position: row['position'] as int,
        trackId: row['track_id'] as int,
        status: OfflineGroupItemStatus.values.byName(row['status'] as String),
        title: row['title'] as String,
        artist: row['artist'] as String,
        album: row['album'] as String,
        sourceSha256: row['source_sha256'] as String,
        durationSeconds: (row['duration_seconds'] as num?)?.toDouble(),
        sizeBytes: row['size_bytes'] as int?,
        mimeType: row['mime_type'] as String?,
        extension: row['extension'] as String?,
        errorMessage: row['error_message'] as String?,
      );

  @override
  Future<void> createGroup(
    OfflineDownloadGroup group,
    List<OfflineDownloadGroupItem> items,
  ) async {
    final db = await _db();
    await db.transaction((txn) async {
      await txn.insert('offline_download_groups', _groupToRow(group));
      for (final item in items) {
        await txn.insert('offline_download_group_items', _groupItemToRow(item));
      }
    });
  }

  @override
  Future<void> updateGroup(OfflineDownloadGroup group) async {
    final db = await _db();
    await db.update(
      'offline_download_groups',
      _groupToRow(group),
      where: 'id = ? AND user_id = ?',
      whereArgs: [group.id, group.userId],
    );
  }

  @override
  Future<List<OfflineDownloadGroup>> listGroupsForUser(int userId) async {
    final db = await _db();
    final rows = await db.query(
      'offline_download_groups',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'updated_at DESC',
    );
    return rows.map(_groupFromRow).toList(growable: false);
  }

  @override
  Future<OfflineDownloadGroup?> findGroup(int userId, String groupId) async {
    final db = await _db();
    final rows = await db.query(
      'offline_download_groups',
      where: 'id = ? AND user_id = ?',
      whereArgs: [groupId, userId],
      limit: 1,
    );
    return rows.isEmpty ? null : _groupFromRow(rows.first);
  }

  @override
  Future<List<OfflineDownloadGroupItem>> listGroupItems(String groupId) async {
    final db = await _db();
    final rows = await db.query(
      'offline_download_group_items',
      where: 'group_id = ?',
      whereArgs: [groupId],
      orderBy: 'position ASC',
    );
    return rows.map(_groupItemFromRow).toList(growable: false);
  }

  @override
  Future<void> updateGroupItem(OfflineDownloadGroupItem item) async {
    final db = await _db();
    await db.update(
      'offline_download_group_items',
      _groupItemToRow(item),
      where: 'group_id = ? AND track_id = ?',
      whereArgs: [item.groupId, item.trackId],
    );
  }

  @override
  Future<void> deleteGroup(int userId, String groupId) async {
    final db = await _db();
    await db.transaction((txn) async {
      final owned = await txn.query(
        'offline_download_groups',
        columns: const ['id'],
        where: 'id = ? AND user_id = ?',
        whereArgs: [groupId, userId],
        limit: 1,
      );
      if (owned.isEmpty) return;
      await txn.delete(
        'offline_download_group_items',
        where: 'group_id = ?',
        whereArgs: [groupId],
      );
      await txn.delete(
        'offline_download_groups',
        where: 'id = ? AND user_id = ?',
        whereArgs: [groupId, userId],
      );
    });
  }
}

final offlineManifestStoreProvider = Provider<OfflineManifestStore>(
  (ref) => SqliteOfflineManifestStore(),
);
