#!/usr/bin/env python3
"""Local regression tests for the owner-run Phase 6.4A soak harness.

No test opens an SSH connection. Runtime behavior uses SelfTest or the
extracted helper; the remote ValidateOnly contract is checked statically.
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


def embedded_helper() -> str:
    match = re.search(
        r"\$script:RemoteHelperSource = @'\n(.*?)\n'@",
        read(),
        re.DOTALL,
    )
    if match is None:
        raise AssertionError("embedded helper not found")
    return match.group(1)


def helper_namespace() -> dict:
    namespace = {"__name__": "phase64a_embedded_helper"}
    exec(compile(embedded_helper(), "<phase64a-helper>", "exec"), namespace)
    namespace["JOURNAL_POLL_SECONDS"] = 0
    return namespace


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

    def test_validate_only_runs_preflight_without_starting_soak(self) -> None:
        code = read()
        validate_block = code[
            code.index("if ($ValidateOnly) {") :
            code.index("if ($SelfTest) {")
        ]
        self.assertIn("New-ShadowToken", validate_block)
        self.assertIn("Invoke-RemoteMode -Mode 'preflight'", validate_block)
        self.assertIn("Assert-RequestRecord $validateJournalRecord", validate_block)
        self.assertIn("Assert-Preflight", validate_block)
        self.assertIn("soakStarted = $false", validate_block)
        self.assertNotIn("$deadline", validate_block)

    def test_embedded_remote_helper_parses_as_python(self) -> None:
        result = subprocess.run(
            [sys.executable, "-c", "import ast,sys; ast.parse(sys.stdin.read())"],
            input=embedded_helper(),
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
        self.assertNotIn("AUTH_TOKEN_" + "SECRET=", code)
        self.assertNotIn("AUDIO_REMOTE_SHARED_" + "SECRET=", code)
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

    def test_sanitized_events_survive_an_early_failure(self) -> None:
        _, summary = self.run_scenario("EvidenceFailure")
        output = self.temp / "EvidenceFailure"
        self.assertEqual(summary["verdict"], "NO_GO")
        self.assertGreater((output / "requests.jsonl").stat().st_size, 0)
        events = (output / "events-sanitized.jsonl").read_text(encoding="ascii")
        self.assertIn("REMOTE_STORAGE_REQUEST_STARTED", events)


class JournalEvidenceRegressionTest(unittest.TestCase):
    @staticmethod
    def _http_result(request_id: str, status: int = 200) -> dict:
        return {
            "status": status,
            "sizeBytes": 0,
            "sha256": "",
            "requestId": request_id,
            "contentRange": None,
            "elapsedMs": 1.0,
        }

    def test_iso_timestamp_is_normalized_for_journalctl(self) -> None:
        helper = helper_namespace()
        self.assertEqual(
            helper["normalize_journal_since"]("2026-07-28T20:15:16.123Z"),
            "2026-07-28 20:15:16 UTC",
        )

    def test_nonzero_journalctl_exit_is_not_an_empty_journal(self) -> None:
        helper = helper_namespace()
        helper["run"] = lambda *_args, **_kwargs: (1, "", "generic failure")
        result = helper["journal_query"]("2026-07-28T20:15:16Z")
        self.assertFalse(result["ok"])
        self.assertEqual(result["journalReadable"], "unknown")
        self.assertEqual(result["logEvidenceAvailable"], "unknown")
        self.assertEqual(result["verdict"], "JOURNALCTL_FAILED")

    def test_permission_denied_is_classified_without_exposing_stderr(self) -> None:
        helper = helper_namespace()
        secret_stderr = "Permission denied Authorization: Bearer should-not-leak"
        helper["run"] = lambda *_args, **_kwargs: (1, "", secret_stderr)
        result = helper["journal_query"]("2026-07-28T20:15:16Z")
        self.assertEqual(result["verdict"], "JOURNAL_PERMISSION_DENIED")
        self.assertNotIn("stderr", result)
        self.assertNotIn("should-not-leak", json.dumps(result))

    def test_unavailable_unit_or_journal_has_explicit_safe_cause(self) -> None:
        helper = helper_namespace()
        helper["run"] = lambda *_args, **_kwargs: (
            1, "", "Failed to open journal: unavailable"
        )
        result = helper["journal_query"]("2026-07-28T20:15:16Z")
        self.assertEqual(result["verdict"], "LOG_EVIDENCE_UNAVAILABLE")
        self.assertEqual(result["failureKind"], "unit_or_journal_unavailable")

    def test_readable_empty_journal_is_distinct_from_failure(self) -> None:
        helper = helper_namespace()
        helper["run"] = lambda *_args, **_kwargs: (0, "", "")
        result = helper["journal_query"]("2026-07-28T20:15:16Z")
        self.assertTrue(result["ok"])
        self.assertTrue(result["journalReadable"])
        self.assertFalse(result["logEvidenceAvailable"])

    def test_health_200_needs_no_request_id_event(self) -> None:
        helper = helper_namespace()
        polled = []
        helper["journal_query"] = lambda _since: {
            "ok": True, "lines": [], "returnCode": 0,
            "journalReadable": True, "logEvidenceAvailable": False,
            "verdict": None, "failureKind": None,
        }
        helper["http_request"] = lambda method, path, token="": (
            self._http_result("health-no-event")
            if path == "/health"
            else self._http_result("cached-head")
        )

        def poll(request_id: str, _since: str, expected_hit: bool = True) -> dict:
            polled.append((request_id, expected_hit))
            return {
                "cacheHit": True, "remoteStorageStarted": False,
                "journalReadable": True, "logEvidenceAvailable": True,
                "verdict": None,
                "events": [{"requestId": request_id, "event": "CACHE_HIT"}],
            }

        helper["poll_request_evidence"] = poll
        result = helper["journal_preflight"]("temporary-shadow-token")
        self.assertEqual(result["healthStatus"], 200)
        self.assertEqual(polled, [("cached-head", True)])
        self.assertEqual(result["probe"]["name"], "journalCachedHeadProbe")

    def test_cached_head_produces_exact_cache_hit_evidence(self) -> None:
        helper = helper_namespace()
        helper["http_request"] = lambda *_args, **_kwargs: self._http_result(
            "cached-head"
        )
        helper["poll_request_evidence"] = lambda request_id, _since: {
            "cacheHit": request_id == "cached-head",
            "remoteStorageStarted": False,
            "journalReadable": True,
            "logEvidenceAvailable": True,
            "verdict": None,
            "events": [{"requestId": request_id, "event": "CACHE_HIT"}],
        }
        result = helper["request_operation"](
            "head-hit", "temporary-shadow-token", "2026-07-29T00:00:00Z"
        )
        self.assertEqual(result["name"], "headHit")
        self.assertIs(result["cacheHit"], True)
        self.assertIs(result["remoteStorageStarted"], False)

    def test_timeout_applies_to_cached_head_not_health(self) -> None:
        helper = helper_namespace()
        polled = []
        helper["journal_query"] = lambda _since: {
            "ok": True, "lines": [], "returnCode": 0,
            "journalReadable": True, "logEvidenceAvailable": False,
            "verdict": None, "failureKind": None,
        }
        helper["http_request"] = lambda method, path, token="": (
            self._http_result("health-no-event")
            if path == "/health"
            else self._http_result("missing-cached-head")
        )

        def timeout(request_id: str, _since: str, expected_hit: bool = True) -> dict:
            polled.append(request_id)
            return {
                "cacheHit": "unknown", "remoteStorageStarted": "unknown",
                "journalReadable": True, "logEvidenceAvailable": False,
                "verdict": "JOURNAL_EVENT_TIMEOUT", "events": [],
            }

        helper["poll_request_evidence"] = timeout
        result = helper["journal_preflight"]("temporary-shadow-token")
        self.assertEqual(result["healthStatus"], 200)
        self.assertEqual(polled, ["missing-cached-head"])
        self.assertEqual(result["verdict"], "JOURNAL_EVENT_TIMEOUT")

    def test_delayed_event_is_found_by_bounded_polling(self) -> None:
        helper = helper_namespace()
        request_id = "phase64a-delayed"
        calls = {"count": 0}

        def delayed(_since: str) -> dict:
            calls["count"] += 1
            lines = []
            if calls["count"] == 3:
                lines = [json.dumps({"requestId": request_id, "event": "CACHE_HIT"})]
            return {
                "ok": True, "lines": lines, "returnCode": 0,
                "journalReadable": True,
                "logEvidenceAvailable": bool(lines), "verdict": None,
            }

        helper["journal_query"] = delayed
        result = helper["poll_request_evidence"](request_id, "-")
        self.assertEqual(calls["count"], 3)
        self.assertIs(result["cacheHit"], True)
        self.assertIs(result["remoteStorageStarted"], False)

    def test_exact_cache_hit_is_detected(self) -> None:
        result = self._poll_with_events([
            {"requestId": "wanted", "event": "CACHE_HIT"},
        ])
        self.assertIs(result["cacheHit"], True)
        self.assertIs(result["remoteStorageStarted"], False)

    def test_exact_remote_start_is_detected(self) -> None:
        result = self._poll_with_events([
            {"requestId": "wanted", "event": "REMOTE_STORAGE_REQUEST_STARTED"},
        ])
        self.assertIs(result["remoteStorageStarted"], True)
        self.assertEqual(
            result["verdict"], "REMOTE_CONTACT_OBSERVED_ON_EXPECTED_HIT"
        )

    def test_other_request_id_is_ignored(self) -> None:
        result = self._poll_with_events([
            {"requestId": "other", "event": "REMOTE_STORAGE_REQUEST_STARTED"},
            {"requestId": "wanted", "event": "CACHE_HIT"},
        ])
        self.assertIs(result["cacheHit"], True)
        self.assertIs(result["remoteStorageStarted"], False)

    def test_unavailable_journal_produces_unknown_never_false(self) -> None:
        helper = helper_namespace()
        helper["journal_query"] = lambda _since: {
            "ok": False, "lines": [], "returnCode": 2,
            "journalReadable": "unknown",
            "logEvidenceAvailable": "unknown",
            "verdict": "LOG_EVIDENCE_UNAVAILABLE",
        }
        result = helper["poll_request_evidence"]("wanted", "-")
        for field in (
            "cacheHit", "remoteStorageStarted",
            "journalReadable", "logEvidenceAvailable",
        ):
            self.assertEqual(result[field], "unknown")
            self.assertIsNot(result[field], False)
        self.assertEqual(result["verdict"], "LOG_EVIDENCE_UNAVAILABLE")

    def test_no_exact_event_times_out_as_unavailable_evidence(self) -> None:
        result = self._poll_with_events([])
        self.assertEqual(result["verdict"], "JOURNAL_EVENT_TIMEOUT")
        self.assertEqual(result["cacheHit"], "unknown")
        self.assertFalse(result["logEvidenceAvailable"])

    @staticmethod
    def _poll_with_events(records: list[dict]) -> dict:
        helper = helper_namespace()
        lines = [json.dumps(record) for record in records]
        helper["journal_query"] = lambda _since: {
            "ok": True, "lines": lines, "returnCode": 0,
            "journalReadable": True,
            "logEvidenceAvailable": bool(lines), "verdict": None,
        }
        return helper["poll_request_evidence"]("wanted", "-")


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
