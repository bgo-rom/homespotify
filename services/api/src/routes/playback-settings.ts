import type { FastifyInstance, FastifyReply } from 'fastify';
import { and, eq } from 'drizzle-orm';
import type { AuthGuards } from '../auth/guards.js';
import {
  publicAudioAnalysisFailureReason,
  type TrackAudioAnalysisService,
} from '../audio/bpm-analysis.js';
import { userTrackPlaybackSettings } from '../db/schema.js';
import { userCanAccessTrack } from '../library/user-library-service.js';

interface TrackParams {
  trackId: string;
}

interface PlaybackSettingsBody {
  speedRatio?: unknown;
  preservePitch?: unknown;
}

function parseTrackId(raw: string): number | null {
  const trackId = Number(raw);
  return Number.isInteger(trackId) && trackId > 0 ? trackId : null;
}

function notFound(reply: FastifyReply): FastifyReply {
  return reply.code(404).send({
    statusCode: 404,
    error: 'not_found',
    message: 'Piste inconnue.',
  });
}

function invalidSettings(reply: FastifyReply): FastifyReply {
  return reply.code(400).send({
    statusCode: 400,
    error: 'bad_request',
    message: 'speedRatio doit être compris entre 0.70 et 1.30 et preservePitch doit valoir true.',
  });
}

export function registerPlaybackSettingsRoutes(
  app: FastifyInstance,
  guards: AuthGuards,
  audioAnalysis: TrackAudioAnalysisService,
): void {
  const requireAuth = guards.requireAuth();
  const { db } = app.dbHandle;

  app.get<{ Params: TrackParams }>(
    '/api/tracks/:trackId/playback-settings',
    { preHandler: requireAuth },
    async (request, reply) => {
      const trackId = parseTrackId(request.params.trackId);
      if (
        trackId === null ||
        !userCanAccessTrack(app.dbHandle, request.authUser.id, trackId)
      ) {
        return notFound(reply);
      }
      const row = db
        .select()
        .from(userTrackPlaybackSettings)
        .where(
          and(
            eq(userTrackPlaybackSettings.userId, request.authUser.id),
            eq(userTrackPlaybackSettings.trackId, trackId),
          ),
        )
        .get();
      request.log.debug(
        {
          userId: request.authUser.id,
          trackId,
          speedRatio: row?.speedRatio ?? 1,
          isDefault: row === undefined,
        },
        'lecture reglage vitesse',
      );
      return {
        trackId,
        speedRatio: row?.speedRatio ?? 1,
        preservePitch: true,
        isDefault: row === undefined,
      };
    },
  );

  app.put<{ Params: TrackParams; Body: PlaybackSettingsBody }>(
    '/api/tracks/:trackId/playback-settings',
    { preHandler: requireAuth },
    async (request, reply) => {
      const trackId = parseTrackId(request.params.trackId);
      if (
        trackId === null ||
        !userCanAccessTrack(app.dbHandle, request.authUser.id, trackId)
      ) {
        return notFound(reply);
      }
      const ratio = request.body?.speedRatio;
      if (
        typeof ratio !== 'number' ||
        !Number.isFinite(ratio) ||
        ratio < 0.7 ||
        ratio > 1.3 ||
        request.body?.preservePitch !== true
      ) {
        request.log.debug(
          {
            userId: request.authUser.id,
            trackId,
            requestedRatio: ratio,
            preservePitch: request.body?.preservePitch,
            persisted: false,
          },
          'reglage vitesse refuse',
        );
        return invalidSettings(reply);
      }

      const speedRatio = Math.round(ratio * 100) / 100;
      const now = new Date().toISOString();
      db.insert(userTrackPlaybackSettings)
        .values({
          userId: request.authUser.id,
          trackId,
          speedRatio,
          preservePitch: true,
          createdAt: now,
          updatedAt: now,
        })
        .onConflictDoUpdate({
          target: [
            userTrackPlaybackSettings.userId,
            userTrackPlaybackSettings.trackId,
          ],
          set: { speedRatio, preservePitch: true, updatedAt: now },
        })
        .run();
      request.log.debug(
        {
          userId: request.authUser.id,
          trackId,
          requestedRatio: ratio,
          speedRatio,
          preservePitch: true,
          persisted: true,
        },
        'reglage vitesse enregistre',
      );
      return { trackId, speedRatio, preservePitch: true, isDefault: false };
    },
  );

  app.delete<{ Params: TrackParams }>(
    '/api/tracks/:trackId/playback-settings',
    { preHandler: requireAuth },
    async (request, reply) => {
      const trackId = parseTrackId(request.params.trackId);
      if (
        trackId === null ||
        !userCanAccessTrack(app.dbHandle, request.authUser.id, trackId)
      ) {
        return notFound(reply);
      }
      db.delete(userTrackPlaybackSettings)
        .where(
          and(
            eq(userTrackPlaybackSettings.userId, request.authUser.id),
            eq(userTrackPlaybackSettings.trackId, trackId),
          ),
        )
        .run();
      return reply.code(204).send();
    },
  );

  app.get<{ Params: TrackParams }>(
    '/api/tracks/:trackId/audio-analysis',
    { preHandler: requireAuth },
    async (request, reply) => {
      const trackId = parseTrackId(request.params.trackId);
      if (
        trackId === null ||
        !userCanAccessTrack(app.dbHandle, request.authUser.id, trackId)
      ) {
        return notFound(reply);
      }
      const analysis = audioAnalysis.getOrSchedule(trackId);
      const failureReason =
        analysis.status === 'FAILED'
          ? publicAudioAnalysisFailureReason(analysis.errorMessage)
          : null;
      request.log.debug(
        {
          userId: request.authUser.id,
          trackId,
          analysisStatus: analysis.status,
          bpm: analysis.bpm,
          failureReason,
        },
        'lecture analyse BPM',
      );
      return {
        trackId,
        status: analysis.status,
        bpm: analysis.bpm,
        bpmConfidence: analysis.bpmConfidence,
        bpmSource: analysis.bpmSource,
        analyzedAt: analysis.analyzedAt,
        failureReason,
      };
    },
  );
}
