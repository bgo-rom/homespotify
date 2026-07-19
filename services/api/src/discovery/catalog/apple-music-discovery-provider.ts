/**
 * Fournisseur découverte Apple Music — RÉUTILISE le provider MusicKit existant
 * (apple-music-catalog-provider.ts) pour le JWT ES256 et la configuration.
 * Aucun second client de signature n'est créé : ce module ajoute uniquement
 * les capacités catalogue manquantes (recherche multi-types, fiches, previews
 * officielles documentées par l'attribut `previews` de l'API Apple Music).
 *
 * Actif UNIQUEMENT si les secrets Apple sont présents (config.appleMusic).
 */

import type { AppleMusicCatalogProvider } from '../apple-music-catalog-provider.js';
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
  type PreviewDescriptor,
  type ProviderReference,
} from './types.js';

export interface AppleMusicDiscoveryProviderOptions {
  /** Provider MusicKit existant : source UNIQUE du developer token. */
  tokenSource: Pick<AppleMusicCatalogProvider, 'developerToken'>;
  storefront?: string;
  baseUrl?: string;
  timeoutMs?: number;
  maxResponseBytes?: number;
  fetchImpl?: typeof fetch;
}

interface AppleArtwork {
  url?: string;
  width?: number;
  height?: number;
}
interface AppleResource<A> {
  id?: string;
  attributes?: A;
}
interface AppleSongAttributes {
  name?: string;
  artistName?: string;
  albumName?: string;
  isrc?: string;
  durationInMillis?: number;
  releaseDate?: string;
  contentRating?: string;
  url?: string;
  previews?: Array<{ url?: string }>;
  artwork?: AppleArtwork;
  discNumber?: number;
  trackNumber?: number;
}
interface AppleArtistAttributes {
  name?: string;
  url?: string;
  genreNames?: string[];
  artwork?: AppleArtwork;
}
interface AppleAlbumAttributes {
  name?: string;
  artistName?: string;
  releaseDate?: string;
  trackCount?: number;
  upc?: string;
  recordLabel?: string;
  copyright?: string;
  url?: string;
  contentRating?: string;
  artwork?: AppleArtwork;
  isSingle?: boolean;
  isCompilation?: boolean;
}
interface AppleList<A> {
  data?: Array<AppleResource<A>>;
  next?: string;
}
interface AppleSearchResponse {
  results?: {
    songs?: AppleList<AppleSongAttributes>;
    artists?: AppleList<AppleArtistAttributes>;
    albums?: AppleList<AppleAlbumAttributes>;
  };
}

function httpsUrl(url: string | undefined): string | null {
  if (!url) return null;
  try {
    return new URL(url).protocol === 'https:' ? url : null;
  } catch {
    return null;
  }
}

function artworkImages(artwork: AppleArtwork | undefined, size = 600): CatalogImage[] {
  const template = artwork?.url;
  if (!template) return [];
  const url = httpsUrl(template.replace('{w}', String(size)).replace('{h}', String(size)).replace('{f}', 'jpg'));
  return url === null ? [] : [{ url, width: size, height: size }];
}

export class AppleMusicDiscoveryProvider implements DiscoveryCatalogProvider {
  readonly id = 'apple_music' as const;
  readonly capabilities: ReadonlySet<CatalogCapability> = new Set<CatalogCapability>([
    'SEARCH_TRACKS',
    'SEARCH_ARTISTS',
    'SEARCH_ALBUMS',
    'LOOKUP_ISRC',
    'ARTIST_DISCOGRAPHY',
    'ALBUM_TRACKLIST',
    'EXTERNAL_LINKS',
    'PREVIEW',
  ]);
  readonly attribution = 'Contenu fourni par Apple Music';

  private readonly tokenSource: Pick<AppleMusicCatalogProvider, 'developerToken'>;
  private readonly storefront: string;
  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly maxResponseBytes: number;
  private readonly fetchImpl: typeof fetch;

  constructor(options: AppleMusicDiscoveryProviderOptions) {
    this.tokenSource = options.tokenSource;
    this.storefront = (options.storefront ?? 'fr').toLowerCase();
    this.baseUrl = (options.baseUrl ?? 'https://api.music.apple.com').replace(/\/+$/u, '');
    this.timeoutMs = options.timeoutMs ?? 8_000;
    this.maxResponseBytes = options.maxResponseBytes ?? 2_000_000;
    this.fetchImpl = options.fetchImpl ?? fetch;
  }

  async search(input: CatalogSearchInput): Promise<CatalogSearchPage> {
    const types =
      input.type === 'track' ? 'songs' : input.type === 'artist' ? 'artists' : input.type === 'album' ? 'albums' : null;
    // L'API recherche playlists éditoriales Apple ; non exposé ici (périmètre
    // playlists réservé aux providers avec tracklist utilisateur vérifiée).
    if (types === null) return { items: [], nextCursor: null };
    const params = new URLSearchParams({
      term: input.query,
      types,
      limit: String(Math.min(25, Math.max(1, input.limit))),
    });
    const body = (await this.get(
      `/v1/catalog/${this.storefront}/search?${params}`,
    )) as AppleSearchResponse;
    if (input.type === 'track') {
      return {
        items: (body.results?.songs?.data ?? []).map((song) => this.songResult(song)),
        nextCursor: null,
      };
    }
    if (input.type === 'artist') {
      return {
        items: (body.results?.artists?.data ?? []).map((artist) => this.artistResult(artist)),
        nextCursor: null,
      };
    }
    return {
      items: (body.results?.albums?.data ?? []).map((album) => this.albumResult(album)),
      nextCursor: null,
    };
  }

  async resolveByIsrc(isrc: string): Promise<CatalogSearchResult[]> {
    const params = new URLSearchParams();
    params.set('filter[isrc]', isrc.toUpperCase());
    const body = (await this.get(
      `/v1/catalog/${this.storefront}/songs?${params}`,
    )) as AppleList<AppleSongAttributes>;
    return (body.data ?? []).map((song) => ({
      ...this.songResult(song),
      matchConfidence: 'EXACT' as const,
    }));
  }

  async getArtist(id: string): Promise<CatalogArtist> {
    const body = (await this.get(
      `/v1/catalog/${this.storefront}/artists/${encodeURIComponent(id)}`,
    )) as AppleList<AppleArtistAttributes>;
    const artist = body.data?.[0];
    if (!artist?.id) {
      throw new CatalogProviderError('NOT_FOUND', 'Artiste Apple Music inconnu');
    }
    const a = artist.attributes;
    return {
      reference: this.reference('artist', artist.id, a?.url),
      name: a?.name ?? '',
      disambiguation: null,
      images: artworkImages(a?.artwork),
      genres: a?.genreNames ?? [],
      externalLinks: this.selfLink(a?.url),
    };
  }

  async getArtistAlbums(id: string, _market: string, cursor?: string | null): Promise<CatalogAlbumPage> {
    const offset = cursor ? Math.max(0, Number(cursor) || 0) : 0;
    const params = new URLSearchParams({ limit: '25', offset: String(offset) });
    const body = (await this.get(
      `/v1/catalog/${this.storefront}/artists/${encodeURIComponent(id)}/albums?${params}`,
    )) as AppleList<AppleAlbumAttributes>;
    const items = (body.data ?? [])
      .filter((album) => album.id)
      .map((album) => ({
        reference: this.reference('album', album.id!, album.attributes?.url),
        title: album.attributes?.name ?? '',
        albumType: album.attributes?.isSingle
          ? 'single'
          : album.attributes?.isCompilation
            ? 'compilation'
            : 'album',
        releaseDate: album.attributes?.releaseDate ?? null,
        trackCount: album.attributes?.trackCount ?? null,
        images: artworkImages(album.attributes?.artwork),
      }));
    return {
      items,
      nextCursor: body.next ? String(offset + items.length) : null,
    };
  }

  async getAlbum(id: string): Promise<CatalogAlbum> {
    const params = new URLSearchParams({ include: 'tracks' });
    const body = (await this.get(
      `/v1/catalog/${this.storefront}/albums/${encodeURIComponent(id)}?${params}`,
    )) as {
      data?: Array<
        AppleResource<AppleAlbumAttributes> & {
          relationships?: { tracks?: AppleList<AppleSongAttributes> };
        }
      >;
    };
    const album = body.data?.[0];
    if (!album?.id) throw new CatalogProviderError('NOT_FOUND', 'Album Apple Music inconnu');
    const a = album.attributes;
    const songs = album.relationships?.tracks?.data ?? [];
    return {
      reference: this.reference('album', album.id, a?.url),
      title: a?.name ?? '',
      artists: a?.artistName ? [{ name: a.artistName, reference: null }] : [],
      releaseDate: a?.releaseDate ?? null,
      albumType: a?.isSingle ? 'single' : a?.isCompilation ? 'compilation' : 'album',
      label: a?.recordLabel ?? null,
      copyright: a?.copyright ?? null,
      upc: a?.upc ?? null,
      mbid: null,
      images: artworkImages(a?.artwork),
      discCount: songs.reduce((max, s) => Math.max(max, s.attributes?.discNumber ?? 1), 1),
      trackCount: a?.trackCount ?? songs.length,
      tracks: songs
        .filter((song) => song.id)
        .map((song, index) => ({
          discNumber: song.attributes?.discNumber ?? null,
          trackNumber: song.attributes?.trackNumber ?? null,
          position: index + 1,
          title: song.attributes?.name ?? '',
          artists: song.attributes?.artistName
            ? [{ name: song.attributes.artistName, reference: null }]
            : [],
          durationMs: song.attributes?.durationInMillis ?? null,
          explicit: song.attributes?.contentRating === 'explicit',
          isrc: song.attributes?.isrc?.toUpperCase() ?? null,
          reference: this.reference('track', song.id!, song.attributes?.url),
          preview: this.preview(song.attributes),
        })),
      externalLinks: this.selfLink(a?.url),
    };
  }

  // --- Mappers ---------------------------------------------------------------

  private reference(
    entityType: CatalogEntityType,
    externalId: string,
    url: string | undefined,
  ): ProviderReference {
    return {
      provider: 'apple_music',
      entityType,
      externalId,
      externalUrl: httpsUrl(url),
      market: this.storefront.toUpperCase(),
    };
  }

  private selfLink(url: string | undefined) {
    const secure = httpsUrl(url);
    if (secure === null) return [];
    return [
      {
        platform: 'apple_music',
        url: secure,
        status: 'CONFIRMED' as const,
        source: 'APPLE_MUSIC_OFFICIAL_API',
        matchMethod: 'ID',
        confidence: 1,
      },
    ];
  }

  /**
   * Preview officielle Apple Music (attribut documenté `previews`). Streaming
   * uniquement : l'URL n'est jamais persistée ni téléchargée côté serveur.
   */
  private preview(attributes: AppleSongAttributes | undefined): PreviewDescriptor | null {
    const url = httpsUrl(attributes?.previews?.[0]?.url);
    if (url === null) return null;
    return {
      provider: 'apple_music',
      url,
      durationMs: 30_000,
      expiresAt: null,
      requiresOfficialSdk: false,
      attribution: this.attribution,
    };
  }

  private songResult(song: AppleResource<AppleSongAttributes>): CatalogSearchResult {
    const a = song.attributes;
    const isrc = a?.isrc?.toUpperCase() ?? null;
    const reference = this.reference('track', song.id ?? '', a?.url);
    return {
      canonicalKey: isrc ? `isrc:${isrc}` : `apple_music:track:${song.id ?? ''}`,
      entityType: 'track',
      title: a?.name ?? '',
      artists: a?.artistName ? [{ name: a.artistName, reference: null }] : [],
      album: a?.albumName ?? null,
      durationMs: a?.durationInMillis ?? null,
      releaseDate: a?.releaseDate ?? null,
      explicit: a?.contentRating === 'explicit',
      images: artworkImages(a?.artwork),
      isrc,
      upc: null,
      mbid: null,
      trackCount: null,
      providerReferences: [reference],
      externalLinks: this.selfLink(a?.url),
      preview: this.preview(a),
      matchConfidence: 'STRONG',
    };
  }

  private artistResult(artist: AppleResource<AppleArtistAttributes>): CatalogSearchResult {
    const a = artist.attributes;
    const reference = this.reference('artist', artist.id ?? '', a?.url);
    return {
      canonicalKey: `apple_music:artist:${artist.id ?? ''}`,
      entityType: 'artist',
      title: a?.name ?? '',
      artists: [{ name: a?.name ?? '', reference }],
      album: null,
      durationMs: null,
      releaseDate: null,
      explicit: null,
      images: artworkImages(a?.artwork),
      isrc: null,
      upc: null,
      mbid: null,
      trackCount: null,
      providerReferences: [reference],
      externalLinks: this.selfLink(a?.url),
      preview: null,
      matchConfidence: 'STRONG',
    };
  }

  private albumResult(album: AppleResource<AppleAlbumAttributes>): CatalogSearchResult {
    const a = album.attributes;
    const reference = this.reference('album', album.id ?? '', a?.url);
    return {
      canonicalKey: a?.upc ? `upc:${a.upc}` : `apple_music:album:${album.id ?? ''}`,
      entityType: 'album',
      title: a?.name ?? '',
      artists: a?.artistName ? [{ name: a.artistName, reference: null }] : [],
      album: a?.name ?? null,
      durationMs: null,
      releaseDate: a?.releaseDate ?? null,
      explicit: a?.contentRating === 'explicit',
      images: artworkImages(a?.artwork),
      isrc: null,
      upc: a?.upc ?? null,
      mbid: null,
      trackCount: a?.trackCount ?? null,
      providerReferences: [reference],
      externalLinks: this.selfLink(a?.url),
      preview: null,
      matchConfidence: 'STRONG',
    };
  }

  // --- HTTP ------------------------------------------------------------------

  private async get(pathAndQuery: string): Promise<unknown> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const response = await this.fetchImpl(`${this.baseUrl}${pathAndQuery}`, {
        headers: {
          accept: 'application/json',
          authorization: `Bearer ${this.tokenSource.developerToken()}`,
        },
        signal: controller.signal,
      });
      if (response.status === 401) throw new CatalogProviderError('UNAUTHORIZED', 'Apple Music 401');
      if (response.status === 403) throw new CatalogProviderError('FORBIDDEN', 'Apple Music 403');
      if (response.status === 404) throw new CatalogProviderError('NOT_FOUND', 'Apple Music 404');
      if (response.status === 429) {
        const retryAfter = Number(response.headers.get('retry-after') ?? '');
        throw new CatalogProviderError(
          'RATE_LIMITED',
          'Apple Music rate limit',
          Number.isFinite(retryAfter) ? retryAfter * 1000 : null,
        );
      }
      if (!response.ok) throw new CatalogProviderError('UPSTREAM_ERROR', `Apple Music ${response.status}`);
      const text = await response.text();
      if (text.length > this.maxResponseBytes) {
        throw new CatalogProviderError('INVALID_RESPONSE', 'Apple Music : réponse trop volumineuse');
      }
      try {
        return JSON.parse(text) as unknown;
      } catch {
        throw new CatalogProviderError('INVALID_RESPONSE', 'Apple Music : JSON invalide');
      }
    } catch (error) {
      if (error instanceof CatalogProviderError) throw error;
      throw new CatalogProviderError('TIMEOUT', 'Apple Music injoignable ou timeout');
    } finally {
      clearTimeout(timeout);
    }
  }
}
