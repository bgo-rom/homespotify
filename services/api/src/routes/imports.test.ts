import { existsSync, mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import type { FastifyInstance } from 'fastify';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { buildApp } from '../app.js';
import type { AppConfig } from '../config.js';
import { userImportDirectories, users } from '../db/schema.js';
import { hashPassword } from '../auth/passwords.js';

let root: string;
let app: FastifyInstance;

beforeEach(async () => {
  root = mkdtempSync(join(tmpdir(), 'homespotify-import-routes-'));
  const config: AppConfig = {
    nodeEnv: 'test',
    host: '127.0.0.1',
    port: 0,
    dbPath: ':memory:',
    logLevel: 'fatal',
    musicDir: join(root, 'music'),
    incomingDir: join(root, 'incoming'),
    importRoot: join(root, 'imports'),
    coversDir: join(root, 'covers'),
    maxUploadBytes: 200 * 1024 * 1024,
    authTokenSecret: 'test-secret-at-least-thirty-two-characters',
    accessTokenTtlSeconds: 900,
    refreshTokenTtlSeconds: 86400,
  };
  app = buildApp(config, { importWatcher: false });
  await app.ready();
});

afterEach(async () => {
  await app.close();
  rmSync(root, { recursive: true, force: true });
});

async function login(username: string, password: string): Promise<string> {
  const response = await app.inject({
    method: 'POST',
    url: '/api/auth/login',
    payload: { username, password },
  });
  expect(response.statusCode).toBe(200);
  return response.json().accessToken as string;
}

describe('routes imports OWNER', () => {
  it('crée le dossier du compte et refuse ADMIN/USER', async () => {
    const ownerPassword = 'owner-password-123';
    const bootstrap = await app.inject({
      method: 'POST',
      url: '/api/auth/bootstrap',
      payload: {
        username: 'owner',
        displayName: 'Owner',
        password: ownerPassword,
        passwordConfirmation: ownerPassword,
      },
    });
    expect(bootstrap.statusCode).toBe(201);
    const ownerToken = bootstrap.json().accessToken as string;
    const created = await app.inject({
      method: 'POST',
      url: '/api/admin/users',
      headers: { authorization: `Bearer ${ownerToken}` },
      payload: {
        username: 'listener',
        displayName: 'Listener',
        temporaryPassword: 'listener-password-123',
        role: 'USER',
      },
    });
    expect(created.statusCode).toBe(201);
    const listenerId = created.json().user.id as number;
    const directory = app.dbHandle.db
      .select()
      .from(userImportDirectories)
      .where(eq(userImportDirectories.userId, listenerId))
      .get();
    expect(directory?.directoryName).toBe(`${listenerId}_listener`);
    expect(existsSync(join(root, 'imports', `${listenerId}_listener`, 'inbox'))).toBe(true);

    const now = new Date().toISOString();
    for (const [username, role] of [['admin', 'ADMIN'], ['user', 'USER']] as const) {
      app.dbHandle.db.insert(users).values({
        username,
        displayName: username,
        passwordHash: await hashPassword(`${username}-password-123`),
        role,
        isActive: true,
        mustChangePassword: false,
        createdAt: now,
        updatedAt: now,
      }).run();
      const token = await login(username, `${username}-password-123`);
      const response = await app.inject({
        method: 'GET',
        url: '/api/admin/imports',
        headers: { authorization: `Bearer ${token}` },
      });
      expect(response.statusCode).toBe(403);
    }
    const ownerResponse = await app.inject({
      method: 'GET',
      url: '/api/admin/imports',
      headers: { authorization: `Bearer ${ownerToken}` },
    });
    expect(ownerResponse.statusCode).toBe(200);

    const scanResponse = await app.inject({
      method: 'POST',
      url: '/api/admin/imports/scan',
      headers: { authorization: `Bearer ${ownerToken}` },
    });
    expect(scanResponse.statusCode).toBe(202);
    expect(scanResponse.json()).toMatchObject({
      accepted: true,
      profiles: 4,
      discoveredFiles: 0,
      queuedFiles: 0,
    });
  });
});
