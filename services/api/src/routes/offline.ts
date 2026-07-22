import { stat } from 'node:fs/promises';
import type { FastifyInstance, FastifyReply } from 'fastify';
import { eq } from 'drizzle-orm';
import { tracks, trackQuality } from '../db/schema.js';
import type { AuthGuards } from '../auth/guards.js';
import { userCanAccessTrack } from '../library/user-library-service.js';
import { isTrackPublished } from '../library/catalog-service.js';
import { serveTrackFile } from './tracks.js';
import {
  OFFLINE_PROFILE_SPECS,
  estimateOpusSizeBytes,
  isOfflineProfile,
  type OfflineVariantRow,
  type OfflineVariantService,
} from '../audio/offline-variant-service.js';

/**
 * Contrats hors ligne Phase 1A (TD-Offline-Opus-2026-07-22).
 *
 * Toutes les routes exigent un Bearer et revérifient l'accès VISIBLE à la
 * piste : une variante physique peut être mutualisée, jamais son autorisation.
 * Aucune réponse ne contient de chemin absolu ni de chemin serveur.
 * L'original n'a PAS de route dédiée ici : il réutilise la route Range
 * canonique `/api/tracks/:id/download` et n'est jamais recopié dans le cache
 * de dérivées.
 */

type VariantDtoStatus = OfflineVariantRow['status'];

interface OfflineVariantDto {
  profile: string;
  profileVersion: string;
  encoderVersion: string;
  codec: 'opus';
  container: 'ogg';
  lossy: true;
  status: VariantDtoStatus;
  targetBitrateKbps: number;
  measuredBitrateKbps: number | null;
  durationSeconds: number | null;
  sizeBytes: number | null;
  sizeKind: 'estimated' | 'exact' | null;
  sha256: string | null;
  sourceSha256: string;
}

function variantDto(row: OfflineVariantRow): OfflineVariantDto {
  const ready = row.status === 'READY';
  const estimated =
    row.durationSeconds !== null
      ? estimateOpusSizeBytes(row.durationSeconds, row.targetBitrateKbps)
      : null;
  return {
    profile: row.profile,
    profileVersion: row.profileVersion,
    encoderVersion: row.encoderVersion,
    codec: 'opus',
    container: 'ogg',
    lossy: true,
    status: row.status,
    targetBitrateKbps: row.targetBitrateKbps,
    measuredBitrateKbps: row.measuredBitrateKbps,
    durationSeconds: row.durationSeconds,
    sizeBytes: ready ? row.sizeBytes : estimated,
    sizeKind: ready ? 'exact' : estimated !== null ? 'estimated' : null,
    sha256: ready ? row.sha256 : null,
    sourceSha256: row.sourceSha256,
  };
}

function notFound(reply: FastifyReply, message: string): FastifyReply {
  return reply.code(404).send({ statusCode: 404, error: 'not_found', message });
}

export function registerOfflineRoutes(
  app: FastifyInstance,
  guards: AuthGuards,
  service: OfflineVariantService,
): void {
  const { db } = app.dbHandle;
  const requireAuth = guards.requireAuth();

  /** Même politique d'accès que stream/download : bibliothèque OU catalogue publié. */
  const findAccessibleTrack = (userId: number, id: string) => {
    const trackId = Number(id);
    if (!Number.isInteger(trackId)) return undefined;
    const personal = userCanAccessTrack(app.dbHandle, userId, trackId);
    if (!personal && !isTrackPublished(app.dbHandle, trackId)) return undefined;
    return db.select().from(tracks).where(eq(tracks.id, trackId)).get();
  };

  const rejectUnknownProfile = (reply: FastifyReply, profile: string): FastifyReply =>
    reply.code(400).send({
      statusCode: 400,
      error: 'bad_request',
      message: `Profil "${profile}" inconnu (attendu : opus_128, opus_256)`,
    });

  // Les trois choix présentés au téléchargement : opus_128, opus_256
  // (recommandé, lossy) et original. Tailles Opus estimées tant que la
  // variante n'est pas prête ; original toujours exact.
  app.get<{ Params: { id: string } }>(
    '/api/tracks/:id/offline-options',
    { preHandler: requireAuth },
    async (request, reply) => {
      const track = findAccessibleTrack(request.authUser.id, request.params.id);
      if (!track) return notFound(reply, 'Piste inconnue');
      service.markStaleVariants(track);
      const quality = db.select().from(trackQuality).where(eq(trackQuality.trackId, track.id)).get();

      const opusOptions = await Promise.all(
        (['opus_128', 'opus_256'] as const).map(async (profile) => {
          const spec = OFFLINE_PROFILE_SPECS[profile];
          const variant = await service.getCurrentVariant(track, profile);
          if (variant !== undefined) {
            return { ...variantDto(variant), recommended: profile === 'opus_256' };
          }
          const estimated =
            track.durationSeconds !== null
              ? estimateOpusSizeBytes(track.durationSeconds, spec.targetBitrateKbps)
              : null;
          return {
            profile: spec.profile,
            profileVersion: spec.profileVersion,
            encoderVersion: null,
            codec: 'opus' as const,
            container: 'ogg' as const,
            lossy: true as const,
            status: 'NOT_REQUESTED' as const,
            targetBitrateKbps: spec.targetBitrateKbps,
            measuredBitrateKbps: null,
            durationSeconds: track.durationSeconds,
            sizeBytes: estimated,
            sizeKind: estimated !== null ? ('estimated' as const) : null,
            sha256: null,
            sourceSha256: track.hash,
            recommended: profile === 'opus_256',
          };
        }),
      );

      return {
        trackId: track.id,
        sourceSha256: track.hash,
        durationSeconds: track.durationSeconds,
        options: [
          ...opusOptions,
          {
            // L'original : copie exacte, servie par la route Range canonique.
            // Sa qualité vient UNIQUEMENT de l'analyse technique (track_quality).
            profile: 'original',
            profileVersion: null,
            encoderVersion: null,
            codec: quality?.codec ?? null,
            container: quality?.container ?? null,
            lossy: quality ? quality.status === 'lossy' : null,
            qualityStatus: quality?.status ?? 'inconnue',
            status: 'READY',
            targetBitrateKbps: null,
            measuredBitrateKbps: null,
            durationSeconds: track.durationSeconds,
            sizeBytes: track.sizeBytes,
            sizeKind: 'exact',
            sha256: track.hash,
            sourceSha256: track.hash,
            recommended: false,
          },
        ],
      };
    },
  );

  // Crée (ou retrouve, single-flight) la variante de l'identité courante.
  // 202 tant que l'encodage n'est pas terminé, 200 quand la variante est prête.
  app.post<{ Params: { id: string; profile: string } }>(
    '/api/tracks/:id/offline-variants/:profile',
    { preHandler: requireAuth },
    async (request, reply) => {
      const { profile } = request.params;
      if (!isOfflineProfile(profile)) return rejectUnknownProfile(reply, profile);
      const track = findAccessibleTrack(request.authUser.id, request.params.id);
      if (!track) return notFound(reply, 'Piste inconnue');
      const variant = await service.requestVariant(track, profile);
      const statusCode = variant.status === 'READY' ? 200 : 202;
      return reply.code(statusCode).send(variantDto(variant));
    },
  );

  // État de la variante pour l'identité courante de la piste.
  app.get<{ Params: { id: string; profile: string } }>(
    '/api/tracks/:id/offline-variants/:profile',
    { preHandler: requireAuth },
    async (request, reply) => {
      const { profile } = request.params;
      if (!isOfflineProfile(profile)) return rejectUnknownProfile(reply, profile);
      const track = findAccessibleTrack(request.authUser.id, request.params.id);
      if (!track) return notFound(reply, 'Piste inconnue');
      const variant = await service.getCurrentVariant(track, profile);
      if (variant === undefined) return notFound(reply, 'Variante jamais demandée');
      return variantDto(variant);
    },
  );

  // Fichier de la variante, Range-resumable (réutilise serveTrackFile).
  // ETag = SHA-256 de la dérivée : le mobile vérifie l'intégrité après reprise.
  app.get<{ Params: { id: string; profile: string } }>(
    '/api/tracks/:id/offline-variants/:profile/file',
    { preHandler: requireAuth },
    async (request, reply) => {
      const { profile } = request.params;
      if (!isOfflineProfile(profile)) return rejectUnknownProfile(reply, profile);
      const track = findAccessibleTrack(request.authUser.id, request.params.id);
      if (!track) return notFound(reply, 'Piste inconnue');
      const variant = await service.getCurrentVariant(track, profile);
      if (variant === undefined || variant.status !== 'READY' || variant.sha256 === null) {
        return notFound(reply, 'Variante non disponible');
      }
      const absPath = service.absolutePathFor(variant);
      if (absPath === null) return notFound(reply, 'Variante non disponible');
      const exists = await stat(absPath).then(() => true, () => false);
      if (!exists) return notFound(reply, 'Variante non disponible');
      return serveTrackFile(request, reply, track.id, absPath, variant.sha256, 'audio/ogg');
    },
  );
}

export type { OfflineVariantDto };
