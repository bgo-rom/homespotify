import { describe, expect, it } from 'vitest';
import { DeezerDiscoveryProvider } from './deezer-discovery-provider.js';
import { CatalogProviderError } from './types.js';

function providerWith(body: unknown, status = 200) {
  const calls: string[] = [];
  const provider = new DeezerDiscoveryProvider({
    baseUrl: 'https://deezer.test',
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

describe('DeezerDiscoveryProvider', () => {
  it('enrichit PARAFFINE avec pochette, photo artiste et aperçu officiel', async () => {
    const { provider, calls } = providerWith({
      total: 1,
      data: [{
        id: 31337,
        title: 'PARAFFINE',
        duration: 133,
        explicit_lyrics: true,
        preview: 'https://cdn-preview.dzcdn.net/paraffine.mp3',
        link: 'https://www.deezer.com/track/31337',
        artist: {
          id: 42,
          name: 'Ajna',
          link: 'https://www.deezer.com/artist/42',
          picture_xl: 'https://cdn-images.dzcdn.net/artist.jpg',
        },
        album: {
          id: 7,
          title: 'L’HERMITE',
          cover_xl: 'https://cdn-images.dzcdn.net/cover.jpg',
        },
      }],
    });

    const page = await provider.search({
      query: 'PARAFFINE AJNA',
      type: 'track',
      market: 'FR',
      limit: 20,
      cursor: null,
    });

    expect(calls[0]).toContain('/search?');
    expect(page.items[0]).toMatchObject({
      canonicalKey: 'deezer:track:31337',
      title: 'PARAFFINE',
      album: 'L’HERMITE',
      durationMs: 133_000,
      images: [{ url: 'https://cdn-images.dzcdn.net/cover.jpg' }],
      preview: {
        provider: 'deezer',
        url: 'https://cdn-preview.dzcdn.net/paraffine.mp3',
        durationMs: 30_000,
        expiresAt: null,
      },
    });
  });

  it('extrait l’expiration des previews Deezer signées', async () => {
    const { provider } = providerWith({
      total: 1,
      data: [{
        id: 31337,
        title: 'PARAFFINE',
        preview: 'https://cdnt-preview.dzcdn.net/audio.mp3?hdnea=exp=1784581008~acl=%2F*~hmac=test',
        artist: { id: 42, name: 'Ajna' },
        album: { id: 7, title: 'L’HERMITE' },
      }],
    });

    const page = await provider.search({
      query: 'PARAFFINE AJNA', type: 'track', market: 'FR', limit: 20, cursor: null,
    });

    expect(page.items[0]?.preview?.expiresAt).toBe('2026-07-20T20:56:48.000Z');
  });

  it('normalise une photo artiste depuis la recherche dédiée', async () => {
    const { provider } = providerWith({
      total: 1,
      data: [{
        id: 42,
        name: 'Ajna',
        link: 'https://www.deezer.com/artist/42',
        picture_xl: 'https://cdn-images.dzcdn.net/ajna.jpg',
      }],
    });

    const page = await provider.search({
      query: 'Ajna', type: 'artist', market: 'FR', limit: 20, cursor: null,
    });
    expect(page.items[0]?.images[0]?.url).toContain('ajna.jpg');
  });

  it('place l’artiste auteur des titres devant les homonymes et retire les résultats fuzzy', async () => {
    const provider = new DeezerDiscoveryProvider({
      baseUrl: 'https://deezer.test',
      fetchImpl: (async (input: RequestInfo | URL) => {
        const url = String(input);
        const body = url.includes('/search/artist')
          ? {
              total: 4,
              data: [
                { id: 1, name: 'Ajna', nb_fan: 9, picture_xl: 'https://img.test/wrong.jpg' },
                { id: 2, name: 'ELIESG', nb_fan: 765, picture_xl: 'https://img.test/fuzzy.jpg' },
                { id: 1197134, name: 'Ajna', nb_fan: 22408, picture_xl: 'https://img.test/rapper.jpg' },
                { id: 3, name: 'Ajna', nb_fan: 20, picture_xl: 'https://img.test/other.jpg' },
              ],
            }
          : {
              total: 3,
              data: [
                { id: 10, title: 'AJCENSION', rank: 900000, artist: { id: 1197134, name: 'Ajna' } },
                { id: 11, title: 'PARAFFINE', rank: 850000, artist: { id: 1197134, name: 'Ajna' } },
                { id: 12, title: 'Autre', rank: 10, artist: { id: 1, name: 'Ajna' } },
              ],
            };
        return new Response(JSON.stringify(body), { status: 200 });
      }) as typeof fetch,
    });

    const page = await provider.search({
      query: 'Ajna', type: 'artist', market: 'FR', limit: 20, cursor: null,
    });
    expect(page.items[0]).toMatchObject({
      title: 'Ajna',
      canonicalKey: 'deezer:artist:1197134',
      images: [{ url: 'https://img.test/rapper.jpg' }],
    });
    expect(page.items.every((item) => item.title.toLowerCase() === 'ajna')).toBe(true);
  });

  it('catégorise une limitation distante sans exposer le corps', async () => {
    const { provider } = providerWith({ secret: 'ne doit pas sortir' }, 429);
    await expect(provider.search({
      query: 'test', type: 'track', market: 'FR', limit: 10, cursor: null,
    })).rejects.toMatchObject<CatalogProviderError>({ category: 'RATE_LIMITED' });
  });
});
