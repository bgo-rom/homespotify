ALTER TABLE `recommendation_candidates` ADD `evidence_json` text;--> statement-breakpoint
ALTER TABLE `user_recommendation_queue` ADD `category` text DEFAULT 'SAFE' NOT NULL;--> statement-breakpoint
ALTER TABLE `user_recommendation_queue` ADD `served_at` text;
