CREATE TABLE `acquisition_jobs` (
	`id` text PRIMARY KEY NOT NULL,
	`requested_by_user_id` integer NOT NULL,
	`provider_id` text NOT NULL,
	`selection_json` text NOT NULL,
	`status` text NOT NULL,
	`progress` integer,
	`current_step` text,
	`error_code` text,
	`error_message` text,
	`created_at` text NOT NULL,
	`updated_at` text NOT NULL,
	`started_at` text,
	`completed_at` text,
	`resulting_track_id` integer,
	FOREIGN KEY (`requested_by_user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE restrict,
	FOREIGN KEY (`resulting_track_id`) REFERENCES `tracks`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
CREATE INDEX `acquisition_jobs_requester_idx` ON `acquisition_jobs` (`requested_by_user_id`);--> statement-breakpoint
CREATE INDEX `acquisition_jobs_status_idx` ON `acquisition_jobs` (`status`);