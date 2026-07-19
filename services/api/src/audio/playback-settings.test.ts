import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import FormData from 'form-data';
import type { FastifyInstance } from 'fastify';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../app.js';
import type { AppConfig } from '../config.js';
import { trackAudioAnalysis, userTracks } from '../db/schema.js';
import { makeWav } from '../test/wav.js';
import {
  normalizeBpm,
  publicAudioAnalysisFailureReason,
  TrackAudioAnalysisService,
  type BpmMeasurement,
  type TrackBpmAnalyzer,
} from './bpm-analysis.js';

let base: string;
let app: FastifyInstance;
let analyzer: FakeBpmAnalyzer;

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
  };
}

beforeEach(async () => {
  base = mkdtempSync(join(tmpdir(), 'homespotify-speed-'));
  analyzer = new FakeBpmAnalyzer();
  app = buildApp(config(), { bpmAnalyzer: analyzer });
  await app.ready();
});

afterEach(async () => {
  await app.close();
  rmSync(base, { recursive: true, force: true });
});

describe('réglages de vitesse par utilisateur', () => {
  it('applique les valeurs par défaut et rejette 0.69, 1.31 et preservePitch=false', async () => {
    const owner = await bootstrapOwner();
    const trackId = await importTrack(owner.token);
    const path = `/api/tracks/${trackId}/playback-settings`;

    const initial = await app.inject({ method: 'GET', url: path, headers: auth(owner.token) });
    expect(initial.json()).toMatchObject({
      speedRatio: 1,
      preservePitch: true,
      isDefault: true,
    });

    for (const payload of [
      { speedRatio: 0.69, preservePitch: true },
      { speedRatio: 1.31, preservePitch: true },
      { speedRatio: 1, preservePitch: false },
    ]) {
      const response = await app.inject({
        method: 'PUT',
        url: path,
        headers: auth(owner.token),
        payload,
      });
      expect(response.statusCode).toBe(400);
    }

    expect(() =>
      app.dbHandle.sqlite
        .prepare(
          `INSERT INTO user_track_playback_settings
           (user_id, track_id, speed_ratio, preserve_pitch, created_at, updated_at)
           VALUES (?, ?, ?, ?, ?, ?)`,
        )
        .run(owner.id, trackId, 0.69, 1, new Date().toISOString(), new Date().toISOString()),
    ).toThrow();
  });

  it('isole le réglage par compte et DELETE restaure 1.00x', async () => {
    const owner = await bootstrapOwner();
    const alice = await createUser(owner.token, 'alice');
    const bob = await createUser(owner.token, 'bob');
    const trackId = await importTrack(alice.token);
    app.dbHandle.db
      .insert(userTracks)
      .values({
        userId: bob.id,
        trackId,
        addedAt: new Date().toISOString(),
        addedByUserId: owner.id,
        source: 'ADMIN',
        isVisible: true,
      })
      .run();
    const path = `/api/tracks/${trackId}/playback-settings`;

    expect(
      (
        await app.inject({
          method: 'PUT',
          url: path,
          headers: auth(alice.token),
          payload: { speedRatio: 1.2, preservePitch: true },
        })
      ).statusCode,
    ).toBe(200);
    const bobDefault = await app.inject({ method: 'GET', url: path, headers: auth(bob.token) });
    expect(bobDefault.json().speedRatio).toBe(1);

    await app.inject({
      method: 'PUT',
      url: path,
      headers: auth(bob.token),
      payload: { speedRatio: 0.8, preservePitch: true },
    });
    const aliceSetting = await app.inject({
      method: 'GET',
      url: path,
      headers: auth(alice.token),
    });
    expect(aliceSetting.json().speedRatio).toBe(1.2);

    await app.inject({ method: 'DELETE', url: path, headers: auth(alice.token) });
    const reset = await app.inject({ method: 'GET', url: path, headers: auth(alice.token) });
    expect(reset.json()).toMatchObject({ speedRatio: 1, isDefault: true });
  });
});

describe('analyse BPM en arrière-plan', () => {
  it('retourne PENDING sans attendre puis persiste le fallback analysé', async () => {
    const owner = await bootstrapOwner();
    const trackId = await importTrack(owner.token);
    const path = `/api/tracks/${trackId}/audio-analysis`;

    const pending = await app.inject({ method: 'GET', url: path, headers: auth(owner.token) });
    expect(pending.statusCode).toBe(200);
    expect(pending.json().status).toBe('PENDING');

    await waitFor(() => analyzer.calls === 1);
    analyzer.resolve({
      rawBpm: 118.2,
      bpm: 118.2,
      confidence: 0.62,
      source: 'FFMPEG_TEMPO',
    });
    const ready = await waitForAnalysis(path, owner.token);
    expect(ready).toMatchObject({
      status: 'LOW_CONFIDENCE',
      bpm: 118.2,
      bpmConfidence: 0.62,
      bpmSource: 'FFMPEG_TEMPO',
    });
    expect(analyzer.calls, 1);
  });

  it('termine en READY quand la confiance est suffisante', async () => {
    const owner = await bootstrapOwner();
    const trackId = await importTrack(owner.token);
    const path = `/api/tracks/${trackId}/audio-analysis`;

    await app.inject({ method: 'GET', url: path, headers: auth(owner.token) });
    await waitFor(() => analyzer.calls === 1);
    analyzer.resolve({
      rawBpm: 121,
      bpm: 121,
      confidence: 0.91,
      source: 'FFMPEG_TEMPO',
    });

    expect(await waitForAnalysis(path, owner.token)).toMatchObject({
      status: 'READY',
      bpm: 121,
      bpmConfidence: 0.91,
      failureReason: null,
    });
  });

  it('termine en FAILED avec une raison publique sure', async () => {
    const owner = await bootstrapOwner();
    const trackId = await importTrack(owner.token);
    const path = `/api/tracks/${trackId}/audio-analysis`;

    await app.inject({ method: 'GET', url: path, headers: auth(owner.token) });
    await waitFor(() => analyzer.calls === 1);
    analyzer.reject(new Error('Signal trop court pour estimer le tempo.'));

    expect(await waitForAnalysis(path, owner.token)).toMatchObject({
      status: 'FAILED',
      bpm: null,
      failureReason: 'BPM_NOT_DETECTED',
    });
  });

  it('reprend au boot un etat ANALYZING orphelin', async () => {
    const owner = await bootstrapOwner();
    const trackId = await importTrack(owner.token);
    app.dbHandle.db
      .insert(trackAudioAnalysis)
      .values({
        trackId,
        status: 'ANALYZING',
        updatedAt: new Date().toISOString(),
      })
      .run();

    const resumedAnalyzer = new FakeBpmAnalyzer();
    const resumedService = new TrackAudioAnalysisService(
      app.dbHandle,
      join(base, 'music'),
      resumedAnalyzer,
    );
    await waitFor(() => resumedAnalyzer.calls === 1);
    expect(resumedService).toBeDefined();
    resumedAnalyzer.resolve({
      rawBpm: 126,
      bpm: 126,
      confidence: 0.9,
      source: 'FFMPEG_TEMPO',
    });
    await waitFor(() => analysisRow(trackId)?.status === 'READY');
  });

  it('rend un analyseur bloque terminal apres le timeout du job', async () => {
    const owner = await bootstrapOwner();
    const trackId = await importTrack(owner.token);
    const service = new TrackAudioAnalysisService(
      app.dbHandle,
      join(base, 'music'),
      new NeverBpmAnalyzer(),
      20,
    );

    expect(service.getOrSchedule(trackId).status).toBe('PENDING');
    await waitFor(() => analysisRow(trackId)?.status === 'FAILED');
    const failed = analysisRow(trackId)!;
    expect(publicAudioAnalysisFailureReason(failed.error_message)).toBe(
      'ANALYSIS_TIMEOUT',
    );
  });

  it('normalise les tempos half-time et double-time', () => {
    expect(normalizeBpm(59)).toBe(118);
    expect(normalizeBpm(220)).toBe(110);
    expect(normalizeBpm(128)).toBe(128);
  });
});

class FakeBpmAnalyzer implements TrackBpmAnalyzer {
  private resolver?: (measurement: BpmMeasurement) => void;
  private rejecter?: (error: unknown) => void;
  calls = 0;

  analyze(): Promise<BpmMeasurement> {
    this.calls += 1;
    return new Promise((resolve, reject) => {
      this.resolver = resolve;
      this.rejecter = reject;
    });
  }

  resolve(measurement: BpmMeasurement): void {
    this.resolver?.(measurement);
  }

  reject(error: unknown): void {
    this.rejecter?.(error);
  }
}

class NeverBpmAnalyzer implements TrackBpmAnalyzer {
  analyze(): Promise<BpmMeasurement> {
    return new Promise(() => {});
  }
}

function analysisRow(trackId: number): {
  status: string;
  error_message: string | null;
} | undefined {
  return app.dbHandle.sqlite
    .prepare(
      'SELECT status, error_message FROM track_audio_analysis WHERE track_id = ?',
    )
    .get(trackId) as { status: string; error_message: string | null } | undefined;
}

async function bootstrapOwner(): Promise<{ id: number; token: string }> {
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
  expect(response.statusCode).toBe(201);
  return { id: response.json().user.id, token: response.json().accessToken };
}

async function createUser(
  ownerToken: string,
  username: string,
): Promise<{ id: number; token: string }> {
  const created = await app.inject({
    method: 'POST',
    url: '/api/admin/users',
    headers: auth(ownerToken),
    payload: {
      username,
      displayName: username,
      temporaryPassword: 'motdepasse-temp-1',
      role: 'USER',
    },
  });
  const id = created.json().user.id;
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
      newPassword: 'motdepasse-final-1',
      newPasswordConfirmation: 'motdepasse-final-1',
    },
  });
  return { id, token: changed.json().accessToken };
}

async function importTrack(token: string): Promise<number> {
  const form = new FormData();
  form.append('provenance', 'rip_cd');
  form.append(
    'file',
    makeWav({ title: 'Tempo', artist: 'Artiste', album: 'Album', seconds: 0.08 }),
    { filename: 'tempo.wav', contentType: 'audio/wav' },
  );
  const response = await app.inject({
    method: 'POST',
    url: '/api/tracks',
    headers: { ...form.getHeaders(), ...auth(token) },
    payload: form,
  });
  expect(response.statusCode).toBe(201);
  return response.json().id;
}

async function waitForAnalysis(path: string, token: string): Promise<Record<string, unknown>> {
  for (let attempt = 0; attempt < 30; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
    const response = await app.inject({ method: 'GET', url: path, headers: auth(token) });
    if (['READY', 'LOW_CONFIDENCE', 'FAILED'].includes(response.json().status)) {
      return response.json();
    }
  }
  throw new Error('Analyse BPM non terminée.');
}

async function waitFor(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 30; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error('Condition asynchrone non satisfaite.');
}

function auth(token: string): { authorization: string } {
  return { authorization: `Bearer ${token}` };
}
