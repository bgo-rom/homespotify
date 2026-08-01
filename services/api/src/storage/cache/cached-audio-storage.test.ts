import { createHash } from 'node:crypto';
import {
  appendFileSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  rmSync,
  utimesSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { afterEach, describe, expect, it } from 'vitest';
import {
  AudioStorageError,
  type AudioFileInfo,
  type AudioStorageProvider,
  type ByteRange,
  type StorageHealth,
  type TrackStorageReference,
} from '../audio-storage.js';
import {
  AudioCacheConfigError,
  loadAudioCacheConfig,
  type AudioCacheConfig,
} from './cache-config.js';
import { CachedAudioStorageProvider } from './cached-audio-storage.js';

const roots: string[] = [];

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

function root(): string {
  const value = mkdtempSync(join(tmpdir(), 'homespotify-cache-'));
  roots.push(value);
  return value;
}

function config(cacheRoot = root(), maxBytes = 1024 * 1024): AudioCacheConfig {
  return {
    root: cacheRoot,
    maxBytes,
    minFreeBytes: 1,
    tempMaxAgeMs: 1_000,
    fillOnFullGet: true,
    verifyOnHit: 'size',
    evictionTargetRatio: 0.9,
  };
}

function hash(content: Buffer): string {
  return createHash('sha256').update(content).digest('hex');
}

function reference(id: number, content: Buffer): TrackStorageReference {
  return {
    trackId: id,
    relativePath: `ignored-${id}.flac`,
    contentHash: hash(content),
    expectedSizeBytes: content.length,
  };
}

async function collect(stream: Readable): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of stream) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks);
}

class FakeUpstream implements AudioStorageProvider {
  offline = false;
  statCount = 0;
  readCount = 0;

  constructor(private readonly values: Map<number, Buffer>) {}

  async stat(reference: TrackStorageReference): Promise<AudioFileInfo> {
    this.statCount++;
    if (this.offline) throw new AudioStorageError('AGENT_UNAVAILABLE', 'offline');
    const content = this.values.get(reference.trackId);
    if (content === undefined) throw new AudioStorageError('NOT_FOUND', 'absent');
    return {
      sizeBytes: content.length,
      modifiedAt: new Date('2026-07-26T12:00:00Z'),
      contentType: 'audio/flac',
      source: 'remote',
    };
  }

  async createReadStream(
    reference: TrackStorageReference,
    range?: ByteRange,
  ): Promise<Readable> {
    this.readCount++;
    if (this.offline) throw new AudioStorageError('AGENT_UNAVAILABLE', 'offline');
    const content = this.values.get(reference.trackId);
    if (content === undefined) throw new AudioStorageError('NOT_FOUND', 'absent');
    return Readable.from(
      range === undefined ? content : content.subarray(range.start, range.end + 1),
    );
  }

  async healthCheck(): Promise<StorageHealth> {
    return this.offline
      ? { status: 'offline', reason: 'offline' }
      : { status: 'online', source: 'remote', latencyMs: 1 };
  }
}

describe('configuration du cache audio', () => {
  it('n’exige rien en local ou remote', () => {
    expect(loadAudioCacheConfig({}, 'local')).toBeUndefined();
    expect(loadAudioCacheConfig({}, 'remote')).toBeUndefined();
  });

  it('valide cached et refuse racine, limite ou ratio invalides', () => {
    const cacheRoot = root();
    expect(
      loadAudioCacheConfig(
        {
          AUDIO_CACHE_ROOT: cacheRoot,
          AUDIO_CACHE_MAX_BYTES: '1000',
          AUDIO_CACHE_MIN_FREE_BYTES: '1',
          AUDIO_CACHE_EVICTION_TARGET_RATIO: '0.8',
        },
        'cached',
      ),
    ).toMatchObject({ root: cacheRoot, maxBytes: 1000, evictionTargetRatio: 0.8 });
    expect(() => loadAudioCacheConfig({}, 'cached')).toThrow(AudioCacheConfigError);
    expect(() =>
      loadAudioCacheConfig({ AUDIO_CACHE_ROOT: cacheRoot, AUDIO_CACHE_MAX_BYTES: '0' }, 'cached'),
    ).toThrow(/MAX_BYTES/);
    expect(() =>
      loadAudioCacheConfig(
        { AUDIO_CACHE_ROOT: cacheRoot, AUDIO_CACHE_EVICTION_TARGET_RATIO: '1' },
        'cached',
      ),
    ).toThrow(/RATIO/);
  });
});

describe('CachedAudioStorageProvider', () => {
  it('remplit atomiquement puis sert HEAD, GET et Range sans agent', async () => {
    const content = Buffer.from('cache-complet-0123456789');
    const ref = reference(1, content);
    const upstream = new FakeUpstream(new Map([[1, content]]));
    const provider = new CachedAudioStorageProvider(upstream, config());

    expect((await provider.stat(ref)).source).toBe('remote');
    expect(await collect(await provider.createReadStream(ref))).toEqual(content);
    expect(provider.metrics()).toMatchObject({
      entryCount: 1,
      totalBytes: content.length,
      fillCount: 1,
    });

    upstream.offline = true;
    expect(await provider.stat(ref)).toMatchObject({
      source: 'cache',
      sizeBytes: content.length,
      contentType: 'audio/flac',
    });
    expect(await collect(await provider.createReadStream(ref))).toEqual(content);
    expect(
      await collect(await provider.createReadStream(ref, { start: 6, end: 12 })),
    ).toEqual(content.subarray(6, 13));
    expect(provider.metrics().tempFileCount).toBe(0);
    await provider.close();
  });

  it('ne remplit ni HEAD MISS ni Range MISS', async () => {
    const content = Buffer.from('range-only');
    const ref = reference(2, content);
    const upstream = new FakeUpstream(new Map([[2, content]]));
    const provider = new CachedAudioStorageProvider(upstream, config());

    await provider.stat(ref);
    expect(await collect(await provider.createReadStream(ref, { start: 1, end: 3 }))).toEqual(
      content.subarray(1, 4),
    );
    expect(provider.metrics()).toMatchObject({ entryCount: 0, fillCount: 0 });
    await provider.close();
  });

  it('ne sert jamais une entrée dont la taille est corrompue', async () => {
    const content = Buffer.from('integrite');
    const ref = reference(3, content);
    const cacheRoot = root();
    const upstream = new FakeUpstream(new Map([[3, content]]));
    const provider = new CachedAudioStorageProvider(upstream, config(cacheRoot));
    await collect(await provider.createReadStream(ref));
    appendFileSync(
      join(cacheRoot, 'objects', ref.contentHash.slice(0, 2), `${ref.contentHash}.audio`),
      'x',
    );
    upstream.offline = true;
    await expect(provider.stat(ref)).rejects.toMatchObject({ code: 'AGENT_UNAVAILABLE' });
    expect(provider.metrics()).toMatchObject({ entryCount: 0, corruptionCount: 1 });
    await provider.close();
  });

  it('applique single-flight sans lire le fichier partiel', async () => {
    const content = Buffer.alloc(64 * 1024, 7);
    const ref = reference(4, content);
    const upstream = new FakeUpstream(new Map([[4, content]]));
    const provider = new CachedAudioStorageProvider(upstream, config());
    const first = await provider.createReadStream(ref);
    const second = await provider.createReadStream(ref);
    const [one, two] = await Promise.all([collect(first), collect(second)]);
    expect(one).toEqual(content);
    expect(two).toEqual(content);
    expect(upstream.readCount).toBe(2);
    expect(provider.metrics().entryCount).toBe(1);
    await provider.close();
  });

  it('supprime le .part et annule l’amont après abandon', async () => {
    const content = Buffer.alloc(512 * 1024, 3);
    const ref = reference(5, content);
    const upstream = new FakeUpstream(new Map([[5, content]]));
    const cacheRoot = root();
    const provider = new CachedAudioStorageProvider(upstream, config(cacheRoot));
    const stream = await provider.createReadStream(ref);
    stream.once('data', () => stream.destroy());
    await new Promise((resolve) => stream.once('close', resolve));
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(readdirSync(join(cacheRoot, 'tmp'))).toEqual([]);
    expect(provider.metrics().entryCount).toBe(0);
    await provider.close();
  });

  it('bypasse le cache sous pression sans casser la lecture distante', async () => {
    const content = Buffer.from('trop-grand-pour-cache');
    const ref = reference(6, content);
    const upstream = new FakeUpstream(new Map([[6, content]]));
    const provider = new CachedAudioStorageProvider(upstream, config(root(), 4));
    expect(await collect(await provider.createReadStream(ref))).toEqual(content);
    expect(provider.metrics().entryCount).toBe(0);
    await provider.close();
  });

  it('ne promeut jamais un contenu dont le SHA-256 diverge', async () => {
    const content = Buffer.from('hash-reel');
    const ref = {
      ...reference(7, content),
      contentHash: '0'.repeat(64),
    };
    const upstream = new FakeUpstream(new Map([[7, content]]));
    const provider = new CachedAudioStorageProvider(upstream, config());
    expect(await collect(await provider.createReadStream(ref))).toEqual(content);
    expect(provider.metrics()).toMatchObject({ entryCount: 0, fillCount: 0 });
    await provider.close();
  });

  it('évince en LRU sans toucher à une entrée active', async () => {
    const firstContent = Buffer.from('12345678');
    const secondContent = Buffer.from('ABCDEFGH');
    const first = reference(8, firstContent);
    const second = reference(9, secondContent);
    const upstream = new FakeUpstream(
      new Map([
        [8, firstContent],
        [9, secondContent],
      ]),
    );
    const provider = new CachedAudioStorageProvider(upstream, config(root(), 12));
    await collect(await provider.createReadStream(first));
    await collect(await provider.createReadStream(second));
    expect(provider.metrics()).toMatchObject({ entryCount: 1, evictionCount: 1 });
    upstream.offline = true;
    expect((await provider.stat(second)).source).toBe('cache');
    await expect(provider.stat(first)).rejects.toMatchObject({ code: 'AGENT_UNAVAILABLE' });
    await provider.close();
  });

  it('récupère un HIT après redémarrage de l’API', async () => {
    const content = Buffer.from('persistant');
    const ref = reference(10, content);
    const cacheRoot = root();
    const upstream = new FakeUpstream(new Map([[10, content]]));
    const first = new CachedAudioStorageProvider(upstream, config(cacheRoot));
    await collect(await first.createReadStream(ref));
    await first.close();

    const offline = new FakeUpstream(new Map([[10, content]]));
    offline.offline = true;
    const restarted = new CachedAudioStorageProvider(offline, config(cacheRoot));
    expect((await restarted.stat(ref)).source).toBe('cache');
    expect(await collect(await restarted.createReadStream(ref))).toEqual(content);
    await restarted.close();
  });

  it('nettoie les .part anciens et les objets sans index au démarrage', async () => {
    const cacheRoot = root();
    const tempRoot = join(cacheRoot, 'tmp');
    const objectRoot = join(cacheRoot, 'objects', 'aa');
    mkdirSync(tempRoot, { recursive: true });
    mkdirSync(objectRoot, { recursive: true });
    const part = join(tempRoot, `${'b'.repeat(64)}.old.part`);
    const orphan = join(objectRoot, `${'a'.repeat(64)}.audio`);
    writeFileSync(part, 'partial');
    writeFileSync(orphan, 'orphan');
    const old = new Date(Date.now() - 10_000);
    utimesSync(part, old, old);

    const provider = new CachedAudioStorageProvider(
      new FakeUpstream(new Map()),
      config(cacheRoot),
    );
    expect(readdirSync(tempRoot)).toEqual([]);
    expect(readdirSync(objectRoot)).toEqual([]);
    await provider.close();
  });
});
