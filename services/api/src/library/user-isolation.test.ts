import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import FormData from 'form-data';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { eq } from 'drizzle-orm';
import { buildApp } from '../app.js';
import type { AppConfig } from '../config.js';
import { tracks, userTracks } from '../db/schema.js';
import { makeWav } from '../test/wav.js';
import { backfillOwnerLibrary } from './user-library-service.js';

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

/** Crée un USER/ADMIN via le OWNER puis renvoie un access token après changement de mot de passe. */
async function createUser(
  ownerToken: string,
  username: string,
  role: 'USER' | 'ADMIN' = 'USER',
): Promise<{ id: number; token: string }> {
  const created = await app.inject({
    method: 'POST',
    url: '/api/admin/users',
    headers: { authorization: `Bearer ${ownerToken}` },
    payload: { username, displayName: username, temporaryPassword: 'motdepasse-temp-1', role },
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
    headers: { authorization: `Bearer ${login.json().accessToken}` },
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
  return res.json().id;
}

function auth(token: string) {
  return { authorization: `Bearer ${token}` };
}

beforeEach(async () => {
  base = mkdtempSync(join(tmpdir(), 'homespotify-iso-'));
  app = buildApp(makeConfig());
  await app.ready();
});

afterEach(async () => {
  await app.close();
  rmSync(base, { recursive: true, force: true });
});

describe('isolation des bibliothèques', () => {
  it('un utilisateur A ne voit pas les pistes de B', async () => {
    const ownerToken = await bootstrapOwner();
    const a = await createUser(ownerToken, 'alice');
    const b = await createUser(ownerToken, 'bob');

    const trackA = await importTrack(a.token, 'Chanson Alice');
    await importTrack(b.token, 'Chanson Bob');

    const listA = await app.inject({ method: 'GET', url: '/api/tracks', headers: auth(a.token) });
    const idsA = listA.json().items.map((t: { id: number }) => t.id);
    expect(idsA).toContain(trackA);
    expect(listA.json().total).toBe(1);

    const listB = await app.inject({ method: 'GET', url: '/api/tracks', headers: auth(b.token) });
    expect(listB.json().items.map((t: { id: number }) => t.id)).not.toContain(trackA);
  });

  it('la recherche/liste est filtrée et le total ne fuit pas', async () => {
    const ownerToken = await bootstrapOwner();
    const a = await createUser(ownerToken, 'alice');
    await importTrack(a.token, 'Une');
    await importTrack(a.token, 'Deux');
    const b = await createUser(ownerToken, 'bob');

    const listB = await app.inject({ method: 'GET', url: '/api/tracks', headers: auth(b.token) });
    expect(listB.json().total).toBe(0);
    expect(listB.json().items).toHaveLength(0);
  });

  it('stream anonyme refusé (401)', async () => {
    const ownerToken = await bootstrapOwner();
    const a = await createUser(ownerToken, 'alice');
    const trackA = await importTrack(a.token, 'Sans auth');
    const res = await app.inject({ method: 'GET', url: `/api/tracks/${trackA}/stream` });
    expect(res.statusCode).toBe(401);
  });

  it('stream d’une piste NON publiée (orpheline) refusé (404)', async () => {
    const ownerToken = await bootstrapOwner();
    const a = await createUser(ownerToken, 'alice');
    const b = await createUser(ownerToken, 'bob');
    const trackA = await importTrack(a.token, 'Privée Alice');

    // Alice la retire : plus aucun propriétaire → hors catalogue global.
    await app.inject({
      method: 'DELETE',
      url: `/api/library/tracks/${trackA}`,
      headers: auth(a.token),
    });

    const res = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackA}/stream`,
      headers: auth(b.token),
    });
    expect(res.statusCode).toBe(404);
  });

  it('stream et cover : Bearer obligatoire ; une piste PUBLIÉE est lisible par tout compte authentifié', async () => {
    const ownerToken = await bootstrapOwner();
    const a = await createUser(ownerToken, 'alice');
    const b = await createUser(ownerToken, 'bob');
    const trackA = await importTrack(a.token, 'Média protégé');
    const cover = Buffer.from([0xff, 0xd8, 0xff, 0xd9]);
    writeFileSync(join(makeConfig().coversDir, 'protected.jpg'), cover);
    app.dbHandle.db
      .update(tracks)
      .set({ coverPath: 'protected.jpg' })
      .where(eq(tracks.id, trackA))
      .run();

    for (const suffix of ['stream', 'cover']) {
      // Jamais d'accès anonyme : le Bearer reste obligatoire.
      const anonymous = await app.inject({
        method: 'GET',
        url: `/api/tracks/${trackA}/${suffix}`,
      });
      expect(anonymous.statusCode).toBe(401);
      // Bob ne l'a PAS dans sa bibliothèque, mais elle est publiée au catalogue
      // global : la lecture est autorisée (cf. « Ajouts récents »).
      const fromCatalog = await app.inject({
        method: 'GET',
        url: `/api/tracks/${trackA}/${suffix}`,
        headers: auth(b.token),
      });
      expect(fromCatalog.statusCode).toBe(200);
      const allowed = await app.inject({
        method: 'GET',
        url: `/api/tracks/${trackA}/${suffix}`,
        headers: auth(a.token),
      });
      expect(allowed.statusCode).toBe(200);
    }
    // …mais la piste ne s'invite JAMAIS dans la bibliothèque de Bob.
    const list = await app.inject({ method: 'GET', url: '/api/tracks', headers: auth(b.token) });
    expect(list.json().items.map((t: { id: number }) => t.id)).not.toContain(trackA);
  });

  it('un fichier physique unique peut être partagé par attribution OWNER (jamais dupliqué)', async () => {
    const ownerToken = await bootstrapOwner();
    const a = await createUser(ownerToken, 'alice');
    const b = await createUser(ownerToken, 'bob');
    const trackA = await importTrack(a.token, 'Partagée');

    const grant = await app.inject({
      method: 'POST',
      url: `/api/admin/users/${b.id}/library/tracks`,
      headers: auth(ownerToken),
      payload: { trackId: trackA },
    });
    expect(grant.statusCode).toBe(201);

    // B y accède maintenant, mais il n'existe qu'UNE ligne dans tracks.
    const streamB = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackA}/stream`,
      headers: auth(b.token),
    });
    expect(streamB.statusCode).toBe(200);
    const trackRows = app.dbHandle.db.select().from(tracks).all();
    expect(trackRows).toHaveLength(1);
    // Deux accès logiques pour la même piste.
    const accesses = app.dbHandle.db
      .select()
      .from(userTracks)
      .where(eq(userTracks.trackId, trackA))
      .all();
    expect(accesses).toHaveLength(2);
  });
});

describe('favoris et playlists séparés', () => {
  it('les favoris sont propres à chaque compte', async () => {
    const ownerToken = await bootstrapOwner();
    const a = await createUser(ownerToken, 'alice');
    const b = await createUser(ownerToken, 'bob');
    const trackA = await importTrack(a.token, 'Fav Alice');

    const fav = await app.inject({
      method: 'POST',
      url: '/api/favorites',
      headers: auth(a.token),
      payload: { trackId: trackA },
    });
    expect(fav.statusCode).toBe(201);

    const favA = await app.inject({ method: 'GET', url: '/api/favorites', headers: auth(a.token) });
    expect(favA.json().trackIds).toEqual([trackA]);
    const favB = await app.inject({ method: 'GET', url: '/api/favorites', headers: auth(b.token) });
    expect(favB.json().trackIds).toEqual([]);
  });

  it('on ne peut pas mettre en favori une piste sans accès', async () => {
    const ownerToken = await bootstrapOwner();
    const a = await createUser(ownerToken, 'alice');
    const b = await createUser(ownerToken, 'bob');
    const trackA = await importTrack(a.token, 'Inaccessible');

    const fav = await app.inject({
      method: 'POST',
      url: '/api/favorites',
      headers: auth(b.token),
      payload: { trackId: trackA },
    });
    expect(fav.statusCode).toBe(404);
  });

  it('les playlists sont propres à chaque compte et inaccessibles aux autres', async () => {
    const ownerToken = await bootstrapOwner();
    const a = await createUser(ownerToken, 'alice');
    const b = await createUser(ownerToken, 'bob');
    const trackA = await importTrack(a.token, 'Piste playlist');

    const created = await app.inject({
      method: 'POST',
      url: '/api/playlists',
      headers: auth(a.token),
      payload: { name: 'Ma playlist' },
    });
    expect(created.statusCode).toBe(201);
    const playlistId = created.json().id;

    await app.inject({
      method: 'POST',
      url: `/api/playlists/${playlistId}/tracks`,
      headers: auth(a.token),
      payload: { trackId: trackA },
    });

    // B ne voit pas la playlist de A.
    const listB = await app.inject({ method: 'GET', url: '/api/playlists', headers: auth(b.token) });
    expect(listB.json().items).toHaveLength(0);
    // B ne peut pas ouvrir la playlist de A (404, pas 403 : ne révèle pas l'existence).
    const openB = await app.inject({
      method: 'GET',
      url: `/api/playlists/${playlistId}`,
      headers: auth(b.token),
    });
    expect(openB.statusCode).toBe(404);
    // A la voit avec sa piste.
    const openA = await app.inject({
      method: 'GET',
      url: `/api/playlists/${playlistId}`,
      headers: auth(a.token),
    });
    expect(openA.json().trackIds).toEqual([trackA]);
  });

  it('réordonner exige une permutation exacte', async () => {
    const ownerToken = await bootstrapOwner();
    const a = await createUser(ownerToken, 'alice');
    const t1 = await importTrack(a.token, 'T1');
    const t2 = await importTrack(a.token, 'T2');
    const created = await app.inject({
      method: 'POST',
      url: '/api/playlists',
      headers: auth(a.token),
      payload: { name: 'Ordre' },
    });
    const playlistId = created.json().id;
    for (const trackId of [t1, t2]) {
      await app.inject({
        method: 'POST',
        url: `/api/playlists/${playlistId}/tracks`,
        headers: auth(a.token),
        payload: { trackId },
      });
    }
    const reordered = await app.inject({
      method: 'PUT',
      url: `/api/playlists/${playlistId}/order`,
      headers: auth(a.token),
      payload: { trackIds: [t2, t1] },
    });
    expect(reordered.statusCode).toBe(200);
    expect(reordered.json().trackIds).toEqual([t2, t1]);

    const bad = await app.inject({
      method: 'PUT',
      url: `/api/playlists/${playlistId}/order`,
      headers: auth(a.token),
      payload: { trackIds: [t1] },
    });
    expect(bad.statusCode).toBe(400);
  });
});

describe('backfill OWNER', () => {
  it('attribue au OWNER les pistes préexistantes et est relançable sans doublon', async () => {
    const ownerToken = await bootstrapOwner();
    // Insère une piste directement en base (comme un scan CLI), sans user_tracks.
    const now = new Date().toISOString();
    const inserted = app.dbHandle.db
      .insert(tracks)
      .values({
        hash: 'hash-preexisting',
        path: 'x.wav',
        sizeBytes: 1000,
        title: 'Préexistante',
        artist: 'A',
        album: 'Alb',
        createdAt: now,
      })
      .returning()
      .get();

    const first = backfillOwnerLibrary(app.dbHandle);
    expect(first.assignedTracks).toBe(1);
    // Relance : aucun doublon, rien de nouveau.
    const second = backfillOwnerLibrary(app.dbHandle);
    expect(second.assignedTracks).toBe(0);

    const accesses = app.dbHandle.db
      .select()
      .from(userTracks)
      .where(eq(userTracks.trackId, inserted.id))
      .all();
    expect(accesses).toHaveLength(1);
    expect(accesses[0].source).toBe('EXISTING');

    // Le OWNER voit la piste rétro-attribuée.
    const list = await app.inject({ method: 'GET', url: '/api/tracks', headers: auth(ownerToken) });
    expect(list.json().items.map((t: { id: number }) => t.id)).toContain(inserted.id);
  });
});

describe('administration bibliothèque OWNER', () => {
  it('refuse USER et ADMIN, autorise OWNER', async () => {
    const ownerToken = await bootstrapOwner();
    const user = await createUser(ownerToken, 'simple', 'USER');
    const admin = await createUser(ownerToken, 'gerant', 'ADMIN');

    for (const token of [user.token, admin.token]) {
      const res = await app.inject({
        method: 'GET',
        url: `/api/admin/users/${user.id}/library`,
        headers: auth(token),
      });
      expect(res.statusCode).toBe(403);
    }
    const ok = await app.inject({
      method: 'GET',
      url: `/api/admin/users/${user.id}/library`,
      headers: auth(ownerToken),
    });
    expect(ok.statusCode).toBe(200);
  });

  it('le OWNER attribue puis retire un accès sans supprimer le fichier', async () => {
    const ownerToken = await bootstrapOwner();
    const a = await createUser(ownerToken, 'alice');
    const b = await createUser(ownerToken, 'bob');
    const trackA = await importTrack(a.token, 'Cible');

    const grant = await app.inject({
      method: 'POST',
      url: `/api/admin/users/${b.id}/library/tracks`,
      headers: auth(ownerToken),
      payload: { trackId: trackA },
    });
    expect(grant.statusCode).toBe(201);
    expect(grant.json().granted).toBe(true);

    const summary = await app.inject({
      method: 'GET',
      url: `/api/admin/users/${b.id}/library`,
      headers: auth(ownerToken),
    });
    expect(summary.json().summary.trackCount).toBe(1);

    const revoke = await app.inject({
      method: 'DELETE',
      url: `/api/admin/users/${b.id}/library/tracks/${trackA}`,
      headers: auth(ownerToken),
    });
    expect(revoke.statusCode).toBe(200);
    expect(revoke.json().revoked).toBe(true);

    // Fichier physique et ligne tracks toujours présents.
    expect(app.dbHandle.db.select().from(tracks).where(eq(tracks.id, trackA)).get()).toBeDefined();
    // B ne l'a plus dans SA bibliothèque personnelle…
    const listB = await app.inject({ method: 'GET', url: '/api/tracks', headers: auth(b.token) });
    expect(listB.json().items.map((t: { id: number }) => t.id)).not.toContain(trackA);
    // …mais la piste reste publiée au catalogue (A la détient) : lecture permise.
    const streamB = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackA}/stream`,
      headers: auth(b.token),
    });
    expect(streamB.statusCode).toBe(200);
    // A conserve son accès personnel.
    const streamA = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackA}/stream`,
      headers: auth(a.token),
    });
    expect(streamA.statusCode).toBe(200);
  });

  it('tailles logique / partagée / exclusive calculées correctement', async () => {
    const ownerToken = await bootstrapOwner();
    const a = await createUser(ownerToken, 'alice');
    const b = await createUser(ownerToken, 'bob');
    const shared = await importTrack(a.token, 'Partagée');
    const exclusive = await importTrack(a.token, 'Exclusive');
    await app.inject({
      method: 'POST',
      url: `/api/admin/users/${b.id}/library/tracks`,
      headers: auth(ownerToken),
      payload: { trackId: shared },
    });

    const sizeShared = app.dbHandle.db
      .select()
      .from(tracks)
      .where(eq(tracks.id, shared))
      .get()!.sizeBytes;
    const sizeExclusive = app.dbHandle.db
      .select()
      .from(tracks)
      .where(eq(tracks.id, exclusive))
      .get()!.sizeBytes;

    const summary = await app.inject({
      method: 'GET',
      url: `/api/admin/users/${a.id}/library`,
      headers: auth(ownerToken),
    });
    const s = summary.json().summary;
    expect(s.trackCount).toBe(2);
    expect(s.logicalSizeBytes).toBe(sizeShared + sizeExclusive);
    // Partagée comptée à moitié (2 accès), exclusive entière.
    expect(s.sharedSizeBytes).toBe(Math.round(sizeShared / 2) + sizeExclusive);
    expect(s.exclusiveSizeBytes).toBe(sizeExclusive);
  });

  it('n’accepte jamais un userId arbitraire : le userId vient du token', async () => {
    const ownerToken = await bootstrapOwner();
    const a = await createUser(ownerToken, 'alice');
    const trackA = await importTrack(a.token, 'Ma piste');
    // A tente de streamer en prétendant être un autre id via un champ body : impossible,
    // l'API ne lit jamais d'userId du client. La liste de A ne dépend que du token.
    const list = await app.inject({
      method: 'GET',
      url: '/api/tracks',
      headers: auth(a.token),
      payload: { userId: 999 },
    });
    expect(list.statusCode).toBe(200);
    expect(list.json().items.map((t: { id: number }) => t.id)).toEqual([trackA]);
  });
});
