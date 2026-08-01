import { and, asc, eq, gt, inArray, isNull, sql } from 'drizzle-orm';
import type { DbHandle } from '../db/client.js';
import {
  recommendationCandidates,
  recommendationEvents,
  recommendationImpressions,
  tracks,
  userHiddenTracks,
  userRecommendationQueue,
  userTracks,
  RECOMMENDATION_ACTIONS,
  type RecommendationAction,
} from '../db/schema.js';

/**
 * Service de recommandations — côté LECTURE, tout vient de la file
 * pré-calculée `user_recommendation_queue` (cf. recommendation-engine.ts) :
 * aucun appel réseau ni scoring au moment du feed, et JAMAIS de
 * déclenchement de téléchargement.
 */

export interface RecommendationItem {
  id: number;
  externalId: string | null;
  itemType: string;
  title: string;
  artist: string;
  album: string | null;
  artworkUrl: string | null;
  externalUrl: string | null;
  previewUrl: string | null;
  durationMs: number | null;
  genres: string[];
  source: string;
  /** Explication courte affichée sur la carte. */
  reason: string | null;
  reasonCode: string | null;
  /** SAFE | ADJACENT | EXPLORATION. */
  category: string;
  score: number;
  rank: number;
  modelVersion: string;
}

export interface RecommendationPage {
  items: RecommendationItem[];
  /** Curseur opaque à repasser pour la page suivante (null : fin de file). */
  nextCursor: string | null;
}

export const DEFAULT_PAGE_SIZE = 15;
export const MAX_PAGE_SIZE = 20;
export const MIN_PAGE_SIZE = 1;

export const normalizeKey = (value: string): string => value.trim().toLowerCase();

/** previewUrl acceptée seulement si c'est une URL https bien formée. */
function sanitizePreviewUrl(raw: string | null): string | null {
  if (raw === null || raw.trim().length === 0) return null;
  try {
    const url = new URL(raw);
    return url.protocol === 'https:' ? url.toString() : null;
  } catch {
    return null;
  }
}

function parseGenres(genresJson: string | null): string[] {
  if (genresJson === null) return [];
  try {
    const parsed: unknown = JSON.parse(genresJson);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((genre): genre is string => typeof genre === 'string');
  } catch {
    return [];
  }
}

/** Clés (titre|artiste) des pistes visibles de l'utilisateur. */
export function buildOwnedTrackKeys(handle: DbHandle, userId: number): Set<string> {
  const rows = handle.db
    .select({ title: tracks.title, artist: tracks.artist })
    .from(userTracks)
    .innerJoin(tracks, eq(tracks.id, userTracks.trackId))
    .where(and(eq(userTracks.userId, userId), eq(userTracks.isVisible, true)))
    .all();
  return new Set(rows.map((row) => `${normalizeKey(row.title)}|${normalizeKey(row.artist)}`));
}

/** Clés (titre|artiste) des pistes supprimées (soft delete) par l'utilisateur. */
export function buildRemovedTrackKeys(handle: DbHandle, userId: number): Set<string> {
  const rows = handle.db
    .select({ title: tracks.title, artist: tracks.artist })
    .from(userHiddenTracks)
    .innerJoin(tracks, eq(tracks.id, userHiddenTracks.trackId))
    .where(and(eq(userHiddenTracks.userId, userId), sql`${userHiddenTracks.trackId} IS NOT NULL`))
    .all();
  return new Set(rows.map((row) => `${normalizeKey(row.title)}|${normalizeKey(row.artist)}`));
}

/** Ids de candidats exclus : masqués, dislikés (dernier avis) ou déjà demandés. */
export function buildExcludedCandidateIds(handle: DbHandle, userId: number): Set<number> {
  const { db } = handle;
  const excluded = new Set<number>();

  const hiddenRows = db
    .select({ candidateId: userHiddenTracks.candidateId })
    .from(userHiddenTracks)
    .where(
      and(eq(userHiddenTracks.userId, userId), sql`${userHiddenTracks.candidateId} IS NOT NULL`),
    )
    .all();
  for (const row of hiddenRows) {
    if (row.candidateId !== null) excluded.add(row.candidateId);
  }

  // Dernier avis LIKE/DISLIKE par candidat : DISLIKE final = exclu.
  const verdictRows = db
    .select({
      candidateId: recommendationEvents.candidateId,
      action: recommendationEvents.action,
      id: recommendationEvents.id,
    })
    .from(recommendationEvents)
    .where(
      and(
        eq(recommendationEvents.userId, userId),
        inArray(recommendationEvents.action, ['LIKE', 'DISLIKE']),
      ),
    )
    .orderBy(recommendationEvents.id)
    .all();
  const lastVerdict = new Map<number, string>();
  for (const row of verdictRows) lastVerdict.set(row.candidateId, row.action);
  for (const [candidateId, action] of lastVerdict) {
    if (action === 'DISLIKE') excluded.add(candidateId);
  }

  return excluded;
}

export function buildExcludedTrackKeys(handle: DbHandle, userId: number): Set<string> {
  const keys = new Set([
    ...buildOwnedTrackKeys(handle, userId),
    ...buildRemovedTrackKeys(handle, userId),
  ]);
  const disliked = handle.db
    .select({
      title: recommendationCandidates.title,
      artist: recommendationCandidates.artist,
      action: recommendationEvents.action,
      eventId: recommendationEvents.id,
    })
    .from(recommendationEvents)
    .innerJoin(
      recommendationCandidates,
      eq(recommendationCandidates.id, recommendationEvents.candidateId),
    )
    .where(
      and(
        eq(recommendationEvents.userId, userId),
        inArray(recommendationEvents.action, ['LIKE', 'DISLIKE']),
      ),
    )
    .orderBy(recommendationEvents.id)
    .all();
  const verdicts = new Map<string, string>();
  for (const row of disliked) {
    verdicts.set(`${normalizeKey(row.title)}|${normalizeKey(row.artist)}`, row.action);
  }
  for (const [key, action] of verdicts) if (action === 'DISLIKE') keys.add(key);

  return keys;
}

export interface QueuePageOptions {
  cursor?: string | null;
  limit?: number;
}

/** Confiance minimale d'un extrait pour le feed standard (miroir moteur). */
const SERVE_PREVIEW_CONFIDENCE_FLOOR = 0.8;

/**
 * Porte média du feed. Le modèle v4 n'insère QUE des MEDIA_READY dans la file :
 * cette porte est une DOUBLE SÉCURITÉ (jamais de carte muette/sans image même
 * si une file legacy traînait) — extrait https fiable ET pochette présents.
 */
function previewGate() {
  return sql`${recommendationCandidates.previewUrl} IS NOT NULL
    AND coalesce(${recommendationCandidates.previewConfidence}, 0) >= ${SERVE_PREVIEW_CONFIDENCE_FLOOR}
    AND ${recommendationCandidates.artworkUrl} IS NOT NULL`;
}

function parseCursor(raw: string | null | undefined): number {
  if (raw === null || raw === undefined || raw.trim().length === 0) return 0;
  const value = Number(raw);
  return Number.isInteger(value) && value >= 0 ? value : 0;
}

/**
 * Lit une page de la file pré-calculée. STRICTEMENT local (< 300 ms) : aucun
 * appel externe, aucun scoring. Chaque carte servie est journalisée dans
 * `recommendation_impressions`.
 */
export function listQueueForUser(
  handle: DbHandle,
  userId: number,
  options: QueuePageOptions = {},
): RecommendationPage {
  const limit = Math.max(
    MIN_PAGE_SIZE,
    Math.min(options.limit ?? DEFAULT_PAGE_SIZE, MAX_PAGE_SIZE),
  );
  const afterRank = parseCursor(options.cursor);
  const nowIso = new Date().toISOString();

  const rows = handle.db
    .select({
      queue: userRecommendationQueue,
      candidate: recommendationCandidates,
    })
    .from(userRecommendationQueue)
    .innerJoin(
      recommendationCandidates,
      eq(recommendationCandidates.id, userRecommendationQueue.candidateId),
    )
    .where(
      and(
        eq(userRecommendationQueue.userId, userId),
        gt(userRecommendationQueue.rank, afterRank),
        eq(recommendationCandidates.isActive, true),
        previewGate(),
      ),
    )
    .orderBy(asc(userRecommendationQueue.rank))
    .limit(limit)
    .all();

  // Marque les cartes réellement servies (comptage « prêtes non vues » du
  // refill continu) — sans jamais réétiqueter une carte déjà servie.
  if (rows.length > 0) {
    handle.db
      .update(userRecommendationQueue)
      .set({ servedAt: nowIso })
      .where(
        and(
          eq(userRecommendationQueue.userId, userId),
          inArray(
            userRecommendationQueue.candidateId,
            rows.map((row) => row.candidate.id),
          ),
          isNull(userRecommendationQueue.servedAt),
        ),
      )
      .run();
  }

  const items: RecommendationItem[] = rows.map(({ queue, candidate }) => ({
    id: candidate.id,
    externalId: candidate.externalId,
    itemType: candidate.itemType,
    title: candidate.title,
    artist: candidate.artist,
    album: candidate.album,
    artworkUrl: candidate.artworkUrl,
    externalUrl: candidate.externalUrl,
    previewUrl: sanitizePreviewUrl(candidate.previewUrl),
    durationMs: candidate.durationMs,
    genres: parseGenres(candidate.genresJson),
    source: candidate.source,
    reason: queue.reasonText,
    reasonCode: queue.reasonCode,
    category: queue.category,
    score: queue.score,
    rank: queue.rank,
    modelVersion: queue.modelVersion,
  }));

  // Journal d'exposition (append-only, par compte).
  handle.db.transaction((tx) => {
    for (const [index, row] of rows.entries()) {
      tx.insert(recommendationImpressions)
        .values({
          userId,
          candidateId: row.candidate.id,
          shownAt: nowIso,
          position: afterRank + index + 1,
          modelVersion: row.queue.modelVersion,
          reasonCode: row.queue.reasonCode,
        })
        .run();
    }
  });

  const lastRow = rows[rows.length - 1];
  const nextCursor = rows.length === limit && lastRow !== undefined
    ? String(lastRow.queue.rank)
    : null;
  return { items, nextCursor };
}

export interface QueueStatus {
  queueSize: number;
  /** Cartes pas encore servies passant la porte extrait (feed standard). */
  readyCount: number;
  /** Cartes pas encore servies, toutes portes confondues (réserve). */
  reserveCount: number;
  lastGeneratedAt: string | null;
  expiresAt: string | null;
  modelVersion: string | null;
  refreshing: boolean;
  /** EMPTY : aucune file. READY : cartes disponibles. REFRESHING : job en
   *  cours. EXHAUSTED : tout a été servi et rien n'attend. */
  generationStatus: 'EMPTY' | 'READY' | 'REFRESHING' | 'EXHAUSTED';
}

export function getQueueStatus(handle: DbHandle, userId: number, refreshing: boolean): QueueStatus {
  const first = handle.db
    .select({
      generatedAt: userRecommendationQueue.generatedAt,
      expiresAt: userRecommendationQueue.expiresAt,
      modelVersion: userRecommendationQueue.modelVersion,
    })
    .from(userRecommendationQueue)
    .where(eq(userRecommendationQueue.userId, userId))
    .orderBy(asc(userRecommendationQueue.rank))
    .limit(1)
    .get();
  const counts = handle.db
    .select({
      total: sql<number>`count(*)`,
      unserved: sql<number>`sum(case when ${userRecommendationQueue.servedAt} is null then 1 else 0 end)`,
      ready: sql<number>`sum(case when ${userRecommendationQueue.servedAt} is null
        and ${recommendationCandidates.previewUrl} is not null
        and coalesce(${recommendationCandidates.previewConfidence}, 0) >= ${SERVE_PREVIEW_CONFIDENCE_FLOOR}
        and ${recommendationCandidates.artworkUrl} is not null
        then 1 else 0 end)`,
    })
    .from(userRecommendationQueue)
    .innerJoin(
      recommendationCandidates,
      eq(recommendationCandidates.id, userRecommendationQueue.candidateId),
    )
    .where(
      and(
        eq(userRecommendationQueue.userId, userId),
        eq(recommendationCandidates.isActive, true),
      ),
    )
    .get() ?? { total: 0, unserved: 0, ready: 0 };
  const size = counts.total;
  const reserveCount = counts.unserved ?? 0;
  return {
    queueSize: size,
    readyCount: counts.ready ?? 0,
    reserveCount,
    lastGeneratedAt: first?.generatedAt ?? null,
    expiresAt: first?.expiresAt ?? null,
    modelVersion: first?.modelVersion ?? null,
    refreshing,
    generationStatus: refreshing
      ? 'REFRESHING'
      : size === 0
        ? 'EMPTY'
        : reserveCount === 0
          ? 'EXHAUSTED'
          : 'READY',
  };
}

/** true si l'action fait partie du vocabulaire de swipe accepté. */
export function isRecommendationAction(value: unknown): value is RecommendationAction {
  return (
    typeof value === 'string' &&
    (RECOMMENDATION_ACTIONS as readonly string[]).includes(value)
  );
}

/**
 * Enregistre un swipe. DISLIKE crée aussi l'entrée `user_hidden_tracks`
 * (raison DISLIKED) qui bloque les futures recommandations ; LIKE retire un
 * éventuel masquage DISLIKED antérieur (l'utilisateur a changé d'avis).
 * DISLIKE retire aussi immédiatement le candidat de la file pré-calculée.
 */
export function recordRecommendationAction(
  handle: DbHandle,
  input: { userId: number; candidateId: number; action: RecommendationAction },
): { recorded: boolean } {
  const candidate = handle.db
    .select({ id: recommendationCandidates.id })
    .from(recommendationCandidates)
    .where(eq(recommendationCandidates.id, input.candidateId))
    .get();
  if (!candidate) return { recorded: false };

  const now = new Date().toISOString();
  handle.db.transaction((tx) => {
    tx.insert(recommendationEvents)
      .values({
        userId: input.userId,
        candidateId: input.candidateId,
        action: input.action,
        createdAt: now,
      })
      .run();
    if (input.action === 'DISLIKE') {
      tx.insert(userHiddenTracks)
        .values({
          userId: input.userId,
          trackId: null,
          candidateId: input.candidateId,
          reason: 'DISLIKED',
          createdAt: now,
        })
        .onConflictDoNothing()
        .run();
      // Exclusion permanente : purge immédiate de la file (le prochain
      // rafraîchissement ne le remettra pas — cf. buildExcludedCandidateIds).
      tx.delete(userRecommendationQueue)
        .where(
          and(
            eq(userRecommendationQueue.userId, input.userId),
            eq(userRecommendationQueue.candidateId, input.candidateId),
          ),
        )
        .run();
    } else if (input.action === 'LIKE') {
      tx.delete(userHiddenTracks)
        .where(
          and(
            eq(userHiddenTracks.userId, input.userId),
            eq(userHiddenTracks.candidateId, input.candidateId),
            eq(userHiddenTracks.reason, 'DISLIKED'),
          ),
        )
        .run();
    }
  });
  return { recorded: true };
}
