import { describe, expect, it } from 'vitest';
import type { CatalogSearchResult, DiscoveryProviderId } from '../discovery/catalog/types.js';
import {
  candidatesForResult,
  scoreTrackMatch,
  TrackCandidateResolver,
} from './candidate-resolver.js';

function track(options: {
  title: string;
  artist: string;
  album?: string | null;
  durationSeconds?: number | null;
  isrc?: string | null;
  providers?: Array<{ id: DiscoveryProviderId; url: string | null }>;
  images?: boolean;
}): CatalogSearchResult {
  const providers = options.providers ?? [
    { id: 'deezer', url: 'https://www.deezer.com/track/1' },
  ];
  return {
    canonicalKey: options.isrc ? `isrc:${options.isrc}` : `id:${options.title}`,
    entityType: 'track',
    title: options.title,
    artists: [{ name: options.artist, reference: null }],
    album: options.album ?? null,
    durationMs:
      options.durationSeconds === undefined || options.durationSeconds === null
        ? null
        : options.durationSeconds * 1000,
    releaseDate: null,
    explicit: null,
    images: options.images === false ? [] : [{ url: 'https://cdn/img.jpg', width: 500, height: 500 }],
    isrc: options.isrc ?? null,
    upc: null,
    mbid: null,
    trackCount: null,
    providerReferences: providers.map((entry) => ({
      provider: entry.id,
      entityType: 'track' as const,
      externalId: 'x',
      externalUrl: entry.url,
      market: 'FR',
    })),
    externalLinks: [],
    preview: null,
    matchConfidence: 'STRONG',
  };
}

const resolver = new TrackCandidateResolver();

describe('scoreTrackMatch — priorités imposées', () => {
  it('l’ISRC identique l’emporte sur tout le reste', () => {
    const wrongText = track({
      title: 'Titre totalement différent',
      artist: 'Autre artiste',
      isrc: 'USUM71703861',
    });
    expect(
      scoreTrackMatch(wrongText, { query: 'Guala Lifestyles' }, {
        expectedIsrc: 'USUM71703861',
      }),
    ).toBe(100);
  });

  it('un ISRC connu ET différent disqualifie totalement', () => {
    const other = track({
      title: 'Lifestyles',
      artist: 'Guala',
      isrc: 'FRXXX0000001',
    });
    expect(
      scoreTrackMatch(other, { query: 'Guala Lifestyles' }, {
        expectedIsrc: 'USUM71703861',
      }),
    ).toBe(0);
  });

  it('exige des tokens dans le titre ET l’artiste, pas seulement dans l’un', () => {
    const both = track({ title: 'Lifestyles', artist: 'Guala' });
    const titleOnly = track({ title: 'Lifestyles', artist: 'Quelqu’un d’autre' });
    const artistOnly = track({ title: 'Autre morceau', artist: 'Guala' });

    const intent = { query: 'Guala Lifestyles' };
    expect(scoreTrackMatch(both, intent)).toBeGreaterThan(
      scoreTrackMatch(titleOnly, intent),
    );
    expect(scoreTrackMatch(both, intent)).toBeGreaterThan(
      scoreTrackMatch(artistOnly, intent),
    );
  });

  it('fonctionne quel que soit l’ordre de saisie', () => {
    const result = track({ title: 'Lifestyles', artist: 'Guala' });
    expect(scoreTrackMatch(result, { query: 'Guala Lifestyles' })).toBe(
      scoreTrackMatch(result, { query: 'Lifestyles Guala' }),
    );
  });

  it('utilise la durée dans le score', () => {
    const close = track({ title: 'Lifestyles', artist: 'Guala', durationSeconds: 180 });
    const far = track({ title: 'Lifestyles', artist: 'Guala', durationSeconds: 600 });
    const intent = { query: 'Guala Lifestyles' };
    expect(
      scoreTrackMatch(close, intent, { expectedDurationSeconds: 181 }),
    ).toBeGreaterThan(scoreTrackMatch(far, intent, { expectedDurationSeconds: 181 }));
  });

  it('préfère la version studio quand aucune variante n’est demandée', () => {
    const studio = track({ title: 'Lifestyles', artist: 'Guala' });
    const remix = track({ title: 'Lifestyles (Remix)', artist: 'Guala' });
    const live = track({ title: 'Lifestyles - Live', artist: 'Guala' });
    const intent = { query: 'Guala Lifestyles' };

    expect(scoreTrackMatch(studio, intent)).toBeGreaterThan(scoreTrackMatch(remix, intent));
    expect(scoreTrackMatch(studio, intent)).toBeGreaterThan(scoreTrackMatch(live, intent));
  });

  it('respecte une variante explicitement demandée', () => {
    const remix = track({ title: 'Lifestyles (Remix)', artist: 'Guala' });
    expect(
      scoreTrackMatch(remix, { query: 'Guala Lifestyles Remix' }),
    ).toBeGreaterThan(scoreTrackMatch(remix, { query: 'Guala Lifestyles' }));
  });

  it('exploite title et artist explicites quand ils sont fournis', () => {
    const exact = track({ title: 'Lifestyles', artist: 'Guala' });
    const wrongArtist = track({ title: 'Lifestyles', artist: 'Autre' });
    const intent = { query: '', title: 'Lifestyles', artist: 'Guala' };
    expect(scoreTrackMatch(exact, intent)).toBeGreaterThan(
      scoreTrackMatch(wrongArtist, intent),
    );
  });
});

describe('candidatesForResult — ordre des sources', () => {
  it('classe Spotify avant Qobuz/Apple, puis Deezer verrouillé', () => {
    const result = track({
      title: 'Lifestyles',
      artist: 'Guala',
      providers: [
        { id: 'deezer', url: 'https://www.deezer.com/track/1' },
        { id: 'itunes', url: 'https://music.apple.com/fr/album/x/1?i=2' },
        { id: 'spotify', url: 'https://open.spotify.com/track/abc' },
      ],
    });

    const candidates = candidatesForResult(result, 80);
    expect(candidates.map((entry) => entry.provider)).toEqual([
      'spotify',
      'itunes',
      'deezer',
    ]);
    expect(candidates[0]?.sourceRank).toBeGreaterThan(candidates[1]!.sourceRank);
  });

  it('ignore les URL hors allowlist et les doublons', () => {
    const result = track({
      title: 'Lifestyles',
      artist: 'Guala',
      providers: [
        { id: 'musicbrainz', url: 'https://musicbrainz.org/recording/abc' },
        { id: 'deezer', url: 'https://www.deezer.com/track/1' },
        { id: 'deezer', url: 'https://www.deezer.com/track/1?utm_source=x' },
        { id: 'spotify', url: null },
      ],
    });

    const candidates = candidatesForResult(result, 80);
    expect(candidates).toHaveLength(1);
    expect(candidates[0]?.url).toBe('https://www.deezer.com/track/1');
  });

  it('n’expose jamais une référence d’album comme candidat de piste', () => {
    const result = track({ title: 'Lifestyles', artist: 'Guala' });
    result.providerReferences[0]!.entityType = 'album';
    expect(candidatesForResult(result, 80)).toHaveLength(0);
  });
});

describe('TrackCandidateResolver — décision', () => {
  it('retient la bonne piste quand elle se détache', () => {
    const resolution = resolver.resolve(
      [
        track({ title: 'Lifestyle', artist: 'Rich Gang' }),
        track({
          title: 'Lifestyles',
          artist: 'Guala',
          providers: [
            { id: 'spotify', url: 'https://open.spotify.com/track/abc' },
            { id: 'deezer', url: 'https://www.deezer.com/track/1' },
          ],
        }),
      ],
      { query: 'Guala Lifestyles' },
    );

    expect(resolution.kind).toBe('confident');
    if (resolution.kind !== 'confident') return;
    expect(resolution.track.title).toBe('Lifestyles');
    expect(resolution.track.artist).toBe('Guala');
    expect(resolution.track.candidates[0]?.provider).toBe('spotify');
  });

  it('rejette un homonyme qui ne partage que le titre', () => {
    const resolution = resolver.resolve(
      [track({ title: 'Lifestyles', artist: 'Un Tout Autre Groupe' })],
      { query: 'Guala Lifestyles' },
    );
    // Score plausible mais insuffisant : on demande confirmation plutôt que
    // d'importer une mauvaise piste.
    expect(resolution.kind).not.toBe('confident');
  });

  it('demande un choix quand deux pistes distinctes sont proches', () => {
    const resolution = resolver.resolve(
      [
        track({ title: 'Lifestyles', artist: 'Guala', isrc: 'AAAAA0000001' }),
        track({ title: 'Lifestyles', artist: 'Guala', isrc: 'BBBBB0000002' }),
      ],
      { query: 'Guala Lifestyles' },
    );
    expect(resolution.kind).toBe('ambiguous');
    if (resolution.kind !== 'ambiguous') return;
    expect(resolution.options.length).toBeGreaterThanOrEqual(2);
  });

  it('ne considère pas deux catalogues du MÊME ISRC comme une ambiguïté', () => {
    const resolution = resolver.resolve(
      [
        track({
          title: 'Lifestyles',
          artist: 'Guala',
          isrc: 'AAAAA0000001',
          providers: [{ id: 'spotify', url: 'https://open.spotify.com/track/abc' }],
        }),
        track({
          title: 'Lifestyles',
          artist: 'Guala',
          isrc: 'AAAAA0000001',
          providers: [{ id: 'deezer', url: 'https://www.deezer.com/track/1' }],
        }),
      ],
      { query: 'Guala Lifestyles' },
    );
    expect(resolution.kind).toBe('confident');
  });

  it('retourne no_match quand rien n’est plausible', () => {
    expect(
      resolver.resolve(
        [track({ title: 'Symphonie n°9', artist: 'Beethoven' })],
        { query: 'Guala Lifestyles' },
      ).kind,
    ).toBe('no_match');
    expect(resolver.resolve([], { query: 'Guala Lifestyles' }).kind).toBe('no_match');
  });

  it('écarte une piste sans aucune URL téléchargeable', () => {
    const resolution = resolver.resolve(
      [
        track({
          title: 'Lifestyles',
          artist: 'Guala',
          providers: [{ id: 'musicbrainz', url: 'https://musicbrainz.org/recording/x' }],
        }),
      ],
      { query: 'Guala Lifestyles' },
    );
    expect(resolution.kind).toBe('no_match');
  });
});
