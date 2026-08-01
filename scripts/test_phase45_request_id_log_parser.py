#!/usr/bin/env python3
"""Tests ciblés du parseur de corrélation WinSW Phase 4.5."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from phase45_request_id_log_parser import find_correlation


class RequestIdLogParserTest(unittest.TestCase):
    def test_finds_exact_success_in_rotated_prefixed_json_log(self) -> None:
        with tempfile.TemporaryDirectory(prefix="phase45 logs with spaces ") as directory:
            root = Path(directory)
            request_id = "phase45-requestid-20260726-a1b2c3"
            records = [
                {"event": "STORAGE_AGENT_REQUEST_COMPLETED", "requestId": request_id + "-other", "statusCode": 200, "method": "HEAD", "trackId": 78},
                {"event": "STORAGE_AGENT_REQUEST_STARTED", "requestId": request_id, "method": "HEAD", "trackId": 78},
                {"event": "STORAGE_AGENT_REQUEST_COMPLETED", "requestId": request_id, "statusCode": 200, "method": "HEAD", "trackId": 78},
            ]
            path = root / "HomeSpotifyStorageAgent.out.1.log"
            path.write_text(
                "\n".join("WinSW-prefix " + json.dumps(record) for record in records),
                encoding="utf-8",
            )

            result = find_correlation(root, request_id, 100)

            self.assertIsNotNone(result)
            self.assertEqual(result["event"], "STORAGE_AGENT_REQUEST_COMPLETED")
            self.assertEqual(result["statusCode"], 200)
            self.assertEqual(result["file"], path.name)

    def test_rejects_started_only_and_failed_events(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            request_id = "phase45-requestid-no-success"
            path = root / "HomeSpotifyStorageAgent.out.log"
            path.write_text(
                "\n".join(
                    json.dumps(record)
                    for record in [
                        {"event": "STORAGE_AGENT_REQUEST_STARTED", "requestId": request_id, "method": "HEAD", "trackId": 78},
                        {"event": "STORAGE_AGENT_REQUEST_COMPLETED", "requestId": request_id, "statusCode": 503, "method": "HEAD", "trackId": 78},
                    ]
                ),
                encoding="utf-8",
            )

            self.assertIsNone(find_correlation(root, request_id, 100))

    def test_tail_limit_ignores_an_old_match(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            request_id = "phase45-requestid-old"
            path = root / "HomeSpotifyStorageAgent.out.log"
            old = json.dumps(
                {"event": "STORAGE_AGENT_REQUEST_COMPLETED", "requestId": request_id, "statusCode": 200, "method": "HEAD", "trackId": 78}
            )
            path.write_text(old + "\n" + "\n".join("{}" for _ in range(10)), encoding="utf-8")

            self.assertIsNone(find_correlation(root, request_id, 5))


if __name__ == "__main__":
    unittest.main()
