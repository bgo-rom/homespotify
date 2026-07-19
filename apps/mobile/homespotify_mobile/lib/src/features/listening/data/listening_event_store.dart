import 'dart:convert';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class PendingListeningEvent {
  const PendingListeningEvent({required this.id, required this.payload});
  final int id;
  final Map<String, dynamic> payload;
}

abstract interface class ListeningEventStore {
  Future<void> enqueue(int userId, Map<String, dynamic> payload);
  Future<List<PendingListeningEvent>> pending(int userId, {int limit = 50});
  Future<void> acknowledge(Iterable<int> ids);
  Future<void> markRetry(
    Iterable<int> ids,
    String category,
    DateTime nextAttemptAt,
  );
}

class SqliteListeningEventStore implements ListeningEventStore {
  Database? _database;
  Future<Database>? _opening;

  Future<Database> _db() {
    final current = _database;
    if (current != null) return Future.value(current);
    return _opening ??= _open();
  }

  Future<Database> _open() async {
    final directory = await getApplicationSupportDirectory();
    final db = await openDatabase(
      '${directory.path}/listening_activity.db',
      version: 1,
      onCreate: (database, _) async {
        await database.execute('''
          CREATE TABLE pending_listening_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER NOT NULL,
            client_event_id TEXT NOT NULL,
            event_type TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            next_attempt_at TEXT NOT NULL,
            last_error_category TEXT,
            UNIQUE(user_id, client_event_id)
          )
        ''');
        await database.execute(
          'CREATE INDEX pending_listening_events_due_idx '
          'ON pending_listening_events(user_id, next_attempt_at, id)',
        );
      },
    );
    _database = db;
    _opening = null;
    return db;
  }

  @override
  Future<void> enqueue(int userId, Map<String, dynamic> payload) async {
    final db = await _db();
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert('pending_listening_events', {
      'user_id': userId,
      'client_event_id': payload['clientEventId'] as String,
      'event_type': payload['type'] as String,
      'payload_json': jsonEncode(payload),
      'created_at': now,
      'next_attempt_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await _compact(db, userId);
  }

  Future<void> _compact(Database db, int userId) async {
    await db.delete(
      'pending_listening_events',
      where: 'user_id = ? AND created_at < ?',
      whereArgs: [
        userId,
        DateTime.now()
            .toUtc()
            .subtract(const Duration(days: 7))
            .toIso8601String(),
      ],
    );
    final count =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM pending_listening_events WHERE user_id = ?',
            [userId],
          ),
        ) ??
        0;
    if (count <= 1000) return;
    final overflow = count - 900;
    await db.rawDelete(
      '''DELETE FROM pending_listening_events WHERE id IN (
        SELECT id FROM pending_listening_events
        WHERE user_id = ? AND event_type = 'PLAY_PROGRESS'
        ORDER BY id ASC LIMIT ?
      )''',
      [userId, overflow],
    );
    final afterProgress =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM pending_listening_events WHERE user_id = ?',
            [userId],
          ),
        ) ??
        0;
    if (afterProgress > 1000) {
      await db.rawDelete(
        '''DELETE FROM pending_listening_events WHERE id IN (
          SELECT id FROM pending_listening_events
          WHERE user_id = ? AND event_type NOT IN ('PLAY_STARTED', 'PLAY_COMPLETED')
          ORDER BY id ASC LIMIT ?
        )''',
        [userId, afterProgress - 1000],
      );
    }
  }

  @override
  Future<List<PendingListeningEvent>> pending(
    int userId, {
    int limit = 50,
  }) async {
    final db = await _db();
    final rows = await db.query(
      'pending_listening_events',
      columns: ['id', 'payload_json'],
      where: 'user_id = ? AND next_attempt_at <= ?',
      whereArgs: [userId, DateTime.now().toUtc().toIso8601String()],
      orderBy: 'id ASC',
      limit: limit,
    );
    return rows
        .map(
          (row) => PendingListeningEvent(
            id: row['id'] as int,
            payload:
                jsonDecode(row['payload_json'] as String)
                    as Map<String, dynamic>,
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> acknowledge(Iterable<int> ids) async {
    final values = ids.toList(growable: false);
    if (values.isEmpty) return;
    final db = await _db();
    final marks = List.filled(values.length, '?').join(',');
    await db.rawDelete(
      'DELETE FROM pending_listening_events WHERE id IN ($marks)',
      values,
    );
  }

  @override
  Future<void> markRetry(
    Iterable<int> ids,
    String category,
    DateTime nextAttemptAt,
  ) async {
    final values = ids.toList(growable: false);
    if (values.isEmpty) return;
    final db = await _db();
    final marks = List.filled(values.length, '?').join(',');
    await db.rawUpdate(
      'UPDATE pending_listening_events SET attempts = attempts + 1, '
      'last_error_category = ?, next_attempt_at = ? WHERE id IN ($marks)',
      [category, nextAttemptAt.toUtc().toIso8601String(), ...values],
    );
  }
}
