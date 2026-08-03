import { tracks } from '../../db/schema.js';
import type { DbHandle } from '../../db/client.js';
import { toPortableRelativePath } from '../audio-storage.js';
import { sha256Hex } from './hmac-client.js';

export interface RemoteStorageIndexDocument {
  body: Buffer;
  contentSha256: string;
  entryCount: number;
  generatedAt: string;
  omittedTrackIds: number[];
}

/**
 * Construit l'index complet destiné au Storage Agent à partir du snapshot
 * SQLite courant. Aucun fichier audio n'est ouvert sur le VPS.
 *
 * Les chemins invalides sont exclus et leurs seuls identifiants sont remontés
 * au logger. Le document ne contient jamais de chemin absolu.
 */
export function buildRemoteStorageIndexDocument(
  handle: DbHandle,
  now: () => Date = () => new Date(),
): RemoteStorageIndexDocument {
  const rows = handle.db
    .select({ id: tracks.id, path: tracks.path })
    .from(tracks)
    .orderBy(tracks.id)
    .all();

  const entries: Record<string, { relativePath: string }> = {};
  const omittedTrackIds: number[] = [];
  for (const row of rows) {
    try {
      entries[String(row.id)] = {
        relativePath: toPortableRelativePath(row.path),
      };
    } catch {
      omittedTrackIds.push(row.id);
    }
  }

  const generatedAt = now().toISOString();
  const body = Buffer.from(
    `${JSON.stringify(
      {
        version: 1,
        generatedAt,
        entries,
      },
      null,
      2,
    )}\n`,
    'utf8',
  );

  return {
    body,
    contentSha256: sha256Hex(body),
    entryCount: Object.keys(entries).length,
    generatedAt,
    omittedTrackIds,
  };
}
