#!/usr/bin/env python3
"""Régression locale du harnais Phase 5.

Deux défauts réels sont verrouillés ici.

1. 2026-07-27 — `abort_request()` recevait le tuple de réponse de `request()`
   au lieu du chemin HTTP, la variable `second` servant à deux usages
   incompatibles. Échec tardif et opaque dans `http.client` :
   `TypeError: expected string or bytes-like object, got 'tuple'`.

2. 2026-07-27 (exécution suivante) — la piste d'abandon était choisie par
   `ORDER BY size_bytes ASC` sans plancher. `vps_phase45_setup.sh` insère une
   piste PÉRIMÉE de 4 096 octets (hash `"f" * 64`, absente de l'index du
   Storage Agent) que la Phase 5 hérite en copiant la base. Elle était donc
   toujours retenue, l'agent répondait `404 TRACK_NOT_INDEXED` → `INDEX_STALE`
   → **503**, et le harnais concluait `ok=false` sans dire laquelle des dix
   conditions avait échoué.
"""

from __future__ import annotations

import importlib.util
import json
import sqlite3
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
CACHE_TEST = SCRIPTS / "vps_phase5_cache_test.py"
SELECTION = SCRIPTS / "phase5_track_selection.py"
WRITE_ENV = SCRIPTS / "vps_phase5_write_env.py"
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


selection = _load("phase5_track_selection", SELECTION)
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


# Reproduction fidèle de l'injection de vps_phase45_setup.sh:287-307.
STALE_TRACK = {"id": 1000029, "hash": "f" * 64, "size": 4096}
REAL_SMALL = {"id": 17, "hash": "a" * 64, "size": 9_165_881}
REAL_SECOND = {"id": 29, "hash": "b" * 64, "size": 12_400_000}


def build_database(path: Path, rows: list[dict[str, object]], user_id: int = 1) -> None:
    database = sqlite3.connect(path)
    try:
        database.execute(
            "CREATE TABLE tracks (id INTEGER PRIMARY KEY, hash TEXT, size_bytes INTEGER)"
        )
        database.execute(
            "CREATE TABLE user_tracks (user_id INTEGER, track_id INTEGER, is_visible INTEGER)"
        )
        for row in rows:
            database.execute(
                "INSERT INTO tracks (id, hash, size_bytes) VALUES (?,?,?)",
                (row["id"], row["hash"], row["size"]),
            )
            database.execute(
                "INSERT INTO user_tracks (user_id, track_id, is_visible) VALUES (?,?,1)",
                (user_id, row["id"]),
            )
        database.commit()
    finally:
        database.close()


class _StubHandler(BaseHTTPRequestHandler):
    """API parallèle simulée : 200 sur les pistes servables, 503 sinon."""

    servable_paths: set[str] = set()
    paths_seen: list[str] = []
    body_size = 4096

    def _dispatch(self, write_body: bool) -> None:
        type(self).paths_seen.append(self.path)
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path not in type(self).servable_paths:
            # Exactement ce que produit une piste absente de l'index distant :
            # INDEX_STALE -> 503 générique, sans code interne exposé.
            payload = b'{"statusCode":503,"error":"service_unavailable"}'
            self.send_response(503)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        body = b"x" * type(self).body_size
        self.send_response(200)
        self.send_header("Content-Type", "audio/flac")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if write_body:
            self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 — imposé par BaseHTTPRequestHandler
        self._dispatch(True)

    def do_HEAD(self) -> None:  # noqa: N802
        self._dispatch(False)

    def log_message(self, *_args: object) -> None:
        return


class _StubServer:
    def __init__(self, servable: set[str] | None = None) -> None:
        self.servable = servable or set()

    def __enter__(self) -> "_StubServer":
        _StubHandler.paths_seen = []
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


# ===========================================================================
# Défaut 2 — sélection de la piste d'abandon
# ===========================================================================


class AbortTrackSelectionTest(unittest.TestCase):
    def test_stale_phase45_track_is_never_selected(self) -> None:
        """La piste périmée de 4 096 octets est écartée par le plancher."""
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "runtime.db"
            build_database(database, [STALE_TRACK, REAL_SMALL, REAL_SECOND])
            candidates = selection.candidate_tracks(str(database), 1, (REAL_SMALL["id"],))
        self.assertTrue(candidates)
        self.assertNotIn(STALE_TRACK["id"], [c.track_id for c in candidates])
        self.assertEqual(candidates[0].track_id, REAL_SECOND["id"])

    def test_old_ordering_would_have_chosen_the_stale_track(self) -> None:
        """Contrôle négatif : sans plancher, la piste périmée gagne."""
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "runtime.db"
            build_database(database, [STALE_TRACK, REAL_SMALL, REAL_SECOND])
            connection = sqlite3.connect(database)
            try:
                row = connection.execute(
                    "SELECT t.id FROM tracks t JOIN user_tracks ut ON ut.track_id=t.id "
                    "WHERE ut.user_id=1 AND ut.is_visible=1 AND t.id<>? "
                    "ORDER BY t.size_bytes ASC LIMIT 1",
                    (REAL_SMALL["id"],),
                ).fetchone()
            finally:
                connection.close()
        self.assertEqual(row[0], STALE_TRACK["id"])

    def test_stale_hash_passes_a_form_check_so_form_alone_is_insufficient(self) -> None:
        """`"f" * 64` est un SHA-256 bien formé : la forme ne suffit pas."""
        self.assertEqual(
            selection.ensure_content_hash(STALE_TRACK["hash"], argument="h"),
            STALE_TRACK["hash"],
        )

    def test_selection_requires_successful_head(self) -> None:
        """Une candidate qui ne répond pas 200 à un HEAD est rejetée."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "cache/objects").mkdir(parents=True)
            (root / "runtime").mkdir(parents=True)
            database = root / "runtime.db"
            build_database(database, [REAL_SMALL, REAL_SECOND])
            servable = {f"/api/tracks/{REAL_SECOND['id']}/stream"}
            with _StubServer(servable) as server:
                choice = harness.choose_abort_track(
                    root, str(database), 1, (REAL_SMALL["id"],), server.port, FAKE_AUTH
                )
        self.assertIsNotNone(choice.track)
        self.assertEqual(choice.track.track_id, REAL_SECOND["id"])
        self.assertEqual(choice.head_status, 200)

    def test_unservable_candidate_is_rejected_with_sanitized_code(self) -> None:
        """Rejet documenté, code public assaini, aucun code interne exposé."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "cache/objects").mkdir(parents=True)
            (root / "runtime").mkdir(parents=True)
            database = root / "runtime.db"
            build_database(database, [REAL_SMALL, REAL_SECOND])
            with _StubServer(set()) as server:
                choice = harness.choose_abort_track(
                    root, str(database), 1, (REAL_SMALL["id"],), server.port, FAKE_AUTH
                )
        self.assertIsNone(choice.track)
        self.assertIsNotNone(choice.skip_reason)
        self.assertTrue(choice.rejected)
        rejection = choice.rejected[0]
        self.assertEqual(rejection["reason"], "HEAD_NON_200")
        self.assertEqual(rejection["status"], 503)
        self.assertEqual(rejection["publicErrorCode"], "service_unavailable")
        self.assertNotIn("TRACK_NOT_INDEXED", json.dumps(choice.rejected))

    def test_already_cached_candidate_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cached = harness.object_path(root, REAL_SECOND["hash"])
            cached.parent.mkdir(parents=True)
            cached.write_bytes(b"x")
            database = root / "runtime.db"
            build_database(database, [REAL_SMALL, REAL_SECOND])
            with _StubServer({f"/api/tracks/{REAL_SECOND['id']}/stream"}) as server:
                choice = harness.choose_abort_track(
                    root, str(database), 1, (REAL_SMALL["id"],), server.port, FAKE_AUTH
                )
        self.assertIsNone(choice.track)
        self.assertEqual(choice.rejected[0]["reason"], "DEJA_EN_CACHE")

    def test_no_candidate_produces_explicit_skip_not_opaque_failure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            database = root / "runtime.db"
            build_database(database, [REAL_SMALL, STALE_TRACK])
            choice = harness.choose_abort_track(
                root, str(database), 1, (REAL_SMALL["id"],), 1, FAKE_AUTH
            )
        self.assertIsNone(choice.track)
        self.assertIsNotNone(choice.skip_reason)
        # Le motif doit citer le plancher, pour être actionnable sans lire le code.
        self.assertIn(str(selection.MIN_TRACK_SIZE_BYTES), choice.skip_reason)
        self.assertEqual(choice.rejected, [])

    def test_write_env_and_cache_test_share_the_same_selection(self) -> None:
        """Dimensionnement et test doivent viser la MÊME piste."""
        write_env_source = WRITE_ENV.read_text(encoding="utf-8")
        cache_source = CACHE_TEST.read_text(encoding="utf-8")
        self.assertIn("from phase5_track_selection import", write_env_source)
        self.assertIn("candidate_tracks", write_env_source)
        self.assertIn("from phase5_track_selection import", cache_source)
        self.assertNotIn("ORDER BY t.size_bytes ASC", write_env_source)


# ===========================================================================
# Scénario d'abandon
# ===========================================================================


class AbortScenarioTest(unittest.TestCase):
    def test_503_is_never_accepted_as_a_valid_abort(self) -> None:
        """Le cœur du défaut : un 503 initial ne prouve aucun abandon."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "cache/tmp").mkdir(parents=True)
            (root / "cache/objects").mkdir(parents=True)
            (root / "runtime").mkdir(parents=True)
            track = selection.SelectedTrack(REAL_SECOND["id"], REAL_SECOND["size"], REAL_SECOND["hash"])
            with _StubServer(set()) as server:
                outcome = harness.run_abort_scenario(
                    root, server.port, track, FAKE_AUTH,
                    part_appear_timeout_s=0.5, part_cleanup_timeout_s=0.5,
                )
        self.assertEqual(outcome.first.status, 503)
        self.assertEqual(outcome.first.bytes_read, 0)
        self.assertIsNone(outcome.second, "aucune seconde tentative sans premier depart")
        self.assertFalse(outcome.lock_released_behaviorally)
        self.assertFalse(outcome.refill_started)

    def test_abort_after_first_bytes_is_started(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "cache/tmp").mkdir(parents=True)
            (root / "cache/objects").mkdir(parents=True)
            (root / "runtime").mkdir(parents=True)
            track = selection.SelectedTrack(REAL_SECOND["id"], REAL_SECOND["size"], REAL_SECOND["hash"])
            with _StubServer({track.stream_path}) as server:
                outcome = harness.run_abort_scenario(
                    root, server.port, track, FAKE_AUTH,
                    part_appear_timeout_s=0.5, part_cleanup_timeout_s=0.5,
                )
        self.assertEqual(outcome.first.status, 200)
        self.assertGreater(outcome.first.bytes_read, 0)
        self.assertTrue(outcome.first.part_removed)
        self.assertTrue(outcome.not_promoted)
        self.assertIsNotNone(outcome.second, "une preuve comportementale doit etre tentee")

    def test_part_removal_and_promotion_are_checked_independently(self) -> None:
        """Un objet final promu doit faire échouer `abortNotPromoted`."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "cache/tmp").mkdir(parents=True)
            track = selection.SelectedTrack(REAL_SECOND["id"], REAL_SECOND["size"], REAL_SECOND["hash"])
            promoted = harness.object_path(root, track.sha256)
            promoted.parent.mkdir(parents=True)
            promoted.write_bytes(b"x")
            (root / "runtime").mkdir(parents=True)
            with _StubServer({track.stream_path}) as server:
                outcome = harness.run_abort_scenario(
                    root, server.port, track, FAKE_AUTH,
                    part_appear_timeout_s=0.5, part_cleanup_timeout_s=0.5,
                )
        self.assertFalse(outcome.not_promoted)

    def test_waits_are_bounded(self) -> None:
        """`wait_until` rend la main même si la condition reste fausse."""
        started = harness.time.monotonic()
        result = harness.wait_until(lambda: False, 0.5)
        self.assertFalse(result)
        self.assertLess(harness.time.monotonic() - started, 5)

    # La corrélation par requestId est désormais couverte par
    # test_vps_phase5_proofs.LogReaderTest, sur le module dédié.


# ===========================================================================
# Rapport explicite
# ===========================================================================


class ReportDetailTest(unittest.TestCase):
    def test_emit_names_every_failed_condition(self) -> None:
        import io
        import contextlib

        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            ok = harness.emit(
                {"mode": "full"},
                {"missSucceeded": True, "abortStatusAccepted": False, "lockReleased": False},
            )
        payload = json.loads(buffer.getvalue())
        self.assertFalse(ok)
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["failedChecks"], ["abortStatusAccepted", "lockReleased"])
        self.assertTrue(payload["checks"]["missSucceeded"])

    def test_emit_reports_ok_when_every_check_passes(self) -> None:
        import io
        import contextlib

        buffer = io.StringIO()
        with contextlib.redirect_stdout(buffer):
            ok = harness.emit({"mode": "abort"}, {"abortStarted": True})
        payload = json.loads(buffer.getvalue())
        self.assertTrue(ok)
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["failedChecks"], [])

    def test_full_mode_declares_every_required_check(self) -> None:
        source = CACHE_TEST.read_text(encoding="utf-8")
        for name in (
            "missSucceeded", "hitSucceeded", "contentMatched", "headHitSucceeded",
            "rangeHitSucceeded", "abortStarted", "abortStatusAccepted",
            "abortPartRemoved", "objectCountValid", "partCountValid",
        ):
            self.assertIn(f'"{name}"', source, f"contrôle manquant : {name}")

    def test_public_error_code_never_exposes_internal_agent_codes(self) -> None:
        for status, expected in ((404, "not_found"), (503, "service_unavailable"), (502, "bad_gateway")):
            response = harness.Response(status, {}, 0, "0" * 64, 1.0, 0.1, "rid")
            self.assertEqual(harness.public_error_code(response), expected)
        healthy = harness.Response(200, {}, 1, "0" * 64, 1.0, 0.1, "rid")
        self.assertIsNone(harness.public_error_code(healthy))


# ===========================================================================
# Défaut 1 — typage des chemins HTTP
# ===========================================================================


class Phase5PathTypingTest(unittest.TestCase):
    def test_response_tuple_passed_as_path_is_rejected_by_name(self) -> None:
        response = harness.Response(200, {}, 4096, "0" * 64, 12.5, 0.4, "rid")
        with self.assertRaises(TypeError) as caught:
            harness.request(1, "GET", response, FAKE_AUTH)
        message = str(caught.exception)
        self.assertIn("path", message)
        self.assertIn("Response", message)
        self.assertNotIn(FAKE_AUTH, message)

    def test_selected_track_exposes_string_stream_path(self) -> None:
        track = selection.SelectedTrack(track_id=42, size_bytes=2048, sha256="b" * 64)
        self.assertIsInstance(track.stream_path, str)
        self.assertEqual(track.stream_path, "/api/tracks/42/stream")
        self.assertEqual(track.hash_prefix, "b" * 12)

    def test_ensure_http_path_rejects_non_string_types(self) -> None:
        for value in ((1, 2), {"path": "/x"}, None, 42, ["/x"]):
            with self.subTest(value=type(value).__name__):
                with self.assertRaises(TypeError) as caught:
                    selection.ensure_http_path(value, argument="path")
                self.assertIn(type(value).__name__, str(caught.exception))

    def test_ensure_track_id_rejects_bool_and_other_types(self) -> None:
        for value in (True, False, "17", None, (17,), 17.0):
            with self.subTest(value=repr(value)):
                with self.assertRaises(TypeError):
                    selection.ensure_track_id(value, argument="track_id")

    def test_ensure_track_id_rejects_non_positive(self) -> None:
        for value in (0, -1):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    selection.ensure_track_id(value, argument="track_id")

    def test_ensure_content_hash_rejects_malformed(self) -> None:
        for value in ("g" * 64, "a" * 63, "A" * 64, None, 42):
            with self.subTest(value=repr(value)[:20]):
                with self.assertRaises((TypeError, ValueError)):
                    selection.ensure_content_hash(value, argument="hash")

    def test_no_error_message_leaks_the_auth_token(self) -> None:
        for bad in (("/x",), {"a": 1}, None):
            with self.subTest(value=type(bad).__name__):
                with self.assertRaises(TypeError) as caught:
                    harness.request(1, "GET", bad, FAKE_AUTH)
                message = str(caught.exception)
                self.assertNotIn(FAKE_AUTH, message)
                self.assertNotIn("Bearer", message)

    def test_source_contains_no_hardcoded_secret(self) -> None:
        for path in (CACHE_TEST, SELECTION):
            source = path.read_text(encoding="utf-8")
            self.assertNotIn("STORAGE_AGENT_SHARED_SECRET=", source)
            self.assertEqual([line for line in source.splitlines() if "eyJ" in line], [])


# ===========================================================================
# Mode ciblé
# ===========================================================================


class AbortOnlyModeTest(unittest.TestCase):
    def test_runner_declares_abort_only_switch(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        self.assertIn("[switch] $AbortOnly", source)
        self.assertIn("--mode abort", source)

    def test_abort_only_does_not_stop_the_storage_agent(self) -> None:
        """Le mode ciblé ne doit ouvrir aucune fenêtre d'indisponibilité."""
        source = RUNNER.read_text(encoding="utf-8")
        # La borne est le mode ciblé SUIVANT : `-OfflineOnly`, qui lui a le
        # droit d'arrêter l'agent — après un `offline-precheck` vert.
        branch = source.split("elseif ($AbortOnly) {", 1)[1].split("elseif ($OfflineOnly) {", 1)[0]
        self.assertNotIn("Stop-Service", branch)
        self.assertNotIn("Invoke-OfflineScenario", branch)

    def test_shared_selection_module_is_shipped_to_the_vps(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        self.assertIn("phase5_track_selection.py", source)

    def test_abort_mode_is_accepted_by_the_cli(self) -> None:
        source = CACHE_TEST.read_text(encoding="utf-8")
        for mode in ("full", "offline", "offline-precheck", "restart", "eviction", "abort"):
            self.assertIn(f'"{mode}"', source, f"mode manquant : {mode}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
