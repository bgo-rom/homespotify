CREATE TABLE IF NOT EXISTS `track_loudness_analysis` (
  `track_id` integer PRIMARY KEY NOT NULL,
  `status` text DEFAULT 'PENDING' NOT NULL,
  `integrated_lufs` real,
  `true_peak_dbfs` real,
  `replay_gain_db` real,
  `target_lufs` real DEFAULT -18 NOT NULL,
  `peak_ceiling_dbfs` real DEFAULT -1 NOT NULL,
  `error_message` text,
  `analyzed_at` text,
  `updated_at` text NOT NULL,
  FOREIGN KEY (`track_id`) REFERENCES `tracks`(`id`) ON UPDATE no action ON DELETE cascade,
  CONSTRAINT `track_loudness_analysis_lufs_check` CHECK (`integrated_lufs` IS NULL OR (`integrated_lufs` >= -70 AND `integrated_lufs` <= 5)),
  CONSTRAINT `track_loudness_analysis_peak_check` CHECK (`true_peak_dbfs` IS NULL OR (`true_peak_dbfs` >= -120 AND `true_peak_dbfs` <= 20)),
  CONSTRAINT `track_loudness_analysis_gain_check` CHECK (`replay_gain_db` IS NULL OR (`replay_gain_db` >= -24 AND `replay_gain_db` <= 12))
);
