import { randomUUID } from 'node:crypto';
import { and, desc, eq, inArray, sql } from 'drizzle-orm';
import type { DbHandle } from '../db/client.js';
import {
  ACTIVE_MUSIC_REQUEST_STATUSES,
  musicRequestItems,
  musicRequests,
  recommendationCandidates,
  recommendationEvents,
  tracks,
  users,
  userTracks,
  type MusicRequestItemStatus,
  type MusicRequestStatus,
} from '../db/schema.js';
import { recordAudit } from '../auth/audit.js';
import { grantTrack } from '../library/user-library-service.js';

export type MusicRequestType = 'TRACK' | 'ALBUM' | 'PLAYLIST';

export class MusicRequestError extends Error {
  constructor(
    readonly code:
      | 'candidate_not_found'
      | 'already_owned'
      | 'duplicate_active_request'
      | 'request_not_found'
      | 'request_item_not_found'
      | 'cancel_forbidden'
      | 'invalid_status'
      | 'completed_is_reconciled_only'
      | 'track_not_found',
    message: string,
  ) {
    super(message);
    this.name = 'MusicRequestError';
  }
}

export interface MusicRequestItemView {
  id: number;
  position: number;
  title: string;
  artist: string | null;
  album: string | null;
  durationMs: number | null;
  isrc: string | null;
  resultingTrackId: number | null;
  status: MusicRequestItemStatus;
  ownerNote: string | null;
  presentInRequesterLibrary: boolean;
}

export interface MusicRequestView {
  id: number;
  candidateId: number;
  requestType: MusicRequestType;
  title: string;
  artist: string;
  album: string | null;
  artworkUrl: string | null;
  externalUrl: string | null;
  externalSource: string | null;
  status: MusicRequestStatus;
  userNote: string | null;
  ownerNote: string | null;
  resultingTrackId: number | null;
  requestedItemCount: number;
  completedItemCount: number;
  unavailableItemCount: number;
  presentInRequesterLibrary: boolean;
  items: MusicRequestItemView[];
  createdAt: string;
  updatedAt: string;
  completedAt: string | null;
}

export interface CreateMusicRequestItemInput {
  position?: number;
  title: string;
  artist?: string | null;
  album?: string | null;
  durationMs?: number | null;
  isrc?: string | null;
}

export interface CreateMusicRequestInput {
  userId: number;
  candidateId?: number;
  requestType?: MusicRequestType;
  title?: string;
  artist?: string | null;
  album?: string | null;
  externalUrl?: string | null;
  externalSource?: string | null;
  coverUrl?: string | null;
  userNote?: string | null;
  items?: CreateMusicRequestItemInput[];
}

const ACTIVE_STATUSES: MusicRequestStatus[] = [...ACTIVE_MUSIC_REQUEST_STATUSES];
const OWNER_SETTABLE_STATUSES: MusicRequestStatus[] = [
  'SENT',
  'REVIEWING',
  'APPROVED',
  'SEARCHING_MANUALLY',
  'IMPORTING',
  'REJECTED',
  'FAILED',
];
const CANCELLABLE_STATUSES: MusicRequestStatus[] = [
  'SENT',
  'REVIEWING',
  'APPROVED',
  'SEARCHING_MANUALLY',
];
const TERMINAL_ITEM_STATUSES: MusicRequestItemStatus[] = [
  'COMPLETED',
  'UNAVAILABLE',
  'REJECTED',
  'FAILED',
];

function normalize(value: string | null | undefined): string {
  return (value ?? '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .trim()
    .toLowerCase()
    .replace(/\s+/g, ' ');
}

function findRequestRow(handle: DbHandle, requestId: number) {
  return handle.db.select().from(musicRequests).where(eq(musicRequests.id, requestId)).get();
}

function candidateOf(handle: DbHandle, candidateId: number) {
  return handle.db
    .select()
    .from(recommendationCandidates)
    .where(eq(recommendationCandidates.id, candidateId))
    .get();
}

function userHasTrack(handle: DbHandle, userId: number, trackId: number | null): boolean {
  if (trackId === null) return false;
  return handle.db
    .select({ trackId: userTracks.trackId })
    .from(userTracks)
    .where(
      and(
        eq(userTracks.userId, userId),
        eq(userTracks.trackId, trackId),
        eq(userTracks.isVisible, true),
      ),
    )
    .get() !== undefined;
}

function itemsForRequest(
  handle: DbHandle,
  requestId: number,
  requesterId: number,
): MusicRequestItemView[] {
  return handle.db
    .select()
    .from(musicRequestItems)
    .where(eq(musicRequestItems.musicRequestId, requestId))
    .orderBy(musicRequestItems.position, musicRequestItems.id)
    .all()
    .map((item) => ({
      id: item.id,
      position: item.position,
      title: item.title,
      artist: item.artist,
      album: item.album,
      durationMs: item.durationMs,
      isrc: item.isrc,
      resultingTrackId: item.resultingTrackId,
      status: item.status as MusicRequestItemStatus,
      ownerNote: item.ownerNote,
      presentInRequesterLibrary: userHasTrack(handle, requesterId, item.resultingTrackId),
    }));
}

function toView(
  handle: DbHandle,
  row: typeof musicRequests.$inferSelect,
  candidate: typeof recommendationCandidates.$inferSelect | undefined,
): MusicRequestView {
  const items = itemsForRequest(handle, row.id, row.requestedByUserId);
  return {
    id: row.id,
    candidateId: row.candidateId,
    requestType: (row.requestType || candidate?.itemType || 'TRACK') as MusicRequestType,
    title: row.title || candidate?.title || 'Titre inconnu',
    artist: row.artist || candidate?.artist || 'Artiste inconnu',
    album: row.album ?? candidate?.album ?? null,
    artworkUrl: row.coverUrl ?? candidate?.artworkUrl ?? null,
    externalUrl: row.externalUrl ?? candidate?.externalUrl ?? null,
    externalSource: row.externalSource,
    status: row.status as MusicRequestStatus,
    userNote: row.userNote,
    ownerNote: row.ownerNote,
    resultingTrackId: row.resultingTrackId,
    requestedItemCount: row.requestedItemCount,
    completedItemCount: row.completedItemCount,
    unavailableItemCount: row.unavailableItemCount,
    presentInRequesterLibrary:
      items.length > 0 && items.every((item) => item.presentInRequesterLibrary),
    items,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    completedAt: row.completedAt,
  };
}

function userOwnsIdentity(
  handle: DbHandle,
  userId: number,
  title: string,
  artist: string,
): boolean {
  const rows = handle.db
    .select({ title: tracks.title, artist: tracks.artist })
    .from(userTracks)
    .innerJoin(tracks, eq(tracks.id, userTracks.trackId))
    .where(and(eq(userTracks.userId, userId), eq(userTracks.isVisible, true)))
    .all();
  const key = `${normalize(title)}|${normalize(artist)}`;
  return rows.some((row) => `${normalize(row.title)}|${normalize(row.artist)}` === key);
}

export function createMusicRequest(
  handle: DbHandle,
  input: CreateMusicRequestInput,
): MusicRequestView {
  const candidate = input.candidateId === undefined ? undefined : candidateOf(handle, input.candidateId);
  if (input.candidateId !== undefined && candidate === undefined) {
    throw new MusicRequestError('candidate_not_found', 'Candidat de recommandation inconnu.');
  }
  const requestType = (input.requestType ?? candidate?.itemType ?? 'TRACK') as MusicRequestType;
  const title = input.title?.trim() || candidate?.title || '';
  const artist = input.artist?.trim() || candidate?.artist || '';
  const album = input.album?.trim() || candidate?.album || null;
  if (requestType === 'TRACK' && userOwnsIdentity(handle, input.userId, title, artist)) {
    throw new MusicRequestError('already_owned', 'Cette piste est déjà dans ta bibliothèque.');
  }
  const duplicate = handle.db
    .select({ id: musicRequests.id })
    .from(musicRequests)
    .where(
      and(
        eq(musicRequests.requestedByUserId, input.userId),
        inArray(musicRequests.status, ACTIVE_STATUSES),
        sql`lower(coalesce(${musicRequests.title}, '')) = ${normalize(title)}`,
        sql`lower(coalesce(${musicRequests.artist}, '')) = ${normalize(artist)}`,
        eq(musicRequests.requestType, requestType),
      ),
    )
    .get();
  if (duplicate) {
    throw new MusicRequestError(
      'duplicate_active_request',
      'Une demande est déjà en cours pour cet élément.',
    );
  }

  const itemInputs = input.items?.length
    ? input.items
    : requestType === 'TRACK'
      ? [{ title, artist, album, durationMs: candidate?.durationMs ?? null }]
      : [];
  // Album/playlist déjà ENTIÈREMENT possédé : rien à demander. Un snapshot
  // partiellement possédé reste accepté (les éléments présents seront
  // réconciliés COMPLETED dès l'attribution, sans double demande).
  if (
    (requestType === 'ALBUM' || requestType === 'PLAYLIST') &&
    itemInputs.length > 0 &&
    itemInputs.every((item) =>
      userOwnsIdentity(handle, input.userId, item.title, item.artist ?? ''),
    )
  ) {
    throw new MusicRequestError(
      'already_owned',
      'Tous les titres de cette demande sont déjà dans ta bibliothèque.',
    );
  }
  const now = new Date().toISOString();
  const row = handle.db.transaction((tx) => {
    const requestCandidate = candidate ?? tx
      .insert(recommendationCandidates)
      .values({
        externalId: `manual-request:${randomUUID()}`,
        itemType: requestType,
        title,
        artist,
        album,
        artworkUrl: input.coverUrl ?? null,
        externalUrl: input.externalUrl ?? null,
        source: 'MANUAL',
        isActive: false,
        createdAt: now,
        updatedAt: now,
      })
      .returning()
      .get();
    const inserted = tx
      .insert(musicRequests)
      .values({
        requestedByUserId: input.userId,
        candidateId: requestCandidate.id,
        requestType,
        title,
        artist,
        album,
        externalUrl: input.externalUrl ?? candidate?.externalUrl ?? null,
        externalSource: input.externalSource ?? null,
        coverUrl: input.coverUrl ?? candidate?.artworkUrl ?? null,
        status: 'SENT',
        userNote: input.userNote ?? null,
        requestedItemCount: itemInputs.length,
        completedItemCount: 0,
        unavailableItemCount: 0,
        createdAt: now,
        updatedAt: now,
      })
      .returning()
      .get();
    itemInputs.forEach((item, index) => {
      tx.insert(musicRequestItems)
        .values({
          musicRequestId: inserted.id,
          position: item.position ?? index + 1,
          title: item.title.trim(),
          artist: item.artist?.trim() || null,
          album: item.album?.trim() || null,
          durationMs: item.durationMs ?? null,
          isrc: item.isrc?.trim().toUpperCase() || null,
          status: 'PENDING',
          createdAt: now,
          updatedAt: now,
        })
        .run();
    });
    tx.insert(recommendationEvents)
      .values({
        userId: input.userId,
        candidateId: requestCandidate.id,
        action: 'REQUEST',
        createdAt: now,
      })
      .run();
    return inserted;
  });
  recordAudit(handle, {
    action: 'music_request.created',
    actorUserId: input.userId,
    metadata: { requestId: row.id, requestType, itemCount: itemInputs.length },
  });
  return toView(handle, row, candidateOf(handle, row.candidateId));
}

export function listMusicRequests(handle: DbHandle, userId: number): MusicRequestView[] {
  return handle.db
    .select()
    .from(musicRequests)
    .where(eq(musicRequests.requestedByUserId, userId))
    .orderBy(desc(musicRequests.id))
    .all()
    .map((row) => toView(handle, row, candidateOf(handle, row.candidateId)));
}

export function getMusicRequest(
  handle: DbHandle,
  userId: number,
  requestId: number,
): MusicRequestView | null {
  const row = findRequestRow(handle, requestId);
  if (!row || row.requestedByUserId !== userId) return null;
  return toView(handle, row, candidateOf(handle, row.candidateId));
}

export function cancelMusicRequest(
  handle: DbHandle,
  userId: number,
  requestId: number,
): MusicRequestView {
  const row = findRequestRow(handle, requestId);
  if (!row || row.requestedByUserId !== userId) {
    throw new MusicRequestError('request_not_found', 'Demande inconnue.');
  }
  if (!CANCELLABLE_STATUSES.includes(row.status as MusicRequestStatus)) {
    throw new MusicRequestError('cancel_forbidden', 'Cette demande ne peut plus être annulée.');
  }
  const updated = handle.db
    .update(musicRequests)
    .set({ status: 'CANCELLED', updatedAt: new Date().toISOString() })
    .where(eq(musicRequests.id, requestId))
    .returning()
    .get();
  recordAudit(handle, {
    action: 'music_request.cancelled',
    actorUserId: userId,
    metadata: { requestId, previousStatus: row.status },
  });
  return toView(handle, updated, candidateOf(handle, row.candidateId));
}

export function ownerUpdateMusicRequest(
  handle: DbHandle,
  input: {
    ownerId: number;
    requestId: number;
    status?: MusicRequestStatus;
    ownerNote?: string | null;
  },
): MusicRequestView {
  const row = findRequestRow(handle, input.requestId);
  if (!row) throw new MusicRequestError('request_not_found', 'Demande inconnue.');
  if (input.status === 'COMPLETED' || input.status === 'PARTIALLY_COMPLETED') {
    throw new MusicRequestError(
      'completed_is_reconciled_only',
      'Les statuts de complétion sont calculés uniquement par la réconciliation.',
    );
  }
  if (input.status !== undefined && !OWNER_SETTABLE_STATUSES.includes(input.status)) {
    throw new MusicRequestError('invalid_status', 'Statut non autorisé.');
  }
  handle.db
    .update(musicRequests)
    .set({
      ...(input.status !== undefined ? { status: input.status } : {}),
      ...(input.ownerNote !== undefined ? { ownerNote: input.ownerNote } : {}),
      reviewedByOwnerId: input.ownerId,
      updatedAt: new Date().toISOString(),
    })
    .where(eq(musicRequests.id, input.requestId))
    .run();
  recordAudit(handle, {
    action: 'music_request.updated',
    actorUserId: input.ownerId,
    targetUserId: row.requestedByUserId,
    metadata: { requestId: input.requestId, status: input.status ?? row.status },
  });
  reconcileMusicRequestStatus(handle, input.requestId);
  const fresh = findRequestRow(handle, input.requestId) ?? row;
  return toView(handle, fresh, candidateOf(handle, fresh.candidateId));
}

export function ownerAddMusicRequestItem(
  handle: DbHandle,
  input: { ownerId: number; requestId: number; item: CreateMusicRequestItemInput },
): MusicRequestView {
  const row = findRequestRow(handle, input.requestId);
  if (!row) throw new MusicRequestError('request_not_found', 'Demande inconnue.');
  const nextPosition = (handle.db
    .select({ value: sql<number>`coalesce(max(${musicRequestItems.position}), 0) + 1` })
    .from(musicRequestItems)
    .where(eq(musicRequestItems.musicRequestId, input.requestId))
    .get()?.value ?? 1);
  const now = new Date().toISOString();
  handle.db.insert(musicRequestItems).values({
    musicRequestId: input.requestId,
    position: input.item.position ?? nextPosition,
    title: input.item.title,
    artist: input.item.artist ?? null,
    album: input.item.album ?? null,
    durationMs: input.item.durationMs ?? null,
    isrc: input.item.isrc?.toUpperCase() ?? null,
    status: 'PENDING',
    createdAt: now,
    updatedAt: now,
  }).run();
  recordAudit(handle, {
    action: 'music_request.item_added',
    actorUserId: input.ownerId,
    targetUserId: row.requestedByUserId,
    metadata: { requestId: input.requestId, position: input.item.position ?? nextPosition },
  });
  reconcileMusicRequestStatus(handle, input.requestId);
  return getMusicRequest(handle, row.requestedByUserId, input.requestId)!;
}

export function ownerUpdateMusicRequestItem(
  handle: DbHandle,
  input: {
    ownerId: number;
    itemId: number;
    status?: MusicRequestItemStatus;
    ownerNote?: string | null;
  },
): MusicRequestView {
  const item = handle.db.select().from(musicRequestItems).where(eq(musicRequestItems.id, input.itemId)).get();
  if (!item) throw new MusicRequestError('request_item_not_found', 'Item de demande inconnu.');
  if (input.status === 'COMPLETED') {
    throw new MusicRequestError(
      'completed_is_reconciled_only',
      'COMPLETED est calculé uniquement par la réconciliation.',
    );
  }
  handle.db.update(musicRequestItems).set({
    ...(input.status !== undefined ? { status: input.status } : {}),
    ...(input.ownerNote !== undefined ? { ownerNote: input.ownerNote } : {}),
    updatedAt: new Date().toISOString(),
  }).where(eq(musicRequestItems.id, input.itemId)).run();
  reconcileMusicRequestStatus(handle, item.musicRequestId);
  const request = findRequestRow(handle, item.musicRequestId)!;
  recordAudit(handle, {
    action: 'music_request.item_updated',
    actorUserId: input.ownerId,
    targetUserId: request.requestedByUserId,
    metadata: { requestId: request.id, itemId: input.itemId, status: input.status ?? item.status },
  });
  return toView(handle, request, candidateOf(handle, request.candidateId));
}

export function assignMusicRequestItemTrack(
  handle: DbHandle,
  input: { ownerId: number; requestId: number; itemId: number; trackId: number },
): MusicRequestView {
  const row = findRequestRow(handle, input.requestId);
  if (!row) throw new MusicRequestError('request_not_found', 'Demande inconnue.');
  const item = handle.db.select().from(musicRequestItems).where(
    and(
      eq(musicRequestItems.id, input.itemId),
      eq(musicRequestItems.musicRequestId, input.requestId),
    ),
  ).get();
  if (!item) throw new MusicRequestError('request_item_not_found', 'Item de demande inconnu.');
  const track = handle.db.select({ id: tracks.id }).from(tracks).where(eq(tracks.id, input.trackId)).get();
  if (!track) throw new MusicRequestError('track_not_found', 'Piste inconnue.');
  grantTrack(handle, {
    userId: row.requestedByUserId,
    trackId: input.trackId,
    source: 'ADMIN',
    addedByUserId: input.ownerId,
  });
  const now = new Date().toISOString();
  handle.db.update(musicRequestItems).set({
    resultingTrackId: input.trackId,
    status: 'IMPORTING',
    updatedAt: now,
  }).where(eq(musicRequestItems.id, input.itemId)).run();
  if ((row.requestType || 'TRACK') === 'TRACK') {
    handle.db.update(musicRequests).set({ resultingTrackId: input.trackId, status: 'IMPORTING', updatedAt: now })
      .where(eq(musicRequests.id, row.id)).run();
  }
  recordAudit(handle, {
    action: 'music_request.track_assigned',
    actorUserId: input.ownerId,
    targetUserId: row.requestedByUserId,
    metadata: { requestId: row.id, itemId: item.id, trackId: input.trackId },
  });
  reconcileMusicRequestStatus(handle, row.id);
  const fresh = findRequestRow(handle, row.id)!;
  return toView(handle, fresh, candidateOf(handle, fresh.candidateId));
}

export function listAllMusicRequests(handle: DbHandle) {
  return handle.db
    .select({ request: musicRequests, username: users.username, displayName: users.displayName })
    .from(musicRequests)
    .innerJoin(users, eq(users.id, musicRequests.requestedByUserId))
    .orderBy(desc(musicRequests.id))
    .all()
    .map((row) => {
      const view = toView(handle, row.request, candidateOf(handle, row.request.candidateId));
      return {
        ...view,
        requestedByUserId: row.request.requestedByUserId,
        requester: {
          id: row.request.requestedByUserId,
          username: row.username,
          displayName: row.displayName,
        },
        presentInRequesterLibrary:
          view.requestedItemCount > 0 &&
          view.completedItemCount === view.requestedItemCount,
      };
    });
}

export function reconcileMusicRequestStatus(
  handle: DbHandle,
  requestId: number,
): { status: MusicRequestStatus; changed: boolean } {
  const row = findRequestRow(handle, requestId);
  if (!row) throw new MusicRequestError('request_not_found', 'Demande inconnue.');
  const items = handle.db
    .select()
    .from(musicRequestItems)
    .where(eq(musicRequestItems.musicRequestId, requestId))
    .all();
  const now = new Date().toISOString();
  for (const item of items) {
    const visible = userHasTrack(handle, row.requestedByUserId, item.resultingTrackId);
    if (visible && item.status !== 'COMPLETED') {
      handle.db.update(musicRequestItems).set({ status: 'COMPLETED', updatedAt: now })
        .where(eq(musicRequestItems.id, item.id)).run();
      item.status = 'COMPLETED';
    } else if (!visible && item.status === 'COMPLETED') {
      handle.db.update(musicRequestItems).set({ status: 'IMPORTING', updatedAt: now })
        .where(eq(musicRequestItems.id, item.id)).run();
      item.status = 'IMPORTING';
    }
  }
  const completed = items.filter((item) => item.status === 'COMPLETED').length;
  const unavailable = items.filter((item) => ['UNAVAILABLE', 'REJECTED', 'FAILED'].includes(item.status)).length;
  const allComplete = items.length > 0 && completed === items.length;
  const allTerminal = items.length > 0 && items.every((item) =>
    TERMINAL_ITEM_STATUSES.includes(item.status as MusicRequestItemStatus));
  const partial = completed > 0 && completed < items.length && allTerminal;
  let nextStatus = row.status as MusicRequestStatus;
  if (allComplete) nextStatus = 'COMPLETED';
  else if (partial) nextStatus = 'PARTIALLY_COMPLETED';
  else if (nextStatus === 'COMPLETED' || nextStatus === 'PARTIALLY_COMPLETED') nextStatus = 'IMPORTING';
  const changed =
    nextStatus !== row.status ||
    completed !== row.completedItemCount ||
    unavailable !== row.unavailableItemCount ||
    items.length !== row.requestedItemCount;
  if (changed) {
    handle.db.update(musicRequests).set({
      status: nextStatus,
      requestedItemCount: items.length,
      completedItemCount: completed,
      unavailableItemCount: unavailable,
      completedAt: nextStatus === 'COMPLETED' ? row.completedAt ?? now : null,
      updatedAt: now,
    }).where(eq(musicRequests.id, requestId)).run();
    if (nextStatus === 'COMPLETED' && row.status !== 'COMPLETED') {
      recordAudit(handle, {
        action: 'music_request.completed',
        actorUserId: null,
        targetUserId: row.requestedByUserId,
        metadata: { requestId, itemCount: items.length },
      });
    }
  }
  return { status: nextStatus, changed };
}

export function reconcileAllMusicRequests(handle: DbHandle): { reconciled: number } {
  const rows = handle.db.select({ id: musicRequests.id }).from(musicRequests).all();
  let reconciled = 0;
  for (const row of rows) {
    if (reconcileMusicRequestStatus(handle, row.id).changed) reconciled += 1;
  }
  return { reconciled };
}
