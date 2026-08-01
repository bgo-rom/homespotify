#!/usr/bin/env python3
"""Local regression tests for the owner-run Phase 6.4A soak harness.

No test opens an SSH connection. Runtime behavior is exercised only through
the explicit local ValidateOnly and SelfTest modes.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "run_phase64a_soak.ps1"


def read() -> str:
    return SCRIPT.read_text(encoding="utf-8-sig")


def powershell(*arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            "powershell",
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(SCRIPT),
            *arguments,
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )


class ParameterAndSafetyTest(unittest.TestCase):
    def test_duration_below_120_is_refused(self) -> None:
        result = powershell(
            "-SshKeyPath", "unused",
            "-OutputDirectory", "unused",
            "-DurationMinutes", "119",
            "-ValidateOnly",
        )
        self.assertNotEqual(result.returncode, 0)

    def test_validate_only_never_connects(self) -> None:
        result = powershell(
            "-SshKeyPath", "definitely-does-not-exist",
            "-OutputDirectory", "unused",
            "-ValidateOnly",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(payload["sshConnectionsOpened"], 0)

    def test_embedded_remote_helper_parses_as_python(self) -> None:
        code = read()
        match = re.search(
            r"\$script:RemoteHelperSource = @'\n(.*?)\n'@",
            code,
            re.DOTALL,
        )
        self.assertIsNotNone(match)
        result = subprocess.run(
            [sys.executable, "-c", "import ast,sys; ast.parse(sys.stdin.read())"],
            input=match.group(1),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_key_is_never_read_or_printed(self) -> None:
        code = read()
        for forbidden in (
            "Get-Content -LiteralPath $SshKeyPath",
            "ReadAllText($SshKeyPath",
            "Write-Host $SshKeyPath",
            "Write-Output $SshKeyPath",
        ):
            self.assertNotIn(forbidden, code)
        self.assertIn("'-i', $SshKeyPath", code)

    def test_no_secret_value_is_put_in_remote_arguments(self) -> None:
        code = read()
        self.assertNotRegex(code, r"RemoteCommand\s+.*\$(?:token|secret)")
        self.assertNotIn("AUTH_TOKEN_SECRET=", code)
        self.assertNotIn("AUDIO_REMOTE_SHARED_SECRET=", code)
        self.assertIn("/etc/homespotify/api-shadow.env", code)

    def test_ssh_protections_are_explicit(self) -> None:
        code = read()
        for required in (
            "BatchMode=yes",
            "ConnectTimeout=15",
            "ServerAliveInterval=20",
            "ServerAliveCountMax=3",
        ):
            self.assertIn(required, code)
        for forbidden in ("StrictHostKeyChecking=no", "UserKnownHostsFile=/dev/null"):
            self.assertNotIn(forbidden, code)

    def test_no_repair_or_production_mutation_commands_exist(self) -> None:
        code = read()
        for forbidden in (
            "systemctl restart",
            "systemctl start",
            "systemctl stop",
            "systemctl enable",
            "systemctl reboot",
            "shutdown.exe",
            "Restart-Service",
            "Stop-Service",
            "Start-Service",
            "caddy reload",
        ):
            self.assertNotIn(forbidden, code)


class DetectionAndReportTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = Path(tempfile.mkdtemp(prefix="phase64a-test-"))

    def tearDown(self) -> None:
        shutil.rmtree(self.temp, ignore_errors=True)

    def run_scenario(self, scenario: str) -> tuple[subprocess.CompletedProcess[str], dict]:
        output = self.temp / scenario
        result = powershell(
            "-SshKeyPath", "unused",
            "-OutputDirectory", str(output),
            "-SelfTest",
            "-SelfTestScenario", scenario,
        )
        summary = json.loads((output / "phase64a-summary.json").read_text())
        return result, summary

    def test_public_listener_is_detected(self) -> None:
        _, summary = self.run_scenario("PublicListener")
        self.assertEqual(summary["verdict"], "NO_GO")
        self.assertIn("listener anomaly", summary["failureReason"])

    def test_pid_change_is_detected(self) -> None:
        _, summary = self.run_scenario("PidChanged")
        self.assertEqual(summary["verdict"], "NO_GO")
        self.assertIn("MainPID changed", summary["failureReason"])

    def test_restart_is_detected(self) -> None:
        _, summary = self.run_scenario("Restarted")
        self.assertEqual(summary["verdict"], "NO_GO")
        self.assertIn("NRestarts increased", summary["failureReason"])

    def test_no_go_is_bounded_and_reports_are_written(self) -> None:
        _, summary = self.run_scenario("PidChanged")
        self.assertEqual(summary["sampleCount"], 2)
        for name in (
            "samples.csv",
            "requests.jsonl",
            "events-sanitized.jsonl",
            "phase64a-summary.json",
            "PHASE64A_SOAK_REPORT.md",
        ):
            self.assertTrue((self.temp / "PidChanged" / name).is_file(), name)

    def test_interruption_requires_a_full_restart(self) -> None:
        _, summary = self.run_scenario("Interrupted")
        self.assertEqual(summary["verdict"], "INCOMPLETE_RESTART_REQUIRED")

    def test_memorymax_is_derived_from_observed_peak(self) -> None:
        _, summary = self.run_scenario("Healthy")
        memory = summary["memoryMaxRecommendation"]
        self.assertEqual(memory["peakRssKiB"], 126224)
        self.assertGreaterEqual(memory["marginX2MiB"], 2 * 126224 / 1024)
        self.assertGreaterEqual(memory["marginX3MiB"], 3 * 126224 / 1024)
        self.assertGreaterEqual(memory["finalMiB"], memory["marginX3MiB"])

    def test_reports_never_contain_a_token_or_authorization_header(self) -> None:
        self.run_scenario("Healthy")
        joined = "\n".join(
            path.read_text(encoding="ascii")
            for path in (self.temp / "Healthy").iterdir()
            if path.is_file()
        )
        self.assertNotRegex(joined, re.compile(r"Authorization:\s*Bearer", re.I))
        self.assertNotRegex(joined, re.compile(r"eyJ[A-Za-z0-9_-]+\.", re.I))


class CleanupContractTest(unittest.TestCase):
    def test_finally_removes_only_remote_temporary_files(self) -> None:
        code = read()
        finally_block = code[code.rindex("} finally {") :]
        self.assertIn("$script:RemoteTokenPath", finally_block)
        self.assertIn("$script:RemoteHelperPath", finally_block)
        self.assertIn("sudo -n rm -f --", finally_block)
        self.assertNotIn("Remove-Item", finally_block)

    def test_listener_pid_restart_and_reports_are_contractual(self) -> None:
        code = read()
        for required in (
            "publicListenerCount",
            "MainPID changed",
            "NRestarts increased",
            "INCOMPLETE_RESTART_REQUIRED",
            "samples.csv",
            "requests.jsonl",
            "events-sanitized.jsonl",
            "phase64a-summary.json",
            "PHASE64A_SOAK_REPORT.md",
        ):
            self.assertIn(required, code)


if __name__ == "__main__":
    unittest.main(verbosity=2)
