import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { and, eq } from 'drizzle-orm';
import { buildApp } from '../app.js';
import type { AppConfig } from '../config.js';
import { runMigrations } from '../db/migrate.js';
import { listeningEvents, listeningSessions, tracks, userTracks } from '../db/schema.js';

let base: string;
let app: FastifyInstance;
let owner: { id: number; token: string };

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

const auth = (token: string) => ({ authorization: `Bearer ${token}` });

async function createUser(username: string): Promise<{ id: number; token: string }> {
  const created = await app.inject({
    method: 'POST',
    url: '/api/admin/users',
    headers: auth(owner.token),
    payload: {
      username,
      displayName: username,
      temporaryPassword: 'motdepasse-temp-1',
      role: 'USER',
    },
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

function seedTrack(userId: number, title = 'Historique'): number {
  const now = new Date().toISOString();
  const result = app.dbHandle.db
    .insert(tracks)
    .values({
      hash: `hash-${userId}-${title}-${Math.random()}`,
      path: `${title}.flac`,
      sizeBytes: 1000,
      durationSeconds: 120,
      title,
      artist: 'Artiste',
      album: 'Album',
      createdAt: now,
    })
    .run();
  const trackId = Number(result.lastInsertRowid);
  app.dbHandle.db
    .insert(userTracks)
    .values({
      userId,
      trackId,
      addedAt: now,
      source: 'EXISTING',
      isVisible: true,
    })
    .run();
  return trackId;
}

function event(
  trackId: number,
  options: {
    eventId?: string;
    sessionId?: string;
    type?: string;
    positionMs?: number;
    listenedMs?: number;
    createdAt?: string;
  } = {},
) {
  return {
    clientEventId: options.eventId ?? '11111111-1111-4111-8111-111111111111',
    clientSessionId: options.sessionId ?? '22222222-2222-4222-8222-222222222222',
    installationId: '33333333-3333-4333-8333-333333333333',
    trackId,
    type: options.type ?? 'PLAY_STARTED',
    positionMs: options.positionMs ?? 0,
    listenedMs: options.listenedMs ?? 0,
    durationMs: 120000,
    playbackSpeed: 1,
    clientCreatedAt: options.createdAt ?? new Date().toISOString(),
  };
}

async function send(token: string, events: unknown[]) {
  return app.inject({
    method: 'POST',
    url: '/api/play-events/batch',
    headers: auth(token),
    payload: { events },
  });
}

beforeEach(async () => {
  base = mkdtempSync(join(tmpdir(), 'homespotify-listening-'));
  app = buildApp(config(), { importWatcher: false });
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
  await app.close();
  rmSync(base, { recursive: true, force: true });
});

describe('activité d’écoute', () => {
  it('migration 0016 additive et idempotente sur la base temporaire', () => {
    runMigrations(app.dbHandle, { info: () => {}, error: () => {} });
    runMigrations(app.dbHandle, { info: () => {}, error: () => {} });
    const objects = app.dbHandle.sqlite
      .prepare(
        "SELECT name FROM sqlite_master WHERE name IN ('listening_sessions', 'listening_events') ORDER BY name",
      )
      .all() as Array<{ name: string }>;
    expect(objects.map((row) => row.name)).toEqual([
      'listening_events',
      'listening_sessions',
    ]);
  });

  it('crée une session et ingère un batch idempotent', async () => {
    const trackId = seedTrack(owner.id);
    const first = await send(owner.token, [
      event(trackId),
      event(trackId, {
        eventId: '44444444-4444-4444-8444-444444444444',
        type: 'PLAY_PROGRESS',
        positionMs: 32000,
        listenedMs: 32000,
      }),
    ]);
    expect(first.statusCode).toBe(201);
    expect(first.json()).toEqual({ accepted: 2, duplicates: 0, rejected: 0 });
    const duplicate = await send(owner.token, [event(trackId)]);
    expect(duplicate.json()).toEqual({ accepted: 0, duplicates: 1, rejected: 0 });
    const session = app.dbHandle.db.select().from(listeningSessions).get();
    expect(session).toMatchObject({ listenedMs: 32000, qualifiedPlay: true });
    expect(app.dbHandle.db.select().from(listeningEvents).all()).toHaveLength(2);
  });

  it('tolère les événements désordonnés sans diminuer la progression', async () => {
    const trackId = seedTrack(owner.id);
    const now = Date.now();
    await send(owner.token, [
      event(trackId, {
        eventId: '55555555-5555-4555-8555-555555555555',
        type: 'PLAY_PROGRESS',
        positionMs: 60000,
        listenedMs: 50000,
        createdAt: new Date(now).toISOString(),
      }),
      event(trackId, {
        eventId: '66666666-6666-4666-8666-666666666666',
        type: 'PLAY_PROGRESS',
        positionMs: 20000,
        listenedMs: 20000,
        createdAt: new Date(now - 10000).toISOString(),
      }),
    ]);
    expect(app.dbHandle.db.select().from(listeningSessions).get()).toMatchObject({
      listenedMs: 50000,
      lastPositionMs: 60000,
    });
  });

  it('distingue skip rapide et complétion naturelle', async () => {
    const firstTrack = seedTrack(owner.id, 'Skip');
    const secondTrack = seedTrack(owner.id, 'Complete');
    await send(owner.token, [
      event(firstTrack, {
        type: 'PLAY_SKIPPED',
        listenedMs: 5000,
        positionMs: 5000,
      }),
      event(secondTrack, {
        eventId: '77777777-7777-4777-8777-777777777777',
        sessionId: '88888888-8888-4888-8888-888888888888',
        type: 'PLAY_COMPLETED',
        listenedMs: 100000,
        positionMs: 120000,
      }),
    ]);
    const sessions = app.dbHandle.db.select().from(listeningSessions).all();
    expect(sessions.find((row) => row.trackId === firstTrack)).toMatchObject({
      completed: false,
      qualifiedPlay: false,
      endReason: 'SKIPPED',
    });
    expect(sessions.find((row) => row.trackId === secondTrack)).toMatchObject({
      completed: true,
      qualifiedPlay: true,
      endReason: 'COMPLETED',
    });
  });

  it('termine une ancienne session quand la même installation en démarre une autre', async () => {
    const firstTrack = seedTrack(owner.id, 'Ancienne session');
    const secondTrack = seedTrack(owner.id, 'Nouvelle session');
    const startedAt = Date.now();
    await send(owner.token, [
      event(firstTrack, { createdAt: new Date(startedAt).toISOString() }),
    ]);
    await send(owner.token, [
      event(secondTrack, {
        eventId: '12121212-1212-4212-8212-121212121212',
        sessionId: '34343434-3434-4434-8434-343434343434',
        createdAt: new Date(startedAt + 1_000).toISOString(),
      }),
    ]);

    const sessions = app.dbHandle.db
      .select()
      .from(listeningSessions)
      .all();
    expect(sessions.find((row) => row.trackId === firstTrack)).toMatchObject({
      status: 'ENDED',
      endReason: 'SUPERSEDED',
    });
    expect(sessions.find((row) => row.trackId === secondTrack)).toMatchObject({
      status: 'ACTIVE',
      endReason: null,
    });
  });

  it('isole Alice et Bob et ignore un userId injecté', async () => {
    const alice = await createUser('alice');
    const bob = await createUser('bob');
    const trackId = seedTrack(alice.id);
    const inaccessible = await send(bob.token, [{ ...event(trackId), userId: alice.id }]);
    // La piste est publiée car Alice la possède : Bob peut la lire et journaliser
    // sa propre session, mais le userId arbitraire n'est jamais utilisé.
    expect(inaccessible.json().accepted).toBe(1);
    expect(
      app.dbHandle.db
        .select()
        .from(listeningSessions)
        .where(eq(listeningSessions.userId, alice.id))
        .all(),
    ).toHaveLength(0);
    expect(
      app.dbHandle.db
        .select()
        .from(listeningSessions)
        .where(eq(listeningSessions.userId, bob.id))
        .all(),
    ).toHaveLength(1);
  });

  it('rejette piste inconnue, vitesse et progression incohérentes', async () => {
    const trackId = seedTrack(owner.id);
    const response = await send(owner.token, [
      event(999999),
      { ...event(trackId), clientEventId: '99999999-9999-4999-8999-999999999999', playbackSpeed: 1.31 },
      { ...event(trackId), clientEventId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', listenedMs: 999999 },
    ]);
    expect(response.json()).toEqual({ accepted: 0, duplicates: 0, rejected: 3 });
  });

  it('pagine l’historique, propose une reprise pertinente et exclut 95 %', async () => {
    const resumable = seedTrack(owner.id, 'À reprendre');
    const almostDone = seedTrack(owner.id, 'Presque fini');
    await send(owner.token, [
      event(resumable, { type: 'PLAY_PAUSED', positionMs: 60000, listenedMs: 40000 }),
      event(almostDone, {
        eventId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        sessionId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
        type: 'PLAY_PAUSED',
        positionMs: 114000,
        listenedMs: 50000,
      }),
    ]);
    const history = await app.inject({
      method: 'GET',
      url: '/api/me/listening-activity?limit=1',
      headers: auth(owner.token),
    });
    expect(history.statusCode).toBe(200);
    expect(history.json().items).toHaveLength(1);
    expect(history.json().nextCursor).toEqual(expect.any(String));
    const resume = await app.inject({
      method: 'GET',
      url: '/api/me/resume-listening',
      headers: auth(owner.token),
    });
    expect(resume.json().items.map((item: { track: { id: number } }) => item.track.id)).toEqual([
      resumable,
    ]);
  });

  it('supprime uniquement l’historique du compte courant', async () => {
    const alice = await createUser('alice');
    const aliceTrack = seedTrack(alice.id, 'Alice');
    const ownerTrack = seedTrack(owner.id, 'Owner');
    await send(alice.token, [event(aliceTrack)]);
    await send(owner.token, [
      event(ownerTrack, {
        eventId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
        sessionId: 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
      }),
    ]);
    const deleted = await app.inject({
      method: 'DELETE',
      url: '/api/me/listening-activity',
      headers: auth(alice.token),
    });
    expect(deleted.statusCode).toBe(204);
    expect(
      app.dbHandle.db
        .select()
        .from(listeningSessions)
        .where(eq(listeningSessions.userId, alice.id))
        .all(),
    ).toHaveLength(0);
    expect(
      app.dbHandle.db
        .select()
        .from(listeningSessions)
        .where(and(eq(listeningSessions.userId, owner.id), eq(listeningSessions.trackId, ownerTrack)))
        .all(),
    ).toHaveLength(1);
  });
});
