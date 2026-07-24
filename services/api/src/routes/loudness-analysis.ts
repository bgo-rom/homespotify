import type { FastifyInstance, FastifyReply } from 'fastify';
import type { AuthGuards } from '../auth/guards.js';
import type { TrackLoudnessAnalysisService } from '../audio/loudness-analysis.js';
import { userCanAccessTrack } from '../library/user-library-service.js';

interface TrackParams {
  trackId: string;
}

export function registerLoudnessAnalysisRoutes(
  app: FastifyInstance,
  guards: AuthGuards,
  service: TrackLoudnessAnalysisService,
): void {
  app.get<{ Params: TrackParams }>(
    '/api/tracks/:trackId/loudness-analysis',
    { preHandler: guards.requireAuth() },
    async (request, reply) => {
      const trackId = parseTrackId(request.params.trackId);
      if (
        trackId === null ||
        !userCanAccessTrack(app.dbHandle, request.authUser.id, trackId)
      ) {
        return notFound(reply);
      }

      const analysis = service.getOrSchedule(trackId);
      const failureReason =
        analysis.status === 'FAILED'
          ? publicFailureReason(analysis.errorMessage)
          : null;
      request.log.debug(
        {
          userId: request.authUser.id,
          trackId,
          status: analysis.status,
          integratedLufs: analysis.integratedLufs,
          replayGainDb: analysis.replayGainDb,
          failureReason,
        },
        'lecture analyse sonie R128',
      );
      return {
        trackId,
        status: analysis.status,
        integratedLufs: analysis.integratedLufs,
        truePeakDbfs: analysis.truePeakDbfs,
        replayGainDb: analysis.replayGainDb,
        targetLufs: analysis.targetLufs,
        peakCeilingDbfs: analysis.peakCeilingDbfs,
        analyzedAt: analysis.analyzedAt,
        failureReason,
      };
    },
  );
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

export function publicFailureReason(
  error: string | null,
):
  | 'SILENCE_OR_INVALID_SIGNAL'
  | 'ANALYSIS_TIMEOUT'
  | 'ANALYZER_UNAVAILABLE'
  | 'ANALYSIS_FAILED' {
  const normalized = (error ?? '')
    .normalize('NFD')
    .replace(/\p{Diacritic}/gu, '')
    .toLocaleLowerCase('fr');
  if (
    normalized.includes('silencieux') ||
    normalized.includes('mesure r128 invalide')
  ) {
    return 'SILENCE_OR_INVALID_SIGNAL';
  }
  if (normalized.includes('delai') || normalized.includes('timeout')) {
    return 'ANALYSIS_TIMEOUT';
  }
  if (
    normalized.includes('enoent') ||
    (normalized.includes('ffmpeg') && normalized.includes('introuvable'))
  ) {
    return 'ANALYZER_UNAVAILABLE';
  }
  return 'ANALYSIS_FAILED';
}
