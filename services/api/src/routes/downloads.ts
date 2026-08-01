import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import type { AuthGuards } from '../auth/guards.js';
import { DOWNLOAD_JOB_STATUSES, type DownloadJobStatus } from '../db/schema.js';
import type { DownloadJobRow } from '../download/download-job-repository.js';
import {
  DownloadService,
  DownloadServiceError,
  type DownloadJobEvent,
} from '../download/download-service.js';
import {
  parseDownloadUrl,
  SUPPORTED_DOWNLOAD_SERVICES,
} from '../download/download-url.js';
import { TrackSearchError } from '../download/track-search.js';

const DEFAULT_LIST_LIMIT = 20;
const MAX_LIST_LIMIT = 100;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** Battement SSE : garde le flux ouvert derrière un proxy inactif. */
const SSE_HEARTBEAT_MS = 15_000;

export interface DownloadRouteDependencies {
  service: DownloadService | null;
}

interface CreateDownloadBody {
  url?: unknown;
  source?: unknown;
  format?: unknown;
}

interface SearchDownloadBody {
  query?: unknown;
  title?: unknown;
  artist?: unknown;
  album?: unknown;
  isrc?: unknown;
  durationSeconds?: unknown;
}

/** ISRC : 2 lettres pays, 3 alphanumériques d'inscrit, 5 chiffres année+série. */
const ISRC_PATTERN = /^[A-Z]{2}[A-Z0-9]{3}\d{7}$/;
/** Borne haute volontairement large (mix DJ), mais finie. */
const MAX_TRACK_DURATION_SECONDS = 7200;

const MIN_SEARCH_QUERY_LENGTH = 2;
const MAX_SEARCH_QUERY_LENGTH = 200;

/**
 * Vue publique d'une piste résolue : ce que l'application affiche pour choisir.
 * Les URL exposées sont celles, publiques, des catalogues — jamais un chemin
 * serveur ni un token.
 */
function publicResolvedTrack(track: {
  canonicalKey: string;
  title: string;
  artist: string;
  album: string | null;
  durationSeconds: number | null;
  isrc: string | null;
  confidence: number;
  artworkUrl: string | null;
  candidates: ReadonlyArray<{
    provider: string;
    url: string;
    sourceRank: number;
  }>;
}): Record<string, unknown> {
  return {
    key: track.canonicalKey,
    title: track.title,
    artist: track.artist,
    album: track.album,
    durationSeconds: track.durationSeconds,
    isrc: track.isrc,
    confidence: track.confidence,
    artworkUrl: track.artworkUrl,
    // L'application a besoin de l'URL du meilleur candidat pour pouvoir
    // relancer explicitement son choix via POST /api/downloads.
    downloadUrl: track.candidates[0]?.url ?? null,
    sources: track.candidates.map((candidate) => candidate.provider),
  };
}

function parseSearchQuery(reply: FastifyReply, raw: unknown): string | null {
  if (typeof raw !== 'string') {
    sendError(reply, 400, 'bad_request', 'query est obligatoire.');
    return null;
  }
  const query = raw.trim().replace(/\s+/g, ' ');
  if (query.length < MIN_SEARCH_QUERY_LENGTH) {
    sendError(
      reply,
      400,
      'bad_request',
      `query doit contenir au moins ${MIN_SEARCH_QUERY_LENGTH} caractères.`,
    );
    return null;
  }
  if (query.length > MAX_SEARCH_QUERY_LENGTH) {
    sendError(
      reply,
      400,
      'bad_request',
      `query ne peut pas dépasser ${MAX_SEARCH_QUERY_LENGTH} caractères.`,
    );
    return null;
  }
  // eslint-disable-next-line no-control-regex
  if (/[\u0000-\u001f\u007f]/.test(raw)) {
    sendError(reply, 400, 'bad_request', 'query contient un caractère interdit.');
    return null;
  }
  return query;
}

/** `undefined` = absent ; `null` = invalide (réponse déjà envoyée). */
function parseOptionalText(
  reply: FastifyReply,
  field: string,
  raw: unknown,
): string | undefined | null {
  if (raw === undefined || raw === null) return undefined;
  if (typeof raw !== 'string') {
    sendError(reply, 400, 'bad_request', `${field} doit être une chaîne.`);
    return null;
  }
  const value = raw.trim().replace(/\s+/g, ' ');
  if (value.length === 0) return undefined;
  if (value.length > MAX_SEARCH_QUERY_LENGTH) {
    sendError(reply, 400, 'bad_request', `${field} est trop long.`);
    return null;
  }
  return value;
}

/**
 * ISRC facultatif. `undefined` = absent ; `null` = invalide (réponse envoyée).
 *
 * Un ISRC malformé n'est pas silencieusement ignoré : c'est la preuve
 * d'identité la plus forte du résolveur, et l'accepter dégradé reviendrait à
 * télécharger une autre piste que celle affichée à l'écran.
 */
function parseOptionalIsrc(
  reply: FastifyReply,
  raw: unknown,
): string | undefined | null {
  if (raw === undefined || raw === null) return undefined;
  if (typeof raw !== 'string') {
    sendError(reply, 400, 'bad_request', 'isrc doit être une chaîne.');
    return null;
  }
  const value = raw.trim().replace(/[\s-]/g, '').toUpperCase();
  if (value.length === 0) return undefined;
  if (!ISRC_PATTERN.test(value)) {
    sendError(reply, 400, 'bad_request', 'isrc est invalide.');
    return null;
  }
  return value;
}

/** Durée facultative en secondes. `null` = invalide (réponse envoyée). */
function parseOptionalDuration(
  reply: FastifyReply,
  raw: unknown,
): number | undefined | null {
  if (raw === undefined || raw === null) return undefined;
  if (typeof raw !== 'number' || !Number.isFinite(raw)) {
    sendError(reply, 400, 'bad_request', 'durationSeconds doit être un nombre.');
    return null;
  }
  const value = Math.round(raw);
  if (value <= 0 || value > MAX_TRACK_DURATION_SECONDS) {
    sendError(
      reply,
      400,
      'bad_request',
      `durationSeconds doit être compris entre 1 et ${MAX_TRACK_DURATION_SECONDS}.`,
    );
    return null;
  }
  return value;
}

function sendError(
  reply: FastifyReply,
  statusCode: number,
  error: string,
  message: string,
): FastifyReply {
  return reply.code(statusCode).send({ statusCode, error, message });
}

function unavailable(reply: FastifyReply): FastifyReply {
  return sendError(
    reply,
    503,
    'feature_unavailable',
    'Le moteur de téléchargement n’est pas configuré sur ce serveur.',
  );
}

function asRecord(value: unknown): Record<string, unknown> | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null;
  return value as Record<string, unknown>;
}

/**
 * Vue publique d'un job.
 *
 * N'expose JAMAIS : chemin absolu, PID, commande, `stderr`, clé Premium,
 * identifiant d'un autre compte. `outputPath` est volontairement absent :
 * l'application n'a aucun usage d'un chemin serveur.
 */
export function publicDownloadJob(job: DownloadJobRow): Record<string, unknown> {
  return {
    id: job.id,
    provider: job.provider,
    url: job.requestedUrl,
    status: job.status,
    stage: job.stage,
    progress: job.progress,
    message: job.message,
    title: job.title,
    artist: job.artist,
    album: job.album,
    source: job.source,
    quality: job.quality,
    // Catalogue de l'URL en cours d'essai (`spotify`, `deezer`…). Ce n'est ni
    // un secret ni un chemin : c'est ce qui rend un repli lisible à l'écran.
    attemptedSource: job.selectedProvider,
    requestKind: job.requestKind,
    query: job.query,
    attempt: job.attempt,
    maxAttempts: job.maxAttempts,
    cancelRequested: job.cancelRequested,
    // Succès par réutilisation d'une piste déjà indexée : ce n'est pas un
    // échec, et l'application l'annonce différemment.
    reused: job.status === 'completed' && job.stage === 'reused',
    trackId: job.trackId,
    errorCode: job.errorCode,
    errorMessage: job.errorMessage,
    createdAt: job.createdAt,
    updatedAt: job.updatedAt,
    startedAt: job.startedAt,
    completedAt: job.completedAt,
  };
}

function sendServiceError(
  reply: FastifyReply,
  error: DownloadServiceError,
): FastifyReply {
  switch (error.code) {
    case 'invalid_input':
      return sendError(reply, 400, error.code, error.message);
    case 'active_duplicate':
      return sendError(reply, 409, error.code, error.message);
    case 'not_retryable':
      return sendError(reply, 409, error.code, error.message);
    case 'job_not_found':
      return sendError(reply, 404, error.code, error.message);
    case 'service_stopped':
    case 'search_unavailable':
      return sendError(reply, 503, error.code, error.message);
    default:
      return sendError(
        reply,
        500,
        'internal_error',
        'Erreur interne du service de téléchargement.',
      );
  }
}

function parseJobId(reply: FastifyReply, raw: string | undefined): string | null {
  if (typeof raw !== 'string' || !UUID_PATTERN.test(raw)) {
    sendError(reply, 400, 'bad_request', 'Identifiant de téléchargement invalide.');
    return null;
  }
  return raw;
}

function parseLimit(reply: FastifyReply, raw: string | undefined): number | null {
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
): DownloadJobStatus | null | undefined {
  if (raw === undefined) return undefined;
  if (!(DOWNLOAD_JOB_STATUSES as readonly string[]).includes(raw)) {
    sendError(reply, 400, 'bad_request', 'status de téléchargement invalide.');
    return null;
  }
  return raw as DownloadJobStatus;
}

/**
 * Routes utilisateur du moteur de téléchargement.
 *
 * Toutes exigent une authentification et sont strictement cloisonnées par
 * compte : un utilisateur ne voit et n'agit que sur SES téléchargements. Le
 * backend ne fait aucune différence entre « job inexistant » et « job d'un
 * autre compte » — les deux répondent 404.
 */
export function registerDownloadRoutes(
  app: FastifyInstance,
  guards: AuthGuards,
  dependencies: DownloadRouteDependencies,
): void {
  const authenticated = guards.requireAuth();

  app.post<{ Body: CreateDownloadBody }>(
    '/api/downloads',
    { preHandler: authenticated },
    async (request, reply) => {
      const service = dependencies.service;
      if (!service) return unavailable(reply);

      const body = asRecord(request.body);
      if (!body) {
        return sendError(reply, 400, 'bad_request', 'Le corps JSON est obligatoire.');
      }

      const parsed = parseDownloadUrl(body.url);
      if (!parsed.ok) {
        return reply.code(400).send({
          statusCode: 400,
          error: 'bad_request',
          message: parsed.message,
          reasonCode: parsed.code,
          supportedServices: SUPPORTED_DOWNLOAD_SERVICES,
        });
      }

      // `source` et `format` sont acceptés pour la compatibilité du contrat,
      // mais seule la configuration serveur décide : l'application ne choisit
      // pas ce que le moteur exécute.
      if (
        body.source !== undefined &&
        (typeof body.source !== 'string' || body.source.trim().toLowerCase() !== 'auto')
      ) {
        return sendError(
          reply,
          400,
          'bad_request',
          'source doit valoir "auto" : la source est décidée par le serveur.',
        );
      }
      if (
        body.format !== undefined &&
        (typeof body.format !== 'string' || body.format.trim().toLowerCase() !== 'flac')
      ) {
        return sendError(
          reply,
          400,
          'bad_request',
          'format doit valoir "flac" : le format est décidé par le serveur.',
        );
      }

      try {
        const job = service.enqueue({
          userId: request.authUser.id,
          username: request.authUser.username,
          requestedUrl: parsed.requestedUrl,
          normalizedUrl: parsed.normalizedUrl,
        });
        // Journal volontairement minimal : ni URL complète, ni commande.
        request.log.info(
          { jobId: job.id, userId: request.authUser.id, host: parsed.host },
          'DOWNLOAD_JOB_QUEUED',
        );
        return reply.code(202).send({
          jobId: job.id,
          status: job.status,
          item: publicDownloadJob(job),
        });
      } catch (error) {
        if (error instanceof DownloadServiceError) return sendServiceError(reply, error);
        throw error;
      }
    },
  );

  /**
   * Recherche musicale puis téléchargement.
   *
   * Antra ne sait pas rechercher : le texte est résolu en URL candidates par le
   * catalogue de découverte existant. Quand une piste se détache, un job normal
   * est créé (202) ; sinon la liste est renvoyée (200) pour que l'utilisateur
   * tranche, plutôt que d'importer arbitrairement une mauvaise piste.
   */
  app.post<{ Body: SearchDownloadBody }>(
    '/api/downloads/search',
    { preHandler: authenticated },
    async (request, reply) => {
      const service = dependencies.service;
      if (!service) return unavailable(reply);

      const body = asRecord(request.body);
      if (!body) {
        return sendError(reply, 400, 'bad_request', 'Le corps JSON est obligatoire.');
      }

      const title = parseOptionalText(reply, 'title', body.title);
      if (title === null) return reply;
      const artist = parseOptionalText(reply, 'artist', body.artist);
      if (artist === null) return reply;
      const album = parseOptionalText(reply, 'album', body.album);
      if (album === null) return reply;
      const isrc = parseOptionalIsrc(reply, body.isrc);
      if (isrc === null) return reply;
      const durationSeconds = parseOptionalDuration(reply, body.durationSeconds);
      if (durationSeconds === null) return reply;

      // `query` seul, ou reconstruit depuis title + artist : l'appelant peut
      // fournir l'un ou l'autre.
      const rawQuery =
        typeof body.query === 'string' && body.query.trim().length > 0
          ? body.query
          : [artist, title].filter(Boolean).join(' ');
      const query = parseSearchQuery(reply, rawQuery);
      if (query === null) return reply;

      try {
        const outcome = await service.enqueueFromSearch({
          userId: request.authUser.id,
          username: request.authUser.username,
          query,
          title,
          artist,
          album,
          isrc,
          durationSeconds,
        });

        if (outcome.kind === 'no_match') {
          return reply.code(200).send({
            resolution: 'no_match',
            query,
            candidates: [],
            message: 'Aucune piste correspondante n’a été trouvée.',
          });
        }
        if (outcome.kind === 'ambiguous') {
          // Aucun job créé : l'utilisateur choisit.
          return reply.code(200).send({
            resolution: 'ambiguous',
            query,
            candidates: outcome.options.map(publicResolvedTrack),
            message: 'Plusieurs pistes correspondent : choisis la bonne.',
          });
        }

        request.log.info(
          {
            jobId: outcome.job.id,
            userId: request.authUser.id,
            candidates: outcome.track.candidates.length,
          },
          'DOWNLOAD_SEARCH_QUEUED',
        );
        return reply.code(202).send({
          resolution: 'queued',
          jobId: outcome.job.id,
          status: outcome.job.status,
          item: publicDownloadJob(outcome.job),
          track: publicResolvedTrack(outcome.track),
        });
      } catch (error) {
        if (error instanceof DownloadServiceError) return sendServiceError(reply, error);
        if (error instanceof TrackSearchError) {
          return sendError(
            reply,
            error.code === 'provider_unavailable' ? 503 : 502,
            error.code,
            error.message,
          );
        }
        throw error;
      }
    },
  );

  app.get<{ Querystring: { limit?: string; status?: string } }>(
    '/api/downloads',
    { preHandler: authenticated },
    async (request, reply) => {
      const service = dependencies.service;
      if (!service) return unavailable(reply);

      const limit = parseLimit(reply, request.query.limit);
      if (limit === null) return reply;
      const status = parseStatus(reply, request.query.status);
      if (status === null) return reply;

      try {
        const jobs = service.listRecentForUser(request.authUser.id, limit, status);
        return { items: jobs.map(publicDownloadJob) };
      } catch (error) {
        if (error instanceof DownloadServiceError) return sendServiceError(reply, error);
        throw error;
      }
    },
  );

  // Déclarée AVANT `/api/downloads/:id` n'est pas nécessaire avec Fastify
  // (routage par arbre, les segments statiques gagnent), mais l'ordre reste
  // lisible pour un humain.
  app.get(
    '/api/downloads/health',
    { preHandler: authenticated },
    async (_request, reply) => {
      const service = dependencies.service;
      if (!service) {
        return reply.code(200).send({
          available: false,
          configured: false,
          pythonFound: false,
          antraImportable: false,
          outputWritable: false,
          premiumKeyConfigured: false,
          soulseekDisabled: true,
          detail: 'Moteur de téléchargement non configuré sur ce serveur.',
          checkedAt: new Date().toISOString(),
        });
      }

      const health = await service.health();
      // `premiumKeyConfigured` est un BOOLÉEN strict : ni la clé, ni sa
      // longueur, ni son préfixe ne sortent jamais d'ici.
      return {
        available: health.available,
        configured: true,
        pythonFound: health.pythonFound,
        antraImportable: health.antraImportable,
        outputWritable: health.outputWritable,
        premiumKeyConfigured: health.premiumKeyConfigured,
        soulseekDisabled: health.soulseekDisabled,
        detail: health.detail,
        checkedAt: health.checkedAt,
        queued: service.queuedCount(),
        active: service.activeCount(),
      };
    },
  );

  app.get<{ Params: { id: string } }>(
    '/api/downloads/:id',
    { preHandler: authenticated },
    async (request, reply) => {
      const service = dependencies.service;
      if (!service) return unavailable(reply);

      const jobId = parseJobId(reply, request.params.id);
      if (jobId === null) return reply;

      const job = service.getJobForUser(jobId, request.authUser.id);
      if (!job) {
        return sendError(reply, 404, 'job_not_found', 'Téléchargement introuvable.');
      }
      return { item: publicDownloadJob(job) };
    },
  );

  app.delete<{ Params: { id: string } }>(
    '/api/downloads/:id',
    { preHandler: authenticated },
    async (request, reply) => {
      const service = dependencies.service;
      if (!service) return unavailable(reply);

      const jobId = parseJobId(reply, request.params.id);
      if (jobId === null) return reply;

      try {
        const accepted = await service.cancel(jobId, request.authUser.id);
        const job = service.getJobForUser(jobId, request.authUser.id);
        if (!job) {
          return sendError(reply, 404, 'job_not_found', 'Téléchargement introuvable.');
        }
        // 202 = annulation enregistrée ; 200 = rien à annuler (déjà terminal).
        return reply.code(accepted ? 202 : 200).send({
          accepted,
          jobId,
          status: job.status,
          item: publicDownloadJob(job),
        });
      } catch (error) {
        if (error instanceof DownloadServiceError) return sendServiceError(reply, error);
        throw error;
      }
    },
  );

  app.post<{ Params: { id: string } }>(
    '/api/downloads/:id/retry',
    { preHandler: authenticated },
    async (request, reply) => {
      const service = dependencies.service;
      if (!service) return unavailable(reply);

      const jobId = parseJobId(reply, request.params.id);
      if (jobId === null) return reply;

      try {
        const job = service.retry(
          jobId,
          request.authUser.id,
          request.authUser.username,
        );
        return reply.code(202).send({
          jobId: job.id,
          status: job.status,
          item: publicDownloadJob(job),
        });
      } catch (error) {
        if (error instanceof DownloadServiceError) return sendServiceError(reply, error);
        throw error;
      }
    },
  );

  /**
   * Flux temps réel (SSE).
   *
   * SSE et non WebSocket : aucun WebSocket n'existe dans HomeSpotify, et un
   * flux unidirectionnel suffit. Les logs bruts du moteur ne sont pas renvoyés
   * tels quels — ils sont déjà assainis et traduits en messages propres.
   */
  app.get<{ Params: { id: string } }>(
    '/api/downloads/:id/events',
    { preHandler: authenticated },
    async (request: FastifyRequest<{ Params: { id: string } }>, reply) => {
      const service = dependencies.service;
      if (!service) return unavailable(reply);

      const jobId = parseJobId(reply, request.params.id);
      if (jobId === null) return reply;

      const job = service.getJobForUser(jobId, request.authUser.id);
      if (!job) {
        return sendError(reply, 404, 'job_not_found', 'Téléchargement introuvable.');
      }

      reply.raw.writeHead(200, {
        'Content-Type': 'text/event-stream; charset=utf-8',
        'Cache-Control': 'no-cache, no-transform',
        Connection: 'keep-alive',
        // Neutralise la mise en tampon d'un éventuel reverse proxy.
        'X-Accel-Buffering': 'no',
      });

      let closed = false;
      const write = (event: string, payload: unknown): void => {
        if (closed || reply.raw.writableEnded) return;
        reply.raw.write(`event: ${event}\ndata: ${JSON.stringify(payload)}\n\n`);
      };

      write('snapshot', { item: publicDownloadJob(job) });
      if (isTerminal(job.status)) {
        closed = true;
        reply.raw.end();
        return reply;
      }

      const heartbeat = setInterval(() => {
        if (closed || reply.raw.writableEnded) return;
        // Commentaire SSE : maintient la connexion sans polluer le flux.
        reply.raw.write(': ping\n\n');
      }, SSE_HEARTBEAT_MS);
      heartbeat.unref();

      const close = (): void => {
        if (closed) return;
        closed = true;
        clearInterval(heartbeat);
        unsubscribe();
        if (!reply.raw.writableEnded) reply.raw.end();
      };

      const unsubscribe = service.subscribe(jobId, (event: DownloadJobEvent) => {
        switch (event.type) {
          case 'progress':
          case 'snapshot':
            write('progress', { item: publicDownloadJob(event.job) });
            return;
          case 'log':
            write('log', { level: event.level, message: event.message });
            return;
          case 'completed':
            write('completed', { item: publicDownloadJob(event.job) });
            close();
            return;
          case 'failed':
            write('failed', { item: publicDownloadJob(event.job) });
            close();
            return;
          case 'cancelled':
            write('cancelled', { item: publicDownloadJob(event.job) });
            close();
            return;
        }
      });

      // Client parti (application fermée, réseau coupé) : plus aucun écouteur
      // ne doit survivre.
      request.raw.on('close', close);
      reply.raw.on('close', close);

      return reply;
    },
  );
}

function isTerminal(status: string): boolean {
  return (
    status === 'completed' ||
    status === 'failed' ||
    status === 'cancelled' ||
    status === 'interrupted'
  );
}
