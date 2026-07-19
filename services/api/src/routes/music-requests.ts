import type { FastifyInstance, FastifyReply } from 'fastify';
import {
  MUSIC_REQUEST_ITEM_STATUSES,
  MUSIC_REQUEST_STATUSES,
  type MusicRequestItemStatus,
  type MusicRequestStatus,
} from '../db/schema.js';
import type { AuthGuards } from '../auth/guards.js';
import {
  assignMusicRequestItemTrack,
  cancelMusicRequest,
  createMusicRequest,
  getMusicRequest,
  listAllMusicRequests,
  listMusicRequests,
  MusicRequestError,
  ownerAddMusicRequestItem,
  ownerUpdateMusicRequest,
  ownerUpdateMusicRequestItem,
  reconcileMusicRequestStatus,
  type CreateMusicRequestItemInput,
  type MusicRequestType,
} from '../discovery/music-request-service.js';

const REQUEST_TYPES = ['TRACK', 'ALBUM', 'PLAYLIST'] as const;
const MAX_NOTE_LENGTH = 500;

function badRequest(reply: FastifyReply, message: string): FastifyReply {
  return reply.code(400).send({ statusCode: 400, error: 'bad_request', message });
}

function sendServiceError(reply: FastifyReply, error: MusicRequestError): FastifyReply {
  const statusCode = (() => {
    switch (error.code) {
      case 'candidate_not_found':
      case 'request_not_found':
      case 'request_item_not_found':
      case 'track_not_found':
        return 404;
      case 'already_owned':
      case 'duplicate_active_request':
      case 'cancel_forbidden':
      case 'completed_is_reconciled_only':
        return 409;
      default:
        return 400;
    }
  })();
  return reply.code(statusCode).send({ statusCode, error: error.code, message: error.message });
}

function parseId(reply: FastifyReply, raw: string): number | null {
  const id = Number(raw);
  if (!Number.isInteger(id) || id < 1) {
    badRequest(reply, 'Identifiant invalide.');
    return null;
  }
  return id;
}

function optionalText(value: unknown, maxLength: number): string | null | undefined {
  if (value === undefined) return undefined;
  if (value === null) return null;
  if (typeof value !== 'string') return undefined;
  const clean = value.trim().slice(0, maxLength);
  return clean.length === 0 ? null : clean;
}

function httpUrl(value: unknown): string | null | undefined {
  const clean = optionalText(value, 2000);
  if (clean === undefined || clean === null) return clean;
  try {
    const parsed = new URL(clean);
    return parsed.protocol === 'http:' || parsed.protocol === 'https:' ? parsed.toString() : undefined;
  } catch {
    return undefined;
  }
}

function parseRequestItem(raw: unknown, index: number): CreateMusicRequestItemInput | null {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return null;
  const value = raw as Record<string, unknown>;
  const title = optionalText(value.title, 200);
  if (title === undefined || title === null) return null;
  const durationMs = value.durationMs === undefined || value.durationMs === null
    ? null
    : Number(value.durationMs);
  if (durationMs !== null && (!Number.isInteger(durationMs) || durationMs < 0 || durationMs > 7_200_000)) {
    return null;
  }
  const position = value.position === undefined ? index + 1 : Number(value.position);
  if (!Number.isInteger(position) || position < 1) return null;
  return {
    position,
    title,
    artist: optionalText(value.artist, 200) ?? null,
    album: optionalText(value.album, 200) ?? null,
    durationMs,
    isrc: optionalText(value.isrc, 20)?.toUpperCase() ?? null,
  };
}

/**
 * Routes des demandes. Toutes les entrées sont validées avant le service ;
 * le userId provient exclusivement du token. Les URLs ne sont jamais appelées
 * par le backend et aucun téléchargement automatique n'existe ici.
 */
export function registerMusicRequestRoutes(app: FastifyInstance, guards: AuthGuards): void {
  const handle = app.dbHandle;
  const requireAuth = guards.requireAuth();

  app.post<{ Body: Record<string, unknown> }>(
    '/api/music-requests',
    { preHandler: requireAuth },
    async (request, reply) => {
      const body = request.body ?? {};
      const candidateId = body.candidateId === undefined ? undefined : Number(body.candidateId);
      if (candidateId !== undefined && (!Number.isInteger(candidateId) || candidateId < 1)) {
        return badRequest(reply, 'candidateId doit être un entier positif.');
      }
      const requestTypeRaw = body.requestType ?? 'TRACK';
      if (typeof requestTypeRaw !== 'string' || !(REQUEST_TYPES as readonly string[]).includes(requestTypeRaw)) {
        return badRequest(reply, 'requestType doit valoir TRACK, ALBUM ou PLAYLIST.');
      }
      const requestType = requestTypeRaw as MusicRequestType;
      const title = optionalText(body.title, 200);
      const artist = optionalText(body.artist, 200);
      const album = optionalText(body.album, 200);
      if (candidateId === undefined && (title === undefined || title === null)) {
        return badRequest(reply, 'title est obligatoire pour une demande libre.');
      }
      const externalUrl = httpUrl(body.externalUrl);
      if (body.externalUrl !== undefined && externalUrl === undefined) {
        return badRequest(reply, 'externalUrl doit être une URL HTTP ou HTTPS valide.');
      }
      const coverUrl = httpUrl(body.coverUrl);
      if (body.coverUrl !== undefined && coverUrl === undefined) {
        return badRequest(reply, 'coverUrl doit être une URL HTTP ou HTTPS valide.');
      }
      const rawItems = body.items;
      if (rawItems !== undefined && !Array.isArray(rawItems)) {
        return badRequest(reply, 'items doit être une liste.');
      }
      const items = (rawItems as unknown[] | undefined)?.map(parseRequestItem) ?? [];
      if (items.some((item) => item === null) || items.length > 500) {
        return badRequest(reply, 'Liste de titres invalide (500 maximum).');
      }
      if (requestType === 'PLAYLIST' && externalUrl == null && items.length === 0) {
        return badRequest(reply, 'Une playlist exige un lien externe ou une liste manuelle de titres.');
      }
      let externalSource: string | null = null;
      if (externalUrl) externalSource = new URL(externalUrl).hostname.toLowerCase();
      try {
        const view = createMusicRequest(handle, {
          userId: request.authUser.id,
          ...(candidateId !== undefined ? { candidateId } : {}),
          requestType,
          ...(typeof title === 'string' ? { title } : {}),
          artist: artist ?? null,
          album: album ?? null,
          externalUrl: externalUrl ?? null,
          externalSource,
          coverUrl: coverUrl ?? null,
          userNote: optionalText(body.userNote, MAX_NOTE_LENGTH) ?? null,
          items: items as CreateMusicRequestItemInput[],
        });
        return reply.code(201).send(view);
      } catch (error) {
        if (error instanceof MusicRequestError) return sendServiceError(reply, error);
        throw error;
      }
    },
  );

  app.get('/api/music-requests', { preHandler: requireAuth }, async (request) => ({
    items: listMusicRequests(handle, request.authUser.id),
  }));

  app.get<{ Params: { id: string } }>(
    '/api/music-requests/:id',
    { preHandler: requireAuth },
    async (request, reply) => {
      const id = parseId(reply, request.params.id);
      if (id === null) return reply;
      const view = getMusicRequest(handle, request.authUser.id, id);
      return view ?? reply.code(404).send({
        statusCode: 404,
        error: 'request_not_found',
        message: 'Demande inconnue.',
      });
    },
  );

  app.post<{ Params: { id: string } }>(
    '/api/music-requests/:id/cancel',
    { preHandler: requireAuth },
    async (request, reply) => {
      const id = parseId(reply, request.params.id);
      if (id === null) return reply;
      try {
        return cancelMusicRequest(handle, request.authUser.id, id);
      } catch (error) {
        if (error instanceof MusicRequestError) return sendServiceError(reply, error);
        throw error;
      }
    },
  );

  app.get<{
    Querystring: { userId?: string; type?: string; status?: string; q?: string };
  }>(
    '/api/admin/music-requests',
    { preHandler: guards.requireAdmin('music_request.review') },
    async (request, reply) => {
      const userId = request.query.userId === undefined ? undefined : Number(request.query.userId);
      if (userId !== undefined && (!Number.isInteger(userId) || userId < 1)) {
        return badRequest(reply, 'userId invalide.');
      }
      const type = request.query.type;
      if (type !== undefined && !(REQUEST_TYPES as readonly string[]).includes(type)) {
        return badRequest(reply, 'type invalide.');
      }
      const status = request.query.status;
      if (status !== undefined && !(MUSIC_REQUEST_STATUSES as readonly string[]).includes(status)) {
        return badRequest(reply, 'status invalide.');
      }
      const query = request.query.q?.trim().toLowerCase() ?? '';
      const items = listAllMusicRequests(handle).filter((item) => {
        if (userId !== undefined && item.requestedByUserId !== userId) return false;
        if (type !== undefined && item.requestType !== type) return false;
        if (status !== undefined && item.status !== status) return false;
        if (query.length > 0) {
          const haystack = [item.title, item.artist, item.album, item.requester.displayName, item.requester.username]
            .filter((part): part is string => typeof part === 'string')
            .join(' ')
            .toLowerCase();
          if (!haystack.includes(query)) return false;
        }
        return true;
      });
      return { items };
    },
  );

  app.get<{ Params: { id: string } }>(
    '/api/admin/music-requests/:id',
    { preHandler: guards.requireAdmin('music_request.review') },
    async (request, reply) => {
      const id = parseId(reply, request.params.id);
      if (id === null) return reply;
      return listAllMusicRequests(handle).find((entry) => entry.id === id) ?? reply.code(404).send({
        statusCode: 404,
        error: 'request_not_found',
        message: 'Demande inconnue.',
      });
    },
  );

  app.patch<{ Params: { id: string }; Body: Record<string, unknown> }>(
    '/api/admin/music-requests/:id',
    { preHandler: guards.requireAdmin('music_request.review') },
    async (request, reply) => {
      const id = parseId(reply, request.params.id);
      if (id === null) return reply;
      const body = request.body ?? {};
      const status = body.status;
      if (
        status !== undefined &&
        (typeof status !== 'string' || !(MUSIC_REQUEST_STATUSES as readonly string[]).includes(status))
      ) return badRequest(reply, 'status inconnu.');
      const ownerNote = optionalText(body.ownerNote, MAX_NOTE_LENGTH);
      if (body.ownerNote !== undefined && ownerNote === undefined) {
        return badRequest(reply, 'ownerNote invalide.');
      }
      if (status === undefined && ownerNote === undefined) return badRequest(reply, 'Aucun champ à modifier.');
      try {
        return ownerUpdateMusicRequest(handle, {
          ownerId: request.authUser.id,
          requestId: id,
          ...(status !== undefined ? { status: status as MusicRequestStatus } : {}),
          ...(ownerNote !== undefined ? { ownerNote } : {}),
        });
      } catch (error) {
        if (error instanceof MusicRequestError) return sendServiceError(reply, error);
        throw error;
      }
    },
  );

  app.post<{ Params: { id: string }; Body: Record<string, unknown> }>(
    '/api/admin/music-requests/:id/items',
    { preHandler: guards.requireAdmin('music_request.review') },
    async (request, reply) => {
      const requestId = parseId(reply, request.params.id);
      if (requestId === null) return reply;
      const item = parseRequestItem(request.body ?? {}, 0);
      if (!item) return badRequest(reply, 'Item invalide.');
      try {
        return reply.code(201).send(ownerAddMusicRequestItem(handle, {
          ownerId: request.authUser.id,
          requestId,
          item,
        }));
      } catch (error) {
        if (error instanceof MusicRequestError) return sendServiceError(reply, error);
        throw error;
      }
    },
  );

  app.patch<{ Params: { id: string; itemId: string }; Body: Record<string, unknown> }>(
    '/api/admin/music-requests/:id/items/:itemId',
    { preHandler: guards.requireAdmin('music_request.review') },
    async (request, reply) => {
      const requestId = parseId(reply, request.params.id);
      const itemId = parseId(reply, request.params.itemId);
      if (requestId === null || itemId === null) return reply;
      const status = request.body?.status;
      if (
        status !== undefined &&
        (typeof status !== 'string' || !(MUSIC_REQUEST_ITEM_STATUSES as readonly string[]).includes(status))
      ) return badRequest(reply, 'Statut item invalide.');
      const ownerNote = optionalText(request.body?.ownerNote, MAX_NOTE_LENGTH);
      if (request.body?.ownerNote !== undefined && ownerNote === undefined) {
        return badRequest(reply, 'ownerNote invalide.');
      }
      try {
        return ownerUpdateMusicRequestItem(handle, {
          ownerId: request.authUser.id,
          itemId,
          ...(status !== undefined ? { status: status as MusicRequestItemStatus } : {}),
          ...(request.body.ownerNote !== undefined
            ? { ownerNote: ownerNote ?? null }
            : {}),
        });
      } catch (error) {
        if (error instanceof MusicRequestError) return sendServiceError(reply, error);
        throw error;
      }
    },
  );

  app.post<{ Params: { id: string; itemId: string }; Body: Record<string, unknown> }>(
    '/api/admin/music-requests/:id/items/:itemId/assign-track',
    { preHandler: guards.requireAdmin('music_request.review') },
    async (request, reply) => {
      const requestId = parseId(reply, request.params.id);
      const itemId = parseId(reply, request.params.itemId);
      const trackId = Number(request.body?.trackId);
      if (requestId === null || itemId === null) return reply;
      if (!Number.isInteger(trackId) || trackId < 1) return badRequest(reply, 'trackId invalide.');
      try {
        return assignMusicRequestItemTrack(handle, {
          ownerId: request.authUser.id,
          requestId,
          itemId,
          trackId,
        });
      } catch (error) {
        if (error instanceof MusicRequestError) return sendServiceError(reply, error);
        throw error;
      }
    },
  );

  // Compatibilité avec l'ancien panel : attribue le premier item du TRACK.
  app.post<{ Params: { id: string }; Body: Record<string, unknown> }>(
    '/api/admin/music-requests/:id/assign-track',
    { preHandler: guards.requireAdmin('music_request.review') },
    async (request, reply) => {
      const requestId = parseId(reply, request.params.id);
      const trackId = Number(request.body?.trackId);
      if (requestId === null) return reply;
      if (!Number.isInteger(trackId) || trackId < 1) return badRequest(reply, 'trackId invalide.');
      const requestView = listAllMusicRequests(handle).find((entry) => entry.id === requestId);
      const first = requestView?.items[0];
      if (!first) return badRequest(reply, 'La demande ne contient aucun item.');
      try {
        return assignMusicRequestItemTrack(handle, {
          ownerId: request.authUser.id,
          requestId,
          itemId: first.id,
          trackId,
        });
      } catch (error) {
        if (error instanceof MusicRequestError) return sendServiceError(reply, error);
        throw error;
      }
    },
  );

  app.post<{ Params: { id: string } }>(
    '/api/admin/music-requests/:id/reconcile',
    { preHandler: guards.requireAdmin('music_request.review') },
    async (request, reply) => {
      const id = parseId(reply, request.params.id);
      if (id === null) return reply;
      try {
        return reconcileMusicRequestStatus(handle, id);
      } catch (error) {
        if (error instanceof MusicRequestError) return sendServiceError(reply, error);
        throw error;
      }
    },
  );
}
