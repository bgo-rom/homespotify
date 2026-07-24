import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { eq } from 'drizzle-orm';
import { buildApp } from '../app.js';
import type { AppConfig } from '../config.js';
import { createDb, type DbHandle } from './client.js';
import {
  ensureDiscoverV3Columns,
  ensureLoudnessAnalysisSchema,
  ensureOfflineVariantsSchema,
  ensurePlaybackSettingsAndAnalysisSchema,
  runMigrations,
} from './migrate.js';
import { classifyRefreshError } from '../discovery/recommendation-engine.js';
import {
  recommendationCandidates,
  recommendationEvents,
  tracks,
  userRecommendationQueue,
  users,
} from './schema.js';

/**
 * Ces tests reproduisent la panne réelle : la migration 0012 (colonnes V3
 * `category` / `served_at` / `evidence_json`) a un `when` de journal ANTÉRIEUR
 * à 0011 (timestamp fabriqué), donc le migrateur drizzle la saute sur toute
 * base déjà à l'état 0011. On vérifie que la réparation (ensureDiscoverV3Columns
 * + 0013) répare une base cassée SANS perte de données, et reste sûre sur une
 * base neuve.
 */

let base: string;
let dbFile: string;

const silentLog = { info: () => {}, error: () => {} };

function makeConfig(): AppConfig {
  return {
    nodeEnv: 'test',
    host: '127.0.0.1',
    port: 0,
    dbPath: dbFile,
    logLevel: 'error',
    musicDir: join(base, 'music'),
    incomingDir: join(base, 'imports'),
    importRoot: join(base, 'imports'),
    coversDir: join(base, 'covers'),
    maxUploadBytes: 200 * 1024 * 1024,
    // Secret FIXE : un token émis par la première instance reste valable dans
    // la seconde (sinon secret aléatoire par processus).
    authTokenSecret: 'test-secret-0123456789abcdef0123456789abcdef',
    accessTokenTtlSeconds: 900,
    refreshTokenTtlSeconds: 30 * 24 * 60 * 60,
  };
}

/** Colonnes V3 réellement présentes dans la base. */
function v3Columns(handle: DbHandle): { queue: string[]; candidates: string[] } {
  const cols = (t: string) =>
    (handle.sqlite.prepare(`PRAGMA table_info(${t})`).all() as Array<{ name: string }>).map(
      (c) => c.name,
    );
  return {
    queue: cols('user_recommendation_queue').filter((c) => c === 'category' || c === 'served_at'),
    candidates: cols('recommendation_candidates').filter((c) => c === 'evidence_json'),
  };
}

function playbackAndAnalysisObjects(handle: DbHandle): string[] {
  return (
    handle.sqlite
      .prepare(
        `SELECT name FROM sqlite_master
         WHERE name IN (
           'user_track_playback_settings',
           'user_track_playback_settings_user_track_unique',
           'track_audio_analysis'
         )
         ORDER BY name`,
      )
      .all() as Array<{ name: string }>
  ).map((row) => row.name);
}

/**
 * Ramène une base au schéma pré-V3 « bloqué à 0011 » : supprime les 3 colonnes
 * V3 et l'index dépendant, puis rembobine `__drizzle_migrations` pour que le
 * `created_at` max soit celui de 0011 (0012/0013 non enregistrées).
 */
function breakToPreV3(handle: DbHandle): void {
  const sqlite = handle.sqlite;
  sqlite.exec('DROP INDEX IF EXISTS `user_recommendation_queue_served_idx`');
  // DROP COLUMN nécessite que la colonne ne soit dans aucun index (fait ci-dessus).
  sqlite.exec('ALTER TABLE `user_recommendation_queue` DROP COLUMN `served_at`');
  sqlite.exec('ALTER TABLE `user_recommendation_queue` DROP COLUMN `category`');
  sqlite.exec('ALTER TABLE `recommendation_candidates` DROP COLUMN `evidence_json`');
  // Rembobine le journal des migrations à l'état 0011 (when = 1783944000000) :
  // supprime toute migration enregistrée avec un created_at >= celui de 0012.
  sqlite.prepare('DELETE FROM __drizzle_migrations WHERE created_at >= ?').run(1783865256480);
  // Garantit qu'au moins la « dernière appliquée » = 0011.
  const max = (
    sqlite.prepare('SELECT max(created_at) AS m FROM __drizzle_migrations').get() as { m: number | null }
  ).m;
  if (max === null || max < 1783944000000) {
    sqlite
      .prepare('INSERT INTO __drizzle_migrations (hash, created_at) VALUES (?, ?)')
      .run('legacy-0011', 1783944000000);
  }
}

beforeEach(() => {
  base = mkdtempSync(join(tmpdir(), 'homespotify-migrate-'));
  dbFile = join(base, 'homespotify.db');
});

afterEach(() => {
  rmSync(base, { recursive: true, force: true });
});

describe('réparation du schéma V3 (migration 0013 + ensureDiscoverV3Columns)', () => {
  it('sur une base NEUVE : toutes les colonnes V3 existent, aucune erreur', () => {
    const handle = createDb(dbFile);
    runMigrations(handle, silentLog);
    expect(v3Columns(handle)).toEqual({ queue: ['category', 'served_at'], candidates: ['evidence_json'] });
    // Idempotent : relancer ne casse rien et n'ajoute rien.
    const again = ensureDiscoverV3Columns(handle, silentLog);
    expect(again).toEqual([]);
    handle.sqlite.close();
  });

  it('sur une base bloquée à 0011 : répare les 3 colonnes SANS perdre les données', () => {
    // 1. Base saine complète.
    const seed = createDb(dbFile);
    runMigrations(seed, silentLog);
    const now = new Date().toISOString();
    seed.db.insert(users).values({
      username: 'owner', displayName: 'Owner', passwordHash: 'x', role: 'OWNER',
      isActive: true, mustChangePassword: false, createdAt: now, updatedAt: now,
    }).run();
    const ownerId = (seed.db.select({ id: users.id }).from(users).get())!.id;
    seed.db.insert(tracks).values({
      hash: 'h1', path: 'a.wav', sizeBytes: 1000, title: 'Legacy', artist: 'Ajna', album: 'Antidote', createdAt: now,
    }).run();
    const candidate = seed.db.insert(recommendationCandidates).values({
      itemType: 'TRACK', title: 'All Black', artist: 'Ajna', source: 'MANUAL', isActive: true,
      createdAt: now, updatedAt: now,
    }).returning({ id: recommendationCandidates.id }).get();
    seed.db.insert(recommendationEvents).values({
      userId: ownerId, candidateId: candidate.id, action: 'LIKE', createdAt: now,
    }).run();
    // 2. Casse le schéma pour reproduire la panne réelle.
    breakToPreV3(seed);
    expect(v3Columns(seed)).toEqual({ queue: [], candidates: [] });
    seed.sqlite.close();

    // 3. Réparation via runMigrations (comme au boot du serveur).
    const repaired = createDb(dbFile);
    runMigrations(repaired, silentLog);

    // 4. Colonnes V3 rétablies…
    expect(v3Columns(repaired)).toEqual({
      queue: ['category', 'served_at'],
      candidates: ['evidence_json'],
    });
    // …index recréé (0013)…
    const idx = repaired.sqlite
      .prepare(`SELECT name FROM sqlite_master WHERE type='index' AND name = ?`)
      .get('user_recommendation_queue_served_idx');
    expect(idx).toBeDefined();
    // …et DONNÉES intactes (users, tracks, candidats, historique d'événements).
    expect(repaired.db.select().from(users).all()).toHaveLength(1);
    expect(repaired.db.select().from(tracks).all()).toHaveLength(1);
    expect(
      repaired.db.select().from(recommendationCandidates).where(eq(recommendationCandidates.id, candidate.id)).get(),
    ).toBeDefined();
    expect(repaired.db.select().from(recommendationEvents).all()).toHaveLength(1);
    repaired.sqlite.close();
  });

  it('réparation idempotente : deux runMigrations consécutifs ne cassent rien', () => {
    const handle = createDb(dbFile);
    runMigrations(handle, silentLog);
    breakToPreV3(handle);
    handle.sqlite.close();

    const h2 = createDb(dbFile);
    runMigrations(h2, silentLog);
    runMigrations(h2, silentLog); // second passage : no-op
    expect(v3Columns(h2)).toEqual({ queue: ['category', 'served_at'], candidates: ['evidence_json'] });
    h2.sqlite.close();
  });
});

describe('reparation hors journal du schema playback/BPM', () => {
  it('repare une base dont le journal futur fait sauter 0014, puis reste idempotent', () => {
    const seed = createDb(dbFile);
    runMigrations(seed, silentLog);
    seed.sqlite.exec('DROP TABLE `user_track_playback_settings`');
    seed.sqlite.exec('DROP TABLE `track_audio_analysis`');
    seed.sqlite
      .prepare('INSERT INTO __drizzle_migrations (hash, created_at) VALUES (?, ?)')
      .run('legacy-future-migration', 1784050000000);
    expect(playbackAndAnalysisObjects(seed)).toEqual([]);
    seed.sqlite.close();

    const repaired = createDb(dbFile);
    runMigrations(repaired, silentLog);
    expect(playbackAndAnalysisObjects(repaired)).toEqual([
      'track_audio_analysis',
      'user_track_playback_settings',
      'user_track_playback_settings_user_track_unique',
    ]);
    expect(ensurePlaybackSettingsAndAnalysisSchema(repaired, silentLog)).toEqual([]);

    expect(() =>
      repaired.sqlite.exec(`
        INSERT INTO users
          (username, display_name, password_hash, role, is_active, must_change_password, created_at, updated_at)
        VALUES ('legacy-owner', 'Legacy Owner', 'x', 'OWNER', 1, 0, 'now', 'now');
        INSERT INTO tracks
          (hash, path, size_bytes, title, artist, album, created_at)
        VALUES ('legacy-track', 'legacy.wav', 1, 'Legacy', 'Artist', 'Album', 'now');
        INSERT INTO user_track_playback_settings
          (user_id, track_id, speed_ratio, preserve_pitch, created_at, updated_at)
        VALUES (1, 1, 0.69, 1, 'now', 'now');
      `),
    ).toThrow();
    repaired.sqlite.close();
  });
});

describe('schéma des variantes hors ligne (Phase 1A)', () => {
  it('base NEUVE : table et index créés par runMigrations, idempotent', () => {
    const handle = createDb(dbFile);
    runMigrations(handle, silentLog);
    const objects = (
      handle.sqlite
        .prepare(
          `SELECT name FROM sqlite_master
           WHERE name IN ('track_offline_variants', 'track_offline_variants_identity_unique')
           ORDER BY name`,
        )
        .all() as Array<{ name: string }>
    ).map((row) => row.name);
    expect(objects).toEqual(['track_offline_variants', 'track_offline_variants_identity_unique']);
    expect(ensureOfflineVariantsSchema(handle, silentLog)).toEqual([]); // second passage : no-op
    // L'unicité (source_sha256, profile_version, encoder_version) est réelle.
    handle.sqlite.exec(`
      INSERT INTO tracks (hash, path, size_bytes, title, artist, album, created_at)
      VALUES ('src-hash', 'x.flac', 1, 'T', 'A', 'B', 'now');
      INSERT INTO track_offline_variants
        (track_id, source_sha256, profile, profile_version, encoder_version, target_bitrate_kbps, created_at, updated_at)
      VALUES (1, 'src-hash', 'opus_128', 'opus-128-v1', 'enc-1', 128, 'now', 'now');
    `);
    expect(() =>
      handle.sqlite.exec(`
        INSERT INTO track_offline_variants
          (track_id, source_sha256, profile, profile_version, encoder_version, target_bitrate_kbps, created_at, updated_at)
        VALUES (1, 'src-hash', 'opus_128', 'opus-128-v1', 'enc-1', 128, 'now', 'now');
      `),
    ).toThrow();
    handle.sqlite.close();
  });

  it('base LEGACY (table absente, journal futur) : réparée sans perte de données', () => {
    const seed = createDb(dbFile);
    runMigrations(seed, silentLog);
    const now = new Date().toISOString();
    seed.db.insert(tracks).values({
      hash: 'legacy-h', path: 'l.wav', sizeBytes: 1, title: 'L', artist: 'A', album: 'B', createdAt: now,
    }).run();
    seed.sqlite.exec('DROP TABLE `track_offline_variants`');
    // Journal « futur » : le migrateur drizzle ne rejouera jamais rien.
    seed.sqlite
      .prepare('INSERT INTO __drizzle_migrations (hash, created_at) VALUES (?, ?)')
      .run('legacy-future-offline', 1784060000000);
    seed.sqlite.close();

    const repaired = createDb(dbFile);
    runMigrations(repaired, silentLog);
    const table = repaired.sqlite
      .prepare(`SELECT name FROM sqlite_master WHERE name = 'track_offline_variants'`)
      .get();
    expect(table).toBeDefined();
    expect(repaired.db.select().from(tracks).all()).toHaveLength(1);
    repaired.sqlite.close();
  });
});

describe('schéma de mesure R128 (Phase 1C)', () => {
  it('crée la table sur base neuve et reste idempotent', () => {
    const handle = createDb(dbFile);
    runMigrations(handle, silentLog);
    const table = handle.sqlite
      .prepare(
        `SELECT name FROM sqlite_master
         WHERE type = 'table' AND name = 'track_loudness_analysis'`,
      )
      .get();
    expect(table).toBeDefined();
    expect(ensureLoudnessAnalysisSchema(handle, silentLog)).toEqual([]);
    handle.sqlite.close();
  });

  it('répare une base legacy dont le journal futur masque la migration', () => {
    const seed = createDb(dbFile);
    runMigrations(seed, silentLog);
    seed.sqlite.exec('DROP TABLE `track_loudness_analysis`');
    seed.sqlite
      .prepare(
        'INSERT INTO __drizzle_migrations (hash, created_at) VALUES (?, ?)',
      )
      .run('legacy-future-loudness', 1785900000000);
    seed.sqlite.close();

    const repaired = createDb(dbFile);
    runMigrations(repaired, silentLog);
    expect(
      repaired.sqlite
        .prepare(
          `SELECT name FROM sqlite_master
           WHERE type = 'table' AND name = 'track_loudness_analysis'`,
        )
        .get(),
    ).toBeDefined();
    repaired.sqlite.close();
  });
});

describe('routes de recommandation après réparation (aucun crash SQLite)', () => {
  it('GET /recommendations, POST /refresh et GET /status répondent sur une base réparée', async () => {
    // 1. Base saine, bootstrap OWNER (persiste user + refresh token), puis casse.
    const app1 = buildApp(makeConfig(), { similarityProvider: null });
    await app1.ready();
    const bootstrap = await app1.inject({
      method: 'POST',
      url: '/api/auth/bootstrap',
      payload: {
        username: 'owner', displayName: 'Owner',
        password: 'motdepasse-owner-1', passwordConfirmation: 'motdepasse-owner-1',
      },
    });
    expect(bootstrap.statusCode).toBe(201);
    const token = bootstrap.json().accessToken as string;
    breakToPreV3(app1.dbHandle);
    await app1.close();

    // 2. Nouveau boot : buildApp réapplique runMigrations → réparation.
    const app2 = buildApp(makeConfig(), { similarityProvider: null });
    await app2.ready();
    expect(v3Columns(app2.dbHandle)).toEqual({
      queue: ['category', 'served_at'],
      candidates: ['evidence_json'],
    });

    const auth = { authorization: `Bearer ${token}` };
    const feed = await app2.inject({ method: 'GET', url: '/api/recommendations', headers: auth });
    expect(feed.statusCode).toBe(200);
    expect(feed.json().items).toEqual([]);
    expect(feed.json().status.generationStatus).toBe('EMPTY');

    const refresh = await app2.inject({ method: 'POST', url: '/api/recommendations/refresh', headers: auth });
    expect(refresh.statusCode).toBe(202);

    // Laisse le job async se terminer, puis vérifie que /status ne remonte pas
    // d'erreur de schéma (la réparation a réussi).
    await new Promise((resolve) => setTimeout(resolve, 50));
    const status = await app2.inject({ method: 'GET', url: '/api/recommendations/status', headers: auth });
    expect(status.statusCode).toBe(200);
    const lastError = status.json().lastError;
    expect(lastError === null || lastError.kind !== 'SCHEMA_ERROR').toBe(true);

    await app2.close();
  });
});

describe('classification des erreurs de refresh', () => {
  it('détecte les erreurs de SCHÉMA (colonne/table absente)', () => {
    expect(classifyRefreshError(new Error('no such column: category'))).toBe('SCHEMA_ERROR');
    expect(classifyRefreshError(new Error('table x has no column named served_at'))).toBe(
      'SCHEMA_ERROR',
    );
    expect(classifyRefreshError(new Error('no such table: user_recommendation_queue'))).toBe(
      'SCHEMA_ERROR',
    );
  });

  it('classe les autres erreurs en UNKNOWN_ERROR', () => {
    expect(classifyRefreshError(new Error('ECONNRESET'))).toBe('UNKNOWN_ERROR');
    expect(classifyRefreshError('boom')).toBe('UNKNOWN_ERROR');
  });
});
