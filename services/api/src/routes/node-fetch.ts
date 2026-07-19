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
    source_origin_not_allowed: 403,
    node_fetch_queue_full: 429,
    node_fetch_user_busy: 429,
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

export function registerNodeFetchRoutes(
  app: FastifyInstance,
  guards: AuthGuards,
  service: NodeFetchService,
): void {
  app.post<{ Body: Record<string, unknown> }>(
    '/api/library/fetch-node',
    { preHandler: guards.requireAuth() },
    async (request, reply) => {
      const rawUserId = request.body?.userId;
      const userId = typeof rawUserId === 'number' ? rawUserId : Number.NaN;
      if (!Number.isInteger(userId) || userId < 1) {
        return reply.code(400).send({
          statusCode: 400,
          error: 'invalid_user_id',
          message: 'userId doit être un entier positif.',
        });
      }
      // Le payload est seulement un contrôle de cohérence pour le client. La
      // destination provient TOUJOURS du token et ne peut pas être injectée.
      if (userId !== request.authUser.id) {
        return reply.code(403).send({
          statusCode: 403,
          error: 'target_user_forbidden',
          message: 'Le dossier cible doit appartenir au compte authentifié.',
        });
      }
      const url = request.body?.url;
      if (typeof url !== 'string') {
        return reply.code(400).send({
          statusCode: 400,
          error: 'invalid_source_url',
          message: 'URL source invalide.',
        });
      }
      try {
        const job = service.enqueue({
          userId: request.authUser.id,
          username: request.authUser.username,
          url,
        });
        return reply.code(202).send({ accepted: true, message: ACCEPTED_MESSAGE, job });
      } catch (error) {
        if (error instanceof NodeFetchError) return sendServiceError(reply, error);
        throw error;
      }
    },
  );

  app.get<{ Params: { jobId: string } }>(
    '/api/library/fetch-node/:jobId',
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
