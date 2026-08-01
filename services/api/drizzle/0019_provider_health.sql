CREATE TABLE IF NOT EXISTS `provider_health` (
  `provider` text PRIMARY KEY NOT NULL,
  `state` text DEFAULT 'CLOSED' NOT NULL,
  `reason_code` text,
  `public_message` text,
  `failure_count` integer DEFAULT 0 NOT NULL,
  `opened_at` text,
  `retry_at` text,
  `last_failure_at` text,
  `last_success_at` text,
  `half_open_probe_job_id` text,
  `created_at` text NOT NULL,
  `updated_at` text NOT NULL,
  CONSTRAINT `provider_health_state_check` CHECK (`state` IN ('CLOSED','OPEN','HALF_OPEN')),
  CONSTRAINT `provider_health_failure_count_check` CHECK (`failure_count` >= 0),
  CONSTRAINT `provider_health_half_open_probe_check` CHECK (`state` = 'HALF_OPEN' OR `half_open_probe_job_id` IS NULL)
);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS `provider_health_state_retry_idx`
ON `provider_health` (`state`,`retry_at`);
