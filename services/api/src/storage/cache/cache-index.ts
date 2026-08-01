import Database from 'better-sqlite3';

export interface CacheEntry {
  contentHash: string;
  trackId: number;
  sizeBytes: number;
  contentType: string | null;
  modifiedAtMs: number;
  createdAtMs: number;
  lastAccessMs: number;
}

interface CacheRow {
  content_hash: string;
  track_id: number;
  size_bytes: number;
  content_type: string | null;
  modified_at_ms: number;
  created_at_ms: number;
  last_access_ms: number;
}

function entry(row: CacheRow): CacheEntry {
  return {
    contentHash: row.content_hash,
    trackId: row.track_id,
    sizeBytes: row.size_bytes,
    contentType: row.content_type,
    modifiedAtMs: row.modified_at_ms,
    createdAtMs: row.created_at_ms,
    lastAccessMs: row.last_access_ms,
  };
}

export class CacheIndex {
  private readonly database: Database.Database;

  constructor(path: string) {
    this.database = new Database(path);
    this.database.pragma('journal_mode = WAL');
    this.database.pragma('synchronous = FULL');
    this.database.exec(`
      CREATE TABLE IF NOT EXISTS cache_entries (
        content_hash TEXT PRIMARY KEY,
        track_id INTEGER NOT NULL,
        size_bytes INTEGER NOT NULL CHECK(size_bytes >= 0),
        content_type TEXT,
        modified_at_ms INTEGER NOT NULL,
        created_at_ms INTEGER NOT NULL,
        last_access_ms INTEGER NOT NULL,
        complete INTEGER NOT NULL DEFAULT 1 CHECK(complete = 1)
      );
      CREATE INDEX IF NOT EXISTS cache_entries_lru
        ON cache_entries(last_access_ms);
    `);
  }

  get(contentHash: string): CacheEntry | undefined {
    const row = this.database
      .prepare('SELECT * FROM cache_entries WHERE content_hash = ? AND complete = 1')
      .get(contentHash) as CacheRow | undefined;
    return row === undefined ? undefined : entry(row);
  }

  put(value: CacheEntry): void {
    this.database.prepare(`
      INSERT INTO cache_entries (
        content_hash, track_id, size_bytes, content_type,
        modified_at_ms, created_at_ms, last_access_ms, complete
      ) VALUES (?, ?, ?, ?, ?, ?, ?, 1)
      ON CONFLICT(content_hash) DO UPDATE SET
        track_id=excluded.track_id,
        size_bytes=excluded.size_bytes,
        content_type=excluded.content_type,
        modified_at_ms=excluded.modified_at_ms,
        last_access_ms=excluded.last_access_ms,
        complete=1
    `).run(
      value.contentHash,
      value.trackId,
      value.sizeBytes,
      value.contentType,
      value.modifiedAtMs,
      value.createdAtMs,
      value.lastAccessMs,
    );
  }

  touch(contentHash: string, now = Date.now()): void {
    this.database
      .prepare('UPDATE cache_entries SET last_access_ms = ? WHERE content_hash = ?')
      .run(now, contentHash);
  }

  delete(contentHash: string): void {
    this.database.prepare('DELETE FROM cache_entries WHERE content_hash = ?').run(contentHash);
  }

  all(): CacheEntry[] {
    return (
      this.database
        .prepare('SELECT * FROM cache_entries WHERE complete = 1')
        .all() as CacheRow[]
    ).map(entry);
  }

  lru(): CacheEntry[] {
    return (
      this.database
        .prepare(
          'SELECT * FROM cache_entries WHERE complete = 1 ORDER BY last_access_ms ASC',
        )
        .all() as CacheRow[]
    ).map(entry);
  }

  totals(): { entryCount: number; totalBytes: number } {
    return this.database
      .prepare(
        'SELECT count(*) AS entryCount, coalesce(sum(size_bytes), 0) AS totalBytes FROM cache_entries WHERE complete = 1',
      )
      .get() as { entryCount: number; totalBytes: number };
  }

  close(): void {
    this.database.close();
  }
}
