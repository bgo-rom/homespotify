CREATE TABLE `user_recommendation_queue` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`user_id` integer NOT NULL,
	`candidate_id` integer NOT NULL,
	`score` real NOT NULL,
	`rank` integer NOT NULL,
	`reason_code` text NOT NULL,
	`reason_text` text NOT NULL,
	`generated_at` text NOT NULL,
	`expires_at` text NOT NULL,
	`model_version` text NOT NULL,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`candidate_id`) REFERENCES `recommendation_candidates`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `user_recommendation_queue_user_candidate_idx` ON `user_recommendation_queue` (`user_id`,`candidate_id`);
--> statement-breakpoint
CREATE INDEX `user_recommendation_queue_user_rank_idx` ON `user_recommendation_queue` (`user_id`,`rank`);
--> statement-breakpoint
CREATE TABLE `recommendation_impressions` (
	`id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
	`user_id` integer NOT NULL,
	`candidate_id` integer NOT NULL,
	`shown_at` text NOT NULL,
	`position` integer NOT NULL,
	`model_version` text NOT NULL,
	`reason_code` text,
	FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`candidate_id`) REFERENCES `recommendation_candidates`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `recommendation_impressions_user_idx` ON `recommendation_impressions` (`user_id`,`shown_at`);
--> statement-breakpoint
ALTER TABLE `recommendation_candidates` ADD `preview_provider` text;
--> statement-breakpoint
ALTER TABLE `recommendation_candidates` ADD `preview_matched_at` text;
--> statement-breakpoint
ALTER TABLE `recommendation_candidates` ADD `preview_confidence` real;
--> statement-breakpoint
ALTER TABLE `recommendation_candidates` ADD `preview_expires_at` text;
