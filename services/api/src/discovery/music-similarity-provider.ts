import type {
  LastfmClient,
  LastfmSimilarArtist,
  LastfmSimilarTrack,
  LastfmTopTrack,
} from '../metadata/lastfm-client.js';

/**
 * Graphe de similarité musicale RÉEL — abstraction consommée par le moteur.
 *
 * Règle absolue (cf. TECH_DECISIONS) : un candidat n'existe que s'il porte au
 * moins UNE relation directe forte (voisin de morceau) OU PLUSIEURS relations
 * moyennes indépendantes (artiste voisin de plusieurs seeds). Un tag
 * générique n'est JAMAIS une relation.
 */

export interface SimilarityEvidence {
  /** TRACK_SIMILAR : voisin direct d'un morceau seed (fort). ARTIST_SIMILAR : artiste voisin (moyen). */
  type: 'TRACK_SIMILAR' | 'ARTIST_SIMILAR';
  /** Seed lisible : « All Black — Ajna » ou « Ajna ». */
  seed: string;
  /** Artiste de la seed (indépendance des preuves = artistes seeds distincts). */
  seedArtist: string;
  /** Force 0..1 fournie par le provider. */
  match: number;
}

export interface SimilarTrackNeighbor {
  title: string;
  artist: string;
  durationMs: number | null;
  externalUrl: string | null;
  match: number;
}

export interface SimilarArtistNeighbor {
  name: string;
  match: number;
  externalUrl: string | null;
}

export interface TopTrackOfArtist {
  title: string;
  artist: string;
  externalUrl: string | null;
}

export interface MusicSimilarityProvider {
  readonly id: string;
  /** Voisins DIRECTS d'un morceau (relation forte). */
  similarTracks(seed: { title: string; artist: string }): Promise<SimilarTrackNeighbor[]>;
  /** Artistes voisins d'un artiste (relation moyenne). */
  similarArtists(seedArtist: string): Promise<SimilarArtistNeighbor[]>;
  /** Morceaux représentatifs d'un artiste voisin (matérialisation). */
  topTracksOf(artist: string): Promise<TopTrackOfArtist[]>;
}

/** Implémentation Last.fm (provider primaire). */
export class LastfmMusicSimilarityProvider implements MusicSimilarityProvider {
  readonly id = 'LASTFM';

  constructor(private readonly client: LastfmClient) {}

  async similarTracks(seed: { title: string; artist: string }): Promise<SimilarTrackNeighbor[]> {
    const tracks: LastfmSimilarTrack[] = await this.client.getSimilarTracks(
      seed.artist,
      seed.title,
    );
    return tracks.map((track) => ({
      title: track.title,
      artist: track.artist,
      durationMs: track.durationMs,
      externalUrl: track.externalUrl,
      match: track.match,
    }));
  }

  async similarArtists(seedArtist: string): Promise<SimilarArtistNeighbor[]> {
    const artists: LastfmSimilarArtist[] = await this.client.getSimilarArtists(seedArtist);
    return artists.map((artist) => ({
      name: artist.name,
      match: artist.match,
      externalUrl: artist.externalUrl,
    }));
  }

  async topTracksOf(artist: string): Promise<TopTrackOfArtist[]> {
    const tracks: LastfmTopTrack[] = await this.client.getArtistTopTracks(artist);
    return tracks.map((track) => ({
      title: track.title,
      artist: track.artist,
      externalUrl: track.externalUrl,
    }));
  }
}

// --- Règle d'acceptation des preuves --------------------------------------

/** Seuil de relation FORTE pour un voisin direct de morceau. */
export const STRONG_TRACK_MATCH = 0.25;
/** Seuil de relation FORTE pour un artiste voisin très proche. */
export const STRONG_ARTIST_MATCH = 0.7;
/** Seuil minimal d'une relation MOYENNE exploitable. */
export const MEDIUM_MATCH = 0.15;

export function isStrongEvidence(evidence: SimilarityEvidence): boolean {
  if (evidence.type === 'TRACK_SIMILAR') return evidence.match >= STRONG_TRACK_MATCH;
  return evidence.match >= STRONG_ARTIST_MATCH;
}

/**
 * Un candidat est admissible si :
 *  - au moins une preuve FORTE (voisin direct de morceau, ou artiste
 *    quasi-identique), OU
 *  - au moins deux preuves MOYENNES issues de seeds d'ARTISTES DIFFÉRENTS
 *    (indépendance).
 */
export function hasSufficientEvidence(evidences: SimilarityEvidence[]): boolean {
  if (evidences.some(isStrongEvidence)) return true;
  const mediumSeedArtists = new Set(
    evidences
      .filter((evidence) => evidence.match >= MEDIUM_MATCH)
      .map((evidence) => evidence.seedArtist.trim().toLowerCase()),
  );
  return mediumSeedArtists.size >= 2;
}
