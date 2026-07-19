import type { FastifyInstance, FastifyReply } from 'fastify';
import type { AuthGuards } from '../auth/guards.js';
import {
  NodeFetchError,
  type NodeFetchErrorCode,
  type NodeFetchService,
} from '../import/node-fetch-service.js';

const ACCEPTED_MESSAGE =
  'La requête a été envoyée au serveur et est en cours de traitement en arrière-plan.';

function statusFor(error: NodeFetchError): number {
  const statuses: Partial<Record<NodeFetchErrorCode, number>> = {
    node_fetch_disabled: 503,
    node_fetch_stopped: 503,
    node_fetch_queue_full: 429,
    node_fetch_user_busy: 429,
    source_timeout: 504,
    source_unavailable: 502,
    source_http_error: 502,
    source_redirect_invalid: 502,
    remote_response_invalid: 502,
    remote_media_origin_not_allowed: 502,
    remote_track_id_invalid: 400,
  };
  return statuses[error.code] ?? 400;
}

function sendServiceError(reply: FastifyReply, error: NodeFetchError): FastifyReply {
  const statusCode = statusFor(error);
  return reply.code(statusCode).send({
    statusCode,
    error: error.code,
    message: error.message,
  });
}

export function registerRemoteLibraryRoutes(
  app: FastifyInstance,
  guards: AuthGuards,
  service: NodeFetchService,
): void {
  app.get<{ Querystring: { q?: string } }>(
    '/api/library/search-remote',
    { preHandler: guards.requireAuth() },
    async (request, reply) => {
      const query = request.query.q?.trim() ?? '';
      if (query.length < 2 || query.length > 200) {
        return reply.code(400).send({
          statusCode: 400,
          error: 'invalid_query',
          message: 'La recherche doit contenir entre 2 et 200 caractères.',
        });
      }
      try {
        const results = await service.searchRemote(query);
        return { results };
      } catch (error) {
        if (error instanceof NodeFetchError) return sendServiceError(reply, error);
        throw error;
      }
    },
  );

  app.post<{ Body: Record<string, unknown> }>(
    '/api/library/import-remote-track',
    { preHandler: guards.requireAuth() },
    async (request, reply) => {
      const trackId = request.body?.trackId;
      if (typeof trackId !== 'string') {
        return reply.code(400).send({
          statusCode: 400,
          error: 'remote_track_id_invalid',
          message: 'Identifiant de piste distante invalide.',
        });
      }
      try {
        const job = service.enqueueRemoteTrack({
          userId: request.authUser.id,
          username: request.authUser.username,
          trackId,
        });
        return reply.code(202).send({
          accepted: true,
          message: ACCEPTED_MESSAGE,
          job,
        });
      } catch (error) {
        if (error instanceof NodeFetchError) return sendServiceError(reply, error);
        throw error;
      }
    },
  );

  app.get<{ Params: { jobId: string } }>(
    '/api/library/import-remote-track/:jobId',
    { preHandler: guards.requireAuth() },
    async (request, reply) => {
      const jobId = request.params.jobId.trim();
      if (jobId.length === 0 || jobId.length > 100) {
        return reply.code(400).send({
          statusCode: 400,
          error: 'invalid_job_id',
          message: 'Identifiant de tâche invalide.',
        });
      }
      const job = service.getJob(request.authUser.id, jobId);
      if (job === null) {
        return reply.code(404).send({
          statusCode: 404,
          error: 'job_not_found',
          message: 'Tâche inconnue.',
        });
      }
      return { job };
    },
  );
}
