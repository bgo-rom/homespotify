CREATE TABLE `track_enrichment` (
	`track_id` integer PRIMARY KEY NOT NULL,
	`status` text NOT NULL,
	`musicbrainz_recording_id` text,
	`musicbrainz_release_id` text,
	`musicbrainz_release_group_id` text,
	`musicbrainz_artist_id` text,
	`canonical_title` text,
	`canonical_artist` text,
	`canonical_album` text,
	`album_artist` text,
	`release_date` text,
	`track_number` integer,
	`disc_number` integer,
	`genre` text,
	`match_score` real,
	`candidates_json` text,
	`error_message` text,
	`checked_at` text NOT NULL,
	`enriched_at` text,
	FOREIGN KEY (`track_id`) REFERENCES `tracks`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `track_enrichment_status_idx` ON `track_enrichment` (`status`);--> statement-breakpoint
CREATE INDEX `track_enrichment_recording_idx` ON `track_enrichment` (`musicbrainz_recording_id`);