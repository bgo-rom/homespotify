/**
 * Routes de la recherche catalogue (namespace /api/discovery, Phase 9).
 * Authentification OBLIGATOIRE partout ; le diagnostic est réservé au OWNER.
 * Aucun secret, aucun chemin physique, aucune URL arbitraire de l'utilisateur
 * (les IDs sont validés, les URLs sortantes viennent des providers ou d'une
 * relation MusicBrainz — jamais du client).
 */

import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import type { AuthGuards } from '../auth/guards.js';
import type { DiscoveryCatalogService } from '../discovery/catalog/discovery-catalog-service.js';
import {
  CatalogProviderError,
  DISCOVERY_PROVIDER_IDS,
  type CatalogEntityType,
  type DiscoveryProviderId,
} from '../discovery/catalog/types.js';
import { normalizeForMatch } from '../discovery/preview-provider.js';

const ENTITY_TYPES: readonly CatalogEntityType[] = ['track', 'artist', 'album', 'playlist'];
const MIN_QUERY_LENGTH = 2;
const MAX_QUERY_LENGTH = 200;
const MAX_LIMIT = 50;
/** Rate limit par utilisateur : fenêtre glissante d'une minute. */
const RATE_LIMIT_PER_MINUTE = 40;
const SAFE_EXTERNAL_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/u;
const MARKET_RE = /^[A-Z]{2}$/u;

function badRequest(reply: FastifyReply, message: string): FastifyReply {
  return reply.code(400).send({ statusCode: 400, error: 'bad_request', message });
}

function sendProviderError(reply: FastifyReply, error: CatalogProviderError): FastifyReply {
  const statusCode =
    error.category === 'NOT_FOUND'
      ? 404
      : error.category === 'DISABLED'
        ? 503
        : error.category === 'RATE_LIMITED'
          ? 429
          : 502;
  return reply.code(statusCode).send({
    statusCode,
    error: `provider_${error.category.toLowerCase()}`,
    message:
      statusCode === 404
        ? 'Ressource catalogue inconnue.'
        : statusCode === 503
          ? 'Fournisseur désactivé ou non configuré.'
          : 'Le fournisseur externe est momentanément indisponible.',
  });
}

export interface DiscoveryCatalogRouteDeps {
  service: DiscoveryCatalogService;
  discoveryEnabled: boolean;
  now?: () => number;
}

export function registerDiscoveryCatalogRoutes(
  app: FastifyInstance,
  guards: AuthGuards,
  deps: DiscoveryCatalogRouteDeps,
): void {
  const requireAuth = guards.requireAuth();
  const now = deps.now ?? Date.now;
  const rateBuckets = new Map<number, number[]>();

  const rateLimited = (userId: number): boolean => {
    const cutoff = now() - 60_000;
    const bucket = (rateBuckets.get(userId) ?? []).filter((at) => at > cutoff);
    if (bucket.length >= RATE_LIMIT_PER_MINUTE) {
      rateBuckets.set(userId, bucket);
      return true;
    }
    bucket.push(now());
    rateBuckets.set(userId, bucket);
    return false;
  };

  const guardEnabled = (reply: FastifyReply): boolean => {
    if (deps.discoveryEnabled) return true;
    reply.code(503).send({
      statusCode: 503,
      error: 'discovery_disabled',
      message: 'La recherche catalogue est désactivée.',
    });
    return false;
  };

  const parseProvider = (reply: FastifyReply, raw: string): DiscoveryProviderId | null => {
    if ((DISCOVERY_PROVIDER_IDS as readonly string[]).includes(raw)) {
      return raw as DiscoveryProviderId;
    }
    badRequest(reply, 'Fournisseur inconnu.');
    return null;
  };

  const parseExternalId = (reply: FastifyReply, raw: string): string | null => {
    if (SAFE_EXTERNAL_ID_RE.test(raw)) return raw;
    badRequest(reply, 'Identifiant externe invalide.');
    return null;
  };

  const parseMarket = (reply: FastifyReply, raw: string | undefined): string | null | undefined => {
    if (raw === undefined) return undefined;
    const clean = raw.toUpperCase();
    if (MARKET_RE.test(clean)) return clean;
    badRequest(reply, 'market doit être un code pays à deux lettres.');
    return null;
  };

  const checkRate = (request: FastifyRequest, reply: FastifyReply): boolean => {
    if (rateLimited(request.authUser.id)) {
      reply.code(429).send({
        statusCode: 429,
        error: 'rate_limited',
        message: 'Trop de recherches : réessaie dans une minute.',
      });
      return false;
    }
    return true;
  };

  app.get<{
    Querystring: {
      q?: string;
      type?: string;
      limit?: string;
      cursor?: string;
      market?: string;
      providers?: string;
    };
  }>('/api/discovery/search', { preHandler: requireAuth }, async (request, reply) => {
    if (!guardEnabled(reply)) return reply;
    if (!checkRate(request, reply)) return reply;
    const query = (request.query.q ?? '').trim();
    if (query.length < MIN_QUERY_LENGTH) {
      return badRequest(reply, `La recherche exige au moins ${MIN_QUERY_LENGTH} caractères.`);
    }
    if (query.length > MAX_QUERY_LENGTH) {
      return badRequest(reply, `La recherche est limitée à ${MAX_QUERY_LENGTH} caractères.`);
    }
    const type = (request.query.type ?? 'track') as CatalogEntityType;
    if (!ENTITY_TYPES.includes(type)) {
      return badRequest(reply, 'type doit valoir track, artist, album ou playlist.');
    }
    const limit = Number(request.query.limit ?? 20);
    if (!Number.isInteger(limit) || limit < 1 || limit > MAX_LIMIT) {
      return badRequest(reply, `limit doit être un entier entre 1 et ${MAX_LIMIT}.`);
    }
    const market = parseMarket(reply, request.query.market);
    if (market === null) return reply;
    let providerFilter: DiscoveryProviderId[] | undefined;
    if (request.query.providers !== undefined) {
      const parts = request.query.providers.split(',').map((part) => part.trim()).filter(Boolean);
      if (parts.some((part) => !(DISCOVERY_PROVIDER_IDS as readonly string[]).includes(part))) {
        return badRequest(reply, 'providers contient un fournisseur inconnu.');
      }
      providerFilter = parts as DiscoveryProviderId[];
    }
    const cursor = request.query.cursor?.slice(0, 200) ?? null;
    return deps.service.search({
      query,
      type,
      limit,
      cursor,
      ...(market !== undefined ? { market } : {}),
      ...(providerFilter !== undefined ? { providerFilter } : {}),
    });
  });

  app.get('/api/discovery/providers', { preHandler: requireAuth }, async () => ({
    providers: deps.service.publicProviders(),
    defaultMarket: deps.service.market,
    enabled: deps.discoveryEnabled,
  }));

  app.get<{ Params: { provider: string; id: string }; Querystring: { market?: string } }>(
    '/api/discovery/artists/:provider/:id',
    { preHandler: requireAuth },
    async (request, reply) => {
      if (!guardEnabled(reply)) return reply;
      if (!checkRate(request, reply)) return reply;
      const provider = parseProvider(reply, request.params.provider);
      const id = provider === null ? null : parseExternalId(reply, request.params.id);
      if (provider === null || id === null) return reply;
      const market = parseMarket(reply, request.query.market);
      if (market === null) return reply;
      try {
        return await deps.service.getArtist(provider, id, market ?? undefined);
      } catch (error) {
        if (error instanceof CatalogProviderError) return sendProviderError(reply, error);
        throw error;
      }
    },
  );

  app.get<{
    Params: { provider: string; id: string };
    Querystring: { cursor?: string; market?: string };
  }>(
    '/api/discovery/artists/:provider/:id/albums',
    { preHandler: requireAuth },
    async (request, reply) => {
      if (!guardEnabled(reply)) return reply;
      if (!checkRate(request, reply)) return reply;
      const provider = parseProvider(reply, request.params.provider);
      const id = provider === null ? null : parseExternalId(reply, request.params.id);
      if (provider === null || id === null) return reply;
      const market = parseMarket(reply, request.query.market);
      if (market === null) return reply;
      try {
        return await deps.service.getArtistAlbums(
          provider,
          id,
          request.query.cursor?.slice(0, 200) ?? null,
          market ?? undefined,
        );
      } catch (error) {
        if (error instanceof CatalogProviderError) return sendProviderError(reply, error);
        throw error;
      }
    },
  );

  app.get<{ Params: { provider: string; id: string }; Querystring: { market?: string } }>(
    '/api/discovery/albums/:provider/:id',
    { preHandler: requireAuth },
    async (request, reply) => {
      if (!guardEnabled(reply)) return reply;
      if (!checkRate(request, reply)) return reply;
      const provider = parseProvider(reply, request.params.provider);
      const id = provider === null ? null : parseExternalId(reply, request.params.id);
      if (provider === null || id === null) return reply;
      const market = parseMarket(reply, request.query.market);
      if (market === null) return reply;
      try {
        return await deps.service.getAlbum(provider, id, market ?? undefined);
      } catch (error) {
        if (error instanceof CatalogProviderError) return sendProviderError(reply, error);
        throw error;
      }
    },
  );

  app.get<{
    Params: { provider: string; id: string };
    Querystring: { cursor?: string; market?: string };
  }>(
    '/api/discovery/playlists/:provider/:id',
    { preHandler: requireAuth },
    async (request, reply) => {
      if (!guardEnabled(reply)) return reply;
      if (!checkRate(request, reply)) return reply;
      const provider = parseProvider(reply, request.params.provider);
      const id = provider === null ? null : parseExternalId(reply, request.params.id);
      if (provider === null || id === null) return reply;
      const market = parseMarket(reply, request.query.market);
      if (market === null) return reply;
      try {
        return await deps.service.getPlaylist(
          provider,
          id,
          request.query.cursor?.slice(0, 200) ?? null,
          market ?? undefined,
        );
      } catch (error) {
        if (error instanceof CatalogProviderError) return sendProviderError(reply, error);
        throw error;
      }
    },
  );

  app.post<{ Body: Record<string, unknown> }>(
    '/api/discovery/resolve',
    { preHandler: requireAuth },
    async (request, reply) => {
      if (!guardEnabled(reply)) return reply;
      if (!checkRate(request, reply)) return reply;
      const body = request.body ?? {};
      const isrc = typeof body.isrc === 'string' ? body.isrc.trim().toUpperCase() : null;
      if (isrc !== null && !/^[A-Z0-9]{12}$/u.test(isrc)) {
        return badRequest(reply, 'isrc invalide (12 caractères alphanumériques).');
      }
      const title = typeof body.title === 'string' ? body.title.trim().slice(0, 200) : null;
      const artist = typeof body.artist === 'string' ? body.artist.trim().slice(0, 200) : null;
      if (isrc === null && (title === null || title.length < MIN_QUERY_LENGTH)) {
        return badRequest(reply, 'isrc ou title est requis.');
      }
      const entity = await deps.service.resolve({ isrc, title, artist });
      if (entity === null) {
        return reply.code(404).send({
          statusCode: 404,
          error: 'not_resolved',
          message: 'Aucune correspondance fiable.',
        });
      }
      return entity;
    },
  );

  app.get(
    '/api/admin/discovery/health',
    { preHandler: guards.requireAdmin('admin.review') },
    async () => ({
      enabled: deps.discoveryEnabled,
      defaultMarket: deps.service.market,
      ...deps.service.health(),
    }),
  );
}
