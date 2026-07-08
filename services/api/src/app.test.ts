import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { buildApp, CURRENT_PHASE } from './app.js';
import type { AppConfig } from './config.js';

const testConfig: AppConfig = {
  nodeEnv: 'test',
  host: '127.0.0.1',
  port: 0,
  dbPath: ':memory:',
  logLevel: 'error',
};

let app: FastifyInstance;

beforeAll(async () => {
  app = buildApp(testConfig);
  await app.ready();
});

afterAll(async () => {
  await app.close();
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

describe('route inconnue', () => {
  it('répond 404 JSON structuré', async () => {
    const res = await app.inject({ method: 'GET', url: '/nope' });
    expect(res.statusCode).toBe(404);
    expect(res.json().error).toBe('not_found');
  });
});
