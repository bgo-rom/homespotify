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

const ACQUISITION_JOBS_TABLE_SQL = `
CREATE TABLE IF NOT EXISTS \`acquisition_jobs\` (
  \`id\` text PRIMARY KEY NOT NULL,
  \`user_id\` integer NOT NULL,
  \`provider\` text DEFAULT 'QOBUZ' NOT NULL,
  \`query\` text NOT NULL,
  \`dedupe_key\` text NOT NULL,
  \`result_index\` integer,
  \`status\` text DEFAULT 'QUEUED' NOT NULL,
  \`stage\` text,
  \`progress\` integer DEFAULT 0 NOT NULL,
  \`message\` text,
  \`selected_title\` text,
  \`selected_artist\` text,
  \`selected_album\` text,
  \`selected_duration_seconds\` integer,
  \`attempt\` integer DEFAULT 0 NOT NULL,
  \`max_attempts\` integer DEFAULT 3 NOT NULL,
  \`downloaded_relative_path\` text,
  \`local_import_job_id\` integer,
  \`track_id\` integer,
  \`error_code\` text,
  \`error_message\` text,
  \`provider_used\` text DEFAULT 'LUCIDA' NOT NULL,
  \`fallback_from\` text,
  \`fallback_reason_code\` text,
  \`cancel_requested\` integer DEFAULT false NOT NULL,
  \`created_at\` text NOT NULL,
  \`updated_at\` text NOT NULL,
  \`started_at\` text,
  \`completed_at\` text,
  FOREIGN KEY (\`user_id\`) REFERENCES \`users\`(\`id\`) ON UPDATE no action ON DELETE cascade,
  FOREIGN KEY (\`local_import_job_id\`) REFERENCES \`import_jobs\`(\`id\`) ON UPDATE no action ON DELETE set null,
  FOREIGN KEY (\`track_id\`) REFERENCES \`tracks\`(\`id\`) ON UPDATE no action ON DELETE set null,
  CONSTRAINT \`acquisition_jobs_provider_check\` CHECK (\`provider\` IN ('QOBUZ')),
  CONSTRAINT \`acquisition_jobs_status_check\` CHECK (\`status\` IN (
    'QUEUED',
    'SEARCHING',
    'SELECTING',
    'OPENING_RESULT',
    'VERIFYING',
    'DOWNLOADING',
    'RETRYING',
    'PAUSED_PROVIDER',
    'MANUAL_VERIFICATION_REQUIRED',
    'WAITING_MANUAL_DOWNLOAD',
    'DOWNLOADED',
    'IMPORTING',
    'COMPLETED',
    'FAILED',
    'CANCELLED',
    'INTERRUPTED'
  )),
  CONSTRAINT \`acquisition_jobs_progress_check\` CHECK (\`progress\` >= 0 AND \`progress\` <= 100),
  CONSTRAINT \`acquisition_jobs_result_index_check\` CHECK (\`result_index\` IS NULL OR \`result_index\` >= 0),
  CONSTRAINT \`acquisition_jobs_duration_check\` CHECK (\`selected_duration_seconds\` IS NULL OR \`selected_duration_seconds\` >= 0),
  CONSTRAINT \`acquisition_jobs_attempt_check\` CHECK (\`attempt\` >= 0),
  CONSTRAINT \`acquisition_jobs_max_attempts_check\` CHECK (\`max_attempts\` >= 1 AND \`max_attempts\` <= 10)
)`;

const DOWNLOAD_JOBS_TABLE_SQL = `
CREATE TABLE IF NOT EXISTS \`download_jobs\` (
  \`id\` text PRIMARY KEY NOT NULL,
  \`user_id\` integer NOT NULL,
  \`provider\` text DEFAULT 'antra' NOT NULL,
  \`requested_url\` text NOT NULL,
  \`normalized_url\` text NOT NULL,
  \`request_kind\` text DEFAULT 'url' NOT NULL,
  \`query\` text,
  \`candidates_json\` text,
  \`attempts_json\` text,
  \`selected_provider\` text,
  \`selected_url\` text,
  \`status\` text DEFAULT 'queued' NOT NULL,
  \`stage\` text,
  \`progress\` integer DEFAULT 0 NOT NULL,
  \`message\` text,
  \`title\` text,
  \`artist\` text,
  \`album\` text,
  \`source\` text,
  \`quality\` text,
  \`output_path\` text,
  \`local_import_job_id\` integer,
  \`track_id\` integer,
  \`error_code\` text,
  \`error_message\` text,
  \`process_id\` integer,
  \`attempt\` integer DEFAULT 0 NOT NULL,
  \`max_attempts\` integer DEFAULT 3 NOT NULL,
  \`cancel_requested\` integer DEFAULT false NOT NULL,
  \`created_at\` text NOT NULL,
  \`updated_at\` text NOT NULL,
  \`started_at\` text,
  \`completed_at\` text,
  FOREIGN KEY (\`user_id\`) REFERENCES \`users\`(\`id\`) ON UPDATE no action ON DELETE cascade,
  FOREIGN KEY (\`local_import_job_id\`) REFERENCES \`import_jobs\`(\`id\`) ON UPDATE no action ON DELETE set null,
  FOREIGN KEY (\`track_id\`) REFERENCES \`tracks\`(\`id\`) ON UPDATE no action ON DELETE set null,
  CONSTRAINT \`download_jobs_provider_check\` CHECK (\`provider\` IN ('antra')),
  CONSTRAINT \`download_jobs_status_check\` CHECK (\`status\` IN (
    'queued',
    'resolving',
    'downloading',
    'processing',
    'importing',
    'completed',
    'failed',
    'cancelled',
    'interrupted'
  )),
  CONSTRAINT \`download_jobs_progress_check\` CHECK (\`progress\` >= 0 AND \`progress\` <= 100),
  CONSTRAINT \`download_jobs_attempt_check\` CHECK (\`attempt\` >= 0),
  CONSTRAINT \`download_jobs_max_attempts_check\` CHECK (\`max_attempts\` >= 1 AND \`max_attempts\` <= 10),
  CONSTRAINT \`download_jobs_process_id_check\` CHECK (\`process_id\` IS NULL OR \`process_id\` > 0),
  CONSTRAINT \`download_jobs_request_kind_check\` CHECK (\`request_kind\` IN ('url', 'search'))
)`;

/**
 * Colonnes de la recherche texte, ajoutées de façon PUREMENT ADDITIVE.
 *
 * SQLite ne sait pas ajouter une contrainte CHECK par `ALTER TABLE` : sur une
 * table `download_jobs` antérieure, `request_kind` arrive donc sans sa
 * contrainte. Le dépôt la revalide de toute façon avant écriture — la base
 * n'est jamais la seule barrière, et reconstruire la table pour cela coûterait
 * plus cher que le bénéfice.
 */
const DOWNLOAD_JOBS_SEARCH_COLUMNS: ReadonlyArray<{
  table: string;
  column: string;
  ddl: string;
}> = [
  {
    table: 'download_jobs',
    column: 'request_kind',
    ddl: "ALTER TABLE `download_jobs` ADD `request_kind` text DEFAULT 'url' NOT NULL",
  },
  { table: 'download_jobs', column: 'query', ddl: 'ALTER TABLE `download_jobs` ADD `query` text' },
  {
    table: 'download_jobs',
    column: 'candidates_json',
    ddl: 'ALTER TABLE `download_jobs` ADD `candidates_json` text',
  },
  {
    table: 'download_jobs',
    column: 'attempts_json',
    ddl: 'ALTER TABLE `download_jobs` ADD `attempts_json` text',
  },
  {
    table: 'download_jobs',
    column: 'selected_provider',
    ddl: 'ALTER TABLE `download_jobs` ADD `selected_provider` text',
  },
  {
    table: 'download_jobs',
    column: 'selected_url',
    ddl: 'ALTER TABLE `download_jobs` ADD `selected_url` text',
  },
];

const MONOCHROME_MANUAL_SESSIONS_TABLE_SQL = `
CREATE TABLE IF NOT EXISTS \`monochrome_manual_sessions\` (
  \`job_id\` text PRIMARY KEY NOT NULL,
  \`user_id\` integer NOT NULL,
  \`status\` text DEFAULT 'WAITING' NOT NULL,
  \`reserved_at\` text,
  \`started_at\` text,
  \`result_received_at\` text,
  \`created_at\` text NOT NULL,
  \`updated_at\` text NOT NULL,
  FOREIGN KEY (\`job_id\`) REFERENCES \`acquisition_jobs\`(\`id\`) ON UPDATE no action ON DELETE cascade,
  FOREIGN KEY (\`user_id\`) REFERENCES \`users\`(\`id\`) ON UPDATE no action ON DELETE cascade,
  CONSTRAINT \`monochrome_manual_status_check\`
    CHECK (\`status\` IN ('WAITING','RESERVED','RESULT_RECEIVED'))
)`;

const PROVIDER_HEALTH_TABLE_SQL = `
CREATE TABLE IF NOT EXISTS \`provider_health\` (
  \`provider\` text PRIMARY KEY NOT NULL,
  \`state\` text DEFAULT 'CLOSED' NOT NULL,
  \`reason_code\` text,
  \`public_message\` text,
  \`failure_count\` integer DEFAULT 0 NOT NULL,
  \`opened_at\` text,
  \`retry_at\` text,
  \`last_failure_at\` text,
  \`last_success_at\` text,
  \`half_open_probe_job_id\` text,
  \`manual_verification_job_id\` text,
  \`manual_verification_holder_job_id\` text,
  \`created_at\` text NOT NULL,
  \`updated_at\` text NOT NULL,
  CONSTRAINT \`provider_health_state_check\` CHECK (\`state\` IN ('CLOSED','OPEN','HALF_OPEN','MANUAL_VERIFICATION_REQUIRED')),
  CONSTRAINT \`provider_health_failure_count_check\` CHECK (\`failure_count\` >= 0),
  CONSTRAINT \`provider_health_half_open_probe_check\` CHECK (\`state\` = 'HALF_OPEN' OR \`half_open_probe_job_id\` IS NULL),
  CONSTRAINT \`provider_health_manual_verification_job_required_check\` CHECK ((\`state\` = 'MANUAL_VERIFICATION_REQUIRED' AND \`manual_verification_job_id\` IS NOT NULL) OR (\`manual_verification_job_id\` IS NULL AND \`manual_verification_holder_job_id\` IS NULL))
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

/**
 * Schéma persistant des acquisitions distantes. Cette table suit le processus
 * Python et pointe ensuite vers le vrai import_jobs créé par UserImportService.
 */
export function ensureAcquisitionJobsSchema(
  handle: DbHandle,
  log: MigrationLogger = defaultLogger,
): string[] {
  if (
    !tableExists(handle, 'users') ||
    !tableExists(handle, 'tracks') ||
    !tableExists(handle, 'import_jobs')
  ) {
    return [];
  }

  const had = tableExists(handle, 'acquisition_jobs');

  handle.sqlite.transaction(() => {
    if (had) {
      const definition = handle.sqlite
        .prepare(
          "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'acquisition_jobs'",
        )
        .get() as { sql?: string } | undefined;
      if (
        !definition?.sql?.includes('PAUSED_PROVIDER') ||
        !definition.sql.includes('MANUAL_VERIFICATION_REQUIRED') ||
        !definition.sql.includes('WAITING_MANUAL_DOWNLOAD') ||
        !definition.sql.includes('provider_used')
      ) {
        handle.sqlite.exec(
          'ALTER TABLE `acquisition_jobs` RENAME TO `acquisition_jobs_hs_import_16_legacy`',
        );
        handle.sqlite.exec(ACQUISITION_JOBS_TABLE_SQL);
        handle.sqlite.exec(`
          INSERT INTO \`acquisition_jobs\` (
            id,user_id,provider,query,dedupe_key,result_index,status,stage,
            progress,message,selected_title,selected_artist,selected_album,
            selected_duration_seconds,attempt,max_attempts,
            downloaded_relative_path,local_import_job_id,track_id,error_code,
            error_message,provider_used,fallback_from,fallback_reason_code,
            cancel_requested,created_at,updated_at,started_at,
            completed_at
          )
          SELECT
            id,user_id,provider,query,dedupe_key,result_index,status,stage,
            progress,message,selected_title,selected_artist,selected_album,
            selected_duration_seconds,attempt,max_attempts,
            downloaded_relative_path,local_import_job_id,track_id,error_code,
            error_message,'LUCIDA',NULL,NULL,
            cancel_requested,created_at,updated_at,started_at,
            completed_at
          FROM \`acquisition_jobs_hs_import_16_legacy\`
        `);
        handle.sqlite.exec(
          'DROP TABLE `acquisition_jobs_hs_import_16_legacy`',
        );
      }
    }
    handle.sqlite.exec(ACQUISITION_JOBS_TABLE_SQL);
    handle.sqlite.exec(
      'CREATE INDEX IF NOT EXISTS `acquisition_jobs_user_created_idx` ON `acquisition_jobs` (`user_id`,`created_at`)',
    );
    handle.sqlite.exec(
      'CREATE INDEX IF NOT EXISTS `acquisition_jobs_status_idx` ON `acquisition_jobs` (`status`)',
    );
    handle.sqlite.exec(
      'CREATE INDEX IF NOT EXISTS `acquisition_jobs_local_import_idx` ON `acquisition_jobs` (`local_import_job_id`)',
    );
    handle.sqlite.exec(
      "CREATE UNIQUE INDEX IF NOT EXISTS `acquisition_jobs_active_dedupe_unique` ON `acquisition_jobs` (`user_id`,`dedupe_key`) WHERE `status` IN ('QUEUED','SEARCHING','SELECTING','OPENING_RESULT','VERIFYING','DOWNLOADING','RETRYING','PAUSED_PROVIDER','MANUAL_VERIFICATION_REQUIRED','WAITING_MANUAL_DOWNLOAD','DOWNLOADED','IMPORTING')",
    );
    handle.sqlite.exec(MONOCHROME_MANUAL_SESSIONS_TABLE_SQL);
    handle.sqlite.exec(
      "CREATE UNIQUE INDEX IF NOT EXISTS `monochrome_manual_single_active_unique` ON `monochrome_manual_sessions` ((1)) WHERE `status` IN ('WAITING','RESERVED')",
    );
    handle.sqlite.exec(
      'CREATE INDEX IF NOT EXISTS `monochrome_manual_user_idx` ON `monochrome_manual_sessions` (`user_id`)',
    );
  })();

  if (had) return [];

  log.info('réparation schéma : table acquisition_jobs créée');
  return ['acquisition_jobs'];
}

/**
 * Schéma persistant des téléchargements Antra. Filet IDEMPOTENT indépendant du
 * journal drizzle : une base déjà avancée dont le `when` dépasse celui de 0021
 * sauterait la migration sans jamais créer la table.
 */
export function ensureDownloadJobsSchema(
  handle: DbHandle,
  log: MigrationLogger = defaultLogger,
): string[] {
  if (
    !tableExists(handle, 'users') ||
    !tableExists(handle, 'tracks') ||
    !tableExists(handle, 'import_jobs')
  ) {
    return [];
  }

  const had = tableExists(handle, 'download_jobs');
  handle.sqlite.transaction(() => {
    handle.sqlite.exec(DOWNLOAD_JOBS_TABLE_SQL);
    handle.sqlite.exec(
      'CREATE INDEX IF NOT EXISTS `download_jobs_user_created_idx` ON `download_jobs` (`user_id`,`created_at`)',
    );
    handle.sqlite.exec(
      'CREATE INDEX IF NOT EXISTS `download_jobs_status_idx` ON `download_jobs` (`status`)',
    );
    handle.sqlite.exec(
      'CREATE INDEX IF NOT EXISTS `download_jobs_local_import_idx` ON `download_jobs` (`local_import_job_id`)',
    );
    handle.sqlite.exec(
      "CREATE UNIQUE INDEX IF NOT EXISTS `download_jobs_active_url_unique` ON `download_jobs` (`user_id`,`normalized_url`) WHERE `status` IN ('queued','resolving','downloading','processing','importing')",
    );
  })();

  // Base créée avant la recherche texte : ajout additif des colonnes.
  const addedColumns = ensureColumns(handle, DOWNLOAD_JOBS_SEARCH_COLUMNS, log);

  if (had) return addedColumns;
  log.info('réparation schéma : table download_jobs créée');
  return ['download_jobs'];
}

export function ensureProviderHealthSchema(
  handle: DbHandle,
  log: MigrationLogger = defaultLogger,
): string[] {
  const had = tableExists(handle, 'provider_health');
  handle.sqlite.transaction(() => {
    if (had) {
      const definition = handle.sqlite
        .prepare(
          "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'provider_health'",
        )
        .get() as { sql?: string } | undefined;
      const hasManualVerificationColumns =
        definition?.sql?.includes('manual_verification_holder_job_id') ===
        true;
      if (hasManualVerificationColumns) {
        handle.sqlite.exec(`
          UPDATE \`provider_health\`
          SET
            \`state\` = 'CLOSED',
            \`reason_code\` = NULL,
            \`public_message\` = NULL,
            \`failure_count\` = 0,
            \`opened_at\` = NULL,
            \`retry_at\` = NULL,
            \`half_open_probe_job_id\` = NULL,
            \`manual_verification_job_id\` = NULL,
            \`manual_verification_holder_job_id\` = NULL
          WHERE \`state\` = 'MANUAL_VERIFICATION_REQUIRED'
            AND (
              \`manual_verification_job_id\` IS NULL
              OR NOT EXISTS (
                SELECT 1
                FROM \`acquisition_jobs\`
                WHERE \`acquisition_jobs\`.\`id\` =
                      \`provider_health\`.\`manual_verification_job_id\`
                  AND \`acquisition_jobs\`.\`status\` =
                      'MANUAL_VERIFICATION_REQUIRED'
                  AND \`acquisition_jobs\`.\`stage\` =
                      'waiting_user_verification'
              )
            )
        `);
      }
      if (
        !definition?.sql?.includes('MANUAL_VERIFICATION_REQUIRED') ||
        !definition.sql.includes('manual_verification_holder_job_id') ||
        !definition.sql.includes(
          'provider_health_manual_verification_job_required_check',
        )
      ) {
        handle.sqlite.exec(
          'ALTER TABLE `provider_health` RENAME TO `provider_health_hs_import_16_legacy`',
        );
        handle.sqlite.exec(PROVIDER_HEALTH_TABLE_SQL);
        handle.sqlite.exec(`
          INSERT INTO \`provider_health\` (
            provider,state,reason_code,public_message,failure_count,opened_at,
            retry_at,last_failure_at,last_success_at,half_open_probe_job_id,
            manual_verification_job_id,
            manual_verification_holder_job_id,
            created_at,updated_at
          )
          SELECT
            provider,state,reason_code,public_message,failure_count,opened_at,
            retry_at,last_failure_at,last_success_at,half_open_probe_job_id,
            ${
              hasManualVerificationColumns
                ? 'manual_verification_job_id'
                : 'NULL'
            },
            ${
              hasManualVerificationColumns
                ? 'manual_verification_holder_job_id'
                : 'NULL'
            },
            created_at,updated_at
          FROM \`provider_health_hs_import_16_legacy\`
        `);
        handle.sqlite.exec(
          'DROP TABLE `provider_health_hs_import_16_legacy`',
        );
      }
    }
    handle.sqlite.exec(PROVIDER_HEALTH_TABLE_SQL);
    handle.sqlite.exec(
      'CREATE INDEX IF NOT EXISTS `provider_health_state_retry_idx` ON `provider_health` (`state`,`retry_at`)',
    );
  })();
  if (had) return [];
  log.info('réparation schéma : table provider_health créée');
  return ['provider_health'];
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
  const acquisitionJobs = ensureAcquisitionJobsSchema(handle, log);
  const downloadJobs = ensureDownloadJobsSchema(handle, log);
  const providerHealth = ensureProviderHealthSchema(handle, log);
  const offlineVariants = ensureOfflineVariantsSchema(handle, log);
  const loudnessAnalysis = ensureLoudnessAnalysisSchema(handle, log);
  const repaired = [
    ...preRepair,
    ...preMedia,
    ...playbackAndAnalysis,
    ...postRepair,
    ...postMedia,
    ...requestImports,
    ...acquisitionJobs,
    ...downloadJobs,
    ...providerHealth,
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
