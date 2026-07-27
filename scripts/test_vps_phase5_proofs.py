#!/usr/bin/env python3
"""Régression locale des PREUVES du harnais Phase 5.

Troisième défaut verrouillé ici (2026-07-27, troisième exécution réelle) :
le harnais concluait à partir de statuts HTTP et de lectures de journaux
instantanées, là où il fallait des preuves.

- `hitSucceeded` valait « HTTP 200 ». Une exécution a rendu 200 à 2,07 MiB/s
  alors que l'exécution précédente donnait 118 MiB/s : le second GET était
  reparti chercher les octets à distance parce que le remplissage n'était pas
  encore promu. Un 200 ne prouve pas un HIT.
- `lockReleased` exigeait un `CACHE_FILL_ABORTED` visible IMMÉDIATEMENT.
  L'absence d'une ligne de journal ne prouve rien : seul un second
  remplissage qui démarre prouve que le verrou a été rendu.
- `objectCountValid` comptait les objets après un abandon portant sur une
  piste plus grosse que la place restante : l'éviction LRU faisait
  légitimement disparaître l'objet précédent.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
CACHE_TEST = SCRIPTS / "vps_phase5_cache_test.py"
RUNNER = SCRIPTS / "run_phase5_cache_integration.ps1"

if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


selection = _load("phase5_track_selection", SCRIPTS / "phase5_track_selection.py")
log_reader = _load("phase5_log_reader", SCRIPTS / "phase5_log_reader.py")
harness = _load("vps_phase5_cache_test", CACHE_TEST)

FAKE_AUTH = "header.payload.signature-ne-doit-jamais-fuiter"


def setUpModule() -> None:
    """Bornes de scrutation raccourcies : les serveurs simulés n'émettent
    aucun événement, inutile d'épuiser les 10 s réelles à chaque appel."""
    harness.EVENT_ATTEMPTS = 2
    harness.EVENT_INTERVAL_S = 0.01
    harness.PART_APPEAR_TIMEOUT_S = 0.5
    harness.PART_CLEANUP_TIMEOUT_S = 0.5
    harness.POLL_INTERVAL_S = 0.05



def write_log(root: Path, records: list[dict], name: str = "api.stdout.log") -> None:
    runtime = root / "runtime"
    runtime.mkdir(parents=True, exist_ok=True)
    (runtime / name).write_text(
        "\n".join(json.dumps(r) for r in records) + "\n", encoding="utf-8"
    )


def make_track() -> "selection.SelectedTrack":
    return selection.SelectedTrack(29, 4096, "b" * 64)


class _StubHandler(BaseHTTPRequestHandler):
    servable_paths: set = set()

    def _dispatch(self, write_body: bool) -> None:
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path not in type(self).servable_paths:
            payload = b'{"statusCode":503,"error":"service_unavailable"}'
            self.send_response(503)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        body = b"x" * 4096
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if write_body:
            self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        self._dispatch(True)

    def do_HEAD(self) -> None:  # noqa: N802
        self._dispatch(False)

    def log_message(self, *_args: object) -> None:
        return


class _StubServer:
    def __init__(self, servable=None) -> None:
        self.servable = servable or set()

    def __enter__(self):
        _StubHandler.servable_paths = self.servable
        self.server = HTTPServer(("127.0.0.1", 0), _StubHandler)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *_exc: object) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


class FillFinalizationTest(unittest.TestCase):
    def test_promotion_visible_only_after_several_polls(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "runtime").mkdir(parents=True)
            track = make_track()
            state = {"polls": 0}
            original = harness.logs.records_for

            def delayed(_root, request_id, limit=20000):
                state["polls"] += 1
                if state["polls"] >= 3:
                    final = harness.object_path(root, track.sha256)
                    final.parent.mkdir(parents=True, exist_ok=True)
                    final.write_bytes(b"x" * track.size_bytes)
                    return [{"requestId": request_id, "event": "CACHE_FILL_COMPLETED"}]
                return [{"requestId": request_id, "event": "CACHE_FILL_STARTED"}]

            harness.logs.records_for = delayed
            try:
                outcome = harness.wait_for_fill_terminal(
                    root, "rid", track, attempts=10, interval_s=0.01
                )
            finally:
                harness.logs.records_for = original
        self.assertEqual(outcome.terminal_reason, "COMPLETED")
        self.assertTrue(outcome.fill_completed)
        self.assertTrue(outcome.final_object_visible)
        self.assertGreaterEqual(state["polls"], 3)

    def test_object_visible_without_event_is_still_a_promotion(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "runtime").mkdir(parents=True)
            track = make_track()
            final = harness.object_path(root, track.sha256)
            final.parent.mkdir(parents=True)
            final.write_bytes(b"x" * track.size_bytes)
            outcome = harness.wait_for_fill_terminal(
                root, "rid", track, attempts=2, interval_s=0.01
            )
        self.assertEqual(outcome.terminal_reason, "OBJECT_VISIBLE_WITHOUT_EVENT")
        self.assertEqual(outcome.final_object_size, track.size_bytes)

    def test_fill_failed_is_reported_not_masked(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            track = make_track()
            write_log(root, [{"requestId": "rid", "event": "CACHE_WRITE_FAILED"}])
            outcome = harness.wait_for_fill_terminal(
                root, "rid", track, attempts=3, interval_s=0.01
            )
        self.assertTrue(outcome.fill_failed)
        self.assertEqual(outcome.terminal_reason, "CACHE_WRITE_FAILED")
        self.assertFalse(outcome.final_object_visible)

    def test_bypass_is_distinguished_from_a_hit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            track = make_track()
            write_log(root, [{"requestId": "rid", "event": "CACHE_BYPASS",
                              "reason": "SINGLE_FLIGHT_ACTIVE"}])
            outcome = harness.wait_for_fill_terminal(
                root, "rid", track, attempts=3, interval_s=0.01
            )
        self.assertTrue(outcome.fill_bypassed)
        self.assertFalse(outcome.fill_completed)
        self.assertEqual(outcome.terminal_reason, "BYPASSED")

    def test_timeout_is_bounded_and_explicit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "runtime").mkdir(parents=True)
            started = harness.time.monotonic()
            outcome = harness.wait_for_fill_terminal(
                root, "rid", make_track(), attempts=3, interval_s=0.01
            )
        self.assertEqual(outcome.terminal_reason, "TIMEOUT")
        self.assertLess(harness.time.monotonic() - started, 5)


class HitProofTest(unittest.TestCase):
    def test_http_200_from_upstream_is_never_a_cache_hit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "runtime").mkdir(parents=True)
            track = make_track()
            with _StubServer({track.stream_path}) as server:
                # Journal RÉEL : `prove_cache_hit` consulte aussi
                # `logEvidenceAvailable`, qui serait faux sur un dossier vide
                # et rendrait « unknown » au lieu d'un booléen.
                original = harness.logs.records_for
                harness.logs.records_for = lambda _r, rid, limit=20000: [
                    {"requestId": rid, "event": "CACHE_MISS"},
                    {"requestId": rid, "event": "REMOTE_STORAGE_REQUEST_STARTED"},
                ]
                write_log(root, [{"requestId": "autre", "event": "CACHE_MISS"}])
                try:
                    proof = harness.prove_cache_hit(
                        root, server.port, track.stream_path, FAKE_AUTH, track, "hit"
                    )
                finally:
                    harness.logs.records_for = original
        self.assertEqual(proof.response.status, 200)
        self.assertFalse(proof.cache_hit_observed)
        self.assertTrue(proof.upstream_contacted)

    def test_cache_hit_event_proves_the_hit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "runtime").mkdir(parents=True)
            track = make_track()
            with _StubServer({track.stream_path}) as server:
                original = harness.logs.records_for
                harness.logs.records_for = lambda _r, rid, limit=20000: [
                    {"requestId": rid, "event": "CACHE_HIT"}
                ]
                write_log(root, [{"requestId": "autre", "event": "CACHE_HIT"}])
                try:
                    proof = harness.prove_cache_hit(
                        root, server.port, track.stream_path, FAKE_AUTH, track, "hit"
                    )
                finally:
                    harness.logs.records_for = original
        self.assertTrue(proof.cache_hit_observed)
        self.assertFalse(proof.upstream_contacted)


    def test_absent_logs_yield_unknown_not_false(self) -> None:
        """Le point exact du 4e defaut : pas de journaux = indetermine."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "runtime").mkdir(parents=True)
            track = make_track()
            with _StubServer({track.stream_path}) as server:
                proof = harness.prove_cache_hit(
                    root, server.port, track.stream_path, FAKE_AUTH, track, "hit"
                )
        self.assertEqual(proof.response.status, 200)
        self.assertIsNone(proof.cache_hit_observed)
        self.assertIsNone(proof.upstream_contacted)
        self.assertFalse(proof.log_evidence_available)
        self.assertEqual(harness.tri(proof.cache_hit_observed), "unknown")


class LockReleaseProofTest(unittest.TestCase):
    def test_lock_release_is_proven_by_a_second_fill(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "cache/tmp").mkdir(parents=True)
            (root / "cache/objects").mkdir(parents=True)
            (root / "runtime").mkdir(parents=True)
            track = make_track()
            attempts = {"n": 0}
            original = harness._abort_once

            def fake(_r, _port, _t, _auth, label, _appear, _cleanup):
                attempts["n"] += 1
                return harness.AbortAttempt(
                    status=200, bytes_read=65536, part_observed=True,
                    part_removed=True, events=[], request_id=f"rid-{label}",
                )

            harness._abort_once = fake
            try:
                outcome = harness.run_abort_scenario(root, 1, track, FAKE_AUTH)
            finally:
                harness._abort_once = original
        self.assertEqual(attempts["n"], 2, "une seconde requête doit être tentée")
        self.assertTrue(outcome.refill_started)
        self.assertTrue(outcome.lock_released_behaviorally)
        # Le verdict ne dépend PAS de la ligne de journal.
        self.assertFalse(outcome.terminal_event_observed)

    def test_no_second_attempt_when_first_never_started(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "cache/tmp").mkdir(parents=True)
            (root / "cache/objects").mkdir(parents=True)
            (root / "runtime").mkdir(parents=True)
            original = harness._abort_once
            harness._abort_once = lambda _r, _p, _t, _a, _l, _x, _y: harness.AbortAttempt(
                503, 0, False, True, [], "rid"
            )
            try:
                outcome = harness.run_abort_scenario(root, 1, make_track(), FAKE_AUTH)
            finally:
                harness._abort_once = original
        self.assertIsNone(outcome.second)
        self.assertFalse(outcome.lock_released_behaviorally)


class DiskCountersTest(unittest.TestCase):
    def test_counters_are_separated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            obj = harness.object_path(root, "c" * 64)
            obj.parent.mkdir(parents=True)
            obj.write_bytes(b"x" * 1000)
            (root / "cache/tmp").mkdir(parents=True)
            (root / "cache/tmp/part.part").write_bytes(b"y" * 50)
            (root / "cache/metadata").mkdir(parents=True)
            (root / "cache/metadata/other.bin").write_bytes(b"z" * 7)
            report = harness.cache_disk_report(root)
        self.assertEqual(report["objectCount"], 1)
        self.assertEqual(report["objectBytes"], 1000)
        self.assertEqual(report["partCount"], 1)
        self.assertEqual(report["tempBytes"], 50)
        self.assertEqual(report["metadataBytes"], 7)
        self.assertEqual(report["totalCacheDirectoryBytes"], 1057)

    def test_total_bytes_never_proves_an_object_exists(self) -> None:
        """Le cas réel : cacheBytes=98696 avec objects=0."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "cache/metadata").mkdir(parents=True)
            (root / "cache/metadata/other.bin").write_bytes(b"z" * 98696)
            report = harness.cache_disk_report(root)
        self.assertEqual(report["objectCount"], 0)
        self.assertEqual(report["objectBytes"], 0)
        self.assertEqual(report["totalCacheDirectoryBytes"], 98696)


class LogReaderTest(unittest.TestCase):
    def test_reads_current_and_rotated_logs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_log(root, [{"requestId": "rid", "event": "CACHE_HIT"}])
            write_log(root, [{"requestId": "rid", "event": "CACHE_MISS"}], "api.stdout.log.1")
            names = log_reader.event_names(log_reader.records_for(root, "rid"))
        self.assertIn("CACHE_HIT", names)
        self.assertIn("CACHE_MISS", names)

    def test_tolerates_prefix_before_json(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "runtime").mkdir(parents=True)
            (root / "runtime/api.stdout.log").write_text(
                '2026-07-27 18:00:00 INFO {"requestId":"rid","event":"CACHE_HIT"}\n',
                encoding="utf-8",
            )
            names = log_reader.event_names(log_reader.records_for(root, "rid"))
        self.assertEqual(names, ["CACHE_HIT"])

    def test_textual_match_is_not_used(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_log(root, [{"requestId": "rid", "event": "CACHE_BYPASS",
                              "reason": "pas un CACHE_HIT"}])
            names = log_reader.event_names(log_reader.records_for(root, "rid"))
        self.assertEqual(names, ["CACHE_BYPASS"])
        self.assertNotIn("CACHE_HIT", names)

    def test_diagnostics_distinguish_the_three_empty_cases(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "runtime").mkdir(parents=True)
            empty = log_reader.diagnostics(root)
            self.assertFalse(empty["logEvidenceAvailable"])
            self.assertEqual(empty["logRecordsParsed"], 0)

            write_log(root, [{"msg": "hello"}, {"level": 30}])
            no_cache = log_reader.diagnostics(root)
            self.assertGreater(no_cache["logRecordsParsed"], 0)
            self.assertEqual(no_cache["cacheEventsTotal"], 0)
            self.assertFalse(no_cache["logEvidenceAvailable"])

            write_log(root, [{"requestId": "autre", "event": "CACHE_HIT"}])
            with_events = log_reader.diagnostics(root)
            self.assertGreater(with_events["cacheEventsTotal"], 0)
            self.assertTrue(with_events["logEvidenceAvailable"])

    def test_sanitized_events_expose_no_sensitive_field(self) -> None:
        records = [{
            "event": "CACHE_HIT", "requestId": "rid", "trackId": 7,
            "authorization": "Bearer x", "secret": "s", "nonce": "n",
            "signature": "sig", "path": "/musique/Artiste/Album.flac",
        }]
        serialized = json.dumps(log_reader.sanitized_events(records))
        for forbidden in ("authorization", "Bearer", "secret", "nonce", "signature", "Artiste"):
            self.assertNotIn(forbidden, serialized)
        self.assertIn("CACHE_HIT", serialized)


class FinalizeOnlyModeTest(unittest.TestCase):
    def test_runner_declares_finalize_only(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        self.assertIn("[switch] $FinalizeOnly", source)
        self.assertIn("--mode finalize", source)

    def test_finalize_only_does_not_stop_the_agent(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        branch = source.split("if ($FinalizeOnly) {", 1)[1].split("elseif ($AbortOnly)", 1)[0]
        self.assertNotIn("Stop-Service", branch)

    def test_finalize_mode_is_accepted(self) -> None:
        self.assertIn('"abort", "finalize",', CACHE_TEST.read_text(encoding="utf-8"))

    def test_log_reader_is_shipped_to_the_vps(self) -> None:
        self.assertIn("phase5_log_reader.py", RUNNER.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
