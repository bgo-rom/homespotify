#!/usr/bin/env python3
"""Contrat statique du pipeline durable VPS → Windows → SQLite."""

from __future__ import annotations

import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
AGENT_SERVER = REPO / "services/storage-agent/src/server.ts"
AGENT_INDEX = REPO / "services/storage-agent/src/storage-index.ts"
REMOTE_IMPORTER = REPO / "services/api/src/download/remote-downloaded-file-importer.ts"
DOWNLOAD_SERVICE = REPO / "services/api/src/download/download-service.ts"
APP = REPO / "services/api/src/app.ts"


class RemoteDurableImportContractTest(unittest.TestCase):
    def test_storage_agent_exposes_bounded_signed_index_publication(self) -> None:
        text = AGENT_SERVER.read_text(encoding="utf-8")
        self.assertIn("const INDEX_UPLOAD_ROUTE = `${BASE_PATH}/index`", text)
        self.assertIn("config.maxIndexBytes", text)
        self.assertIn("x-hs-content-sha256", text)
        self.assertIn("indexStore.publish", text)
        self.assertIn("status: 'index_stored'", text)
        receipt = text[text.index("status: 'index_stored'") :][:350]
        self.assertNotIn("absolutePath", receipt)
        self.assertNotIn("indexPath", receipt)

    def test_index_is_published_atomically_after_validation(self) -> None:
        text = AGENT_INDEX.read_text(encoding="utf-8")
        hash_check = text.index("observedSha256 !== expectedSha256")
        parse = text.index("parseStorageIndex(raw.toString('utf8'))")
        temporary_sync = text.index("await temporary.sync()")
        rename = text.index("await rename(temporaryPath, this.options.indexPath)")
        final_sync = text.index("await finalHandle.sync()")
        install = text.index("this.index = {", final_sync)
        self.assertLess(hash_check, parse)
        self.assertLess(parse, temporary_sync)
        self.assertLess(temporary_sync, rename)
        self.assertLess(rename, final_sync)
        self.assertLess(final_sync, install)
        self.assertIn("publicationTail", text)
        self.assertIn("INDEX_STALE_UPLOAD", text)

    def test_sqlite_follows_the_durable_object_receipt(self) -> None:
        text = REMOTE_IMPORTER.read_text(encoding="utf-8")
        durable = text.index("await this.requireDurableObject({", text.index("match.kind === 'unique'") + 1)
        transaction = text.index("result = this.handle.db.transaction", durable)
        index = text.index("await this.publishIndex", transaction)
        self.assertLess(durable, transaction)
        self.assertLess(transaction, index)
        self.assertIn("receipt.durable !== true", text)
        self.assertIn("database_failed", text)
        self.assertIn("index_publish_failed", text)

    def test_index_publication_is_serialized_and_built_from_current_sqlite(self) -> None:
        text = REMOTE_IMPORTER.read_text(encoding="utf-8")
        self.assertIn("private tail: Promise<void> = Promise.resolve()", text)
        operation = text.index("const operation = this.tail.then")
        snapshot = text.index("buildRemoteStorageIndexDocument", operation)
        upload = text.index("this.client.putIndex", snapshot)
        self.assertLess(operation, snapshot)
        self.assertLess(snapshot, upload)

    def test_staging_is_deleted_only_after_remote_import_returns(self) -> None:
        text = DOWNLOAD_SERVICE.read_text(encoding="utf-8")
        call = text.index("await remote.importDownloadedFile")
        deletion = text.index("await rm(file, { force: true })", call)
        failure = text.index("REMOTE_IMPORT_FAILED", call)
        self.assertLess(call, deletion)
        self.assertLess(deletion, failure)
        self.assertIn("return false", text[failure : failure + 500])
        self.assertIn("outputPath: null", text)

    def test_remote_pipeline_is_enabled_only_for_remote_or_cached_storage(self) -> None:
        text = APP.read_text(encoding="utf-8")
        self.assertIn("config.audioRemote !== undefined", text)
        self.assertIn("config.audioStorageMode !== 'local'", text)
        self.assertIn("ownedRemoteDownloadImporter?.close()", text)

    def test_importer_never_deletes_the_source_or_exposes_a_disk_path(self) -> None:
        text = REMOTE_IMPORTER.read_text(encoding="utf-8")
        self.assertNotIn("rm(input.filePath", text)
        self.assertNotIn("unlink(input.filePath", text)
        self.assertIn("Le fichier de staging n'est jamais supprimé ici", text)
        self.assertIn(".homespotify/objects/", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
