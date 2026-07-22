/**
 * Cache normalisé de la découverte (table discovery_cache). Ne stocke QUE le
 * JSON normalisé du modèle unifié — jamais la réponse brute d'un fournisseur,
 * jamais de secret, jamais d'audio, jamais d'URL de preview (TTL preview = 0).
 */

import { createHash } from 'node:crypto';
import { and, eq, lt, sql } from 'drizzle-orm';
import type { DbHandle } from '../../db/client.js';
import { discoveryCache } from '../../db/schema.js';

// V3 invalide aussi les pages où durée/explicit créaient plusieurs cartes
// pour une même identité visible.
export const DISCOVERY_CACHE_SCHEMA_VERSION = 3;

/** TTL par opération (ms). Les métadonnées canoniques vivent longtemps, les
 * recherches quelques heures, les erreurs temporaires quelques dizaines de
 * secondes (Phase 7). Les pages contenant une preview appliquent en plus le
 * TTL court calculé par DiscoveryCatalogService. */
export const DISCOVERY_CACHE_TTLS_MS: Record<string, number> = {
  search: 4 * 60 * 60 * 1000,
  isrc: 7 * 24 * 60 * 60 * 1000,
  artist: 3 * 24 * 60 * 60 * 1000,
  artist_albums: 3 * 24 * 60 * 60 * 1000,
  album: 3 * 24 * 60 * 60 * 1000,
  playlist: 30 * 60 * 1000,
  negative: 45 * 1000,
};

const MAX_PAYLOAD_BYTES = 500_000;

export interface DiscoveryCacheOptions {
  maxEntries?: number;
  now?: () => number;
}

export class DiscoveryCache {
  private readonly maxEntries: number;
  private readonly now: () => number;

  constructor(
    private readonly handle: DbHandle,
    options: DiscoveryCacheOptions = {},
  ) {
    this.maxEntries = options.maxEntries ?? 5_000;
    this.now = options.now ?? Date.now;
  }

  /** Hash stable des paramètres (jamais la requête en clair dans la clé). */
  static hashQuery(parts: Record<string, unknown>): string {
    const canonical = JSON.stringify(
      Object.keys(parts)
        .sort()
        .map((key) => [key, parts[key]]),
    );
    return createHash('sha256').update(canonical).digest('hex');
  }

  get<T>(key: {
    provider: string;
    operation: string;
    queryHash: string;
    market: string;
  }): { value: T | null; negative: boolean } | null {
    const row = this.handle.db
      .select()
      .from(discoveryCache)
      .where(
        and(
          eq(discoveryCache.provider, key.provider),
          eq(discoveryCache.operation, key.operation),
          eq(discoveryCache.queryHash, key.queryHash),
          eq(discoveryCache.market, key.market),
        ),
      )
      .get();
    if (!row) return null;
    if (new Date(row.expiresAt).getTime() <= this.now()) return null;
    if (row.schemaVersion !== DISCOVERY_CACHE_SCHEMA_VERSION) return null;
    if (row.negativeResult) return { value: null, negative: true };
    try {
      return { value: JSON.parse(row.normalizedJson) as T, negative: false };
    } catch {
      return null;
    }
  }

  set(
    key: { provider: string; operation: string; queryHash: string; market: string },
    value: unknown,
    options: { entityType?: string | null; statusCode?: number | null; negative?: boolean; ttlMs?: number } = {},
  ): void {
    const negative = options.negative ?? false;
    const ttlMs =
      options.ttlMs ??
      (negative
        ? DISCOVERY_CACHE_TTLS_MS['negative']!
        : DISCOVERY_CACHE_TTLS_MS[key.operation] ?? DISCOVERY_CACHE_TTLS_MS['search']!);
    const normalizedJson = negative ? 'null' : JSON.stringify(value ?? null);
    if (normalizedJson.length > MAX_PAYLOAD_BYTES) return; // jamais de payload géant
    const nowIso = new Date(this.now()).toISOString();
    const expiresAt = new Date(this.now() + ttlMs).toISOString();
    this.handle.db
      .insert(discoveryCache)
      .values({
        provider: key.provider,
        operation: key.operation,
        queryHash: key.queryHash,
        market: key.market,
        entityType: options.entityType ?? null,
        locale: null,
        normalizedJson,
        fetchedAt: nowIso,
        expiresAt,
        schemaVersion: DISCOVERY_CACHE_SCHEMA_VERSION,
        statusCode: options.statusCode ?? null,
        negativeResult: negative,
      })
      .onConflictDoUpdate({
        target: [
          discoveryCache.provider,
          discoveryCache.operation,
          discoveryCache.queryHash,
          discoveryCache.market,
        ],
        set: {
          normalizedJson,
          fetchedAt: nowIso,
          expiresAt,
          schemaVersion: DISCOVERY_CACHE_SCHEMA_VERSION,
          statusCode: options.statusCode ?? null,
          negativeResult: negative,
          entityType: options.entityType ?? null,
        },
      })
      .run();
    this.pruneIfNeeded();
  }

  /** Purge périodique : entrées expirées, puis bornage du volume total. */
  pruneIfNeeded(): void {
    const nowIso = new Date(this.now()).toISOString();
    this.handle.db.delete(discoveryCache).where(lt(discoveryCache.expiresAt, nowIso)).run();
    const total =
      this.handle.db.select({ n: sql<number>`count(*)` }).from(discoveryCache).get()?.n ?? 0;
    if (total > this.maxEntries) {
      // Supprime les plus anciennes entrées au-delà de la limite.
      this.handle.sqlite
        .prepare(
          'DELETE FROM discovery_cache WHERE id IN (SELECT id FROM discovery_cache ORDER BY fetched_at ASC LIMIT ?)',
        )
        .run(total - this.maxEntries);
    }
  }

  stats(): { entries: number; negativeEntries: number } {
    const entries =
      this.handle.db.select({ n: sql<number>`count(*)` }).from(discoveryCache).get()?.n ?? 0;
    const negativeEntries =
      this.handle.db
        .select({ n: sql<number>`count(*)` })
        .from(discoveryCache)
        .where(eq(discoveryCache.negativeResult, true))
        .get()?.n ?? 0;
    return { entries, negativeEntries };
  }
}
