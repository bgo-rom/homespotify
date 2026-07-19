-- Migration 0017 — cache normalisé de la découverte catalogue.
-- ADDITIVE et IDEMPOTENTE : aucune table existante n'est modifiée ni supprimée.
CREATE TABLE IF NOT EXISTS `discovery_cache` (
  `id` integer PRIMARY KEY AUTOINCREMENT NOT NULL,
  `provider` text NOT NULL,
  `operation` text NOT NULL,
  `query_hash` text NOT NULL,
  `entity_type` text,
  `market` text DEFAULT '' NOT NULL,
  `locale` text,
  `normalized_json` text NOT NULL,
  `fetched_at` text NOT NULL,
  `expires_at` text NOT NULL,
  `schema_version` integer DEFAULT 1 NOT NULL,
  `status_code` integer,
  `negative_result` integer DEFAULT false NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX IF NOT EXISTS `discovery_cache_key_unique` ON `discovery_cache` (`provider`,`operation`,`query_hash`,`market`);
--> statement-breakpoint
CREATE INDEX IF NOT EXISTS `discovery_cache_expires_idx` ON `discovery_cache` (`expires_at`);
