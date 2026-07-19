import { and, desc, eq, sql } from 'drizzle-orm';
import type { DbHandle } from '../db/client.js';
import { trackQuality, tracks, userTracks } from '../db/schema.js';

/**
 * Catalogue GLOBAL, strictement ANONYME.
 *
 * Définition : une piste est PUBLIÉE au catalogue si elle est réellement
 * importée (ligne `tracks`) et encore détenue par AU MOINS UN compte
 * (≥ 1 `user_tracks` visible). Une piste orpheline — plus aucun propriétaire,
 * p. ex. retirée par tout le monde — n'est PAS publiée et reste inaccessible à
 * qui n'a pas d'accès personnel.
 *
 * VIE PRIVÉE — règle absolue : ce service ne retourne QUE des champs de piste.
 * Jamais d'identité (userId/username de l'importateur ou du demandeur), jamais
 * de chemin d'import, de dossier personnel ni de donnée d'audit. Le catalogue
 * ne permet donc pas de déduire qui a importé, demandé ou ajouté un morceau.
 *
 * Le catalogue est INDÉPENDANT de la bibliothèque personnelle : y figurer ne
 * crée aucun `user_tracks` (cf. `POST /api/library/tracks/:id`).
 */

export interface CatalogTrackQuality {
  container: string;
  codec: string;
  sampleRate: number;
  bitDepth: number;
  channels: number;
  status: string;
}

export interface CatalogTrack {
  id: number;
  title: string;
  artist: string;
  album: string;
  year: number | null;
  durationSeconds: number | null;
  hasCover: boolean;
  /** Date d'ajout AU CATALOGUE (import). N'identifie personne. */
  addedAt: string;
  /** true si la piste est déjà dans la bibliothèque personnelle du demandeur. */
  inMyLibrary: boolean;
  quality: CatalogTrackQuality | null;
}

export interface CatalogPage {
  page: number;
  limit: number;
  total: number;
  items: CatalogTrack[];
}

export const CATALOG_DEFAULT_LIMIT = 20;
export const CATALOG_MAX_LIMIT = 50;

/** Condition SQL « la piste est publiée au catalogue » (≥ 1 propriétaire visible). */
function publishedCondition() {
  return sql`exists (
    select 1 from ${userTracks} owner_ut
    where owner_ut.track_id = ${tracks.id} and owner_ut.is_visible = 1
  )`;
}

/** true si la piste est publiée au catalogue global. */
export function isTrackPublished(handle: DbHandle, trackId: number): boolean {
  if (!Number.isInteger(trackId)) return false;
  const row = handle.db
    .select({ trackId: userTracks.trackId })
    .from(userTracks)
    .where(and(eq(userTracks.trackId, trackId), eq(userTracks.isVisible, true)))
    .get();
  return row !== undefined;
}

/**
 * « Ajouts récents » du catalogue global : les plus récemment ajoutés d'abord.
 * `inMyLibrary` est calculé pour le compte appelant — c'est la SEULE donnée
 * dépendante de l'utilisateur, et elle ne concerne que lui-même.
 */
export function listRecentCatalog(
  handle: DbHandle,
  userId: number,
  options: { page?: number; limit?: number } = {},
): CatalogPage {
  const { db } = handle;
  const page = Math.max(1, options.page ?? 1);
  const limit = Math.min(CATALOG_MAX_LIMIT, Math.max(1, options.limit ?? CATALOG_DEFAULT_LIMIT));

  const rows = db
    .select({
      track: tracks,
      quality: trackQuality,
      mine: sql<number>`exists (
        select 1 from ${userTracks} mine_ut
        where mine_ut.track_id = ${tracks.id}
          and mine_ut.user_id = ${userId}
          and mine_ut.is_visible = 1
      )`,
    })
    .from(tracks)
    .leftJoin(trackQuality, eq(trackQuality.trackId, tracks.id))
    .where(publishedCondition())
    .orderBy(desc(tracks.createdAt), desc(tracks.id))
    .limit(limit)
    .offset((page - 1) * limit)
    .all();

  const total =
    db
      .select({ n: sql<number>`count(*)` })
      .from(tracks)
      .where(publishedCondition())
      .get()?.n ?? 0;

  const items: CatalogTrack[] = rows.map(({ track, quality, mine }) => ({
    id: track.id,
    title: track.title,
    artist: track.artist,
    album: track.album,
    year: track.year,
    durationSeconds: track.durationSeconds,
    hasCover: track.coverPath !== null,
    addedAt: track.createdAt,
    inMyLibrary: mine === 1,
    quality: quality && {
      container: quality.container,
      codec: quality.codec,
      sampleRate: quality.sampleRate,
      bitDepth: quality.bitDepth,
      channels: quality.channels,
      status: quality.status,
    },
  }));

  return { page, limit, total, items };
}
