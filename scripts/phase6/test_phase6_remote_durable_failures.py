#!/usr/bin/env python3
"""Matrice statique de reprise et de panne du pipeline distant durable."""

from __future__ import annotations

import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
OBJECT_STORE = REPO / "services/storage-agent/src/object-store.ts"
AGENT_FAULTS = REPO / "services/storage-agent/src/durable-import-faults.test.ts"
IMPORTER = REPO / "services/api/src/download/remote-downloaded-file-importer.ts"
IMPORTER_FAULTS = REPO / "services/api/src/download/remote-downloaded-file-importer-faults.test.ts"
CLIENT = REPO / "services/api/src/storage/remote/storage-agent-client.ts"
CLIENT_FAULTS = REPO / "services/api/src/storage/remote/storage-agent-client-faults.test.ts"
MIGRATION = REPO / "services/api/drizzle/0021_download_jobs.sql"


class RemoteDurableFailureMatrixTest(unittest.TestCase):
    def test_concurrent_object_follower_is_explicitly_reused(self) -> None:
        text = OBJECT_STORE.read_text(encoding="utf-8")
        current = text.index("const current = this.inFlight.get(key)")
        verify = text.index("await verifySource(", current)
        wait = text.index("const receipt = await current", verify)
        reused = text.index("return { ...receipt, reused: true }", wait)
        self.assertLess(current, verify)
        self.assertLess(verify, wait)
        self.assertLess(wait, reused)

    def test_storage_agent_faults_cover_partial_response_loss_and_stale_index(self) -> None:
        text = AGENT_FAULTS.read_text(encoding="utf-8")
        for phrase in (
            "nettoie le .part après une coupure au milieu du corps",
            "réutilise l’objet après perte du reçu HTTP",
            "marque le suiveur concurrent comme réutilisation",
            "refuse un index plus ancien et conserve l’index actif",
            "INDEX_STALE_UPLOAD",
        ):
            self.assertIn(phrase, text)
        self.assertIn("incomingParts(fixture)", text)
        self.assertIn("objectStore.activeWrites === 0", text)

    def test_importer_faults_cover_every_commit_boundary(self) -> None:
        text = IMPORTER_FAULTS.read_text(encoding="utf-8")
        for phrase in (
            "réponse objet perdue",
            "réponse index perdue",
            "échec SQLite",
            "reçu objet incohérent",
            "deux imports concurrents",
        ):
            self.assertIn(phrase, text)
        self.assertIn("code: 'durability_not_confirmed'", text)
        self.assertIn("code: 'index_publish_failed'", text)
        self.assertIn("code: 'database_failed'", text)
        self.assertIn("maxConcurrentIndexes", text)

    def test_client_faults_cover_reset_timeout_and_early_rejection(self) -> None:
        text = CLIENT_FAULTS.read_text(encoding="utf-8")
        self.assertIn("coupure réseau au milieu de l’upload", text)
        self.assertIn("RESPONSE_TIMEOUT", text)
        self.assertIn("AGENT_REJECTED", text)
        self.assertIn("bytesObserved", text)
        self.assertIn("toBeLessThan(input.body.length)", text)

    def test_importer_preserves_recoverable_state_at_each_failure(self) -> None:
        text = IMPORTER.read_text(encoding="utf-8")
        durable = text.index("await this.requireDurableObject({", text.index("const deterministicPath"))
        transaction = text.index("result = this.handle.db.transaction", durable)
        publish = text.index("await this.publishIndex", transaction)
        self.assertLess(durable, transaction)
        self.assertLess(transaction, publish)
        self.assertNotIn("rm(input.filePath", text)
        self.assertNotIn("unlink(input.filePath", text)

    def test_client_stops_source_when_agent_has_already_rejected(self) -> None:
        text = CLIENT.read_text(encoding="utf-8")
        rejected = text.index("statusCode < 200 || statusCode >= 300", text.index("private upload"))
        unpipe = text.index("input.source.unpipe(request)", rejected)
        destroy_source = text.index("input.source.destroy()", unpipe)
        destroy_request = text.index("request.destroy()", destroy_source)
        self.assertLess(rejected, unpipe)
        self.assertLess(unpipe, destroy_source)
        self.assertLess(destroy_source, destroy_request)

    def test_download_jobs_migration_keeps_recovery_constraints_and_indexes(self) -> None:
        text = MIGRATION.read_text(encoding="utf-8")
        self.assertEqual(text.count("FOREIGN KEY"), 3)
        self.assertIn("REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade", text)
        self.assertIn("REFERENCES `import_jobs`(`id`) ON UPDATE no action ON DELETE set null", text)
        self.assertIn("REFERENCES `tracks`(`id`) ON UPDATE no action ON DELETE set null", text)
        self.assertIn("'interrupted'", text)
        self.assertIn("download_jobs_progress_check", text)
        self.assertIn("download_jobs_attempt_check", text)
        self.assertEqual(text.count("CREATE INDEX IF NOT EXISTS"), 3)
        self.assertEqual(text.count("CREATE UNIQUE INDEX IF NOT EXISTS"), 1)
        self.assertIn("download_jobs_active_url_unique", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
