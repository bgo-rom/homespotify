/**
 * Fournisseur catalogue Spotify — API Web OFFICIELLE uniquement
 * (https://developer.spotify.com/documentation/web-api), flux Client
 * Credentials côté serveur. Le client secret ne sort JAMAIS du backend.
 *
 * Périmètre vérifié (blog officiel du 2024-11-27) : search, artists, albums,
 * tracks restent accessibles aux nouvelles applications ; recommendations,
 * related-artists, audio-features et playlists éditoriales/algorithmiques sont
 * restreints. `preview_url` est DÉPRÉCIÉ : jamais stocké, jamais requis, ignoré
 * s'il est absent — Spotify n'est pas une source de preview fiable ni, à plus
 * forte raison, une source d'acquisition.
 */

import {
  CatalogProviderError,
  type CatalogAlbum,
  type CatalogAlbumPage,
  type CatalogAlbumSummary,
  type CatalogAlbumTrack,
  type CatalogArtist,
  type CatalogArtistSummary,
  type CatalogCapability,
  type CatalogEntityType,
  type CatalogImage,
  type CatalogPlaylist,
  type CatalogSearchInput,
  type CatalogSearchPage,
  type CatalogSearchResult,
  type DiscoveryCatalogProvider,
  type ProviderReference,
} from './types.js';

export interface SpotifyCatalogProviderOptions {
  clientId: string;
  clientSecret: string;
  apiBase?: string;
  authBase?: string;
  market?: string;
  timeoutMs?: number;
  /** Taille maximale acceptée d'une réponse (protection mémoire). */
  maxResponseBytes?: number;
  fetchImpl?: typeof fetch;
  now?: () => number;
}

interface SpotifyImage {
  url?: string;
  width?: number;
  height?: number;
}
interface SpotifyArtistRef {
  id?: string;
  name?: string;
  external_urls?: { spotify?: string };
}
interface SpotifyAlbumRef {
  id?: string;
  name?: string;
  album_type?: string;
  release_date?: string;
  total_tracks?: number;
  images?: SpotifyImage[];
  artists?: SpotifyArtistRef[];
  external_urls?: { spotify?: string };
}
interface SpotifyTrack {
  id?: string;
  name?: string;
  duration_ms?: number;
  explicit?: boolean;
  disc_number?: number;
  track_number?: number;
  artists?: SpotifyArtistRef[];
  album?: SpotifyAlbumRef;
  external_ids?: { isrc?: string; upc?: string };
  external_urls?: { spotify?: string };
}
interface SpotifyArtistFull extends SpotifyArtistRef {
  genres?: string[];
  images?: SpotifyImage[];
}
interface SpotifyAlbumFull extends SpotifyAlbumRef {
  label?: string;
  copyrights?: Array<{ text?: string }>;
  external_ids?: { upc?: string };
  tracks?: { items?: SpotifyTrack[]; next?: string | null };
}
interface SpotifyPlaylist {
  id?: string;
  name?: string;
  description?: string;
  owner?: { display_name?: string };
  images?: SpotifyImage[];
  external_urls?: { spotify?: string };
  tracks?: {
    total?: number;
    items?: Array<{ track?: SpotifyTrack | null }>;
    next?: string | null;
  };
}
interface SpotifyPaging<T> {
  items?: T[];
  next?: string | null;
  total?: number;
}
interface SpotifySearchResponse {
  tracks?: SpotifyPaging<SpotifyTrack>;
  artists?: SpotifyPaging<SpotifyArtistFull>;
  albums?: SpotifyPaging<SpotifyAlbumRef>;
  playlists?: SpotifyPaging<SpotifyPlaylist | null>;
}

const SEARCH_TYPE: Record<CatalogEntityType, string> = {
  track: 'track',
  artist: 'artist',
  album: 'album',
  playlist: 'playlist',
};

function httpsUrl(url: string | undefined): string | null {
  if (!url) return null;
  try {
    return new URL(url).protocol === 'https:' ? url : null;
  } catch {
    return null;
  }
}

function images(list: SpotifyImage[] | undefined): CatalogImage[] {
  return (list ?? [])
    .map((image) => {
      const url = httpsUrl(image.url);
      if (url === null) return null;
      return { url, width: image.width ?? null, height: image.height ?? null };
    })
    .filter((image): image is CatalogImage => image !== null);
}

/** Encode/décode le curseur opaque (offset numérique) — jamais d'URL brute. */
export function encodeOffsetCursor(offset: number): string {
  return Buffer.from(`o:${offset}`, 'utf-8').toString('base64url');
}
export function decodeOffsetCursor(cursor: string | null | undefined): number {
  if (!cursor) return 0;
  try {
    const raw = Buffer.from(cursor, 'base64url').toString('utf-8');
    const match = /^o:(\d{1,6})$/u.exec(raw);
    return match ? Number(match[1]) : 0;
  } catch {
    return 0;
  }
}

export class SpotifyCatalogProvider implements DiscoveryCatalogProvider {
  readonly id = 'spotify' as const;
  readonly capabilities: ReadonlySet<CatalogCapability> = new Set<CatalogCapability>([
    'SEARCH_TRACKS',
    'SEARCH_ARTISTS',
    'SEARCH_ALBUMS',
    'SEARCH_PLAYLISTS',
    'LOOKUP_ISRC',
    'ARTIST_DISCOGRAPHY',
    'ALBUM_TRACKLIST',
    'PLAYLIST_TRACKLIST',
    'EXTERNAL_LINKS',
    'MARKET_AVAILABILITY',
  ]);
  readonly attribution = 'Contenu fourni par Spotify';

  private readonly clientId: string;
  private readonly clientSecret: string;
  private readonly apiBase: string;
  private readonly authBase: string;
  private readonly timeoutMs: number;
  private readonly maxResponseBytes: number;
  private readonly fetchImpl: typeof fetch;
  private readonly now: () => number;

  private token: { value: string; expiresAtMs: number } | null = null;
  /** Single-flight : jamais deux refresh de token concurrents. */
  private tokenRefresh: Promise<string> | null = null;

  constructor(options: SpotifyCatalogProviderOptions) {
    this.clientId = options.clientId;
    this.clientSecret = options.clientSecret;
    this.apiBase = (options.apiBase ?? 'https://api.spotify.com/v1').replace(/\/+$/u, '');
    this.authBase = (options.authBase ?? 'https://accounts.spotify.com').replace(/\/+$/u, '');
    this.timeoutMs = options.timeoutMs ?? 8_000;
    this.maxResponseBytes = options.maxResponseBytes ?? 2_000_000;
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.now = options.now ?? Date.now;
  }

  async search(input: CatalogSearchInput): Promise<CatalogSearchPage> {
    const offset = decodeOffsetCursor(input.cursor);
    const params = new URLSearchParams({
      q: input.query,
      type: SEARCH_TYPE[input.type],
      market: input.market,
      // Development Mode février 2026 : GET /search est borné à 10 résultats.
      limit: String(Math.min(10, Math.max(1, input.limit))),
      offset: String(offset),
    });
    const body = (await this.get(`/search?${params}`)) as SpotifySearchResponse;
    switch (input.type) {
      case 'track': {
        const page = body.tracks;
        return this.page(page, offset, (page?.items ?? []).map((t) => this.trackResult(t, input.market)));
      }
      case 'artist': {
        const page = body.artists;
        return this.page(page, offset, (page?.items ?? []).map((a) => this.artistResult(a, input.market)));
      }
      case 'album': {
        const page = body.albums;
        return this.page(page, offset, (page?.items ?? []).map((a) => this.albumResult(a, input.market)));
      }
      case 'playlist': {
        const page = body.playlists;
        return this.page(
          page,
          offset,
          (page?.items ?? [])
            .filter((p): p is SpotifyPlaylist => p !== null && p !== undefined)
            .map((p) => this.playlistResult(p, input.market)),
        );
      }
    }
  }

  async resolveByIsrc(isrc: string, market: string): Promise<CatalogSearchResult[]> {
    const params = new URLSearchParams({
      q: `isrc:${isrc}`,
      type: 'track',
      market,
      limit: '10',
    });
    const body = (await this.get(`/search?${params}`)) as SpotifySearchResponse;
    return (body.tracks?.items ?? []).map((track) => {
      const result = this.trackResult(track, market);
      // Correspondance par ISRC exact : confiance maximale.
      return { ...result, matchConfidence: 'EXACT' as const };
    });
  }

  async getArtist(id: string, market: string): Promise<CatalogArtist> {
    const artist = (await this.get(`/artists/${encodeURIComponent(id)}`)) as SpotifyArtistFull;
    const reference = this.reference('artist', artist.id ?? id, artist.external_urls?.spotify, market);
    return {
      reference,
      name: artist.name ?? '',
      disambiguation: null,
      images: images(artist.images),
      genres: artist.genres ?? [],
      externalLinks: this.selfLink(artist.external_urls?.spotify, 'ID'),
    };
  }

  async getArtistAlbums(id: string, market: string, cursor?: string | null): Promise<CatalogAlbumPage> {
    const offset = decodeOffsetCursor(cursor);
    const params = new URLSearchParams({
      include_groups: 'album,single,compilation',
      market,
      limit: '20',
      offset: String(offset),
    });
    const body = (await this.get(
      `/artists/${encodeURIComponent(id)}/albums?${params}`,
    )) as SpotifyPaging<SpotifyAlbumRef>;
    const items: CatalogAlbumSummary[] = (body.items ?? [])
      .filter((album) => album.id)
      .map((album) => ({
        reference: this.reference('album', album.id!, album.external_urls?.spotify, market),
        title: album.name ?? '',
        albumType: album.album_type ?? null,
        releaseDate: album.release_date ?? null,
        trackCount: album.total_tracks ?? null,
        images: images(album.images),
      }));
    return {
      items,
      nextCursor: body.next ? encodeOffsetCursor(offset + (body.items?.length ?? 0)) : null,
    };
  }

  async getAlbum(id: string, market: string): Promise<CatalogAlbum> {
    const params = new URLSearchParams({ market });
    const album = (await this.get(
      `/albums/${encodeURIComponent(id)}?${params}`,
    )) as SpotifyAlbumFull;
    const tracks: CatalogAlbumTrack[] = (album.tracks?.items ?? [])
      .filter((track) => track.id)
      .map((track, index) => ({
        discNumber: track.disc_number ?? null,
        trackNumber: track.track_number ?? null,
        position: index + 1,
        title: track.name ?? '',
        artists: this.artistSummaries(track.artists, market),
        durationMs: track.duration_ms ?? null,
        explicit: track.explicit ?? null,
        isrc: track.external_ids?.isrc ?? null,
        reference: track.id ? this.reference('track', track.id, track.external_urls?.spotify, market) : null,
        preview: null,
      }));
    const discCount = tracks.reduce((max, t) => Math.max(max, t.discNumber ?? 1), 1);
    return {
      reference: this.reference('album', album.id ?? id, album.external_urls?.spotify, market),
      title: album.name ?? '',
      artists: this.artistSummaries(album.artists, market),
      releaseDate: album.release_date ?? null,
      albumType: album.album_type ?? null,
      label: album.label ?? null,
      copyright: album.copyrights?.[0]?.text ?? null,
      upc: album.external_ids?.upc ?? null,
      mbid: null,
      images: images(album.images),
      discCount,
      trackCount: album.total_tracks ?? tracks.length,
      tracks,
      externalLinks: this.selfLink(album.external_urls?.spotify, 'ID'),
    };
  }

  async getPlaylist(id: string, market: string, cursor?: string | null): Promise<CatalogPlaylist> {
    const offset = decodeOffsetCursor(cursor);
    const params = new URLSearchParams({
      market,
      fields:
        'id,name,description,owner(display_name),images,external_urls,' +
        'tracks(total,next,items(track(id,name,duration_ms,explicit,artists,album(name),external_ids,external_urls)))',
    });
    if (offset > 0) params.set('offset', String(offset));
    const playlist = (await this.get(
      `/playlists/${encodeURIComponent(id)}?${params}`,
    )) as SpotifyPlaylist;
    const rawTracks = (playlist.tracks?.items ?? [])
      .map((entry) => entry.track)
      .filter((track): track is SpotifyTrack => track !== null && track !== undefined && Boolean(track.id));
    return {
      reference: this.reference('playlist', playlist.id ?? id, playlist.external_urls?.spotify, market),
      name: playlist.name ?? '',
      description: playlist.description || null,
      ownerName: playlist.owner?.display_name ?? null,
      images: images(playlist.images),
      trackCount: playlist.tracks?.total ?? rawTracks.length,
      tracks: rawTracks.map((track, index) => ({
        position: offset + index + 1,
        title: track.name ?? '',
        artists: this.artistSummaries(track.artists, market),
        album: track.album?.name ?? null,
        durationMs: track.duration_ms ?? null,
        isrc: track.external_ids?.isrc ?? null,
        reference: track.id
          ? this.reference('track', track.id, track.external_urls?.spotify, market)
          : null,
      })),
      nextCursor: playlist.tracks?.next ? encodeOffsetCursor(offset + rawTracks.length) : null,
    };
  }

  // --- Mappers ---------------------------------------------------------------

  private page(
    paging: SpotifyPaging<unknown> | undefined,
    offset: number,
    items: CatalogSearchResult[],
  ): CatalogSearchPage {
    return {
      items,
      nextCursor: paging?.next ? encodeOffsetCursor(offset + items.length) : null,
    };
  }

  private reference(
    entityType: CatalogEntityType,
    externalId: string,
    externalUrl: string | undefined,
    market: string,
  ): ProviderReference {
    return {
      provider: 'spotify',
      entityType,
      externalId,
      externalUrl: httpsUrl(externalUrl),
      market,
    };
  }

  private selfLink(url: string | undefined, matchMethod: string | null) {
    const secure = httpsUrl(url);
    if (secure === null) return [];
    return [
      {
        platform: 'spotify',
        url: secure,
        status: 'CONFIRMED' as const,
        source: 'SPOTIFY_OFFICIAL_API',
        matchMethod,
        confidence: 1,
      },
    ];
  }

  private artistSummaries(list: SpotifyArtistRef[] | undefined, market: string): CatalogArtistSummary[] {
    return (list ?? [])
      .filter((artist) => (artist.name ?? '').length > 0)
      .map((artist) => ({
        name: artist.name!,
        reference: artist.id ? this.reference('artist', artist.id, artist.external_urls?.spotify, market) : null,
      }));
  }

  private trackResult(track: SpotifyTrack, market: string): CatalogSearchResult {
    const isrc = track.external_ids?.isrc?.toUpperCase() ?? null;
    const reference = this.reference('track', track.id ?? '', track.external_urls?.spotify, market);
    return {
      canonicalKey: isrc ? `isrc:${isrc}` : `spotify:track:${track.id ?? ''}`,
      entityType: 'track',
      title: track.name ?? '',
      artists: this.artistSummaries(track.artists, market),
      album: track.album?.name ?? null,
      durationMs: track.duration_ms ?? null,
      releaseDate: track.album?.release_date ?? null,
      explicit: track.explicit ?? null,
      images: images(track.album?.images),
      isrc,
      upc: null,
      mbid: null,
      trackCount: null,
      providerReferences: [reference],
      externalLinks: this.selfLink(track.external_urls?.spotify, isrc ? 'ISRC' : 'ID'),
      // preview_url Spotify est déprécié : jamais utilisé ni stocké.
      preview: null,
      matchConfidence: 'STRONG',
    };
  }

  private artistResult(artist: SpotifyArtistFull, market: string): CatalogSearchResult {
    const reference = this.reference('artist', artist.id ?? '', artist.external_urls?.spotify, market);
    return {
      canonicalKey: `spotify:artist:${artist.id ?? ''}`,
      entityType: 'artist',
      title: artist.name ?? '',
      artists: [{ name: artist.name ?? '', reference }],
      album: null,
      durationMs: null,
      releaseDate: null,
      explicit: null,
      images: images(artist.images),
      isrc: null,
      upc: null,
      mbid: null,
      trackCount: null,
      providerReferences: [reference],
      externalLinks: this.selfLink(artist.external_urls?.spotify, 'ID'),
      preview: null,
      matchConfidence: 'STRONG',
    };
  }

  private albumResult(album: SpotifyAlbumRef, market: string): CatalogSearchResult {
    const reference = this.reference('album', album.id ?? '', album.external_urls?.spotify, market);
    return {
      canonicalKey: `spotify:album:${album.id ?? ''}`,
      entityType: 'album',
      title: album.name ?? '',
      artists: this.artistSummaries(album.artists, market),
      album: album.name ?? null,
      durationMs: null,
      releaseDate: album.release_date ?? null,
      explicit: null,
      images: images(album.images),
      isrc: null,
      upc: null,
      mbid: null,
      trackCount: album.total_tracks ?? null,
      providerReferences: [reference],
      externalLinks: this.selfLink(album.external_urls?.spotify, 'ID'),
      preview: null,
      matchConfidence: 'STRONG',
    };
  }

  private playlistResult(playlist: SpotifyPlaylist, market: string): CatalogSearchResult {
    const reference = this.reference('playlist', playlist.id ?? '', playlist.external_urls?.spotify, market);
    return {
      canonicalKey: `spotify:playlist:${playlist.id ?? ''}`,
      entityType: 'playlist',
      title: playlist.name ?? '',
      artists: playlist.owner?.display_name
        ? [{ name: playlist.owner.display_name, reference: null }]
        : [],
      album: null,
      durationMs: null,
      releaseDate: null,
      explicit: null,
      images: images(playlist.images),
      isrc: null,
      upc: null,
      mbid: null,
      trackCount: playlist.tracks?.total ?? null,
      providerReferences: [reference],
      externalLinks: this.selfLink(playlist.external_urls?.spotify, 'ID'),
      preview: null,
      matchConfidence: 'POSSIBLE',
    };
  }

  // --- HTTP ------------------------------------------------------------------

  /** Token client-credentials avec single-flight et marge de 60 s. */
  private async accessToken(forceRefresh = false): Promise<string> {
    const nowMs = this.now();
    if (!forceRefresh && this.token !== null && this.token.expiresAtMs - nowMs > 60_000) {
      return this.token.value;
    }
    if (this.tokenRefresh !== null) return this.tokenRefresh;
    this.tokenRefresh = (async () => {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), this.timeoutMs);
      try {
        const basic = Buffer.from(`${this.clientId}:${this.clientSecret}`, 'utf-8').toString('base64');
        const response = await this.fetchImpl(`${this.authBase}/api/token`, {
          method: 'POST',
          headers: {
            authorization: `Basic ${basic}`,
            'content-type': 'application/x-www-form-urlencoded',
          },
          body: 'grant_type=client_credentials',
          signal: controller.signal,
        });
        if (!response.ok) {
          throw new CatalogProviderError(
            response.status === 429 ? 'RATE_LIMITED' : 'UNAUTHORIZED',
            `Spotify auth ${response.status}`,
          );
        }
        const body = (await response.json()) as { access_token?: string; expires_in?: number };
        if (!body.access_token) {
          throw new CatalogProviderError('INVALID_RESPONSE', 'Spotify auth : token absent');
        }
        this.token = {
          value: body.access_token,
          expiresAtMs: this.now() + (body.expires_in ?? 3600) * 1000,
        };
        return this.token.value;
      } catch (error) {
        if (error instanceof CatalogProviderError) throw error;
        throw new CatalogProviderError('TIMEOUT', 'Spotify auth injoignable');
      } finally {
        clearTimeout(timeout);
        this.tokenRefresh = null;
      }
    })();
    return this.tokenRefresh;
  }

  private async get(pathAndQuery: string, retried = false): Promise<unknown> {
    const token = await this.accessToken();
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const response = await this.fetchImpl(`${this.apiBase}${pathAndQuery}`, {
        headers: { accept: 'application/json', authorization: `Bearer ${token}` },
        signal: controller.signal,
      });
      if (response.status === 401 && !retried) {
        // Token expiré côté Spotify : un seul refresh forcé, jamais de boucle.
        await this.accessToken(true);
        return this.get(pathAndQuery, true);
      }
      if (response.status === 429) {
        const retryAfter = Number(response.headers.get('retry-after') ?? '');
        throw new CatalogProviderError(
          'RATE_LIMITED',
          'Spotify rate limit',
          Number.isFinite(retryAfter) ? retryAfter * 1000 : null,
        );
      }
      if (response.status === 403) throw new CatalogProviderError('FORBIDDEN', 'Spotify 403');
      if (response.status === 404) throw new CatalogProviderError('NOT_FOUND', 'Spotify 404');
      if (!response.ok) throw new CatalogProviderError('UPSTREAM_ERROR', `Spotify ${response.status}`);
      const contentType = response.headers.get('content-type') ?? '';
      if (!contentType.includes('application/json')) {
        throw new CatalogProviderError('INVALID_RESPONSE', 'Spotify : Content-Type inattendu');
      }
      const text = await response.text();
      if (text.length > this.maxResponseBytes) {
        throw new CatalogProviderError('INVALID_RESPONSE', 'Spotify : réponse trop volumineuse');
      }
      try {
        return JSON.parse(text) as unknown;
      } catch {
        throw new CatalogProviderError('INVALID_RESPONSE', 'Spotify : JSON invalide');
      }
    } catch (error) {
      if (error instanceof CatalogProviderError) throw error;
      throw new CatalogProviderError('TIMEOUT', 'Spotify injoignable ou timeout');
    } finally {
      clearTimeout(timeout);
    }
  }
}
