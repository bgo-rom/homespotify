import type { FastifyInstance, FastifyReply } from 'fastify';
import { and, desc, eq } from 'drizzle-orm';
import { favorites, userTracks } from '../db/schema.js';
import type { AuthGuards } from '../auth/guards.js';
import { summarizeUserLibrary, userCanAccessTrack } from '../library/user-library-service.js';

interface FavoriteBody {
  trackId?: unknown;
}

function badRequest(reply: FastifyReply, message: string): FastifyReply {
  return reply.code(400).send({ statusCode: 400, error: 'bad_request', message });
}

/**
 * Favoris par utilisateur. Le userId vient TOUJOURS du token. On ne peut mettre
 * en favori qu'une piste à laquelle on a accès (sinon 404, cohérent avec
 * l'isolation bibliothèque).
 */
export function registerFavoritesRoutes(app: FastifyInstance, guards: AuthGuards): void {
  const { db } = app.dbHandle;
  const requireAuth = guards.requireAuth();

  // Résumé de SA propre bibliothèque (section Compte mobile). Le userId vient
  // du token ; aucun accès aux données d'un autre compte.
  app.get('/api/library/summary', { preHandler: requireAuth }, async (request) => ({
    summary: summarizeUserLibrary(app.dbHandle, request.authUser.id),
  }));

  // IDs des favoris de l'utilisateur (source de vérité pour le mobile).
  app.get('/api/favorites', { preHandler: requireAuth }, async (request) => {
    const rows = db
      .select({ trackId: favorites.trackId })
      .from(favorites)
      .innerJoin(userTracks, and(
        eq(userTracks.userId, favorites.userId),
        eq(userTracks.trackId, favorites.trackId),
        eq(userTracks.isVisible, true),
      ))
      .where(eq(favorites.userId, request.authUser.id))
      .orderBy(desc(favorites.createdAt))
      .all();
    return { trackIds: rows.map((row) => row.trackId) };
  });

  app.post<{ Body: FavoriteBody }>(
    '/api/favorites',
    { preHandler: requireAuth },
    async (request, reply) => {
      const trackId = Number(request.body?.trackId);
      if (!Number.isInteger(trackId) || trackId < 1) {
        return badRequest(reply, 'trackId (entier positif) est obligatoire.');
      }
      if (!userCanAccessTrack(app.dbHandle, request.authUser.id, trackId)) {
        return reply.code(404).send({ statusCode: 404, error: 'not_found', message: 'Piste inconnue' });
      }
      db.insert(favorites)
        .values({ userId: request.authUser.id, trackId, createdAt: new Date().toISOString() })
        .onConflictDoNothing()
        .run();
      return reply.code(201).send({ trackId, favorite: true });
    },
  );

  app.delete<{ Params: { trackId: string } }>(
    '/api/favorites/:trackId',
    { preHandler: requireAuth },
    async (request, reply) => {
      const trackId = Number(request.params.trackId);
      if (!Number.isInteger(trackId) || trackId < 1) {
        return badRequest(reply, 'trackId invalide.');
      }
      db.delete(favorites)
        .where(and(eq(favorites.userId, request.authUser.id), eq(favorites.trackId, trackId)))
        .run();
      return reply.code(204).send();
    },
  );

  // Import unique des favoris locaux du mobile (migration douce). N'écrase
  // jamais : ajoute seulement les pistes accessibles pas encore en favori.
  app.post<{ Body: { trackIds?: unknown } }>(
    '/api/favorites/import',
    { preHandler: requireAuth },
    async (request, reply) => {
      const raw = request.body?.trackIds;
      if (!Array.isArray(raw)) return badRequest(reply, 'trackIds (tableau) est obligatoire.');
      const userId = request.authUser.id;
      const now = new Date().toISOString();
      let imported = 0;
      db.transaction((tx) => {
        for (const value of raw) {
          const trackId = Number(value);
          if (!Number.isInteger(trackId) || trackId < 1) continue;
          if (!userCanAccessTrack(app.dbHandle, userId, trackId)) continue;
          const result = tx
            .insert(favorites)
            .values({ userId, trackId, createdAt: now })
            .onConflictDoNothing()
            .run();
          imported += result.changes;
        }
      });
      return { imported };
    },
  );
}
