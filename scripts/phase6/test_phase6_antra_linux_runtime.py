#!/usr/bin/env python3
"""Contrat du runtime Python Linux immuable d'Antra."""

from __future__ import annotations

import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
PREPARE = HERE / "vps_phase6_prepare_antra_runtime.sh"
SETUP = HERE / "vps_phase6_systemd_setup.sh"
ACTIVATE = HERE / "vps_phase6_activate_shadow.sh"
ORCHESTRATOR = HERE / "run_phase6_shadow_deploy.ps1"


class AntraLinuxRuntimeTest(unittest.TestCase):
    def test_prepare_uses_an_atomic_immutable_runtime(self) -> None:
        text = PREPARE.read_text(encoding="utf-8")
        self.assertIn("/opt/homespotify-api-shadow", text)
        self.assertIn("python-runtimes", text)
        self.assertIn(".incoming-${RUNTIME_ID}-$$", text)
        self.assertIn('mv -T "${INCOMING}" "${TARGET}"', text)
        self.assertIn("runtime-meta.json", text)
        self.assertIn("pip-freeze.txt", text)
        self.assertIn("pipFreezeSha256", text)
        self.assertNotIn("/current", text)

    def test_dependencies_are_installed_non_interactively(self) -> None:
        text = PREPARE.read_text(encoding="utf-8")
        self.assertIn("--install-system-packages", text)
        self.assertIn("DEBIAN_FRONTEND=noninteractive", text)
        self.assertIn("--no-install-recommends", text)
        self.assertIn("python3 -m venv", text)
        self.assertIn("-m pip install", text)
        self.assertIn("--no-input", text)
        self.assertIn("--no-cache-dir", text)
        self.assertNotIn("npm install", text)
        self.assertNotIn("playwright install", text)

    def test_ffmpeg_and_python_are_blocking_requirements(self) -> None:
        text = PREPARE.read_text(encoding="utf-8")
        self.assertIn("command -v ffmpeg", text)
        self.assertIn("command -v ffprobe", text)
        self.assertIn("PYTHON_VERSION_INATTENDUE", text)
        self.assertIn("requiredPythonVersion", text)
        self.assertIn("requiredSystemCommands", text)

    def test_no_secret_or_service_is_started_by_preparation(self) -> None:
        text = PREPARE.read_text(encoding="utf-8")
        self.assertNotIn("ANTRA_API_KEY=", text)
        self.assertNotIn("systemctl start", text)
        self.assertNotIn("systemctl restart", text)
        self.assertNotIn("Caddyfile", text)
        self.assertNotIn("iptables", text)
        self.assertIn('"serviceStarted":false', text)
        self.assertIn('"currentChanged":false', text)

    def test_systemd_setup_creates_bounded_runtime_state(self) -> None:
        text = SETUP.read_text(encoding="utf-8")
        self.assertIn('"${ROOT}/python-runtimes"', text)
        for relative in (
            "${STATE}/antra",
            "${STATE}/antra/jobs",
            "${STATE}/antra/home",
            "${STATE}/antra/home/.cache",
            "${STATE}/antra/home/.local/share",
        ):
            self.assertIn(relative, text)

    def test_activation_rechecks_runtime_before_current(self) -> None:
        text = ACTIVATE.read_text(encoding="utf-8")
        runtime_check = text.index("RUNTIME_DESCRIPTOR=")
        current_switch = text.index(
            'ln -sfn "${TARGET}" "${ROOT}/current.new"'
        )
        self.assertLess(runtime_check, current_switch)
        self.assertIn("RUNTIME_CIBLE_ABSENTE", text)
        self.assertIn("FFMPEG_ABSENT", text)
        self.assertIn("FFPROBE_ABSENT", text)
        self.assertIn("SMOKE_ANTRA_ECHEC", text)
        self.assertIn(
            'chmod 0750 "${INCOMING}/bin/antra-python"',
            text,
        )

    def test_orchestrator_prepares_before_activation(self) -> None:
        text = ORCHESTRATOR.read_text(encoding="utf-8-sig")
        self.assertIn("vps_phase6_prepare_antra_runtime.sh", text)
        prepare = text.index("étape 4 bis — runtime Python Linux Antra")
        activate = text.index("étape 5 — installation atomique")
        self.assertLess(prepare, activate)
        self.assertIn("--install-system-packages", text)
        self.assertIn(
            "antraRuntime = $report['antraRuntime']",
            text,
        )



class AntraVenvProbeRegressionTest(unittest.TestCase):
    def test_venv_support_is_probed_by_real_creation(self) -> None:
        script = (
            __import__("pathlib").Path(__file__).with_name(
                "vps_phase6_prepare_antra_runtime.sh"
            )
        ).read_text(encoding="utf-8")
        self.assertIn(
            'VENV_PACKAGE="python${REQUIRED_PYTHON}-venv"',
            script,
        )
        self.assertIn("probe_venv() {", script)
        self.assertIn(
            'probe_venv || need_packages+=("${VENV_PACKAGE}")',
            script,
        )
        self.assertIn(
            'probe_venv || fail VENV_ABSENT "${VENV_PACKAGE}"',
            script,
        )
        self.assertNotIn("python3 -m venv --help", script)


class AntraRuntimeFileCountContractRegressionTest(unittest.TestCase):
    # Le build et le validateur Linux doivent partager le même contrat.

    @staticmethod
    def _build_count() -> int:
        import re
        from pathlib import Path
        path = Path(__file__).resolve().with_name(
            "build_shadow_artifact.ps1"
        )
        matches = re.findall(
            r"\$ExpectedRuntimeFileCount\s*=\s*(\d+)",
            path.read_text(encoding="utf-8-sig"),
        )
        if len(matches) != 1:
            raise AssertionError(f"contrat build ambigu : {matches!r}")
        return int(matches[0])

    @staticmethod
    def _prepare_count() -> int:
        import re
        from pathlib import Path
        path = Path(__file__).resolve().with_name(
            "vps_phase6_prepare_antra_runtime.sh"
        )
        lines = path.read_text(encoding="utf-8").splitlines()
        found: list[int] = []
        for marker_index, marker in enumerate(lines):
            if "trackedRuntimeFileCount" not in marker:
                continue
            for line in lines[
                max(0, marker_index - 3):
                min(len(lines), marker_index + 4)
            ]:
                found.extend(
                    int(value)
                    for value in re.findall(
                        r"(?<!\d)(67|69)(?!\d)", line
                    )
                )
        unique = sorted(set(found))
        if len(unique) != 1:
            raise AssertionError(f"contrat prepare ambigu : {unique!r}")
        return unique[0]

    def test_build_and_prepare_counts_match(self) -> None:
        self.assertEqual(self._build_count(), self._prepare_count())

    def test_current_count_is_69(self) -> None:
        self.assertEqual(self._build_count(), 69)
        self.assertEqual(self._prepare_count(), 69)

if __name__ == "__main__":
    unittest.main(verbosity=2)
