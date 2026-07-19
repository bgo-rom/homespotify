/**
 * Orchestration de la recherche catalogue multi-fournisseurs (Phase 9).
 * - appels parallèles avec timeout PAR provider : un provider en panne ne fait
 *   jamais échouer les autres (résultats partiels + statut DEGRADED) ;
 * - cache normalisé (discovery-cache) avec negative caching des erreurs ;
 * - fusion déterministe + classement reproductible (merge.ts) ;
 * - santé par provider (latence, dernière erreur catégorisée) pour le OWNER.
 */

import { DiscoveryCache } from './discovery-cache.js';
import { mergeSearchResults, rankSearchResults } from './merge.js';
import {
  CatalogProviderError,
  type CatalogAlbum,
  type CatalogAlbumPage,
  type CatalogArtist,
  type CatalogEntityType,
  type CatalogPlaylist,
  type CatalogSearchPage,
  type CatalogSearchResult,
  type DiscoveryCatalogProvider,
  type DiscoveryProviderId,
  type ExternalPlatformLink,
  type PlatformAvailabilityStatus,
  type ProviderHealth,
} from './types.js';

export interface RegisteredProvider {
  provider: DiscoveryCatalogProvider | null;
  id: DiscoveryProviderId;
  enabled: boolean;
  /** Raison stable de désactivation (credentials_missing, flag_disabled, tos_unverified). */
  disabledReason: string | null;
}

export interface ProviderRuntimeStatus {
  id: DiscoveryProviderId;
  status: 'OK' | 'DEGRADED' | 'DISABLED';
  latencyMs?: number;
  message?: string;
}

export interface DiscoverySearchResponse {
  items: CatalogSearchResult[];
  nextCursor: string | null;
  providers: ProviderRuntimeStatus[];
}

export interface DiscoveryCatalogServiceOptions {
  providers: RegisteredProvider[];
  cache: DiscoveryCache;
  defaultMarket?: string;
  providerTimeoutMs?: number;
  logger?: {
    info: (context: Record<string, unknown>, message: string) => void;
    warn: (context: Record<string, unknown>, message: string) => void;
  };
  now?: () => number;
}

interface ProviderErrorState {
  category: string;
  at: string;
}

const noopLogger = {
  info: () => undefined,
  warn: () => undefined,
};

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new CatalogProviderError('TIMEOUT', `timeout provider (${ms} ms)`)),
      ms,
    );
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error: unknown) => {
        clearTimeout(timer);
        reject(error instanceof Error ? error : new Error(String(error)));
      },
    );
  });
}

export class DiscoveryCatalogService {
  private readonly providers: RegisteredProvider[];
  private readonly cache: DiscoveryCache;
  private readonly defaultMarket: string;
  private readonly providerTimeoutMs: number;
  private readonly logger: NonNullable<DiscoveryCatalogServiceOptions['logger']>;
  private readonly now: () => number;
  private readonly lastErrors = new Map<DiscoveryProviderId, ProviderErrorState>();
  private readonly lastLatencies = new Map<DiscoveryProviderId, number>();
  private cacheHits = 0;
  private cacheMisses = 0;

  constructor(options: DiscoveryCatalogServiceOptions) {
    this.providers = options.providers;
    this.cache = options.cache;
    this.defaultMarket = options.defaultMarket ?? 'FR';
    this.providerTimeoutMs = options.providerTimeoutMs ?? 6_000;
    this.logger = options.logger ?? noopLogger;
    this.now = options.now ?? Date.now;
  }

  get market(): string {
    return this.defaultMarket;
  }

  private activeProviders(filter?: DiscoveryProviderId[]): RegisteredProvider[] {
    return this.providers.filter(
      (entry) =>
        entry.enabled &&
        entry.provider !== null &&
        (filter === undefined || filter.includes(entry.id)),
    );
  }

  private findProvider(id: string): DiscoveryCatalogProvider {
    const entry = this.providers.find((candidate) => candidate.id === id);
    if (!entry || !entry.enabled || entry.provider === null) {
      throw new CatalogProviderError('DISABLED', `Provider ${id} indisponible`);
    }
    return entry.provider;
  }

  private recordError(id: DiscoveryProviderId, error: unknown): string {
    const category = error instanceof CatalogProviderError ? error.category : 'UPSTREAM_ERROR';
    this.lastErrors.set(id, { category, at: new Date(this.now()).toISOString() });
    return category;
  }

  async search(input: {
    query: string;
    type: CatalogEntityType;
    limit: number;
    cursor: string | null;
    market?: string;
    providerFilter?: DiscoveryProviderId[];
  }): Promise<DiscoverySearchResponse> {
    const market = input.market ?? this.defaultMarket;
    const statuses: ProviderRuntimeStatus[] = [];
    const capability =
      input.type === 'track'
        ? 'SEARCH_TRACKS'
        : input.type === 'artist'
          ? 'SEARCH_ARTISTS'
          : input.type === 'album'
            ? 'SEARCH_ALBUMS'
            : 'SEARCH_PLAYLISTS';
    this.logger.info(
      { type: input.type, market, providers: this.activeProviders(input.providerFilter).length },
      'DISCOVERY_SEARCH_STARTED',
    );

    const candidates = this.activeProviders(input.providerFilter).filter((entry) =>
      entry.provider!.capabilities.has(capability),
    );
    const pages = await Promise.all(
      candidates.map(async (entry): Promise<CatalogSearchPage> => {
        const provider = entry.provider!;
        const queryHash = DiscoveryCache.hashQuery({
          q: input.query.toLowerCase(),
          type: input.type,
          limit: input.limit,
          cursor: input.cursor,
        });
        const cacheKey = { provider: entry.id, operation: 'search', queryHash, market };
        const cached = this.cache.get<CatalogSearchPage>(cacheKey);
        if (cached !== null) {
          this.cacheHits += 1;
          this.logger.info({ provider: entry.id }, 'DISCOVERY_CACHE_HIT');
          if (cached.negative) {
            statuses.push({ id: entry.id, status: 'DEGRADED', message: 'Erreur récente (cache)' });
            return { items: [], nextCursor: null };
          }
          statuses.push({ id: entry.id, status: 'OK', latencyMs: 0 });
          return cached.value!;
        }
        this.cacheMisses += 1;
        this.logger.info({ provider: entry.id }, 'DISCOVERY_CACHE_MISS');
        const startedAt = this.now();
        try {
          this.logger.info({ provider: entry.id }, 'DISCOVERY_PROVIDER_STARTED');
          const page = await withTimeout(
            provider.search({
              query: input.query,
              type: input.type,
              market,
              limit: input.limit,
              cursor: input.cursor,
            }),
            this.providerTimeoutMs,
          );
          const latencyMs = this.now() - startedAt;
          this.lastLatencies.set(entry.id, latencyMs);
          statuses.push({ id: entry.id, status: 'OK', latencyMs });
          this.logger.info({ provider: entry.id, latencyMs, items: page.items.length }, 'DISCOVERY_PROVIDER_COMPLETED');
          this.cache.set(cacheKey, page, { entityType: input.type });
          return page;
        } catch (error) {
          const category = this.recordError(entry.id, error);
          statuses.push({ id: entry.id, status: 'DEGRADED', message: category });
          this.logger.warn(
            { provider: entry.id, category },
            category === 'TIMEOUT'
              ? 'DISCOVERY_PROVIDER_TIMEOUT'
              : category === 'RATE_LIMITED'
                ? 'DISCOVERY_PROVIDER_RATE_LIMITED'
                : 'DISCOVERY_PROVIDER_FAILED',
          );
          this.cache.set(cacheKey, null, { negative: true, entityType: input.type });
          return { items: [], nextCursor: null };
        }
      }),
    );

    for (const entry of this.providers) {
      if (!entry.enabled && (input.providerFilter === undefined || input.providerFilter.includes(entry.id))) {
        statuses.push({ id: entry.id, status: 'DISABLED', message: entry.disabledReason ?? 'disabled' });
      }
    }

    const merged = rankSearchResults(
      mergeSearchResults(pages.map((page) => page.items)),
      input.query,
    ).slice(0, input.limit);
    this.logger.info({ merged: merged.length }, 'DISCOVERY_RESULTS_MERGED');
    // Curseur global = celui du provider prioritaire encore paginable.
    const nextCursor = pages.find((page) => page.nextCursor !== null)?.nextCursor ?? null;
    return { items: merged.map((item) => this.withPlatformSummary(item)), nextCursor, providers: statuses };
  }

  /**
   * Complète les liens d'un résultat avec le statut des plateformes SANS
   * appel réseau : provider désactivé → PROVIDER_DISABLED, aucune preuve →
   * UNKNOWN (jamais « indisponible » sans preuve — Phase 5).
   */
  private withPlatformSummary(result: CatalogSearchResult): CatalogSearchResult {
    const platforms: Array<{ platform: string; providerId: DiscoveryProviderId | null }> = [
      { platform: 'spotify', providerId: 'spotify' },
      { platform: 'apple_music', providerId: 'apple_music' },
      { platform: 'deezer', providerId: 'deezer' },
      { platform: 'tidal', providerId: 'tidal' },
      { platform: 'bandcamp', providerId: null },
      { platform: 'qobuz', providerId: null },
    ];
    const links = [...result.externalLinks];
    for (const { platform, providerId } of platforms) {
      if (links.some((link) => link.platform === platform)) continue;
      let status: PlatformAvailabilityStatus = 'UNKNOWN';
      if (providerId !== null) {
        const entry = this.providers.find((candidate) => candidate.id === providerId);
        if (entry && !entry.enabled) status = 'PROVIDER_DISABLED';
      }
      const placeholder: ExternalPlatformLink = {
        platform,
        url: '',
        status,
        source: 'NONE',
        matchMethod: null,
        confidence: 0,
      };
      links.push(placeholder);
    }
    return { ...result, externalLinks: links };
  }

  private async cachedEntity<T>(
    providerId: string,
    operation: string,
    keyParts: Record<string, unknown>,
    market: string,
    loader: (provider: DiscoveryCatalogProvider) => Promise<T>,
  ): Promise<T> {
    const provider = this.findProvider(providerId);
    const queryHash = DiscoveryCache.hashQuery(keyParts);
    const cacheKey = { provider: provider.id, operation, queryHash, market };
    const cached = this.cache.get<T>(cacheKey);
    if (cached !== null && !cached.negative && cached.value !== null) {
      this.cacheHits += 1;
      return cached.value;
    }
    this.cacheMisses += 1;
    const startedAt = this.now();
    try {
      const value = await withTimeout(loader(provider), this.providerTimeoutMs);
      this.lastLatencies.set(provider.id, this.now() - startedAt);
      this.cache.set(cacheKey, value, { entityType: operation });
      return value;
    } catch (error) {
      this.recordError(provider.id, error);
      throw error;
    }
  }

  async getArtist(providerId: string, id: string, market?: string): Promise<CatalogArtist> {
    const resolvedMarket = market ?? this.defaultMarket;
    return this.cachedEntity(providerId, 'artist', { id }, resolvedMarket, (provider) => {
      if (!provider.getArtist) throw new CatalogProviderError('DISABLED', 'Fiche artiste non supportée');
      return provider.getArtist(id, resolvedMarket);
    });
  }

  async getArtistAlbums(
    providerId: string,
    id: string,
    cursor: string | null,
    market?: string,
  ): Promise<CatalogAlbumPage> {
    const resolvedMarket = market ?? this.defaultMarket;
    return this.cachedEntity(providerId, 'artist_albums', { id, cursor }, resolvedMarket, (provider) => {
      if (!provider.getArtistAlbums) {
        throw new CatalogProviderError('DISABLED', 'Discographie non supportée');
      }
      return provider.getArtistAlbums(id, resolvedMarket, cursor);
    });
  }

  async getAlbum(providerId: string, id: string, market?: string): Promise<CatalogAlbum> {
    const resolvedMarket = market ?? this.defaultMarket;
    return this.cachedEntity(providerId, 'album', { id }, resolvedMarket, (provider) => {
      if (!provider.getAlbum) throw new CatalogProviderError('DISABLED', 'Fiche album non supportée');
      return provider.getAlbum(id, resolvedMarket);
    });
  }

  async getPlaylist(
    providerId: string,
    id: string,
    cursor: string | null,
    market?: string,
  ): Promise<CatalogPlaylist> {
    const resolvedMarket = market ?? this.defaultMarket;
    return this.cachedEntity(providerId, 'playlist', { id, cursor }, resolvedMarket, (provider) => {
      if (!provider.getPlaylist) throw new CatalogProviderError('DISABLED', 'Playlists non supportées');
      return provider.getPlaylist(id, resolvedMarket, cursor);
    });
  }

  /**
   * Résolution de l'entité la plus fiable : ISRC d'abord (tous providers qui
   * le supportent), sinon recherche titre+artiste fusionnée.
   */
  async resolve(input: {
    isrc?: string | null;
    title?: string | null;
    artist?: string | null;
    market?: string;
  }): Promise<CatalogSearchResult | null> {
    const market = input.market ?? this.defaultMarket;
    if (input.isrc) {
      const lists = await Promise.all(
        this.activeProviders()
          .filter((entry) => entry.provider!.capabilities.has('LOOKUP_ISRC'))
          .map(async (entry) => {
            try {
              return await withTimeout(
                entry.provider!.resolveByIsrc!(input.isrc!, market),
                this.providerTimeoutMs,
              );
            } catch (error) {
              this.recordError(entry.id, error);
              return [] as CatalogSearchResult[];
            }
          }),
      );
      const merged = mergeSearchResults(lists);
      if (merged.length > 0) {
        return this.withPlatformSummary(
          rankSearchResults(merged, input.title ?? '')[0]!,
        );
      }
    }
    if (input.title) {
      const query = [input.title, input.artist].filter(Boolean).join(' ');
      const page = await this.search({
        query,
        type: 'track',
        limit: 5,
        cursor: null,
        market,
      });
      return page.items[0] ?? null;
    }
    return null;
  }

  /** Infos publiques (jamais de secret ni de configuration interne). */
  publicProviders(): Array<{
    id: DiscoveryProviderId;
    enabled: boolean;
    capabilities: string[];
    attribution: string | null;
    disabledReason: string | null;
  }> {
    return this.providers.map((entry) => ({
      id: entry.id,
      enabled: entry.enabled,
      capabilities: entry.provider ? [...entry.provider.capabilities] : [],
      attribution: entry.provider?.attribution ?? null,
      disabledReason: entry.enabled ? null : entry.disabledReason,
    }));
  }

  /** Diagnostic OWNER : statut, latence, dernière erreur catégorisée, cache. */
  health(): {
    providers: ProviderHealth[];
    cache: { entries: number; negativeEntries: number; hits: number; misses: number };
  } {
    return {
      providers: this.providers.map((entry) => {
        const lastError = this.lastErrors.get(entry.id) ?? null;
        return {
          id: entry.id,
          status: !entry.enabled ? 'DISABLED' : lastError !== null ? 'DEGRADED' : 'OK',
          lastErrorCategory: lastError?.category ?? null,
          lastErrorAt: lastError?.at ?? null,
          latencyMs: this.lastLatencies.get(entry.id) ?? null,
        };
      }),
      cache: {
        ...this.cache.stats(),
        hits: this.cacheHits,
        misses: this.cacheMisses,
      },
    };
  }
}
