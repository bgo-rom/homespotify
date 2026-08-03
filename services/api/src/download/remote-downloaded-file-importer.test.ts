import { createHash } from 'node:crypto';
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { createDb, type DbHandle } from '../db/client.js';
import { runMigrations } from '../db/migrate.js';
import { tracks, userTracks, users } from '../db/schema.js';
import { makeFlac } from '../test/flac.js';
import {
  RemoteDownloadedFileImporter,
  RemoteDownloadedFileImportError,
  type RemoteStorageWriteClient,
} from './remote-downloaded-file-importer.js';
import type {
  DurableIndexReceipt,
  DurableObjectReceipt,
} from '../storage/remote/storage-agent-client.js';

let root: string;
let handle: DbHandle;
let userId: number;

const silentLogger = {
  info() {},
  warn() {},
  error() {},
};

class FakeWriteClient implements RemoteStorageWriteClient {
  readonly objects: Array<{
    contentHash: string;
    extension: 'flac' | 'wav';
    sizeBytes: number;
  }> = [];
  readonly indexes: Buffer[] = [];
  objectBarrier:
    | {
        promise: Promise<void>;
        release: () => void;
      }
    | undefined;
  failIndex = false;

  async putObject(input: {
    filePath: string;
    contentHash: string;
    extension: 'flac' | 'wav';
    sizeBytes: number;
  }): Promise<DurableObjectReceipt> {
    this.objects.push({
      contentHash: input.contentHash,
      extension: input.extension,
      sizeBytes: input.sizeBytes,
    });
    if (this.objectBarrier) await this.objectBarrier.promise;
    return {
      status: 'stored',
      contentHash: input.contentHash,
      extension: input.extension,
      sizeBytes: input.sizeBytes,
      reused: this.objects.length > 1,
      durable: true,
    };
  }

  async putIndex(input: {
    body: Buffer;
    contentSha256: string;
  }): Promise<DurableIndexReceipt> {
    this.indexes.push(input.body);
    if (this.failIndex) throw new Error('index indisponible');
    const parsed = JSON.parse(input.body.toString('utf8')) as {
      generatedAt: string;
      entries: Record<string, unknown>;
    };
    return {
      status: 'index_stored',
      contentSha256: input.contentSha256,
      entryCount: Object.keys(parsed.entries).length,
      generatedAt: parsed.generatedAt,
      durable: true,
    };
  }

  close(): void {}
}

function deferred(): {
  promise: Promise<void>;
  release: () => void;
} {
  let release = () => {};
  const promise = new Promise<void>((resolve) => {
    release = resolve;
  });
  return { promise, release };
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'hs-remote-importer-'));
  handle = createDb(join(root, 'db.sqlite'));
  runMigrations(handle, { info() {}, error() {} });
  const now = new Date().toISOString();
  userId = handle.db
    .insert(users)
    .values({
      username: 'owner',
      displayName: 'Owner',
      passwordHash: 'x',
      role: 'OWNER',
      createdAt: now,
      updatedAt: now,
    })
    .returning()
    .get()!.id;
});

afterEach(() => {
  handle.sqlite.close();
  rmSync(root, { recursive: true, force: true });
});

describe('RemoteDownloadedFileImporter', () => {
  it('n’écrit aucune piste avant le reçu durable, puis publie l’index', async () => {
    const filePath = join(root, 'track.flac');
    const body = makeFlac({ seconds: 5 });
    writeFileSync(filePath, body);
    const client = new FakeWriteClient();
    client.objectBarrier = deferred();
    const importer = new RemoteDownloadedFileImporter(handle, {
      coversDir: join(root, 'covers'),
      client,
      logger: silentLogger,
    });

    const pending = importer.importDownloadedFile({
      userId,
      filePath,
      requestId: 'download-1',
    });
    while (client.objects.length === 0) {
      await new Promise((resolve) => setTimeout(resolve, 2));
    }

    expect(handle.db.select().from(tracks).all()).toHaveLength(0);
    client.objectBarrier.release();
    const result = await pending;

    expect(result.status).toBe('IMPORTED');
    expect(handle.db.select().from(tracks).all()).toHaveLength(1);
    expect(handle.db.select().from(userTracks).all()).toHaveLength(1);
    expect(client.indexes).toHaveLength(1);
    const index = JSON.parse(client.indexes[0]!.toString('utf8')) as {
      entries: Record<string, { relativePath: string }>;
    };
    const track = handle.db.select().from(tracks).get()!;
    expect(index.entries[String(track.id)]?.relativePath).toBe(track.path);
    expect(track.path).toMatch(
      /^\.homespotify\/objects\/[a-f0-9]{2}\/[a-f0-9]{64}\.flac$/,
    );
    expect(existsSync(filePath)).toBe(true);
  });

  it('garde une transaction atomique si l’utilisateur est invalide', async () => {
    const filePath = join(root, 'track.flac');
    writeFileSync(filePath, makeFlac({ seconds: 5 }));
    const client = new FakeWriteClient();
    const importer = new RemoteDownloadedFileImporter(handle, {
      coversDir: join(root, 'covers'),
      client,
      logger: silentLogger,
    });

    await expect(
      importer.importDownloadedFile({
        userId: userId + 999,
        filePath,
      }),
    ).rejects.toMatchObject({ code: 'database_failed' });

    expect(client.objects).toHaveLength(1);
    expect(handle.db.select().from(tracks).all()).toHaveLength(0);
    expect(handle.db.select().from(userTracks).all()).toHaveLength(0);
    expect(existsSync(filePath)).toBe(true);
  });

  it('reprend idempotemment après un échec de publication d’index', async () => {
    const filePath = join(root, 'track.flac');
    writeFileSync(filePath, makeFlac({ seconds: 5 }));
    const client = new FakeWriteClient();
    client.failIndex = true;
    const importer = new RemoteDownloadedFileImporter(handle, {
      coversDir: join(root, 'covers'),
      client,
      logger: silentLogger,
    });

    await expect(
      importer.importDownloadedFile({ userId, filePath }),
    ).rejects.toBeInstanceOf(RemoteDownloadedFileImportError);
    expect(handle.db.select().from(tracks).all()).toHaveLength(1);
    expect(existsSync(filePath)).toBe(true);

    client.failIndex = false;
    const retried = await importer.importDownloadedFile({
      userId,
      filePath,
    });
    expect(retried.status).toBe('REUSED');
    expect(client.objects).toHaveLength(2);
    expect(client.indexes).toHaveLength(2);
    expect(handle.db.select().from(tracks).all()).toHaveLength(1);
  });
});
