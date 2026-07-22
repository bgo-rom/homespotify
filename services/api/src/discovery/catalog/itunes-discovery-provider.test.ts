import { describe, expect, it } from 'vitest';
import { ItunesDiscoveryProvider } from './itunes-discovery-provider.js';
import { CatalogProviderError } from './types.js';

function providerWith(body: unknown, status = 200) {
  const calls: string[] = [];
  const provider = new ItunesDiscoveryProvider({
    baseUrl: 'https://itunes.test',
    fetchImpl: (async (input: RequestInfo | URL) => {
      calls.push(String(input));
      return new Response(JSON.stringify(body), {
        status,
        headers: { 'content-type': 'application/json' },
      });
    }) as typeof fetch,
  });
  return { provider, calls };
}

describe('ItunesDiscoveryProvider', () => {
  it('recherche gratuitement une piste et normalise les métadonnées', async () => {
    const { provider, calls } = providerWith({
      resultCount: 1,
      results: [{
        wrapperType: 'track',
        trackId: 42,
        trackName: 'PARAFFINE',
        trackViewUrl: 'https://music.apple.com/fr/song/paraffine/42',
        artistId: 7,
        artistName: 'AJNA',
        artistLinkUrl: 'https://music.apple.com/fr/artist/ajna/7',
        collectionId: 9,
        collectionName: 'PARAFFINE',
        trackTimeMillis: 133_000,
        trackExplicitness: 'explicit',
        previewUrl: 'https://audio-ssl.itunes.apple.com/preview.m4a',
        artworkUrl100: 'https://is1-ssl.mzstatic.com/image/100x100bb.jpg',
        releaseDate: '2024-01-05T00:00:00Z',
      }],
    });

    const page = await provider.search({
      query: 'AJNA PARAFFINE',
      type: 'track',
      market: 'FR',
      limit: 20,
      cursor: null,
    });

    expect(calls[0]).toContain('/search?');
    expect(calls[0]).toContain('entity=song');
    expect(page.items[0]).toMatchObject({
      canonicalKey: 'itunes:track:42',
      title: 'PARAFFINE',
      album: 'PARAFFINE',
      durationMs: 133_000,
      explicit: true,
      matchConfidence: 'STRONG',
    });
    expect(page.items[0]!.providerReferences[0]).toMatchObject({
      provider: 'itunes',
      externalId: '42',
    });
    expect(page.items[0]!.preview?.url).toContain('preview.m4a');
    expect(page.items[0]!.images[0]?.url).toContain('600x600bb');
  });

  it('charge la tracklist d’un album pour créer une demande complète', async () => {
    const { provider } = providerWith({
      resultCount: 2,
      results: [
        { wrapperType: 'collection', collectionId: 9, collectionName: 'Album', artistName: 'Artiste', trackCount: 1 },
        { wrapperType: 'track', collectionId: 9, trackId: 10, trackName: 'Titre', artistName: 'Artiste', trackNumber: 1, trackTimeMillis: 120_000 },
      ],
    });
    const album = await provider.getAlbum('9', 'FR');
    expect(album.title).toBe('Album');
    expect(album.tracks).toHaveLength(1);
    expect(album.tracks[0]).toMatchObject({ title: 'Titre', durationMs: 120_000 });
  });

  it('catégorise une limitation distante sans exposer son corps', async () => {
    const { provider } = providerWith({ message: 'secret upstream body' }, 429);
    await expect(provider.search({
      query: 'test', type: 'track', market: 'FR', limit: 10, cursor: null,
    })).rejects.toMatchObject<CatalogProviderError>({ category: 'RATE_LIMITED' });
  });
});
