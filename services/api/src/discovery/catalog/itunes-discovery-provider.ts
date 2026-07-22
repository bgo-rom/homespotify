import {
  CatalogProviderError,
  type CatalogAlbum,
  type CatalogAlbumPage,
  type CatalogArtist,
  type CatalogCapability,
  type CatalogEntityType,
  type CatalogImage,
  type CatalogSearchInput,
  type CatalogSearchPage,
  type CatalogSearchResult,
  type DiscoveryCatalogProvider,
  type ExternalPlatformLink,
  type PreviewDescriptor,
  type ProviderReference,
} from './types.js';

interface Options {
  baseUrl?: string;
  market?: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

interface ItunesItem {
  wrapperType: string | undefined;
  artistId: number | undefined;
  artistName: string | undefined;
  artistLinkUrl: string | undefined;
  collectionId: number | undefined;
  collectionName: string | undefined;
  collectionViewUrl: string | undefined;
  collectionType: string | undefined;
  collectionExplicitness: string | undefined;
  trackId: number | undefined;
  trackName: string | undefined;
  trackViewUrl: string | undefined;
  trackTimeMillis: number | undefined;
  trackExplicitness: string | undefined;
  trackCount: number | undefined;
  discNumber: number | undefined;
  trackNumber: number | undefined;
  previewUrl: string | undefined;
  artworkUrl100: string | undefined;
  releaseDate: string | undefined;
  primaryGenreName: string | undefined;
  copyright: string | undefined;
  isrc: string | undefined;
}

function optionalText(value: unknown): string | undefined {
  return typeof value === 'string' && value.trim() ? value.trim() : undefined;
}

function optionalInteger(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isSafeInteger(value) ? value : undefined;
}

function parseItem(value: unknown): ItunesItem | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return null;
  const row = value as Record<string, unknown>;
  return {
    wrapperType: optionalText(row.wrapperType),
    artistId: optionalInteger(row.artistId),
    artistName: optionalText(row.artistName),
    artistLinkUrl: optionalText(row.artistLinkUrl),
    collectionId: optionalInteger(row.collectionId),
    collectionName: optionalText(row.collectionName),
    collectionViewUrl: optionalText(row.collectionViewUrl),
    collectionType: optionalText(row.collectionType),
    collectionExplicitness: optionalText(row.collectionExplicitness),
    trackId: optionalInteger(row.trackId),
    trackName: optionalText(row.trackName),
    trackViewUrl: optionalText(row.trackViewUrl),
    trackTimeMillis: optionalInteger(row.trackTimeMillis),
    trackExplicitness: optionalText(row.trackExplicitness),
    trackCount: optionalInteger(row.trackCount),
    discNumber: optionalInteger(row.discNumber),
    trackNumber: optionalInteger(row.trackNumber),
    previewUrl: optionalText(row.previewUrl),
    artworkUrl100: optionalText(row.artworkUrl100),
    releaseDate: optionalText(row.releaseDate),
    primaryGenreName: optionalText(row.primaryGenreName),
    copyright: optionalText(row.copyright),
    isrc: optionalText(row.isrc),
  };
}

function httpsUrl(raw: string | undefined): string | null {
  if (!raw) return null;
  try {
    const parsed = new URL(raw);
    return parsed.protocol === 'https:' ? parsed.toString() : null;
  } catch {
    return null;
  }
}

function images(raw: string | undefined): CatalogImage[] {
  const url = httpsUrl(raw);
  if (!url) return [];
  return [{ url: url.replace(/100x100(?=bb)/u, '600x600'), width: 600, height: 600 }];
}

function explicitValue(raw: string | undefined): boolean | null {
  if (raw === 'explicit') return true;
  if (raw === 'cleaned' || raw === 'notExplicit') return false;
  return null;
}

function dateOnly(raw: string | undefined): string | null {
  const timestamp = raw ? Date.parse(raw) : Number.NaN;
  return Number.isFinite(timestamp) ? new Date(timestamp).toISOString().slice(0, 10) : null;
}

export class ItunesDiscoveryProvider implements DiscoveryCatalogProvider {
  readonly id = 'itunes' as const;
  readonly capabilities: ReadonlySet<CatalogCapability> = new Set([
    'SEARCH_TRACKS', 'SEARCH_ARTISTS', 'SEARCH_ALBUMS', 'ARTIST_DISCOGRAPHY',
    'ALBUM_TRACKLIST', 'EXTERNAL_LINKS', 'PREVIEW',
  ]);
  readonly attribution = 'Catalogue et aperçus fournis par Apple iTunes';
  private readonly baseUrl: string;
  private readonly market: string;
  private readonly timeoutMs: number;
  private readonly fetchImpl: typeof fetch;

  constructor(options: Options = {}) {
    this.baseUrl = (options.baseUrl ?? 'https://itunes.apple.com').replace(/\/+$/u, '');
    this.market = (options.market ?? 'FR').toUpperCase();
    this.timeoutMs = options.timeoutMs ?? 6_000;
    this.fetchImpl = options.fetchImpl ?? fetch;
  }

  async search(input: CatalogSearchInput): Promise<CatalogSearchPage> {
    if (input.type === 'playlist') return { items: [], nextCursor: null };
    const type: Exclude<CatalogEntityType, 'playlist'> = input.type;
    const entity = type === 'track' ? 'song' : type === 'artist' ? 'musicArtist' : 'album';
    const params = new URLSearchParams({
      term: input.query,
      country: input.market || this.market,
      media: 'music',
      entity,
      limit: String(Math.min(50, input.limit)),
      explicit: 'Yes',
    });
    const rows = await this.request(`/search?${params.toString()}`);
    return {
      items: rows
        .map((row) => this.searchResult(row, type, input.market || this.market))
        .filter((row): row is CatalogSearchResult => row !== null),
      nextCursor: null,
    };
  }

  async getArtist(id: string, market: string): Promise<CatalogArtist> {
    const artistId = this.numericId(id);
    const row = (await this.request(`/lookup?id=${artistId}`)).find((item) => item.artistId === artistId);
    if (!row?.artistName) throw new CatalogProviderError('NOT_FOUND', 'Artiste iTunes inconnu');
    return {
      reference: this.reference('artist', artistId, row.artistLinkUrl, market),
      name: row.artistName,
      disambiguation: null,
      images: [],
      genres: row.primaryGenreName ? [row.primaryGenreName] : [],
      externalLinks: this.links(row.artistLinkUrl, 'ARTIST_ID'),
    };
  }

  async getArtistAlbums(id: string, market: string): Promise<CatalogAlbumPage> {
    const artistId = this.numericId(id);
    const rows = await this.request(`/lookup?${new URLSearchParams({ id: String(artistId), entity: 'album', country: market })}`);
    return {
      items: rows.flatMap((row) => row.collectionId && row.collectionName ? [{
        reference: this.reference('album', row.collectionId, row.collectionViewUrl, market),
        title: row.collectionName,
        albumType: row.collectionType?.toLowerCase() ?? 'album',
        releaseDate: dateOnly(row.releaseDate),
        trackCount: row.trackCount ?? null,
        images: images(row.artworkUrl100),
      }] : []),
      nextCursor: null,
    };
  }

  async getAlbum(id: string, market: string): Promise<CatalogAlbum> {
    const albumId = this.numericId(id);
    const params = new URLSearchParams({ id: String(albumId), entity: 'song', country: market });
    const rows = await this.request(`/lookup?${params}`);
    const collection = rows.find(
      (row) => row.collectionId === albumId && row.wrapperType === 'collection',
    );
    const tracks = rows.filter(
      (row) => row.collectionId === albumId && row.trackId !== undefined && row.trackName,
    );
    const seed = collection ?? tracks[0];
    if (!seed?.collectionName) throw new CatalogProviderError('NOT_FOUND', 'Album iTunes inconnu');
    return {
      reference: this.reference('album', albumId, seed.collectionViewUrl, market),
      title: seed.collectionName,
      artists: seed.artistName ? [{
        name: seed.artistName,
        reference: seed.artistId
          ? this.reference('artist', seed.artistId, seed.artistLinkUrl, market)
          : null,
      }] : [],
      releaseDate: dateOnly(seed.releaseDate),
      albumType: seed.collectionType?.toLowerCase() ?? 'album',
      label: null,
      copyright: seed.copyright ?? null,
      upc: null,
      mbid: null,
      images: images(seed.artworkUrl100),
      discCount: tracks.length ? Math.max(...tracks.map((row) => row.discNumber ?? 1)) : null,
      trackCount: seed.trackCount ?? tracks.length,
      tracks: tracks.map((row, index) => ({
        discNumber: row.discNumber ?? null,
        trackNumber: row.trackNumber ?? null,
        position: index + 1,
        title: row.trackName!,
        artists: row.artistName ? [{ name: row.artistName, reference: null }] : [],
        durationMs: row.trackTimeMillis ?? null,
        explicit: explicitValue(row.trackExplicitness),
        isrc: row.isrc?.toUpperCase() ?? null,
        reference: this.reference('track', row.trackId!, row.trackViewUrl, market),
        preview: this.preview(row.previewUrl),
      })),
      externalLinks: this.links(seed.collectionViewUrl, 'COLLECTION_ID'),
    };
  }

  private searchResult(
    row: ItunesItem,
    type: Exclude<CatalogEntityType, 'playlist'>,
    market: string,
  ): CatalogSearchResult | null {
    const id = type === 'track' ? row.trackId : type === 'artist' ? row.artistId : row.collectionId;
    const title = type === 'track' ? row.trackName : type === 'artist' ? row.artistName : row.collectionName;
    if (id === undefined || !title) return null;
    const rawUrl = type === 'track' ? row.trackViewUrl : type === 'artist' ? row.artistLinkUrl : row.collectionViewUrl;
    const artistReference = row.artistId
      ? this.reference('artist', row.artistId, row.artistLinkUrl, market)
      : null;
    return {
      canonicalKey: `itunes:${type}:${id}`,
      entityType: type,
      title,
      artists: row.artistName ? [{ name: row.artistName, reference: artistReference }] : [],
      album: type === 'track' ? row.collectionName ?? null : type === 'album' ? title : null,
      durationMs: type === 'track' ? row.trackTimeMillis ?? null : null,
      releaseDate: dateOnly(row.releaseDate),
      explicit: explicitValue(type === 'track' ? row.trackExplicitness : row.collectionExplicitness),
      images: type === 'artist' ? [] : images(row.artworkUrl100),
      isrc: row.isrc?.toUpperCase() ?? null,
      upc: null,
      mbid: null,
      trackCount: type === 'album' ? row.trackCount ?? null : null,
      providerReferences: [this.reference(type, id, rawUrl, market)],
      externalLinks: this.links(rawUrl, `${type.toUpperCase()}_ID`),
      preview: type === 'track' ? this.preview(row.previewUrl) : null,
      matchConfidence: 'STRONG',
    };
  }

  private reference(
    entityType: CatalogEntityType,
    id: number,
    rawUrl: string | undefined,
    market: string,
  ): ProviderReference {
    return {
      provider: this.id,
      entityType,
      externalId: String(id),
      externalUrl: httpsUrl(rawUrl),
      market: market.toUpperCase(),
    };
  }

  private links(rawUrl: string | undefined, matchMethod: string): ExternalPlatformLink[] {
    const url = httpsUrl(rawUrl);
    return url ? [{
      platform: 'apple_music',
      url,
      status: 'CONFIRMED',
      source: 'ITUNES_SEARCH_API',
      matchMethod,
      confidence: 1,
    }] : [];
  }

  private preview(rawUrl: string | undefined): PreviewDescriptor | null {
    const url = httpsUrl(rawUrl);
    return url ? {
      provider: this.id,
      url,
      durationMs: 30_000,
      expiresAt: null,
      requiresOfficialSdk: false,
      attribution: this.attribution,
    } : null;
  }

  private numericId(id: string): number {
    if (!/^\d{1,20}$/u.test(id)) throw new CatalogProviderError('NOT_FOUND', 'Identifiant iTunes invalide');
    const value = Number(id);
    if (!Number.isSafeInteger(value)) throw new CatalogProviderError('NOT_FOUND', 'Identifiant iTunes invalide');
    return value;
  }

  private async request(path: string): Promise<ItunesItem[]> {
    let response: Response;
    try {
      response = await this.fetchImpl(`${this.baseUrl}${path}`, {
        headers: { accept: 'application/json' },
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (error) {
      if (error instanceof Error && error.name === 'TimeoutError') {
        throw new CatalogProviderError('TIMEOUT', 'Délai iTunes dépassé');
      }
      throw new CatalogProviderError('UPSTREAM_ERROR', 'iTunes indisponible');
    }
    if (response.status === 429) throw new CatalogProviderError('RATE_LIMITED', 'iTunes limite les requêtes');
    if (!response.ok) throw new CatalogProviderError('UPSTREAM_ERROR', `iTunes HTTP ${response.status}`);
    let body: unknown;
    try {
      body = await response.json();
    } catch {
      throw new CatalogProviderError('INVALID_RESPONSE', 'Réponse iTunes invalide');
    }
    if (typeof body !== 'object' || body === null || Array.isArray(body)) {
      throw new CatalogProviderError('INVALID_RESPONSE', 'Réponse iTunes invalide');
    }
    const results = (body as Record<string, unknown>).results;
    if (!Array.isArray(results)) throw new CatalogProviderError('INVALID_RESPONSE', 'Résultats iTunes absents');
    return results.map(parseItem).filter((row): row is ItunesItem => row !== null);
  }
}
