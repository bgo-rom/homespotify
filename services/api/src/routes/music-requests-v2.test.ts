import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { FastifyInstance } from 'fastify';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { buildApp } from '../app.js';
import { auditLogs } from '../db/schema.js';
import type { AppConfig } from '../config.js';

let root: string;
let app: FastifyInstance;
let ownerToken: string;

beforeEach(async () => {
  root = mkdtempSync(join(tmpdir(), 'homespotify-requests-v2-'));
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
  ownerToken = bootstrap.json().accessToken as string;
});

afterEach(async () => {
  await app.close();
  rmSync(root, { recursive: true, force: true });
});

async function createUser(username: string): Promise<string> {
  const password = `${username}-password-123`;
  const created = await app.inject({
    method: 'POST',
    url: '/api/admin/users',
    headers: { authorization: `Bearer ${ownerToken}` },
    payload: {
      username,
      displayName: username,
      temporaryPassword: password,
      role: 'USER',
    },
  });
  expect(created.statusCode).toBe(201);
  const login = await app.inject({
    method: 'POST',
    url: '/api/auth/login',
    payload: { username, password },
  });
  expect(login.statusCode).toBe(200);
  const changed = await app.inject({
    method: 'POST',
    url: '/api/auth/change-password',
    headers: { authorization: `Bearer ${login.json().accessToken as string}` },
    payload: {
      currentPassword: password,
      newPassword: `${username}-changed-password-123`,
      newPasswordConfirmation: `${username}-changed-password-123`,
    },
  });
  expect(changed.statusCode).toBe(200);
  return changed.json().accessToken as string;
}

describe('demandes TRACK, ALBUM et PLAYLIST', () => {
  it('conserve le snapshot ordonné, isole les comptes et interdit COMPLETED manuel', async () => {
    const aliceToken = await createUser('alice');
    const bobToken = await createUser('bob');
    const authorization = { authorization: `Bearer ${aliceToken}` };

    const track = await app.inject({
      method: 'POST',
      url: '/api/music-requests',
      headers: authorization,
      payload: { requestType: 'TRACK', title: 'Titre seul', artist: 'Artiste A' },
    });
    expect(track.statusCode).toBe(201);
    expect(track.json()).toMatchObject({
      requestType: 'TRACK',
      requestedItemCount: 1,
    });

    const album = await app.inject({
      method: 'POST',
      url: '/api/music-requests',
      headers: authorization,
      payload: {
        requestType: 'ALBUM',
        title: 'Album demandé',
        artist: 'Artiste B',
        externalUrl: 'https://example.test/album/1',
        items: [
          { position: 1, title: 'Premier', artist: 'Artiste B' },
          { position: 2, title: 'Second', artist: 'Artiste B' },
        ],
      },
    });
    expect(album.statusCode).toBe(201);
    expect(album.json().items.map((item: { title: string }) => item.title)).toEqual([
      'Premier',
      'Second',
    ]);

    const playlist = await app.inject({
      method: 'POST',
      url: '/api/music-requests',
      headers: authorization,
      payload: {
        requestType: 'PLAYLIST',
        title: 'Playlist demandée',
        externalUrl: 'https://example.test/playlist/1',
        items: [{ position: 1, title: 'Unique', artist: 'Artiste C' }],
      },
    });
    expect(playlist.statusCode).toBe(201);
    const playlistId = playlist.json().id as number;

    const crossAccount = await app.inject({
      method: 'GET',
      url: `/api/music-requests/${playlistId}`,
      headers: { authorization: `Bearer ${bobToken}` },
    });
    expect(crossAccount.statusCode).toBe(404);

    const forced = await app.inject({
      method: 'PATCH',
      url: `/api/admin/music-requests/${playlistId}`,
      headers: { authorization: `Bearer ${ownerToken}` },
      payload: { status: 'COMPLETED' },
    });
    expect(forced.statusCode).toBe(409);

    const adminList = await app.inject({
      method: 'GET',
      url: '/api/admin/music-requests?type=PLAYLIST&userId=2',
      headers: { authorization: `Bearer ${ownerToken}` },
    });
    expect(adminList.statusCode).toBe(200);
    expect(adminList.json().items).toHaveLength(1);
    expect(adminList.json().items[0]).toMatchObject({
      id: playlistId,
      externalUrl: 'https://example.test/playlist/1',
      requester: { username: 'alice' },
    });

    expect(
      app.dbHandle.db
        .select()
        .from(auditLogs)
        .where(eq(auditLogs.action, 'music_request.created'))
        .all(),
    ).toHaveLength(3);
  });

  it('refuse les URL non HTTP(S)', async () => {
    const userToken = await createUser('listener');
    const response = await app.inject({
      method: 'POST',
      url: '/api/music-requests',
      headers: { authorization: `Bearer ${userToken}` },
      payload: {
        requestType: 'PLAYLIST',
        title: 'Interdite',
        externalUrl: 'file:///etc/passwd',
      },
    });
    expect(response.statusCode).toBe(400);
  });
});
