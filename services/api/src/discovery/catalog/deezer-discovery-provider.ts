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

interface DeezerDiscoveryProviderOptions {
  baseUrl?: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

type JsonObject = Record<string, unknown>;

function object(value: unknown): JsonObject | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as JsonObject
    : null;
}

function text(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
}

function integer(value: unknown): number | null {
  return typeof value === 'number' && Number.isSafeInteger(value) ? value : null;
}

function identifier(value: unknown): string | null {
  const numeric = integer(value);
  if (numeric !== null && numeric >= 0) return String(numeric);
  const raw = text(value);
  return raw && /^\d{1,20}$/u.test(raw) ? raw : null;
}

function httpsUrl(value: unknown): string | null {
  const raw = text(value);
  if (!raw) return null;
  try {
    const parsed = new URL(raw);
    return parsed.protocol === 'https:' ? parsed.toString() : null;
  } catch {
    return null;
  }
}

function signedUrlExpiry(url: string): string | null {
  const token = new URL(url).searchParams.get('hdnea');
  const rawExpiry = token?.match(/(?:^|~)exp=(\d{1,12})(?:~|$)/u)?.[1];
  if (!rawExpiry) return null;
  const timestampMs = Number(rawExpiry) * 1000;
  if (!Number.isSafeInteger(timestampMs) || timestampMs <= 0) return null;
  return new Date(timestampMs).toISOString();
}

function image(value: unknown, size: number): CatalogImage[] {
  const url = httpsUrl(value);
  return url ? [{ url, width: size, height: size }] : [];
}

function dateOnly(value: unknown): string | null {
  const raw = text(value);
  if (!raw || !/^\d{4}-\d{2}-\d{2}$/u.test(raw)) return null;
  return raw;
}

function dataRows(body: JsonObject): JsonObject[] {
  const data = body.data;
  return Array.isArray(data) ? data.map(object).filter((row): row is JsonObject => row !== null) : [];
}

function normalizedArtistName(value: unknown): string {
  return (text(value) ?? '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/gu, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/gu, ' ')
    .trim();
}

interface ArtistEvidence {
  count: number;
  rank: number;
}

export class DeezerDiscoveryProvider implements DiscoveryCatalogProvider {
  readonly id = 'deezer' as const;
  readonly capabilities: ReadonlySet<CatalogCapability> = new Set([
    'SEARCH_TRACKS',
    'SEARCH_ARTISTS',
    'SEARCH_ALBUMS',
    'LOOKUP_ISRC',
    'ARTIST_DISCOGRAPHY',
    'ALBUM_TRACKLIST',
    'EXTERNAL_LINKS',
    'PREVIEW',
  ]);
  readonly attribution = 'Catalogue, images et aperçus fournis par Deezer';

  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly fetchImpl: typeof fetch;

  constructor(options: DeezerDiscoveryProviderOptions = {}) {
    this.baseUrl = (options.baseUrl ?? 'https://api.deezer.com').replace(/\/+$/u, '');
    this.timeoutMs = options.timeoutMs ?? 6_000;
    this.fetchImpl = options.fetchImpl ?? fetch;
  }

  async search(input: CatalogSearchInput): Promise<CatalogSearchPage> {
    if (input.type === 'playlist') return { items: [], nextCursor: null };
    const type: Exclude<CatalogEntityType, 'playlist'> = input.type;
    const offset = this.offset(input.cursor);
    const path = type === 'track' ? '/search' : `/search/${type}`;
    const params = new URLSearchParams({
      q: input.query,
      limit: String(Math.min(50, input.limit)),
      index: String(offset),
      output: 'json',
    });
    const mainRequest = this.request(`${path}?${params}`);
    const evidenceRequest = type === 'artist'
      ? this.request(`/search?${new URLSearchParams({
          q: input.query,
          limit: '50',
          index: '0',
          output: 'json',
        })}`).catch(() => null)
      : Promise.resolve(null);
    const [body, evidenceBody] = await Promise.all([mainRequest, evidenceRequest]);
    const rawRows = dataRows(body);
    const rows = type === 'artist'
      ? this.rankArtistRows(rawRows, evidenceBody, input.query)
      : rawRows;
    const total = integer(body.total) ?? rows.length;
    return {
      items: rows
        .map((row) => this.searchResult(row, type, input.market))
        .filter((row): row is CatalogSearchResult => row !== null),
      nextCursor: offset + rows.length < total ? String(offset + rows.length) : null,
    };
  }

  async resolveByIsrc(isrc: string, market: string): Promise<CatalogSearchResult[]> {
    if (!/^[A-Z]{2}[A-Z0-9]{3}\d{7}$/u.test(isrc.toUpperCase())) return [];
    try {
      const row = await this.request(`/track/isrc:${encodeURIComponent(isrc.toUpperCase())}`);
      const result = this.searchResult(row, 'track', market);
      return result ? [{ ...result, isrc: isrc.toUpperCase(), matchConfidence: 'EXACT' }] : [];
    } catch (error) {
      if (error instanceof CatalogProviderError && error.category === 'NOT_FOUND') return [];
      throw error;
    }
  }

  async getArtist(id: string, market: string): Promise<CatalogArtist> {
    const row = await this.request(`/artist/${this.numericId(id)}`);
    const name = text(row.name);
    if (!name) throw new CatalogProviderError('NOT_FOUND', 'Artiste Deezer inconnu');
    return {
      reference: this.reference('artist', id, row.link, market),
      name,
      disambiguation: null,
      images: image(row.picture_xl ?? row.picture_big ?? row.picture_medium, 1000),
      genres: [],
      externalLinks: this.links(row.link, 'ARTIST_ID'),
    };
  }

  async getArtistAlbums(
    id: string,
    market: string,
    cursor?: string | null,
  ): Promise<CatalogAlbumPage> {
    const offset = this.offset(cursor ?? null);
    const params = new URLSearchParams({ limit: '50', index: String(offset), output: 'json' });
    const body = await this.request(`/artist/${this.numericId(id)}/albums?${params}`);
    const rows = dataRows(body);
    const total = integer(body.total) ?? rows.length;
    return {
      items: rows.flatMap((row) => {
        const albumId = identifier(row.id);
        const title = text(row.title);
        if (!albumId || !title) return [];
        return [{
          reference: this.reference('album', albumId, row.link, market),
          title,
          albumType: text(row.record_type),
          releaseDate: dateOnly(row.release_date),
          trackCount: integer(row.nb_tracks),
          images: image(row.cover_xl ?? row.cover_big ?? row.cover_medium, 1000),
        }];
      }),
      nextCursor: offset + rows.length < total ? String(offset + rows.length) : null,
    };
  }

  async getAlbum(id: string, market: string): Promise<CatalogAlbum> {
    const row = await this.request(`/album/${this.numericId(id)}`);
    const albumId = identifier(row.id);
    const title = text(row.title);
    if (!albumId || !title) throw new CatalogProviderError('NOT_FOUND', 'Album Deezer inconnu');
    const artist = object(row.artist);
    const albumImages = image(row.cover_xl ?? row.cover_big ?? row.cover_medium, 1000);
    const tracksContainer = object(row.tracks);
    const tracks = tracksContainer ? dataRows(tracksContainer) : [];
    return {
      reference: this.reference('album', albumId, row.link, market),
      title,
      artists: this.artistSummaries(artist, market),
      releaseDate: dateOnly(row.release_date),
      albumType: text(row.record_type),
      label: text(row.label),
      copyright: null,
      upc: text(row.upc),
      mbid: null,
      images: albumImages,
      discCount: tracks.length > 0
        ? Math.max(...tracks.map((track) => integer(track.disk_number) ?? 1))
        : null,
      trackCount: integer(row.nb_tracks) ?? tracks.length,
      tracks: tracks.flatMap((track, index) => {
        const trackId = identifier(track.id);
        const trackTitle = text(track.title);
        if (!trackId || !trackTitle) return [];
        return [{
          discNumber: integer(track.disk_number),
          trackNumber: integer(track.track_position),
          position: index + 1,
          title: trackTitle,
          artists: this.artistSummaries(object(track.artist), market),
          durationMs: integer(track.duration) === null ? null : integer(track.duration)! * 1000,
          explicit: typeof track.explicit_lyrics === 'boolean' ? track.explicit_lyrics : null,
          isrc: text(track.isrc)?.toUpperCase() ?? null,
          reference: this.reference('track', trackId, track.link, market),
          preview: this.preview(track.preview),
        }];
      }),
      externalLinks: this.links(row.link, 'ALBUM_ID'),
    };
  }

  private searchResult(
    row: JsonObject,
    type: Exclude<CatalogEntityType, 'playlist'>,
    market: string,
  ): CatalogSearchResult | null {
    const id = identifier(row.id);
    const title = text(row.title ?? row.name);
    if (!id || !title) return null;
    const artist = type === 'artist' ? row : object(row.artist);
    const album = object(row.album);
    const artistName = text(artist?.name);
    const images = type === 'artist'
      ? image(row.picture_xl ?? row.picture_big ?? row.picture_medium, 1000)
      : image(
          type === 'album'
            ? row.cover_xl ?? row.cover_big ?? row.cover_medium
            : album?.cover_xl ?? album?.cover_big ?? album?.cover_medium,
          1000,
        );
    const durationSeconds = integer(row.duration);
    return {
      canonicalKey: `deezer:${type}:${id}`,
      entityType: type,
      title,
      artists: artistName ? this.artistSummaries(artist ?? null, market) : [],
      album: type === 'track' ? text(album?.title) : type === 'album' ? title : null,
      durationMs: type === 'track' && durationSeconds !== null ? durationSeconds * 1000 : null,
      releaseDate: dateOnly(row.release_date),
      explicit: type === 'track' && typeof row.explicit_lyrics === 'boolean'
        ? row.explicit_lyrics
        : null,
      images,
      isrc: type === 'track' ? text(row.isrc)?.toUpperCase() ?? null : null,
      upc: type === 'album' ? text(row.upc) : null,
      mbid: null,
      trackCount: type === 'album' ? integer(row.nb_tracks) : null,
      providerReferences: [this.reference(type, id, row.link, market)],
      externalLinks: this.links(row.link, `${type.toUpperCase()}_ID`),
      preview: type === 'track' ? this.preview(row.preview) : null,
      matchConfidence: 'STRONG',
    };
  }

  private artistSummaries(artist: JsonObject | null, market: string) {
    const id = identifier(artist?.id);
    const name = text(artist?.name);
    if (!name) return [];
    return [{
      name,
      reference: id ? this.reference('artist', id, artist?.link, market) : null,
    }];
  }

  private rankArtistRows(
    rows: JsonObject[],
    trackSearch: JsonObject | null,
    query: string,
  ): JsonObject[] {
    const evidence = new Map<string, ArtistEvidence>();
    if (trackSearch) {
      for (const track of dataRows(trackSearch)) {
        const artist = object(track.artist);
        const id = identifier(artist?.id);
        if (!id) continue;
        const current = evidence.get(id) ?? { count: 0, rank: 0 };
        current.count += 1;
        current.rank += integer(track.rank) ?? 0;
        evidence.set(id, current);
      }
    }
    const normalizedQuery = normalizedArtistName(query);
    const decorated = rows.map((row, index) => {
      const id = identifier(row.id);
      return {
        row,
        index,
        exact: normalizedArtistName(row.name) === normalizedQuery,
        evidence: id ? evidence.get(id) ?? { count: 0, rank: 0 } : { count: 0, rank: 0 },
        fans: integer(row.nb_fan) ?? 0,
      };
    });
    // Quand au moins un nom correspond exactement, les résultats fuzzy sans
    // rapport (ELIESG, NeS pour « Ajna ») n'apportent aucune valeur à l'écran.
    const exact = decorated.filter((entry) => entry.exact);
    const candidates = exact.length > 0 ? exact : decorated;
    return candidates
      .sort((a, b) =>
        Number(b.exact) - Number(a.exact) ||
        b.evidence.count - a.evidence.count ||
        b.evidence.rank - a.evidence.rank ||
        b.fans - a.fans ||
        a.index - b.index,
      )
      .map((entry) => entry.row);
  }

  private reference(
    entityType: CatalogEntityType,
    id: string,
    rawUrl: unknown,
    market: string,
  ): ProviderReference {
    return {
      provider: this.id,
      entityType,
      externalId: id,
      externalUrl: httpsUrl(rawUrl),
      market: market.toUpperCase(),
    };
  }

  private links(rawUrl: unknown, matchMethod: string): ExternalPlatformLink[] {
    const url = httpsUrl(rawUrl);
    return url ? [{
      platform: 'deezer',
      url,
      status: 'CONFIRMED',
      source: 'DEEZER_PUBLIC_API',
      matchMethod,
      confidence: 1,
    }] : [];
  }

  private preview(rawUrl: unknown): PreviewDescriptor | null {
    const url = httpsUrl(rawUrl);
    return url ? {
      provider: this.id,
      url,
      durationMs: 30_000,
      expiresAt: signedUrlExpiry(url),
      requiresOfficialSdk: false,
      attribution: this.attribution,
    } : null;
  }

  private numericId(id: string): string {
    if (!/^\d{1,20}$/u.test(id)) {
      throw new CatalogProviderError('NOT_FOUND', 'Identifiant Deezer invalide');
    }
    return id;
  }

  private offset(cursor: string | null): number {
    if (!cursor || !/^\d{1,8}$/u.test(cursor)) return 0;
    return Math.max(0, Number(cursor));
  }

  private async request(path: string): Promise<JsonObject> {
    let response: Response;
    try {
      response = await this.fetchImpl(`${this.baseUrl}${path}`, {
        headers: { accept: 'application/json' },
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (error) {
      if (error instanceof Error && (error.name === 'TimeoutError' || error.name === 'AbortError')) {
        throw new CatalogProviderError('TIMEOUT', 'Délai Deezer dépassé');
      }
      throw new CatalogProviderError('UPSTREAM_ERROR', 'Deezer indisponible');
    }
    if (response.status === 404) throw new CatalogProviderError('NOT_FOUND', 'Entité Deezer inconnue');
    if (response.status === 429) throw new CatalogProviderError('RATE_LIMITED', 'Deezer limite les requêtes');
    if (!response.ok) throw new CatalogProviderError('UPSTREAM_ERROR', `Deezer HTTP ${response.status}`);
    let raw: unknown;
    try {
      raw = await response.json();
    } catch {
      throw new CatalogProviderError('INVALID_RESPONSE', 'Réponse Deezer invalide');
    }
    const body = object(raw);
    if (!body) throw new CatalogProviderError('INVALID_RESPONSE', 'Réponse Deezer invalide');
    const apiError = object(body.error);
    if (apiError) {
      const code = integer(apiError.code);
      if (code === 800) throw new CatalogProviderError('NOT_FOUND', 'Entité Deezer inconnue');
      if (code === 4) throw new CatalogProviderError('RATE_LIMITED', 'Deezer limite les requêtes');
      throw new CatalogProviderError('UPSTREAM_ERROR', 'Erreur retournée par Deezer');
    }
    return body;
  }
}
