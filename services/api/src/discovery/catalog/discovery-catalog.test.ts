import { describe, expect, it } from 'vitest';
import { createDb } from '../../db/client.js';
import { runMigrations } from '../../db/migrate.js';
import { DiscoveryCache, DISCOVERY_CACHE_TTLS_MS } from './discovery-cache.js';
import { mergeSearchResults, rankSearchResults } from './merge.js';
import { platformLinksFromUrlRelations } from './musicbrainz-catalog-provider.js';
import { SpotifyCatalogProvider, decodeOffsetCursor, encodeOffsetCursor } from './spotify-catalog-provider.js';
import { CatalogProviderError, type CatalogSearchResult } from './types.js';

function trackResult(overrides: Partial<CatalogSearchResult>): CatalogSearchResult {
  return {
    canonicalKey: 'test',
    entityType: 'track',
    title: 'Titre',
    artists: [{ name: 'Artiste', reference: null }],
    album: null,
    durationMs: 200_000,
    releaseDate: null,
    explicit: null,
    images: [],
    isrc: null,
    upc: null,
    mbid: null,
    trackCount: null,
    providerReferences: [],
    externalLinks: [],
    preview: null,
    matchConfidence: 'POSSIBLE',
    ...overrides,
  };
}

describe('fusion multi-fournisseurs', () => {
  it('déduplique par ISRC exact en conservant toutes les références', () => {
    const spotify = trackResult({
      title: 'Thriller',
      isrc: 'USQX90300111',
      providerReferences: [
        { provider: 'spotify', entityType: 'track', externalId: 's1', externalUrl: null, market: 'FR' },
      ],
    });
    const apple = trackResult({
      title: 'Thriller',
      isrc: 'USQX90300111',
      providerReferences: [
        { provider: 'apple_music', entityType: 'track', externalId: 'a1', externalUrl: null, market: 'FR' },
      ],
    });
    const merged = mergeSearchResults([[spotify], [apple]]);
    expect(merged).toHaveLength(1);
    expect(merged[0]!.providerReferences.map((r) => r.provider)).toEqual(['spotify', 'apple_music']);
    expect(merged[0]!.matchConfidence).toBe('STRONG');
  });

  it('déduplique par MBID exact', () => {
    const a = trackResult({ mbid: 'mbid-1', title: 'Chanson' });
    const b = trackResult({ mbid: 'mbid-1', title: 'Chanson' });
    expect(mergeSearchResults([[a], [b]])).toHaveLength(1);
  });

  it('ne fusionne JAMAIS un remix avec l’original', () => {
    const original = trackResult({ title: 'Around the World' });
    const remix = trackResult({ title: 'Around the World (Remix)' });
    expect(mergeSearchResults([[original], [remix]])).toHaveLength(2);
  });

  it('ne fusionne JAMAIS live et studio', () => {
    const studio = trackResult({ title: 'Thriller' });
    const live = trackResult({ title: 'Thriller (Live)' });
    expect(mergeSearchResults([[studio], [live]])).toHaveLength(2);
  });

  it('sépare deux enregistrements de durées éloignées sans clé forte', () => {
    const shortVersion = trackResult({ title: 'Chanson', durationMs: 180_000 });
    const longVersion = trackResult({ title: 'Chanson', durationMs: 320_000 });
    expect(mergeSearchResults([[shortVersion], [longVersion]])).toHaveLength(2);
  });

  it('fusionne la même identité à durée proche sans clé forte', () => {
    const a = trackResult({ title: 'Chanson', durationMs: 200_000 });
    const b = trackResult({ title: 'Chanson', durationMs: 203_000 });
    expect(mergeSearchResults([[a], [b]])).toHaveLength(1);
  });

  it('classement reproductible : ISRC + multi-catalogue devant', () => {
    const weak = trackResult({ title: 'Requête', canonicalKey: 'k1' });
    const strong = trackResult({
      title: 'Requête',
      canonicalKey: 'k2',
      isrc: 'FRAAA0000001',
      providerReferences: [
        { provider: 'spotify', entityType: 'track', externalId: '1', externalUrl: null, market: 'FR' },
        { provider: 'apple_music', entityType: 'track', externalId: '2', externalUrl: null, market: 'FR' },
      ],
    });
    const ranked = rankSearchResults([weak, strong], 'Requête');
    expect(ranked[0]!.canonicalKey).toBe('k2');
    // Déterminisme : le même appel produit le même ordre.
    expect(rankSearchResults([weak, strong], 'Requête')[0]!.canonicalKey).toBe('k2');
  });
});

describe('relations URL MusicBrainz → liens plateformes', () => {
  it('Bandcamp confirmé par relation = LINK_FOUND', () => {
    const links = platformLinksFromUrlRelations([
      { type: 'bandcamp', url: 'https://artiste.bandcamp.com/album/x' },
    ]);
    expect(links).toHaveLength(1);
    expect(links[0]).toMatchObject({ platform: 'bandcamp', status: 'LINK_FOUND' });
  });

  it('sans relation Qobuz, aucun lien n’est inventé (statut UNKNOWN en aval)', () => {
    expect(platformLinksFromUrlRelations([{ type: 'streaming', url: 'https://inconnu.example/x' }])).toEqual([]);
  });

  it('refuse les URLs non https', () => {
    expect(platformLinksFromUrlRelations([{ type: 'bandcamp', url: 'http://a.bandcamp.com' }])).toEqual([]);
  });
});

describe('cache discovery', () => {
  function makeCache(now: () => number, maxEntries = 100) {
    const handle = createDb(':memory:');
    runMigrations(handle, { info: () => undefined, error: () => undefined });
    return new DiscoveryCache(handle, { now, maxEntries });
  }

  const key = { provider: 'spotify', operation: 'search', queryHash: 'h1', market: 'FR' };

  it('miss puis hit puis expiration', () => {
    let clock = 1_000_000;
    const cache = makeCache(() => clock);
    expect(cache.get(key)).toBeNull();
    cache.set(key, { items: [1, 2] });
    expect(cache.get<{ items: number[] }>(key)?.value?.items).toEqual([1, 2]);
    clock += DISCOVERY_CACHE_TTLS_MS['search']! + 1;
    expect(cache.get(key)).toBeNull();
  });

  it('negative cache court pour les erreurs temporaires', () => {
    let clock = 1_000_000;
    const cache = makeCache(() => clock);
    cache.set(key, null, { negative: true });
    expect(cache.get(key)).toEqual({ value: null, negative: true });
    clock += DISCOVERY_CACHE_TTLS_MS['negative']! + 1;
    expect(cache.get(key)).toBeNull();
  });

  it('borne le nombre d’entrées (purge des plus anciennes)', () => {
    let clock = 1_000_000;
    const cache = makeCache(() => clock, 5);
    for (let index = 0; index < 12; index += 1) {
      clock += 10;
      cache.set({ ...key, queryHash: `h${index}` }, { index });
    }
    expect(cache.stats().entries).toBeLessThanOrEqual(5);
  });

  it('la clé est un hash : la requête en clair n’apparaît pas', () => {
    const hash = DiscoveryCache.hashQuery({ q: 'requête secrète', type: 'track' });
    expect(hash).toMatch(/^[a-f0-9]{64}$/u);
    expect(hash).not.toContain('secrète');
  });
});

describe('SpotifyCatalogProvider (fetch mocké, aucun réseau réel)', () => {
  const tokenResponse = () =>
    new Response(JSON.stringify({ access_token: 'jeton-test', expires_in: 3600 }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });

  function jsonResponse(body: unknown, status = 200, headers: Record<string, string> = {}) {
    return new Response(JSON.stringify(body), {
      status,
      headers: { 'content-type': 'application/json', ...headers },
    });
  }

  function makeProvider(handler: (url: string, init?: RequestInit) => Response | Promise<Response>) {
    const calls: string[] = [];
    const provider = new SpotifyCatalogProvider({
      clientId: 'id-test',
      clientSecret: 'secret-test',
      fetchImpl: (async (input: RequestInfo | URL, init?: RequestInit) => {
        const url = String(input);
        calls.push(url);
        if (url.includes('accounts.spotify.com')) return tokenResponse();
        return handler(url, init);
      }) as typeof fetch,
    });
    return { provider, calls };
  }

  it('recherche track : mapping unifié + ISRC + jamais de preview_url', async () => {
    const { provider } = makeProvider(() =>
      jsonResponse({
        tracks: {
          items: [
            {
              id: 't1',
              name: 'Chanson',
              duration_ms: 201_000,
              explicit: false,
              preview_url: 'https://p.scdn.co/mp3-preview/x',
              artists: [{ id: 'a1', name: 'Artiste', external_urls: { spotify: 'https://open.spotify.com/artist/a1' } }],
              album: { id: 'al1', name: 'Album', release_date: '2001-03-01', images: [{ url: 'https://i.scdn.co/image/1', width: 640, height: 640 }] },
              external_ids: { isrc: 'frz030100001' },
              external_urls: { spotify: 'https://open.spotify.com/track/t1' },
            },
          ],
          next: 'https://api.spotify.com/v1/search?offset=20',
        },
      }),
    );
    const page = await provider.search({ query: 'chanson', type: 'track', market: 'FR', limit: 20, cursor: null });
    expect(page.items).toHaveLength(1);
    const item = page.items[0]!;
    expect(item).toMatchObject({
      title: 'Chanson',
      isrc: 'FRZ030100001',
      canonicalKey: 'isrc:FRZ030100001',
      album: 'Album',
      preview: null, // preview_url déprécié : jamais exploité
    });
    expect(item.externalLinks[0]).toMatchObject({ platform: 'spotify', status: 'CONFIRMED' });
    expect(page.nextCursor).not.toBeNull();
    expect(decodeOffsetCursor(page.nextCursor)).toBe(1);
  });

  it('recherche artiste et album', async () => {
    const { provider } = makeProvider((url) => {
      if (url.includes('type=artist')) {
        return jsonResponse({ artists: { items: [{ id: 'a1', name: 'Artiste', images: [], external_urls: { spotify: 'https://open.spotify.com/artist/a1' } }] } });
      }
      return jsonResponse({ albums: { items: [{ id: 'al1', name: 'Album', total_tracks: 12, release_date: '1999', artists: [{ id: 'a1', name: 'Artiste' }], external_urls: { spotify: 'https://open.spotify.com/album/al1' } }] } });
    });
    const artists = await provider.search({ query: 'artiste', type: 'artist', market: 'FR', limit: 10, cursor: null });
    expect(artists.items[0]).toMatchObject({ entityType: 'artist', title: 'Artiste' });
    const albums = await provider.search({ query: 'album', type: 'album', market: 'FR', limit: 10, cursor: null });
    expect(albums.items[0]).toMatchObject({ entityType: 'album', title: 'Album', trackCount: 12 });
  });

  it('résolution ISRC : q=isrc:… et confiance EXACT', async () => {
    const { provider, calls } = makeProvider(() =>
      jsonResponse({ tracks: { items: [{ id: 't1', name: 'Chanson', external_ids: { isrc: 'FRZ030100001' }, artists: [], album: {} }] } }),
    );
    const results = await provider.resolveByIsrc('FRZ030100001', 'FR');
    expect(results[0]!.matchConfidence).toBe('EXACT');
    expect(calls.some((url) => url.includes('isrc%3AFRZ030100001') || url.includes('isrc:FRZ030100001'))).toBe(true);
  });

  it('429 : catégorie RATE_LIMITED avec Retry-After propagé', async () => {
    const { provider } = makeProvider(() => jsonResponse({}, 429, { 'retry-after': '7' }));
    await expect(
      provider.search({ query: 'x y', type: 'track', market: 'FR', limit: 5, cursor: null }),
    ).rejects.toMatchObject({ category: 'RATE_LIMITED', retryAfterMs: 7_000 });
  });

  it('503 : catégorie UPSTREAM_ERROR', async () => {
    const { provider } = makeProvider(() => jsonResponse({}, 503));
    await expect(
      provider.search({ query: 'x y', type: 'track', market: 'FR', limit: 5, cursor: null }),
    ).rejects.toMatchObject({ category: 'UPSTREAM_ERROR' });
  });

  it('401 en cours de route : un seul refresh forcé puis relance', async () => {
    let apiCalls = 0;
    const { provider } = makeProvider(() => {
      apiCalls += 1;
      if (apiCalls === 1) return jsonResponse({}, 401);
      return jsonResponse({ tracks: { items: [] } });
    });
    const page = await provider.search({ query: 'x y', type: 'track', market: 'FR', limit: 5, cursor: null });
    expect(page.items).toEqual([]);
    expect(apiCalls).toBe(2);
  });

  it('réponse non JSON : INVALID_RESPONSE (jamais de crash)', async () => {
    const { provider } = makeProvider(
      () => new Response('<html></html>', { status: 200, headers: { 'content-type': 'text/html' } }),
    );
    await expect(
      provider.search({ query: 'x y', type: 'track', market: 'FR', limit: 5, cursor: null }),
    ).rejects.toBeInstanceOf(CatalogProviderError);
  });

  it('le secret client ne sort que vers accounts.spotify.com en Basic', async () => {
    const seenHeaders: Array<Record<string, string>> = [];
    const provider = new SpotifyCatalogProvider({
      clientId: 'id-test',
      clientSecret: 'secret-test',
      fetchImpl: (async (input: RequestInfo | URL, init?: RequestInit) => {
        seenHeaders.push({ url: String(input), auth: String((init?.headers as Record<string, string>)?.authorization ?? '') });
        if (String(input).includes('accounts.spotify.com')) return tokenResponse();
        return jsonResponse({ tracks: { items: [] } });
      }) as typeof fetch,
    });
    await provider.search({ query: 'x y', type: 'track', market: 'FR', limit: 5, cursor: null });
    const apiCall = seenHeaders.find((entry) => entry.url!.includes('api.spotify.com'));
    expect(apiCall!.auth).toBe('Bearer jeton-test');
    expect(apiCall!.auth).not.toContain('secret-test');
  });

  it('curseur opaque : encode/décode robustes aux entrées invalides', () => {
    expect(decodeOffsetCursor(encodeOffsetCursor(40))).toBe(40);
    expect(decodeOffsetCursor('n-importe-quoi')).toBe(0);
    expect(decodeOffsetCursor(null)).toBe(0);
  });
});
