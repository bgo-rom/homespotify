import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { extname, join } from 'node:path';
import {
  AudioStorageError,
  trackStorageReference,
  type AudioStorageProvider,
  type TrackStorageReference,
} from '../storage/audio-storage.js';
import { performance } from 'node:perf_hooks';
import { Transform } from 'node:stream';
import type { FastifyReply, FastifyRequest, FastifyInstance } from 'fastify';
import { and, desc, eq, sql } from 'drizzle-orm';
import { tracks, trackEnrichment, trackQuality, userTracks } from '../db/schema.js';
import { parseRangeHeader } from '../lib/range.js';
import { importWav, ImportError, PROVENANCES, type Provenance } from '../import/import-service.js';
import { mimeTypeForPath } from '../import/audio-format.js';
import { coverArtPath } from '../metadata/cover-art-archive-client.js';
import type { AuthGuards } from '../auth/guards.js';
import { grantTrack, userCanAccessTrack } from '../library/user-library-service.js';
import { isTrackPublished } from '../library/catalog-service.js';

const COVER_MIME: Record<string, string> = { png: 'image/png', jpg: 'image/jpeg' };
const STREAM_HIGH_WATER_MARK = 256 * 1024;
const SAFE_REQUEST_ID = /^[A-Za-z0-9._:-]{1,96}$/;

function streamRequestId(request: FastifyRequest): string {
  const raw = request.headers['x-request-id'];
  const candidate = Array.isArray(raw) ? raw[0] : raw;
  if (typeof candidate === 'string' && SAFE_REQUEST_ID.test(candidate)) return candidate;
  return String(request.id);
}

function streamLog(
  request: FastifyRequest,
  event: string,
  fields: Record<string, unknown> = {},
  level: 'info' | 'warn' | 'error' = 'info',
): void {
  request.log[level]({ event, requestId: streamRequestId(request), ...fields }, event);
}

function storageErrorReply(
  reply: FastifyReply,
  error: unknown,
): FastifyReply {
  const code =
    error instanceof AudioStorageError ? error.code : 'REMOTE_INTERNAL';
  if (code === 'NOT_FOUND' || code === 'NOT_A_FILE') {
    return reply.code(404).send({
      statusCode: 404,
      error: 'not_found',
      message: 'Fichier audio introuvable',
    });
  }
  if (
    code === 'STORAGE_OFFLINE' ||
    code === 'AGENT_UNAVAILABLE' ||
    code === 'CONNECT_TIMEOUT' ||
    code === 'HEADERS_TIMEOUT' ||
    code === 'BODY_TIMEOUT' ||
    code === 'INDEX_STALE' ||
    code === 'INDEX_NOT_LOADED' ||
    code === 'MUSIC_ROOT_UNAVAILABLE' ||
    code === 'STORAGE_BUSY'
  ) {
    if (code === 'STORAGE_BUSY') reply.header('retry-after', '1');
    return reply.code(503).send({
      statusCode: 503,
      error: 'service_unavailable',
      message: 'Stockage audio temporairement indisponible',
    });
  }
  if (
    code === 'REMOTE_AUTH_FAILED' ||
    code === 'REMOTE_INVALID_RESPONSE' ||
    code === 'REMOTE_RANGE_INVALID' ||
    code === 'REMOTE_STREAM_INTERRUPTED' ||
    code === 'REMOTE_INTERNAL'
  ) {
    return reply.code(502).send({
      statusCode: 502,
      error: 'bad_gateway',
      message: 'Réponse du stockage audio invalide',
    });
  }
  return reply.code(500).send({
    statusCode: 500,
    error: 'internal_error',
    message: 'Erreur interne du stockage audio',
  });
}

/** Valeur Content-Disposition : fallback ASCII + filename* UTF-8 (RFC 5987) pour tags accentués. */
function attachmentHeader(name: string): string {
  const ascii = name.replace(/[^\x20-\x7e]/g, '_').replace(/["\\]/g, '_');
  const encoded = encodeURIComponent(name);
  return `attachment; filename="${ascii}"; filename*=UTF-8''${encoded}`;
}

/**
 * Sert un fichier local avec support HTTP Range (206/416/200), pour le streaming
 * et le téléchargement. `disposition` fixé → force le download.
 * Exporté : la route de fichier des variantes hors ligne réutilise exactement
 * le même chemin Range/ETag (une seule implémentation de streaming).
 */
export async function serveTrackFile(
  request: FastifyRequest,
  reply: FastifyReply,
  provider: AudioStorageProvider,
  reference: TrackStorageReference,
  contentType: string,
  disposition?: string,
): Promise<FastifyReply> {
  const trackId = reference.trackId;
  const hash = reference.contentHash;
  const requestStartedAt = performance.now();
  const requestId = streamRequestId(request);
  reply.header('x-request-id', requestId);
  streamLog(request, 'STREAM_REQUEST_RECEIVED', {
    trackId,
    method: request.method,
    route: disposition ? '/api/tracks/:id/download' : '/api/tracks/:id/stream',
    rangeRequested: request.headers.range ?? null,
  });

  const statStartedAt = performance.now();
  streamLog(request, 'STREAM_FILE_STAT_STARTED', { trackId });
  let info;
  try {
    info = await provider.stat(reference, { requestId });
  } catch (error) {
    const code =
      error instanceof AudioStorageError
        ? error.code
        : error instanceof Error && 'code' in error
          ? String(error.code)
          : 'STAT_FAILED';
    streamLog(request, 'STREAM_FILE_ERROR', { trackId, errorCode: code }, 'error');
    return storageErrorReply(reply, error);
  }
  const statDurationMs = performance.now() - statStartedAt;
  streamLog(request, 'STREAM_FILE_STAT_COMPLETED', {
    trackId,
    fileSize: info.sizeBytes,
    statDurationMs,
  });
  const size = info.sizeBytes;

  reply
    .header('accept-ranges', 'bytes')
    .header('etag', `"${hash}"`)
    .header('last-modified', info.modifiedAt.toUTCString())
    .header('cache-control', 'private, max-age=3600')
    .type(contentType);
  if (disposition) reply.header('content-disposition', disposition);

  const range = parseRangeHeader(request.headers.range, size);
  if (range === 'unsatisfiable') {
    streamLog(request, 'STREAM_RANGE_INVALID', {
      trackId,
      fileSize: size,
      statusCode: 416,
    }, 'warn');
    return reply.code(416).header('content-range', `bytes */${size}`).send();
  }
  const start = range === 'full' ? 0 : range.start;
  const end = range === 'full' ? size - 1 : range.end;
  const statusCode = range === 'full' ? 200 : 206;
  const contentLength = end - start + 1;
  streamLog(request, 'STREAM_RANGE_PARSED', {
    trackId,
    statusCode,
    rangeStart: start,
    rangeEnd: end,
    contentLength,
    fileSize: size,
  });

  // HEAD public : le stat distant suffit. Aucun GET ni Readable n'est ouvert.
  // L'écriture directe préserve le Content-Length de la représentation, que
  // Fastify remplacerait sinon par zéro sur une réponse sans corps.
  if (request.method === 'HEAD') {
    if (range === 'full') {
      reply.code(200).header('content-length', size);
    } else {
      reply
        .code(206)
        .header('content-range', `bytes ${start}-${end}/${size}`)
        .header('content-length', contentLength);
    }
    streamLog(request, 'STREAM_RESPONSE_HEADERS_SENT', {
      trackId,
      statusCode,
      rangeStart: start,
      rangeEnd: end,
      contentLength,
      fileSize: size,
      statDurationMs,
    });
    streamLog(request, 'STREAM_COMPLETED', {
      trackId,
      statusCode,
      contentLength,
      bytesSent: 0,
      totalDurationMs: performance.now() - requestStartedAt,
      aborted: false,
    });
    const headHeaders: Record<string, string | string[]> = {};
    for (const [name, value] of Object.entries(reply.getHeaders())) {
      if (value === undefined) continue;
      headHeaders[name] =
        typeof value === 'number'
          ? String(value)
          : value;
    }
    reply.hijack();
    reply.raw.writeHead(statusCode, headHeaders);
    reply.raw.end();
    return reply;
  }

  const fileOpenStartedAt = performance.now();
  streamLog(request, 'STREAM_FILE_OPEN_STARTED', { trackId });
  let source;
  try {
    source = await provider.createReadStream(
      reference,
      range === 'full' ? undefined : { start, end },
      { requestId },
    );
  } catch (error) {
    const code =
      error instanceof AudioStorageError ? error.code : 'OPEN_FAILED';
    streamLog(request, 'STREAM_FILE_ERROR', { trackId, errorCode: code }, 'error');
    return storageErrorReply(reply, error);
  }
  let bytesSent = 0;
  let firstChunkAt: number | null = null;
  let terminalEventLogged = false;
  const metered = new Transform({
    transform(chunk: Buffer, _encoding, callback) {
      bytesSent += chunk.length;
      if (firstChunkAt === null) {
        firstChunkAt = performance.now();
        streamLog(request, 'STREAM_FIRST_CHUNK_SENT', {
          trackId,
          statusCode,
          bytes: chunk.length,
          timeToFirstChunkMs: firstChunkAt - requestStartedAt,
          openDurationMs: firstChunkAt - fileOpenStartedAt,
        });
      }
      callback(null, chunk);
    },
  });
  source.once('open', () => {
    streamLog(request, 'STREAM_FILE_OPEN_COMPLETED', {
      trackId,
      openDurationMs: performance.now() - fileOpenStartedAt,
    });
  });
  source.once('error', (error) => {
    if (terminalEventLogged) return;
    terminalEventLogged = true;
    const code = 'code' in error ? String(error.code) : 'READ_FAILED';
    streamLog(request, 'STREAM_FILE_ERROR', {
      trackId,
      statusCode,
      errorCode: code,
      bytesSent,
      totalDurationMs: performance.now() - requestStartedAt,
    }, 'error');
    metered.destroy(error);
  });
  metered.once('end', () => {
    if (terminalEventLogged) return;
    terminalEventLogged = true;
    streamLog(request, 'STREAM_COMPLETED', {
      trackId,
      statusCode,
      contentLength,
      bytesSent,
      totalDurationMs: performance.now() - requestStartedAt,
      aborted: false,
    });
  });
  request.raw.once('aborted', () => {
    if (!source.destroyed) source.destroy();
    if (terminalEventLogged) return;
    terminalEventLogged = true;
    streamLog(request, 'STREAM_ABORTED', {
      trackId,
      statusCode,
      bytesSent,
      totalDurationMs: performance.now() - requestStartedAt,
      aborted: true,
    }, 'warn');
  });
  reply.raw.once('close', () => {
    if (!reply.raw.writableFinished && !source.destroyed) source.destroy();
    if (terminalEventLogged) return;
    terminalEventLogged = true;
    streamLog(request, 'STREAM_CLIENT_DISCONNECTED', {
      trackId,
      statusCode,
      bytesSent,
      totalDurationMs: performance.now() - requestStartedAt,
      aborted: true,
    }, 'warn');
  });
  source.pipe(metered);

  streamLog(request, 'STREAM_RESPONSE_HEADERS_SENT', {
    trackId,
    statusCode,
    rangeStart: start,
    rangeEnd: end,
    contentLength,
    fileSize: size,
    statDurationMs,
  });
  if (range === 'full') {
    return reply
      .code(200)
      .header('content-length', size)
      .send(metered);
  }
  return reply
    .code(206)
    .header('content-range', `bytes ${start}-${end}/${size}`)
    .header('content-length', end - start + 1)
    .send(metered);
}

export function registerTrackRoutes(app: FastifyInstance, guards: AuthGuards): void {
  const { db } = app.dbHandle;
  const dirs = {
    musicDir: app.config.musicDir,
    incomingDir: app.config.incomingDir,
    coversDir: app.config.coversDir,
  };

  // Toutes les routes bibliothèque exigent une authentification (le userId
  // vient du token, jamais du client) et filtrent par `user_tracks`.
  const requireAuth = guards.requireAuth();
  const invokeRequireAuth = requireAuth as unknown as (
    request: FastifyRequest,
    reply: FastifyReply,
  ) => Promise<void>;
  const requireStreamAuth = async (request: FastifyRequest, reply: FastifyReply) => {
    const requestId = streamRequestId(request);
    const startedAt = performance.now();
    reply.header('x-request-id', requestId);
    streamLog(request, 'STREAM_AUTH_STARTED');
    await invokeRequireAuth(request, reply);
    const authDurationMs = performance.now() - startedAt;
    if (reply.sent || reply.statusCode >= 400) {
      streamLog(request, 'STREAM_AUTH_FAILED', {
        statusCode: reply.statusCode,
        authDurationMs,
      }, 'warn');
      return;
    }
    streamLog(request, 'STREAM_AUTH_COMPLETED', {
      userId: request.authUser.id,
      authDurationMs,
    });
  };

  /**
   * Piste LISIBLE par l'utilisateur courant (stream/download/cover), ou
   * undefined. Autorisée si AU MOINS UNE condition est vraie :
   *  - la piste est dans sa bibliothèque personnelle (`user_tracks`) ;
   *  - la piste est PUBLIÉE au catalogue global (tout compte authentifié peut
   *    l'écouter depuis « Ajouts récents », même sans l'avoir ajoutée).
   *
   * Le rôle n'est JAMAIS un bypass : un OWNER n'a pas plus d'accès de lecture
   * qu'un USER. Une piste orpheline (non publiée) reste inaccessible sans
   * `user_tracks`. Ces routes exigent toujours un Bearer token (401 sinon) ;
   * aucun token ne transite par l'URL.
   */
  const findAccessibleTrack = (userId: number, id: string) => {
    const trackId = Number(id);
    if (!Number.isInteger(trackId)) return undefined;
    const personal = userCanAccessTrack(app.dbHandle, userId, trackId);
    if (!personal && !isTrackPublished(app.dbHandle, trackId)) return undefined;
    return db.select().from(tracks).where(eq(tracks.id, trackId)).get();
  };

  // Import d'un WAV (multipart, champ "file" + champ optionnel "provenance").
  // L'importateur reçoit immédiatement l'accès à la piste (source MANUAL_IMPORT).
  app.post('/api/tracks', { preHandler: requireAuth }, async (request, reply) => {
    const file = await request.file();
    if (!file) {
      return reply.code(400).send({ statusCode: 400, error: 'bad_request', message: 'Champ multipart "file" manquant' });
    }
    const provenanceRaw = (file.fields.provenance as { value?: string } | undefined)?.value ?? 'inconnue';
    if (!(PROVENANCES as readonly string[]).includes(provenanceRaw)) {
      return reply.code(400).send({
        statusCode: 400,
        error: 'bad_request',
        message: `Provenance "${provenanceRaw}" inconnue (attendu : ${PROVENANCES.join(', ')})`,
      });
    }
    try {
      const track = await importWav(db, dirs, file.file, file.filename, provenanceRaw as Provenance);
      grantTrack(app.dbHandle, {
        userId: request.authUser.id,
        trackId: track.id,
        source: 'MANUAL_IMPORT',
        addedByUserId: request.authUser.id,
      });
      return reply.code(201).send(track);
    } catch (err) {
      if (err instanceof ImportError) {
        return reply.code(err.statusCode).send({ statusCode: err.statusCode, error: 'import_refused', message: err.message });
      }
      throw err;
    }
  });

  // Liste paginée FILTRÉE par la bibliothèque de l'utilisateur courant.
  // `etag`/`lastModified` par piste → le client mobile compare son cache local.
  app.get<{ Querystring: { page?: string; limit?: string } }>(
    '/api/tracks',
    { preHandler: requireAuth },
    async (request) => {
    const userId = request.authUser.id;
    const page = Math.max(1, Number(request.query.page ?? 1) || 1);
    const limit = Math.min(200, Math.max(1, Number(request.query.limit ?? 50) || 50));
    const items = db
      .select()
      .from(userTracks)
      .innerJoin(tracks, eq(tracks.id, userTracks.trackId))
      .leftJoin(trackQuality, eq(trackQuality.trackId, tracks.id))
      .where(and(eq(userTracks.userId, userId), eq(userTracks.isVisible, true)))
      .orderBy(desc(tracks.createdAt))
      .limit(limit)
      .offset((page - 1) * limit)
      .all()
      .map(({ tracks: t, track_quality: q }) => ({
        id: t.id,
        title: t.title,
        artist: t.artist,
        album: t.album,
        year: t.year,
        genre: t.genre,
        durationSeconds: t.durationSeconds,
        sizeBytes: t.sizeBytes,
        hasCover: t.coverPath !== null,
        mimeType: t.mimeType ?? mimeTypeForPath(t.path),
        extension: t.originalExtension ?? extname(t.path),
        etag: t.hash, // identité de contenu ; change si le fichier est réimporté
        lastModified: t.createdAt,
        quality: q && {
          container: q.container,
          codec: q.codec,
          sampleRate: q.sampleRate,
          bitDepth: q.bitDepth,
          channels: q.channels,
          status: q.status,
          provenance: q.provenance,
        },
      }));
    const total =
      db
        .select({ n: sql<number>`count(*)` })
        .from(userTracks)
        .where(and(eq(userTracks.userId, userId), eq(userTracks.isVisible, true)))
        .get()?.n ?? 0;
    return { page, limit, total, items };
  });

  // Streaming avec HTTP Range (seek/reprise sans télécharger les ~50 Mo).
  // Content-Type = format réel de la piste (audio/wav ou audio/flac), fichier envoyé tel quel.
  // Refusé si l'utilisateur n'a pas accès à la piste (404 générique, ne révèle
  // pas l'existence d'une piste d'un autre compte).
  app.get<{ Params: { id: string } }>(
    '/api/tracks/:id/stream',
    { preHandler: requireStreamAuth },
    async (request, reply) => {
      const track = findAccessibleTrack(request.authUser.id, request.params.id);
      if (!track) {
        return reply.code(404).send({ statusCode: 404, error: 'not_found', message: 'Piste inconnue' });
      }
      const contentType = track.mimeType ?? mimeTypeForPath(track.path);
      return serveTrackFile(
        request,
        reply,
        app.audioStorage,
        trackStorageReference(track),
        contentType,
      );
    },
  );

  // Téléchargement forcé (cache hors ligne mobile) : Content-Disposition attachment
  app.get<{ Params: { id: string } }>(
    '/api/tracks/:id/download',
    { preHandler: requireStreamAuth },
    async (request, reply) => {
      const track = findAccessibleTrack(request.authUser.id, request.params.id);
      if (!track) {
        return reply.code(404).send({ statusCode: 404, error: 'not_found', message: 'Piste inconnue' });
      }
      const ext = extname(track.path) || track.originalExtension || '.wav';
      const contentType = track.mimeType ?? mimeTypeForPath(track.path);
      const filename = `${track.artist} - ${track.title}${ext}`;
      return serveTrackFile(
        request,
        reply,
        app.audioStorage,
        trackStorageReference(track),
        contentType,
        attachmentHeader(filename),
      );
    },
  );

  // Pochette HD Cover Art Archive si disponible, sinon pochette embarquée extraite à l'import.
  // Pochette privée : filtrée par accès utilisateur.
  app.get<{ Params: { id: string } }>(
    '/api/tracks/:id/cover',
    { preHandler: requireAuth },
    async (request, reply) => {
    if (!findAccessibleTrack(request.authUser.id, request.params.id)) {
      return reply.code(404).send({ statusCode: 404, error: 'not_found', message: 'Piste inconnue' });
    }
    const row = db
      .select()
      .from(tracks)
      .leftJoin(trackEnrichment, eq(trackEnrichment.trackId, tracks.id))
      .where(eq(tracks.id, Number(request.params.id)))
      .get();
    if (!row) {
      return reply.code(404).send({ statusCode: 404, error: 'not_found', message: 'Piste inconnue' });
    }
    const track = row.tracks;

    const releaseGroupId = row.track_enrichment?.musicbrainzReleaseGroupId;
    if (releaseGroupId) {
      try {
        const hdCoverPath = coverArtPath(app.config.coversDir, releaseGroupId);
        const hasHdCover = await stat(hdCoverPath).then(() => true, () => false);
        if (hasHdCover) {
          return reply.type('image/jpeg').send(createReadStream(hdCoverPath));
        }
      } catch (error) {
        request.log.warn({ err: error, releaseGroupId }, 'pochette Cover Art Archive ignorée');
      }
    }

    if (!track.coverPath) {
      return reply.code(404).send({ statusCode: 404, error: 'not_found', message: 'Pas de pochette' });
    }
    const ext = track.coverPath.split('.').pop() ?? 'jpg';
    return reply.type(COVER_MIME[ext] ?? 'application/octet-stream').send(createReadStream(join(app.config.coversDir, track.coverPath)));
    },
  );
}
