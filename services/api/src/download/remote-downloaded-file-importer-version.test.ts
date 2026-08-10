/**
 * Barrière de version et publication d'index — chemin distant RÉEL.
 *
 * Ces cas couvrent `AUDIO_STORAGE_MODE=cached`, c'est-à-dire
 * `RemoteDownloadedFileImporter`, et non `UserImportService` : c'est ce
 * chemin-là qui a installé `addiction (Slowed)` à la place de `addiction`
 * en production le 2026-08-10 (LESSONS L-081).
 */
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { createDb, type DbHandle } from '../db/client.js';
import { runMigrations } from '../db/migrate.js';
import { tracks, userTracks, users } from '../db/schema.js';
import { versionFingerprint } from '../lib/version-identity.js';
import type {
  DurableIndexReceipt,
  DurableObjectReceipt,
} from '../storage/remote/storage-agent-client.js';
import { makeFlac } from '../test/flac.js';
import {
  INDEX_PUBLISH_ATTEMPTS,
  RemoteDownloadedFileImporter,
  type RemoteStorageWriteClient,
} from './remote-downloaded-file-importer.js';

let root: string;
let handle: DbHandle;
let ownerId: number;

const silentLogger = { info() {}, warn() {}, error() {} };

class RecordingClient implements RemoteStorageWriteClient {
  readonly objectCalls: string[] = [];
  readonly indexCalls: string[] = [];
  /** Nombre d'échecs à simuler sur `putIndex` avant le premier succès. */
  indexFailures = 0;

  async putObject(input: {
    contentHash: string;
    extension: 'flac' | 'wav';
    sizeBytes: number;
  }): Promise<DurableObjectReceipt> {
    this.objectCalls.push(input.contentHash);
    return {
      status: 'stored',
      contentHash: input.contentHash,
      extension: input.extension,
      sizeBytes: input.sizeBytes,
      reused: false,
      durable: true,
    };
  }

  async putIndex(input: {
    body: Buffer;
    contentSha256: string;
  }): Promise<DurableIndexReceipt> {
    this.indexCalls.push(input.contentSha256);
    if (this.indexFailures > 0) {
      this.indexFailures -= 1;
      // Panne observée en production : l'agent Windows répond 500 parce qu'il
      // ne peut pas remplacer son fichier d'index.
      throw new Error('storage agent 500 INDEX_WRITE_FAILED');
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
  }

  close(): void {}
}

function importer(client: RecordingClient): RemoteDownloadedFileImporter {
  return new RemoteDownloadedFileImporter(handle, {
    coversDir: join(root, 'covers'),
    client,
    logger: silentLogger,
  });
}

/** Fichier FLAC réel, étiqueté comme la source l'aurait livré. */
function audioFile(title: string, fileName = 'downloaded.flac'): string {
  const filePath = join(root, fileName);
  writeFileSync(
    filePath,
    makeFlac({
      seconds: 5,
      tags: { TITLE: title, ARTIST: 'LONOWN', ALBUM: 'addiction - Single' },
    }),
  );
  return filePath;
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'hs-remote-import-version-'));
  handle = createDb(join(root, 'db.sqlite'));
  runMigrations(handle, { info() {}, error() {} });
  const now = new Date().toISOString();
  ownerId = handle.db
    .insert(users)
    .values({
      username: 'owner',
      displayName: 'owner',
      passwordHash: 'x',
      role: 'USER',
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

describe('import distant — barrière de version', () => {
  it('refuse une version ralentie livrée pour une demande normale', async () => {
    const client = new RecordingClient();
    const service = importer(client);

    await expect(
      service.importDownloadedFile({
        userId: ownerId,
        filePath: audioFile('addiction (Slowed)'),
        expectedVersionFingerprint: versionFingerprint('LONOWN addiction'),
      }),
    ).rejects.toMatchObject({ code: 'version_mismatch' });

    // Refus AVANT toute écriture : ni objet durable, ni piste, ni index.
    expect(client.objectCalls).toHaveLength(0);
    expect(client.indexCalls).toHaveLength(0);
    expect(handle.db.select().from(tracks).all()).toHaveLength(0);
    expect(handle.db.select().from(userTracks).all()).toHaveLength(0);
  });

  it('refuse aussi la version normale livrée pour une demande ralentie', async () => {
    const client = new RecordingClient();
    const service = importer(client);

    await expect(
      service.importDownloadedFile({
        userId: ownerId,
        filePath: audioFile('addiction'),
        expectedVersionFingerprint: versionFingerprint('LONOWN addiction slowed'),
      }),
    ).rejects.toMatchObject({ code: 'version_mismatch' });
    expect(handle.db.select().from(tracks).all()).toHaveLength(0);
  });

  it('accepte la version demandée', async () => {
    const client = new RecordingClient();
    const service = importer(client);

    const result = await service.importDownloadedFile({
      userId: ownerId,
      filePath: audioFile('addiction'),
      expectedVersionFingerprint: versionFingerprint('LONOWN addiction'),
    });

    expect(result.status).toBe('IMPORTED');
    expect(handle.db.select().from(tracks).all()).toHaveLength(1);
  });

  it('n’impose rien quand l’intention est inconnue (URL collée)', async () => {
    const client = new RecordingClient();
    const service = importer(client);

    const result = await service.importDownloadedFile({
      userId: ownerId,
      filePath: audioFile('addiction (Slowed)'),
    });

    expect(result.status).toBe('IMPORTED');
  });
});

describe('publication d’index — reprise automatique', () => {
  it('réessaie une panne passagère de l’agent et termine l’import', async () => {
    const client = new RecordingClient();
    client.indexFailures = INDEX_PUBLISH_ATTEMPTS - 1;
    const service = importer(client);

    const result = await service.importDownloadedFile({
      userId: ownerId,
      filePath: audioFile('addiction'),
      expectedVersionFingerprint: '',
    });

    expect(result.status).toBe('IMPORTED');
    expect(client.indexCalls).toHaveLength(INDEX_PUBLISH_ATTEMPTS);
    // Publication idempotente : le même document est renvoyé à chaque essai.
    expect(new Set(client.indexCalls).size).toBe(1);
    expect(handle.db.select().from(tracks).all()).toHaveLength(1);
  });

  it('échoue explicitement quand l’agent reste indisponible', async () => {
    const client = new RecordingClient();
    client.indexFailures = INDEX_PUBLISH_ATTEMPTS;
    const service = importer(client);

    await expect(
      service.importDownloadedFile({
        userId: ownerId,
        filePath: audioFile('addiction'),
        expectedVersionFingerprint: '',
      }),
    ).rejects.toMatchObject({ code: 'index_publish_failed' });
    expect(client.indexCalls).toHaveLength(INDEX_PUBLISH_ATTEMPTS);
    // La piste est en base : c'est précisément ce que dit le message d'erreur.
    expect(handle.db.select().from(tracks).all()).toHaveLength(1);
  });
});
