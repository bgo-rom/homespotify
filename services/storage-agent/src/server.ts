/**
 * Serveur HTTP du Storage Agent.
 *
 * Surface minimale : santé, lecture indexée et import d'objets audio
 * immuables. Aucun chemin arbitraire n'entre par le réseau : un import est
 * adressé uniquement par SHA-256 + extension contrôlée.
 *
 * Ordre des barrières, du moins cher au plus cher :
 *   1. filtrage de l'IP source (403) ;
 *   2. validation méthode/route/taille ;
 *   3. HMAC daté + anti-rejeu, incluant le SHA-256 du corps (401) ;
 *   4. validation de l'identifiant demandé ;
 *   5. confinement sous MUSIC_ROOT ;
 *   6. limites de concurrence ;
 *   7. écriture durable avant reçu d'import.
 */
import { createReadStream as nodeCreateReadStream, type ReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { performance } from 'node:perf_hooks';
import { Transform, type Readable } from 'node:stream';
import Fastify, {
  type FastifyInstance,
  type FastifyReply,
  type FastifyRequest,
  type FastifyServerOptions,
} from 'fastify';
import { normalizeIp, type StorageAgentConfig } from './config.js';
import { contentTypeForPath } from './content-type.js';
import {
  errorBody,
  statusForErrorCode,
  StorageAgentError,
  type StorageAgentErrorCode,
} from './errors.js';
import {
  EMPTY_BODY_SHA256,
  HmacVerifier,
  NonceCache,
} from './hmac-auth.js';
import { PathSafetyError, resolveWithinRoot } from './path-safety.js';
import { isMultiRange, parseRangeHeader } from './range.js';
import { StorageIndexStore } from './storage-index.js';
import {
  DurableObjectStore,
  ObjectStoreError,
  type ObjectExtension,
} from './object-store.js';
import { StreamLimiter } from './stream-limiter.js';

/** Version de l'agent, exposée par `/health`. Suit package.json manuellement. */
export const STORAGE_AGENT_VERSION = '0.2.0';

const BASE_PATH = '/internal/storage';
const OBJECT_UPLOAD_ROUTE = `${BASE_PATH}/objects/:contentHash.:extension`;
const OBJECT_UPLOAD_PATH =
  /^\/internal\/storage\/objects\/([a-f0-9]{64})\.(flac|wav)$/;

/** Identifiant de piste : entier décimal positif, longueur bornée. */
const TRACK_ID = /^[1-9][0-9]{0,14}$/;

interface UploadDescriptor {
  contentHash: string;
  extension: ObjectExtension;
  sizeBytes: number;
}

function uploadDescriptor(
  method: string,
  rawUrl: string,
  contentLength: string | string[] | undefined,
  maxImportBytes: number,
): UploadDescriptor | null {
  if (method !== 'PUT') return null;
  const match = OBJECT_UPLOAD_PATH.exec(rawUrl);
  if (match === null) return null;
  if (
    Array.isArray(contentLength) ||
    typeof contentLength !== 'string' ||
    !/^[1-9][0-9]{0,15}$/.test(contentLength)
  ) {
    throw new StorageAgentError('INVALID_CONTENT_LENGTH');
  }
  const sizeBytes = Number(contentLength);
  if (!Number.isSafeInteger(sizeBytes) || sizeBytes <= 0) {
    throw new StorageAgentError('INVALID_CONTENT_LENGTH');
  }
  if (sizeBytes > maxImportBytes) {
    throw new StorageAgentError('OBJECT_TOO_LARGE');
  }
  return {
    contentHash: match[1]!,
    extension: match[2]! as ObjectExtension,
    sizeBytes,
  };
}

/** `X-Request-Id` fourni par le VPS : accepté seulement s'il est inoffensif. */
const SAFE_REQUEST_ID = /^[A-Za-z0-9._:-]{1,96}$/;

export type CreateReadStreamFn = (
  path: string,
  options: { start?: number; end?: number; highWaterMark?: number },
) => ReadStream;

export interface BuildStorageAgentOptions {
  config: StorageAgentConfig;
  /** Injecté par les tests ; sinon construit depuis la configuration. */
  indexStore?: StorageIndexStore;
  /** Injecté par les tests (comptage d'ouvertures, simulation d'erreur disque). */
  createReadStream?: CreateReadStreamFn;
  /** Injecté par les tests ; sinon magasin durable sous MUSIC_ROOT. */
  objectStore?: DurableObjectStore;
  now?: () => number;
  logger?: FastifyServerOptions['logger'];
}

export interface StorageAgentRuntime {
  indexStore: StorageIndexStore;
  limiter: StreamLimiter;
  importLimiter: StreamLimiter;
  objectStore: DurableObjectStore;
  nonceCache: NonceCache;
  startedAtMs: number;
}

declare module 'fastify' {
  interface FastifyInstance {
    /** État interne exposé aux tests et au point d'entrée. */
    storageAgent: StorageAgentRuntime;
  }
}

export type StorageAgentInstance = FastifyInstance;

interface RequestState {
  startedAt: number;
  trackId: number | null;
  upload: UploadDescriptor | null;
  rangeRequested: string | null;
  bytesSent: number;
  terminalLogged: boolean;
}

const STREAM_HIGH_WATER_MARK = 256 * 1024;

export function buildStorageAgent(options: BuildStorageAgentOptions): StorageAgentInstance {
  const { config } = options;
  const now = options.now ?? (() => Date.now());
  const openStream: CreateReadStreamFn =
    options.createReadStream ??
    ((path, streamOptions) => nodeCreateReadStream(path, streamOptions));

  const indexStore =
    options.indexStore ??
    new StorageIndexStore({
      indexPath: config.indexPath,
      pollIntervalMs: config.indexPollIntervalMs,
      onEvent: (event) => {
        const { event: name, ...rest } = event;
        if (name === 'STORAGE_AGENT_INDEX_REJECTED') app.log.error({ event: name, ...rest }, name);
        else app.log.info({ event: name, ...rest }, name);
      },
    });

  const limiter = new StreamLimiter(config.maxConcurrentStreams);
  const importLimiter = new StreamLimiter(config.maxConcurrentImports);
  const objectStore =
    options.objectStore ??
    new DurableObjectStore({
      musicRoot: config.musicRoot,
      maxBytes: config.maxImportBytes,
    });
  const nonceCache = new NonceCache(config.hmacMaxClockSkewSeconds * 2 * 1000);
  const verifier = new HmacVerifier({
    secret: config.sharedSecret,
    maxClockSkewSeconds: config.hmacMaxClockSkewSeconds,
    nonceCache,
    now,
  });

  const app = Fastify({
    // Le logger par défaut journaliserait l'URL de chaque requête : on préfère
    // des événements explicites et maîtrisés. Sans logger (tests), l'option est
    // inutile et déclencherait un avertissement de dépréciation Fastify 6.
    ...(options.logger === false ? {} : { disableRequestLogging: true }),
    // Un HEAD implicite rejouerait le handler GET et ouvrirait un flux : la
    // route HEAD est déclarée explicitement à la place.
    exposeHeadRoutes: false,
    // Les routes de lecture restent sans corps. La route PUT définit sa borne
    // propre ; le parser octet-stream restitue le flux sans le charger en RAM.
    bodyLimit: 1024,
    genReqId: (request) => {
      const raw = request.headers['x-request-id'];
      const candidate = Array.isArray(raw) ? raw[0] : raw;
      if (typeof candidate === 'string' && SAFE_REQUEST_ID.test(candidate)) return candidate;
      return `sa-${Math.random().toString(36).slice(2, 10)}-${Date.now().toString(36)}`;
    },
    logger: options.logger ?? { level: config.logLevel },
  });

  app.addContentTypeParser(
    'application/octet-stream',
    (_request, payload, done) => done(null, payload),
  );

  const states = new WeakMap<FastifyRequest, RequestState>();

  function stateOf(request: FastifyRequest): RequestState {
    let state = states.get(request);
    if (state === undefined) {
      state = {
        startedAt: performance.now(),
        trackId: null,
        upload: null,
        rangeRequested: null,
        bytesSent: 0,
        terminalLogged: false,
      };
      states.set(request, state);
    }
    return state;
  }

  function logEvent(
    request: FastifyRequest,
    event: string,
    fields: Record<string, unknown> = {},
    level: 'info' | 'warn' | 'error' = 'info',
  ): void {
    const state = stateOf(request);
    request.log[level](
      {
        event,
        requestId: String(request.id),
        method: request.method,
        route: routeLabel(request),
        trackId: state.trackId,
        activeStreams: limiter.activeStreams,
        ...fields,
      },
      event,
    );
  }

  /** Libellé LOGIQUE de la route : jamais l'URL brute, jamais un chemin disque. */
  function routeLabel(request: FastifyRequest): string {
    const url = request.routeOptions?.url;
    if (typeof url === 'string' && url.length > 0) return url;
    return 'unknown';
  }

  function sendError(
    request: FastifyRequest,
    reply: FastifyReply,
    code: StorageAgentErrorCode,
    logFields: Record<string, unknown> = {},
  ): FastifyReply {
    const status = statusForErrorCode(code);
    if (code === 'STREAM_LIMIT_REACHED') {
      // Saturation = 503 + Retry-After (décision documentée dans errors.ts).
      reply.header('retry-after', '1');
      logEvent(request, 'STORAGE_AGENT_LIMIT_REACHED', { limit: limiter.limit }, 'warn');
    }
    // HEAD n'a pas de corps : ce code additif est la seule façon fiable pour
    // le provider VPS de distinguer piste non indexée, fichier absent, auth et
    // saturation sans ouvrir un GET. Il ne contient aucune donnée sensible.
    reply.header('x-hs-error-code', code);
    reply.header('cache-control', 'no-store');
    return reply.code(status).send(errorBody(code, String(request.id)));
  }

  // -------------------------------------------------------------------------
  // Barrières globales : IP source, absence de corps, HMAC
  // -------------------------------------------------------------------------
  app.addHook('onRequest', async (request, reply) => {
    const state = stateOf(request);
    state.rangeRequested =
      typeof request.headers.range === 'string' ? request.headers.range : null;
    reply.header('x-request-id', String(request.id));
    logEvent(request, 'STORAGE_AGENT_REQUEST_STARTED', {
      rangeRequested: state.rangeRequested,
    });

    // `request.socket.remoteAddress` et non `request.ip` : aucune confiance
    // n'est accordée à `X-Forwarded-For`, que trustProxy laisse d'ailleurs
    // désactivé.
    const remoteIp = normalizeIp(request.socket.remoteAddress);
    if (remoteIp === null || !config.allowedRemoteIps.includes(remoteIp)) {
      logEvent(
        request,
        'STORAGE_AGENT_AUTH_REJECTED',
        { errorCode: 'SOURCE_IP_DENIED', reason: 'origine non autorisée' },
        'warn',
      );
      state.terminalLogged = true;
      sendError(request, reply, 'SOURCE_IP_DENIED');
      return reply;
    }

    const rawUrl = request.raw.url ?? request.url;
    let upload: UploadDescriptor | null;
    try {
      upload = uploadDescriptor(
        request.method,
        rawUrl,
        request.headers['content-length'],
        config.maxImportBytes,
      );
    } catch (error) {
      if (error instanceof StorageAgentError) {
        state.terminalLogged = true;
        sendError(request, reply, error.code);
        return reply;
      }
      throw error;
    }
    state.upload = upload;

    const contentLength = request.headers['content-length'];
    if (
      upload === null &&
      ((typeof contentLength === 'string' && contentLength !== '0') ||
        Array.isArray(contentLength))
    ) {
      logEvent(
        request,
        'STORAGE_AGENT_AUTH_REJECTED',
        { errorCode: 'AUTH_INVALID', reason: 'corps refusé sur route de lecture' },
        'warn',
      );
      state.terminalLogged = true;
      sendError(request, reply, 'AUTH_INVALID');
      return reply;
    }
    if (
      upload !== null &&
      request.headers['content-type'] !== 'application/octet-stream'
    ) {
      state.terminalLogged = true;
      sendError(request, reply, 'INVALID_OBJECT');
      return reply;
    }

    const verification = verifier.verify({
      method: request.method,
      // URL brute, query comprise, exactement telle que reçue.
      pathWithQuery: rawUrl,
      headers: request.headers,
      bodySha256: upload?.contentHash ?? EMPTY_BODY_SHA256,
    });
    if (!verification.ok) {
      // `reason` est un motif court et fixe : ni signature, ni secret, ni nonce.
      logEvent(
        request,
        'STORAGE_AGENT_AUTH_REJECTED',
        { errorCode: verification.code, reason: verification.reason },
        'warn',
      );
      state.terminalLogged = true;
      sendError(request, reply, verification.code);
      return reply;
    }
    return undefined;
  });

  app.addHook('onResponse', async (request, reply) => {
    const state = stateOf(request);
    if (state.terminalLogged) return;
    state.terminalLogged = true;
    logEvent(request, 'STORAGE_AGENT_REQUEST_COMPLETED', {
      statusCode: reply.statusCode,
      durationMs: performance.now() - state.startedAt,
      bytesSent: state.bytesSent,
      clientAborted: false,
    });
  });

  app.setNotFoundHandler((request, reply) => sendError(request, reply, 'TRACK_NOT_INDEXED'));

  app.setErrorHandler((error, request, reply) => {
    if (error instanceof StorageAgentError) {
      return sendError(request, reply, error.code, { detail: error.detail });
    }
    // Aucun détail système ne franchit cette frontière.
    logEvent(request, 'STORAGE_AGENT_REQUEST_COMPLETED', { errorCode: 'INTERNAL_ERROR' }, 'error');
    return sendError(request, reply, 'INTERNAL_ERROR');
  });

  // -------------------------------------------------------------------------
  // Résolution d'une piste
  // -------------------------------------------------------------------------
  interface ResolvedTrack {
    trackId: number;
    absolutePath: string;
    portableRelativePath: string;
    sizeBytes: number;
    modifiedAt: Date;
    contentType: string;
  }

  async function resolveTrack(request: FastifyRequest): Promise<ResolvedTrack> {
    const raw = (request.params as { trackId?: string }).trackId ?? '';
    if (!TRACK_ID.test(raw)) throw new StorageAgentError('INVALID_TRACK_ID');
    const trackId = Number(raw);
    if (!Number.isSafeInteger(trackId)) throw new StorageAgentError('INVALID_TRACK_ID');
    stateOf(request).trackId = trackId;

    if (indexStore.current === null) throw new StorageAgentError('INDEX_NOT_LOADED');

    const portableRelativePath = indexStore.lookup(trackId);
    if (portableRelativePath === undefined) throw new StorageAgentError('TRACK_NOT_INDEXED');

    let absolutePath: string;
    try {
      // Seconde barrière de confinement, même si l'index a déjà été validé.
      absolutePath = resolveWithinRoot(config.musicRoot, portableRelativePath);
    } catch (error) {
      const reason = error instanceof PathSafetyError ? error.reason : 'UNKNOWN';
      throw new StorageAgentError('INDEX_INVALID', `confinement refusé (${reason})`);
    }

    let info;
    try {
      info = await stat(absolutePath);
    } catch {
      // Distinguer « ce fichier manque » de « le disque n'est plus là » : la
      // racine n'est vérifiée que sur ce chemin d'erreur, jamais en régime
      // nominal.
      throw (await musicRootAvailable())
        ? new StorageAgentError('FILE_NOT_FOUND')
        : new StorageAgentError('MUSIC_ROOT_UNAVAILABLE');
    }
    if (!info.isFile()) throw new StorageAgentError('FILE_NOT_FOUND');

    return {
      trackId,
      absolutePath,
      portableRelativePath,
      sizeBytes: info.size,
      modifiedAt: info.mtime,
      contentType: contentTypeForPath(portableRelativePath),
    };
  }

  async function musicRootAvailable(): Promise<boolean> {
    try {
      return (await stat(config.musicRoot)).isDirectory();
    } catch {
      return false;
    }
  }

  // -------------------------------------------------------------------------
  // Routes
  // -------------------------------------------------------------------------
  app.get(`${BASE_PATH}/health`, async (request, reply) => {
    const index = indexStore.current;
    const musicRootOk = await musicRootAvailable();
    // Décision documentée : sans index valide l'agent ne peut RIEN servir, donc
    // `unhealthy` (503). Une racine musicale absente avec un index valide est
    // `degraded` (200) : la panne peut être transitoire et l'index reste bon.
    const status = index === null ? 'unhealthy' : musicRootOk ? 'healthy' : 'degraded';
    return reply.code(status === 'unhealthy' ? 503 : 200).send({
      status,
      agentVersion: STORAGE_AGENT_VERSION,
      indexLoaded: index !== null,
      indexVersion: index?.version ?? null,
      indexEntryCount: index?.entries.size ?? 0,
      indexGeneratedAt: index?.generatedAt ?? null,
      indexLoadedAt: index?.loadedAt.toISOString() ?? null,
      indexLastRejectionReason: indexStore.lastRejectionReason,
      musicRootAvailable: musicRootOk,
      activeStreams: limiter.activeStreams,
      maxConcurrentStreams: limiter.limit,
      activeImports: importLimiter.activeStreams,
      maxConcurrentImports: importLimiter.limit,
      uptimeSeconds: Math.floor((now() - startedAtMs) / 1000),
    });
  });

  /**
   * Import d'un objet audio immuable.
   *
   * Le SHA-256 est à la fois dans la route et dans la signature HMAC. Le flux
   * est recalculé pendant l'écriture ; aucune confiance n'est accordée à
   * l'en-tête déclaré. Le reçu `durable: true` n'est émis qu'après fsync du
   * fichier final renommé.
   */
  app.put(
    OBJECT_UPLOAD_ROUTE,
    {
      bodyLimit: config.maxImportBytes,
    },
    async (request, reply) => {
      const descriptor = stateOf(request).upload;
      if (descriptor === null) {
        throw new StorageAgentError('INVALID_OBJECT');
      }
      const release = importLimiter.acquire();
      if (release === null) {
        throw new StorageAgentError('IMPORT_LIMIT_REACHED');
      }
      try {
        const source = request.body as Readable | undefined;
        if (
          source === undefined ||
          typeof (source as { pipe?: unknown }).pipe !== 'function'
        ) {
          throw new StorageAgentError('INVALID_OBJECT');
        }
        const receipt = await objectStore.store({
          contentHash: descriptor.contentHash,
          extension: descriptor.extension,
          expectedSizeBytes: descriptor.sizeBytes,
          source,
        });
        logEvent(request, 'STORAGE_AGENT_OBJECT_STORED', {
          objectId: descriptor.contentHash.slice(0, 12),
          extension: descriptor.extension,
          sizeBytes: receipt.sizeBytes,
          reused: receipt.reused,
          durable: receipt.durable,
        });
        return reply.code(receipt.reused ? 200 : 201).send({
          status: 'stored',
          contentHash: receipt.contentHash,
          extension: receipt.extension,
          sizeBytes: receipt.sizeBytes,
          reused: receipt.reused,
          durable: receipt.durable,
        });
      } catch (error) {
        if (error instanceof ObjectStoreError) {
          throw new StorageAgentError(error.code);
        }
        throw error;
      } finally {
        release();
      }
    },
  );

  /**
   * HEAD : `stat` uniquement, JAMAIS de `createReadStream`, et aucun
   * emplacement de flux consommé.
   *
   * La réponse est écrite en direct (`hijack`) parce que Fastify force
   * `content-length: 0` sur toute réponse sans corps — or un HEAD doit annoncer
   * la taille RÉELLE de la représentation.
   */
  app.head(`${BASE_PATH}/tracks/:trackId`, async (request, reply) => {
    const track = await resolveTrack(request);
    const state = stateOf(request);
    const range = parseRangeHeader(
      typeof request.headers.range === 'string' ? request.headers.range : undefined,
      track.sizeBytes,
    );

    if (range.kind === 'unsatisfiable') {
      state.terminalLogged = true;
      logEvent(
        request,
        'STORAGE_AGENT_REQUEST_COMPLETED',
        { statusCode: 416, durationMs: performance.now() - state.startedAt, bytesSent: 0 },
        'warn',
      );
      reply.hijack();
      reply.raw.writeHead(416, {
        'accept-ranges': 'bytes',
        'content-range': `bytes */${track.sizeBytes}`,
        'content-length': '0',
        'x-hs-error-code': 'INVALID_RANGE',
        'x-request-id': String(request.id),
      });
      reply.raw.end();
      return reply;
    }

    const start = range.kind === 'full' ? 0 : range.start;
    const end = range.kind === 'full' ? Math.max(0, track.sizeBytes - 1) : range.end;
    const partial = range.kind === 'partial';
    const contentLength = partial ? end - start + 1 : track.sizeBytes;
    const statusCode = partial ? 206 : 200;

    state.terminalLogged = true;
    logEvent(request, 'STORAGE_AGENT_REQUEST_COMPLETED', {
      statusCode,
      durationMs: performance.now() - state.startedAt,
      bytesSent: 0,
      contentLength,
    });

    reply.hijack();
    reply.raw.writeHead(statusCode, {
      'accept-ranges': 'bytes',
      'content-type': track.contentType,
      'content-length': String(contentLength),
      'last-modified': track.modifiedAt.toUTCString(),
      'x-request-id': String(request.id),
      ...(partial ? { 'content-range': `bytes ${start}-${end}/${track.sizeBytes}` } : {}),
    });
    reply.raw.end();
    return reply;
  });

  app.get(`${BASE_PATH}/tracks/:trackId`, async (request, reply) => {
    const track = await resolveTrack(request);
    const state = stateOf(request);
    const rangeHeader =
      typeof request.headers.range === 'string' ? request.headers.range : undefined;
    const range = parseRangeHeader(rangeHeader, track.sizeBytes);

    if (range.kind === 'unsatisfiable') {
      return reply
        .code(416)
        .header('accept-ranges', 'bytes')
        .header('content-range', `bytes */${track.sizeBytes}`)
        .header('x-hs-error-code', 'INVALID_RANGE')
        .send();
    }
    if (isMultiRange(rangeHeader)) {
      logEvent(request, 'STORAGE_AGENT_MULTI_RANGE_IGNORED', {}, 'warn');
    }

    const partial = range.kind === 'partial';
    const start = partial ? range.start : 0;
    const end = partial ? range.end : Math.max(0, track.sizeBytes - 1);
    const contentLength = partial ? end - start + 1 : track.sizeBytes;
    const statusCode = partial ? 206 : 200;

    // Emplacement réservé APRÈS toutes les validations et AVANT l'ouverture :
    // un refus ne coûte alors aucun descripteur de fichier.
    const release = limiter.acquire();
    if (release === null) throw new StorageAgentError('STREAM_LIMIT_REACHED');

    let source: ReadStream;
    try {
      source = openStream(track.absolutePath, {
        // Un fichier vide ne se lit pas par plage : bornes omises.
        ...(track.sizeBytes === 0 ? {} : { start, end }),
        highWaterMark: STREAM_HIGH_WATER_MARK,
      });
    } catch {
      release();
      throw new StorageAgentError('STREAM_READ_ERROR');
    }

    // Compteur d'octets réellement transmis. Un Transform préserve la
    // backpressure : rien n'est lu tant que la socket ne draine pas.
    const metered = new Transform({
      transform(chunk: Buffer, _encoding, callback) {
        state.bytesSent += chunk.length;
        callback(null, chunk);
      },
    });

    source.once('error', () => {
      if (!state.terminalLogged) {
        state.terminalLogged = true;
        logEvent(
          request,
          'STORAGE_AGENT_REQUEST_COMPLETED',
          {
            statusCode,
            errorCode: 'STREAM_READ_ERROR',
            bytesSent: state.bytesSent,
            durationMs: performance.now() - state.startedAt,
          },
          'error',
        );
      }
      metered.destroy();
    });

    // Point de libération UNIQUE : `close` de la réponse survient dans tous les
    // cas — fin normale, abandon client, erreur disque, exception Fastify.
    reply.raw.once('close', () => {
      const completed = reply.raw.writableFinished;
      release();
      source.destroy();
      if (state.terminalLogged) return;
      state.terminalLogged = true;
      logEvent(
        request,
        completed ? 'STORAGE_AGENT_REQUEST_COMPLETED' : 'STORAGE_AGENT_REQUEST_ABORTED',
        {
          statusCode,
          contentLength,
          bytesSent: state.bytesSent,
          durationMs: performance.now() - state.startedAt,
          clientAborted: !completed,
        },
        completed ? 'info' : 'warn',
      );
    });

    reply
      .code(statusCode)
      .header('accept-ranges', 'bytes')
      .header('content-type', track.contentType)
      .header('content-length', String(contentLength))
      .header('last-modified', track.modifiedAt.toUTCString());
    if (partial) {
      reply.header('content-range', `bytes ${start}-${end}/${track.sizeBytes}`);
    }
    return reply.send(source.pipe(metered));
  });

  const startedAtMs = now();
  app.decorate('storageAgent', {
    indexStore,
    limiter,
    importLimiter,
    objectStore,
    nonceCache,
    startedAtMs,
  } satisfies StorageAgentRuntime);

  // Un store fourni par l'appelant (tests, main.ts) reste sous SA
  // responsabilité : l'agent ne démarre la scrutation que s'il l'a créé.
  if (options.indexStore === undefined) {
    app.addHook('onReady', async () => {
      indexStore.start();
    });
  }

  app.addHook('onClose', async () => {
    indexStore.stop();
  });

  return app;
}
