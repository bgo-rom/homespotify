import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { extname, join } from 'node:path';
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

/** Valeur Content-Disposition : fallback ASCII + filename* UTF-8 (RFC 5987) pour tags accentués. */
function attachmentHeader(name: string): string {
  const ascii = name.replace(/[^\x20-\x7e]/g, '_').replace(/["\\]/g, '_');
  const encoded = encodeURIComponent(name);
  return `attachment; filename="${ascii}"; filename*=UTF-8''${encoded}`;
}

/**
 * Sert un fichier local avec support HTTP Range (206/416/200), pour le streaming
 * et le téléchargement. `disposition` fixé → force le download.
 */
async function serveTrackFile(
  request: FastifyRequest,
  reply: FastifyReply,
  absPath: string,
  hash: string,
  contentType: string,
  disposition?: string,
): Promise<FastifyReply> {
  const info = await stat(absPath).then((s) => s, () => null);
  if (info === null) {
    request.log.error({ path: absPath }, 'fichier audio absent du disque');
    return reply.code(404).send({ statusCode: 404, error: 'not_found', message: 'Fichier audio introuvable' });
  }
  const size = info.size;

  reply
    .header('accept-ranges', 'bytes')
    .header('etag', `"${hash}"`)
    .header('last-modified', info.mtime.toUTCString())
    .header('cache-control', 'private, max-age=3600')
    .type(contentType);
  if (disposition) reply.header('content-disposition', disposition);

  const range = parseRangeHeader(request.headers.range, size);
  if (range === 'unsatisfiable') {
    return reply.code(416).header('content-range', `bytes */${size}`).send();
  }
  if (range === 'full') {
    return reply
      .code(200)
      .header('content-length', size)
      .send(createReadStream(absPath, { highWaterMark: STREAM_HIGH_WATER_MARK }));
  }
  const { start, end } = range;
  return reply
    .code(206)
    .header('content-range', `bytes ${start}-${end}/${size}`)
    .header('content-length', end - start + 1)
    .send(createReadStream(absPath, { start, end, highWaterMark: STREAM_HIGH_WATER_MARK }));
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
    { preHandler: requireAuth },
    async (request, reply) => {
      const track = findAccessibleTrack(request.authUser.id, request.params.id);
      if (!track) {
        return reply.code(404).send({ statusCode: 404, error: 'not_found', message: 'Piste inconnue' });
      }
      const contentType = track.mimeType ?? mimeTypeForPath(track.path);
      return serveTrackFile(request, reply, join(app.config.musicDir, track.path), track.hash, contentType);
    },
  );

  // Téléchargement forcé (cache hors ligne mobile) : Content-Disposition attachment
  app.get<{ Params: { id: string } }>(
    '/api/tracks/:id/download',
    { preHandler: requireAuth },
    async (request, reply) => {
      const track = findAccessibleTrack(request.authUser.id, request.params.id);
      if (!track) {
        return reply.code(404).send({ statusCode: 404, error: 'not_found', message: 'Piste inconnue' });
      }
      const ext = extname(track.path) || track.originalExtension || '.wav';
      const contentType = track.mimeType ?? mimeTypeForPath(track.path);
      const filename = `${track.artist} - ${track.title}${ext}`;
      return serveTrackFile(
        request, reply, join(app.config.musicDir, track.path), track.hash, contentType, attachmentHeader(filename),
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
