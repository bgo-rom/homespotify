import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { join } from 'node:path';
import type { FastifyReply, FastifyRequest, FastifyInstance } from 'fastify';
import { desc, eq, sql } from 'drizzle-orm';
import { tracks, trackEnrichment, trackQuality } from '../db/schema.js';
import { parseRangeHeader } from '../lib/range.js';
import { importWav, ImportError, PROVENANCES, type Provenance } from '../import/import-service.js';
import { coverArtPath } from '../metadata/cover-art-archive-client.js';

const COVER_MIME: Record<string, string> = { png: 'image/png', jpg: 'image/jpeg' };

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
    .type('audio/wav');
  if (disposition) reply.header('content-disposition', disposition);

  const range = parseRangeHeader(request.headers.range, size);
  if (range === 'unsatisfiable') {
    return reply.code(416).header('content-range', `bytes */${size}`).send();
  }
  if (range === 'full') {
    return reply.code(200).header('content-length', size).send(createReadStream(absPath));
  }
  const { start, end } = range;
  return reply
    .code(206)
    .header('content-range', `bytes ${start}-${end}/${size}`)
    .header('content-length', end - start + 1)
    .send(createReadStream(absPath, { start, end }));
}

export function registerTrackRoutes(app: FastifyInstance): void {
  const { db } = app.dbHandle;
  const dirs = {
    musicDir: app.config.musicDir,
    incomingDir: app.config.incomingDir,
    coversDir: app.config.coversDir,
  };

  const findTrack = (id: string) =>
    db.select().from(tracks).where(eq(tracks.id, Number(id))).get();

  // Import d'un WAV (multipart, champ "file" + champ optionnel "provenance")
  app.post('/api/tracks', async (request, reply) => {
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
      return reply.code(201).send(track);
    } catch (err) {
      if (err instanceof ImportError) {
        return reply.code(err.statusCode).send({ statusCode: err.statusCode, error: 'import_refused', message: err.message });
      }
      throw err;
    }
  });

  // Liste paginée. `etag`/`lastModified` par piste → le client mobile compare son cache local.
  app.get<{ Querystring: { page?: string; limit?: string } }>('/api/tracks', async (request) => {
    const page = Math.max(1, Number(request.query.page ?? 1) || 1);
    const limit = Math.min(200, Math.max(1, Number(request.query.limit ?? 50) || 50));
    const items = db
      .select()
      .from(tracks)
      .leftJoin(trackQuality, eq(trackQuality.trackId, tracks.id))
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
    const total = db.select({ n: sql<number>`count(*)` }).from(tracks).get()?.n ?? 0;
    return { page, limit, total, items };
  });

  // Streaming avec HTTP Range (seek/reprise sans télécharger les ~50 Mo)
  app.get<{ Params: { id: string } }>('/api/tracks/:id/stream', async (request, reply) => {
    const track = findTrack(request.params.id);
    if (!track) {
      return reply.code(404).send({ statusCode: 404, error: 'not_found', message: 'Piste inconnue' });
    }
    return serveTrackFile(request, reply, join(app.config.musicDir, track.path), track.hash);
  });

  // Téléchargement forcé (cache hors ligne mobile) : Content-Disposition attachment
  app.get<{ Params: { id: string } }>('/api/tracks/:id/download', async (request, reply) => {
    const track = findTrack(request.params.id);
    if (!track) {
      return reply.code(404).send({ statusCode: 404, error: 'not_found', message: 'Piste inconnue' });
    }
    const filename = `${track.artist} - ${track.title}.wav`;
    return serveTrackFile(
      request, reply, join(app.config.musicDir, track.path), track.hash, attachmentHeader(filename),
    );
  });

  // Pochette HD Cover Art Archive si disponible, sinon pochette embarquée extraite à l'import.
  app.get<{ Params: { id: string } }>('/api/tracks/:id/cover', async (request, reply) => {
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
  });
}
