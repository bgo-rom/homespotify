import type { FastifyInstance, FastifyReply } from 'fastify';
import type { AuthGuards } from '../auth/guards.js';
import { IMPORT_JOB_STATUSES, type ImportJobStatus } from '../db/schema.js';
import { UserImportError, UserImportService } from '../import/user-import-service.js';

function badRequest(reply: FastifyReply, message: string): FastifyReply {
  return reply.code(400).send({ statusCode: 400, error: 'bad_request', message });
}

function parseId(reply: FastifyReply, raw: string): number | null {
  const id = Number(raw);
  if (!Number.isInteger(id) || id < 1) {
    badRequest(reply, 'Identifiant invalide.');
    return null;
  }
  return id;
}

function sendImportError(reply: FastifyReply, error: UserImportError): FastifyReply {
  const statusCode = error.code.endsWith('not_found') ? 404 : 409;
  return reply.code(statusCode).send({
    statusCode,
    error: error.code,
    message: error.message,
  });
}

/** Administration OWNER des imports locaux. Aucune route utilisateur ne peut
 * lire les dossiers ou jobs d'un autre compte. */
export function registerImportRoutes(
  app: FastifyInstance,
  guards: AuthGuards,
  service: UserImportService,
): void {
  const ownerOnly = guards.requireAdmin('music_request.review');

  app.get<{ Querystring: { userId?: string; status?: string } }>(
    '/api/admin/imports',
    { preHandler: ownerOnly },
    async (request, reply) => {
      const userId = request.query.userId === undefined ? undefined : Number(request.query.userId);
      if (userId !== undefined && (!Number.isInteger(userId) || userId < 1)) {
        return badRequest(reply, 'userId invalide.');
      }
      const status = request.query.status;
      if (status !== undefined && !(IMPORT_JOB_STATUSES as readonly string[]).includes(status)) {
        return badRequest(reply, 'status invalide.');
      }
      return {
        items: service.listJobs({
          ...(userId !== undefined ? { userId } : {}),
          ...(status !== undefined ? { status: status as ImportJobStatus } : {}),
        }),
      };
    },
  );

  app.post<{ Params: { id: string } }>(
    '/api/admin/imports/:id/retry',
    { preHandler: ownerOnly },
    async (request, reply) => {
      const id = parseId(reply, request.params.id);
      if (id === null) return reply;
      try {
        await service.retryJob(id, request.authUser.id);
        return reply.code(202).send({ accepted: true });
      } catch (error) {
        if (error instanceof UserImportError) return sendImportError(reply, error);
        throw error;
      }
    },
  );

  app.post<{ Params: { id: string } }>(
    '/api/admin/imports/:id/reject',
    { preHandler: ownerOnly },
    async (request, reply) => {
      const id = parseId(reply, request.params.id);
      if (id === null) return reply;
      try {
        await service.rejectJob(id, request.authUser.id);
        return { rejected: true };
      } catch (error) {
        if (error instanceof UserImportError) return sendImportError(reply, error);
        throw error;
      }
    },
  );

  app.post<{ Params: { id: string }; Body: Record<string, unknown> }>(
    '/api/admin/imports/:id/assign',
    { preHandler: ownerOnly },
    async (request, reply) => {
      const id = parseId(reply, request.params.id);
      if (id === null) return reply;
      const itemId = Number(request.body?.itemId);
      const trackId = Number(request.body?.trackId);
      if (!Number.isInteger(itemId) || itemId < 1 || !Number.isInteger(trackId) || trackId < 1) {
        return badRequest(reply, 'itemId et trackId doivent être des entiers positifs.');
      }
      try {
        service.assignJob(id, itemId, trackId, request.authUser.id);
        return { assigned: true };
      } catch (error) {
        if (error instanceof UserImportError) return sendImportError(reply, error);
        throw error;
      }
    },
  );
}
