import type { FastifyInstance, FastifyReply } from 'fastify';
import { eq } from 'drizzle-orm';
import type { AuthGuards } from '../auth/guards.js';
import { tracks } from '../db/schema.js';
import {
  CATALOG_MAX_LIMIT,
  isTrackPublished,
  listRecentCatalog,
} from '../library/catalog-service.js';
import { grantTrack, userCanAccessTrack } from '../library/user-library-service.js';

function badRequest(reply: FastifyReply, message: string): FastifyReply {
  return reply.code(400).send({ statusCode: 400, error: 'bad_request', message });
}

function parsePositiveInt(raw: string | undefined, fallback: number): number | null {
  if (raw === undefined) return fallback;
  const value = Number(raw);
  return Number.isInteger(value) && value >= 1 ? value : null;
}

/**
 * Catalogue GLOBAL — distinct de la bibliothèque personnelle.
 *
 * Tout compte AUTHENTIFIÉ peut consulter le catalogue et y ajouter un morceau
 * à SA bibliothèque. Aucune identité (importateur, demandeur) n'est exposée :
 * la réponse ne contient que des champs de piste + `inMyLibrary` (qui ne
 * concerne que l'appelant). Ces routes ne servent JAMAIS de bibliothèque
 * personnelle : `/api/tracks` reste filtré par `user_tracks`.
 */
export function registerCatalogRoutes(app: FastifyInstance, guards: AuthGuards): void {
  const handle = app.dbHandle;
  const requireAuth = guards.requireAuth();

  // « Ajouts récents » : les morceaux les plus récemment ajoutés au catalogue,
  // tous comptes confondus, ANONYMISÉS. Paginé et borné.
  app.get<{ Querystring: { page?: string; limit?: string } }>(
    '/api/catalog/recent',
    { preHandler: requireAuth },
    async (request, reply) => {
      const page = parsePositiveInt(request.query.page, 1);
      if (page === null) return badRequest(reply, 'page doit être un entier positif.');
      const limit = parsePositiveInt(request.query.limit, 20);
      if (limit === null || limit > CATALOG_MAX_LIMIT) {
        return badRequest(reply, `limit doit être un entier entre 1 et ${CATALOG_MAX_LIMIT}.`);
      }
      return listRecentCatalog(handle, request.authUser.id, { page, limit });
    },
  );

  // APPARTENANCE PRÉCISE : la piste est-elle dans la bibliothèque personnelle du
  // compte courant ? Source d'autorité UNIQUE = `user_tracks` (jamais le rôle,
  // ni le catalogue, ni la lecture en cours). `/api/tracks` étant paginé, il ne
  // permet pas de trancher pour une piste arbitraire : d'où cette route.
  app.get<{ Params: { trackId: string } }>(
    '/api/library/tracks/:trackId',
    { preHandler: requireAuth },
    async (request, reply) => {
      const trackId = Number(request.params.trackId);
      if (!Number.isInteger(trackId) || trackId < 1) {
        return badRequest(reply, 'trackId invalide.');
      }
      const track = handle.db
        .select({ id: tracks.id })
        .from(tracks)
        .where(eq(tracks.id, trackId))
        .get();
      if (!track) {
        return reply
          .code(404)
          .send({ statusCode: 404, error: 'not_found', message: 'Piste inconnue' });
      }
      return {
        trackId,
        inMyLibrary: userCanAccessTrack(handle, request.authUser.id, trackId),
      };
    },
  );

  // « Ajouter à ma bibliothèque » : crée UNIQUEMENT l'association user_tracks du
  // compte courant. Idempotent. Ne duplique jamais le fichier ni la ligne
  // `tracks`, et n'affecte aucun autre compte.
  app.post<{ Params: { trackId: string } }>(
    '/api/library/tracks/:trackId',
    { preHandler: requireAuth },
    async (request, reply) => {
      const trackId = Number(request.params.trackId);
      if (!Number.isInteger(trackId) || trackId < 1) {
        return badRequest(reply, 'trackId invalide.');
      }
      const track = handle.db
        .select({ id: tracks.id })
        .from(tracks)
        .where(eq(tracks.id, trackId))
        .get();
      // Piste inconnue OU non publiée au catalogue : 404 générique — on ne
      // révèle jamais l'existence d'une piste privée d'un autre compte.
      if (!track || !isTrackPublished(handle, trackId)) {
        return reply
          .code(404)
          .send({ statusCode: 404, error: 'not_found', message: 'Piste inconnue' });
      }
      const { granted } = grantTrack(handle, {
        userId: request.authUser.id,
        trackId,
        source: 'EXISTING',
        addedByUserId: request.authUser.id,
      });
      return reply.code(granted ? 201 : 200).send({
        trackId,
        inMyLibrary: true,
        added: granted,
      });
    },
  );
}
