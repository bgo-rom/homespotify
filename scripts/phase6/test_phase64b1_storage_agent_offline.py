from __future__ import annotations

import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent
SCRIPT = ROOT / "run_phase64b1_storage_agent_offline_test.ps1"
CODE = SCRIPT.read_text(encoding="utf-8")
POWERSHELL = shutil.which("powershell") or shutil.which("pwsh")


def run_scenario(
    scenario: str,
    *,
    validate_only: bool = False,
) -> tuple[subprocess.CompletedProcess[str], dict, Path]:
    temp = Path(tempfile.mkdtemp(prefix="phase64b1b-test-"))
    command = [
        POWERSHELL,
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(SCRIPT),
        "-SshKeyPath",
        "unused",
        "-OutputDirectory",
        str(temp),
        "-SelfTest",
        "-SelfTestScenario",
        scenario,
    ]
    if validate_only:
        command.append("-ValidateOnly")
    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    summary_path = temp / "phase64b1b-summary.json"
    if summary_path.is_file():
        summary = json.loads(summary_path.read_text())
    else:
        json_lines = [
            line for line in result.stdout.splitlines()
            if line.strip().startswith("{")
        ]
        summary = json.loads(json_lines[-1])
    return result, summary, temp


@unittest.skipUnless(POWERSHELL, "PowerShell is required")
class OfflineOwnerScriptTest(unittest.TestCase):
    def tearDown(self) -> None:
        for path in getattr(self, "temporary_paths", []):
            shutil.rmtree(path, ignore_errors=True)

    def capture(self, scenario: str, *, validate_only: bool = False):
        result, summary, temp = run_scenario(
            scenario, validate_only=validate_only
        )
        self.temporary_paths = getattr(self, "temporary_paths", []) + [temp]
        return result, summary, temp

    def test_non_elevated_returns_elevation_required_without_side_effect(self) -> None:
        result, summary, temp = self.capture("NonElevated")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(summary["verdict"], "ELEVATION_REQUIRED")
        self.assertFalse(summary["elevationConfirmed"])
        self.assertEqual(summary["stopCalls"], 0)
        self.assertEqual(summary["startCalls"], 0)
        self.assertEqual(summary["sshConnectionsOpened"], 0)
        self.assertEqual(list(temp.iterdir()), [])

    def test_validate_only_never_stops_the_agent(self) -> None:
        result, summary, _ = self.capture("Healthy", validate_only=True)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(summary["verdict"], "GO_VALIDATE_ONLY")
        self.assertEqual(summary["stopCalls"], 0)
        self.assertEqual(summary["startCalls"], 0)
        self.assertEqual(summary["serviceAgentFinalState"], "Running")

    def test_finally_restarts_after_success(self) -> None:
        result, summary, _ = self.capture("Healthy")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(summary["verdict"], "GO")
        self.assertTrue(summary["serviceAgentStopped"])
        self.assertEqual(summary["stopCalls"], 1)
        self.assertEqual(summary["startCalls"], 1)
        self.assertEqual(summary["serviceAgentFinalState"], "Running")
        self.assertLess(summary["downtimeSeconds"], 90)
        self.assertTrue(summary["cachedOffline"])
        self.assertTrue(summary["uncachedOffline"])
        self.assertEqual(summary["offlineHttpStatus"], 503)
        self.assertTrue(summary["fillAfterRecovery"])
        self.assertTrue(summary["finalHit"])
        self.assertEqual(summary["partFilesBefore"], 0)
        self.assertEqual(summary["partFilesAfter"], 0)
        self.assertEqual(summary["publicHealthDuring"], 200)
        self.assertEqual(summary["shadowHealthDuring"], 200)

    def test_finally_restarts_after_exception(self) -> None:
        result, summary, _ = self.capture("ExceptionAfterStop")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(summary["verdict"], "NO_GO")
        self.assertEqual(summary["stopCalls"], 1)
        self.assertEqual(summary["startCalls"], 1)
        self.assertEqual(summary["serviceAgentFinalState"], "Running")
        self.assertIn("SIMULATED_OFFLINE_EXCEPTION", summary["failureReason"])

    def test_cached_track_must_be_a_proven_hit(self) -> None:
        result, summary, _ = self.capture("CachedMiss")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(summary["stopCalls"], 0)
        self.assertIn("cachedHead", summary["failureReason"])

    def test_uncached_track_must_return_503(self) -> None:
        result, summary, _ = self.capture("UncachedUnexpectedSuccess")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(summary["offlineHttpStatus"], 206)
        self.assertIn("UNCACHED_OFFLINE_STATUS_206", summary["failureReason"])
        self.assertEqual(summary["serviceAgentFinalState"], "Running")

    def test_no_part_file_is_accepted(self) -> None:
        result, summary, _ = self.capture("PartResidual")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("UNCACHED_CACHE_RESIDUE", summary["failureReason"])
        self.assertEqual(summary["serviceAgentFinalState"], "Running")

    def test_fill_is_required_after_recovery(self) -> None:
        result, summary, _ = self.capture("FillMissing")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("RECOVERY_FILL_FAILED", summary["failureReason"])

    def test_final_hit_is_required(self) -> None:
        result, summary, _ = self.capture("FinalHitMissing")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("RECOVERY_FINAL_HIT_FAILED", summary["failureReason"])

    def test_reports_are_complete_and_sanitized(self) -> None:
        _, summary, temp = self.capture("Healthy")
        required = {
            "verdict", "elevationConfirmed", "serviceAgentInitialState",
            "serviceAgentStopped", "serviceAgentFinalState",
            "productionApiInitialState", "productionApiFinalState",
            "downtimeSeconds", "cachedTrackId", "uncachedTrackId",
            "cachedOffline", "uncachedOffline", "offlineHttpStatus",
            "fillAfterRecovery", "finalHit", "partFilesBefore",
            "partFilesAfter", "publicHealthBefore", "publicHealthDuring",
            "publicHealthAfter", "shadowHealthBefore", "shadowHealthDuring",
            "shadowHealthAfter", "serviceEnabled", "rebootPerformed",
            "publicCutoverPerformed", "secretsPrinted",
        }
        self.assertTrue(required.issubset(summary))
        for filename in (
            "phase64b1b-summary.json",
            "requests.jsonl",
            "events-sanitized.jsonl",
            "PHASE64B1B_STORAGE_AGENT_OFFLINE_REPORT.md",
        ):
            self.assertTrue((temp / filename).is_file())
        joined = "\n".join(
            path.read_text(encoding="ascii")
            for path in temp.iterdir()
            if path.is_file()
        )
        self.assertNotRegex(joined, re.compile(r"Authorization:\s*Bearer", re.I))
        self.assertNotRegex(joined, re.compile(r"eyJ[A-Za-z0-9_-]+\.", re.I))
        self.assertFalse(summary["secretsPrinted"])

    def test_self_tests_open_no_ssh_connection(self) -> None:
        for scenario in (
            "Healthy", "ExceptionAfterStop", "CachedMiss",
            "UncachedUnexpectedSuccess", "PartResidual",
            "FillMissing", "FinalHitMissing",
        ):
            with self.subTest(scenario=scenario):
                _, summary, _ = self.capture(scenario)
                self.assertEqual(summary["sshConnectionsOpened"], 0)


class StaticSafetyContractTest(unittest.TestCase):
    def test_owner_parameters_and_defaults_are_present(self) -> None:
        for fragment in (
            "$VpsHost = '135.125.101.79'",
            "$VpsUser = 'debian'",
            "[string] $SshKeyPath",
            "[string] $OutputDirectory",
            "$StorageAgentServiceName = 'HomeSpotifyStorageAgent'",
            "$ProductionApiServiceName = 'HomeSpotifyApi'",
            "$MaxAgentDowntimeSeconds = 90",
            "$CachedTrackId = 119",
            "[switch] $ValidateOnly",
        ):
            self.assertIn(fragment, CODE)

    def test_only_storage_agent_can_be_stopped(self) -> None:
        stop_commands = re.findall(r"Stop-Service[^\r\n]+", CODE)
        self.assertEqual(len(stop_commands), 1)
        self.assertIn("$expectedStorageAgentService", stop_commands[0])
        self.assertNotIn("$ProductionApiServiceName", stop_commands[0])
        self.assertNotIn("HomeSpotifyApi", stop_commands[0])

    def test_production_api_can_never_be_stopped(self) -> None:
        self.assertNotRegex(
            CODE,
            re.compile(r"Stop-Service[^\r\n]*HomeSpotifyApi", re.I),
        )
        self.assertNotIn("Restart-Service", CODE)

    def test_maximum_downtime_is_90_seconds(self) -> None:
        self.assertIn("[ValidateRange(1, 90)]", CODE)
        self.assertIn("$MaxAgentDowntimeSeconds = 90", CODE)
        self.assertIn("Assert-DowntimeBudget 45", CODE)
        self.assertIn("signal.alarm(35)", CODE)

    def test_no_silent_elevation_or_acl_change(self) -> None:
        for forbidden in (
            "Verb RunAs", "Start-Process", "sc.exe sdset", "Set-Acl",
            "systemctl enable", "caddy reload",
        ):
            self.assertNotIn(forbidden, CODE)
        self.assertNotRegex(CODE, re.compile(r"(?m)^\s*reboot(?:\.exe)?\b", re.I))

    def test_dynamic_uncached_selection_is_not_track_one(self) -> None:
        helper = CODE.split("$script:remoteHelperSource = @'", 1)[1].split(
            "'@", 1
        )[0]
        self.assertIn("select_uncached", helper)
        self.assertIn("if not object_path(item).exists()", helper)
        self.assertNotIn("uncached_track_id = 1", helper)

    def test_remote_events_are_correlated_and_sanitized(self) -> None:
        self.assertIn('record.get("requestId") != request_id', CODE)
        self.assertIn('"level": record.get("level", 30)', CODE)
        self.assertNotIn('"Authorization"', CODE.split(
            "$script:remoteHelperSource = @'", 1
        )[0])

    def test_embedded_python_helper_compiles(self) -> None:
        helper = CODE.split("$script:remoteHelperSource = @'", 1)[1].split(
            "'@", 1
        )[0]
        compile(helper, str(SCRIPT), "exec")


if __name__ == "__main__":
    unittest.main()
