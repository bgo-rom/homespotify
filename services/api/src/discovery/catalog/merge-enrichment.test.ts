import { describe, expect, it } from 'vitest';
import {
  keepExactArtistMatchesWhenAvailable,
  mergeSearchResults,
  rankSearchResults,
} from './merge.js';
import type { CatalogSearchResult, DiscoveryProviderId } from './types.js';

function result(
  provider: DiscoveryProviderId,
  entityType: 'artist' | 'track' | 'album',
  title: string,
  options: { artist?: string; image?: string; preview?: string; mbid?: string } = {},
): CatalogSearchResult {
  return {
    canonicalKey: `${provider}:${entityType}:${title}`,
    entityType,
    title,
    artists: [{ name: options.artist ?? title, reference: null }],
    album: null,
    durationMs: entityType === 'track' ? 120_000 : null,
    releaseDate: null,
    explicit: null,
    images: options.image ? [{ url: options.image, width: 1000, height: 1000 }] : [],
    isrc: null,
    upc: null,
    mbid: options.mbid ?? null,
    trackCount: null,
    providerReferences: [{
      provider,
      entityType,
      externalId: `${provider}-${title}`,
      externalUrl: null,
      market: 'FR',
    }],
    externalLinks: [],
    preview: options.preview ? {
      provider,
      url: options.preview,
      durationMs: 30_000,
      expiresAt: null,
      requiresOfficialSdk: false,
      attribution: provider,
    } : null,
    matchConfidence: 'POSSIBLE',
  };
}

describe('fusion enrichie du catalogue', () => {
  it('regroupe les homonymes artiste et conserve la photo Deezer', () => {
    const merged = mergeSearchResults([
      [result('deezer', 'artist', 'Ajna', { image: 'https://img.test/ajna.jpg' })],
      [result('musicbrainz', 'artist', 'AJNA', { mbid: 'mbid-1' })],
      [result('musicbrainz', 'artist', 'Ajna', { mbid: 'mbid-2' })],
    ]);

    expect(merged).toHaveLength(1);
    expect(merged[0]?.images[0]?.url).toContain('ajna.jpg');
    expect(merged[0]?.providerReferences).toHaveLength(3);
  });

  it('classe une piste illustrée et écoutable avant un résultat incomplet', () => {
    const incomplete = result('musicbrainz', 'track', 'Titre exact', { artist: 'Artiste' });
    const enriched = result('deezer', 'track', 'Autre titre', {
      artist: 'Artiste',
      image: 'https://img.test/cover.jpg',
      preview: 'https://preview.test/audio.mp3',
    });
    expect(rankSearchResults([incomplete, enriched], 'titre')[0]).toBe(enriched);
  });

  it('retire les artistes fuzzy dès qu’un nom exact existe', () => {
    const exact = result('deezer', 'artist', 'Ajna', {
      image: 'https://img.test/ajna.jpg',
    });
    const unrelated = result('musicbrainz', 'artist', 'Ajna Masters');

    expect(keepExactArtistMatchesWhenAvailable([unrelated, exact], 'Ajna')).toEqual([exact]);
  });

  it('regroupe un même album et conserve tous ses enrichissements', () => {
    const illustrated = result('deezer', 'album', 'Antidote', {
      artist: 'Ajna',
      image: 'https://img.test/antidote.jpg',
    });
    const canonical = result('musicbrainz', 'album', 'ANTIDOTE', {
      artist: 'AJNA',
      mbid: 'album-mbid',
    });

    const merged = mergeSearchResults([[illustrated], [canonical]]);
    expect(merged).toHaveLength(1);
    expect(merged[0]?.images[0]?.url).toContain('antidote.jpg');
    expect(merged[0]?.providerReferences).toHaveLength(2);
  });
});
