/**
 * Filtres qualité ABSOLUS du feed Découvrir. Un candidat rejeté ici n'est ni
 * inséré ni servi, quel que soit son score.
 */

const BANNED_ARTIST_PATTERNS: RegExp[] = [
  /^various(\s+artists?)?$/iu,
  /^va$/iu,
  /^\[?unknown\]?(\s+artist)?$/iu,
  /^artiste\s+inconnu$/iu,
  /^divers$/iu,
  /^\[?untitled\]?$/iu,
  /^compilation$/iu,
  /^soundtrack$/iu,
  /^original\s+soundtrack$/iu,
];

/** Titres qui trahissent une compilation/DJ-mix, pas un morceau. */
const BANNED_TITLE_PATTERNS: RegExp[] = [
  /continuous\s+(dj[\s-]*)?mix/iu,
  /^\[?untitled\]?$/iu,
  /\bmegamix\b/iu,
  /\bdj[\s-]?mix\b/iu,
];

export interface CandidateQualityInput {
  title: string;
  artist: string;
  itemType?: string;
}

export type QualityRejection =
  | 'empty_title'
  | 'empty_artist'
  | 'banned_artist'
  | 'banned_title'
  | 'not_a_track';

/** null = accepté ; sinon la raison stable du rejet (diagnostics OWNER). */
export function rejectCandidateQuality(input: CandidateQualityInput): QualityRejection | null {
  const title = input.title.trim();
  const artist = input.artist.trim();
  if (title.length === 0) return 'empty_title';
  if (artist.length === 0) return 'empty_artist';
  // Le feed swipe ne sert que des MORCEAUX : un album sans artiste de piste
  // (compilation) ou tout autre type est rejeté.
  if (input.itemType !== undefined && input.itemType !== 'TRACK') return 'not_a_track';
  if (BANNED_ARTIST_PATTERNS.some((pattern) => pattern.test(artist))) return 'banned_artist';
  if (BANNED_TITLE_PATTERNS.some((pattern) => pattern.test(title))) return 'banned_title';
  return null;
}
