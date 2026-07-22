import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { ServerBackupScheduler } from './backup-scheduler.js';
import type { CreateServerBackupOptions, ServerBackupManifest } from './server-backup.js';

const roots: string[] = [];

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

describe('ServerBackupScheduler', () => {
  it('borne la rétention et expose le dernier succès sans journaliser de secret', async () => {
    const root = mkdtempSync(join(tmpdir(), 'homespotify-backup-scheduler-'));
    roots.push(root);
    let now = new Date(2026, 6, 21, 3, 0, 0, 0);
    const create = async (options: CreateServerBackupOptions): Promise<ServerBackupManifest> => {
      mkdirSync(options.destinationDir, { recursive: true });
      const manifest: ServerBackupManifest = {
        formatVersion: 1,
        createdAt: (options.now ?? now).toISOString(),
        database: { filename: 'homespotify.db', bytes: 10, sha256: 'a'.repeat(64) },
        covers: { included: true, directory: 'covers' },
        media: { included: false, directory: 'music' },
      };
      writeFileSync(
        join(options.destinationDir, 'manifest.json'),
        JSON.stringify(manifest),
      );
      return manifest;
    };
    const scheduler = new ServerBackupScheduler(
      { enabled: true, root, hourLocal: 3, retentionCount: 2 },
      { dbPath: 'db', coversDir: 'covers', musicDir: 'music' },
      { info: () => undefined, error: () => undefined },
      create,
      () => now,
    );

    for (let index = 0; index < 3; index += 1) {
      await scheduler.runNow();
      now = new Date(now.getTime() + 1000);
    }

    const backups = readdirSync(root).filter((name) => name.startsWith('homespotify-'));
    expect(backups).toHaveLength(2);
    expect(scheduler.status()).toMatchObject({
      enabled: true,
      running: false,
      lastSuccessAt: '2026-07-21T01:00:02.000Z',
      lastError: null,
      retentionCount: 2,
    });
    scheduler.stop();
  });
});
