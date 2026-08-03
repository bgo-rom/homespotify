import { and, eq, sql } from 'drizzle-orm';
import type { Db } from '../db/client.js';
import { tracks } from '../db/schema.js';

export interface TrackMatchMetadata {
  title: string;
  artist: string;
  durationMs: number | null;
  isrc: string | null;
}

export type TrackMatch =
  | { kind: 'none'; trackId: null }
  | { kind: 'unique'; trackId: number }
  | { kind: 'ambiguous'; trackIds: number[] };

function normalize(value: string | null | undefined): string {
  return (value ?? '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .trim()
    .toLowerCase()
    .replace(/\s+/g, ' ');
}

/**
 * Point de vérité partagé pour la déduplication des imports locaux et distants.
 *
 * Priorité :
 * 1. SHA-256 exact ;
 * 2. ISRC unique ;
 * 3. titre + artiste + durée à ±5 secondes.
 *
 * Une ambiguïté n'est jamais résolue automatiquement.
 */
export function findExistingTrack(
  db: Db,
  sha256: string,
  metadata: TrackMatchMetadata,
): TrackMatch {
  const exact = db
    .select({ id: tracks.id })
    .from(tracks)
    .where(eq(tracks.hash, sha256))
    .get();
  if (exact) return { kind: 'unique', trackId: exact.id };

  if (metadata.isrc !== null) {
    const byIsrc = db
      .select({ id: tracks.id })
      .from(tracks)
      .where(eq(tracks.isrc, metadata.isrc))
      .limit(3)
      .all();
    if (byIsrc.length === 1) {
      return { kind: 'unique', trackId: byIsrc[0]!.id };
    }
    if (byIsrc.length > 1) {
      return { kind: 'ambiguous', trackIds: byIsrc.map((row) => row.id) };
    }
  }

  const byIdentity = db
    .select({ id: tracks.id, durationSeconds: tracks.durationSeconds })
    .from(tracks)
    .where(
      and(
        sql`lower(${tracks.title}) = ${normalize(metadata.title)}`,
        sql`lower(${tracks.artist}) = ${normalize(metadata.artist)}`,
      ),
    )
    .limit(10)
    .all()
    .filter((row) => {
      if (
        metadata.durationMs === null ||
        row.durationSeconds === null
      ) {
        return true;
      }
      return (
        Math.abs(row.durationSeconds * 1000 - metadata.durationMs) <= 5000
      );
    });

  if (byIdentity.length === 1) {
    return { kind: 'unique', trackId: byIdentity[0]!.id };
  }
  if (byIdentity.length > 1) {
    return {
      kind: 'ambiguous',
      trackIds: byIdentity.map((row) => row.id),
    };
  }
  return { kind: 'none', trackId: null };
}
