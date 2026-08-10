/**
 * Régression du 2026-08-10 (LESSONS L-081).
 *
 * Demande réelle : `LONOWN addiction`, version NORMALE.
 * Résultat réel : `addiction (Slowed)` installé, deux fois.
 *
 * Les données ci-dessous sont celles du cache catalogue de PRODUCTION au
 * moment du job `b481f6e0-4ed2-48ce-9146-782e9711a166` : mêmes titres, même
 * album, même artiste, mêmes identifiants iTunes, mêmes durées.
 */
import { describe, expect, it } from 'vitest';
import { mergeSearchResults } from '../discovery/catalog/merge.js';
import type { CatalogSearchResult } from '../discovery/catalog/types.js';
import { TrackCandidateResolver } from './candidate-resolver.js';

const ARTIST = 'LONOWN & Asenssia';

function itunesTrack(input: {
  externalId: string;
  title: string;
  url: string;
  durationMs: number;
  album?: string;
}): CatalogSearchResult {
  return {
    canonicalKey: `itunes:track:${input.externalId}`,
    entityType: 'track',
    title: input.title,
    artists: [
      {
        name: ARTIST,
        reference: {
          provider: 'itunes',
          entityType: 'artist',
          externalId: '1648625793',
          externalUrl: null,
          market: 'FR',
        },
      },
    ],
    album: input.album ?? 'addiction - Single',
    durationMs: input.durationMs,
    releaseDate: '2026-05-15',
    explicit: false,
    images: [],
    isrc: null,
    upc: null,
    mbid: null,
    trackCount: null,
    providerReferences: [
      {
        provider: 'itunes',
        entityType: 'track',
        externalId: input.externalId,
        externalUrl: input.url,
        market: 'FR',
      },
    ],
    externalLinks: [],
    preview: null,
    matchConfidence: 'STRONG',
  };
}

const NORMAL_URL =
  'https://music.apple.com/fr/album/addiction/1895030608?i=6762825656&uo=4';
const SLOWED_URL =
  'https://music.apple.com/fr/album/addiction-slowed/1895030608?i=6762825657&uo=4';

const SLOWED = itunesTrack({
  externalId: '6762825657',
  title: 'addiction (Slowed)',
  url: SLOWED_URL,
  durationMs: 233_481,
});

const NORMAL = itunesTrack({
  externalId: '6762825656',
  title: 'addiction',
  url: NORMAL_URL,
  durationMs: 208_971,
});

describe('fusion catalogue — normal vs version alternative', () => {
  it('ne fusionne plus « addiction » et « addiction (Slowed) »', () => {
    // Ordre réel du catalogue : la version ralentie arrive en premier.
    const merged = mergeSearchResults([[SLOWED, NORMAL]]);

    expect(merged).toHaveLength(2);
    const titles = merged.map((result) => result.title);
    expect(titles).toContain('addiction');
    expect(titles).toContain('addiction (Slowed)');

    // Chaque carte ne porte QUE sa propre URL : c'est l'agrégation des
    // références sous un seul titre qui avait rendu la version normale
    // inatteignable.
    for (const result of merged) {
      expect(result.providerReferences).toHaveLength(1);
      const url = result.providerReferences[0]!.externalUrl;
      expect(url).toBe(result.title === 'addiction' ? NORMAL_URL : SLOWED_URL);
    }
  });

  it('fusionne toujours deux catalogues décrivant la MÊME version', () => {
    const deezerSameTrack: CatalogSearchResult = {
      ...NORMAL,
      canonicalKey: 'deezer:track:999',
      providerReferences: [
        {
          provider: 'deezer',
          entityType: 'track',
          externalId: '999',
          externalUrl: 'https://www.deezer.com/track/999',
          market: 'FR',
        },
      ],
    };

    const merged = mergeSearchResults([[NORMAL], [deezerSameTrack]]);
    expect(merged).toHaveLength(1);
    expect(merged[0]!.providerReferences).toHaveLength(2);
  });
});

describe('résolution de téléchargement — barrière de version', () => {
  const resolver = new TrackCandidateResolver();
  const catalogue = mergeSearchResults([[SLOWED, NORMAL]]);

  it('installe la version normale quand aucune variante n’est demandée', () => {
    const resolution = resolver.resolve(catalogue, {
      query: 'LONOWN addiction',
    });

    expect(resolution.kind).not.toBe('no_match');
    const options =
      resolution.kind === 'confident'
        ? [resolution.track, ...resolution.alternatives]
        : resolution.kind === 'ambiguous'
          ? resolution.options
          : [];

    // La version ralentie n'est même pas proposée : elle est écartée avant
    // tout score, donc aucune ambiguïté ne peut la faire remonter.
    expect(options.every((track) => track.title === 'addiction')).toBe(true);
    const urls = options.flatMap((track) =>
      track.candidates.map((candidate) => candidate.url),
    );
    expect(urls).toContain(NORMAL_URL);
    expect(urls).not.toContain(SLOWED_URL);
  });

  it('installe la version ralentie quand elle est explicitement demandée', () => {
    const resolution = resolver.resolve(catalogue, {
      query: 'LONOWN addiction slowed',
    });

    expect(resolution.kind).toBe('confident');
    if (resolution.kind !== 'confident') return;
    expect(resolution.track.title).toBe('addiction (Slowed)');
    expect(resolution.track.candidates[0]!.url).toBe(SLOWED_URL);
  });

  it('ne propose rien plutôt que la mauvaise version', () => {
    const resolution = resolver.resolve([SLOWED], {
      query: 'LONOWN addiction',
    });
    expect(resolution.kind).toBe('no_match');
  });

  it.each([
    ['addiction (Slowed)', 'slowed'],
    ['addiction (Sped Up)', 'sped up'],
    ['addiction (Live)', 'live'],
    ['addiction (Remix)', 'remix'],
  ])('n’assimile jamais normal et %s', (altTitle) => {
    const alternate = itunesTrack({
      externalId: '7000000001',
      title: altTitle,
      url: 'https://music.apple.com/fr/album/addiction-alt/1895030608?i=7000000001&uo=4',
      durationMs: 233_481,
    });

    // 1. La fusion les garde distincts.
    const merged = mergeSearchResults([[alternate, NORMAL]]);
    expect(merged).toHaveLength(2);

    // 2. Une demande normale ne retient jamais la variante…
    const normalRequest = resolver.resolve(merged, { query: 'LONOWN addiction' });
    expect(normalRequest.kind).toBe('confident');
    if (normalRequest.kind === 'confident') {
      expect(normalRequest.track.title).toBe('addiction');
      expect(normalRequest.alternatives).toHaveLength(0);
    }

    // 3. …et une demande de variante ne retient jamais la normale.
    const altRequest = resolver.resolve(merged, {
      query: `LONOWN ${altTitle}`,
    });
    expect(altRequest.kind).toBe('confident');
    if (altRequest.kind === 'confident') {
      expect(altRequest.track.title).toBe(altTitle);
      expect(altRequest.alternatives).toHaveLength(0);
    }
  });
});
