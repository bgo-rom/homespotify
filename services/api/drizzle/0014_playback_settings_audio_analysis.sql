CREATE TABLE IF NOT EXISTS `user_track_playback_settings` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`user_id` integer NOT NULL,
	`track_id` integer NOT NULL,
	`speed_ratio` real DEFAULT 1 NOT NULL,
	`preserve_pitch` integer DEFAULT true NOT NULL,
	`created_at` text NOT NULL,
	`updated_at` text NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`track_id`) REFERENCES `tracks`(`id`) ON UPDATE no action ON DELETE cascade,
	CONSTRAINT `user_track_playback_settings_speed_check` CHECK (`speed_ratio` >= 0.70 AND `speed_ratio` <= 1.30),
	CONSTRAINT `user_track_playback_settings_pitch_check` CHECK (`preserve_pitch` = 1)
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS `user_track_playback_settings_user_track_unique` ON `user_track_playback_settings` (`user_id`,`track_id`);
--> statement-breakpoint
CREATE TABLE IF NOT EXISTS `track_audio_analysis` (
	`track_id` integer PRIMARY KEY NOT NULL,
	`raw_bpm` real,
	`bpm` real,
	`bpm_confidence` real,
	`bpm_source` text,
	`status` text DEFAULT 'PENDING' NOT NULL,
	`error_message` text,
	`analyzed_at` text,
	`updated_at` text NOT NULL,
	FOREIGN KEY (`track_id`) REFERENCES `tracks`(`id`) ON UPDATE no action ON DELETE cascade,
	CONSTRAINT `track_audio_analysis_bpm_check` CHECK (`bpm` IS NULL OR (`bpm` >= 40 AND `bpm` <= 240)),
	CONSTRAINT `track_audio_analysis_confidence_check` CHECK (`bpm_confidence` IS NULL OR (`bpm_confidence` >= 0 AND `bpm_confidence` <= 1))
);
