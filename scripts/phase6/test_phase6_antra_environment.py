#!/usr/bin/env python3
"""Contrat Antra du fichier d'environnement shadow."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
TEMPLATE = HERE / "api-shadow.env.template"
RENDERER = HERE / "phase6_env.py"
ORCHESTRATOR = HERE / "run_phase6_shadow_deploy.ps1"

AUDIO_SECRET = "A" * 64
AUTH_SECRET = "B" * 96
ANTRA_SECRET = "premium-key-visible-only-inside-test-process"


class AntraEnvironmentContractTest(unittest.TestCase):
    def test_template_declares_the_complete_linux_contract(self) -> None:
        text = TEMPLATE.read_text(encoding="utf-8-sig")
        expected = {
            "ANTRA_DIR": "/opt/homespotify-api-shadow/current/antra-runtime",
            "ANTRA_PYTHON": "/opt/homespotify-api-shadow/current/bin/antra-python",
            "ANTRA_OUTPUT_DIR": "/var/lib/homespotify-shadow/antra/jobs",
            "ANTRA_ENDPOINT_MANIFEST_CACHE_PATH": (
                "/var/lib/homespotify-shadow/antra/endpoint_manifest_cache.json"
            ),
            "PROVIDER_STATS_DB_PATH": (
                "/var/lib/homespotify-shadow/antra/provider_stats.db"
            ),
            "ANTRA_SLSKD_AUTO_BOOTSTRAP": "false",
            "SLSKD_AUTO_BOOTSTRAP": "false",
            "ACQUISITION_LEGACY_ENABLED": "false",
        }
        for key, value in expected.items():
            with self.subTest(key=key):
                self.assertIn(f"{key}={value}", text)
        self.assertIn("ANTRA_API_KEY=__A_INJECTER__", text)

    def test_renderer_injects_three_secrets_without_reporting_them(self) -> None:
        payload = json.dumps({
            "AUDIO_REMOTE_SHARED_SECRET": AUDIO_SECRET,
            "AUTH_TOKEN_SECRET": AUTH_SECRET,
            "ANTRA_API_KEY": ANTRA_SECRET,
        })
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "api-shadow.env"
            result = subprocess.run(
                [sys.executable, str(RENDERER), "--template", str(TEMPLATE), "--out", str(output)],
                input=payload,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(result.stdout.splitlines()[-1])
            self.assertTrue(report["ok"])
            self.assertEqual(report["secretCount"], 3)
            self.assertEqual(report["secretsPrinted"], 0)
            serialized = json.dumps(report)
            for secret in (AUDIO_SECRET, AUTH_SECRET, ANTRA_SECRET):
                self.assertNotIn(secret, serialized)
            rendered = output.read_text(encoding="utf-8")
            self.assertIn(f"ANTRA_API_KEY={ANTRA_SECRET}", rendered)

    def test_orchestrator_reads_antra_key_without_argv_or_output(self) -> None:
        text = ORCHESTRATOR.read_text(encoding="utf-8-sig")
        self.assertIn("$AntraEnvPath", text)
        self.assertIn(
            "Read-SecretFromEnvFile `\n            -Path $AntraEnvPath `\n            -Key 'ANTRA_API_KEY'",
            text,
        )
        self.assertIn("ANTRA_API_KEY = (ConvertFrom-SecureStringPlain", text)
        self.assertIn("Prompt 'ANTRA_API_KEY (Premium Antra)'", text)
        self.assertNotIn("-AntraApiKey", text)
        self.assertNotIn("--antra-api-key", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
