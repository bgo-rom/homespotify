import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import FormData from 'form-data';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { buildApp } from './app.js';
import type { AppConfig } from './config.js';
import { trackEnrichment } from './db/schema.js';
import { makeWav } from './test/wav.js';
import { makeFlac } from './test/flac.js';

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
  importRoot: join(base, 'imports'),
  coversDir: join(base, 'covers'),
  maxUploadBytes: 200 * 1024 * 1024,
  authTokenSecret: 'test-secret-0123456789abcdef0123456789abcdef',
  accessTokenTtlSeconds: 900,
  refreshTokenTtlSeconds: 30 * 24 * 60 * 60,
};

let app: FastifyInstance;
let ownerToken: string;

beforeAll(async () => {
  app = buildApp(testConfig);
  await app.ready();
  // Les routes bibliothèque exigent désormais une auth : on bootstrappe le
  // OWNER, et les pistes importées lui sont attribuées automatiquement.
  const bootstrap = await app.inject({
    method: 'POST',
    url: '/api/auth/bootstrap',
    payload: {
      username: 'owner',
      displayName: 'Owner',
      password: 'motdepasse-owner-1',
      passwordConfirmation: 'motdepasse-owner-1',
    },
  });
  ownerToken = bootstrap.json().accessToken;
});

afterAll(async () => {
  await app.close();
  rmSync(base, { recursive: true, force: true });
});

/** Inject authentifié en tant que OWNER (le userId vient du token). */
function inject(opts: Parameters<FastifyInstance['inject']>[0] & { headers?: Record<string, string> }) {
  return app.inject({
    ...opts,
    headers: { ...(opts.headers ?? {}), authorization: `Bearer ${ownerToken}` },
  });
}

async function upload(buf: Buffer, filename = 'test.wav', provenance?: string) {
  const form = new FormData();
  // provenance AVANT le fichier : les champs multipart sont lus séquentiellement
  if (provenance) form.append('provenance', provenance);
  form.append('file', buf, { filename, contentType: 'audio/wav' });
  return inject({ method: 'POST', url: '/api/tracks', payload: form, headers: form.getHeaders() });
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

describe('POST /api/tracks (import FLAC)', () => {
  it('importe un FLAC lossless et détecte le format', async () => {
    const res = await upload(makeFlac({ seconds: 0.3 }), 'Chanson FLAC.flac', 'achat');
    expect(res.statusCode).toBe(201);
    const body = res.json();
    expect(body.path.endsWith('.flac')).toBe(true);
    expect(body.mimeType).toBe('audio/flac');
    expect(body.quality).toMatchObject({
      container: 'FLAC',
      codec: 'FLAC',
      sampleRate: 44100,
      bitDepth: 16,
      status: 'lossless_verifie',
    });
  });

  it('accepte un FLAC Hi-Res 24 bit / 96 kHz', async () => {
    const res = await upload(
      makeFlac({ bitDepth: 24, sampleRate: 96000, seconds: 0.2 }),
      'hires.flac',
      'achat',
    );
    expect(res.statusCode).toBe(201);
    expect(res.json().quality.bitDepth).toBe(24);
    expect(res.json().quality.sampleRate).toBe(96000);
  });

  it('rejette un fichier ni WAV ni FLAC (422)', async () => {
    const res = await upload(Buffer.from('OggS pas supporté'), 'weird.ogg');
    expect(res.statusCode).toBe(422);
  });
});

describe('GET /api/tracks', () => {
  it('liste paginée avec qualité et format', async () => {
    const res = await inject({ method: 'GET', url: '/api/tracks' });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.total).toBeGreaterThanOrEqual(1);
    expect(body.items[0].quality.bitDepth).toBeGreaterThan(0);
    expect(body.items[0].mimeType).toMatch(/^audio\/(wav|flac)$/);
    expect(body.items[0].extension).toMatch(/^\.(wav|flac)$/);
  });

  it('expose etag + lastModified par piste (comparaison de cache mobile)', async () => {
    const res = await inject({ method: 'GET', url: '/api/tracks' });
    const item = res.json().items[0];
    expect(item.etag).toMatch(/^[0-9a-f]{64}$/); // hash SHA-256
    expect(new Date(item.lastModified).getTime()).not.toBeNaN();
  });
});

describe('GET /api/tracks/:id/stream (HTTP Range)', () => {
  let trackId: number;
  let size: number;

  beforeAll(async () => {
    const res = await upload(makeWav({ title: 'Stream Test', seconds: 0.5 }), 's.wav', 'rip_cd');
    const body = res.json();
    trackId = body.id;
    const list = await inject({ method: 'GET', url: '/api/tracks?limit=200' });
    size = list.json().items.find((t: { id: number }) => t.id === trackId).sizeBytes;
  });

  it('sans Range → 200 complet, audio/wav, accept-ranges', async () => {
    const res = await inject({ method: 'GET', url: `/api/tracks/${trackId}/stream` });
    expect(res.statusCode).toBe(200);
    expect(res.headers['content-type']).toBe('audio/wav');
    expect(res.headers['accept-ranges']).toBe('bytes');
    expect(Number(res.headers['content-length'])).toBe(size);
    expect(res.rawPayload.subarray(0, 4).toString('ascii')).toBe('RIFF');
  });

  it('bytes=0-3 → 206 avec les 4 premiers octets exactement', async () => {
    const res = await inject({
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
    const res = await inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/stream`,
      headers: { range: 'bytes=100-' },
    });
    expect(res.statusCode).toBe(206);
    expect(res.headers['content-range']).toBe(`bytes 100-${size - 1}/${size}`);
    expect(res.rawPayload.length).toBe(size - 100);
  });

  it('bytes=-8 → 206 suffixe (8 derniers octets)', async () => {
    const res = await inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/stream`,
      headers: { range: 'bytes=-8' },
    });
    expect(res.statusCode).toBe(206);
    expect(res.headers['content-range']).toBe(`bytes ${size - 8}-${size - 1}/${size}`);
    expect(res.rawPayload.length).toBe(8);
  });

  it('Range hors fichier → 416 avec content-range */size', async () => {
    const res = await inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/stream`,
      headers: { range: 'bytes=999999999-' },
    });
    expect(res.statusCode).toBe(416);
    expect(res.headers['content-range']).toBe(`bytes */${size}`);
  });

  it('Range invalide → 200 complet avec taille exacte', async () => {
    const res = await inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/stream`,
      headers: { range: 'bytes=0-3,8-11' },
    });
    expect(res.statusCode).toBe(200);
    expect(Number(res.headers['content-length'])).toBe(size);
    expect(res.rawPayload.length).toBe(size);
  });

  it('piste inconnue → 404', async () => {
    const res = await inject({ method: 'GET', url: '/api/tracks/424242/stream' });
    expect(res.statusCode).toBe(404);
  });
});

describe('GET /api/tracks/:id/stream (FLAC bit-perfect)', () => {
  it('sert le FLAC tel quel avec Content-Type audio/flac + Range', async () => {
    const up = await upload(makeFlac({ seconds: 0.25 }), 'streamflac.flac', 'achat');
    const id = up.json().id as number;

    const full = await inject({ method: 'GET', url: `/api/tracks/${id}/stream` });
    expect(full.statusCode).toBe(200);
    expect(full.headers['content-type']).toBe('audio/flac');
    expect(full.headers['accept-ranges']).toBe('bytes');
    expect(full.rawPayload.subarray(0, 4).toString('ascii')).toBe('fLaC');

    const partial = await inject({
      method: 'GET',
      url: `/api/tracks/${id}/stream`,
      headers: { range: 'bytes=0-3' },
    });
    expect(partial.statusCode).toBe(206);
    expect(partial.headers['content-type']).toBe('audio/flac');
    expect(partial.headers['content-range']).toMatch(/^bytes 0-3\/\d+$/);
    expect(Number(partial.headers['content-length'])).toBe(4);
    expect(partial.rawPayload.toString('ascii')).toBe('fLaC');
  });
});

describe('GET /api/tracks/:id/download (cache hors ligne)', () => {
  let trackId: number;

  beforeAll(async () => {
    const res = await upload(
      makeWav({ title: 'Café Déjà', artist: 'Renée', seconds: 0.3 }),
      'd.wav',
      'achat',
    );
    trackId = res.json().id;
  });

  it('force le téléchargement complet avec Content-Disposition + ETag + Last-Modified', async () => {
    const res = await inject({ method: 'GET', url: `/api/tracks/${trackId}/download` });
    expect(res.statusCode).toBe(200);
    expect(res.headers['content-type']).toBe('audio/wav');
    const cd = res.headers['content-disposition'] as string;
    expect(cd).toContain('attachment');
    expect(cd).toMatch(/filename="[^"]*\.wav"/); // fallback ASCII
    expect(cd).toMatch(/filename\*=UTF-8''/); // accents préservés (Café Déjà, Renée)
    expect(res.headers['etag']).toBeTruthy();
    expect(res.headers['last-modified']).toBeTruthy();
    expect(res.rawPayload.subarray(0, 4).toString('ascii')).toBe('RIFF');
  });

  it('supporte le Range pour la reprise de téléchargement (206)', async () => {
    const res = await inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/download`,
      headers: { range: 'bytes=0-9' },
    });
    expect(res.statusCode).toBe(206);
    expect(res.headers['content-disposition']).toContain('attachment');
    expect(res.rawPayload.length).toBe(10);
  });

  it('piste inconnue → 404', async () => {
    const res = await inject({ method: 'GET', url: '/api/tracks/999999/download' });
    expect(res.statusCode).toBe(404);
  });
});

describe('GET /api/tracks/:id/cover (pochettes enrichies)', () => {
  it('sert la pochette HD Cover Art Archive avant le fallback embarqué', async () => {
    const releaseGroupId = '48140466-cff6-3222-bd55-63c27e43190d';
    const cover = Buffer.from([0xff, 0xd8, 0xff, 0xdb, 0x00, 0x43]);
    const res = await upload(makeWav({ title: 'Cover HD', seconds: 0.2 }), 'cover.wav', 'rip_cd');
    const trackId = res.json().id as number;

    app.dbHandle.db.insert(trackEnrichment).values({
      trackId,
      status: 'matched',
      musicbrainzRecordingId: 'recording-1',
      musicbrainzReleaseId: 'release-1',
      musicbrainzReleaseGroupId: releaseGroupId,
      musicbrainzArtistId: 'artist-1',
      canonicalTitle: 'Cover HD',
      canonicalArtist: 'Artist',
      canonicalAlbum: 'Album',
      albumArtist: 'Artist',
      releaseDate: '2020-01-01',
      trackNumber: 1,
      discNumber: 1,
      genre: null,
      matchScore: 99,
      candidatesJson: null,
      errorMessage: null,
      checkedAt: new Date().toISOString(),
      enrichedAt: new Date().toISOString(),
    }).run();
    writeFileSync(join(testConfig.coversDir, `${releaseGroupId}.jpg`), cover);

    const coverRes = await inject({ method: 'GET', url: `/api/tracks/${trackId}/cover` });
    expect(coverRes.statusCode).toBe(200);
    expect(coverRes.headers['content-type']).toBe('image/jpeg');
    expect(coverRes.rawPayload).toEqual(cover);
  });
});
