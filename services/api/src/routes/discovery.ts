import type { FastifyInstance, FastifyReply } from 'fastify';
import { and, eq, gte, sql } from 'drizzle-orm';
import type { AuthGuards } from '../auth/guards.js';
import { recordAudit } from '../auth/audit.js';
import {
  recommendationCandidates,
  recommendationEvents,
  recommendationImpressions,
  tracks,
  userHiddenTracks,
  userRecommendationQueue,
  userTracks,
  users,
} from '../db/schema.js';
import {
  getQueueStatus,
  isRecommendationAction,
  listQueueForUser,
  recordRecommendationAction,
} from '../discovery/recommendation-service.js';
import {
  buildUserTasteProfile,
  isRefreshInFlight,
  readProviderErrorStatus,
  readUserRefreshError,
  refreshRecommendationQueueForUser,
  RECOMMENDATION_MODEL_VERSION,
  REFILL_THRESHOLD,
  READY_TARGET,
  RESERVE_TARGET,
  type QueueRefreshDeps,
} from '../discovery/recommendation-engine.js';
import { revokeTrack } from '../library/user-library-service.js';

function badRequest(reply: FastifyReply, message: string): FastifyReply {
  return reply.code(400).send({ statusCode: 400, error: 'bad_request', message });
}

function parsePositiveInt(raw: string): number | null {
  const value = Number(raw);
  return Number.isInteger(value) && value >= 1 ? value : null;
}

export interface DiscoveryRouteDeps {
  refreshDeps: QueueRefreshDeps;
}

/**
 * Découverte par swipe + suppression douce de bibliothèque. Le userId vient
 * TOUJOURS du token. Le feed (GET) lit exclusivement la file pré-calculée
 * locale : aucune recherche externe, aucun scoring, aucun téléchargement.
 * Les appels externes n'ont lieu que dans le job asynchrone de
 * rafraîchissement (single-flight par utilisateur).
 */
export function registerDiscoveryRoutes(
  app: FastifyInstance,
  guards: AuthGuards,
  deps: DiscoveryRouteDeps,
): void {
  const handle = app.dbHandle;
  const requireAuth = guards.requireAuth();

  /**
   * Déclenche le job async sans bloquer la réponse. L'erreur est déjà consignée
   * dans l'état par utilisateur par `executeRefresh` (remonté ensuite par
   * `GET /status`) ; on la journalise en plus, sans jamais laisser rejeter une
   * promesse non gérée.
   */
  const triggerRefresh = (userId: number): void => {
    refreshRecommendationQueueForUser(handle, userId, deps.refreshDeps).catch((error) => {
      app.log.error(
        { err: error, userId },
        'Échec du rafraîchissement de la file de recommandations',
      );
    });
  };

  /** Complète le statut de file avec l'erreur de refresh du compte, le cas échéant. */
  const statusWithError = (userId: number) => ({
    ...getQueueStatus(handle, userId, isRefreshInFlight(userId)),
    lastError: readUserRefreshError(handle, userId),
  });

  // Feed paginé, STRICTEMENT local (< 300 ms) : lecture de la file pré-calculée.
  // Modèle v4 : la file ne contient QUE des cartes MEDIA_READY (extrait + image
  // garantis) — le réglage « inclure sans aperçu » a disparu.
  app.get<{ Querystring: { cursor?: string; limit?: string } }>(
    '/api/recommendations',
    { preHandler: requireAuth },
    async (request, reply) => {
      let limit: number | undefined;
      if (request.query.limit !== undefined) {
        const parsed = parsePositiveInt(request.query.limit);
        if (parsed === null) return badRequest(reply, 'La limite doit être un entier positif.');
        limit = parsed;
      }
      const page = listQueueForUser(handle, request.authUser.id, {
        cursor: request.query.cursor ?? null,
        ...(limit !== undefined ? { limit } : {}),
      });
      const status = statusWithError(request.authUser.id);
      // Refill CONTINU : sous le seuil de cartes prêtes, un top-up asynchrone
      // part immédiatement — le feed ne meurt jamais après quelques swipes.
      if (status.readyCount < REFILL_THRESHOLD && !status.refreshing) {
        triggerRefresh(request.authUser.id);
      }
      return { ...page, status };
    },
  );

  // Rafraîchissement ASYNCHRONE de la file : répond 202 immédiatement.
  app.post('/api/recommendations/refresh', { preHandler: requireAuth }, async (request, reply) => {
    const userId = request.authUser.id;
    const alreadyRunning = isRefreshInFlight(userId);
    if (!alreadyRunning) triggerRefresh(userId);
    return reply.code(202).send({
      status: alreadyRunning ? 'already_running' : 'started',
      modelVersion: RECOMMENDATION_MODEL_VERSION,
    });
  });

  // État de la file (taille, fraîcheur, job en cours, DERNIÈRE ERREUR de
  // refresh — PROVIDER_ERROR / SCHEMA_ERROR / UNKNOWN_ERROR) pour l'UI.
  app.get('/api/recommendations/status', { preHandler: requireAuth }, async (request) =>
    statusWithError(request.authUser.id),
  );

  // Swipe : LIKE / DISLIKE / SKIP / OPEN / REQUEST (journal + masquage DISLIKE).
  // LIKE / DISLIKE / REQUEST relancent le job async (le profil a changé).
  app.post<{ Params: { candidateId: string }; Body: { action?: unknown } }>(
    '/api/recommendations/:candidateId/action',
    { preHandler: requireAuth },
    async (request, reply) => {
      const candidateId = parsePositiveInt(request.params.candidateId);
      if (candidateId === null) return badRequest(reply, 'candidateId invalide.');
      const action = request.body?.action;
      if (!isRecommendationAction(action)) {
        return badRequest(reply, 'action doit être LIKE, DISLIKE, SKIP, OPEN ou REQUEST.');
      }
      const { recorded } = recordRecommendationAction(handle, {
        userId: request.authUser.id,
        candidateId,
        action,
      });
      if (!recorded) {
        return reply.code(404).send({
          statusCode: 404,
          error: 'candidate_not_found',
          message: 'Candidat de recommandation inconnu.',
        });
      }
      if (action === 'LIKE' || action === 'DISLIKE' || action === 'REQUEST') {
        triggerRefresh(request.authUser.id);
      }
      return reply.code(201).send({ candidateId, action });
    },
  );

  // Suppression douce : retire l'accès de CE compte (jamais le fichier), les
  // favoris/playlists associés, et masque la piste pour les recommandations.
  app.delete<{ Params: { trackId: string } }>(
    '/api/library/tracks/:trackId',
    { preHandler: requireAuth },
    async (request, reply) => {
      const trackId = parsePositiveInt(request.params.trackId);
      if (trackId === null) return badRequest(reply, 'trackId invalide.');
      const userId = request.authUser.id;

      const track = handle.db
        .select({ id: tracks.id })
        .from(tracks)
        .where(eq(tracks.id, trackId))
        .get();
      const access = handle.db
        .select({ trackId: userTracks.trackId })
        .from(userTracks)
        .where(
          and(
            eq(userTracks.userId, userId),
            eq(userTracks.trackId, trackId),
            eq(userTracks.isVisible, true),
          ),
        )
        .get();
      if (!track || !access) {
        return reply.code(404).send({
          statusCode: 404,
          error: 'not_found',
          message: 'Piste inconnue',
        });
      }

      // revokeTrack masque durablement user_tracks et retire favoris +
      // occurrences dans les playlists de CE seul utilisateur. Le tombstone
      // empêche le backfill du boot de restaurer la piste ; le fichier physique
      // et la ligne tracks restent intacts.
      const { revoked } = revokeTrack(handle, userId, trackId);
      if (!revoked) {
        return reply.code(404).send({
          statusCode: 404,
          error: 'not_found',
          message: 'Piste inconnue',
        });
      }
      handle.db
        .insert(userHiddenTracks)
        .values({
          userId,
          trackId,
          candidateId: null,
          reason: 'REMOVED',
          createdAt: new Date().toISOString(),
        })
        .onConflictDoNothing()
        .run();
      recordAudit(handle, {
        action: 'library.track_removed',
        actorUserId: userId,
        metadata: { trackId },
      });

      // Le retrait pénalise le voisinage : la file doit être régénérée.
      triggerRefresh(userId);

      return { trackId, removed: true };
    },
  );

  // --- Diagnostics OWNER (remplace l'ancien CRUD manuel du catalogue) ------

  app.get(
    '/api/admin/recommendations/health',
    { preHandler: guards.requireAdmin('admin.review') },
    async () => {
      const providerError = readProviderErrorStatus(handle);
      const candidateStats = handle.db
        .select({
          total: sql<number>`count(*)`,
          active: sql<number>`sum(case when is_active then 1 else 0 end)`,
          withPreview: sql<number>`sum(case when preview_url is not null then 1 else 0 end)`,
          reliablePreview: sql<number>`sum(case when preview_url is not null and coalesce(preview_confidence, 0) >= 0.8 then 1 else 0 end)`,
          withEvidence: sql<number>`sum(case when evidence_json is not null then 1 else 0 end)`,
        })
        .from(recommendationCandidates)
        .get();
      const queueStats = handle.db
        .select({
          usersWithQueue: sql<number>`count(distinct user_id)`,
          totalEntries: sql<number>`count(*)`,
          lastGeneratedAt: sql<string | null>`max(generated_at)`,
        })
        .from(userRecommendationQueue)
        .get();
      return {
        status: providerError === null ? 'ok' : 'degraded',
        modelVersion: RECOMMENDATION_MODEL_VERSION,
        providerError,
        providers: {
          similarityGraph: deps.refreshDeps.similarityProvider === null ? 'unconfigured' : 'configured',
          previews: 'ITUNES',
        },
        candidates: {
          total: candidateStats?.total ?? 0,
          active: candidateStats?.active ?? 0,
          withPreview: candidateStats?.withPreview ?? 0,
          reliablePreview: candidateStats?.reliablePreview ?? 0,
          withEvidence: candidateStats?.withEvidence ?? 0,
        },
        queues: {
          usersWithQueue: queueStats?.usersWithQueue ?? 0,
          totalEntries: queueStats?.totalEntries ?? 0,
          lastGeneratedAt: queueStats?.lastGeneratedAt ?? null,
        },
      };
    },
  );

  app.get(
    '/api/admin/recommendations/metrics',
    { preHandler: guards.requireAdmin('admin.review') },
    async () => {
      const since = new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString();
      const actionRows = handle.db
        .select({ action: recommendationEvents.action, n: sql<number>`count(*)` })
        .from(recommendationEvents)
        .groupBy(recommendationEvents.action)
        .all();
      const actions: Record<string, number> = {};
      for (const row of actionRows) actions[row.action] = row.n;
      const impressions24h =
        handle.db
          .select({ n: sql<number>`count(*)` })
          .from(recommendationImpressions)
          .where(gte(recommendationImpressions.shownAt, since))
          .get()?.n ?? 0;
      const impressionsTotal =
        handle.db
          .select({ n: sql<number>`count(*)` })
          .from(recommendationImpressions)
          .get()?.n ?? 0;
      return { actions, impressions: { last24h: impressions24h, total: impressionsTotal } };
    },
  );

  // Vue diagnostic LECTURE SEULE du profil de goût d'un compte : seeds
  // dominants, poids, état de la file et couverture d'extraits. Jamais
  // d'édition manuelle du catalogue ici.
  app.get<{ Params: { userId: string } }>(
    '/api/admin/recommendations/profile/:userId',
    { preHandler: guards.requireAdmin('admin.review') },
    async (request, reply) => {
      const userId = parsePositiveInt(request.params.userId);
      if (userId === null) return badRequest(reply, 'userId invalide.');
      const target = handle.db.select({ id: users.id }).from(users).where(eq(users.id, userId)).get();
      if (!target) {
        return reply
          .code(404)
          .send({ statusCode: 404, error: 'user_not_found', message: 'Utilisateur inconnu.' });
      }
      const profile = buildUserTasteProfile(handle, userId);
      const queueStatus = getQueueStatus(handle, userId, isRefreshInFlight(userId));
      const categoryRows = handle.db
        .select({ category: userRecommendationQueue.category, n: sql<number>`count(*)` })
        .from(userRecommendationQueue)
        .where(eq(userRecommendationQueue.userId, userId))
        .groupBy(userRecommendationQueue.category)
        .all();
      const categories: Record<string, number> = {};
      for (const row of categoryRows) categories[row.category] = row.n;
      return {
        userId,
        modelVersion: RECOMMENDATION_MODEL_VERSION,
        profile: {
          topArtists: profile.topArtists.slice(0, 10).map((name) => ({
            name,
            weight:
              Math.round(
                (profile.artistWeights.get(name.trim().toLowerCase()) ?? 0) * 100,
              ) / 100,
          })),
          trackSeeds: profile.trackSeeds.slice(0, 12).map((seed) => ({
            title: seed.title,
            artist: seed.artist,
            weight: Math.round(seed.weight * 100) / 100,
          })),
          favoriteArtists: profile.favoriteArtists.slice(0, 5),
        },
        queue: { ...queueStatus, categories },
        providerError: readProviderErrorStatus(handle),
      };
    },
  );

  // Diagnostic MÉDIA par utilisateur (OWNER) : entonnoir de la machine à états,
  // couverture d'extraits/pochettes de la file, raisons d'échec et estimation
  // du temps de préparation restant. LECTURE SEULE.
  app.get<{ Params: { userId: string } }>(
    '/api/admin/recommendations/media-health/:userId',
    { preHandler: guards.requireAdmin('admin.review') },
    async (request, reply) => {
      const userId = parsePositiveInt(request.params.userId);
      if (userId === null) return badRequest(reply, 'userId invalide.');
      const target = handle.db.select({ id: users.id }).from(users).where(eq(users.id, userId)).get();
      if (!target) {
        return reply
          .code(404)
          .send({ statusCode: 404, error: 'user_not_found', message: 'Utilisateur inconnu.' });
      }

      // Entonnoir média GLOBAL (candidats partagés entre comptes).
      const statusRows = handle.db
        .select({
          status: recommendationCandidates.mediaResolutionStatus,
          n: sql<number>`count(*)`,
        })
        .from(recommendationCandidates)
        .where(eq(recommendationCandidates.isActive, true))
        .groupBy(recommendationCandidates.mediaResolutionStatus)
        .all();
      const byStatus: Record<string, number> = {};
      for (const row of statusRows) byStatus[row.status] = row.n;
      const get = (s: string) => byStatus[s] ?? 0;

      const reasonRows = handle.db
        .select({
          reason: recommendationCandidates.mediaFailureReason,
          n: sql<number>`count(*)`,
        })
        .from(recommendationCandidates)
        .where(
          and(
            eq(recommendationCandidates.isActive, true),
            sql`${recommendationCandidates.mediaFailureReason} IS NOT NULL`,
          ),
        )
        .groupBy(recommendationCandidates.mediaFailureReason)
        .all();
      const failureReasons: Record<string, number> = {};
      for (const row of reasonRows) if (row.reason) failureReasons[row.reason] = row.n;

      const queue = getQueueStatus(handle, userId, isRefreshInFlight(userId));
      // Estimation grossière du temps restant : candidats encore à résoudre
      // pour atteindre la cible, ~700 ms/candidat, divisés par la concurrence.
      const pendingResolvable = get('DISCOVERED') + get('IDENTITY_RESOLVED') + get('RETRYABLE_ERROR');
      const readyDeficit = Math.max(0, READY_TARGET + RESERVE_TARGET - queue.readyCount);
      const toResolve = Math.min(pendingResolvable, readyDeficit);
      const estimatedRemainingMs = queue.readyCount >= READY_TARGET ? 0 : Math.ceil(toResolve / 5) * 700;

      return {
        userId,
        modelVersion: RECOMMENDATION_MODEL_VERSION,
        providers: {
          catalog: deps.refreshDeps.previewProvider.id,
          similarityGraph: deps.refreshDeps.similarityProvider === null ? 'unconfigured' : 'configured',
        },
        candidates: {
          candidatesDiscovered: get('DISCOVERED') + get('IDENTITY_RESOLVING') + get('IDENTITY_RESOLVED'),
          mediaResolving: get('MEDIA_RESOLVING'),
          mediaReady: get('MEDIA_READY'),
          mediaUnavailable: get('MEDIA_UNAVAILABLE'),
          retryableError: get('RETRYABLE_ERROR'),
          permanentlyRejected: get('PERMANENTLY_REJECTED'),
          noPreview: get('MEDIA_UNAVAILABLE') + get('RETRYABLE_ERROR'),
        },
        failureReasons,
        queue: {
          queueSize: queue.queueSize,
          readyCount: queue.readyCount,
          reserveCount: queue.reserveCount,
          generationStatus: queue.generationStatus,
          refreshing: queue.refreshing,
          targetReady: READY_TARGET,
          targetReserve: RESERVE_TARGET,
        },
        estimatedRemainingMs,
        providerErrors: {
          global: readProviderErrorStatus(handle),
          user: readUserRefreshError(handle, userId),
        },
      };
    },
  );

  app.post<{ Params: { userId: string } }>(
    '/api/admin/recommendations/refresh-user/:userId',
    { preHandler: guards.requireAdmin('admin.review') },
    async (request, reply) => {
      const userId = parsePositiveInt(request.params.userId);
      if (userId === null) return badRequest(reply, 'userId invalide.');
      const target = handle.db.select({ id: users.id }).from(users).where(eq(users.id, userId)).get();
      if (!target) {
        return reply
          .code(404)
          .send({ statusCode: 404, error: 'user_not_found', message: 'Utilisateur inconnu.' });
      }
      // Attendu (pas fire-and-forget) : c'est un outil de maintenance OWNER.
      return refreshRecommendationQueueForUser(handle, userId, deps.refreshDeps);
    },
  );

  // Maintenance manuelle : régénère la file de tous les comptes actifs.
  app.post(
    '/api/admin/recommendations/maintenance',
    { preHandler: guards.requireAdmin('admin.review') },
    async (request, reply) => {
      const activeUsers = handle.db
        .select({ id: users.id })
        .from(users)
        .where(eq(users.isActive, true))
        .all();
      for (const row of activeUsers) triggerRefresh(row.id);
      recordAudit(handle, {
        action: 'admin.recommendations_maintenance',
        actorUserId: request.authUser.id,
        metadata: { users: activeUsers.length },
      });
      return reply.code(202).send({ status: 'started', users: activeUsers.length });
    },
  );
}
