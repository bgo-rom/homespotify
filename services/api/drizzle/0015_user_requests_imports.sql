-- SQLite ne supporte pas ADD COLUMN IF NOT EXISTS. Les colonnes additives de
-- tracks/music_requests et leur backfill sont donc appliqués par la réparation
-- idempotente ensureRequestImportSchema() juste après le migrateur. Cette
-- migration reste rejouable même si un ancien journal Drizzle est rembobiné.
CREATE TABLE IF NOT EXISTS `music_request_items` (
  `id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
  `music_request_id` integer NOT NULL,
  `position` integer NOT NULL,
  `title` text NOT NULL,
  `artist` text,
  `album` text,
  `duration_ms` integer,
  `isrc` text,
  `resulting_track_id` integer,
  `status` text DEFAULT 'PENDING' NOT NULL,
  `owner_note` text,
  `created_at` text NOT NULL,
  `updated_at` text NOT NULL,
  FOREIGN KEY (`music_request_id`) REFERENCES `music_requests`(`id`) ON UPDATE no action ON DELETE cascade,
  FOREIGN KEY (`resulting_track_id`) REFERENCES `tracks`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS `music_request_items_request_position_unique` ON `music_request_items` (`music_request_id`,`position`);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS `music_request_items_request_idx` ON `music_request_items` (`music_request_id`);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS `music_request_items_track_idx` ON `music_request_items` (`resulting_track_id`);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS `user_import_directories` (
  `id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
  `user_id` integer NOT NULL,
  `directory_name` text NOT NULL,
  `created_at` text NOT NULL,
  FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS `user_import_directories_user_unique` ON `user_import_directories` (`user_id`);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS `user_import_directories_name_unique` ON `user_import_directories` (`directory_name`);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS `import_jobs` (
  `id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
  `user_id` integer NOT NULL,
  `filename` text NOT NULL,
  `relative_path` text NOT NULL,
  `size_bytes` integer,
  `status` text DEFAULT 'DISCOVERED' NOT NULL,
  `sha256` text,
  `metadata_json` text,
  `track_id` integer,
  `music_request_id` integer,
  `music_request_item_id` integer,
  `match_candidates_json` text,
  `error_message` text,
  `attempts` integer DEFAULT 0 NOT NULL,
  `created_at` text NOT NULL,
  `updated_at` text NOT NULL,
  `processed_at` text,
  FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
  FOREIGN KEY (`track_id`) REFERENCES `tracks`(`id`) ON UPDATE no action ON DELETE set null,
  FOREIGN KEY (`music_request_id`) REFERENCES `music_requests`(`id`) ON UPDATE no action ON DELETE set null,
  FOREIGN KEY (`music_request_item_id`) REFERENCES `music_request_items`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS `import_jobs_user_created_idx` ON `import_jobs` (`user_id`,`created_at`);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS `import_jobs_status_idx` ON `import_jobs` (`status`);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS `import_jobs_active_path_unique` ON `import_jobs` (`user_id`,`relative_path`) WHERE `status` IN ('DISCOVERED', 'WAITING_FOR_STABLE_FILE', 'ANALYZING');
