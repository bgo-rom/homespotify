import { fileURLToPath } from 'node:url';
import { migrate } from 'drizzle-orm/better-sqlite3/migrator';
import { sql } from 'drizzle-orm';
import { appMeta } from './schema.js';
import type { DbHandle } from './client.js';

const migrationsFolder = fileURLToPath(new URL('../../drizzle', import.meta.url));

export function runMigrations(handle: DbHandle): void {
  migrate(handle.db, { migrationsFolder });
  const now = new Date().toISOString();
  handle.db
    .insert(appMeta)
    .values({ key: 'initialized_at', value: now, updatedAt: now })
    .onConflictDoNothing()
    .run();
}

export function isDbInitialized(handle: DbHandle): boolean {
  try {
    const rows = handle.db
      .select({ ok: sql<number>`1` })
      .from(appMeta)
      .limit(1)
      .all();
    return rows.length >= 0; // la table existe : requête réussie
  } catch {
    return false;
  }
}
