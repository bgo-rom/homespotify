import { mkdtempSync, rmSync, readdirSync } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { eq } from 'drizzle-orm';
import { buildApp } from '../app.js';
import type { AppConfig } from '../config.js';
import { trackOfflineVariants, tracks, userTracks } from '../db/schema.js';
import {
  estimateOpusSizeBytes,
  type OpusEncoderRunner,
  type OpusProbeResult,
} from '../audio/offline-variant-service.js';

let base: string;
let app: FastifyInstance;
let owner: { id: number; token: string };
let runner: FakeOpusEncoderRunner;

type FakeMode =
  | 'ok'
  | 'encode_fail'
  | 'probe_bad_codec'
  | 'probe_bad_duration'
  | 'probe_missing_duration'
  | 'probe_missing_bitrate'
  | 'probe_bad_container';

/** Aucun ffmpeg réel : écrit un contenu déterministe et répond une sonde contrôlée. */
class FakeOpusEncoderRunner implements OpusEncoderRunner {
  mode: FakeMode = 'ok';
  encodeCalls: Array<{ source: string; target: string; kbps: number }> = [];

  async encoderVersion(): Promise<string> {
    return 'test-encoder-1';
  }

  async encode(source: string, target: string, kbps: number, signal?: AbortSignal): Promise<void> {
    if (signal?.aborted) throw new Error('encodage annulé');
    this.encodeCalls.push({ source, target, kbps });
    if (this.mode === 'encode_fail') throw new Error('ffmpeg simulé : échec');
    // Contenu déterministe par débit : le SHA-256 et la taille sont stables.
    await writeFile(target, Buffer.alloc(1024 * (kbps / 128), kbps % 256));
  }

  async probe(_file: string): Promise<OpusProbeResult> {
    if (this.mode === 'probe_bad_codec') {
      return { formatName: 'ogg', codecName: 'vorbis', durationSeconds: 120, bitrateKbps: 128 };
    }
    if (this.mode === 'probe_bad_container') {
      return { formatName: 'matroska', codecName: 'opus', durationSeconds: 120, bitrateKbps: 128 };
    }
    if (this.mode === 'probe_bad_duration') {
      return { formatName: 'ogg', codecName: 'opus', durationSeconds: 500, bitrateKbps: 128 };
    }
    if (this.mode === 'probe_missing_duration') {
      return { formatName: 'ogg', codecName: 'opus', durationSeconds: null, bitrateKbps: 128 };
    }
    if (this.mode === 'probe_missing_bitrate') {
      return { formatName: 'ogg', codecName: 'opus', durationSeconds: 120, bitrateKbps: null };
    }
    return { formatName: 'ogg', codecName: 'opus', durationSeconds: 120, bitrateKbps: 131 };
  }
}

function config(): AppConfig {
  return {
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
    offline: { derivedCacheDir: join(base, 'derived'), encodeConcurrency: 1 },
  };
}

const auth = (token: string) => ({ authorization: `Bearer ${token}` });

async function createUser(username: string): Promise<{ id: number; token: string }> {
  const created = await app.inject({
    method: 'POST',
    url: '/api/admin/users',
    headers: auth(owner.token),
    payload: { username, displayName: username, temporaryPassword: 'motdepasse-temp-1', role: 'USER' },
  });
  const id = created.json().user.id as number;
  const login = await app.inject({
    method: 'POST',
    url: '/api/auth/login',
    payload: { username, password: 'motdepasse-temp-1' },
  });
  const changed = await app.inject({
    method: 'POST',
    url: '/api/auth/change-password',
    headers: auth(login.json().accessToken),
    payload: {
      currentPassword: 'motdepasse-temp-1',
      newPassword: 'motdepasse-user-2',
      newPasswordConfirmation: 'motdepasse-user-2',
    },
  });
  return { id, token: changed.json().accessToken };
}

function seedTrack(userId: number, title = 'Piste', durationSeconds: number | null = 120): number {
  const now = new Date().toISOString();
  const result = app.dbHandle.db
    .insert(tracks)
    .values({
      hash: `hash-${userId}-${title}-${Math.random()}`,
      path: `${title}.flac`,
      sizeBytes: 42_000_000,
      durationSeconds,
      title,
      artist: 'Artiste',
      album: 'Album',
      createdAt: now,
    })
    .run();
  const trackId = Number(result.lastInsertRowid);
  app.dbHandle.db
    .insert(userTracks)
    .values({ userId, trackId, addedAt: now, source: 'EXISTING', isVisible: true })
    .run();
  return trackId;
}

async function drain(): Promise<void> {
  await app.offlineVariants.drain();
}

beforeEach(async () => {
  base = mkdtempSync(join(tmpdir(), 'homespotify-offline-'));
  runner = new FakeOpusEncoderRunner();
  app = buildApp(config(), { importWatcher: false, opusEncoderRunner: runner });
  await app.ready();
  const response = await app.inject({
    method: 'POST',
    url: '/api/auth/bootstrap',
    payload: {
      username: 'owner',
      displayName: 'Owner',
      password: 'motdepasse-owner-1',
      passwordConfirmation: 'motdepasse-owner-1',
    },
  });
  owner = { id: response.json().user.id, token: response.json().accessToken };
});

afterEach(async () => {
  await drain();
  await app.close();
  rmSync(base, { recursive: true, force: true });
});

describe('routes hors ligne — auth et isolation', () => {
  it('401 sans Bearer sur les quatre routes', async () => {
    const trackId = seedTrack(owner.id);
    for (const [method, url] of [
      ['GET', `/api/tracks/${trackId}/offline-options`],
      ['POST', `/api/tracks/${trackId}/offline-variants/opus_128`],
      ['GET', `/api/tracks/${trackId}/offline-variants/opus_128`],
      ['GET', `/api/tracks/${trackId}/offline-variants/opus_128/file`],
    ] as const) {
      const response = await app.inject({ method, url });
      expect(response.statusCode, `${method} ${url}`).toBe(401);
    }
  });

  it('même politique que stream : piste masquée (tombstone) → 404 pour tous', async () => {
    const trackId = seedTrack(owner.id);
    const bob = await createUser('bob');
    // Suppression logique : la piste n'est plus visible dans aucune bibliothèque
    // ni au catalogue — l'accès hors ligne doit disparaître aussi.
    app.dbHandle.db
      .update(userTracks)
      .set({ isVisible: false })
      .where(eq(userTracks.trackId, trackId))
      .run();
    for (const account of [owner, bob]) {
      for (const [method, url] of [
        ['GET', `/api/tracks/${trackId}/offline-options`],
        ['POST', `/api/tracks/${trackId}/offline-variants/opus_128`],
        ['GET', `/api/tracks/${trackId}/offline-variants/opus_128`],
        ['GET', `/api/tracks/${trackId}/offline-variants/opus_128/file`],
      ] as const) {
        const response = await app.inject({ method, url, headers: auth(account.token) });
        expect(response.statusCode, `${method} ${url}`).toBe(404);
      }
    }
    expect(runner.encodeCalls).toHaveLength(0);
  });

  it("une piste publiée est téléchargeable par tout compte authentifié (mutualisation), l'autorisation est revérifiée", async () => {
    const trackId = seedTrack(owner.id);
    const bob = await createUser('bob2');
    const options = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/offline-options`,
      headers: auth(bob.token),
    });
    expect(options.statusCode).toBe(200); // même politique que /stream et /download
  });

  it('profil inconnu ou chemin malveillant → 400 sans toucher au disque', async () => {
    const trackId = seedTrack(owner.id);
    for (const profile of ['flac_999', '..%2F..%2Fetc%2Fpasswd', 'opus_128.part', 'ORIGINAL']) {
      const response = await app.inject({
        method: 'POST',
        url: `/api/tracks/${trackId}/offline-variants/${profile}`,
        headers: auth(owner.token),
      });
      expect(response.statusCode, profile).toBe(400);
    }
    expect(runner.encodeCalls).toHaveLength(0);
  });
});

describe('offline-options — trois profils, tailles estimées/exactes', () => {
  it('expose opus_128, opus_256 recommandé lossy et original exact', async () => {
    const trackId = seedTrack(owner.id);
    const response = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/offline-options`,
      headers: auth(owner.token),
    });
    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.options).toHaveLength(3);
    const [opus128, opus256, original] = body.options;

    // Estimation DÉTERMINISTE : durée × débit × 125 (ni aléa, ni mesure).
    expect(opus128.profile).toBe('opus_128');
    expect(opus128.sizeBytes).toBe(estimateOpusSizeBytes(120, 128));
    expect(opus128.sizeBytes).toBe(1_920_000);
    expect(opus128.sizeKind).toBe('estimated');
    expect(opus128.lossy).toBe(true);
    expect(opus128.recommended).toBe(false);

    expect(opus256.profile).toBe('opus_256');
    expect(opus256.sizeBytes).toBe(3_840_000);
    expect(opus256.sizeKind).toBe('estimated');
    expect(opus256.lossy).toBe(true);
    expect(opus256.recommended).toBe(true);

    expect(original.profile).toBe('original');
    expect(original.sizeBytes).toBe(42_000_000);
    expect(original.sizeKind).toBe('exact');
    expect(original.status).toBe('READY');

    // Jamais de chemin serveur dans un DTO.
    for (const option of body.options) expect(option).not.toHaveProperty('path');
  });

  it('durée inconnue → aucune estimation inventée (sizeBytes null)', async () => {
    const trackId = seedTrack(owner.id, 'SansDuree', null);
    const response = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/offline-options`,
      headers: auth(owner.token),
    });
    const [opus128] = response.json().options;
    expect(opus128.sizeBytes).toBeNull();
    expect(opus128.sizeKind).toBeNull();
  });
});

describe('cycle de vie des variantes', () => {
  it('POST → 202 puis READY avec taille exacte, hash et débit mesuré', async () => {
    const trackId = seedTrack(owner.id);
    const created = await app.inject({
      method: 'POST',
      url: `/api/tracks/${trackId}/offline-variants/opus_256`,
      headers: auth(owner.token),
    });
    expect(created.statusCode).toBe(202);
    expect(created.json().status).toBe('PENDING');
    expect(created.json().sizeKind).toBe('estimated');

    await drain();
    const readyState = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/offline-variants/opus_256`,
      headers: auth(owner.token),
    });
    expect(readyState.statusCode).toBe(200);
    const body = readyState.json();
    expect(body.status).toBe('READY');
    expect(body.sizeKind).toBe('exact');
    expect(body.sizeBytes).toBe(2048); // 1024 × (256/128)
    expect(body.sha256).toMatch(/^[0-9a-f]{64}$/);
    // La qualité affichée vient de ffprobe, jamais de l'argument demandé.
    expect(body.measuredBitrateKbps).toBe(131);
    expect(body.lossy).toBe(true);
    expect(body).not.toHaveProperty('path');

    // Un second POST retourne 200 sans réencoder (single-flight).
    const again = await app.inject({
      method: 'POST',
      url: `/api/tracks/${trackId}/offline-variants/opus_256`,
      headers: auth(owner.token),
    });
    expect(again.statusCode).toBe(200);
    expect(runner.encodeCalls).toHaveLength(1);
  });

  it('single-flight séparé : 128 et 256 sont deux identités distinctes', async () => {
    const trackId = seedTrack(owner.id);
    await app.inject({
      method: 'POST',
      url: `/api/tracks/${trackId}/offline-variants/opus_128`,
      headers: auth(owner.token),
    });
    await app.inject({
      method: 'POST',
      url: `/api/tracks/${trackId}/offline-variants/opus_256`,
      headers: auth(owner.token),
    });
    await drain();
    const rows = app.dbHandle.db
      .select()
      .from(trackOfflineVariants)
      .where(eq(trackOfflineVariants.trackId, trackId))
      .all();
    expect(rows).toHaveLength(2);
    expect(new Set(rows.map((r) => r.profileVersion))).toEqual(
      new Set(['opus-128-v1', 'opus-256-v1']),
    );
    expect(rows.every((r) => r.status === 'READY')).toBe(true);
    expect(runner.encodeCalls.map((c) => c.kbps).sort()).toEqual([128, 256]);
  });

  it('source remplacée → variante obsolète (STALE) et nouvelle identité', async () => {
    const trackId = seedTrack(owner.id);
    await app.inject({
      method: 'POST',
      url: `/api/tracks/${trackId}/offline-variants/opus_128`,
      headers: auth(owner.token),
    });
    await drain();

    // Réimport simulé : le hash source change.
    app.dbHandle.db
      .update(tracks)
      .set({ hash: 'hash-remplace-apres-reimport' })
      .where(eq(tracks.id, trackId))
      .run();

    const afterReplace = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/offline-variants/opus_128`,
      headers: auth(owner.token),
    });
    expect(afterReplace.statusCode).toBe(404); // l'identité courante n'existe plus

    const rows = app.dbHandle.db
      .select()
      .from(trackOfflineVariants)
      .where(eq(trackOfflineVariants.trackId, trackId))
      .all();
    expect(rows).toHaveLength(1);
    expect(rows[0]?.status).toBe('STALE');

    // Le fichier obsolète n'est plus servi.
    const file = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/offline-variants/opus_128/file`,
      headers: auth(owner.token),
    });
    expect(file.statusCode).toBe(404);
  });

  it('échec ffmpeg → FAILED, aucun fichier publié, retry possible', async () => {
    runner.mode = 'encode_fail';
    const trackId = seedTrack(owner.id);
    await app.inject({
      method: 'POST',
      url: `/api/tracks/${trackId}/offline-variants/opus_128`,
      headers: auth(owner.token),
    });
    await drain();

    const state = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/offline-variants/opus_128`,
      headers: auth(owner.token),
    });
    expect(state.json().status).toBe('FAILED');
    expect(readdirSync(join(base, 'derived'))).toHaveLength(0); // ni .ogg ni .part

    // Réarmement : un nouveau POST relance l'encodage.
    runner.mode = 'ok';
    const retry = await app.inject({
      method: 'POST',
      url: `/api/tracks/${trackId}/offline-variants/opus_128`,
      headers: auth(owner.token),
    });
    expect(retry.statusCode).toBe(202);
    await drain();
    const recovered = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/offline-variants/opus_128`,
      headers: auth(owner.token),
    });
    expect(recovered.json().status).toBe('READY');
  });

  it.each([
    ['probe_bad_codec', 'codec inattendu'],
    ['probe_bad_container', 'conteneur inattendu'],
    ['probe_bad_duration', 'durée incohérente'],
    ['probe_missing_duration', 'durée de la dérivée absente'],
    ['probe_missing_bitrate', 'débit de la dérivée absent'],
  ] as const)('validation ffprobe %s → rejet sans publication', async (mode) => {
    runner.mode = mode;
    const trackId = seedTrack(owner.id);
    await app.inject({
      method: 'POST',
      url: `/api/tracks/${trackId}/offline-variants/opus_128`,
      headers: auth(owner.token),
    });
    await drain();
    const state = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/offline-variants/opus_128`,
      headers: auth(owner.token),
    });
    expect(state.json().status).toBe('FAILED');
    expect(readdirSync(join(base, 'derived')).filter((f) => f.endsWith('.ogg'))).toHaveLength(0);
  });

  it('READY sans fichier physique → régénération automatique', async () => {
    const trackId = seedTrack(owner.id);
    await app.inject({
      method: 'POST',
      url: `/api/tracks/${trackId}/offline-variants/opus_128`,
      headers: auth(owner.token),
    });
    await drain();
    const row = app.dbHandle.db
      .select()
      .from(trackOfflineVariants)
      .where(eq(trackOfflineVariants.trackId, trackId))
      .get();
    expect(row?.status).toBe('READY');
    if (row?.path === null || row?.path === undefined) throw new Error('chemin READY manquant');
    rmSync(join(base, 'derived', row.path));

    const repairing = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/offline-variants/opus_128`,
      headers: auth(owner.token),
    });
    expect(repairing.json().status).toBe('PENDING');
    await drain();

    const recovered = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/offline-variants/opus_128`,
      headers: auth(owner.token),
    });
    expect(recovered.json().status).toBe('READY');
    expect(runner.encodeCalls).toHaveLength(2);
  });
});

describe('fichier de variante — HTTP Range', () => {
  async function readyVariant(): Promise<number> {
    const trackId = seedTrack(owner.id);
    await app.inject({
      method: 'POST',
      url: `/api/tracks/${trackId}/offline-variants/opus_128`,
      headers: auth(owner.token),
    });
    await drain();
    return trackId;
  }

  it('200 complet, 206 partiel, reprise à un offset et 416', async () => {
    const trackId = await readyVariant();
    const url = `/api/tracks/${trackId}/offline-variants/opus_128/file`;

    const full = await app.inject({ method: 'GET', url, headers: auth(owner.token) });
    expect(full.statusCode).toBe(200);
    expect(full.headers['content-length']).toBe('1024');
    expect(full.headers['content-type']).toContain('audio/ogg');
    expect(full.headers['accept-ranges']).toBe('bytes');

    const partial = await app.inject({
      method: 'GET',
      url,
      headers: { ...auth(owner.token), range: 'bytes=0-99' },
    });
    expect(partial.statusCode).toBe(206);
    expect(partial.headers['content-range']).toBe('bytes 0-99/1024');
    expect(partial.rawPayload).toHaveLength(100);

    // Reprise après interruption : suffixe depuis l'octet 1000.
    const resume = await app.inject({
      method: 'GET',
      url,
      headers: { ...auth(owner.token), range: 'bytes=1000-' },
    });
    expect(resume.statusCode).toBe(206);
    expect(resume.headers['content-range']).toBe('bytes 1000-1023/1024');
    expect(resume.rawPayload).toHaveLength(24);

    const unsatisfiable = await app.inject({
      method: 'GET',
      url,
      headers: { ...auth(owner.token), range: 'bytes=999999-' },
    });
    expect(unsatisfiable.statusCode).toBe(416);
    expect(unsatisfiable.headers['content-range']).toBe('bytes */1024');
  });

  it("l'ETag du fichier est le SHA-256 de la dérivée (vérification mobile)", async () => {
    const trackId = await readyVariant();
    const state = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/offline-variants/opus_128`,
      headers: auth(owner.token),
    });
    const file = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/offline-variants/opus_128/file`,
      headers: auth(owner.token),
    });
    expect(file.headers.etag).toBe(`"${state.json().sha256}"`);
  });

  it('variante non prête → 404 (jamais de transcodage dans la réponse HTTP)', async () => {
    runner.mode = 'encode_fail';
    const trackId = seedTrack(owner.id);
    await app.inject({
      method: 'POST',
      url: `/api/tracks/${trackId}/offline-variants/opus_128`,
      headers: auth(owner.token),
    });
    await drain();
    const file = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/offline-variants/opus_128/file`,
      headers: auth(owner.token),
    });
    expect(file.statusCode).toBe(404);
  });
});

describe('reprise des jobs au démarrage', () => {
  it('un ENCODING interrompu redevient PENDING puis aboutit', async () => {
    const trackId = seedTrack(owner.id);
    // Ligne orpheline simulant un crash serveur en plein encodage.
    const track = app.dbHandle.db.select().from(tracks).where(eq(tracks.id, trackId)).get();
    if (track === undefined) throw new Error('seed manquant');
    const now = new Date().toISOString();
    app.dbHandle.db
      .insert(trackOfflineVariants)
      .values({
        trackId,
        sourceSha256: track.hash,
        profile: 'opus_128',
        profileVersion: 'opus-128-v1',
        encoderVersion: 'test-encoder-1',
        status: 'ENCODING',
        targetBitrateKbps: 128,
        durationSeconds: 120,
        createdAt: now,
        updatedAt: now,
      })
      .run();

    app.offlineVariants.resumePendingJobs();
    await drain();

    const state = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/offline-variants/opus_128`,
      headers: auth(owner.token),
    });
    expect(state.json().status).toBe('READY');
  });
});
