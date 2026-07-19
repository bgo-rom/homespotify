import { describe, expect, it } from 'vitest';
import { ItunesCatalogProvider, normalizeForMatch } from './preview-provider.js';

interface FakeCall {
  url: string;
}

function makeFetch(
  respond: (url: string) => { status?: number; results?: unknown[] } | Error,
  calls: FakeCall[] = [],
): typeof fetch {
  return (async (input: string | URL | Request) => {
    const url = String(input);
    calls.push({ url });
    const out = respond(url);
    if (out instanceof Error) throw out;
    return {
      ok: (out.status ?? 200) === 200,
      status: out.status ?? 200,
      statusText: '',
      json: async () => ({ resultCount: out.results?.length ?? 0, results: out.results ?? [] }),
      text: async () => '',
    } as Response;
  }) as typeof fetch;
}

const song = (over: Record<string, unknown> = {}) => ({
  trackId: 111,
  trackName: 'Titre',
  artistName: 'Artiste',
  collectionName: 'Album',
  trackTimeMillis: 200_000,
  previewUrl: 'https://audio-ssl.itunes.apple.com/p.m4a',
  artworkUrl100: 'https://is1-ssl.mzstatic.com/x/100x100bb.jpg',
  ...over,
});

describe('normalizeForMatch', () => {
  it('retire diacritiques, parenthèses, feat. et ponctuation', () => {
    expect(normalizeForMatch('Possédée (Live)')).toBe('possedee');
    expect(normalizeForMatch('Aimé feat. Quelqu’un')).toBe('aime');
    expect(normalizeForMatch('Café — Déjà Vu!')).toBe('cafe deja vu');
  });
});

describe('ItunesCatalogProvider — identité + désambiguïsation canonique', () => {
  it('ISRC exact : confiance 1.0, storefront FR', async () => {
    const calls: FakeCall[] = [];
    const provider = new ItunesCatalogProvider({
      fetchImpl: makeFetch(
        (url) => (url.includes('isrc=FRXXX0000001') ? { results: [song()] } : { results: [] }),
        calls,
      ),
    });
    const match = await provider.findPreview({
      title: 'Titre',
      artist: 'Artiste',
      durationMs: 200_000,
      isrc: 'FRXXX0000001',
    });
    expect(match).toMatchObject({ provider: 'ITUNES', confidence: 1.0, catalogId: '111' });
    expect(match?.artworkUrl).toContain('600x600bb');
    expect(match?.artworkWidth).toBe(600);
    expect(calls.some((c) => c.url.includes('country=FR'))).toBe(true);
  });

  it('catalogId stable : confiance 0.95', async () => {
    const provider = new ItunesCatalogProvider({
      fetchImpl: makeFetch((url) => (url.includes('/lookup?id=111') ? { results: [song()] } : { results: [] })),
    });
    const match = await provider.findPreview({
      title: 'Titre',
      artist: 'Artiste',
      durationMs: null,
      catalogId: '111',
    });
    expect(match?.confidence).toBe(0.95);
  });

  it('durée corroborée : version la plus proche, confiance 0.9', async () => {
    const provider = new ItunesCatalogProvider({
      fetchImpl: makeFetch((url) =>
        url.includes('/search?')
          ? {
              results: [
                song({ trackId: 1, trackTimeMillis: 260_000 }), // trop loin
                song({ trackId: 2, trackTimeMillis: 198_000 }), // proche
              ],
            }
          : { results: [] },
      ),
    });
    const match = await provider.findPreview({ title: 'Titre', artist: 'Artiste', durationMs: 200_000 });
    expect(match).toMatchObject({ confidence: 0.9, catalogId: '2' });
  });

  it('PLUSIEURS versions studio, aucune durée fiable : prend la première (0.85), jamais null', async () => {
    // Cas Phase 1 (Thriller/Airbourne) : l'ancien code abandonnait, le nouveau
    // choisit la version canonique.
    const provider = new ItunesCatalogProvider({
      fetchImpl: makeFetch(() => ({
        results: [song({ trackId: 10 }), song({ trackId: 11 }), song({ trackId: 12 })],
      })),
    });
    const match = await provider.findPreview({ title: 'Titre', artist: 'Artiste', durationMs: null });
    expect(match).toMatchObject({ confidence: 0.85, catalogId: '10' });
  });

  it('exclut les versions live/remix au profit de la version studio', async () => {
    const provider = new ItunesCatalogProvider({
      fetchImpl: makeFetch(() => ({
        results: [
          song({ trackId: 1, trackName: 'Titre (Live)' }),
          song({ trackId: 2, trackName: 'Titre - Remix' }),
          song({ trackId: 3, trackName: 'Titre' }), // seule vraie studio
        ],
      })),
    });
    const match = await provider.findPreview({ title: 'Titre', artist: 'Artiste', durationMs: null });
    expect(match?.catalogId).toBe('3');
  });

  it('durée seed FAUSSE (hors de toute version) : ne rejette pas, désambiguïse par version', async () => {
    // Cas GNR : Last.fm annonce 569 s, aucune version iTunes n'est proche.
    const provider = new ItunesCatalogProvider({
      fetchImpl: makeFetch(() => ({ results: [song({ trackId: 7, trackTimeMillis: 303_000 })] })),
    });
    const match = await provider.findPreview({ title: 'Titre', artist: 'Artiste', durationMs: 569_000 });
    expect(match?.catalogId).toBe('7');
  });

  it('studios DISTINCTS (durées éloignées) sans arbitre de durée : AMBIGUOUS → null', async () => {
    const provider = new ItunesCatalogProvider({
      fetchImpl: makeFetch(() => ({
        results: [
          song({ trackId: 1, trackTimeMillis: 120_000 }),
          song({ trackId: 2, trackTimeMillis: 240_000 }),
        ],
      })),
    });
    expect(
      await provider.findPreview({ title: 'Titre', artist: 'Artiste', durationMs: null }),
    ).toBeNull();
  });

  it('identité absente du catalogue : null (MEDIA_UNAVAILABLE en amont)', async () => {
    const provider = new ItunesCatalogProvider({
      fetchImpl: makeFetch(() => ({ results: [song({ trackName: 'Autre Chanson', artistName: 'Autre' })] })),
    });
    expect(
      await provider.findPreview({ title: 'Titre', artist: 'Artiste', durationMs: null }),
    ).toBeNull();
  });

  it('previewUrl non https rejetée', async () => {
    const provider = new ItunesCatalogProvider({
      fetchImpl: makeFetch(() => ({ results: [song({ previewUrl: 'http://insecure.example/p.m4a' })] })),
    });
    expect(
      await provider.findPreview({ title: 'Titre', artist: 'Artiste', durationMs: null }),
    ).toBeNull();
  });

  it('échec réseau : null, jamais d’exception (la préparation continue)', async () => {
    const provider = new ItunesCatalogProvider({
      maxRetries: 0,
      fetchImpl: makeFetch(() => new Error('réseau coupé')),
    });
    await expect(
      provider.findPreview({ title: 'Titre', artist: 'Artiste', durationMs: null }),
    ).resolves.toBeNull();
  });

  it('cache TTL : pas de second appel réseau pour la même requête', async () => {
    const calls: FakeCall[] = [];
    const provider = new ItunesCatalogProvider({
      fetchImpl: makeFetch(() => ({ results: [song()] }), calls),
    });
    const input = { title: 'Titre', artist: 'Artiste', durationMs: null };
    await provider.findPreview(input);
    const after = calls.length;
    await provider.findPreview(input);
    expect(calls.length).toBe(after);
  });

  it('single-flight : deux résolutions concurrentes identiques ⇒ un seul appel', async () => {
    const calls: FakeCall[] = [];
    const provider = new ItunesCatalogProvider({
      fetchImpl: makeFetch(() => ({ results: [song()] }), calls),
    });
    const input = { title: 'SoloTitre', artist: 'SoloArtiste', durationMs: null };
    const [a, b] = await Promise.all([provider.findPreview(input), provider.findPreview(input)]);
    expect(a?.catalogId).toBe(b?.catalogId);
    expect(calls.length).toBe(1);
  });

  it('retry avec backoff sur 5xx puis succès', async () => {
    let attempt = 0;
    const provider = new ItunesCatalogProvider({
      sleep: async () => {},
      fetchImpl: makeFetch(() => {
        attempt += 1;
        return attempt === 1 ? { status: 503, results: [] } : { results: [song()] };
      }),
    });
    const match = await provider.findPreview({ title: 'Titre', artist: 'Artiste', durationMs: null });
    expect(match).not.toBeNull();
    expect(attempt).toBe(2);
  });
});
