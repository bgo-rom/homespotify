import { describe, expect, it } from 'vitest';
import { MusicBrainzClient } from './musicbrainz-client.js';

describe('MusicBrainzClient', () => {
  it('sérialise les appels et respecte 1 requête/seconde', async () => {
    let currentTime = 10_000;
    const requestStarts: number[] = [];
    const client = new MusicBrainzClient({
      userAgent: 'HomeSpotifyTest/0.1 (test@example.local)',
      minIntervalMs: 1_000,
      now: () => currentTime,
      sleep: async (ms) => {
        currentTime += ms;
      },
      fetchImpl: async () => {
        requestStarts.push(currentTime);
        return new Response(JSON.stringify({ recordings: [] }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        });
      },
    });

    await Promise.all([
      client.searchRecordings({ title: 'A', artist: 'B' }),
      client.searchRecordings({ title: 'C', artist: 'D' }),
    ]);

    expect(requestStarts).toEqual([10_000, 11_000]);
  });

  it('normalise les résultats recording utiles', async () => {
    const client = new MusicBrainzClient({
      userAgent: 'HomeSpotifyTest/0.1 (test@example.local)',
      fetchImpl: async () => new Response(JSON.stringify({
        recordings: [{
          id: 'rec-1',
          title: 'Song',
          score: '99',
          length: 180000,
          'artist-credit': [{ name: 'Artist', artist: { id: 'artist-1', name: 'Artist' } }],
          releases: [{
            id: 'rel-1',
            title: 'Album',
            date: '2020-01-01',
            status: 'Official',
            'release-group': { id: 'rg-1', 'primary-type': 'Album' },
            media: [{ position: 1, tracks: [{ number: '2', position: 2 }] }],
          }],
          tags: [{ name: 'rock', count: 1 }],
        }],
      }), { status: 200, headers: { 'content-type': 'application/json' } }),
    });

    const results = await client.searchRecordings({ title: 'Song', artist: 'Artist', album: 'Album' });
    expect(results[0]).toMatchObject({
      id: 'rec-1',
      title: 'Song',
      score: 99,
      artistId: 'artist-1',
      artistCreditPhrase: 'Artist',
      tags: ['rock'],
    });
    expect(results[0].releases[0]).toMatchObject({
      id: 'rel-1',
      releaseGroupId: 'rg-1',
      trackNumber: 2,
      discNumber: 1,
    });
  });
});
