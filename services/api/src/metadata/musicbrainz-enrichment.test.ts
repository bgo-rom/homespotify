import { describe, expect, it } from 'vitest';
import { chooseBestMusicBrainzMatch, type TrackForEnrichment } from './musicbrainz-enrichment.js';
import type { MusicBrainzRecordingCandidate } from './musicbrainz-client.js';

const track: TrackForEnrichment = {
  id: 7,
  title: 'The Song',
  artist: 'The Artist',
  album: 'The Album',
  durationSeconds: 180,
  year: 2020,
  genre: null,
};

function candidate(overrides: Partial<MusicBrainzRecordingCandidate> = {}): MusicBrainzRecordingCandidate {
  return {
    id: 'recording-1',
    title: 'The Song',
    score: 100,
    lengthMs: 180000,
    artistCreditPhrase: 'The Artist',
    artistId: 'artist-1',
    releases: [{
      id: 'release-1',
      title: 'The Album',
      date: '2020-01-01',
      status: 'Official',
      releaseGroupId: 'rg-1',
      releaseGroupPrimaryType: 'Album',
      artistCreditPhrase: 'The Artist',
      discNumber: 1,
      trackNumber: 3,
    }],
    tags: ['rock'],
    ...overrides,
  };
}

describe('chooseBestMusicBrainzMatch', () => {
  it('accepte un match net et conserve les IDs MusicBrainz', () => {
    const analysis = chooseBestMusicBrainzMatch(track, [candidate()]);
    expect(analysis.status).toBe('matched');
    expect(analysis.matchScore).toBeGreaterThanOrEqual(95);
    expect(analysis.matched).toMatchObject({
      musicbrainzRecordingId: 'recording-1',
      musicbrainzReleaseId: 'release-1',
      musicbrainzReleaseGroupId: 'rg-1',
      musicbrainzArtistId: 'artist-1',
      canonicalTitle: 'The Song',
      canonicalAlbum: 'The Album',
      trackNumber: 3,
      genre: 'rock',
    });
  });

  it('marque ambiguous quand deux candidats sont trop proches', () => {
    const analysis = chooseBestMusicBrainzMatch(track, [
      candidate({ id: 'recording-1' }),
      candidate({ id: 'recording-2', title: 'The Song', score: 99 }),
    ]);
    expect(analysis.status).toBe('ambiguous');
    expect(analysis.matched).toBeNull();
    expect(analysis.candidates).toHaveLength(2);
  });

  it('marque not_found sans candidat', () => {
    const analysis = chooseBestMusicBrainzMatch(track, []);
    expect(analysis.status).toBe('not_found');
    expect(analysis.matched).toBeNull();
  });

  it('refuse un candidat sous le seuil automatique', () => {
    const analysis = chooseBestMusicBrainzMatch(track, [
      candidate({
        title: 'Other Song',
        artistCreditPhrase: 'Other Artist',
        score: 45,
        lengthMs: 240000,
        releases: [],
      }),
    ]);
    expect(analysis.status).toBe('ambiguous');
    expect(analysis.matched).toBeNull();
    expect(analysis.errorMessage).toContain('seuil');
  });
});
