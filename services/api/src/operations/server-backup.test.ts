import { appendFileSync, existsSync, mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import Database from 'better-sqlite3';
import { afterEach, describe, expect, it } from 'vitest';
import { createServerBackup, restoreServerBackup, verifyServerBackup } from './server-backup.js';

describe('server backup', () => {
  const roots: string[] = [];

  afterEach(() => {
    for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
  });

  function fixture() {
    const root = mkdtempSync(join(tmpdir(), 'homespotify-backup-'));
    roots.push(root);
    const dbPath = join(root, 'source', 'homespotify.db');
    mkdirSync(join(root, 'source'), { recursive: true });
    const database = new Database(dbPath);
    database.exec('CREATE TABLE tracks (id INTEGER PRIMARY KEY, title TEXT NOT NULL)');
    database.prepare('INSERT INTO tracks (title) VALUES (?)').run('Original');
    database.close();
    const coversDir = join(root, 'covers');
    const musicDir = join(root, 'music');
    mkdirSync(coversDir);
    mkdirSync(musicDir);
    writeFileSync(join(coversDir, 'cover.jpg'), 'cover');
    writeFileSync(join(musicDir, 'track.flac'), 'audio-test-only');
    return { root, dbPath, coversDir, musicDir };
  }

  it('crée une base cohérente et restaure avec une copie de sécurité', async () => {
    const source = fixture();
    const backupDir = join(source.root, 'backup');
    const manifest = await createServerBackup({
      dbPath: source.dbPath,
      coversDir: source.coversDir,
      musicDir: source.musicDir,
      destinationDir: backupDir,
      includeMedia: false,
      now: new Date('2026-07-21T10:00:00.000Z'),
    });

    expect(manifest.media.included).toBe(false);
    expect(existsSync(join(backupDir, 'music'))).toBe(false);
    expect(existsSync(join(backupDir, 'homespotify.db-wal'))).toBe(false);
    expect(existsSync(join(backupDir, 'homespotify.db-shm'))).toBe(false);
    expect(readFileSync(join(backupDir, 'covers', 'cover.jpg'), 'utf8')).toBe('cover');
    await expect(verifyServerBackup(backupDir)).resolves.toEqual(manifest);

    const targetDb = join(source.root, 'target', 'homespotify.db');
    mkdirSync(join(source.root, 'target'));
    const target = new Database(targetDb);
    target.exec('CREATE TABLE old_data (value TEXT)');
    target.close();
    const targetCovers = join(source.root, 'target-covers');
    const result = await restoreServerBackup({
      backupDir,
      dbPath: targetDb,
      coversDir: targetCovers,
      musicDir: join(source.root, 'target-music'),
      restoreMedia: false,
      now: new Date('2026-07-21T11:00:00.000Z'),
    });

    expect(result.safetyCopyPath).not.toBeNull();
    expect(existsSync(result.safetyCopyPath!)).toBe(true);
    const restored = new Database(targetDb, { readonly: true });
    expect(restored.prepare('SELECT title FROM tracks').pluck().all()).toEqual(['Original']);
    restored.close();
    expect(readFileSync(join(targetCovers, 'cover.jpg'), 'utf8')).toBe('cover');
  });

  it('refuse une sauvegarde altérée avant restauration', async () => {
    const source = fixture();
    const backupDir = join(source.root, 'backup');
    await createServerBackup({
      dbPath: source.dbPath,
      coversDir: source.coversDir,
      musicDir: source.musicDir,
      destinationDir: backupDir,
      includeMedia: true,
    });
    appendFileSync(join(backupDir, 'homespotify.db'), 'tampered');

    await expect(verifyServerBackup(backupDir)).rejects.toThrow(/Taille|SHA-256/);
  });
});
