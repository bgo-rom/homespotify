#!/usr/bin/env python3
"""Régression locale de la CAPTURE des journaux de l'API Phase 5.

Quatrième défaut verrouillé ici (2026-07-27, quatrième exécution réelle) :
`api.stdout.log` et `api.stderr.log` faisaient **zéro octet** alors que l'API
répondait normalement et que le cache était correctement promu.

Cause : `services/api/src/app.ts:239-244` construit Fastify avec

    logger: { level: config.logLevel, enabled: config.nodeEnv !== 'test' }

et `vps_phase5_write_env.py` posait `NODE_ENV=test`. Le logger était donc
ENTIÈREMENT désactivé : `app.log.*` inerte, callbacks des providers inertes,
aucun événement `CACHE_*` nulle part. `LOG_LEVEL=info` était correct mais sans
objet — un niveau ne sert à rien quand le logger est éteint.

Conséquence de conception : l'absence de preuve ne doit jamais devenir une
preuve négative. `cacheHitObserved` et `upstreamContactedOnHit` valent
désormais `unknown` quand aucun journal exploitable n'existe.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
WRITE_ENV = SCRIPTS / "vps_phase5_write_env.py"
SETUP = SCRIPTS / "vps_phase5_setup.sh"
RUNNER = SCRIPTS / "run_phase5_cache_integration.ps1"
CACHE_TEST = SCRIPTS / "vps_phase5_cache_test.py"
APP_TS = SCRIPTS.parent / "services" / "api" / "src" / "app.ts"

if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


log_reader = _load("phase5_log_reader", SCRIPTS / "phase5_log_reader.py")
harness = _load("vps_phase5_cache_test", CACHE_TEST)


class NodeEnvTest(unittest.TestCase):
    def test_phase5_env_never_uses_node_env_test(self) -> None:
        """La cause racine, verrouillée : `test` éteindrait le logger."""
        source = WRITE_ENV.read_text(encoding="utf-8")
        self.assertNotIn('"NODE_ENV": "test"', source)
        self.assertIn('"NODE_ENV": "production"', source)

    def test_phase5_env_sets_log_level_info(self) -> None:
        """Les événements CACHE_* sont émis en `info`."""
        self.assertIn('"LOG_LEVEL": "info"', WRITE_ENV.read_text(encoding="utf-8"))

    def test_app_still_disables_logger_only_for_node_env_test(self) -> None:
        """Contrôle négatif sur le code réel : si cette condition change,
        le commentaire du harnais devient faux et ce test le signale."""
        if not APP_TS.exists():
            self.skipTest("app.ts absent")
        source = APP_TS.read_text(encoding="utf-8")
        self.assertIn("enabled: config.nodeEnv !== 'test'", source)

    def test_cache_events_are_emitted_at_info_level(self) -> None:
        """CACHE_HIT, CACHE_MISS et CACHE_FILL_* passent par `log('info', …)`."""
        provider = SCRIPTS.parent / "services/api/src/storage/cache/cached-audio-storage.ts"
        if not provider.exists():
            self.skipTest("provider absent")
        source = provider.read_text(encoding="utf-8")
        for event in ("CACHE_HIT", "CACHE_MISS", "CACHE_FILL_STARTED", "CACHE_FILL_COMPLETED"):
            self.assertIn(f"'info', '{event}'", source, f"{event} n'est plus en info")
        # Les abandons et échecs restent en `warn`, également capturés.
        self.assertIn("this.log('warn', reason", source)


class EarlyCaptureVerificationTest(unittest.TestCase):
    def test_setup_verifies_capture_before_returning(self) -> None:
        source = SETUP.read_text(encoding="utf-8")
        self.assertIn("verify_log_capture", source)
        self.assertIn("logCaptureVerified", source)
        self.assertIn("structuredLines", source)

    def test_setup_reports_real_pid_and_fd_targets(self) -> None:
        """Le PID enregistré et la destination réelle de ses descripteurs."""
        source = SETUP.read_text(encoding="utf-8")
        self.assertIn("/proc/${API_PID}/fd/1", source)
        self.assertIn("/proc/${API_PID}/fd/2", source)
        self.assertIn("kill -0", source)

    def test_setup_fails_fast_when_nothing_is_captured(self) -> None:
        source = SETUP.read_text(encoding="utf-8")
        self.assertIn("no_structured_log_captured", source)
        self.assertIn("exit 3", source)

    def test_node_output_is_never_redirected_to_dev_null(self) -> None:
        """Seuls stdout/stderr de Node comptent : `pushd >/dev/null` est
        legitime et ne doit pas faire echouer ce controle."""
        source = SETUP.read_text(encoding="utf-8")
        self.assertIn('>"${ROOT}/runtime/api.stdout.log"', source)
        self.assertIn('2>"${ROOT}/runtime/api.stderr.log"', source)
        launch = [l for l in source.splitlines() if "node dist/server.js" in l]
        self.assertEqual(len(launch), 1)
        self.assertNotIn("/dev/null", launch[0])


class UnknownStateTest(unittest.TestCase):
    def test_tri_state_never_turns_absence_into_a_negative(self) -> None:
        self.assertEqual(harness.tri(None), "unknown")
        self.assertEqual(harness.tri(True), "true")
        self.assertEqual(harness.tri(False), "false")

    def test_missing_logs_yield_unknown_not_false(self) -> None:
        """Sans journaux : `unknown`, jamais `false`."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "runtime").mkdir(parents=True)
            self.assertFalse(log_reader.diagnostics(root)["logEvidenceAvailable"])

    def test_present_logs_yield_a_real_boolean(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "runtime").mkdir(parents=True)
            (root / "runtime/api.stdout.log").write_text(
                json.dumps({"requestId": "rid", "event": "CACHE_HIT"}) + "\n",
                encoding="utf-8",
            )
            self.assertTrue(log_reader.diagnostics(root)["logEvidenceAvailable"])

    def test_checks_require_positive_proof(self) -> None:
        """`unknown` ne doit pas faire passer un contrôle."""
        source = CACHE_TEST.read_text(encoding="utf-8")
        self.assertIn("cache_hit_observed is True", source)
        self.assertIn("upstream_contacted is False", source)
        self.assertNotIn("not hit.upstream_contacted", source)

    def test_report_exposes_tri_state_values(self) -> None:
        source = CACHE_TEST.read_text(encoding="utf-8")
        self.assertIn('"cacheHitObserved": tri(', source)
        self.assertIn('"upstreamContactedOnHit": tri(', source)
        self.assertIn('"logEvidenceAvailable"', source)


class SshNoiseTest(unittest.TestCase):
    def test_non_piped_ssh_calls_close_stdin(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        self.assertIn("ssh.exe -n @ssh", source)

    def test_secret_transfer_keeps_its_stdin(self) -> None:
        """Le transfert du secret DOIT garder stdin : il y lit la valeur."""
        source = RUNNER.read_text(encoding="utf-8")
        self.assertIn("$sharedSecret | & ssh.exe @ssh", source)
        self.assertNotIn("$sharedSecret | & ssh.exe -n", source)


class NoSecretInLogsTest(unittest.TestCase):
    def test_sanitized_events_drop_every_sensitive_field(self) -> None:
        records = [{
            "event": "CACHE_HIT", "requestId": "rid",
            "AUTH_TOKEN_SECRET": "x", "authorization": "Bearer y",
            "signature": "z", "nonce": "n", "path": "/musique/A/B.flac",
        }]
        serialized = json.dumps(log_reader.sanitized_events(records))
        for forbidden in ("AUTH_TOKEN_SECRET", "Bearer", "signature", "nonce", "musique"):
            self.assertNotIn(forbidden, serialized)

    def test_setup_json_output_exposes_no_secret(self) -> None:
        """Controle cible sur la ligne JSON emise, pas sur tout le script :
        le `sed` de caviardage mentionne SECRET, c'est son role."""
        source = SETUP.read_text(encoding="utf-8")
        emitted = [l for l in source.splitlines() if l.startswith('{"status":"phase5-api-ready"')]
        self.assertEqual(len(emitted), 1)
        for forbidden in ("SECRET", "AUTH_TOKEN", "hmac-secret", "Authorization", "MUSIC_DIR"):
            self.assertNotIn(forbidden, emitted[0])

    def test_setup_redacts_secrets_in_failure_output(self) -> None:
        """Le caviardage de la sortie d'erreur doit rester en place."""
        self.assertIn("[REDACTED]", SETUP.read_text(encoding="utf-8"))


class CleanupUnchangedTest(unittest.TestCase):
    def test_cleanup_still_invoked_for_every_mode(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        finally_block = source.split("} finally {", 1)[1]
        self.assertIn("vps_phase5_cleanup.sh", finally_block)
        self.assertIn("$sharedSecret = $null", finally_block)

    def test_no_mode_returns_early_and_skips_cleanup(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        try_block = source.split("try {", 1)[1].split("} finally {", 1)[0]
        self.assertNotIn("\n        return\n", try_block)
        self.assertNotIn("\n    return\n", try_block)


if __name__ == "__main__":
    unittest.main(verbosity=2)
