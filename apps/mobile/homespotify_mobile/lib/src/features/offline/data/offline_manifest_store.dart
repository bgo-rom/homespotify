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
  Future<OfflineTrackRecord?> find(int userId, int trackId, OfflineProfile profile);
  Future<List<OfflineTrackRecord>> listForUser(int userId);
  Future<List<OfflineTrackRecord>> readyForTrack(int userId, int trackId);
  Future<void> delete(int userId, int trackId, OfflineProfile profile);
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
            options: OpenDatabaseOptions(version: 1, onCreate: _onCreate),
          )
        : openDatabase(path, version: 1, onCreate: _onCreate));
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
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            UNIQUE(user_id, track_id, profile)
          )
        ''');
    await database.execute(
      'CREATE INDEX offline_tracks_user_idx ON offline_tracks(user_id, status)',
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
  Future<List<OfflineTrackRecord>> readyForTrack(int userId, int trackId) async {
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
}

final offlineManifestStoreProvider = Provider<OfflineManifestStore>(
  (ref) => SqliteOfflineManifestStore(),
);
