#!/usr/bin/env python3
"""Régression du packaging local d'Antra dans l'artefact HomeSpotify."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import phase6_manifest as manifest


HERE = Path(__file__).resolve().parent
BUILD = HERE / "build_shadow_artifact.ps1"
BUILD_MANIFEST = HERE / "phase6_build_manifest.py"

ANTRA_COMMIT = "dbce23c5960af504d672cc28c7c51ece0bea8e68"
REQUIREMENTS_SHA256 = (
    "6d0ced20523398f2d2b24d849588957006b4d721130989c9fd40c7a588e8a589"
)
RUNTIME_ID = "py311-antra-dbce23c5-6d0ced20"


class AntraArtifactManifestTest(unittest.TestCase):
    def test_runtime_paths_are_kept_and_sensitive_paths_are_excluded(self) -> None:
        self.assertFalse(
            manifest.is_excluded("antra-runtime/antra/json_cli.py")
        )
        self.assertFalse(
            manifest.is_excluded(
                "antra-runtime/requirements-homespotify-vps.txt"
            )
        )
        self.assertFalse(
            manifest.is_excluded("antra-runtime/runtime.json")
        )
        self.assertFalse(
            manifest.is_excluded("bin/antra-python")
        )

        for forbidden in (
            "antra-runtime/.env",
            "antra-runtime/provider_stats.db",
            "antra-runtime/endpoint_manifest_cache.json",
            "antra-runtime/antra/__pycache__/x.pyc",
        ):
            with self.subTest(path=forbidden):
                self.assertTrue(manifest.is_excluded(forbidden))

    def test_manifest_reports_the_qualified_antra_runtime(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "dist").mkdir()
            (root / "dist" / "server.js").write_text(
                "export {};",
                encoding="utf-8",
            )
            (root / "antra-runtime").mkdir()
            (root / "antra-runtime" / "runtime.json").write_text(
                json.dumps({"runtimeId": RUNTIME_ID}),
                encoding="utf-8",
            )

            built = manifest.build_manifest(
                root,
                commit="a" * 40,
                built_at="20260802T220000Z",
                node_version="v22.18.0",
                node_abi="127",
                arch="x64",
                bundle_id="linux-x64-node22.18.0-abi127",
                antra_commit=ANTRA_COMMIT,
                antra_requirements_sha256=REQUIREMENTS_SHA256,
                antra_runtime_id=RUNTIME_ID,
            )

        self.assertEqual(built["antraCommit"], ANTRA_COMMIT)
        self.assertEqual(
            built["antraRequirementsSha256"],
            REQUIREMENTS_SHA256,
        )
        self.assertEqual(built["antraRuntimeId"], RUNTIME_ID)
        self.assertIn(
            "antra-runtime/runtime.json",
            {entry["path"] for entry in built["files"]},
        )

    def test_build_script_pins_and_copies_the_nested_repository(self) -> None:
        text = BUILD.read_text(encoding="utf-8")

        self.assertIn(ANTRA_COMMIT, text)
        self.assertIn(REQUIREMENTS_SHA256, text)
        self.assertIn(RUNTIME_ID, text)
        self.assertIn("ls-files", text)
        self.assertIn("'antra'", text)
        self.assertIn(
            "'requirements-homespotify-vps.txt'",
            text,
        )
        self.assertIn("worktree Antra non propre", text)
        self.assertIn("copie Antra divergente", text)
        self.assertIn("runtime.json", text)
        self.assertIn("binDirectory", text)

        self.assertNotIn(
            "Copy-Item -Recurse -Force -LiteralPath $AntraRoot",
            text,
        )

    def test_linux_launcher_targets_the_immutable_python_runtime(self) -> None:
        text = BUILD.read_text(encoding="utf-8")

        expected = (
            "/opt/homespotify-api-shadow/python-runtimes/"
            f"{RUNTIME_ID}/venv/bin/python"
        )

        self.assertIn(expected, text)
        self.assertIn('exec "', text)
        self.assertIn('"$@"', text)
        self.assertNotIn("$launcherTemplate = @'", text)

    def test_manifest_cli_requires_antra_metadata(self) -> None:
        text = BUILD_MANIFEST.read_text(encoding="utf-8")

        for argument in (
            "--antra-commit",
            "--antra-requirements-sha256",
            "--antra-runtime-id",
        ):
            self.assertIn(argument, text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
