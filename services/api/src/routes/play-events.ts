import type { FastifyInstance, FastifyReply } from 'fastify';
import { and, desc, eq, lt, or, sql } from 'drizzle-orm';
import {
  LISTENING_EVENT_TYPES,
  listeningEvents,
  listeningSessions,
  playEvents,
  tracks,
} from '../db/schema.js';
import type { ListeningEventType } from '../db/schema.js';
import type { AuthGuards } from '../auth/guards.js';
import { userCanAccessTrack } from '../library/user-library-service.js';
import { isTrackPublished } from '../library/catalog-service.js';

const MAX_BATCH = 50;
const MAX_CLOCK_SKEW_MS = 5 * 60_000;
const MAX_EVENT_AGE_MS = 30 * 24 * 60 * 60_000;
const RESUME_MAX_AGE_MS = 30 * 24 * 60 * 60_000;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const EVENT_TYPES = new Set<string>(LISTENING_EVENT_TYPES);

function badRequest(reply: FastifyReply, message: string): FastifyReply {
  return reply.code(400).send({ statusCode: 400, error: 'bad_request', message });
}

interface LegacyPlayEventInput {
  trackId?: unknown;
  startedAt?: unknown;
  listenedMs?: unknown;
  completed?: unknown;
}

interface ListeningEventInput {
  clientEventId?: unknown;
  clientSessionId?: unknown;
  installationId?: unknown;
  trackId?: unknown;
  type?: unknown;
  positionMs?: unknown;
  listenedMs?: unknown;
  durationMs?: unknown;
  playbackSpeed?: unknown;
  clientCreatedAt?: unknown;
  metadata?: unknown;
}

interface ParsedListeningEvent {
  clientEventId: string;
  clientSessionId: string;
  installationId: string;
  trackId: number;
  type: ListeningEventType;
  positionMs: number;
  listenedMs: number;
  durationMs: number | null;
  playbackSpeed: number;
  clientCreatedAt: string;
  metadataJson: string | null;
}

function parseEvent(raw: ListeningEventInput, nowMs: number): ParsedListeningEvent | null {
  if (
    typeof raw.clientEventId !== 'string' ||
    !UUID_PATTERN.test(raw.clientEventId) ||
    typeof raw.clientSessionId !== 'string' ||
    !UUID_PATTERN.test(raw.clientSessionId) ||
    typeof raw.installationId !== 'string' ||
    !UUID_PATTERN.test(raw.installationId) ||
    typeof raw.type !== 'string' ||
    !EVENT_TYPES.has(raw.type)
  ) {
    return null;
  }
  const trackId = Number(raw.trackId);
  const positionMs = Number(raw.positionMs);
  const listenedMs = Number(raw.listenedMs);
  const playbackSpeed = Number(raw.playbackSpeed);
  const durationMs = raw.durationMs == null ? null : Number(raw.durationMs);
  const clientTime = typeof raw.clientCreatedAt === 'string' ? Date.parse(raw.clientCreatedAt) : NaN;
  if (
    !Number.isInteger(trackId) ||
    trackId < 1 ||
    !Number.isFinite(positionMs) ||
    positionMs < 0 ||
    !Number.isFinite(listenedMs) ||
    listenedMs < 0 ||
    !Number.isFinite(playbackSpeed) ||
    playbackSpeed < 0.7 ||
    playbackSpeed > 1.3 ||
    (durationMs !== null && (!Number.isFinite(durationMs) || durationMs <= 0)) ||
    !Number.isFinite(clientTime) ||
    clientTime > nowMs + MAX_CLOCK_SKEW_MS ||
    clientTime < nowMs - MAX_EVENT_AGE_MS
  ) {
    return null;
  }
  const roundedDuration = durationMs === null ? null : Math.round(durationMs);
  // À 0,70x le temps mural peut dépasser la durée média. Cette borne tolère
  // la latence et les fins de fichier sans accepter une progression absurde.
  if (
    roundedDuration !== null &&
    listenedMs > Math.round(roundedDuration / 0.7) + 30_000
  ) {
    return null;
  }
  let metadataJson: string | null = null;
  if (raw.metadata !== undefined) {
    if (
      raw.metadata === null ||
      typeof raw.metadata !== 'object' ||
      Array.isArray(raw.metadata)
    ) {
      return null;
    }
    const metadata = raw.metadata as Record<string, unknown>;
    if (Object.keys(metadata).some((key) => key !== 'reason' && key !== 'automatic')) {
      return null;
    }
    if (
      (metadata.reason !== undefined &&
        (typeof metadata.reason !== 'string' || metadata.reason.length > 64)) ||
      (metadata.automatic !== undefined && typeof metadata.automatic !== 'boolean')
    ) {
      return null;
    }
    const encoded = JSON.stringify(metadata);
    if (encoded.length > 1_024) return null;
    metadataJson = encoded;
  }
  return {
    clientEventId: raw.clientEventId,
    clientSessionId: raw.clientSessionId,
    installationId: raw.installationId,
    trackId,
    type: raw.type as ListeningEventType,
    positionMs: Math.round(positionMs),
    listenedMs: Math.round(listenedMs),
    durationMs: roundedDuration,
    playbackSpeed: Math.round(playbackSpeed * 100) / 100,
    clientCreatedAt: new Date(clientTime).toISOString(),
    metadataJson,
  };
}

function sessionState(type: ListeningEventType): {
  status: 'ACTIVE' | 'PAUSED' | 'ENDED';
  endReason: string | null;
} {
  switch (type) {
    case 'PLAY_PAUSED':
      return { status: 'PAUSED', endReason: null };
    case 'PLAY_COMPLETED':
      return { status: 'ENDED', endReason: 'COMPLETED' };
    case 'PLAY_SKIPPED':
      return { status: 'ENDED', endReason: 'SKIPPED' };
    case 'PLAY_STOPPED':
      return { status: 'ENDED', endReason: 'STOPPED' };
    case 'PLAY_ERROR':
      return { status: 'ENDED', endReason: 'ERROR' };
    case 'TRACK_CHANGED':
      return { status: 'ENDED', endReason: 'TRACK_CHANGED' };
    default:
      return { status: 'ACTIVE', endReason: null };
  }
}

function encodeCursor(startedAt: string, id: number): string {
  return Buffer.from(`${startedAt}\n${id}`, 'utf8').toString('base64url');
}

function decodeCursor(cursor: string | undefined): { startedAt: string; id: number } | null {
  if (!cursor) return null;
  try {
    const [startedAt, rawId] = Buffer.from(cursor, 'base64url').toString('utf8').split('\n');
    const id = Number(rawId);
    return startedAt && Number.isInteger(id) && id > 0 ? { startedAt, id } : null;
  } catch {
    return null;
  }
}

/**
 * Compatibilité du signal de recommandation existant + API fiable d'activité.
 * Tous les userId proviennent exclusivement du Bearer token.
 */
export function registerPlayEventRoutes(app: FastifyInstance, guards: AuthGuards): void {
  const handle = app.dbHandle;

  app.post<{ Body: { items?: unknown } }>(
    '/api/play-events',
    { preHandler: guards.requireAuth() },
    async (request, reply) => {
      const raw = request.body?.items;
      if (!Array.isArray(raw) || raw.length === 0) {
        return badRequest(reply, 'items (tableau non vide) est obligatoire.');
      }
      if (raw.length > MAX_BATCH) {
        return badRequest(reply, `Au plus ${MAX_BATCH} événements par lot.`);
      }
      const userId = request.authUser.id;
      let inserted = 0;
      handle.db.transaction((tx) => {
        for (const item of raw as LegacyPlayEventInput[]) {
          const trackId = Number(item?.trackId);
          const listenedMs = Number(item?.listenedMs);
          const startedAt =
            typeof item?.startedAt === 'string' && !Number.isNaN(Date.parse(item.startedAt))
              ? item.startedAt
              : null;
          if (
            !Number.isInteger(trackId) ||
            trackId < 1 ||
            startedAt === null ||
            !Number.isFinite(listenedMs) ||
            listenedMs < 0
          ) {
            continue;
          }
          if (!userCanAccessTrack(handle, userId, trackId)) continue;
          tx.insert(playEvents)
            .values({
              userId,
              trackId,
              startedAt,
              listenedMs: Math.round(listenedMs),
              completed: item?.completed === true,
            })
            .run();
          inserted += 1;
        }
      });
      return reply.code(201).send({ inserted });
    },
  );

  app.post<{ Body: { events?: unknown } }>(
    '/api/play-events/batch',
    { preHandler: guards.requireAuth() },
    async (request, reply) => {
      if (!Array.isArray(request.body?.events) || request.body.events.length === 0) {
        return badRequest(reply, 'events (tableau non vide) est obligatoire.');
      }
      if (request.body.events.length > MAX_BATCH) {
        return badRequest(reply, `Au plus ${MAX_BATCH} événements par lot.`);
      }
      const userId = request.authUser.id;
      const nowMs = Date.now();
      const now = new Date(nowMs).toISOString();
      let accepted = 0;
      let duplicates = 0;
      let rejected = 0;

      handle.db.transaction((tx) => {
        for (const raw of request.body.events as ListeningEventInput[]) {
          const event = parseEvent(raw, nowMs);
          if (event === null) {
            rejected += 1;
            continue;
          }
          const duplicate = tx
            .select({ id: listeningEvents.id })
            .from(listeningEvents)
            .where(
              and(
                eq(listeningEvents.userId, userId),
                eq(listeningEvents.clientEventId, event.clientEventId),
              ),
            )
            .get();
          if (duplicate !== undefined) {
            duplicates += 1;
            continue;
          }
          if (
            !userCanAccessTrack(handle, userId, event.trackId) &&
            !isTrackPublished(handle, event.trackId)
          ) {
            rejected += 1;
            continue;
          }

          let session = tx
            .select()
            .from(listeningSessions)
            .where(
              and(
                eq(listeningSessions.userId, userId),
                eq(listeningSessions.clientSessionId, event.clientSessionId),
              ),
            )
            .get();
          if (session !== undefined && session.trackId !== event.trackId) {
            rejected += 1;
            continue;
          }
          if (session === undefined) {
            const supersededSessions = tx
              .select()
              .from(listeningSessions)
              .where(
                and(
                  eq(listeningSessions.userId, userId),
                  eq(listeningSessions.installationId, event.installationId),
                  or(
                    eq(listeningSessions.status, 'ACTIVE'),
                    eq(listeningSessions.status, 'PAUSED'),
                  ),
                  lt(listeningSessions.latestClientEventAt, event.clientCreatedAt),
                ),
              )
              .all();
            for (const superseded of supersededSessions) {
              const durationMs = superseded.durationMs;
              const completedAtPosition =
                durationMs !== null && superseded.lastPositionMs / durationMs >= 0.9;
              tx.update(listeningSessions)
                .set({
                  status: 'ENDED',
                  endReason: completedAtPosition ? 'COMPLETED_POSITION' : 'SUPERSEDED',
                  endedAt: event.clientCreatedAt,
                  completed: superseded.completed || completedAtPosition,
                  lastActivityAt: now,
                  updatedAt: now,
                })
                .where(eq(listeningSessions.id, superseded.id))
                .run();
            }
            const result = tx
              .insert(listeningSessions)
              .values({
                userId,
                trackId: event.trackId,
                clientSessionId: event.clientSessionId,
                installationId: event.installationId,
                startedAt: event.clientCreatedAt,
                lastActivityAt: now,
                latestClientEventAt: event.clientCreatedAt,
                initialPositionMs: event.positionMs,
                lastPositionMs: event.positionMs,
                durationMs: event.durationMs,
                listenedMs: event.listenedMs,
                playbackSpeed: event.playbackSpeed,
                status: 'ACTIVE',
                qualifiedPlay: false,
                completed: false,
                createdAt: now,
                updatedAt: now,
              })
              .run();
            session = tx
              .select()
              .from(listeningSessions)
              .where(eq(listeningSessions.id, Number(result.lastInsertRowid)))
              .get();
          }
          if (session === undefined) {
            rejected += 1;
            continue;
          }

          tx.insert(listeningEvents)
            .values({
              userId,
              sessionId: session.id,
              clientEventId: event.clientEventId,
              eventType: event.type,
              positionMs: event.positionMs,
              listenedMs: event.listenedMs,
              durationMs: event.durationMs,
              playbackSpeed: event.playbackSpeed,
              clientCreatedAt: event.clientCreatedAt,
              serverReceivedAt: now,
              metadataJson: event.metadataJson,
            })
            .run();

          const isNewest = event.clientCreatedAt >= session.latestClientEventAt;
          const durationMs = event.durationMs ?? session.durationMs;
          const listenedMs = Math.max(session.listenedMs, event.listenedMs);
          const qualifiedThreshold = Math.min(30_000, Math.round((durationMs ?? 60_000) * 0.5));
          const state = sessionState(event.type);
          const terminalNearEnd =
            state.status === 'ENDED' &&
            event.type !== 'PLAY_ERROR' &&
            durationMs !== null &&
            event.positionMs / durationMs >= 0.9;
          const completed =
            session.completed || event.type === 'PLAY_COMPLETED' || terminalNearEnd;
          tx.update(listeningSessions)
            .set({
              lastActivityAt: now,
              latestClientEventAt: isNewest ? event.clientCreatedAt : session.latestClientEventAt,
              lastPositionMs: isNewest ? event.positionMs : session.lastPositionMs,
              durationMs,
              listenedMs,
              playbackSpeed: isNewest ? event.playbackSpeed : session.playbackSpeed,
              status: isNewest ? state.status : session.status,
              endReason: isNewest
                ? terminalNearEnd && event.type !== 'PLAY_COMPLETED'
                  ? 'COMPLETED_POSITION'
                  : state.endReason
                : session.endReason,
              endedAt: isNewest && state.status === 'ENDED' ? event.clientCreatedAt : session.endedAt,
              pauseCount: session.pauseCount + (event.type === 'PLAY_PAUSED' ? 1 : 0),
              seekCount: session.seekCount + (event.type === 'PLAY_SEEKED' ? 1 : 0),
              qualifiedPlay: session.qualifiedPlay || listenedMs >= qualifiedThreshold,
              completed,
              updatedAt: now,
            })
            .where(eq(listeningSessions.id, session.id))
            .run();
          accepted += 1;
        }
      });

      if (accepted > 0) {
        request.log.info({ userId, accepted, duplicates, rejected }, 'LISTENING_BATCH_ACCEPTED');
      }
      return reply.code(201).send({ accepted, duplicates, rejected });
    },
  );

  app.get<{
    Querystring: { limit?: string; cursor?: string; before?: string; trackId?: string };
  }>(
    '/api/me/listening-activity',
    { preHandler: guards.requireAuth() },
    async (request, reply) => {
      const userId = request.authUser.id;
      const limit = Math.min(50, Math.max(1, Number(request.query.limit) || 20));
      const cursor = decodeCursor(request.query.cursor);
      if (request.query.cursor && cursor === null) return badRequest(reply, 'cursor invalide.');
      const trackId = request.query.trackId === undefined ? null : Number(request.query.trackId);
      if (trackId !== null && (!Number.isInteger(trackId) || trackId < 1)) {
        return badRequest(reply, 'trackId invalide.');
      }
      const before = request.query.before ? Date.parse(request.query.before) : NaN;
      if (request.query.before && !Number.isFinite(before)) {
        return badRequest(reply, 'before invalide.');
      }
      const filters = [eq(listeningSessions.userId, userId)];
      if (trackId !== null) filters.push(eq(listeningSessions.trackId, trackId));
      if (Number.isFinite(before)) {
        filters.push(lt(listeningSessions.startedAt, new Date(before).toISOString()));
      }
      if (cursor !== null) {
        filters.push(
          or(
            lt(listeningSessions.startedAt, cursor.startedAt),
            and(
              eq(listeningSessions.startedAt, cursor.startedAt),
              lt(listeningSessions.id, cursor.id),
            ),
          )!,
        );
      }
      const rows = handle.db
        .select({ session: listeningSessions, track: tracks })
        .from(listeningSessions)
        .innerJoin(tracks, eq(tracks.id, listeningSessions.trackId))
        .where(and(...filters))
        .orderBy(desc(listeningSessions.startedAt), desc(listeningSessions.id))
        .limit(limit + 1)
        .all();
      const hasMore = rows.length > limit;
      const page = rows.slice(0, limit);
      const items = page.map(({ session, track }) => {
        const available =
          userCanAccessTrack(handle, userId, track.id) || isTrackPublished(handle, track.id);
        return {
          id: session.id,
          track: {
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            durationMs:
              session.durationMs ??
              (track.durationSeconds === null ? null : Math.round(track.durationSeconds * 1_000)),
            coverUrl: available && track.coverPath ? `/api/tracks/${track.id}/cover` : null,
            available,
          },
          startedAt: session.startedAt,
          endedAt: session.endedAt,
          lastActivityAt: session.lastActivityAt,
          listenedMs: session.listenedMs,
          positionMs: session.lastPositionMs,
          durationMs: session.durationMs,
          status: session.status,
          endReason: session.endReason,
          qualifiedPlay: session.qualifiedPlay,
          completed: session.completed,
        };
      });
      const last = page.at(-1)?.session;
      return reply.send({
        items,
        nextCursor: hasMore && last ? encodeCursor(last.startedAt, last.id) : null,
      });
    },
  );

  app.get(
    '/api/me/resume-listening',
    { preHandler: guards.requireAuth() },
    async (request, reply) => {
      const userId = request.authUser.id;
      const cutoff = new Date(Date.now() - RESUME_MAX_AGE_MS).toISOString();
      const rows = handle.db
        .select({ session: listeningSessions, track: tracks })
        .from(listeningSessions)
        .innerJoin(tracks, eq(tracks.id, listeningSessions.trackId))
        .where(
          and(
            eq(listeningSessions.userId, userId),
            eq(listeningSessions.completed, false),
            sql`${listeningSessions.lastActivityAt} >= ${cutoff}`,
          ),
        )
        .orderBy(desc(listeningSessions.lastActivityAt), desc(listeningSessions.id))
        .limit(100)
        .all();
      const seen = new Set<number>();
      const items = [];
      for (const { session, track } of rows) {
        if (seen.has(track.id)) continue;
        seen.add(track.id);
        const durationMs =
          session.durationMs ??
          (track.durationSeconds === null ? null : Math.round(track.durationSeconds * 1_000));
        if (
          durationMs === null ||
          session.lastPositionMs < 5_000 ||
          session.lastPositionMs / durationMs >= 0.9 ||
          (!userCanAccessTrack(handle, userId, track.id) && !isTrackPublished(handle, track.id))
        ) {
          continue;
        }
        items.push({
          track: {
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            durationMs,
            coverUrl: track.coverPath ? `/api/tracks/${track.id}/cover` : null,
          },
          positionMs: session.lastPositionMs,
          durationMs,
          updatedAt: session.lastActivityAt,
          progress: session.lastPositionMs / durationMs,
        });
        if (items.length >= 20) break;
      }
      return reply.send({ items });
    },
  );

  app.get<{ Params: { id: string } }>(
    '/api/me/tracks/:id/listening-state',
    { preHandler: guards.requireAuth() },
    async (request, reply) => {
      const trackId = Number(request.params.id);
      if (!Number.isInteger(trackId) || trackId < 1) return badRequest(reply, 'id invalide.');
      const userId = request.authUser.id;
      const summary = handle.db
        .select({
          totalListenedMs: sql<number>`coalesce(sum(${listeningSessions.listenedMs}), 0)`,
          qualifiedPlays: sql<number>`coalesce(sum(case when ${listeningSessions.qualifiedPlay} then 1 else 0 end), 0)`,
          completions: sql<number>`coalesce(sum(case when ${listeningSessions.completed} then 1 else 0 end), 0)`,
          lastPlayedAt: sql<string | null>`max(${listeningSessions.lastActivityAt})`,
        })
        .from(listeningSessions)
        .where(
          and(eq(listeningSessions.userId, userId), eq(listeningSessions.trackId, trackId)),
        )
        .get();
      const latest = handle.db
        .select({ positionMs: listeningSessions.lastPositionMs })
        .from(listeningSessions)
        .where(
          and(eq(listeningSessions.userId, userId), eq(listeningSessions.trackId, trackId)),
        )
        .orderBy(desc(listeningSessions.lastActivityAt), desc(listeningSessions.id))
        .get();
      return reply.send({
        lastPositionMs: latest?.positionMs ?? 0,
        qualifiedPlays: summary?.qualifiedPlays ?? 0,
        completions: summary?.completions ?? 0,
        lastPlayedAt: summary?.lastPlayedAt ?? null,
        totalListenedMs: summary?.totalListenedMs ?? 0,
      });
    },
  );

  app.delete(
    '/api/me/listening-activity',
    { preHandler: guards.requireAuth() },
    async (request, reply) => {
      const result = handle.db
        .delete(listeningSessions)
        .where(eq(listeningSessions.userId, request.authUser.id))
        .run();
      request.log.info(
        { userId: request.authUser.id, deletedSessions: result.changes },
        'LISTENING_ACTIVITY_DELETED',
      );
      return reply.code(204).send();
    },
  );
}
