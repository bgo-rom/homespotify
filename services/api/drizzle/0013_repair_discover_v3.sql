-- Réparation V3 « Découvrir ». Les colonnes manquantes (category, served_at,
-- evidence_json) sont ajoutées AVANT le migrateur par ensureDiscoverV3Columns()
-- (idempotent, cf. src/db/migrate.ts) ; cette migration ne pose donc qu'un
-- index idempotent qui s'appuie sur `served_at`. Elle porte un `when` (journal)
-- SUPÉRIEUR à 0011 pour être réellement appliquée sur la base bloquée à 0011
-- (0012 ayant été sautée à cause d'un timestamp hors-ordre).
CREATE INDEX IF NOT EXISTS `user_recommendation_queue_served_idx` ON `user_recommendation_queue` (`user_id`,`served_at`);
