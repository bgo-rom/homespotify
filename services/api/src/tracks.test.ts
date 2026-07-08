import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import FormData from 'form-data';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { buildApp } from './app.js';
import type { AppConfig } from './config.js';

// --- Fixture : WAV PCM synthétique valide, avec tags RIFF INFO optionnels ---
function riffChunk(id: string, body: Buffer): Buffer {
  const padded = body.length % 2 ? Buffer.concat([body, Buffer.alloc(1)]) : body;
  const header = Buffer.alloc(8);
  header.write(id, 0, 4, 'ascii');
  header.writeUInt32LE(body.length, 4);
  return Buffer.concat([header, padded]);
}

function makeWav(opts: {
  sampleRate?: number;
  bitDepth?: number;
  seconds?: number;
  title?: string;
  artist?: string;
} = {}): Buffer {
  const { sampleRate = 44100, bitDepth = 16, seconds = 0.05, title, artist } = opts;
  const bytesPerSample = bitDepth / 8;
  const data = Buffer.alloc(Math.floor(sampleRate * seconds) * bytesPerSample); // mono, silence
  const fmt = Buffer.alloc(16);
  fmt.writeUInt16LE(1, 0); // PCM
  fmt.writeUInt16LE(1, 2); // mono
  fmt.writeUInt32LE(sampleRate, 4);
  fmt.writeUInt32LE(sampleRate * bytesPerSample, 8);
  fmt.writeUInt16LE(bytesPerSample, 12);
  fmt.writeUInt16LE(bitDepth, 14);
  const chunks = [Buffer.from('WAVE'), riffChunk('fmt ', fmt), riffChunk('data', data)];
  if (title !== undefined || artist !== undefined) {
    const info: Buffer[] = [Buffer.from('INFO')];
    if (title !== undefined) info.push(riffChunk('INAM', Buffer.from(`${title}\0`, 'latin1')));
    if (artist !== undefined) info.push(riffChunk('IART', Buffer.from(`${artist}\0`, 'latin1')));
    chunks.push(riffChunk('LIST', Buffer.concat(info)));
  }
  const body = Buffer.concat(chunks);
  const riff = Buffer.alloc(8);
  riff.write('RIFF', 0, 4, 'ascii');
  riff.writeUInt32LE(body.length, 4);
  return Buffer.concat([riff, body]);
}

// --- App de test : DB mémoire + répertoires jetables ---
const base = mkdtempSync(join(tmpdir(), 'homespotify-test-'));
const testConfig: AppConfig = {
  nodeEnv: 'test',
  host: '127.0.0.1',
  port: 0,
  dbPath: ':memory:',
  logLevel: 'error',
  musicDir: join(base, 'music'),
  incomingDir: join(base, 'imports'),
  coversDir: join(base, 'covers'),
  maxUploadBytes: 200 * 1024 * 1024,
};

let app: FastifyInstance;

beforeAll(async () => {
  app = buildApp(testConfig);
  await app.ready();
});

afterAll(async () => {
  await app.close();
  rmSync(base, { recursive: true, force: true });
});

async function upload(buf: Buffer, filename = 'test.wav', provenance?: string) {
  const form = new FormData();
  // provenance AVANT le fichier : les champs multipart sont lus séquentiellement
  if (provenance) form.append('provenance', provenance);
  form.append('file', buf, { filename, contentType: 'audio/wav' });
  return app.inject({ method: 'POST', url: '/api/tracks', payload: form, headers: form.getHeaders() });
}

describe('POST /api/tracks (import WAV)', () => {
  it('importe un WAV 44.1kHz taggé et mesure sa qualité', async () => {
    const res = await upload(makeWav({ title: 'Ma Chanson', artist: 'Mon Artiste' }), 'x.wav', 'rip_cd');
    expect(res.statusCode).toBe(201);
    const body = res.json();
    expect(body.title).toBe('Ma Chanson');
    expect(body.artist).toBe('Mon Artiste');
    expect(body.quality).toMatchObject({
      sampleRate: 44100,
      bitDepth: 16,
      status: 'lossless_verifie',
      provenance: 'rip_cd',
    });
    expect(body.path.endsWith('.wav')).toBe(true);
  });

  it('rejette le doublon exact (409)', async () => {
    const wav = makeWav({ title: 'Doublon', seconds: 0.07 });
    expect((await upload(wav)).statusCode).toBe(201);
    const res = await upload(wav);
    expect(res.statusCode).toBe(409);
  });

  it('rejette un fichier non-WAV (422)', async () => {
    const res = await upload(Buffer.from('ID3\x03pas un wav du tout'), 'fake.wav');
    expect(res.statusCode).toBe(422);
  });

  it('rejette un WAV hors specs 22.05kHz (422)', async () => {
    const res = await upload(makeWav({ sampleRate: 22050 }));
    expect(res.statusCode).toBe(422);
    expect(res.json().message).toMatch(/22050/);
  });

  it('provenance sans preuve → statut inconnue, jamais lossless', async () => {
    const res = await upload(makeWav({ title: 'Origine douteuse', seconds: 0.06 }));
    expect(res.statusCode).toBe(201);
    expect(res.json().quality.status).toBe('inconnue');
  });

  it('provenance upscale_ia → statut lossy malgré le conteneur PCM', async () => {
    const res = await upload(makeWav({ title: 'Upscale IA', seconds: 0.08 }), 'u.wav', 'upscale_ia');
    expect(res.statusCode).toBe(201);
    expect(res.json().quality.status).toBe('lossy');
  });
});

describe('GET /api/tracks', () => {
  it('liste paginée avec qualité', async () => {
    const res = await app.inject({ method: 'GET', url: '/api/tracks' });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.total).toBeGreaterThanOrEqual(1);
    expect(body.items[0].quality.bitDepth).toBe(16);
  });
});

describe('GET /api/tracks/:id/stream (HTTP Range)', () => {
  let trackId: number;
  let size: number;

  beforeAll(async () => {
    const res = await upload(makeWav({ title: 'Stream Test', seconds: 0.5 }), 's.wav', 'rip_cd');
    const body = res.json();
    trackId = body.id;
    const list = await app.inject({ method: 'GET', url: '/api/tracks?limit=200' });
    size = list.json().items.find((t: { id: number }) => t.id === trackId).sizeBytes;
  });

  it('sans Range → 200 complet, audio/wav, accept-ranges', async () => {
    const res = await app.inject({ method: 'GET', url: `/api/tracks/${trackId}/stream` });
    expect(res.statusCode).toBe(200);
    expect(res.headers['content-type']).toBe('audio/wav');
    expect(res.headers['accept-ranges']).toBe('bytes');
    expect(Number(res.headers['content-length'])).toBe(size);
    expect(res.rawPayload.subarray(0, 4).toString('ascii')).toBe('RIFF');
  });

  it('bytes=0-3 → 206 avec les 4 premiers octets exactement', async () => {
    const res = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/stream`,
      headers: { range: 'bytes=0-3' },
    });
    expect(res.statusCode).toBe(206);
    expect(res.headers['content-range']).toBe(`bytes 0-3/${size}`);
    expect(Number(res.headers['content-length'])).toBe(4);
    expect(res.rawPayload.toString('ascii')).toBe('RIFF');
  });

  it('bytes=100- → 206 jusqu à la fin (reprise de lecture)', async () => {
    const res = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/stream`,
      headers: { range: 'bytes=100-' },
    });
    expect(res.statusCode).toBe(206);
    expect(res.headers['content-range']).toBe(`bytes 100-${size - 1}/${size}`);
    expect(res.rawPayload.length).toBe(size - 100);
  });

  it('bytes=-8 → 206 suffixe (8 derniers octets)', async () => {
    const res = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/stream`,
      headers: { range: 'bytes=-8' },
    });
    expect(res.statusCode).toBe(206);
    expect(res.headers['content-range']).toBe(`bytes ${size - 8}-${size - 1}/${size}`);
    expect(res.rawPayload.length).toBe(8);
  });

  it('Range hors fichier → 416 avec content-range */size', async () => {
    const res = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/stream`,
      headers: { range: 'bytes=999999999-' },
    });
    expect(res.statusCode).toBe(416);
    expect(res.headers['content-range']).toBe(`bytes */${size}`);
  });

  it('piste inconnue → 404', async () => {
    const res = await app.inject({ method: 'GET', url: '/api/tracks/424242/stream' });
    expect(res.statusCode).toBe(404);
  });
});
