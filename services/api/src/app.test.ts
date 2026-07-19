import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { buildApp, CURRENT_PHASE } from './app.js';
import type { AppConfig } from './config.js';
import { runMigrations } from './db/migrate.js';

import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const base = mkdtempSync(join(tmpdir(), 'homespotify-app-test-'));
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

beforeAll(async () => {
  app = buildApp(testConfig);
  await app.ready();
});

afterAll(async () => {
  await app.close();
  rmSync(base, { recursive: true, force: true });
});

describe('GET /health', () => {
  it('répond ok avec timestamp et uptime', async () => {
    const res = await app.inject({ method: 'GET', url: '/health' });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.status).toBe('ok');
    expect(new Date(body.timestamp).getTime()).not.toBeNaN();
    expect(typeof body.uptimeSeconds).toBe('number');
  });
});

describe('GET /version', () => {
  it('répond nom, version et environnement', async () => {
    const res = await app.inject({ method: 'GET', url: '/version' });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.name).toBe('@homespotify/api');
    expect(body.version).toMatch(/^\d+\.\d+\.\d+$/);
    expect(body.environment).toBe('test');
  });
});

describe('GET /api/status', () => {
  it('répond phase, backend prêt et base initialisée', async () => {
    const res = await app.inject({ method: 'GET', url: '/api/status' });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.phase).toBe(CURRENT_PHASE);
    expect(body.backendReady).toBe(true);
    expect(body.database).toBe('initialized');
  });
});

describe('migrations manuscrites 0010/0011', () => {
  it('bootstrap in-memory complet et réexécution idempotente', () => {
    expect(() => runMigrations(app.dbHandle)).not.toThrow();
    const tables = app.dbHandle.sqlite
      .prepare("select name from sqlite_master where type = 'table'")
      .all() as Array<{ name: string }>;
    expect(tables.map((row) => row.name)).toContain('user_recommendation_queue');
    expect(tables.map((row) => row.name)).toContain('recommendation_impressions');

    const candidateColumns = app.dbHandle.sqlite
      .prepare('pragma table_info(recommendation_candidates)')
      .all() as Array<{ name: string }>;
    expect(candidateColumns.map((row) => row.name)).toEqual(
      expect.arrayContaining([
        'item_type',
        'external_url',
        'is_active',
        'preview_provider',
        'preview_matched_at',
        'preview_confidence',
        'preview_expires_at',
      ]),
    );
  });
});

describe('route inconnue', () => {
  it('répond 404 JSON structuré', async () => {
    const res = await app.inject({ method: 'GET', url: '/nope' });
    expect(res.statusCode).toBe(404);
    expect(res.json().error).toBe('not_found');
  });
});
