CREATE TABLE `music_requests` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`requested_by_user_id` integer NOT NULL,
	`candidate_id` integer NOT NULL,
	`status` text NOT NULL,
	`owner_note` text,
	`reviewed_by_owner_id` integer,
	`resulting_track_id` integer,
	`created_at` text NOT NULL,
	`updated_at` text NOT NULL,
	`completed_at` text,
	FOREIGN KEY (`requested_by_user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`candidate_id`) REFERENCES `recommendation_candidates`(`id`) ON UPDATE no action ON DELETE restrict,
	FOREIGN KEY (`reviewed_by_owner_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE set null,
	FOREIGN KEY (`resulting_track_id`) REFERENCES `tracks`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
CREATE INDEX `music_requests_requester_idx` ON `music_requests` (`requested_by_user_id`);--> statement-breakpoint
CREATE INDEX `music_requests_status_idx` ON `music_requests` (`status`);--> statement-breakpoint
CREATE UNIQUE INDEX `music_requests_active_unique` ON `music_requests` (`requested_by_user_id`,`candidate_id`) WHERE status IN ('SENT', 'REVIEWING', 'APPROVED', 'SEARCHING_MANUALLY', 'IMPORTING');--> statement-breakpoint
CREATE TABLE `play_events` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`user_id` integer NOT NULL,
	`track_id` integer NOT NULL,
	`started_at` text NOT NULL,
	`listened_ms` integer DEFAULT 0 NOT NULL,
	`completed` integer DEFAULT false NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`track_id`) REFERENCES `tracks`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `play_events_user_idx` ON `play_events` (`user_id`,`track_id`);--> statement-breakpoint
CREATE TABLE `recommendation_candidates` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`external_id` text,
	`title` text NOT NULL,
	`artist` text NOT NULL,
	`album` text,
	`artwork_url` text,
	`preview_url` text,
	`duration_ms` integer,
	`genres_json` text,
	`source` text NOT NULL,
	`metadata_json` text,
	`created_at` text NOT NULL,
	`updated_at` text NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `recommendation_candidates_source_external_idx` ON `recommendation_candidates` (`source`,`external_id`) WHERE external_id IS NOT NULL;--> statement-breakpoint
CREATE INDEX `recommendation_candidates_artist_idx` ON `recommendation_candidates` (`artist`);--> statement-breakpoint
CREATE TABLE `recommendation_events` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`user_id` integer NOT NULL,
	`candidate_id` integer NOT NULL,
	`action` text NOT NULL,
	`created_at` text NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`candidate_id`) REFERENCES `recommendation_candidates`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `recommendation_events_user_idx` ON `recommendation_events` (`user_id`);--> statement-breakpoint
CREATE INDEX `recommendation_events_candidate_idx` ON `recommendation_events` (`candidate_id`);--> statement-breakpoint
CREATE TABLE `user_hidden_tracks` (
	`user_id` integer NOT NULL,
	`track_id` integer,
	`candidate_id` integer,
	`reason` text NOT NULL,
	`created_at` text NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`track_id`) REFERENCES `tracks`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`candidate_id`) REFERENCES `recommendation_candidates`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `user_hidden_tracks_track_unique` ON `user_hidden_tracks` (`user_id`,`track_id`) WHERE track_id IS NOT NULL;--> statement-breakpoint
CREATE UNIQUE INDEX `user_hidden_tracks_candidate_unique` ON `user_hidden_tracks` (`user_id`,`candidate_id`) WHERE candidate_id IS NOT NULL;--> statement-breakpoint
CREATE INDEX `user_hidden_tracks_user_idx` ON `user_hidden_tracks` (`user_id`);