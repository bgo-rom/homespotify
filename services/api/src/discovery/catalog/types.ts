/**
 * Modèle unifié de la recherche catalogue multi-fournisseurs (Phase Discovery).
 * Indépendant des formats propriétaires : chaque provider mappe sa réponse vers
 * ces types, et rien d'autre ne sort vers le client Flutter.
 *
 * Séparation stricte des responsabilités (cf. DISCOVERY_CATALOG.md) :
 * DISCOVERY (métadonnées) → PREVIEW (extrait officiel) → REQUEST (demande
 * HomeSpotify) → ACQUISITION (hors périmètre, jamais déclenchée ici).
 */

export const CATALOG_CAPABILITIES = [
  'SEARCH_TRACKS',
  'SEARCH_ARTISTS',
  'SEARCH_ALBUMS',
  'SEARCH_PLAYLISTS',
  'LOOKUP_ISRC',
  'ARTIST_DISCOGRAPHY',
  'ALBUM_TRACKLIST',
  'PLAYLIST_TRACKLIST',
  'EXTERNAL_LINKS',
  'PREVIEW',
  'MARKET_AVAILABILITY',
] as const;
export type CatalogCapability = (typeof CATALOG_CAPABILITIES)[number];

/** Identifiants stables des fournisseurs de découverte. */
export const DISCOVERY_PROVIDER_IDS = [
  'spotify',
  'musicbrainz',
  'apple_music',
  'deezer',
  'tidal',
] as const;
export type DiscoveryProviderId = (typeof DISCOVERY_PROVIDER_IDS)[number];

export type CatalogEntityType = 'track' | 'artist' | 'album' | 'playlist';

/**
 * Statut de disponibilité par plateforme. JAMAIS un booléen : l'absence de
 * résultat ne prouve pas l'indisponibilité (règle Phase 5).
 */
export const PLATFORM_AVAILABILITY_STATUSES = [
  'CONFIRMED',
  'LINK_FOUND',
  'SEARCH_LINK_ONLY',
  'UNAVAILABLE_CONFIRMED',
  'UNKNOWN',
  'PROVIDER_DISABLED',
  'PROVIDER_ERROR',
] as const;
export type PlatformAvailabilityStatus = (typeof PLATFORM_AVAILABILITY_STATUSES)[number];

export interface ProviderReference {
  provider: DiscoveryProviderId;
  entityType: CatalogEntityType;
  externalId: string;
  externalUrl: string | null;
  market: string | null;
}

export interface ExternalPlatformLink {
  /** Plateforme cible (spotify, apple_music, tidal, deezer, bandcamp, qobuz, official…). */
  platform: string;
  url: string;
  status: PlatformAvailabilityStatus;
  /** Origine de la relation (SPOTIFY_OFFICIAL_API, MUSICBRAINZ_URL_RELATION…). */
  source: string;
  /** ISRC | MBID | TEXT_MATCH | URL_RELATION. */
  matchMethod: string | null;
  confidence: number;
}

/**
 * Extrait officiel éphémère. JAMAIS stocké durablement, jamais téléchargé,
 * jamais mis hors ligne (règles Phase 18).
 */
export interface PreviewDescriptor {
  provider: DiscoveryProviderId;
  url: string;
  durationMs: number | null;
  expiresAt: string | null;
  requiresOfficialSdk: boolean;
  attribution: string;
}

export interface CatalogImage {
  url: string;
  width: number | null;
  height: number | null;
}

export interface CatalogArtistSummary {
  name: string;
  reference: ProviderReference | null;
}

/** Niveau de correspondance après fusion multi-provider (Phase 22). */
export type MatchConfidenceLevel = 'EXACT' | 'STRONG' | 'POSSIBLE' | 'AMBIGUOUS';

export interface CatalogSearchResult {
  /** Clé de regroupement déterministe (isrc:… | mbid:… | id:… ). */
  canonicalKey: string;
  entityType: CatalogEntityType;
  title: string;
  artists: CatalogArtistSummary[];
  album: string | null;
  durationMs: number | null;
  releaseDate: string | null;
  explicit: boolean | null;
  images: CatalogImage[];
  isrc: string | null;
  upc: string | null;
  mbid: string | null;
  /** Nombre de pistes (albums/playlists). */
  trackCount: number | null;
  providerReferences: ProviderReference[];
  externalLinks: ExternalPlatformLink[];
  preview: PreviewDescriptor | null;
  matchConfidence: MatchConfidenceLevel;
}

export interface CatalogSearchInput {
  query: string;
  type: CatalogEntityType;
  market: string;
  limit: number;
  /** Curseur opaque propre au provider (offset encodé). */
  cursor: string | null;
}

export interface CatalogSearchPage {
  items: CatalogSearchResult[];
  nextCursor: string | null;
}

export interface CatalogAlbumTrack {
  discNumber: number | null;
  trackNumber: number | null;
  position: number;
  title: string;
  artists: CatalogArtistSummary[];
  durationMs: number | null;
  explicit: boolean | null;
  isrc: string | null;
  reference: ProviderReference | null;
  preview: PreviewDescriptor | null;
}

export interface CatalogAlbum {
  reference: ProviderReference;
  title: string;
  artists: CatalogArtistSummary[];
  releaseDate: string | null;
  albumType: string | null;
  label: string | null;
  copyright: string | null;
  upc: string | null;
  mbid: string | null;
  images: CatalogImage[];
  discCount: number | null;
  trackCount: number | null;
  tracks: CatalogAlbumTrack[];
  externalLinks: ExternalPlatformLink[];
}

export interface CatalogAlbumSummary {
  reference: ProviderReference;
  title: string;
  albumType: string | null;
  releaseDate: string | null;
  trackCount: number | null;
  images: CatalogImage[];
}

export interface CatalogAlbumPage {
  items: CatalogAlbumSummary[];
  nextCursor: string | null;
}

export interface CatalogArtist {
  reference: ProviderReference;
  name: string;
  disambiguation: string | null;
  images: CatalogImage[];
  genres: string[];
  externalLinks: ExternalPlatformLink[];
}

export interface CatalogPlaylistTrack {
  position: number;
  title: string;
  artists: CatalogArtistSummary[];
  album: string | null;
  durationMs: number | null;
  isrc: string | null;
  reference: ProviderReference | null;
}

export interface CatalogPlaylist {
  reference: ProviderReference;
  name: string;
  description: string | null;
  ownerName: string | null;
  images: CatalogImage[];
  trackCount: number | null;
  tracks: CatalogPlaylistTrack[];
  nextCursor: string | null;
}

export type ProviderHealthStatus = 'OK' | 'DEGRADED' | 'DISABLED' | 'ERROR';

export interface ProviderHealth {
  id: DiscoveryProviderId;
  status: ProviderHealthStatus;
  /** Catégorie stable de la dernière erreur (jamais le corps brut). */
  lastErrorCategory: string | null;
  lastErrorAt: string | null;
  latencyMs: number | null;
}

/** Erreur catégorisée d'un provider (pas de corps de réponse externe). */
export class CatalogProviderError extends Error {
  constructor(
    readonly category:
      | 'UNAUTHORIZED'
      | 'FORBIDDEN'
      | 'RATE_LIMITED'
      | 'TIMEOUT'
      | 'UPSTREAM_ERROR'
      | 'INVALID_RESPONSE'
      | 'NOT_FOUND'
      | 'DISABLED',
    message: string,
    readonly retryAfterMs: number | null = null,
  ) {
    super(message);
    this.name = 'CatalogProviderError';
  }
}

/**
 * Interface commune des fournisseurs de découverte. Un provider ne déclare
 * dans `capabilities` QUE ce qui est vérifié par sa documentation officielle
 * et couvert par ses tests contractuels.
 */
export interface DiscoveryCatalogProvider {
  readonly id: DiscoveryProviderId;
  readonly capabilities: ReadonlySet<CatalogCapability>;
  /** Attribution à afficher quand le contenu de ce provider est montré. */
  readonly attribution: string;

  search(input: CatalogSearchInput): Promise<CatalogSearchPage>;
  getArtist?(id: string, market: string): Promise<CatalogArtist>;
  getArtistAlbums?(id: string, market: string, cursor?: string | null): Promise<CatalogAlbumPage>;
  getAlbum?(id: string, market: string): Promise<CatalogAlbum>;
  getPlaylist?(id: string, market: string, cursor?: string | null): Promise<CatalogPlaylist>;
  resolveByIsrc?(isrc: string, market: string): Promise<CatalogSearchResult[]>;
}
