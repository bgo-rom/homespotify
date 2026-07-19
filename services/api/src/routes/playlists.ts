import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { and, asc, eq, sql } from 'drizzle-orm';
import { playlists, playlistTracks } from '../db/schema.js';
import type { AuthGuards } from '../auth/guards.js';
import { userCanAccessTrack } from '../library/user-library-service.js';

function badRequest(reply: FastifyReply, message: string): FastifyReply {
  return reply.code(400).send({ statusCode: 400, error: 'bad_request', message });
}

function notFound(reply: FastifyReply): FastifyReply {
  return reply.code(404).send({ statusCode: 404, error: 'not_found', message: 'Playlist inconnue.' });
}

function normalizeName(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const name = raw.trim().replace(/\s+/g, ' ');
  return name.length >= 1 && name.length <= 100 ? name : null;
}

/**
 * Playlists par utilisateur. Chaque playlist appartient à l'utilisateur du
 * token. Toute opération vérifie d'abord que la playlist appartient bien à
 * l'appelant (sinon 404 — ne révèle pas l'existence d'une playlist d'autrui).
 */
export function registerPlaylistsRoutes(app: FastifyInstance, guards: AuthGuards): void {
  const { db } = app.dbHandle;
  const requireAuth = guards.requireAuth();

  /** Retourne la playlist si elle appartient à l'appelant, sinon null. */
  function ownedPlaylist(request: FastifyRequest, id: string) {
    const playlistId = Number(id);
    if (!Number.isInteger(playlistId)) return null;
    const row = db.select().from(playlists).where(eq(playlists.id, playlistId)).get();
    if (!row || row.userId !== request.authUser.id) return null;
    return row;
  }

  function serializePlaylist(playlistId: number) {
    const meta = db.select().from(playlists).where(eq(playlists.id, playlistId)).get();
    if (!meta) return null;
    const items = db
      .select({ trackId: playlistTracks.trackId, position: playlistTracks.position })
      .from(playlistTracks)
      .where(eq(playlistTracks.playlistId, playlistId))
      .orderBy(asc(playlistTracks.position))
      .all();
    return {
      id: meta.id,
      name: meta.name,
      createdAt: meta.createdAt,
      updatedAt: meta.updatedAt,
      trackIds: items.map((item) => item.trackId),
    };
  }

  app.get('/api/playlists', { preHandler: requireAuth }, async (request) => {
    const rows = db
      .select({
        id: playlists.id,
        name: playlists.name,
        createdAt: playlists.createdAt,
        updatedAt: playlists.updatedAt,
      })
      .from(playlists)
      .where(eq(playlists.userId, request.authUser.id))
      .orderBy(asc(playlists.name))
      .all();
    // Contenu ordonné de chaque playlist (le mobile a besoin des trackIds).
    const items = rows.map((row) => {
      const trackIds = db
        .select({ trackId: playlistTracks.trackId })
        .from(playlistTracks)
        .where(eq(playlistTracks.playlistId, row.id))
        .orderBy(asc(playlistTracks.position))
        .all()
        .map((entry) => entry.trackId);
      return { ...row, trackIds, trackCount: trackIds.length };
    });
    return { items };
  });

  app.get<{ Params: { id: string } }>(
    '/api/playlists/:id',
    { preHandler: requireAuth },
    async (request, reply) => {
      const owned = ownedPlaylist(request, request.params.id);
      if (!owned) return notFound(reply);
      return serializePlaylist(owned.id);
    },
  );

  app.post<{ Body: { name?: unknown } }>(
    '/api/playlists',
    { preHandler: requireAuth },
    async (request, reply) => {
      const name = normalizeName(request.body?.name);
      if (!name) return badRequest(reply, 'name (1 à 100 caractères) est obligatoire.');
      const now = new Date().toISOString();
      const created = db
        .insert(playlists)
        .values({ userId: request.authUser.id, name, createdAt: now, updatedAt: now })
        .returning()
        .get();
      return reply.code(201).send(serializePlaylist(created.id));
    },
  );

  app.patch<{ Params: { id: string }; Body: { name?: unknown } }>(
    '/api/playlists/:id',
    { preHandler: requireAuth },
    async (request, reply) => {
      const owned = ownedPlaylist(request, request.params.id);
      if (!owned) return notFound(reply);
      const name = normalizeName(request.body?.name);
      if (!name) return badRequest(reply, 'name (1 à 100 caractères) est obligatoire.');
      db.update(playlists)
        .set({ name, updatedAt: new Date().toISOString() })
        .where(eq(playlists.id, owned.id))
        .run();
      return serializePlaylist(owned.id);
    },
  );

  app.delete<{ Params: { id: string } }>(
    '/api/playlists/:id',
    { preHandler: requireAuth },
    async (request, reply) => {
      const owned = ownedPlaylist(request, request.params.id);
      if (!owned) return notFound(reply);
      // playlist_tracks tombe par cascade FK.
      db.delete(playlists).where(eq(playlists.id, owned.id)).run();
      return reply.code(204).send();
    },
  );

  // Ajouter une piste de SA bibliothèque en fin de playlist.
  app.post<{ Params: { id: string }; Body: { trackId?: unknown } }>(
    '/api/playlists/:id/tracks',
    { preHandler: requireAuth },
    async (request, reply) => {
      const owned = ownedPlaylist(request, request.params.id);
      if (!owned) return notFound(reply);
      const trackId = Number(request.body?.trackId);
      if (!Number.isInteger(trackId) || trackId < 1) {
        return badRequest(reply, 'trackId (entier positif) est obligatoire.');
      }
      if (!userCanAccessTrack(app.dbHandle, request.authUser.id, trackId)) {
        return reply.code(404).send({ statusCode: 404, error: 'not_found', message: 'Piste inconnue' });
      }
      db.transaction((tx) => {
        const maxPos = tx
          .select({ max: sql<number>`coalesce(max(${playlistTracks.position}), -1)` })
          .from(playlistTracks)
          .where(eq(playlistTracks.playlistId, owned.id))
          .get();
        tx.insert(playlistTracks)
          .values({
            playlistId: owned.id,
            trackId,
            position: (maxPos?.max ?? -1) + 1,
            addedAt: new Date().toISOString(),
          })
          .onConflictDoNothing()
          .run();
        tx.update(playlists)
          .set({ updatedAt: new Date().toISOString() })
          .where(eq(playlists.id, owned.id))
          .run();
      });
      return reply.code(201).send(serializePlaylist(owned.id));
    },
  );

  app.delete<{ Params: { id: string; trackId: string } }>(
    '/api/playlists/:id/tracks/:trackId',
    { preHandler: requireAuth },
    async (request, reply) => {
      const owned = ownedPlaylist(request, request.params.id);
      if (!owned) return notFound(reply);
      const trackId = Number(request.params.trackId);
      if (!Number.isInteger(trackId)) return badRequest(reply, 'trackId invalide.');
      db.delete(playlistTracks)
        .where(and(eq(playlistTracks.playlistId, owned.id), eq(playlistTracks.trackId, trackId)))
        .run();
      db.update(playlists)
        .set({ updatedAt: new Date().toISOString() })
        .where(eq(playlists.id, owned.id))
        .run();
      return serializePlaylist(owned.id);
    },
  );

  // Réordonner : liste complète des trackIds dans le nouvel ordre.
  app.put<{ Params: { id: string }; Body: { trackIds?: unknown } }>(
    '/api/playlists/:id/order',
    { preHandler: requireAuth },
    async (request, reply) => {
      const owned = ownedPlaylist(request, request.params.id);
      if (!owned) return notFound(reply);
      const raw = request.body?.trackIds;
      if (!Array.isArray(raw)) return badRequest(reply, 'trackIds (tableau) est obligatoire.');

      const current = db
        .select({ trackId: playlistTracks.trackId })
        .from(playlistTracks)
        .where(eq(playlistTracks.playlistId, owned.id))
        .all()
        .map((row) => row.trackId);
      const requested = raw.map(Number);
      // Le nouvel ordre doit être exactement l'ensemble courant (permutation).
      const sameSet =
        requested.length === current.length &&
        new Set(requested).size === requested.length &&
        requested.every((id) => current.includes(id));
      if (!sameSet) {
        return badRequest(reply, 'trackIds doit être une permutation exacte du contenu de la playlist.');
      }

      db.transaction((tx) => {
        requested.forEach((trackId, position) => {
          tx.update(playlistTracks)
            .set({ position })
            .where(and(eq(playlistTracks.playlistId, owned.id), eq(playlistTracks.trackId, trackId)))
            .run();
        });
        tx.update(playlists)
          .set({ updatedAt: new Date().toISOString() })
          .where(eq(playlists.id, owned.id))
          .run();
      });
      return serializePlaylist(owned.id);
    },
  );
}
