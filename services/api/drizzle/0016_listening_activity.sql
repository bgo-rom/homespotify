CREATE TABLE IF NOT EXISTS `listening_sessions` (
  `id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
  `user_id` integer NOT NULL,
  `track_id` integer NOT NULL,
  `client_session_id` text NOT NULL,
  `installation_id` text NOT NULL,
  `started_at` text NOT NULL,
  `last_activity_at` text NOT NULL,
  `latest_client_event_at` text NOT NULL,
  `ended_at` text,
  `initial_position_ms` integer DEFAULT 0 NOT NULL,
  `last_position_ms` integer DEFAULT 0 NOT NULL,
  `duration_ms` integer,
  `listened_ms` integer DEFAULT 0 NOT NULL,
  `playback_speed` real DEFAULT 1 NOT NULL,
  `status` text DEFAULT 'ACTIVE' NOT NULL,
  `end_reason` text,
  `pause_count` integer DEFAULT 0 NOT NULL,
  `seek_count` integer DEFAULT 0 NOT NULL,
  `qualified_play` integer DEFAULT false NOT NULL,
  `completed` integer DEFAULT false NOT NULL,
  `created_at` text NOT NULL,
  `updated_at` text NOT NULL,
  FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
  FOREIGN KEY (`track_id`) REFERENCES `tracks`(`id`) ON UPDATE no action ON DELETE cascade,
  CONSTRAINT `listening_sessions_listened_nonnegative` CHECK (`listened_ms` >= 0),
  CONSTRAINT `listening_sessions_position_nonnegative` CHECK (`last_position_ms` >= 0),
  CONSTRAINT `listening_sessions_speed_range` CHECK (`playback_speed` >= 0.7 AND `playback_speed` <= 1.3)
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS `listening_sessions_user_client_unique` ON `listening_sessions` (`user_id`,`client_session_id`);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS `listening_sessions_user_started_idx` ON `listening_sessions` (`user_id`,`started_at`);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS `listening_sessions_user_track_idx` ON `listening_sessions` (`user_id`,`track_id`);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS `listening_events` (
  `id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
  `user_id` integer NOT NULL,
  `session_id` integer NOT NULL,
  `client_event_id` text NOT NULL,
  `event_type` text NOT NULL,
  `position_ms` integer NOT NULL,
  `listened_ms` integer NOT NULL,
  `duration_ms` integer,
  `playback_speed` real NOT NULL,
  `client_created_at` text NOT NULL,
  `server_received_at` text NOT NULL,
  `metadata_json` text,
  FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
  FOREIGN KEY (`session_id`) REFERENCES `listening_sessions`(`id`) ON UPDATE no action ON DELETE cascade,
  CONSTRAINT `listening_events_listened_nonnegative` CHECK (`listened_ms` >= 0),
  CONSTRAINT `listening_events_position_nonnegative` CHECK (`position_ms` >= 0)
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS `listening_events_user_client_unique` ON `listening_events` (`user_id`,`client_event_id`);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS `listening_events_session_idx` ON `listening_events` (`session_id`);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS `listening_events_user_received_idx` ON `listening_events` (`user_id`,`server_received_at`);
