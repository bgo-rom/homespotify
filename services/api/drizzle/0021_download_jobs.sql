-- DDL volontairement IDEMPOTENT (cf. LESSONS / migration 0019) : le journal
-- drizzle peut être rembobiné sur une base réelle, et la réparation
-- `ensureDownloadJobsSchema` peut avoir déjà créé la table.
CREATE TABLE IF NOT EXISTS `download_jobs` (
	`id` text PRIMARY KEY NOT NULL,
	`user_id` integer NOT NULL,
	`provider` text DEFAULT 'antra' NOT NULL,
	`requested_url` text NOT NULL,
	`normalized_url` text NOT NULL,
	`request_kind` text DEFAULT 'url' NOT NULL,
	`query` text,
	`candidates_json` text,
	`attempts_json` text,
	`selected_provider` text,
	`selected_url` text,
	`status` text DEFAULT 'queued' NOT NULL,
	`stage` text,
	`progress` integer DEFAULT 0 NOT NULL,
	`message` text,
	`title` text,
	`artist` text,
	`album` text,
	`source` text,
	`quality` text,
	`output_path` text,
	`local_import_job_id` integer,
	`track_id` integer,
	`error_code` text,
	`error_message` text,
	`process_id` integer,
	`attempt` integer DEFAULT 0 NOT NULL,
	`max_attempts` integer DEFAULT 3 NOT NULL,
	`cancel_requested` integer DEFAULT false NOT NULL,
	`created_at` text NOT NULL,
	`updated_at` text NOT NULL,
	`started_at` text,
	`completed_at` text,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`local_import_job_id`) REFERENCES `import_jobs`(`id`) ON UPDATE no action ON DELETE set null,
	FOREIGN KEY (`track_id`) REFERENCES `tracks`(`id`) ON UPDATE no action ON DELETE set null,
	CONSTRAINT `download_jobs_provider_check` CHECK (`provider` IN ('antra')),
	CONSTRAINT `download_jobs_status_check` CHECK (`status` IN ('queued','resolving','downloading','processing','importing','completed','failed','cancelled','interrupted')),
	CONSTRAINT `download_jobs_progress_check` CHECK (`progress` >= 0 AND `progress` <= 100),
	CONSTRAINT `download_jobs_attempt_check` CHECK (`attempt` >= 0),
	CONSTRAINT `download_jobs_max_attempts_check` CHECK (`max_attempts` >= 1 AND `max_attempts` <= 10),
	CONSTRAINT `download_jobs_process_id_check` CHECK (`process_id` IS NULL OR `process_id` > 0),
	CONSTRAINT `download_jobs_request_kind_check` CHECK (`request_kind` IN ('url','search'))
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS `download_jobs_user_created_idx` ON `download_jobs` (`user_id`,`created_at`);--> statement-breakpoint
CREATE INDEX IF NOT EXISTS `download_jobs_status_idx` ON `download_jobs` (`status`);--> statement-breakpoint
CREATE INDEX IF NOT EXISTS `download_jobs_local_import_idx` ON `download_jobs` (`local_import_job_id`);--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS `download_jobs_active_url_unique` ON `download_jobs` (`user_id`,`normalized_url`) WHERE `status` IN ('queued','resolving','downloading','processing','importing');
