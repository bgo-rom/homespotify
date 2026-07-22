import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { eq } from 'drizzle-orm';
import { buildApp } from '../app.js';
import type { AppConfig } from '../config.js';
import { users } from '../db/schema.js';
import { sanitizeAuditMetadata } from './audit.js';

const base = mkdtempSync(join(tmpdir(), 'homespotify-auth-test-'));

function makeConfig(): AppConfig {
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

const OWNER_CREDENTIALS = {
  username: 'romain',
  displayName: 'Romain',
  password: 'motdepasse-owner-1',
  passwordConfirmation: 'motdepasse-owner-1',
};

let app: FastifyInstance;

async function bootstrapOwner() {
  const res = await app.inject({
    method: 'POST',
    url: '/api/auth/bootstrap',
    payload: OWNER_CREDENTIALS,
  });
  expect(res.statusCode).toBe(201);
  return res.json();
}

async function createUserAsOwner(
  ownerToken: string,
  input: { username: string; role?: string; temporaryPassword?: string },
) {
  const res = await app.inject({
    method: 'POST',
    url: '/api/admin/users',
    headers: { authorization: `Bearer ${ownerToken}` },
    payload: {
      username: input.username,
      displayName: input.username,
      temporaryPassword: input.temporaryPassword ?? 'motdepasse-temp-1',
      role: input.role ?? 'USER',
    },
  });
  expect(res.statusCode).toBe(201);
  return res.json().user;
}

/** Connexion complète d'un compte créé par le OWNER (change son mot de passe temporaire). */
async function loginFully(username: string, temporaryPassword = 'motdepasse-temp-1') {
  const login = await app.inject({
    method: 'POST',
    url: '/api/auth/login',
    payload: { username, password: temporaryPassword },
  });
  expect(login.statusCode).toBe(200);
  const changed = await app.inject({
    method: 'POST',
    url: '/api/auth/change-password',
    headers: { authorization: `Bearer ${login.json().accessToken}` },
    payload: {
      currentPassword: temporaryPassword,
      newPassword: 'motdepasse-final-1',
      newPasswordConfirmation: 'motdepasse-final-1',
    },
  });
  expect(changed.statusCode).toBe(200);
  return changed.json();
}

beforeEach(async () => {
  app = buildApp(makeConfig());
  await app.ready();
});

afterEach(async () => {
  await app.close();
  rmSync(base, { recursive: true, force: true });
});

describe('bootstrap OWNER', () => {
  it('indique bootstrapRequired puis crée le premier compte en OWNER avec session', async () => {
    const before = await app.inject({ method: 'GET', url: '/api/auth/bootstrap-status' });
    expect(before.json().bootstrapRequired).toBe(true);

    const body = await bootstrapOwner();
    expect(body.user.role).toBe('OWNER');
    expect(body.user.username).toBe('romain');
    expect(body.accessToken).toBeTruthy();
    expect(body.refreshToken).toBeTruthy();
    expect(body.user.passwordHash).toBeUndefined();

    const after = await app.inject({ method: 'GET', url: '/api/auth/bootstrap-status' });
    expect(after.json().bootstrapRequired).toBe(false);
  });

  it('refuse un deuxième bootstrap', async () => {
    await bootstrapOwner();
    const res = await app.inject({
      method: 'POST',
      url: '/api/auth/bootstrap',
      payload: { ...OWNER_CREDENTIALS, username: 'autre' },
    });
    expect(res.statusCode).toBe(409);
    expect(res.json().error).toBe('bootstrap_unavailable');
  });

  it('résiste à deux bootstraps simultanés : un seul OWNER créé', async () => {
    const [a, b] = await Promise.all([
      app.inject({ method: 'POST', url: '/api/auth/bootstrap', payload: OWNER_CREDENTIALS }),
      app.inject({
        method: 'POST',
        url: '/api/auth/bootstrap',
        payload: { ...OWNER_CREDENTIALS, username: 'concurrent' },
      }),
    ]);
    const codes = [a.statusCode, b.statusCode].sort();
    expect(codes).toEqual([201, 409]);
    const owners = app.dbHandle.db.select().from(users).where(eq(users.role, 'OWNER')).all();
    expect(owners).toHaveLength(1);
  });

  it("l'unicité du OWNER est garantie par la base elle-même", () => {
    const now = new Date().toISOString();
    const insertOwner = (username: string) =>
      app.dbHandle.db
        .insert(users)
        .values({
          username,
          displayName: username,
          passwordHash: 'x',
          role: 'OWNER',
          isActive: true,
          mustChangePassword: false,
          createdAt: now,
          updatedAt: now,
        })
        .run();
    insertOwner('owner1');
    expect(() => insertOwner('owner2')).toThrow(/UNIQUE/);
  });

  it('valide et nettoie les entrées', async () => {
    for (const payload of [
      { ...OWNER_CREDENTIALS, username: 'A B<script>' },
      { ...OWNER_CREDENTIALS, password: 'court', passwordConfirmation: 'court' },
      { ...OWNER_CREDENTIALS, passwordConfirmation: 'autre-mot-de-passe' },
      { ...OWNER_CREDENTIALS, displayName: '' },
    ]) {
      const res = await app.inject({ method: 'POST', url: '/api/auth/bootstrap', payload });
      expect(res.statusCode).toBe(400);
    }
  });
});

describe('login / refresh / logout', () => {
  it('login réussi, refresh avec rotation, ancien token révoqué, logout', async () => {
    await bootstrapOwner();

    const login = await app.inject({
      method: 'POST',
      url: '/api/auth/login',
      payload: { username: 'ROMAIN ', password: OWNER_CREDENTIALS.password, deviceName: 'Pixel' },
    });
    expect(login.statusCode).toBe(200);
    const { accessToken, refreshToken } = login.json();

    const me = await app.inject({
      method: 'GET',
      url: '/api/auth/me',
      headers: { authorization: `Bearer ${accessToken}` },
    });
    expect(me.statusCode).toBe(200);
    expect(me.json().user.username).toBe('romain');
    expect(me.json().user.passwordHash).toBeUndefined();

    const refresh = await app.inject({
      method: 'POST',
      url: '/api/auth/refresh',
      payload: { refreshToken },
    });
    expect(refresh.statusCode).toBe(200);
    const newRefreshToken = refresh.json().refreshToken;
    expect(newRefreshToken).not.toBe(refreshToken);

    // L'ancien refresh token est consommé : sa réutilisation échoue.
    const replay = await app.inject({
      method: 'POST',
      url: '/api/auth/refresh',
      payload: { refreshToken },
    });
    expect(replay.statusCode).toBe(401);

    const logout = await app.inject({
      method: 'POST',
      url: '/api/auth/logout',
      payload: { refreshToken: newRefreshToken },
    });
    expect(logout.statusCode).toBe(204);

    const afterLogout = await app.inject({
      method: 'POST',
      url: '/api/auth/refresh',
      payload: { refreshToken: newRefreshToken },
    });
    expect(afterLogout.statusCode).toBe(401);
  });

  it('répond un message générique sur identifiants invalides', async () => {
    await bootstrapOwner();
    const unknownUser = await app.inject({
      method: 'POST',
      url: '/api/auth/login',
      payload: { username: 'inconnu', password: 'nimportequoi-123' },
    });
    const wrongPassword = await app.inject({
      method: 'POST',
      url: '/api/auth/login',
      payload: { username: 'romain', password: 'mauvais-mot-de-passe' },
    });
    expect(unknownUser.statusCode).toBe(401);
    expect(wrongPassword.statusCode).toBe(401);
    expect(unknownUser.json().message).toBe(wrongPassword.json().message);
  });

  it('refuse un compte bloqué au login et invalide ses tokens existants', async () => {
    const owner = await bootstrapOwner();
    const user = await createUserAsOwner(owner.accessToken, { username: 'invite' });
    const session = await loginFully('invite');

    const block = await app.inject({
      method: 'PATCH',
      url: `/api/admin/users/${user.id}/status`,
      headers: { authorization: `Bearer ${owner.accessToken}` },
      payload: { isActive: false, reason: 'test' },
    });
    expect(block.statusCode).toBe(200);

    // Access token encore cryptographiquement valide, mais compte inactif.
    const me = await app.inject({
      method: 'GET',
      url: '/api/auth/me',
      headers: { authorization: `Bearer ${session.accessToken}` },
    });
    expect(me.statusCode).toBe(401);

    const login = await app.inject({
      method: 'POST',
      url: '/api/auth/login',
      payload: { username: 'invite', password: 'motdepasse-final-1' },
    });
    expect(login.statusCode).toBe(403);
    expect(login.json().error).toBe('account_disabled');
  });

  it('force le changement de mot de passe (mustChangePassword)', async () => {
    const owner = await bootstrapOwner();
    await createUserAsOwner(owner.accessToken, { username: 'nouveau' });

    const login = await app.inject({
      method: 'POST',
      url: '/api/auth/login',
      payload: { username: 'nouveau', password: 'motdepasse-temp-1' },
    });
    expect(login.statusCode).toBe(200);
    expect(login.json().user.mustChangePassword).toBe(true);
    const token = login.json().accessToken;

    // Route quelconque refusée tant que le mot de passe n'est pas changé.
    const blocked = await app.inject({
      method: 'POST',
      url: '/api/auth/logout-all',
      headers: { authorization: `Bearer ${token}` },
    });
    expect(blocked.statusCode).toBe(204); // logout-all reste permis

    const adminBlocked = await app.inject({
      method: 'GET',
      url: '/api/admin/overview',
      headers: { authorization: `Bearer ${token}` },
    });
    expect(adminBlocked.statusCode).toBe(403);
  });
});

describe('administration OWNER', () => {
  it('refuse les routes admin sans token, à USER et à ADMIN', async () => {
    const owner = await bootstrapOwner();
    await createUserAsOwner(owner.accessToken, { username: 'simple', role: 'USER' });
    await createUserAsOwner(owner.accessToken, {
      username: 'gerant',
      role: 'ADMIN',
      temporaryPassword: 'motdepasse-temp-2',
    });
    const userSession = await loginFully('simple');
    const adminSession = await loginFully('gerant', 'motdepasse-temp-2');

    for (const [name, headers] of [
      ['anonyme', {}],
      ['USER', { authorization: `Bearer ${userSession.accessToken}` }],
      ['ADMIN', { authorization: `Bearer ${adminSession.accessToken}` }],
    ] as const) {
      const overview = await app.inject({ method: 'GET', url: '/api/admin/overview', headers });
      const list = await app.inject({ method: 'GET', url: '/api/admin/users', headers });
      expect(overview.statusCode, `overview ${name}`).toBeGreaterThanOrEqual(401);
      expect(list.statusCode, `users ${name}`).toBeGreaterThanOrEqual(401);
    }
  });

  it('OWNER voit l’overview avec des données réelles et sans secret', async () => {
    const owner = await bootstrapOwner();
    const res = await app.inject({
      method: 'GET',
      url: '/api/admin/overview',
      headers: { authorization: `Bearer ${owner.accessToken}` },
    });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.backend.status).toBe('ok');
    expect(body.library.trackCount).toBe(0);
    expect(body.users.total).toBe(1);
    expect(body.sessions.active).toBeGreaterThanOrEqual(1);
    expect(body.operations.status).toBe('healthy');
    expect(body.operations.audioErrors24h).toBe(0);
    expect(body.operations.failedImports).toBe(0);
    expect(body.operations.files).toEqual({
      suspect: 0,
      missing: 0,
      inconsistentSize: 0,
      invalidPath: 0,
    });
    expect(body.operations.scanner.running).toBe(false);
    const raw = res.body.toLowerCase();
    expect(raw).not.toContain('secret');
    expect(raw).not.toContain('passwordhash');
  });

  it('refuse le lancement manuel quand les sauvegardes sont désactivées', async () => {
    const owner = await bootstrapOwner();
    const res = await app.inject({
      method: 'POST',
      url: '/api/admin/backup/run',
      headers: { authorization: `Bearer ${owner.accessToken}` },
    });
    expect(res.statusCode).toBe(503);
    expect(res.json().error).toBe('backup_disabled');
  });

  it('OWNER administre un autre compte : rôle, sessions, reset, suppression', async () => {
    const owner = await bootstrapOwner();
    const user = await createUserAsOwner(owner.accessToken, { username: 'cible' });
    const session = await loginFully('cible');
    const auth = { authorization: `Bearer ${owner.accessToken}` };

    const promote = await app.inject({
      method: 'PATCH',
      url: `/api/admin/users/${user.id}/role`,
      headers: auth,
      payload: { role: 'ADMIN' },
    });
    expect(promote.statusCode).toBe(200);
    expect(promote.json().user.role).toBe('ADMIN');

    const demote = await app.inject({
      method: 'PATCH',
      url: `/api/admin/users/${user.id}/role`,
      headers: auth,
      payload: { role: 'USER' },
    });
    expect(demote.json().user.role).toBe('USER');

    const reset = await app.inject({
      method: 'POST',
      url: `/api/admin/users/${user.id}/reset-password`,
      headers: auth,
      payload: { temporaryPassword: 'motdepasse-reset-1' },
    });
    expect(reset.statusCode).toBe(200);
    expect(reset.json().user.mustChangePassword).toBe(true);
    expect(reset.body).not.toContain('motdepasse-reset-1');

    // Le reset révoque les sessions : l'ancien refresh token est mort.
    const refresh = await app.inject({
      method: 'POST',
      url: '/api/auth/refresh',
      payload: { refreshToken: session.refreshToken },
    });
    expect(refresh.statusCode).toBe(401);

    const del = await app.inject({
      method: 'DELETE',
      url: `/api/admin/users/${user.id}`,
      headers: auth,
    });
    expect(del.statusCode).toBe(204);
    const gone = await app.inject({
      method: 'GET',
      url: `/api/admin/users/${user.id}`,
      headers: auth,
    });
    expect(gone.statusCode).toBe(404);
  });

  it('le OWNER ne peut être ni supprimé, ni bloqué, ni rétrogradé, ni visé par un reset', async () => {
    const owner = await bootstrapOwner();
    const ownerId = owner.user.id;
    const auth = { authorization: `Bearer ${owner.accessToken}` };

    const attempts = [
      app.inject({ method: 'DELETE', url: `/api/admin/users/${ownerId}`, headers: auth }),
      app.inject({
        method: 'PATCH',
        url: `/api/admin/users/${ownerId}/status`,
        headers: auth,
        payload: { isActive: false },
      }),
      app.inject({
        method: 'PATCH',
        url: `/api/admin/users/${ownerId}/role`,
        headers: auth,
        payload: { role: 'USER' },
      }),
      app.inject({
        method: 'POST',
        url: `/api/admin/users/${ownerId}/reset-password`,
        headers: auth,
        payload: { temporaryPassword: 'motdepasse-reset-1' },
      }),
    ];
    for (const res of await Promise.all(attempts)) {
      expect(res.statusCode).toBe(403);
      expect(res.json().error).toBe('owner_protected');
    }
  });

  it('aucun endpoint ne permet de créer un second OWNER', async () => {
    const owner = await bootstrapOwner();
    const res = await app.inject({
      method: 'POST',
      url: '/api/admin/users',
      headers: { authorization: `Bearer ${owner.accessToken}` },
      payload: {
        username: 'fauxowner',
        displayName: 'Faux',
        temporaryPassword: 'motdepasse-temp-1',
        role: 'OWNER',
      },
    });
    expect(res.statusCode).toBe(400);
  });

  it('journalise les actions sensibles sans donnée sensible et pagine', async () => {
    const owner = await bootstrapOwner();
    const user = await createUserAsOwner(owner.accessToken, { username: 'journal' });
    const auth = { authorization: `Bearer ${owner.accessToken}` };
    await app.inject({
      method: 'PATCH',
      url: `/api/admin/users/${user.id}/status`,
      headers: auth,
      payload: { isActive: false },
    });
    await app.inject({
      method: 'POST',
      url: '/api/auth/login',
      payload: { username: 'journal', password: 'mauvais-mot-de-passe' },
    });

    const res = await app.inject({ method: 'GET', url: '/api/admin/audit-logs?limit=10', headers: auth });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.total).toBeGreaterThanOrEqual(4);
    const actions = body.items.map((item: { action: string }) => item.action);
    expect(actions).toContain('auth.bootstrap');
    expect(actions).toContain('admin.user_created');
    expect(actions).toContain('admin.user_blocked');
    expect(actions).toContain('auth.login_failed');
    const raw = res.body.toLowerCase();
    expect(raw).not.toContain('motdepasse');
    expect(raw).not.toContain('passwordhash');
  });
});

describe('sanitizeAuditMetadata', () => {
  it('supprime toute clé ou valeur sensible', () => {
    expect(
      sanitizeAuditMetadata({
        reason: 'test',
        password: 'oops',
        refreshToken: 'oops',
        passwordHash: 'oops',
        note: 'contient un token secret',
        count: 3,
        nested: { deep: true },
      }),
    ).toEqual({ reason: 'test', count: 3 });
  });
});
