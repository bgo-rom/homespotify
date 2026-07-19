import { createHash } from 'node:crypto';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { and, asc, eq } from 'drizzle-orm';
import { tracks, trackEnrichment, trackQuality, userTracks } from '../db/schema.js';
import type { AuthGuards } from '../auth/guards.js';

export interface SyncManifestTrack {
  track_id: number;
  enrichment_status: string;
  etag: string;
  lastModified: string;
}

export interface SyncManifest {
  tracks: SyncManifestTrack[];
}

function latestIso(...values: Array<string | null | undefined>): string {
  const timestamps = values
    .filter((value): value is string => typeof value === 'string' && value.length > 0)
    .map((value) => ({ value, time: new Date(value).getTime() }))
    .filter((item) => !Number.isNaN(item.time))
    .sort((a, b) => b.time - a.time);
  return timestamps[0]?.value ?? new Date(0).toISOString();
}

function manifestEtag(manifest: SyncManifest): string {
  const hash = createHash('sha256').update(JSON.stringify(manifest)).digest('hex');
  return `"${hash}"`;
}

function requestHasMatchingEtag(request: FastifyRequest, etag: string): boolean {
  const raw = request.headers['if-none-match'];
  if (!raw) return false;
  const values = Array.isArray(raw) ? raw.join(',') : raw;
  return values
    .split(',')
    .map((value) => value.trim())
    .some((value) => value === etag || value === '*');
}

export function registerSyncRoutes(app: FastifyInstance, guards: AuthGuards): void {
  const { db } = app.dbHandle;

  // Manifeste de sync filtré par la bibliothèque de l'utilisateur : le cache
  // hors ligne mobile ne référence que des pistes auxquelles il a accès.
  app.get(
    '/api/sync/manifest',
    { preHandler: guards.requireAuth() },
    async (request, reply): Promise<FastifyReply | SyncManifest> => {
    const userId = request.authUser.id;
    const rows = db
      .select()
      .from(userTracks)
      .innerJoin(tracks, eq(tracks.id, userTracks.trackId))
      .leftJoin(trackQuality, eq(trackQuality.trackId, tracks.id))
      .leftJoin(trackEnrichment, eq(trackEnrichment.trackId, tracks.id))
      .where(and(eq(userTracks.userId, userId), eq(userTracks.isVisible, true)))
      .orderBy(asc(tracks.id))
      .all();

    const manifest: SyncManifest = {
      tracks: rows.map(({ tracks: track, track_quality: quality, track_enrichment: enrichment }) => ({
        track_id: track.id,
        enrichment_status: enrichment?.status ?? 'pending',
        etag: track.hash,
        lastModified: latestIso(track.createdAt, quality?.analyzedAt, enrichment?.checkedAt, enrichment?.enrichedAt),
      })),
    };
    const etag = manifestEtag(manifest);

    reply
      .header('etag', etag)
      .header('cache-control', 'private, max-age=0, must-revalidate')
      .type('application/json');

    if (requestHasMatchingEtag(request, etag)) {
      return reply.code(304).send();
    }

    return manifest;
    },
  );
}
