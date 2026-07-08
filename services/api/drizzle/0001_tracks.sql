CREATE TABLE `track_quality` (
	`track_id` integer PRIMARY KEY NOT NULL,
	`container` text NOT NULL,
	`codec` text NOT NULL,
	`sample_rate` integer NOT NULL,
	`bit_depth` integer NOT NULL,
	`channels` integer NOT NULL,
	`status` text NOT NULL,
	`provenance` text NOT NULL,
	`analyzed_at` text NOT NULL,
	FOREIGN KEY (`track_id`) REFERENCES `tracks`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `tracks` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`hash` text NOT NULL,
	`path` text NOT NULL,
	`size_bytes` integer NOT NULL,
	`duration_seconds` real,
	`title` text NOT NULL,
	`artist` text NOT NULL,
	`album` text NOT NULL,
	`year` integer,
	`genre` text,
	`cover_path` text,
	`created_at` text NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `tracks_hash_unique` ON `tracks` (`hash`);