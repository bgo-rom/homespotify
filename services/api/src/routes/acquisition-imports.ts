import type {
  FastifyInstance,
  FastifyReply,
} from 'fastify';
import type { AuthGuards } from '../auth/guards.js';
import {
  ACQUISITION_JOB_STATUSES,
  type AcquisitionJobStatus,
} from '../db/schema.js';
import {
  AcquisitionImportService,
  AcquisitionImportServiceError,
} from '../import/acquisition-import-service.js';
import {
  AcquisitionJobRepositoryError,
  type AcquisitionJobRow,
} from '../import/acquisition-job-repository.js';
import {
  LucidaProcessError,
  type LucidaRunResult,
  type LucidaSearchRunRequest,
} from '../import/lucida-process-runner.js';

const MAX_QUERY_LENGTH = 200;
const MAX_RESULT_INDEX = 100;
const MAX_DOWNLOAD_TIMEOUT_SECONDS = 300;
const MAX_DOWNLOAD_RETRIES = 9;
const DEFAULT_LIST_LIMIT = 20;
const MAX_LIST_LIMIT = 100;
const DEFAULT_SEARCH_TIMEOUT_MS = 45_000;
const MAX_SEARCH_RESULTS = 100;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/;

export interface LucidaSearchRunner {
  run(request: LucidaSearchRunRequest): Promise<LucidaRunResult>;
}

export interface AcquisitionImportRouteDependencies {
  service: AcquisitionImportService | null;
  searchRunner: LucidaSearchRunner | null;
  /** Injectable uniquement pour les tests ; 45 s par défaut. */
  searchTimeoutMs?: number;
}

interface CreateJobBody {
  query?: unknown;
  resultIndex?: unknown;
  service?: unknown;
  downloadTimeoutSeconds?: unknown;
  downloadRetries?: unknown;
}

interface SearchBody {
  query?: unknown;
}

function sendError(
  reply: FastifyReply,
  statusCode: number,
  error: string,
  message: string,
): FastifyReply {
  return reply.code(statusCode).send({
    statusCode,
    error,
    message,
  });
}

function unavailable(reply: FastifyReply): FastifyReply {
  return sendError(
    reply,
    503,
    'feature_unavailable',
    'L’acquisition distante n’est pas configurée sur ce serveur.',
  );
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (
    typeof value !== 'object' ||
    value === null ||
    Array.isArray(value)
  ) {
    return null;
  }
  return value as Record<string, unknown>;
}

function parseQuery(
  reply: FastifyReply,
  value: unknown,
): string | null {
  if (typeof value !== 'string') {
    sendError(
      reply,
      400,
      'bad_request',
      'query est obligatoire et doit être une chaîne.',
    );
    return null;
  }

  const query = value.trim().replace(/\s+/g, ' ');
  if (!query) {
    sendError(
      reply,
      400,
      'bad_request',
      'query ne peut pas être vide.',
    );
    return null;
  }
  if (query.length > MAX_QUERY_LENGTH) {
    sendError(
      reply,
      400,
      'bad_request',
      `query ne peut pas dépasser ${MAX_QUERY_LENGTH} caractères.`,
    );
    return null;
  }
  if (CONTROL_CHARACTERS.test(value)) {
    sendError(
      reply,
      400,
      'bad_request',
      'query contient un caractère de contrôle interdit.',
    );
    return null;
  }

  return query;
}

function parseInteger(
  reply: FastifyReply,
  field: string,
  value: unknown,
  min: number,
  max: number,
  fallback?: number,
): number | null {
  if (value === undefined && fallback !== undefined) return fallback;
  if (
    !Number.isInteger(value) ||
    (value as number) < min ||
    (value as number) > max
  ) {
    sendError(
      reply,
      400,
      'bad_request',
      `${field} doit être un entier compris entre ${min} et ${max}.`,
    );
    return null;
  }
  return value as number;
}

function parseLimit(
  reply: FastifyReply,
  raw: string | undefined,
): number | null {
  if (raw === undefined) return DEFAULT_LIST_LIMIT;
  if (!/^\d+$/.test(raw)) {
    sendError(
      reply,
      400,
      'bad_request',
      `limit doit être un entier compris entre 1 et ${MAX_LIST_LIMIT}.`,
    );
    return null;
  }
  const limit = Number(raw);
  if (limit < 1 || limit > MAX_LIST_LIMIT) {
    sendError(
      reply,
      400,
      'bad_request',
      `limit doit être un entier compris entre 1 et ${MAX_LIST_LIMIT}.`,
    );
    return null;
  }
  return limit;
}

function parseStatus(
  reply: FastifyReply,
  raw: string | undefined,
): AcquisitionJobStatus | null | undefined {
  if (raw === undefined) return undefined;
  if (
    !(ACQUISITION_JOB_STATUSES as readonly string[]).includes(raw)
  ) {
    sendError(
      reply,
      400,
      'bad_request',
      'status d’acquisition invalide.',
    );
    return null;
  }
  return raw as AcquisitionJobStatus;
}

function publicFailureMessage(job: AcquisitionJobRow): string | null {
  if (job.errorCode === null) return null;

  switch (job.errorCode) {
    case 'CANCELLED':
      return 'Import annulé.';
    case 'SERVER_RESTART':
      return 'Import interrompu par un redémarrage du serveur.';
    case 'SERVER_SHUTDOWN':
      return 'Import interrompu par l’arrêt du serveur.';
    case 'NO_RESULTS':
      return 'Aucun résultat trouvé.';
    case 'NO_EXACT_MATCH':
      return 'Aucune correspondance exacte n’a été trouvée.';
    case 'LOCAL_IMPORT_REVIEW_REQUIRED':
      return 'Une validation manuelle du propriétaire est nécessaire.';
    case 'LOCAL_IMPORT_REJECTED':
      return 'Le fichier a été rejeté par le pipeline local.';
    case 'LOCAL_IMPORT_FAILED':
    case 'LOCAL_IMPORT_INCOMPLETE':
    case 'LOCAL_IMPORT_JOB_MISSING':
    case 'LOCAL_IMPORT_TRACK_MISSING':
      return 'L’ajout du fichier dans la bibliothèque a échoué.';
    case 'TIMEOUT':
      return 'L’acquisition a dépassé le délai autorisé.';
    default:
      return 'L’acquisition a échoué.';
  }
}

function publicMessage(job: AcquisitionJobRow): string | null {
  if (
    job.status === 'FAILED' ||
    job.status === 'CANCELLED' ||
    job.status === 'INTERRUPTED'
  ) {
    return publicFailureMessage(job);
  }
  return job.message;
}

function publicJob(job: AcquisitionJobRow) {
  return {
    id: job.id,
    query: job.query,
    provider: 'Qobuz' as const,
    resultIndex: job.resultIndex,
    status: job.status,
    stage: job.stage,
    progress: job.progress,
    message: publicMessage(job),
    selectedTitle: job.selectedTitle,
    selectedArtist: job.selectedArtist,
    selectedAlbum: job.selectedAlbum,
    selectedDurationSeconds: job.selectedDurationSeconds,
    attempt: job.attempt,
    maxAttempts: job.maxAttempts,
    cancelRequested: job.cancelRequested,
    finalTrackId: job.trackId,
    errorCode: job.errorCode,
    errorMessage: publicFailureMessage(job),
    createdAt: job.createdAt,
    updatedAt: job.updatedAt,
    startedAt: job.startedAt,
    completedAt: job.completedAt,
  };
}

function sendServiceError(
  reply: FastifyReply,
  error: AcquisitionImportServiceError | AcquisitionJobRepositoryError,
): FastifyReply {
  switch (error.code) {
    case 'invalid_input':
      return sendError(reply, 400, error.code, error.message);

    case 'active_duplicate':
      return sendError(reply, 409, error.code, error.message);

    case 'job_not_found':
      return sendError(reply, 404, error.code, error.message);

    case 'service_stopped':
      return sendError(reply, 503, error.code, error.message);

    default:
      return sendError(
        reply,
        500,
        'internal_error',
        'Erreur interne du service d’acquisition.',
      );
  }
}

function sendSearchError(
  reply: FastifyReply,
  error: LucidaProcessError,
  timedOut: boolean,
): FastifyReply {
  if (timedOut || error.code === 'TIMEOUT') {
    return sendError(
      reply,
      504,
      'search_timeout',
      'La recherche a dépassé le délai autorisé.',
    );
  }

  if (
    error.code === 'INVALID_REQUEST' ||
    error.code === 'INVALID_ARGUMENT'
  ) {
    return sendError(reply, 400, 'bad_request', error.message);
  }

  return sendError(
    reply,
    502,
    'external_tool_error',
    'La recherche distante a échoué.',
  );
}

/**
 * Routes utilisateur de recherche et d’acquisition.
 *
 * Aucun chemin de fichier, clé de déduplication, stderr Python ou identifiant
 * d’un autre utilisateur n’est exposé.
 */
export function registerAcquisitionImportRoutes(
  app: FastifyInstance,
  guards: AuthGuards,
  dependencies: AcquisitionImportRouteDependencies,
): void {
  const authenticated = guards.requireAuth();
  const searchTimeoutMs =
    dependencies.searchTimeoutMs ?? DEFAULT_SEARCH_TIMEOUT_MS;

  if (
    !Number.isInteger(searchTimeoutMs) ||
    searchTimeoutMs < 10 ||
    searchTimeoutMs > 5 * 60 * 1000
  ) {
    throw new Error(
      'searchTimeoutMs doit être un entier compris entre 10 et 300000.',
    );
  }

  app.post<{ Body: SearchBody }>(
    '/api/imports/search',
    { preHandler: authenticated },
    async (request, reply) => {
      const runner = dependencies.searchRunner;
      if (!runner) return unavailable(reply);

      const body = asRecord(request.body);
      if (!body) {
        return sendError(
          reply,
          400,
          'bad_request',
          'Le corps JSON est obligatoire.',
        );
      }

      const query = parseQuery(reply, body.query);
      if (query === null) return reply;

      const controller = new AbortController();
      let timedOut = false;
      const timer = setTimeout(() => {
        timedOut = true;
        controller.abort();
      }, searchTimeoutMs);

      try {
        const result = await runner.run({
          mode: 'search',
          query,
          signal: controller.signal,
        });

        if (result.mode !== 'search') {
          throw new LucidaProcessError(
            'PROTOCOL_ERROR',
            'Le runner a retourné un téléchargement pendant une recherche.',
          );
        }

        return {
          results: result.results
            .slice(0, MAX_SEARCH_RESULTS)
            .map((item) => ({
              index: item.index,
              title: item.title,
              artist: item.artist,
              album: item.album,
              duration: item.duration,
            })),
        };
      } catch (error) {
        if (
          error instanceof LucidaProcessError &&
          error.code === 'NO_RESULTS'
        ) {
          return { results: [] };
        }
        if (error instanceof LucidaProcessError) {
          return sendSearchError(reply, error, timedOut);
        }
        throw error;
      } finally {
        clearTimeout(timer);
      }
    },
  );

  app.post<{ Body: CreateJobBody }>(
    '/api/imports/jobs',
    { preHandler: authenticated },
    async (request, reply) => {
      const acquisitionService = dependencies.service;
      if (!acquisitionService) return unavailable(reply);

      const body = asRecord(request.body);
      if (!body) {
        return sendError(
          reply,
          400,
          'bad_request',
          'Le corps JSON est obligatoire.',
        );
      }

      const query = parseQuery(reply, body.query);
      if (query === null) return reply;

      const resultIndex = parseInteger(
        reply,
        'resultIndex',
        body.resultIndex,
        0,
        MAX_RESULT_INDEX,
      );
      if (resultIndex === null) return reply;

      if (
        body.service !== undefined &&
        (
          typeof body.service !== 'string' ||
          body.service.trim().toLocaleLowerCase('fr-FR') !== 'qobuz'
        )
      ) {
        return sendError(
          reply,
          400,
          'bad_request',
          'Seul le service Qobuz est autorisé.',
        );
      }

      const downloadTimeoutSeconds = parseInteger(
        reply,
        'downloadTimeoutSeconds',
        body.downloadTimeoutSeconds,
        10,
        MAX_DOWNLOAD_TIMEOUT_SECONDS,
        75,
      );
      if (downloadTimeoutSeconds === null) return reply;

      const downloadRetries = parseInteger(
        reply,
        'downloadRetries',
        body.downloadRetries,
        0,
        MAX_DOWNLOAD_RETRIES,
        2,
      );
      if (downloadRetries === null) return reply;

      try {
        const job = acquisitionService.enqueue({
          userId: request.authUser.id,
          username: request.authUser.username,
          query,
          resultIndex,
          downloadTimeoutSeconds,
          downloadRetries,
        });

        request.log.info(
          {
            jobId: job.id,
            userId: request.authUser.id,
          },
          'ACQUISITION_IMPORT_QUEUED',
        );

        return reply.code(202).send({
          accepted: true,
          item: publicJob(job),
        });
      } catch (error) {
        if (
          error instanceof AcquisitionImportServiceError ||
          error instanceof AcquisitionJobRepositoryError
        ) {
          return sendServiceError(reply, error);
        }
        throw error;
      }
    },
  );

  app.get<{
    Querystring: {
      limit?: string;
      status?: string;
    };
  }>(
    '/api/imports/jobs',
    { preHandler: authenticated },
    async (request, reply) => {
      const acquisitionService = dependencies.service;
      if (!acquisitionService) return unavailable(reply);

      const limit = parseLimit(reply, request.query.limit);
      if (limit === null) return reply;

      const status = parseStatus(reply, request.query.status);
      if (status === null) return reply;

      return {
        items: acquisitionService
          .listRecentForUser(
            request.authUser.id,
            limit,
            status,
          )
          .map(publicJob),
      };
    },
  );

  app.get<{ Params: { id: string } }>(
    '/api/imports/jobs/:id',
    { preHandler: authenticated },
    async (request, reply) => {
      const acquisitionService = dependencies.service;
      if (!acquisitionService) return unavailable(reply);

      if (!UUID_PATTERN.test(request.params.id)) {
        return sendError(
          reply,
          400,
          'bad_request',
          'Identifiant de job invalide.',
        );
      }

      const job = acquisitionService.getJobForUser(
        request.params.id,
        request.authUser.id,
      );
      if (!job) {
        return sendError(
          reply,
          404,
          'job_not_found',
          'Job d’acquisition introuvable.',
        );
      }

      return { item: publicJob(job) };
    },
  );

  app.delete<{ Params: { id: string } }>(
    '/api/imports/jobs/:id',
    { preHandler: authenticated },
    async (request, reply) => {
      const acquisitionService = dependencies.service;
      if (!acquisitionService) return unavailable(reply);

      if (!UUID_PATTERN.test(request.params.id)) {
        return sendError(
          reply,
          400,
          'bad_request',
          'Identifiant de job invalide.',
        );
      }

      const existing = acquisitionService.getJobForUser(
        request.params.id,
        request.authUser.id,
      );
      if (!existing) {
        return sendError(
          reply,
          404,
          'job_not_found',
          'Job d’acquisition introuvable.',
        );
      }

      try {
        const accepted = acquisitionService.cancel(
          request.params.id,
          request.authUser.id,
        );
        const current =
          acquisitionService.getJobForUser(
            request.params.id,
            request.authUser.id,
          ) ?? existing;

        return reply.code(accepted ? 202 : 200).send({
          accepted,
          jobId: current.id,
          status: current.status,
        });
      } catch (error) {
        if (
          error instanceof AcquisitionImportServiceError ||
          error instanceof AcquisitionJobRepositoryError
        ) {
          return sendServiceError(reply, error);
        }
        throw error;
      }
    },
  );
}
