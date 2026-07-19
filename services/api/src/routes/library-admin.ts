import type { FastifyInstance, FastifyReply } from 'fastify';
import { and, desc, eq, like, or } from 'drizzle-orm';
import { tracks, userTracks } from '../db/schema.js';
import { findUserById } from '../auth/auth-service.js';
import { recordAudit } from '../auth/audit.js';
import type { AuthGuards } from '../auth/guards.js';
import {
  grantTrack,
  revokeTrack,
  summarizeUserLibrary,
} from '../library/user-library-service.js';

function parseUserId(reply: FastifyReply, raw: string): number | null {
  const id = Number(raw);
  if (!Number.isInteger(id) || id < 1) {
    reply.code(400).send({ statusCode: 400, error: 'bad_request', message: 'Identifiant utilisateur invalide.' });
    return null;
  }
  return id;
}

/**
 * Administration OWNER de la bibliothèque d'un utilisateur : résumé, liste des
 * pistes, attribution/retrait d'accès. Toutes les actions sont journalisées.
 * Réservé au OWNER (guards.requireAdmin). Retirer un accès ne supprime jamais
 * le fichier physique.
 */
export function registerLibraryAdminRoutes(app: FastifyInstance, guards: AuthGuards): void {
  const handle = app.dbHandle;
  const { db } = handle;

  // Recherche OWNER pour associer une piste existante à une demande/import.
  app.get<{ Querystring: { q?: string; limit?: string } }>(
    '/api/admin/tracks/search',
    { preHandler: guards.requireAdmin('library.view') },
    async (request, reply) => {
      const query = request.query.q?.trim() ?? '';
      if (query.length < 2) {
        return reply.code(400).send({
          statusCode: 400,
          error: 'bad_request',
          message: 'La recherche doit contenir au moins 2 caractères.',
        });
      }
      const limit = Math.min(50, Math.max(1, Number(request.query.limit ?? 20) || 20));
      const pattern = `%${query.replace(/[\\%_]/g, '\\$&')}%`;
      const items = db
        .select({
          id: tracks.id,
          title: tracks.title,
          artist: tracks.artist,
          album: tracks.album,
          durationSeconds: tracks.durationSeconds,
          isrc: tracks.isrc,
        })
        .from(tracks)
        .where(
          or(
            like(tracks.title, pattern),
            like(tracks.artist, pattern),
            like(tracks.album, pattern),
          ),
        )
        .orderBy(tracks.artist, tracks.album, tracks.title)
        .limit(limit)
        .all();
      return { items };
    },
  );

  // Résumé : comptes + tailles logique / partagée / exclusive.
  app.get<{ Params: { id: string } }>(
    '/api/admin/users/:id/library',
    { preHandler: guards.requireAdmin('library.view') },
    async (request, reply) => {
      const userId = parseUserId(reply, request.params.id);
      if (userId === null) return reply;
      const target = findUserById(handle, userId);
      if (!target) {
        return reply.code(404).send({ statusCode: 404, error: 'user_not_found', message: 'Utilisateur inconnu.' });
      }
      return { userId, summary: summarizeUserLibrary(handle, userId) };
    },
  );

  // Liste des pistes accessibles à cet utilisateur (avec la source d'accès).
  app.get<{ Params: { id: string }; Querystring: { page?: string; limit?: string } }>(
    '/api/admin/users/:id/library/tracks',
    { preHandler: guards.requireAdmin('library.view') },
    async (request, reply) => {
      const userId = parseUserId(reply, request.params.id);
      if (userId === null) return reply;
      const page = Math.max(1, Number(request.query.page ?? 1) || 1);
      const limit = Math.min(200, Math.max(1, Number(request.query.limit ?? 50) || 50));
      const items = db
        .select({
          id: tracks.id,
          title: tracks.title,
          artist: tracks.artist,
          album: tracks.album,
          sizeBytes: tracks.sizeBytes,
          source: userTracks.source,
          isVisible: userTracks.isVisible,
          addedAt: userTracks.addedAt,
        })
        .from(userTracks)
        .innerJoin(tracks, eq(tracks.id, userTracks.trackId))
        .where(eq(userTracks.userId, userId))
        .orderBy(desc(userTracks.addedAt))
        .limit(limit)
        .offset((page - 1) * limit)
        .all();
      return { userId, page, limit, items };
    },
  );

  // Attribuer une piste existante à un utilisateur.
  app.post<{ Params: { id: string }; Body: { trackId?: unknown } }>(
    '/api/admin/users/:id/library/tracks',
    { preHandler: guards.requireAdmin('library.grant_track') },
    async (request, reply) => {
      const userId = parseUserId(reply, request.params.id);
      if (userId === null) return reply;
      const target = findUserById(handle, userId);
      if (!target) {
        return reply.code(404).send({ statusCode: 404, error: 'user_not_found', message: 'Utilisateur inconnu.' });
      }
      const trackId = Number(request.body?.trackId);
      if (!Number.isInteger(trackId) || trackId < 1) {
        return reply.code(400).send({ statusCode: 400, error: 'bad_request', message: 'trackId (entier positif) est obligatoire.' });
      }
      const track = db.select({ id: tracks.id }).from(tracks).where(eq(tracks.id, trackId)).get();
      if (!track) {
        return reply.code(404).send({ statusCode: 404, error: 'track_not_found', message: 'Piste inconnue.' });
      }
      const { granted } = grantTrack(handle, {
        userId,
        trackId,
        source: 'ADMIN',
        addedByUserId: request.authUser.id,
      });
      recordAudit(handle, {
        action: 'admin.library_track_granted',
        actorUserId: request.authUser.id,
        targetUserId: userId,
        metadata: { trackId, alreadyGranted: !granted },
      });
      return reply.code(granted ? 201 : 200).send({ userId, trackId, granted });
    },
  );

  // Retirer l'accès d'un utilisateur à une piste (JAMAIS de suppression de fichier).
  app.delete<{ Params: { id: string; trackId: string } }>(
    '/api/admin/users/:id/library/tracks/:trackId',
    { preHandler: guards.requireAdmin('library.revoke_track') },
    async (request, reply) => {
      const userId = parseUserId(reply, request.params.id);
      if (userId === null) return reply;
      const trackId = Number(request.params.trackId);
      if (!Number.isInteger(trackId) || trackId < 1) {
        return reply.code(400).send({ statusCode: 400, error: 'bad_request', message: 'trackId invalide.' });
      }
      const { revoked } = revokeTrack(handle, userId, trackId);
      recordAudit(handle, {
        action: 'admin.library_track_revoked',
        actorUserId: request.authUser.id,
        targetUserId: userId,
        metadata: { trackId, wasGranted: revoked },
      });
      // Le fichier physique et la ligne tracks restent intacts.
      return reply.code(revoked ? 200 : 404).send({ userId, trackId, revoked });
    },
  );
}
