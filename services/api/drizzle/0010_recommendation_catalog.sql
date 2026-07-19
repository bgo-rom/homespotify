ALTER TABLE `recommendation_candidates` ADD `item_type` text DEFAULT 'TRACK' NOT NULL;
--> statement-breakpoint
ALTER TABLE `recommendation_candidates` ADD `external_url` text;
--> statement-breakpoint
ALTER TABLE `recommendation_candidates` ADD `is_active` integer DEFAULT true NOT NULL;
--> statement-breakpoint
ALTER TABLE `music_requests` ADD `user_note` text;
