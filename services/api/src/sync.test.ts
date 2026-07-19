import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import FormData from 'form-data';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { buildApp } from './app.js';
import type { AppConfig } from './config.js';
import { trackEnrichment } from './db/schema.js';
import { makeWav } from './test/wav.js';

let base: string;
let app: FastifyInstance;
let ownerToken: string;
let testConfig: AppConfig;

beforeEach(async () => {
  base = mkdtempSync(join(tmpdir(), 'homespotify-sync-'));
  testConfig = {
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
  app = buildApp(testConfig);
  await app.ready();
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

afterEach(async () => {
  await app.close();
  rmSync(base, { recursive: true, force: true });
});

/** Inject authentifié OWNER (routes bibliothèque désormais protégées). */
function inject(opts: Parameters<FastifyInstance['inject']>[0] & { headers?: Record<string, string> }) {
  return app.inject({
    ...opts,
    headers: { ...(opts.headers ?? {}), authorization: `Bearer ${ownerToken}` },
  });
}

async function upload(title: string, seconds: number) {
  const form = new FormData();
  form.append('provenance', 'rip_cd');
  form.append('file', makeWav({ title, artist: 'Sync Artist', album: 'Sync Album', seconds }), {
    filename: `${title}.wav`,
    contentType: 'audio/wav',
  });
  const res = await inject({ method: 'POST', url: '/api/tracks', payload: form, headers: form.getHeaders() });
  expect(res.statusCode).toBe(201);
  return res.json() as { id: number };
}

function insertMatchedEnrichment(trackId: number, checkedAt: string): void {
  app.dbHandle.db.insert(trackEnrichment).values({
    trackId,
    status: 'matched',
    musicbrainzRecordingId: 'recording-1',
    musicbrainzReleaseId: 'release-1',
    musicbrainzReleaseGroupId: '48140466-cff6-3222-bd55-63c27e43190d',
    musicbrainzArtistId: 'artist-1',
    canonicalTitle: 'Canonical',
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
    checkedAt,
    enrichedAt: checkedAt,
  }).run();
}

describe('GET /api/sync/manifest', () => {
  it('renvoie un manifeste compact complet avec ETag global', async () => {
    const first = await upload('Manifest One', 0.12);
    const second = await upload('Manifest Two', 0.13);
    const metadataTime = '2099-01-02T03:04:05.000Z';
    insertMatchedEnrichment(first.id, metadataTime);

    const res = await inject({ method: "GET", url: "/api/sync/manifest" });

    expect(res.statusCode).toBe(200);
    expect(res.headers.etag).toMatch(/^"[0-9a-f]{64}"$/);
    expect(res.headers['cache-control']).toBe('private, max-age=0, must-revalidate');

    const body = res.json() as {
      tracks: Array<{
        track_id: number;
        enrichment_status: string;
        etag: string;
        lastModified: string;
      }>;
    };
    expect(Object.keys(body).sort()).toEqual(['tracks']);
    expect(body.tracks).toHaveLength(2);
    expect(body.tracks[0]).toMatchObject({
      track_id: first.id,
      enrichment_status: 'matched',
      lastModified: metadataTime,
    });
    expect(body.tracks[0].etag).toMatch(/^[0-9a-f]{64}$/);
    expect(body.tracks[1]).toMatchObject({
      track_id: second.id,
      enrichment_status: 'pending',
    });
    expect(new Date(body.tracks[1].lastModified).getTime()).not.toBeNaN();
  });

  it('répond 304 quand If-None-Match correspond au manifeste courant', async () => {
    await upload('Manifest Cache', 0.14);
    const first = await inject({ method: "GET", url: "/api/sync/manifest" });
    const etag = first.headers.etag as string;

    const cached = await inject({
      method: 'GET',
      url: '/api/sync/manifest',
      headers: { 'if-none-match': etag },
    });

    expect(cached.statusCode).toBe(304);
    expect(cached.headers.etag).toBe(etag);
    expect(cached.body).toBe('');
  });

  it('change d ETag global quand les métadonnées d enrichissement changent', async () => {
    const track = await upload('Manifest Update', 0.15);
    const first = await inject({ method: "GET", url: "/api/sync/manifest" });
    const firstEtag = first.headers.etag;

    insertMatchedEnrichment(track.id, '2099-05-06T07:08:09.000Z');
    const second = await inject({ method: "GET", url: "/api/sync/manifest" });

    expect(second.headers.etag).not.toBe(firstEtag);
    expect(second.json().tracks[0]).toMatchObject({
      track_id: track.id,
      enrichment_status: 'matched',
      lastModified: '2099-05-06T07:08:09.000Z',
    });
  });
});
