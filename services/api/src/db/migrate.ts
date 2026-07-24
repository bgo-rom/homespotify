import { fileURLToPath } from 'node:url';
import { migrate } from 'drizzle-orm/better-sqlite3/migrator';
import { sql } from 'drizzle-orm';
import { appMeta } from './schema.js';
import type { DbHandle } from './client.js';

const migrationsFolder = fileURLToPath(new URL('../../drizzle', import.meta.url));

/** Journalisation minimale des migrations (facultative : `console` par défaut). */
export interface MigrationLogger {
  info(message: string, context?: Record<string, unknown>): void;
  error(message: string, context?: Record<string, unknown>): void;
}

const defaultLogger: MigrationLogger = {
  info: (message, context) =>
    console.log(context ? `${message} ${JSON.stringify(context)}` : message),
  error: (message, context) =>
    console.error(context ? `${message} ${JSON.stringify(context)}` : message),
};

/**
 * Colonnes de RÉPARATION V3 « Découvrir ». Le migrateur drizzle
 * (better-sqlite3) décide quoi appliquer d'après le `when` du journal : la
 * migration 0012 a reçu un timestamp ANTÉRIEUR à 0011 (écrit à la main avec un
 * `when` fabriqué), donc elle est sautée définitivement sur toute base déjà à
 * l'état 0011. Résultat : `category`, `served_at`, `evidence_json` manquantes.
 *
 * Cette réparation est IDEMPOTENTE et indépendante du journal : elle n'ajoute
 * une colonne que si la table existe ET que la colonne manque. Sûre sur une
 * base ancienne (table absente → ignorée), partielle (ajoute ce qui manque) ou
 * neuve (colonnes déjà créées par 0012 → no-op). Voir LESSONS.
 */
const V3_REPAIR_COLUMNS: ReadonlyArray<{ table: string; column: string; ddl: string }> = [
  {
    table: 'user_recommendation_queue',
    column: 'category',
    // NOT NULL exige un DEFAULT en SQLite ADD COLUMN : rétro-compatible.
    ddl: "ALTER TABLE `user_recommendation_queue` ADD `category` text DEFAULT 'SAFE' NOT NULL",
  },
  {
    table: 'user_recommendation_queue',
    column: 'served_at',
    ddl: 'ALTER TABLE `user_recommendation_queue` ADD `served_at` text',
  },
  {
    table: 'recommendation_candidates',
    column: 'evidence_json',
    ddl: 'ALTER TABLE `recommendation_candidates` ADD `evidence_json` text',
  },
];

/**
 * Colonnes du modèle v4 « media-ready ». Réparation IDEMPOTENTE et indépendante
 * du journal (même logique que la V3) : garantit la présence des colonnes de la
 * machine à états média même si le migrateur 0014 est sauté (base neuve créée
 * par drizzle-kit ou journal réordonné). Purement additif.
 */
const V4_MEDIA_COLUMNS: ReadonlyArray<{ table: string; column: string; ddl: string }> = [
  { table: 'recommendation_candidates', column: 'canonical_artist', ddl: 'ALTER TABLE `recommendation_candidates` ADD `canonical_artist` text' },
  { table: 'recommendation_candidates', column: 'canonical_title', ddl: 'ALTER TABLE `recommendation_candidates` ADD `canonical_title` text' },
  { table: 'recommendation_candidates', column: 'isrc', ddl: 'ALTER TABLE `recommendation_candidates` ADD `isrc` text' },
  { table: 'recommendation_candidates', column: 'apple_music_song_id', ddl: 'ALTER TABLE `recommendation_candidates` ADD `apple_music_song_id` text' },
  { table: 'recommendation_candidates', column: 'artwork_width', ddl: 'ALTER TABLE `recommendation_candidates` ADD `artwork_width` integer' },
  { table: 'recommendation_candidates', column: 'artwork_height', ddl: 'ALTER TABLE `recommendation_candidates` ADD `artwork_height` integer' },
  { table: 'recommendation_candidates', column: 'artwork_provider', ddl: 'ALTER TABLE `recommendation_candidates` ADD `artwork_provider` text' },
  {
    table: 'recommendation_candidates',
    column: 'media_resolution_status',
    ddl: "ALTER TABLE `recommendation_candidates` ADD `media_resolution_status` text DEFAULT 'DISCOVERED' NOT NULL",
  },
  { table: 'recommendation_candidates', column: 'media_failure_reason', ddl: 'ALTER TABLE `recommendation_candidates` ADD `media_failure_reason` text' },
  { table: 'recommendation_candidates', column: 'media_resolved_at', ddl: 'ALTER TABLE `recommendation_candidates` ADD `media_resolved_at` text' },
];

const PLAYBACK_SETTINGS_TABLE_SQL = `
CREATE TABLE IF NOT EXISTS \`user_track_playback_settings\` (
  \`id\` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
  \`user_id\` integer NOT NULL,
  \`track_id\` integer NOT NULL,
  \`speed_ratio\` real DEFAULT 1 NOT NULL,
  \`preserve_pitch\` integer DEFAULT true NOT NULL,
  \`created_at\` text NOT NULL,
  \`updated_at\` text NOT NULL,
  FOREIGN KEY (\`user_id\`) REFERENCES \`users\`(\`id\`) ON UPDATE no action ON DELETE cascade,
  FOREIGN KEY (\`track_id\`) REFERENCES \`tracks\`(\`id\`) ON UPDATE no action ON DELETE cascade,
  CONSTRAINT \`user_track_playback_settings_speed_check\` CHECK (\`speed_ratio\` >= 0.70 AND \`speed_ratio\` <= 1.30),
  CONSTRAINT \`user_track_playback_settings_pitch_check\` CHECK (\`preserve_pitch\` = 1)
)`;

const PLAYBACK_SETTINGS_INDEX_SQL = `
CREATE UNIQUE INDEX IF NOT EXISTS \`user_track_playback_settings_user_track_unique\`
ON \`user_track_playback_settings\` (\`user_id\`, \`track_id\`)`;

const TRACK_AUDIO_ANALYSIS_TABLE_SQL = `
CREATE TABLE IF NOT EXISTS \`track_audio_analysis\` (
  \`track_id\` integer PRIMARY KEY NOT NULL,
  \`raw_bpm\` real,
  \`bpm\` real,
  \`bpm_confidence\` real,
  \`bpm_source\` text,
  \`status\` text DEFAULT 'PENDING' NOT NULL,
  \`error_message\` text,
  \`analyzed_at\` text,
  \`updated_at\` text NOT NULL,
  FOREIGN KEY (\`track_id\`) REFERENCES \`tracks\`(\`id\`) ON UPDATE no action ON DELETE cascade,
  CONSTRAINT \`track_audio_analysis_bpm_check\` CHECK (\`bpm\` IS NULL OR (\`bpm\` >= 40 AND \`bpm\` <= 240)),
  CONSTRAINT \`track_audio_analysis_confidence_check\` CHECK (\`bpm_confidence\` IS NULL OR (\`bpm_confidence\` >= 0 AND \`bpm_confidence\` <= 1))
)`;

const TRACK_LOUDNESS_ANALYSIS_TABLE_SQL = `
CREATE TABLE IF NOT EXISTS \`track_loudness_analysis\` (
  \`track_id\` integer PRIMARY KEY NOT NULL,
  \`status\` text DEFAULT 'PENDING' NOT NULL,
  \`integrated_lufs\` real,
  \`true_peak_dbfs\` real,
  \`replay_gain_db\` real,
  \`target_lufs\` real DEFAULT -18 NOT NULL,
  \`peak_ceiling_dbfs\` real DEFAULT -1 NOT NULL,
  \`error_message\` text,
  \`analyzed_at\` text,
  \`updated_at\` text NOT NULL,
  FOREIGN KEY (\`track_id\`) REFERENCES \`tracks\`(\`id\`) ON UPDATE no action ON DELETE cascade,
  CONSTRAINT \`track_loudness_analysis_lufs_check\` CHECK (\`integrated_lufs\` IS NULL OR (\`integrated_lufs\` >= -70 AND \`integrated_lufs\` <= 5)),
  CONSTRAINT \`track_loudness_analysis_peak_check\` CHECK (\`true_peak_dbfs\` IS NULL OR (\`true_peak_dbfs\` >= -120 AND \`true_peak_dbfs\` <= 20)),
  CONSTRAINT \`track_loudness_analysis_gain_check\` CHECK (\`replay_gain_db\` IS NULL OR (\`replay_gain_db\` >= -24 AND \`replay_gain_db\` <= 12))
)`;

const REQUEST_IMPORT_COLUMNS: ReadonlyArray<{ table: string; column: string; ddl: string }> = [
  { table: 'tracks', column: 'isrc', ddl: 'ALTER TABLE `tracks` ADD `isrc` text' },
  { table: 'music_requests', column: 'request_type', ddl: "ALTER TABLE `music_requests` ADD `request_type` text DEFAULT 'TRACK' NOT NULL" },
  { table: 'music_requests', column: 'title', ddl: 'ALTER TABLE `music_requests` ADD `title` text' },
  { table: 'music_requests', column: 'artist', ddl: 'ALTER TABLE `music_requests` ADD `artist` text' },
  { table: 'music_requests', column: 'album', ddl: 'ALTER TABLE `music_requests` ADD `album` text' },
  { table: 'music_requests', column: 'external_url', ddl: 'ALTER TABLE `music_requests` ADD `external_url` text' },
  { table: 'music_requests', column: 'external_source', ddl: 'ALTER TABLE `music_requests` ADD `external_source` text' },
  { table: 'music_requests', column: 'cover_url', ddl: 'ALTER TABLE `music_requests` ADD `cover_url` text' },
  { table: 'music_requests', column: 'requested_item_count', ddl: 'ALTER TABLE `music_requests` ADD `requested_item_count` integer DEFAULT 1 NOT NULL' },
  { table: 'music_requests', column: 'completed_item_count', ddl: 'ALTER TABLE `music_requests` ADD `completed_item_count` integer DEFAULT 0 NOT NULL' },
  { table: 'music_requests', column: 'unavailable_item_count', ddl: 'ALTER TABLE `music_requests` ADD `unavailable_item_count` integer DEFAULT 0 NOT NULL' },
];

const MUSIC_REQUEST_ITEMS_TABLE_SQL = `
CREATE TABLE IF NOT EXISTS \`music_request_items\` (
  \`id\` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
  \`music_request_id\` integer NOT NULL,
  \`position\` integer NOT NULL,
  \`title\` text NOT NULL,
  \`artist\` text,
  \`album\` text,
  \`duration_ms\` integer,
  \`isrc\` text,
  \`resulting_track_id\` integer,
  \`status\` text DEFAULT 'PENDING' NOT NULL,
  \`owner_note\` text,
  \`created_at\` text NOT NULL,
  \`updated_at\` text NOT NULL,
  FOREIGN KEY (\`music_request_id\`) REFERENCES \`music_requests\`(\`id\`) ON UPDATE no action ON DELETE cascade,
  FOREIGN KEY (\`resulting_track_id\`) REFERENCES \`tracks\`(\`id\`) ON UPDATE no action ON DELETE set null
)`;

const USER_IMPORT_DIRECTORIES_TABLE_SQL = `
CREATE TABLE IF NOT EXISTS \`user_import_directories\` (
  \`id\` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
  \`user_id\` integer NOT NULL,
  \`directory_name\` text NOT NULL,
  \`created_at\` text NOT NULL,
  FOREIGN KEY (\`user_id\`) REFERENCES \`users\`(\`id\`) ON UPDATE no action ON DELETE cascade
)`;

const IMPORT_JOBS_TABLE_SQL = `
CREATE TABLE IF NOT EXISTS \`import_jobs\` (
  \`id\` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
  \`user_id\` integer NOT NULL,
  \`filename\` text NOT NULL,
  \`relative_path\` text NOT NULL,
  \`size_bytes\` integer,
  \`status\` text DEFAULT 'DISCOVERED' NOT NULL,
  \`sha256\` text,
  \`metadata_json\` text,
  \`track_id\` integer,
  \`music_request_id\` integer,
  \`music_request_item_id\` integer,
  \`match_candidates_json\` text,
  \`error_message\` text,
  \`attempts\` integer DEFAULT 0 NOT NULL,
  \`created_at\` text NOT NULL,
  \`updated_at\` text NOT NULL,
  \`processed_at\` text,
  FOREIGN KEY (\`user_id\`) REFERENCES \`users\`(\`id\`) ON UPDATE no action ON DELETE cascade,
  FOREIGN KEY (\`track_id\`) REFERENCES \`tracks\`(\`id\`) ON UPDATE no action ON DELETE set null,
  FOREIGN KEY (\`music_request_id\`) REFERENCES \`music_requests\`(\`id\`) ON UPDATE no action ON DELETE set null,
  FOREIGN KEY (\`music_request_item_id\`) REFERENCES \`music_request_items\`(\`id\`) ON UPDATE no action ON DELETE set null
)`;

const TRACK_OFFLINE_VARIANTS_TABLE_SQL = `
CREATE TABLE IF NOT EXISTS \`track_offline_variants\` (
  \`id\` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
  \`track_id\` integer NOT NULL,
  \`source_sha256\` text NOT NULL,
  \`profile\` text NOT NULL,
  \`profile_version\` text NOT NULL,
  \`encoder_version\` text NOT NULL,
  \`status\` text DEFAULT 'PENDING' NOT NULL,
  \`target_bitrate_kbps\` integer NOT NULL,
  \`measured_bitrate_kbps\` integer,
  \`duration_seconds\` real,
  \`size_bytes\` integer,
  \`sha256\` text,
  \`path\` text,
  \`error_message\` text,
  \`attempts\` integer DEFAULT 0 NOT NULL,
  \`created_at\` text NOT NULL,
  \`updated_at\` text NOT NULL,
  \`ready_at\` text,
  FOREIGN KEY (\`track_id\`) REFERENCES \`tracks\`(\`id\`) ON UPDATE no action ON DELETE cascade
)`;

/**
 * Schéma des variantes hors ligne (Phase 1A). Réparation IDEMPOTENTE et
 * indépendante du journal drizzle (leçon V3 : jamais de migration raw fragile).
 * Sûre sur base neuve (tracks absent → no-op avant migrate, créée après) et
 * sur base legacy (CREATE IF NOT EXISTS).
 */
export function ensureOfflineVariantsSchema(
  handle: DbHandle,
  log: MigrationLogger = defaultLogger,
): string[] {
  if (!tableExists(handle, 'tracks')) return [];
  const had = tableExists(handle, 'track_offline_variants');
  handle.sqlite.transaction(() => {
    handle.sqlite.exec(TRACK_OFFLINE_VARIANTS_TABLE_SQL);
    handle.sqlite.exec(
      'CREATE UNIQUE INDEX IF NOT EXISTS `track_offline_variants_identity_unique` ON `track_offline_variants` (`source_sha256`,`profile_version`,`encoder_version`)',
    );
    handle.sqlite.exec(
      'CREATE INDEX IF NOT EXISTS `track_offline_variants_track_idx` ON `track_offline_variants` (`track_id`)',
    );
    handle.sqlite.exec(
      'CREATE INDEX IF NOT EXISTS `track_offline_variants_status_idx` ON `track_offline_variants` (`status`)',
    );
  })();
  if (!had) {
    log.info('réparation schéma : table track_offline_variants créée');
    return ['track_offline_variants'];
  }
  return [];
}

function tableExists(handle: DbHandle, table: string): boolean {
  return (
    handle.sqlite
      .prepare(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?`)
      .get(table) !== undefined
  );
}

function columnExists(handle: DbHandle, table: string, column: string): boolean {
  const columns = handle.sqlite.prepare(`PRAGMA table_info(${table})`).all() as Array<{
    name: string;
  }>;
  return columns.some((c) => c.name === column);
}

/**
 * Ajoute les colonnes V3 manquantes (réparation idempotente). Retourne la
 * liste des colonnes réellement ajoutées (vide = rien à faire).
 */
export function ensureDiscoverV3Columns(
  handle: DbHandle,
  log: MigrationLogger = defaultLogger,
): string[] {
  return ensureColumns(handle, V3_REPAIR_COLUMNS, log);
}

/** Réparation idempotente des colonnes v4 « media-ready » (cf. V4_MEDIA_COLUMNS). */
export function ensureMediaReadyV4Columns(
  handle: DbHandle,
  log: MigrationLogger = defaultLogger,
): string[] {
  const added = ensureColumns(handle, V4_MEDIA_COLUMNS, log);
  // L'index n'existe que si la table existe (base réelle avancée sans 0014).
  if (
    tableExists(handle, 'recommendation_candidates') &&
    columnExists(handle, 'recommendation_candidates', 'media_resolution_status')
  ) {
    handle.sqlite.exec(
      'CREATE INDEX IF NOT EXISTS `recommendation_candidates_media_status_idx` ON `recommendation_candidates` (`media_resolution_status`)',
    );
  }
  return added;
}

/**
 * Répare le schéma de la migration 0014 sans se fier au journal Drizzle.
 * Certaines bases ont un created_at historique supérieur au `when` de 0014 :
 * le migrateur la saute alors définitivement, bien que les tables manquent.
 * Les DDL sont volontairement identiques à 0014 et entièrement idempotents.
 */
export function ensurePlaybackSettingsAndAnalysisSchema(
  handle: DbHandle,
  log: MigrationLogger = defaultLogger,
): string[] {
  if (!tableExists(handle, 'users') || !tableExists(handle, 'tracks')) return [];

  const created: string[] = [];
  const hadPlaybackSettings = tableExists(handle, 'user_track_playback_settings');
  const hadAudioAnalysis = tableExists(handle, 'track_audio_analysis');

  handle.sqlite.transaction(() => {
    handle.sqlite.exec(PLAYBACK_SETTINGS_TABLE_SQL);
    handle.sqlite.exec(PLAYBACK_SETTINGS_INDEX_SQL);
    handle.sqlite.exec(TRACK_AUDIO_ANALYSIS_TABLE_SQL);
  })();

  if (!hadPlaybackSettings) created.push('user_track_playback_settings');
  if (!hadAudioAnalysis) created.push('track_audio_analysis');
  if (created.length > 0) {
    log.info('réparation schéma playback/BPM appliquée', { tables: created });
  }
  return created;
}

/**
 * Filet de sécurité de la mesure R128. Comme les autres tables audio critiques,
 * il ne dépend pas exclusivement du journal Drizzle d'une base déjà avancée.
 */
export function ensureLoudnessAnalysisSchema(
  handle: DbHandle,
  log: MigrationLogger = defaultLogger,
): string[] {
  if (!tableExists(handle, 'tracks')) return [];
  const had = tableExists(handle, 'track_loudness_analysis');
  handle.sqlite.exec(TRACK_LOUDNESS_ANALYSIS_TABLE_SQL);
  if (had) return [];
  log.info('réparation schéma : table track_loudness_analysis créée');
  return ['track_loudness_analysis'];
}

/**
 * Filet de sécurité additif pour les demandes multi-items et les imports par
 * utilisateur. Exécuté APRÈS le migrateur afin de ne jamais rejouer les
 * ALTER de 0015 sur une base qui doit encore appliquer cette migration.
 */
export function ensureRequestImportSchema(
  handle: DbHandle,
  log: MigrationLogger = defaultLogger,
): string[] {
  if (!tableExists(handle, 'users') || !tableExists(handle, 'tracks')) return [];
  const repaired = ensureColumns(handle, REQUEST_IMPORT_COLUMNS, log);
  if (!tableExists(handle, 'music_requests')) return repaired;

  const hadItems = tableExists(handle, 'music_request_items');
  const hadDirectories = tableExists(handle, 'user_import_directories');
  const hadJobs = tableExists(handle, 'import_jobs');
  handle.sqlite.transaction(() => {
    handle.sqlite.exec(MUSIC_REQUEST_ITEMS_TABLE_SQL);
    handle.sqlite.exec('CREATE UNIQUE INDEX IF NOT EXISTS `music_request_items_request_position_unique` ON `music_request_items` (`music_request_id`,`position`)');
    handle.sqlite.exec('CREATE INDEX IF NOT EXISTS `music_request_items_request_idx` ON `music_request_items` (`music_request_id`)');
    handle.sqlite.exec('CREATE INDEX IF NOT EXISTS `music_request_items_track_idx` ON `music_request_items` (`resulting_track_id`)');
    handle.sqlite.exec(USER_IMPORT_DIRECTORIES_TABLE_SQL);
    handle.sqlite.exec('CREATE UNIQUE INDEX IF NOT EXISTS `user_import_directories_user_unique` ON `user_import_directories` (`user_id`)');
    handle.sqlite.exec('CREATE UNIQUE INDEX IF NOT EXISTS `user_import_directories_name_unique` ON `user_import_directories` (`directory_name`)');
    handle.sqlite.exec(IMPORT_JOBS_TABLE_SQL);
    handle.sqlite.exec('CREATE INDEX IF NOT EXISTS `import_jobs_user_created_idx` ON `import_jobs` (`user_id`,`created_at`)');
    handle.sqlite.exec('CREATE INDEX IF NOT EXISTS `import_jobs_status_idx` ON `import_jobs` (`status`)');
    handle.sqlite.exec("CREATE UNIQUE INDEX IF NOT EXISTS `import_jobs_active_path_unique` ON `import_jobs` (`user_id`,`relative_path`) WHERE `status` IN ('DISCOVERED', 'WAITING_FOR_STABLE_FILE', 'ANALYZING')");

    handle.sqlite.exec(`
      UPDATE music_requests
      SET request_type = coalesce(request_type, (SELECT item_type FROM recommendation_candidates WHERE id = music_requests.candidate_id), 'TRACK'),
          title = coalesce(title, (SELECT title FROM recommendation_candidates WHERE id = music_requests.candidate_id)),
          artist = coalesce(artist, (SELECT artist FROM recommendation_candidates WHERE id = music_requests.candidate_id)),
          album = coalesce(album, (SELECT album FROM recommendation_candidates WHERE id = music_requests.candidate_id)),
          external_url = coalesce(external_url, (SELECT external_url FROM recommendation_candidates WHERE id = music_requests.candidate_id)),
          cover_url = coalesce(cover_url, (SELECT artwork_url FROM recommendation_candidates WHERE id = music_requests.candidate_id))
    `);
    handle.sqlite.exec(`
      INSERT OR IGNORE INTO music_request_items (
        music_request_id, position, title, artist, album, resulting_track_id,
        status, created_at, updated_at
      )
      SELECT id, 1, coalesce(title, 'Titre inconnu'), artist, album,
        resulting_track_id,
        CASE
          WHEN status = 'COMPLETED' THEN 'COMPLETED'
          WHEN status = 'REJECTED' THEN 'REJECTED'
          WHEN status = 'FAILED' THEN 'FAILED'
          ELSE 'PENDING'
        END,
        created_at, updated_at
      FROM music_requests
    `);
  })();
  if (!hadItems) repaired.push('music_request_items');
  if (!hadDirectories) repaired.push('user_import_directories');
  if (!hadJobs) repaired.push('import_jobs');
  return repaired;
}

function ensureColumns(
  handle: DbHandle,
  specs: ReadonlyArray<{ table: string; column: string; ddl: string }>,
  log: MigrationLogger,
): string[] {
  const added: string[] = [];
  for (const spec of specs) {
    if (!tableExists(handle, spec.table)) continue;
    if (columnExists(handle, spec.table, spec.column)) continue;
    handle.sqlite.exec(spec.ddl);
    added.push(`${spec.table}.${spec.column}`);
    log.info('réparation schéma : colonne ajoutée', { column: `${spec.table}.${spec.column}` });
  }
  return added;
}

/**
 * Applique les migrations Drizzle de façon SÛRE et idempotente, puis répare le
 * schéma V3. Ordre :
 *   1. Réparation V3 AVANT le migrateur : garantit `served_at`/`category`/
 *      `evidence_json` sur une base bloquée à 0011 (0012 sautée). Sur une base
 *      neuve, no-op (tables absentes) — le migrateur créera tout.
 *   2. Migrateur drizzle standard : base neuve = schéma complet ; base réelle =
 *      applique la migration 0013 (index sur `served_at`, désormais présente).
 *   3. Filet de sécurité : re-vérifie après migrate (cas base neuve où 0012 a
 *      créé les colonnes — reste no-op).
 *
 * Toute erreur ici DOIT remonter : le serveur ne démarre jamais avec un schéma
 * incomplet (cf. server.ts / buildApp).
 */
export function runMigrations(handle: DbHandle, log: MigrationLogger = defaultLogger): void {
  const preRepair = ensureDiscoverV3Columns(handle, log);
  // v4 « media-ready » : colonnes ajoutées par une réparation IDEMPOTENTE (pas
  // de migration drizzle 0014), leçon V3 — une migration raw ALTER ADD casse si
  // le journal est rembobiné. Avant migrate : no-op sur base neuve (tables
  // absentes) ; sur base réelle avancée, ajoute les colonnes.
  const preMedia = ensureMediaReadyV4Columns(handle, log);
  migrate(handle.db, { migrationsFolder });
  const playbackAndAnalysis = ensurePlaybackSettingsAndAnalysisSchema(handle, log);
  const postRepair = ensureDiscoverV3Columns(handle, log);
  // Après migrate : base neuve → les tables existent enfin, on ajoute les
  // colonnes v4. Toujours idempotente (colonnes déjà là → skip).
  const postMedia = ensureMediaReadyV4Columns(handle, log);
  const requestImports = ensureRequestImportSchema(handle, log);
  const offlineVariants = ensureOfflineVariantsSchema(handle, log);
  const loudnessAnalysis = ensureLoudnessAnalysisSchema(handle, log);
  const repaired = [
    ...preRepair,
    ...preMedia,
    ...playbackAndAnalysis,
    ...postRepair,
    ...postMedia,
    ...requestImports,
    ...offlineVariants,
    ...loudnessAnalysis,
  ];
  if (repaired.length > 0) {
    log.info('réparation schéma appliquée', { objects: repaired });
  }

  const now = new Date().toISOString();
  handle.db
    .insert(appMeta)
    .values({ key: 'initialized_at', value: now, updatedAt: now })
    .onConflictDoNothing()
    .run();
}

/** Nombre de migrations enregistrées dans `__drizzle_migrations` (diagnostic boot). */
export function appliedMigrationCount(handle: DbHandle): number {
  try {
    const row = handle.sqlite
      .prepare('SELECT count(*) AS n FROM __drizzle_migrations')
      .get() as { n: number } | undefined;
    return row?.n ?? 0;
  } catch {
    return 0;
  }
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
