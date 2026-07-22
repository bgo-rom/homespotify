/**
 * Fournisseur catalogue MusicBrainz — métadonnées CANONIQUES (MBID, ISRC,
 * relations URL). Réutilise le MusicBrainzClient existant : queue globale
 * 1 req/s, User-Agent identifiable, retry borné 503 (politique officielle
 * https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting).
 *
 * MusicBrainz ne fournit NI preview NI pochette directe (Cover Art Archive
 * séparé) : ce provider sert l'identité, la désambiguïsation et les liens
 * externes (Bandcamp/Qobuz/plateformes) via les relations URL — seules sources
 * autorisées pour ces plateformes sans API officielle utilisable.
 */

import type {
  MusicBrainzClient,
  MusicBrainzRecordingCandidate,
  MusicBrainzReleaseGroupCandidate,
} from '../../metadata/musicbrainz-client.js';
import type {
  CatalogAlbum,
  CatalogAlbumPage,
  CatalogArtist,
  CatalogCapability,
  CatalogEntityType,
  CatalogSearchInput,
  CatalogSearchPage,
  CatalogSearchResult,
  DiscoveryCatalogProvider,
  ExternalPlatformLink,
  ProviderReference,
} from './types.js';

/** Domaines de plateformes reconnus dans les relations URL MusicBrainz. */
const URL_RELATION_PLATFORMS: ReadonlyArray<{ hostSuffix: string; platform: string }> = [
  { hostSuffix: 'bandcamp.com', platform: 'bandcamp' },
  { hostSuffix: 'qobuz.com', platform: 'qobuz' },
  { hostSuffix: 'open.spotify.com', platform: 'spotify' },
  { hostSuffix: 'music.apple.com', platform: 'apple_music' },
  { hostSuffix: 'itunes.apple.com', platform: 'apple_music' },
  { hostSuffix: 'tidal.com', platform: 'tidal' },
  { hostSuffix: 'deezer.com', platform: 'deezer' },
  { hostSuffix: 'soundcloud.com', platform: 'soundcloud' },
];

function coverArtImages(releaseGroupId: string | null): Array<{
  url: string;
  width: number;
  height: number;
}> {
  return releaseGroupId
    ? [{
        url: `https://coverartarchive.org/release-group/${releaseGroupId}/front-500`,
        width: 500,
        height: 500,
      }]
    : [];
}

/**
 * Convertit les relations URL MusicBrainz en liens plateformes vérifiés.
 * Une relation confirmée = LINK_FOUND ; jamais de statut « indisponible »
 * déduit d'une absence de relation (règle Bandcamp/Qobuz → UNKNOWN).
 */
export function platformLinksFromUrlRelations(
  relations: Array<{ type: string; url: string }>,
): ExternalPlatformLink[] {
  const links: ExternalPlatformLink[] = [];
  for (const relation of relations) {
    let parsed: URL;
    try {
      parsed = new URL(relation.url);
    } catch {
      continue;
    }
    if (parsed.protocol !== 'https:') continue;
    const host = parsed.hostname.toLowerCase();
    const known = URL_RELATION_PLATFORMS.find(
      (entry) => host === entry.hostSuffix || host.endsWith(`.${entry.hostSuffix}`),
    );
    if (known) {
      links.push({
        platform: known.platform,
        url: parsed.toString(),
        status: 'LINK_FOUND',
        source: 'MUSICBRAINZ_URL_RELATION',
        matchMethod: 'URL_RELATION',
        confidence: 0.9,
      });
    } else if (relation.type === 'official homepage') {
      links.push({
        platform: 'official',
        url: parsed.toString(),
        status: 'LINK_FOUND',
        source: 'MUSICBRAINZ_URL_RELATION',
        matchMethod: 'URL_RELATION',
        confidence: 0.9,
      });
    }
  }
  return links;
}

export class MusicBrainzCatalogProvider implements DiscoveryCatalogProvider {
  readonly id = 'musicbrainz' as const;
  readonly capabilities: ReadonlySet<CatalogCapability> = new Set<CatalogCapability>([
    'SEARCH_TRACKS',
    'SEARCH_ARTISTS',
    'SEARCH_ALBUMS',
    'LOOKUP_ISRC',
    'ARTIST_DISCOGRAPHY',
    'ALBUM_TRACKLIST',
    'EXTERNAL_LINKS',
  ]);
  readonly attribution = 'Données MusicBrainz (CC BY-NC-SA)';

  constructor(private readonly client: MusicBrainzClient) {}

  async search(input: CatalogSearchInput): Promise<CatalogSearchPage> {
    switch (input.type) {
      case 'track': {
        const recordings = await this.client.searchRecordingsText(
          input.query,
          Math.min(10, input.limit),
        );
        return { items: recordings.map((r) => this.recordingResult(r)), nextCursor: null };
      }
      case 'artist': {
        const artists = await this.client.searchArtists(input.query, Math.min(10, input.limit));
        return {
          items: artists.map((artist) => this.artistResult(artist.id, artist.name)),
          nextCursor: null,
        };
      }
      case 'album': {
        const groups = await this.client.searchReleaseGroups({
          title: input.query,
          limit: Math.min(10, input.limit),
        });
        return { items: groups.map((g) => this.releaseGroupResult(g)), nextCursor: null };
      }
      case 'playlist':
        // MusicBrainz n'a pas de notion de playlist consommateur.
        return { items: [], nextCursor: null };
    }
  }

  async resolveByIsrc(isrc: string): Promise<CatalogSearchResult[]> {
    const recordings = await this.client.lookupIsrc(isrc);
    return recordings.map((recording) => ({
      ...this.recordingResult(recording, isrc.toUpperCase()),
      matchConfidence: 'EXACT' as const,
    }));
  }

  async getArtist(id: string): Promise<CatalogArtist> {
    const detail = await this.client.lookupArtistWithUrls(id);
    if (detail === null) {
      throw Object.assign(new Error('Artiste MusicBrainz inconnu'), { statusCode: 404 });
    }
    return {
      reference: this.reference('artist', detail.id),
      name: detail.name,
      disambiguation: detail.disambiguation,
      images: [],
      genres: detail.tags,
      externalLinks: [
        this.selfLink('artist', detail.id),
        ...platformLinksFromUrlRelations(detail.urlRelations),
      ],
    };
  }

  async getArtistAlbums(id: string, _market: string, cursor?: string | null): Promise<CatalogAlbumPage> {
    const offset = cursor ? Math.max(0, Number(cursor) || 0) : 0;
    const { items, total } = await this.client.browseArtistReleaseGroups(id, {
      limit: 50,
      offset,
    });
    const sorted = [...items].sort((a, b) =>
      (a.firstReleaseDate ?? '9999').localeCompare(b.firstReleaseDate ?? '9999'),
    );
    return {
      items: sorted.map((group) => ({
        reference: this.reference('album', group.id),
        title: group.title,
        albumType: group.primaryType?.toLowerCase() ?? null,
        releaseDate: group.firstReleaseDate,
        trackCount: null,
        images: coverArtImages(group.id),
      })),
      nextCursor: offset + items.length < total ? String(offset + items.length) : null,
    };
  }

  async getAlbum(id: string): Promise<CatalogAlbum> {
    // id = release-group MBID : on choisit la release officielle la plus
    // ancienne (édition originale) puis on charge sa tracklist.
    const releases = await this.client.browseReleaseGroupReleases(id);
    const canonical = [...releases].sort((a, b) =>
      (a.date ?? '9999').localeCompare(b.date ?? '9999'),
    )[0];
    const detail = canonical ? await this.client.lookupReleaseWithTracks(canonical.id) : null;
    if (!detail) {
      throw Object.assign(new Error('Album MusicBrainz introuvable'), { statusCode: 404 });
    }
    return {
      reference: this.reference('album', id),
      title: detail.title,
      artists: detail.artistCreditPhrase
        ? [{ name: detail.artistCreditPhrase, reference: null }]
        : [],
      releaseDate: detail.date,
      albumType: null,
      label: detail.label,
      copyright: null,
      upc: null,
      mbid: id,
      images: coverArtImages(id),
      discCount: detail.discCount,
      trackCount: detail.tracks.length,
      tracks: detail.tracks.map((track, index) => ({
        discNumber: track.discNumber,
        trackNumber: track.trackNumber,
        position: index + 1,
        title: track.title,
        artists: track.artistCreditPhrase
          ? [{ name: track.artistCreditPhrase, reference: null }]
          : [],
        durationMs: track.lengthMs,
        explicit: null,
        isrc: track.isrc,
        reference: track.recordingId ? this.reference('track', track.recordingId) : null,
        preview: null,
      })),
      externalLinks: [this.selfLink('release-group', id)],
    };
  }

  // --- Mappers ---------------------------------------------------------------

  private reference(entityType: CatalogEntityType, mbid: string): ProviderReference {
    const path = entityType === 'album' ? 'release-group' : entityType === 'track' ? 'recording' : entityType;
    return {
      provider: 'musicbrainz',
      entityType,
      externalId: mbid,
      externalUrl: `https://musicbrainz.org/${path}/${mbid}`,
      market: null,
    };
  }

  private selfLink(path: string, mbid: string): ExternalPlatformLink {
    return {
      platform: 'musicbrainz',
      url: `https://musicbrainz.org/${path}/${mbid}`,
      status: 'CONFIRMED',
      source: 'MUSICBRAINZ_OFFICIAL_API',
      matchMethod: 'MBID',
      confidence: 1,
    };
  }

  private recordingResult(
    recording: MusicBrainzRecordingCandidate,
    isrc: string | null = null,
  ): CatalogSearchResult {
    const release = recording.releases[0] ?? null;
    return {
      canonicalKey: isrc ? `isrc:${isrc}` : `mbid:${recording.id}`,
      entityType: 'track',
      title: recording.title,
      artists: recording.artistCreditPhrase
        ? [
            {
              name: recording.artistCreditPhrase,
              reference: recording.artistId ? this.reference('artist', recording.artistId) : null,
            },
          ]
        : [],
      album: release?.title ?? null,
      durationMs: recording.lengthMs,
      releaseDate: release?.date ?? null,
      explicit: null,
      images: coverArtImages(release?.releaseGroupId ?? null),
      isrc,
      upc: null,
      mbid: recording.id,
      trackCount: null,
      providerReferences: [this.reference('track', recording.id)],
      externalLinks: [this.selfLink('recording', recording.id)],
      preview: null,
      matchConfidence: 'POSSIBLE',
    };
  }

  private artistResult(mbid: string, name: string): CatalogSearchResult {
    const reference = this.reference('artist', mbid);
    return {
      canonicalKey: `mbid:${mbid}`,
      entityType: 'artist',
      title: name,
      artists: [{ name, reference }],
      album: null,
      durationMs: null,
      releaseDate: null,
      explicit: null,
      images: [],
      isrc: null,
      upc: null,
      mbid,
      trackCount: null,
      providerReferences: [reference],
      externalLinks: [this.selfLink('artist', mbid)],
      preview: null,
      matchConfidence: 'STRONG',
    };
  }

  private releaseGroupResult(group: MusicBrainzReleaseGroupCandidate): CatalogSearchResult {
    return {
      canonicalKey: `mbid:${group.id}`,
      entityType: 'album',
      title: group.title,
      artists: group.artistCreditPhrase
        ? [
            {
              name: group.artistCreditPhrase,
              reference: group.artistId ? this.reference('artist', group.artistId) : null,
            },
          ]
        : [],
      album: group.title,
      durationMs: null,
      releaseDate: group.firstReleaseDate,
      explicit: null,
      images: coverArtImages(group.id),
      isrc: null,
      upc: null,
      mbid: group.id,
      trackCount: null,
      providerReferences: [this.reference('album', group.id)],
      externalLinks: [this.selfLink('release-group', group.id)],
      preview: null,
      matchConfidence: 'POSSIBLE',
    };
  }
}
