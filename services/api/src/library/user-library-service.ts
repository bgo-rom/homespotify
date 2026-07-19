import { and, eq, inArray, sql } from 'drizzle-orm';
import type { DbHandle } from '../db/client.js';
import {
  favorites,
  playlists,
  playlistTracks,
  tracks,
  userTracks,
  users,
  type UserTrackSource,
} from '../db/schema.js';

/**
 * Service central d'isolation par utilisateur : toute décision « ce compte
 * a-t-il accès à cette piste » et tout calcul de taille passe par ici. Aucune
 * route bibliothèque ne requête `tracks` sans joindre `user_tracks`.
 */

/** true si l'utilisateur a un accès VISIBLE à la piste. */
export function userCanAccessTrack(handle: DbHandle, userId: number, trackId: number): boolean {
  const row = handle.db
    .select({ trackId: userTracks.trackId })
    .from(userTracks)
    .where(
      and(
        eq(userTracks.userId, userId),
        eq(userTracks.trackId, trackId),
        eq(userTracks.isVisible, true),
      ),
    )
    .get();
  return row !== undefined;
}

/** Attribue une piste à un utilisateur (idempotent : ne recrée pas un accès existant). */
export function grantTrack(
  handle: DbHandle,
  input: { userId: number; trackId: number; source: UserTrackSource; addedByUserId?: number | null },
): { granted: boolean } {
  const result = handle.db
    .insert(userTracks)
    .values({
      userId: input.userId,
      trackId: input.trackId,
      addedAt: new Date().toISOString(),
      addedByUserId: input.addedByUserId ?? null,
      source: input.source,
      isVisible: true,
    })
    .onConflictDoNothing()
    .run();
  return { granted: result.changes > 0 };
}

/**
 * Retire l'accès d'un utilisateur à une piste. Ne supprime JAMAIS le fichier
 * physique ni la ligne `tracks` (bibliothèque partagée). Retire aussi la piste
 * des favoris et playlists de ce seul utilisateur pour rester cohérent.
 */
export function revokeTrack(
  handle: DbHandle,
  userId: number,
  trackId: number,
): { revoked: boolean } {
  return handle.db.transaction((tx) => {
    const result = tx
      .delete(userTracks)
      .where(and(eq(userTracks.userId, userId), eq(userTracks.trackId, trackId)))
      .run();
    if (result.changes === 0) return { revoked: false };

    tx.delete(favorites)
      .where(and(eq(favorites.userId, userId), eq(favorites.trackId, trackId)))
      .run();
    // Retirer la piste des playlists de CET utilisateur uniquement.
    const owned = tx
      .select({ id: playlists.id })
      .from(playlists)
      .where(eq(playlists.userId, userId))
      .all()
      .map((row) => row.id);
    if (owned.length > 0) {
      tx.delete(playlistTracks)
        .where(and(inArray(playlistTracks.playlistId, owned), eq(playlistTracks.trackId, trackId)))
        .run();
    }
    return { revoked: true };
  });
}

export interface UserLibrarySummary {
  trackCount: number;
  favoriteCount: number;
  playlistCount: number;
  /** Somme brute des tailles des pistes accessibles (un fichier partagé compté une fois par utilisateur). */
  logicalSizeBytes: number;
  /** Part au prorata du partage : somme de size/nbUtilisateurs — évite le double comptage global. */
  sharedSizeBytes: number;
  /** Taille des pistes accessibles UNIQUEMENT à cet utilisateur. */
  exclusiveSizeBytes: number;
}

/** Résumé de la bibliothèque d'un utilisateur (comptes + tailles logique/partagée/exclusive). */
export function summarizeUserLibrary(handle: DbHandle, userId: number): UserLibrarySummary {
  const { db } = handle;

  const counts = db
    .select({
      trackCount: sql<number>`count(*)`,
      logicalSizeBytes: sql<number>`coalesce(sum(${tracks.sizeBytes}), 0)`,
    })
    .from(userTracks)
    .innerJoin(tracks, eq(tracks.id, userTracks.trackId))
    .where(and(eq(userTracks.userId, userId), eq(userTracks.isVisible, true)))
    .get() ?? { trackCount: 0, logicalSizeBytes: 0 };

  // Nombre total d'utilisateurs ayant accès à chaque piste de cet utilisateur.
  const accessCounts = db
    .select({
      trackId: userTracks.trackId,
      sizeBytes: tracks.sizeBytes,
      sharers: sql<number>`(
        select count(*) from ${userTracks} ut2 where ut2.track_id = ${userTracks.trackId}
      )`,
    })
    .from(userTracks)
    .innerJoin(tracks, eq(tracks.id, userTracks.trackId))
    .where(and(eq(userTracks.userId, userId), eq(userTracks.isVisible, true)))
    .all();

  let sharedSizeBytes = 0;
  let exclusiveSizeBytes = 0;
  for (const row of accessCounts) {
    const sharers = row.sharers > 0 ? row.sharers : 1;
    sharedSizeBytes += row.sizeBytes / sharers;
    if (sharers === 1) exclusiveSizeBytes += row.sizeBytes;
  }

  const favoriteCount =
    db.select({ n: sql<number>`count(*)` }).from(favorites).where(eq(favorites.userId, userId)).get()
      ?.n ?? 0;
  const playlistCount =
    db.select({ n: sql<number>`count(*)` }).from(playlists).where(eq(playlists.userId, userId)).get()
      ?.n ?? 0;

  return {
    trackCount: counts.trackCount,
    favoriteCount,
    playlistCount,
    logicalSizeBytes: counts.logicalSizeBytes,
    sharedSizeBytes: Math.round(sharedSizeBytes),
    exclusiveSizeBytes,
  };
}

/**
 * Backfill OWNER : attribue au OWNER les pistes SANS AUCUN PROPRIÉTAIRE
 * (orphelines) — typiquement celles créées hors modèle multi-comptes par le
 * scan CLI, ou préexistantes. Idempotent et relançable à chaque démarrage.
 *
 * ⚠️ CORRECTION D'ISOLATION : la version précédente sélectionnait toute piste
 * « que le OWNER ne possède pas » (`NOT IN (… where user_id = owner)`). Comme
 * elle tournait à CHAQUE démarrage, elle avalait aussi les imports des AUTRES
 * comptes (qui ont bien un `user_tracks`, mais pas pour le OWNER) : la
 * bibliothèque personnelle du OWNER devenait de fait la bibliothèque globale.
 * On ne prend désormais QUE les pistes sans aucun `user_tracks` : une piste
 * détenue par un autre compte n'est JAMAIS attribuée au OWNER.
 *
 * Retourne le nombre de pistes nouvellement attribuées (0 si rien d'orphelin).
 */
export function backfillOwnerLibrary(handle: DbHandle): { assignedTracks: number } {
  const { db } = handle;

  const owner = db.select().from(users).where(eq(users.role, 'OWNER')).get();
  if (!owner) return { assignedTracks: 0 }; // pas encore de OWNER : rien à faire

  return db.transaction((tx) => {
    const now = new Date().toISOString();
    const orphanTrackIds = tx
      .select({ id: tracks.id })
      .from(tracks)
      .where(sql`${tracks.id} NOT IN (select ${userTracks.trackId} from ${userTracks})`)
      .all()
      .map((row) => row.id);

    for (const trackId of orphanTrackIds) {
      tx.insert(userTracks)
        .values({
          userId: owner.id,
          trackId,
          addedAt: now,
          addedByUserId: null,
          source: 'EXISTING',
          isVisible: true,
        })
        .onConflictDoNothing()
        .run();
    }

    return { assignedTracks: orphanTrackIds.length };
  });
}

/**
 * Répare la fuite historique du backfill : retire les accès du OWNER de source
 * `EXISTING` portant sur une piste réellement IMPORTÉE par un autre compte
 * (`MANUAL_IMPORT`). Ces lignes ne peuvent être que des artefacts du backfill —
 * le OWNER n'a jamais importé ces pistes.
 *
 * Préserve : les pistes historiques (aucun importateur identifié), tout accès
 * OWNER obtenu par import/attribution explicite, et les accès des autres
 * comptes. Ne touche JAMAIS aux fichiers ni à la table `tracks`. Idempotent.
 */
export function repairOwnerBackfillLeak(handle: DbHandle): { revokedTracks: number } {
  const { db } = handle;
  const owner = db.select().from(users).where(eq(users.role, 'OWNER')).get();
  if (!owner) return { revokedTracks: 0 };

  const leaked = db
    .select({ trackId: userTracks.trackId })
    .from(userTracks)
    .where(
      and(
        eq(userTracks.userId, owner.id),
        eq(userTracks.source, 'EXISTING'),
        sql`exists (
          select 1 from ${userTracks} other
          where other.track_id = ${userTracks.trackId}
            and other.user_id != ${owner.id}
            and other.source = 'MANUAL_IMPORT'
        )`,
      ),
    )
    .all()
    .map((row) => row.trackId);

  // revokeTrack retire aussi les favoris/playlists du OWNER pour cette piste :
  // cohérent, puisque cet accès n'aurait jamais dû exister.
  for (const trackId of leaked) revokeTrack(handle, owner.id, trackId);
  return { revokedTracks: leaked.length };
}
