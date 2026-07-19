import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import FormData from 'form-data';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { eq } from 'drizzle-orm';
import { buildApp } from '../app.js';
import type { AppConfig } from '../config.js';
import { userTracks } from '../db/schema.js';
import { makeWav } from '../test/wav.js';

/**
 * Isolation stricte des bibliothèques + catalogue global anonymisé.
 * Scénario de référence : `skibidi` importe une piste ; le OWNER ne doit JAMAIS
 * la recevoir automatiquement dans sa bibliothèque PERSONNELLE.
 */

let base: string;
let app: FastifyInstance;

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

const auth = (token: string) => ({ authorization: `Bearer ${token}` });

async function bootstrapOwner(): Promise<string> {
  const res = await app.inject({
    method: 'POST',
    url: '/api/auth/bootstrap',
    payload: {
      username: 'owner',
      displayName: 'Owner',
      password: 'motdepasse-owner-1',
      passwordConfirmation: 'motdepasse-owner-1',
    },
  });
  expect(res.statusCode).toBe(201);
  return res.json().accessToken;
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
  expect(created.statusCode).toBe(201);
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
  expect(changed.statusCode).toBe(200);
  return { id, token: changed.json().accessToken };
}

async function importTrack(token: string, title: string): Promise<number> {
  const form = new FormData();
  form.append('provenance', 'rip_cd');
  form.append('file', makeWav({ title, artist: 'A', album: 'Alb', seconds: 0.08 }), {
    filename: `${title}.wav`,
    contentType: 'audio/wav',
  });
  const res = await app.inject({
    method: 'POST',
    url: '/api/tracks',
    payload: form,
    headers: { ...form.getHeaders(), authorization: `Bearer ${token}` },
  });
  expect(res.statusCode).toBe(201);
  return res.json().id as number;
}

const libraryIds = async (token: string): Promise<number[]> => {
  const res = await app.inject({ method: 'GET', url: '/api/tracks', headers: auth(token) });
  expect(res.statusCode).toBe(200);
  return res.json().items.map((t: { id: number }) => t.id);
};

beforeEach(async () => {
  base = mkdtempSync(join(tmpdir(), 'homespotify-catalog-'));
  app = buildApp(makeConfig(), { similarityProvider: null });
  await app.ready();
});

afterEach(async () => {
  await app.close();
  rmSync(base, { recursive: true, force: true });
});

describe('isolation stricte des bibliothèques personnelles', () => {
  it('la piste de skibidi reste à skibidi : ni OWNER ni un autre USER ne la reçoit', async () => {
    const ownerToken = await bootstrapOwner();
    const skibidi = await createUser(ownerToken, 'skibidi');
    const other = await createUser(ownerToken, 'autre');

    const trackId = await importTrack(skibidi.token, 'Piste Skibidi');

    expect(await libraryIds(skibidi.token)).toContain(trackId);
    expect(await libraryIds(other.token)).not.toContain(trackId);
    // Le rôle OWNER n'élargit JAMAIS la bibliothèque personnelle.
    expect(await libraryIds(ownerToken)).not.toContain(trackId);
  });

  it('un redémarrage ne transfère pas les imports des autres comptes au OWNER', async () => {
    const ownerToken = await bootstrapOwner();
    const skibidi = await createUser(ownerToken, 'skibidi');
    const trackId = await importTrack(skibidi.token, 'Piste Skibidi');

    // Le backfill du boot tournait à chaque démarrage et avalait cette piste.
    const { backfillOwnerLibrary } = await import('./user-library-service.js');
    backfillOwnerLibrary(app.dbHandle);
    backfillOwnerLibrary(app.dbHandle);

    expect(await libraryIds(ownerToken)).not.toContain(trackId);
    const accesses = app.dbHandle.db
      .select()
      .from(userTracks)
      .where(eq(userTracks.trackId, trackId))
      .all();
    expect(accesses).toHaveLength(1); // skibidi uniquement
    expect(accesses[0]!.userId).toBe(skibidi.id);
  });
});

describe('catalogue global anonymisé', () => {
  it('tous les comptes voient la piste, sans AUCUNE identité de l’importateur', async () => {
    const ownerToken = await bootstrapOwner();
    const skibidi = await createUser(ownerToken, 'skibidi');
    const other = await createUser(ownerToken, 'autre');
    const trackId = await importTrack(skibidi.token, 'Piste Skibidi');

    for (const token of [ownerToken, skibidi.token, other.token]) {
      const res = await app.inject({
        method: 'GET',
        url: '/api/catalog/recent',
        headers: auth(token),
      });
      expect(res.statusCode).toBe(200);
      const item = res.json().items.find((t: { id: number }) => t.id === trackId);
      expect(item).toBeDefined();
      // Anonymat : aucune trace de l'importateur ni de son dossier.
      const raw = JSON.stringify(res.json());
      expect(raw).not.toContain('skibidi');
      expect(raw).not.toMatch(/userId|username|importedBy|requestedBy|path|directory/i);
    }
  });

  it('inMyLibrary reflète UNIQUEMENT la bibliothèque du demandeur', async () => {
    const ownerToken = await bootstrapOwner();
    const skibidi = await createUser(ownerToken, 'skibidi');
    const trackId = await importTrack(skibidi.token, 'Piste Skibidi');

    const forSkibidi = await app.inject({
      method: 'GET',
      url: '/api/catalog/recent',
      headers: auth(skibidi.token),
    });
    const forOwner = await app.inject({
      method: 'GET',
      url: '/api/catalog/recent',
      headers: auth(ownerToken),
    });
    const pick = (r: typeof forOwner) =>
      r.json().items.find((t: { id: number }) => t.id === trackId);
    expect(pick(forSkibidi).inMyLibrary).toBe(true);
    expect(pick(forOwner).inMyLibrary).toBe(false);
  });

  it('exige une authentification', async () => {
    await bootstrapOwner();
    const res = await app.inject({ method: 'GET', url: '/api/catalog/recent' });
    expect(res.statusCode).toBe(401);
  });
});

describe('ajouter / retirer de sa bibliothèque', () => {
  it('ajout idempotent : un seul user_tracks, aucune copie de piste', async () => {
    const ownerToken = await bootstrapOwner();
    const skibidi = await createUser(ownerToken, 'skibidi');
    const other = await createUser(ownerToken, 'autre');
    const trackId = await importTrack(skibidi.token, 'Piste Skibidi');

    const first = await app.inject({
      method: 'POST',
      url: `/api/library/tracks/${trackId}`,
      headers: auth(other.token),
    });
    expect(first.statusCode).toBe(201);
    expect(first.json()).toMatchObject({ trackId, inMyLibrary: true, added: true });

    // Idempotent : rejouer n'ajoute rien.
    const second = await app.inject({
      method: 'POST',
      url: `/api/library/tracks/${trackId}`,
      headers: auth(other.token),
    });
    expect(second.statusCode).toBe(200);
    expect(second.json()).toMatchObject({ inMyLibrary: true, added: false });

    expect(await libraryIds(other.token)).toContain(trackId);
    // Une seule association pour `autre` ; la piste physique n'est pas dupliquée.
    const accesses = app.dbHandle.db
      .select()
      .from(userTracks)
      .where(eq(userTracks.trackId, trackId))
      .all();
    expect(accesses.filter((a) => a.userId === other.id)).toHaveLength(1);
    expect(accesses).toHaveLength(2); // skibidi + autre, même trackId
    // Le OWNER n'a toujours rien reçu.
    expect(await libraryIds(ownerToken)).not.toContain(trackId);
  });

  it('retrait : n’affecte que soi, la piste reste chez l’autre compte et au catalogue', async () => {
    const ownerToken = await bootstrapOwner();
    const skibidi = await createUser(ownerToken, 'skibidi');
    const other = await createUser(ownerToken, 'autre');
    const trackId = await importTrack(skibidi.token, 'Piste Skibidi');
    await app.inject({
      method: 'POST',
      url: `/api/library/tracks/${trackId}`,
      headers: auth(other.token),
    });

    const removed = await app.inject({
      method: 'DELETE',
      url: `/api/library/tracks/${trackId}`,
      headers: auth(other.token),
    });
    expect(removed.statusCode).toBe(200);

    expect(await libraryIds(other.token)).not.toContain(trackId);
    expect(await libraryIds(skibidi.token)).toContain(trackId); // intact
    // Toujours publié au catalogue global.
    const catalog = await app.inject({
      method: 'GET',
      url: '/api/catalog/recent',
      headers: auth(other.token),
    });
    expect(catalog.json().items.map((t: { id: number }) => t.id)).toContain(trackId);
  });
});

describe('autorisation du stream', () => {
  it('un compte authentifié peut lire une piste publiée qu’il ne possède pas', async () => {
    const ownerToken = await bootstrapOwner();
    const skibidi = await createUser(ownerToken, 'skibidi');
    const trackId = await importTrack(skibidi.token, 'Piste Skibidi');

    // Le OWNER ne l'a PAS dans sa bibliothèque, mais elle est au catalogue.
    expect(await libraryIds(ownerToken)).not.toContain(trackId);
    const stream = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/stream`,
      headers: auth(ownerToken),
    });
    expect(stream.statusCode).toBe(200);
  });

  it('sans authentification : 401', async () => {
    const ownerToken = await bootstrapOwner();
    const skibidi = await createUser(ownerToken, 'skibidi');
    const trackId = await importTrack(skibidi.token, 'Piste Skibidi');
    const res = await app.inject({ method: 'GET', url: `/api/tracks/${trackId}/stream` });
    expect(res.statusCode).toBe(401);
  });

  it('piste NON publiée (orpheline) : interdite sans user_tracks', async () => {
    const ownerToken = await bootstrapOwner();
    const skibidi = await createUser(ownerToken, 'skibidi');
    const other = await createUser(ownerToken, 'autre');
    const trackId = await importTrack(skibidi.token, 'Piste Skibidi');

    // skibidi la retire : plus aucun propriétaire → hors catalogue.
    await app.inject({
      method: 'DELETE',
      url: `/api/library/tracks/${trackId}`,
      headers: auth(skibidi.token),
    });

    const stream = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/stream`,
      headers: auth(other.token),
    });
    expect(stream.statusCode).toBe(404);
  });
});
