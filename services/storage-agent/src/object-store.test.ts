import { createHash } from 'node:crypto';
import { createReadStream, readdirSync, writeFileSync } from 'node:fs';
import { mkdir, mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { afterEach, describe, expect, it } from 'vitest';
import {
  DurableObjectStore,
  ObjectStoreError,
  objectAbsolutePath,
  objectRelativePath,
} from './object-store.js';

const roots: string[] = [];

async function fixture(): Promise<{ root: string; store: DurableObjectStore }> {
  const root = await mkdtemp(join(tmpdir(), 'hs-object-store-'));
  roots.push(root);
  return {
    root,
    store: new DurableObjectStore({ musicRoot: root, maxBytes: 1024 }),
  };
}

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe('chemin d’objet', () => {
  it('est déterministe, portable et confiné', () => {
    const hash = 'a'.repeat(64);
    expect(objectRelativePath(hash, 'flac')).toBe(
      `.homespotify/objects/aa/${hash}.flac`,
    );
    expect(objectAbsolutePath('C:\\music', hash, 'wav')).toContain(
      `.homespotify`,
    );
  });

  it('refuse une empreinte ou une extension non contrôlée', () => {
    expect(() => objectRelativePath('../x', 'flac')).toThrowError(ObjectStoreError);
    expect(() => objectRelativePath('a'.repeat(64), '../wav')).toThrowError(ObjectStoreError);
  });
});

describe('publication durable', () => {
  it('publie après contrôle de taille et SHA puis ne laisse aucun .part', async () => {
    const { root, store } = await fixture();
    const body = Buffer.from('audio lossless');
    const hash = createHash('sha256').update(body).digest('hex');

    const receipt = await store.store({
      contentHash: hash,
      extension: 'flac',
      expectedSizeBytes: body.length,
      source: Readable.from(body),
    });

    expect(receipt).toMatchObject({
      contentHash: hash,
      extension: 'flac',
      sizeBytes: body.length,
      reused: false,
      durable: true,
    });
    expect(await readFile(join(root, receipt.relativePath))).toEqual(body);
    const incoming = join(root, '.homespotify', 'incoming');
    expect(readdirSync(incoming).filter((name) => name.endsWith('.part'))).toEqual([]);
  });

  it('est idempotent pour le même objet sans réécriture', async () => {
    const { root, store } = await fixture();
    const body = Buffer.from('same object');
    const hash = createHash('sha256').update(body).digest('hex');

    await store.store({
      contentHash: hash,
      extension: 'wav',
      expectedSizeBytes: body.length,
      source: Readable.from(body),
    });
    const path = objectAbsolutePath(root, hash, 'wav');
    const before = await readFile(path);
    const receipt = await store.store({
      contentHash: hash,
      extension: 'wav',
      expectedSizeBytes: body.length,
      source: Readable.from(body),
    });

    expect(receipt.reused).toBe(true);
    expect(await readFile(path)).toEqual(before);
  });

  it('supprime le partiel et ne publie rien si le corps est tronqué', async () => {
    const { root, store } = await fixture();
    const body = Buffer.from('short');
    const hash = createHash('sha256').update(Buffer.from('expected-longer')).digest('hex');

    await expect(
      store.store({
        contentHash: hash,
        extension: 'flac',
        expectedSizeBytes: body.length + 10,
        source: Readable.from(body),
      }),
    ).rejects.toMatchObject({ code: 'OBJECT_SIZE_MISMATCH' });

    await expect(
      readFile(objectAbsolutePath(root, hash, 'flac')),
    ).rejects.toThrow();
    expect(
      readdirSync(join(root, '.homespotify', 'incoming')).filter((name) => name.endsWith('.part')),
    ).toEqual([]);
  });

  it('refuse une empreinte fausse et conserve un objet existant intact', async () => {
    const { root, store } = await fixture();
    const expected = Buffer.from('expected');
    const hash = createHash('sha256').update(expected).digest('hex');
    const finalPath = objectAbsolutePath(root, hash, 'flac');
    await mkdir(join(root, '.homespotify', 'objects', hash.slice(0, 2)), {
      recursive: true,
    });
    writeFileSync(finalPath, Buffer.from('corrupt'), { flag: 'w' });

    await expect(
      store.store({
        contentHash: hash,
        extension: 'flac',
        expectedSizeBytes: Buffer.byteLength('corrupt'),
        source: createReadStream(finalPath),
      }),
    ).rejects.toMatchObject({ code: 'OBJECT_HASH_MISMATCH' });
    expect(await readFile(finalPath, 'utf8')).toBe('corrupt');
  });

  it('refuse une taille supérieure à la borne avant toute écriture', async () => {
    const { store } = await fixture();
    await expect(
      store.store({
        contentHash: 'b'.repeat(64),
        extension: 'flac',
        expectedSizeBytes: 1025,
        source: Readable.from(Buffer.alloc(0)),
      }),
    ).rejects.toMatchObject({ code: 'OBJECT_TOO_LARGE' });
  });
});
