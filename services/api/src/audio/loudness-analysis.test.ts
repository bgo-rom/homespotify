import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import FormData from 'form-data';
import type { FastifyInstance } from 'fastify';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../app.js';
import type { AppConfig } from '../config.js';
import { makeWav } from '../test/wav.js';
import {
  computeReplayGain,
  parseLoudnormOutput,
  type LoudnessMeasurement,
  type TrackLoudnessAnalyzer,
} from './loudness-analysis.js';

let base: string;
let app: FastifyInstance;
let analyzer: FakeLoudnessAnalyzer;

beforeEach(async () => {
  base = mkdtempSync(join(tmpdir(), 'homespotify-loudness-'));
  analyzer = new FakeLoudnessAnalyzer();
  app = buildApp(config(), { loudnessAnalyzer: analyzer });
  await app.ready();
});

afterEach(async () => {
  await app.close();
  rmSync(base, { recursive: true, force: true });
});

describe('mesure R128 et ReplayGain', () => {
  it('vise -18 LUFS mais respecte le plafond true-peak -1 dBFS', () => {
    expect(
      computeReplayGain({ integratedLufs: -12, truePeakDbfs: -2 }),
    ).toEqual({ replayGainDb: -6, peakLimited: false });
    expect(
      computeReplayGain({ integratedLufs: -22, truePeakDbfs: -0.2 }),
    ).toEqual({ replayGainDb: -0.8, peakLimited: true });
  });

  it('parse le résumé JSON loudnorm sans dépendre du reste de stderr', () => {
    expect(
      parseLoudnormOutput(`
        Input #0
        {
          "input_i" : "-14.27",
          "input_tp" : "-0.83",
          "input_lra" : "5.10"
        }
      `),
    ).toEqual({ integratedLufs: -14.27, truePeakDbfs: -0.83 });
  });

  it('répond immédiatement puis publie uniquement une mesure calculée', async () => {
    const owner = await bootstrapOwner();
    const trackId = await importTrack(owner.token);
    const path = `/api/tracks/${trackId}/loudness-analysis`;

    const pending = await app.inject({
      method: 'GET',
      url: path,
      headers: auth(owner.token),
    });
    expect(pending.statusCode).toBe(200);
    expect(pending.json()).toMatchObject({
      status: 'PENDING',
      replayGainDb: null,
      targetLufs: -18,
      peakCeilingDbfs: -1,
    });

    await waitFor(() => analyzer.calls === 1);
    analyzer.resolve({ integratedLufs: -11.4, truePeakDbfs: -0.4 });
    const ready = await waitForAnalysis(path, owner.token);
    expect(ready).toMatchObject({
      status: 'READY',
      integratedLufs: -11.4,
      truePeakDbfs: -0.4,
      replayGainDb: -6.6,
      targetLufs: -18,
      peakCeilingDbfs: -1,
    });
    expect(analyzer.calls).toBe(1);
  });

  it('exige une authentification et masque une piste non accessible', async () => {
    const owner = await bootstrapOwner();
    const trackId = await importTrack(owner.token);
    const path = `/api/tracks/${trackId}/loudness-analysis`;

    expect((await app.inject({ method: 'GET', url: path })).statusCode).toBe(
      401,
    );
    const user = await createUser(owner.token, 'alice');
    expect(
      (
        await app.inject({
          method: 'GET',
          url: path,
          headers: auth(user.token),
        })
      ).statusCode,
    ).toBe(404);
  });
});

class FakeLoudnessAnalyzer implements TrackLoudnessAnalyzer {
  private resolver?: (measurement: LoudnessMeasurement) => void;
  calls = 0;

  analyze(): Promise<LoudnessMeasurement> {
    this.calls += 1;
    return new Promise((resolve) => {
      this.resolver = resolve;
    });
  }

  resolve(measurement: LoudnessMeasurement): void {
    this.resolver?.(measurement);
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
  };
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
  return {
    id: created.json().user.id,
    token: changed.json().accessToken,
  };
}

async function importTrack(token: string): Promise<number> {
  const form = new FormData();
  form.append('provenance', 'rip_cd');
  form.append(
    'file',
    makeWav({
      title: 'Loudness',
      artist: 'Artiste',
      album: 'Album',
      seconds: 0.08,
    }),
    { filename: 'loudness.wav', contentType: 'audio/wav' },
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

async function waitForAnalysis(
  path: string,
  token: string,
): Promise<Record<string, unknown>> {
  for (let attempt = 0; attempt < 30; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
    const response = await app.inject({
      method: 'GET',
      url: path,
      headers: auth(token),
    });
    if (['READY', 'FAILED'].includes(response.json().status)) {
      return response.json();
    }
  }
  throw new Error('Analyse R128 non terminée.');
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
