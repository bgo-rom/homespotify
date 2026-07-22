import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { buildApp } from '../app.js';
import type { AppConfig } from '../config.js';

const roots: string[] = [];

function config(root: string, secret: string): AppConfig {
  return {
    nodeEnv: 'test',
    host: '127.0.0.1',
    port: 0,
    dbPath: join(root, 'homespotify.db'),
    logLevel: 'fatal',
    musicDir: join(root, 'music'),
    incomingDir: join(root, 'imports'),
    importRoot: join(root, 'imports'),
    coversDir: join(root, 'covers'),
    maxUploadBytes: 200 * 1024 * 1024,
    authTokenSecret: secret,
    accessTokenTtlSeconds: 900,
    refreshTokenTtlSeconds: 30 * 24 * 60 * 60,
  };
}

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

describe('rotation du secret JWT', () => {
  it('invalide l’ancien access token mais conserve le refresh token opaque', async () => {
    const root = mkdtempSync(join(tmpdir(), 'homespotify-secret-rotation-'));
    roots.push(root);
    let app: FastifyInstance = buildApp(config(root, 'a'.repeat(64)), {
      importWatcher: false,
    });
    await app.ready();
    const bootstrap = await app.inject({
      method: 'POST',
      url: '/api/auth/bootstrap',
      payload: {
        username: 'owner',
        displayName: 'Owner',
        password: 'owner-password-123',
        passwordConfirmation: 'owner-password-123',
      },
    });
    expect(bootstrap.statusCode).toBe(201);
    const oldAccessToken = bootstrap.json().accessToken as string;
    const refreshToken = bootstrap.json().refreshToken as string;
    await app.close();

    app = buildApp(config(root, 'b'.repeat(64)), { importWatcher: false });
    await app.ready();
    const rejected = await app.inject({
      method: 'GET',
      url: '/api/auth/me',
      headers: { authorization: `Bearer ${oldAccessToken}` },
    });
    expect(rejected.statusCode).toBe(401);

    const refreshed = await app.inject({
      method: 'POST',
      url: '/api/auth/refresh',
      payload: { refreshToken },
    });
    expect(refreshed.statusCode).toBe(200);
    const accepted = await app.inject({
      method: 'GET',
      url: '/api/auth/me',
      headers: { authorization: `Bearer ${refreshed.json().accessToken as string}` },
    });
    expect(accepted.statusCode).toBe(200);
    await app.close();
  });
});
