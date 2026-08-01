import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import { once } from 'node:events';
import { Readable } from 'node:stream';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  EMPTY_BODY_SHA256,
  HmacVerifier,
  NonceCache,
} from '../../../../storage-agent/src/hmac-auth.js';
import { AudioStorageError, type TrackStorageReference } from '../audio-storage.js';
import type { RemoteStorageConfig } from './remote-config.js';
import { RemoteWindowsStorageProvider } from './remote-windows-storage.js';

const SECRET = '0123456789abcdef0123456789abcdef';
const CONTENT = Buffer.from('0123456789abcdef');
const MODIFIED = new Date('2026-07-26T12:00:00.000Z');

interface CapturedRequest {
  method: string;
  url: string;
  range?: string;
  requestId?: string;
  remotePort?: number;
}

let server: ReturnType<typeof createServer>;
let provider: RemoteWindowsStorageProvider;
let captured: CapturedRequest[];
let logger: {
  info: ReturnType<typeof vi.fn>;
  warn: ReturnType<typeof vi.fn>;
  error: ReturnType<typeof vi.fn>;
};
let responseClosedEarly: boolean;

function reference(trackId = 1): TrackStorageReference {
  return {
    trackId,
    relativePath: 'ne/doit/jamais/partir.flac',
    contentHash: 'a'.repeat(64),
    expectedSizeBytes: CONTENT.length,
  };
}

function headers(response: ServerResponse, length: number): void {
  response.setHeader('accept-ranges', 'bytes');
  response.setHeader('content-type', 'audio/flac');
  response.setHeader('content-length', String(length));
  response.setHeader('last-modified', MODIFIED.toUTCString());
}

function error(response: ServerResponse, status: number, code: string): void {
  response.writeHead(status, {
    'x-hs-error-code': code,
    'content-type': 'application/json',
  });
  response.end(JSON.stringify({ error: code }));
}

function verifyHmac(request: IncomingMessage): boolean {
  const verifier = new HmacVerifier({
    secret: SECRET,
    maxClockSkewSeconds: 60,
    nonceCache: new NonceCache(120_000),
  });
  return verifier.verify({
    method: request.method ?? '',
    pathWithQuery: request.url ?? '',
    headers: request.headers,
    bodySha256: EMPTY_BODY_SHA256,
  }).ok;
}

async function handler(request: IncomingMessage, response: ServerResponse): Promise<void> {
  captured.push({
    method: request.method ?? '',
    url: request.url ?? '',
    ...(typeof request.headers.range === 'string'
      ? { range: request.headers.range }
      : {}),
    ...(typeof request.headers['x-request-id'] === 'string'
      ? { requestId: request.headers['x-request-id'] }
      : {}),
    ...(request.socket.remotePort === undefined
      ? {}
      : { remotePort: request.socket.remotePort }),
  });
  if (!verifyHmac(request)) {
    error(response, 401, 'AUTH_INVALID');
    return;
  }
  if (request.url === '/internal/storage/health') {
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ status: 'healthy', indexEntryCount: 158 }));
    return;
  }
  const id = Number(request.url?.split('/').pop());
  const errors: Record<number, [number, string]> = {
    2: [404, 'TRACK_NOT_INDEXED'],
    3: [404, 'FILE_NOT_FOUND'],
    4: [503, 'INDEX_NOT_LOADED'],
    5: [503, 'MUSIC_ROOT_UNAVAILABLE'],
    6: [503, 'STREAM_LIMIT_REACHED'],
  };
  const failure = errors[id];
  if (failure !== undefined) {
    error(response, failure[0], failure[1]);
    return;
  }
  if (id === 7) {
    response.writeHead(200, {
      'accept-ranges': 'bytes',
      'content-type': 'audio/flac',
      'last-modified': MODIFIED.toUTCString(),
    });
    response.end();
    return;
  }
  if (request.method === 'HEAD') {
    headers(response, CONTENT.length);
    response.end();
    return;
  }

  const rawRange = request.headers.range;
  const match =
    typeof rawRange === 'string'
      ? /^bytes=(\d+)-(\d+)$/.exec(rawRange)
      : null;
  const start = match === null ? 0 : Number(match[1]);
  const end = match === null ? CONTENT.length - 1 : Number(match[2]);
  const body = CONTENT.subarray(start, end + 1);
  headers(response, id === 8 ? body.length + 2 : body.length);
  if (match !== null) {
    response.statusCode = 206;
    response.setHeader('content-range', `bytes ${start}-${end}/${CONTENT.length}`);
  }
  response.once('close', () => {
    if (!response.writableFinished) responseClosedEarly = true;
  });
  if (id === 9) {
    response.write(body.subarray(0, 1));
    return;
  }
  if (id === 8) {
    response.write(body);
    setImmediate(() => response.socket?.destroy());
    return;
  }
  response.end(body);
}

beforeEach(async () => {
  captured = [];
  responseClosedEarly = false;
  logger = { info: vi.fn(), warn: vi.fn(), error: vi.fn() };
  server = createServer((request, response) => {
    void handler(request, response);
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const address = server.address();
  if (address === null || typeof address === 'string') throw new Error('port absent');
  const config: RemoteStorageConfig = {
    baseUrl: `http://127.0.0.1:${address.port}`,
    sharedSecret: SECRET,
    connectTimeoutMs: 500,
    headersTimeoutMs: 500,
    bodyIdleTimeoutMs: 100,
    maxConnections: 8,
  };
  provider = new RemoteWindowsStorageProvider(config, logger);
});

afterEach(async () => {
  provider.close();
  server.close();
  await once(server, 'close');
});

describe('RemoteWindowsStorageProvider.stat', () => {
  it('utilise HEAD par trackId, valide les en-têtes et ne transmet aucun chemin', async () => {
    await expect(provider.stat(reference(), { requestId: 'public-42' })).resolves.toEqual({
      sizeBytes: CONTENT.length,
      modifiedAt: MODIFIED,
      contentType: 'audio/flac',
      source: 'remote',
    });
    expect(captured[0]).toMatchObject({
      method: 'HEAD',
      url: '/internal/storage/tracks/1',
      requestId: 'public-42',
    });
    expect(JSON.stringify(captured)).not.toContain('ne/doit');
  });

  it('journalise une divergence SQLite/agent sans modifier le résultat', async () => {
    await provider.stat({ ...reference(), expectedSizeBytes: 999 });
    expect(logger.warn).toHaveBeenCalledWith(
      expect.objectContaining({
        event: 'REMOTE_STORAGE_SIZE_MISMATCH',
        expectedSizeBytes: 999,
        observedSizeBytes: CONTENT.length,
      }),
      'REMOTE_STORAGE_SIZE_MISMATCH',
    );
  });

  it.each([
    [2, 'INDEX_STALE'],
    [3, 'NOT_FOUND'],
    [4, 'INDEX_NOT_LOADED'],
    [5, 'MUSIC_ROOT_UNAVAILABLE'],
  ])('mappe l’erreur agent de la piste %s vers %s', async (id, code) => {
    await expect(provider.stat(reference(id))).rejects.toMatchObject({ code });
  });

  it('refuse un Content-Length absent', async () => {
    await expect(provider.stat(reference(7))).rejects.toMatchObject({
      code: 'REMOTE_INVALID_RESPONSE',
    });
  });

  it('réutilise une connexion keep-alive', async () => {
    await provider.stat(reference());
    await provider.stat(reference());
    expect(captured[0]?.remotePort).toBe(captured[1]?.remotePort);
  });
});

describe('RemoteWindowsStorageProvider.createReadStream', () => {
  it('diffuse le fichier complet sans Buffer global ni fichier temporaire', async () => {
    const stream = await provider.createReadStream(reference());
    expect(stream).toBeInstanceOf(Readable);
    const chunks: Buffer[] = [];
    for await (const chunk of stream) chunks.push(Buffer.from(chunk));
    expect(Buffer.concat(chunks)).toEqual(CONTENT);
    expect(captured[0]).toMatchObject({
      method: 'GET',
      url: '/internal/storage/tracks/1',
    });
    expect(captured[0]?.range).toBeUndefined();
  });

  it('transmet exactement la plage inclusive et valide Content-Range', async () => {
    const stream = await provider.createReadStream(reference(), { start: 2, end: 5 });
    const chunks: Buffer[] = [];
    for await (const chunk of stream) chunks.push(Buffer.from(chunk));
    expect(Buffer.concat(chunks)).toEqual(CONTENT.subarray(2, 6));
    expect(captured[0]?.range).toBe('bytes=2-5');
  });

  it('mappe la saturation en STORAGE_BUSY', async () => {
    await expect(provider.createReadStream(reference(6))).rejects.toMatchObject({
      code: 'STORAGE_BUSY',
    });
  });

  it('détecte un flux tronqué', async () => {
    const stream = await provider.createReadStream(reference(8));
    await expect(async () => {
      for await (const _chunk of stream) {
        // consommation progressive
      }
    }).rejects.toMatchObject({ code: 'REMOTE_STREAM_INTERRUPTED' });
  });

  it('annule la réponse distante quand le consommateur abandonne', async () => {
    const stream = await provider.createReadStream(reference(9));
    stream.destroy();
    await new Promise((resolve) => setTimeout(resolve, 25));
    expect(responseClosedEarly).toBe(true);
  });

  it('déclenche BODY_TIMEOUT si le corps reste inactif', async () => {
    const stream = await provider.createReadStream(reference(9));
    await expect(async () => {
      for await (const _chunk of stream) {
        // le serveur laisse la réponse ouverte après le premier octet
      }
    }).rejects.toMatchObject({ code: 'BODY_TIMEOUT' });
  });
});

it('healthCheck traduit une santé distante sans exposer sa réponse complète', async () => {
  await expect(provider.healthCheck()).resolves.toMatchObject({
    status: 'online',
    source: 'remote',
  });
});

it('un mauvais secret devient une erreur interne, jamais une auth utilisateur', async () => {
  const address = server.address();
  if (address === null || typeof address === 'string') throw new Error('port absent');
  const bad = new RemoteWindowsStorageProvider({
    baseUrl: `http://127.0.0.1:${address.port}`,
    sharedSecret: 'x'.repeat(32),
    connectTimeoutMs: 500,
    headersTimeoutMs: 500,
    bodyIdleTimeoutMs: 100,
    maxConnections: 1,
  });
  await expect(bad.stat(reference())).rejects.toMatchObject({
    code: 'REMOTE_AUTH_FAILED',
  });
  bad.close();
});

it('une connexion refusée devient AGENT_UNAVAILABLE et jamais NOT_FOUND', async () => {
  const unavailable = new RemoteWindowsStorageProvider({
    baseUrl: 'http://127.0.0.1:1',
    sharedSecret: SECRET,
    connectTimeoutMs: 100,
    headersTimeoutMs: 100,
    bodyIdleTimeoutMs: 100,
    maxConnections: 1,
  });
  await expect(unavailable.stat(reference())).rejects.toMatchObject({
    code: 'AGENT_UNAVAILABLE',
  });
  unavailable.close();
});
