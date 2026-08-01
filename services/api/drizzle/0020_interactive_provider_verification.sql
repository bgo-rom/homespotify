ALTER TABLE `provider_health`
RENAME TO `provider_health_hs_import_16_legacy`;
--> statement-breakpoint
CREATE TABLE `provider_health` (
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
  `manual_verification_job_id` text,
  `manual_verification_holder_job_id` text,
  `created_at` text NOT NULL,
  `updated_at` text NOT NULL,
  CONSTRAINT `provider_health_state_check` CHECK (
    `state` IN (
      'CLOSED',
      'OPEN',
      'HALF_OPEN',
      'MANUAL_VERIFICATION_REQUIRED'
    )
  ),
  CONSTRAINT `provider_health_failure_count_check`
    CHECK (`failure_count` >= 0),
  CONSTRAINT `provider_health_half_open_probe_check` CHECK (
    `state` = 'HALF_OPEN' OR `half_open_probe_job_id` IS NULL
  ),
  CONSTRAINT `provider_health_manual_verification_job_required_check` CHECK (
    (
      `state` = 'MANUAL_VERIFICATION_REQUIRED'
      AND `manual_verification_job_id` IS NOT NULL
    )
    OR (
      `manual_verification_job_id` IS NULL
      AND `manual_verification_holder_job_id` IS NULL
    )
  )
);
--> statement-breakpoint
INSERT INTO `provider_health` (
  `provider`,
  `state`,
  `reason_code`,
  `public_message`,
  `failure_count`,
  `opened_at`,
  `retry_at`,
  `last_failure_at`,
  `last_success_at`,
  `half_open_probe_job_id`,
  `manual_verification_job_id`,
  `manual_verification_holder_job_id`,
  `created_at`,
  `updated_at`
)
SELECT
  `provider`,
  `state`,
  `reason_code`,
  `public_message`,
  `failure_count`,
  `opened_at`,
  `retry_at`,
  `last_failure_at`,
  `last_success_at`,
  `half_open_probe_job_id`,
  NULL,
  NULL,
  `created_at`,
  `updated_at`
FROM `provider_health_hs_import_16_legacy`;
--> statement-breakpoint
DROP TABLE `provider_health_hs_import_16_legacy`;
--> statement-breakpoint
CREATE INDEX `provider_health_state_retry_idx`
ON `provider_health` (`state`,`retry_at`);
