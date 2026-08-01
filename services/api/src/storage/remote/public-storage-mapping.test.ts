import { Readable } from 'node:stream';
import Fastify from 'fastify';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { serveTrackFile } from '../../routes/tracks.js';
import {
  AudioStorageError,
  type AudioStorageErrorCode,
  type AudioStorageProvider,
  type ByteRange,
  type TrackStorageReference,
} from '../audio-storage.js';

const CONTENT = Buffer.from('0123456789abcdef');
const REFERENCE: TrackStorageReference = {
  trackId: 42,
  relativePath: 'jamais/transmis.flac',
  contentHash: 'b'.repeat(64),
};

let app: ReturnType<typeof Fastify> | undefined;

async function launch(provider: AudioStorageProvider): Promise<ReturnType<typeof Fastify>> {
  const instance = Fastify({ logger: false });
  instance.get('/stream', async (request, reply) =>
    serveTrackFile(request, reply, provider, REFERENCE, 'audio/flac'),
  );
  await instance.ready();
  app = instance;
  return instance;
}

afterEach(async () => {
  await app?.close();
  app = undefined;
});

function failingProvider(code: AudioStorageErrorCode): AudioStorageProvider {
  return {
    async stat() {
      throw new AudioStorageError(code, 'détail interne à masquer');
    },
    async createReadStream() {
      throw new Error('ne doit pas être appelé');
    },
    async healthCheck() {
      return { status: 'offline', reason: 'test' };
    },
  };
}

describe('mapping HTTP public des erreurs de stockage', () => {
  it.each([
    ['NOT_FOUND', 404, 'not_found'],
    ['INDEX_STALE', 503, 'service_unavailable'],
    ['AGENT_UNAVAILABLE', 503, 'service_unavailable'],
    ['CONNECT_TIMEOUT', 503, 'service_unavailable'],
    ['HEADERS_TIMEOUT', 503, 'service_unavailable'],
    ['BODY_TIMEOUT', 503, 'service_unavailable'],
    ['INDEX_NOT_LOADED', 503, 'service_unavailable'],
    ['MUSIC_ROOT_UNAVAILABLE', 503, 'service_unavailable'],
    ['STORAGE_BUSY', 503, 'service_unavailable'],
    ['REMOTE_AUTH_FAILED', 502, 'bad_gateway'],
    ['REMOTE_INVALID_RESPONSE', 502, 'bad_gateway'],
    ['REMOTE_STREAM_INTERRUPTED', 502, 'bad_gateway'],
  ] satisfies Array<[AudioStorageErrorCode, number, string]>)(
    '%s devient %i sans détail interne',
    async (code, status, publicError) => {
      const instance = await launch(failingProvider(code));
      const response = await instance.inject({ method: 'GET', url: '/stream' });
      expect(response.statusCode).toBe(status);
      expect(response.json()).toMatchObject({ error: publicError });
      expect(response.body).not.toContain('détail interne');
      if (code === 'REMOTE_AUTH_FAILED') expect(response.statusCode).not.toBe(401);
      if (code === 'STORAGE_BUSY') expect(response.headers['retry-after']).toBe('1');
    },
  );
});

it('HEAD public utilise seulement stat et conserve les en-têtes sans corps', async () => {
  const createReadStream = vi.fn();
  const provider: AudioStorageProvider = {
    async stat() {
      return {
        sizeBytes: CONTENT.length,
        modifiedAt: new Date('2026-07-26T12:00:00Z'),
        source: 'remote',
      };
    },
    createReadStream,
    async healthCheck() {
      return { status: 'online', source: 'remote', latencyMs: 1 };
    },
  };
  const instance = await launch(provider);
  const response = await instance.inject({
    method: 'HEAD',
    url: '/stream',
    headers: { 'x-request-id': 'head-public-1' },
  });
  expect(response.statusCode).toBe(200);
  expect(response.headers['content-length']).toBe(String(CONTENT.length));
  expect(response.headers['accept-ranges']).toBe('bytes');
  expect(response.headers.etag).toBe(`"${REFERENCE.contentHash}"`);
  expect(response.headers['last-modified']).toBeTruthy();
  expect(response.headers['x-request-id']).toBe('head-public-1');
  expect(response.body).toBe('');
  expect(createReadStream).not.toHaveBeenCalled();
});

it.each([
  ['bytes=2-5', { start: 2, end: 5 }, 'bytes 2-5/16', '2345'],
  ['bytes=12-', { start: 12, end: 15 }, 'bytes 12-15/16', 'cdef'],
  ['bytes=-3', { start: 13, end: 15 }, 'bytes 13-15/16', 'def'],
] satisfies Array<[string, ByteRange, string, string]>)(
  'transmet la plage publique %s sans changer ses bornes',
  async (rawRange, expectedRange, expectedHeader, expectedBody) => {
    const seen: Array<ByteRange | undefined> = [];
    const provider: AudioStorageProvider = {
      async stat() {
        return {
          sizeBytes: CONTENT.length,
          modifiedAt: new Date('2026-07-26T12:00:00Z'),
          source: 'remote',
        };
      },
      async createReadStream(_reference, range) {
        seen.push(range);
        if (range === undefined) return Readable.from(CONTENT);
        return Readable.from(CONTENT.subarray(range.start, range.end + 1));
      },
      async healthCheck() {
        return { status: 'online', source: 'remote', latencyMs: 1 };
      },
    };
    const instance = await launch(provider);
    const response = await instance.inject({
      method: 'GET',
      url: '/stream',
      headers: { range: rawRange },
    });
    expect(response.statusCode).toBe(206);
    expect(response.headers['content-range']).toBe(expectedHeader);
    expect(response.headers['content-length']).toBe(String(expectedBody.length));
    expect(response.body).toBe(expectedBody);
    expect(seen).toEqual([expectedRange]);
  },
);

it('une plage publique invalide reste 416 sans ouvrir de flux', async () => {
  const createReadStream = vi.fn();
  const provider: AudioStorageProvider = {
    async stat() {
      return {
        sizeBytes: CONTENT.length,
        modifiedAt: new Date('2026-07-26T12:00:00Z'),
        source: 'remote',
      };
    },
    createReadStream,
    async healthCheck() {
      return { status: 'online', source: 'remote', latencyMs: 1 };
    },
  };
  const instance = await launch(provider);
  const response = await instance.inject({
    method: 'GET',
    url: '/stream',
    headers: { range: 'bytes=99-' },
  });
  expect(response.statusCode).toBe(416);
  expect(response.headers['content-range']).toBe('bytes */16');
  expect(createReadStream).not.toHaveBeenCalled();
});
