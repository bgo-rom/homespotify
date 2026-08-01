#!/usr/bin/env python3
"""Régression locale du quoting et de la lecture d'état Phase 4.5."""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
STATE_READER = SCRIPTS / "vps_phase45_state_value.py"
AUDITED_FILES = [
    SCRIPTS / "run_phase45_remote_integration.ps1",
    SCRIPTS / "vps_phase45_setup.sh",
    SCRIPTS / "vps_phase45_cleanup.sh",
    SCRIPTS / "vps_phase45_run_smoke.sh",
    SCRIPTS / "vps_phase45_run_provider_test.sh",
    SCRIPTS / "vps_storage_agent_smoke_test.py",
]


class Phase45HarnessQuotingTest(unittest.TestCase):
    def test_state_reader_handles_path_with_spaces(self) -> None:
        with tempfile.TemporaryDirectory(prefix="phase45 state with spaces ") as directory:
            state_file = Path(directory) / "ready state.json"
            state_file.write_text(
                json.dumps(
                    {
                        "smallTrackId": 17,
                        "largeTrackId": 29,
                        "staleTrackId": 1_000_029,
                        "sourceTrackCount": 158,
                    }
                ),
                encoding="utf-8",
            )
            for key, expected in (
                ("smallTrackId", "17"),
                ("largeTrackId", "29"),
                ("staleTrackId", "1000029"),
                ("sourceTrackCount", "158"),
            ):
                completed = subprocess.run(
                    [sys.executable, str(STATE_READER), str(state_file), key],
                    check=True,
                    capture_output=True,
                    text=True,
                    timeout=20,
                )
                self.assertEqual(completed.stdout.strip(), expected)

    def test_old_nested_python_c_pattern_is_absent(self) -> None:
        fragile = re.compile(r"python3?\s+-c\s+[\"']?import\s+json", re.IGNORECASE)
        for path in AUDITED_FILES:
            self.assertIsNone(fragile.search(path.read_text(encoding="utf-8")), path.name)

    def test_powershell_invokes_remote_smoke_file(self) -> None:
        orchestrator = (SCRIPTS / "run_phase45_remote_integration.ps1").read_text(
            encoding="utf-8"
        )
        self.assertGreaterEqual(orchestrator.count("vps_phase45_run_smoke.sh"), 2)
        self.assertNotIn("TRACK_ID=", orchestrator)
        self.assertNotIn("json.load", orchestrator)


if __name__ == "__main__":
    unittest.main()
