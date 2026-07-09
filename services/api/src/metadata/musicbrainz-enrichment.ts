import { eq } from 'drizzle-orm';
import type { Db } from '../db/client.js';
import { trackEnrichment } from '../db/schema.js';
import type { MusicBrainzClient, MusicBrainzRecordingCandidate, MusicBrainzReleaseCandidate } from './musicbrainz-client.js';

export type EnrichmentStatus = 'pending' | 'matched' | 'ambiguous' | 'not_found' | 'failed';

export interface TrackForEnrichment {
  id: number;
  title: string;
  artist: string;
  album: string;
  durationSeconds: number | null;
  year: number | null;
  genre: string | null;
}

export interface EnrichmentOptions {
  minScore?: number;
  ambiguityDelta?: number;
}

export interface MatchedMusicBrainzData {
  musicbrainzRecordingId: string;
  musicbrainzReleaseId: string | null;
  musicbrainzReleaseGroupId: string | null;
  musicbrainzArtistId: string | null;
  canonicalTitle: string;
  canonicalArtist: string | null;
  canonicalAlbum: string | null;
  albumArtist: string | null;
  releaseDate: string | null;
  trackNumber: number | null;
  discNumber: number | null;
  genre: string | null;
}

export interface EnrichmentAnalysis {
  trackId: number;
  status: EnrichmentStatus;
  matchScore: number | null;
  matched: MatchedMusicBrainzData | null;
  candidates: CandidateSummary[];
  errorMessage: string | null;
  checkedAt: string;
  enrichedAt: string | null;
}

export interface CandidateSummary {
  recordingId: string;
  title: string;
  artist: string | null;
  score: number;
  musicBrainzScore: number;
  durationDeltaSeconds: number | null;
  release: {
    id: string;
    title: string;
    date: string | null;
    status: string | null;
    trackNumber: number | null;
    discNumber: number | null;
  } | null;
}

interface ScoredCandidate {
  candidate: MusicBrainzRecordingCandidate;
  release: MusicBrainzReleaseCandidate | null;
  score: number;
  durationDeltaSeconds: number | null;
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

function normalizeText(value: string | null | undefined): string {
  return (value ?? '')
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/gu, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/gu, ' ')
    .trim();
}

function textSimilarity(a: string | null | undefined, b: string | null | undefined): number {
  const left = normalizeText(a);
  const right = normalizeText(b);
  if (!left || !right) return 0;
  if (left === right) return 1;
  if (left.includes(right) || right.includes(left)) return 0.9;

  const leftTokens = new Set(left.split(' ').filter(Boolean));
  const rightTokens = new Set(right.split(' ').filter(Boolean));
  if (leftTokens.size === 0 || rightTokens.size === 0) return 0;
  let intersection = 0;
  for (const token of leftTokens) {
    if (rightTokens.has(token)) intersection += 1;
  }
  return (2 * intersection) / (leftTokens.size + rightTokens.size);
}

function durationSimilarity(trackSeconds: number | null, candidateMs: number | null): {
  similarity: number;
  deltaSeconds: number | null;
} {
  if (!trackSeconds || !candidateMs) return { similarity: 0.5, deltaSeconds: null };
  const delta = Math.abs(trackSeconds - candidateMs / 1000);
  if (delta <= 2) return { similarity: 1, deltaSeconds: delta };
  if (delta <= 5) return { similarity: 0.85, deltaSeconds: delta };
  if (delta <= 15) return { similarity: 0.5, deltaSeconds: delta };
  return { similarity: clamp(1 - delta / 60, 0, 0.3), deltaSeconds: delta };
}

function scoreRelease(track: TrackForEnrichment, release: MusicBrainzReleaseCandidate): number {
  const albumScore = textSimilarity(track.album, release.title) * 0.75;
  const officialBonus = release.status === 'Official' ? 0.15 : 0;
  const dateBonus = track.year && release.date?.startsWith(String(track.year)) ? 0.1 : 0;
  return clamp(albumScore + officialBonus + dateBonus, 0, 1);
}

function bestRelease(track: TrackForEnrichment, candidate: MusicBrainzRecordingCandidate): MusicBrainzReleaseCandidate | null {
  if (candidate.releases.length === 0) return null;
  return [...candidate.releases].sort((a, b) => scoreRelease(track, b) - scoreRelease(track, a))[0] ?? null;
}

function scoreCandidate(track: TrackForEnrichment, candidate: MusicBrainzRecordingCandidate): ScoredCandidate {
  const release = bestRelease(track, candidate);
  const duration = durationSimilarity(track.durationSeconds, candidate.lengthMs);
  const score =
    clamp(candidate.score, 0, 100) * 0.35 +
    textSimilarity(track.title, candidate.title) * 25 +
    textSimilarity(track.artist, candidate.artistCreditPhrase) * 20 +
    (release ? scoreRelease(track, release) : 0.4) * 12 +
    duration.similarity * 8;

  return {
    candidate,
    release,
    score: Math.round(clamp(score, 0, 100) * 10) / 10,
    durationDeltaSeconds: duration.deltaSeconds === null ? null : Math.round(duration.deltaSeconds * 10) / 10,
  };
}

function summarize(scored: ScoredCandidate): CandidateSummary {
  return {
    recordingId: scored.candidate.id,
    title: scored.candidate.title,
    artist: scored.candidate.artistCreditPhrase,
    score: scored.score,
    musicBrainzScore: scored.candidate.score,
    durationDeltaSeconds: scored.durationDeltaSeconds,
    release: scored.release && {
      id: scored.release.id,
      title: scored.release.title,
      date: scored.release.date,
      status: scored.release.status,
      trackNumber: scored.release.trackNumber,
      discNumber: scored.release.discNumber,
    },
  };
}

function matchedData(scored: ScoredCandidate): MatchedMusicBrainzData {
  const { candidate, release } = scored;
  return {
    musicbrainzRecordingId: candidate.id,
    musicbrainzReleaseId: release?.id ?? null,
    musicbrainzReleaseGroupId: release?.releaseGroupId ?? null,
    musicbrainzArtistId: candidate.artistId,
    canonicalTitle: candidate.title,
    canonicalArtist: candidate.artistCreditPhrase,
    canonicalAlbum: release?.title ?? null,
    albumArtist: release?.artistCreditPhrase ?? candidate.artistCreditPhrase,
    releaseDate: release?.date ?? null,
    trackNumber: release?.trackNumber ?? null,
    discNumber: release?.discNumber ?? null,
    genre: candidate.tags[0] ?? null,
  };
}

export function chooseBestMusicBrainzMatch(
  track: TrackForEnrichment,
  candidates: MusicBrainzRecordingCandidate[],
  options: EnrichmentOptions = {},
): EnrichmentAnalysis {
  const checkedAt = new Date().toISOString();
  const minScore = options.minScore ?? 82;
  const ambiguityDelta = options.ambiguityDelta ?? 5;
  const scored = candidates
    .map((candidate) => scoreCandidate(track, candidate))
    .sort((a, b) => b.score - a.score);
  const [best, second] = scored;

  if (!best) {
    return {
      trackId: track.id,
      status: 'not_found',
      matchScore: null,
      matched: null,
      candidates: [],
      errorMessage: null,
      checkedAt,
      enrichedAt: null,
    };
  }

  const summaries = scored.slice(0, 5).map(summarize);
  if (best.score < minScore) {
    return {
      trackId: track.id,
      status: 'ambiguous',
      matchScore: best.score,
      matched: null,
      candidates: summaries,
      errorMessage: `Meilleur score ${best.score} < seuil ${minScore}`,
      checkedAt,
      enrichedAt: null,
    };
  }

  if (second && best.score - second.score <= ambiguityDelta) {
    return {
      trackId: track.id,
      status: 'ambiguous',
      matchScore: best.score,
      matched: null,
      candidates: summaries,
      errorMessage: `Candidats trop proches (${best.score} vs ${second.score})`,
      checkedAt,
      enrichedAt: null,
    };
  }

  return {
    trackId: track.id,
    status: 'matched',
    matchScore: best.score,
    matched: matchedData(best),
    candidates: summaries,
    errorMessage: null,
    checkedAt,
    enrichedAt: checkedAt,
  };
}

function rowFromAnalysis(analysis: EnrichmentAnalysis) {
  return {
    trackId: analysis.trackId,
    status: analysis.status,
    musicbrainzRecordingId: analysis.matched?.musicbrainzRecordingId ?? null,
    musicbrainzReleaseId: analysis.matched?.musicbrainzReleaseId ?? null,
    musicbrainzReleaseGroupId: analysis.matched?.musicbrainzReleaseGroupId ?? null,
    musicbrainzArtistId: analysis.matched?.musicbrainzArtistId ?? null,
    canonicalTitle: analysis.matched?.canonicalTitle ?? null,
    canonicalArtist: analysis.matched?.canonicalArtist ?? null,
    canonicalAlbum: analysis.matched?.canonicalAlbum ?? null,
    albumArtist: analysis.matched?.albumArtist ?? null,
    releaseDate: analysis.matched?.releaseDate ?? null,
    trackNumber: analysis.matched?.trackNumber ?? null,
    discNumber: analysis.matched?.discNumber ?? null,
    genre: analysis.matched?.genre ?? null,
    matchScore: analysis.matchScore,
    candidatesJson: analysis.candidates.length > 0 ? JSON.stringify(analysis.candidates) : null,
    errorMessage: analysis.errorMessage,
    checkedAt: analysis.checkedAt,
    enrichedAt: analysis.enrichedAt,
  };
}

export function storeEnrichmentAnalysis(db: Db, analysis: EnrichmentAnalysis): void {
  const row = rowFromAnalysis(analysis);
  db.insert(trackEnrichment)
    .values(row)
    .onConflictDoUpdate({
      target: trackEnrichment.trackId,
      set: row,
    })
    .run();
}

export function storeFailedEnrichment(db: Db, trackId: number, error: unknown): EnrichmentAnalysis {
  const checkedAt = new Date().toISOString();
  const message = error instanceof Error ? error.message : String(error);
  const analysis: EnrichmentAnalysis = {
    trackId,
    status: 'failed',
    matchScore: null,
    matched: null,
    candidates: [],
    errorMessage: message.slice(0, 500),
    checkedAt,
    enrichedAt: null,
  };
  storeEnrichmentAnalysis(db, analysis);
  return analysis;
}

export async function analyzeTrackWithMusicBrainz(
  client: MusicBrainzClient,
  track: TrackForEnrichment,
  options: EnrichmentOptions = {},
): Promise<EnrichmentAnalysis> {
  const candidates = await client.searchRecordings({
    title: track.title,
    artist: track.artist,
    album: track.album,
    limit: 5,
  });
  return chooseBestMusicBrainzMatch(track, candidates, options);
}

export async function enrichTrackWithMusicBrainz(
  db: Db,
  client: MusicBrainzClient,
  track: TrackForEnrichment,
  options: EnrichmentOptions = {},
): Promise<EnrichmentAnalysis> {
  try {
    const analysis = await analyzeTrackWithMusicBrainz(client, track, options);
    storeEnrichmentAnalysis(db, analysis);
    return analysis;
  } catch (error) {
    return storeFailedEnrichment(db, track.id, error);
  }
}

export function hasExistingEnrichment(db: Db, trackId: number): boolean {
  return db
    .select({ trackId: trackEnrichment.trackId })
    .from(trackEnrichment)
    .where(eq(trackEnrichment.trackId, trackId))
    .get() !== undefined;
}
