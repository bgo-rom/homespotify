import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { createDb, type DbHandle } from '../db/client.js';
import { runMigrations } from '../db/migrate.js';
import { tracks, userTracks, users } from '../db/schema.js';
import type {
  DurableIndexReceipt,
  DurableObjectReceipt,
} from '../storage/remote/storage-agent-client.js';
import { makeFlac } from '../test/flac.js';
import {
  RemoteDownloadedFileImporter,
  type RemoteStorageWriteClient,
} from './remote-downloaded-file-importer.js';

let root: string;
let handle: DbHandle;
let ownerId: number;

const silentLogger = {
  info() {},
  warn() {},
  error() {},
};

function deferred(): { promise: Promise<void>; release: () => void } {
  let release = () => {};
  const promise = new Promise<void>((resolve) => {
    release = resolve;
  });
  return { promise, release };
}

class FaultClient implements RemoteStorageWriteClient {
  readonly objectCalls: Array<{
    contentHash: string;
    extension: 'flac' | 'wav';
    sizeBytes: number;
  }> = [];
  readonly indexCalls: Buffer[] = [];
  readonly durableObjects = new Set<string>();
  objectResponseLosses = 0;
  indexResponseLosses = 0;
  invalidObjectReceipt = false;
  indexDelayMs = 0;
  maxConcurrentIndexes = 0;
  private activeIndexes = 0;
  private objectGate:
    | { target: number; wait: Promise<void>; release: () => void }
    | undefined;

  gateObjectsUntil(target: number): void {
    const gate = deferred();
    this.objectGate = {
      target,
      wait: gate.promise,
      release: gate.release,
    };
  }

  async putObject(input: {
    filePath: string;
    contentHash: string;
    extension: 'flac' | 'wav';
    sizeBytes: number;
  }): Promise<DurableObjectReceipt> {
    const reused = this.durableObjects.has(input.contentHash);
    this.durableObjects.add(input.contentHash);
    this.objectCalls.push({
      contentHash: input.contentHash,
      extension: input.extension,
      sizeBytes: input.sizeBytes,
    });

    if (this.objectGate !== undefined) {
      if (this.objectCalls.length >= this.objectGate.target) {
        this.objectGate.release();
      }
      await this.objectGate.wait;
    }

    if (this.objectResponseLosses > 0) {
      this.objectResponseLosses -= 1;
      throw new Error('réponse objet perdue après publication');
    }

    if (this.invalidObjectReceipt) {
      return {
        status: 'stored',
        contentHash: input.contentHash,
        extension: input.extension,
        sizeBytes: input.sizeBytes + 1,
        reused,
        durable: true,
      };
    }

    return {
      status: 'stored',
      contentHash: input.contentHash,
      extension: input.extension,
      sizeBytes: input.sizeBytes,
      reused,
      durable: true,
    };
  }

  async putIndex(input: {
    body: Buffer;
    contentSha256: string;
  }): Promise<DurableIndexReceipt> {
    this.indexCalls.push(input.body);
    this.activeIndexes += 1;
    this.maxConcurrentIndexes = Math.max(
      this.maxConcurrentIndexes,
      this.activeIndexes,
    );
    try {
      if (this.indexDelayMs > 0) {
        await new Promise((resolve) => setTimeout(resolve, this.indexDelayMs));
      }
      if (this.indexResponseLosses > 0) {
        this.indexResponseLosses -= 1;
        throw new Error('réponse index perdue après publication');
      }
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
    } finally {
      this.activeIndexes -= 1;
    }
  }

  close(): void {}
}

function createUser(username: string): number {
  const now = new Date().toISOString();
  return handle.db
    .insert(users)
    .values({
      username,
      displayName: username,
      passwordHash: 'x',
      role: 'USER',
      createdAt: now,
      updatedAt: now,
    })
    .returning()
    .get()!.id;
}

function importer(client: FaultClient): RemoteDownloadedFileImporter {
  return new RemoteDownloadedFileImporter(handle, {
    coversDir: join(root, 'covers'),
    client,
    logger: silentLogger,
  });
}

function audioFile(): string {
  const filePath = join(root, 'fault-track.flac');
  writeFileSync(filePath, makeFlac({ seconds: 5 }));
  return filePath;
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'hs-remote-import-faults-'));
  handle = createDb(join(root, 'db.sqlite'));
  runMigrations(handle, { info() {}, error() {} });
  ownerId = createUser('owner');
});

afterEach(() => {
  handle.sqlite.close();
  rmSync(root, { recursive: true, force: true });
});

describe('RemoteDownloadedFileImporter — matrice de pannes', () => {
  it('reprend après une réponse objet perdue sans écrire SQLite trop tôt', async () => {
    const client = new FaultClient();
    client.objectResponseLosses = 1;
    const service = importer(client);
    const filePath = audioFile();

    await expect(
      service.importDownloadedFile({ userId: ownerId, filePath }),
    ).rejects.toMatchObject({ code: 'durability_not_confirmed' });
    expect(handle.db.select().from(tracks).all()).toHaveLength(0);
    expect(client.indexCalls).toHaveLength(0);

    const retried = await service.importDownloadedFile({
      userId: ownerId,
      filePath,
    });
    expect(retried.status).toBe('IMPORTED');
    expect(client.objectCalls).toHaveLength(2);
    expect(client.indexCalls).toHaveLength(1);
    expect(handle.db.select().from(tracks).all()).toHaveLength(1);
  });

  it('reprend après une réponse index perdue sans créer une seconde piste', async () => {
    const client = new FaultClient();
    client.indexResponseLosses = 1;
    const service = importer(client);
    const filePath = audioFile();

    await expect(
      service.importDownloadedFile({ userId: ownerId, filePath }),
    ).rejects.toMatchObject({ code: 'index_publish_failed' });
    expect(handle.db.select().from(tracks).all()).toHaveLength(1);
    expect(client.indexCalls).toHaveLength(1);

    const retried = await service.importDownloadedFile({
      userId: ownerId,
      filePath,
    });
    expect(retried.status).toBe('REUSED');
    expect(handle.db.select().from(tracks).all()).toHaveLength(1);
    expect(client.objectCalls).toHaveLength(2);
    expect(client.indexCalls).toHaveLength(2);
  });

  it('garde l’objet orphelin récupérable après échec SQLite', async () => {
    const client = new FaultClient();
    const service = importer(client);
    const filePath = audioFile();

    await expect(
      service.importDownloadedFile({ userId: ownerId + 999, filePath }),
    ).rejects.toMatchObject({ code: 'database_failed' });
    expect(client.durableObjects.size).toBe(1);
    expect(handle.db.select().from(tracks).all()).toHaveLength(0);
    expect(client.indexCalls).toHaveLength(0);

    const retried = await service.importDownloadedFile({
      userId: ownerId,
      filePath,
    });
    expect(retried.status).toBe('IMPORTED');
    expect(handle.db.select().from(tracks).all()).toHaveLength(1);
    expect(client.indexCalls).toHaveLength(1);
  });

  it('refuse un reçu objet incohérent sans modifier SQLite', async () => {
    const client = new FaultClient();
    client.invalidObjectReceipt = true;
    const service = importer(client);

    await expect(
      service.importDownloadedFile({
        userId: ownerId,
        filePath: audioFile(),
      }),
    ).rejects.toMatchObject({ code: 'durability_not_confirmed' });
    expect(handle.db.select().from(tracks).all()).toHaveLength(0);
    expect(handle.db.select().from(userTracks).all()).toHaveLength(0);
    expect(client.indexCalls).toHaveLength(0);
  });

  it('sérialise deux imports concurrents et ne crée qu’une piste', async () => {
    const secondUserId = createUser('second-user');
    const client = new FaultClient();
    client.gateObjectsUntil(2);
    client.indexDelayMs = 20;
    const service = importer(client);
    const filePath = audioFile();

    const results = await Promise.all([
      service.importDownloadedFile({ userId: ownerId, filePath }),
      service.importDownloadedFile({ userId: secondUserId, filePath }),
    ]);

    expect(results.map((result) => result.status).sort()).toEqual([
      'IMPORTED',
      'REUSED',
    ]);
    expect(handle.db.select().from(tracks).all()).toHaveLength(1);
    expect(handle.db.select().from(userTracks).all()).toHaveLength(2);
    expect(client.objectCalls).toHaveLength(2);
    expect(client.indexCalls).toHaveLength(2);
    expect(client.maxConcurrentIndexes).toBe(1);
  });
});
