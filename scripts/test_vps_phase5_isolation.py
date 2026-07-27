#!/usr/bin/env python3
"""Régression de l'ISOLATION des scénarios Phase 5.

Défaut réel verrouillé ici — 2026-07-27, 4e exécution
-----------------------------------------------------
Les trois scénarios partageaient une racine de cache et une limite unique :

    AUDIO_CACHE_MAX_BYTES = max(smallSize, secondSize) + 1

Cette limite est calibrée POUR provoquer l'éviction. Séquence observée dans
les journaux réels :

    1. piste 78 promue : contentHashPrefix=cf43ef5cb02c, objectCount=1,
       indexEntryCount=1 ;
    2. scénario d'abandon démarré sur la piste 79 ;
    3. CACHE_EVICTION_STARTED puis
       CACHE_EVICTED contentHashPrefix=cf43ef5cb02c sizeBytes=9165881 ;
    4. CACHE_FILL_ABORTED, objectCount=0, indexEntryCount=0 ;
    5. Storage Agent arrêté, lecture de la piste 78 → CACHE_MISS →
       REMOTE_STORAGE_AGENT_UNAVAILABLE → HTTP 503.

Le 503 était CORRECT. La précondition avait été détruite par le harnais.
Ces tests interdisent le retour de cette orchestration.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
CACHE_TEST = SCRIPTS / "vps_phase5_cache_test.py"
WRITE_ENV = SCRIPTS / "vps_phase5_write_env.py"
RUNNER = SCRIPTS / "run_phase5_cache_integration.ps1"
SETUP = SCRIPTS / "vps_phase5_setup.sh"
SWITCH = SCRIPTS / "vps_phase5_switch_scenario.sh"
CLEANUP = SCRIPTS / "vps_phase5_cleanup.sh"

if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def code_only(text: str) -> str:
    """Texte débarrassé des commentaires.

    Les commentaires de ces scripts CITENT Caddy, WireGuard et le pare-feu
    pour dire qu'ils ne sont pas touchés. Une recherche brute confondrait la
    documentation de la garantie avec sa violation.
    """
    without_block = []
    depth = 0
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("<#"):
            depth += 1
        if depth > 0:
            if stripped.endswith("#>"):
                depth -= 1
            continue
        if stripped.startswith("#"):
            continue
        without_block.append(line.split(" #", 1)[0] if stripped.startswith("$") else line)
    return "\n".join(without_block)


selection = _load("phase5_track_selection", SCRIPTS / "phase5_track_selection.py")
log_reader = _load("phase5_log_reader", SCRIPTS / "phase5_log_reader.py")
harness = _load("vps_phase5_cache_test", CACHE_TEST)
write_env = _load("vps_phase5_write_env", WRITE_ENV)

# Tailles RÉELLES du 2026-07-27, pour que l'arithmétique testée soit celle qui
# a échoué et pas une approximation.
SMALL_SIZE = 9_165_881
SECOND_SIZE = 12_400_000
SMALL_HASH = "cf43ef5cb02c" + "0" * 52
SECOND_HASH = "b" * 64


class ContradictoryCapacityTest(unittest.TestCase):
    """§4 — une limite par scénario, jamais une seule limite contradictoire."""

    def test_old_single_limit_could_not_hold_both_objects(self) -> None:
        """Contrôle négatif : c'est bien la limite qui causait l'éviction."""
        old_limit = max(SMALL_SIZE, SECOND_SIZE) + 1
        self.assertLess(old_limit, SMALL_SIZE + SECOND_SIZE)

    def test_finalize_offline_capacity_holds_both_objects(self) -> None:
        limit = write_env.cache_max_bytes_for("finalize-offline", SMALL_SIZE, SECOND_SIZE)
        self.assertGreater(limit, SMALL_SIZE + SECOND_SIZE)

    def test_abort_capacity_never_forces_an_eviction_to_start(self) -> None:
        limit = write_env.cache_max_bytes_for("abort", SMALL_SIZE, SECOND_SIZE)
        self.assertGreater(limit, SECOND_SIZE)
        self.assertGreater(limit, SMALL_SIZE + SECOND_SIZE)

    def test_eviction_capacity_stays_deliberately_tight(self) -> None:
        limit = write_env.cache_max_bytes_for("eviction", SMALL_SIZE, SECOND_SIZE)
        self.assertEqual(limit, max(SMALL_SIZE, SECOND_SIZE) + 1)
        self.assertLess(limit, SMALL_SIZE + SECOND_SIZE)

    def test_every_scenario_has_a_distinct_cache_root(self) -> None:
        root = Path("/home/debian/homespotify-phase5")
        roots = {s: write_env.cache_root_for(root, s) for s in write_env.SCENARIOS}
        self.assertEqual(len(set(roots.values())), len(write_env.SCENARIOS))
        for scenario, path in roots.items():
            self.assertEqual(path.name, f"cache-{scenario}")

    def test_offline_and_abort_and_eviction_roots_are_disjoint(self) -> None:
        root = Path("/tmp/phase5")
        offline = write_env.cache_root_for(root, "finalize-offline")
        abort = write_env.cache_root_for(root, "abort")
        eviction = write_env.cache_root_for(root, "eviction")
        for a, b in ((offline, abort), (offline, eviction), (abort, eviction)):
            self.assertNotEqual(a, b)
            self.assertFalse(str(b).startswith(str(a) + "/"))


class CacheRootIsolationTest(unittest.TestCase):
    """La racine effective vient de `AUDIO_CACHE_ROOT`, pas d'une constante."""

    def tearDown(self) -> None:
        harness.set_cache_root(None)

    def test_reports_follow_the_scenario_cache_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness.set_cache_root(root / "runtime/cache-abort")
            obj = harness.object_path(root, SECOND_HASH)
            obj.parent.mkdir(parents=True)
            obj.write_bytes(b"x" * 10)
            # L'ancienne racine partagée ne doit RIEN voir.
            harness.set_cache_root(root / "runtime/cache-finalize-offline")
            self.assertEqual(harness.cache_disk_report(root)["objectCount"], 0)
            harness.set_cache_root(root / "runtime/cache-abort")
            self.assertEqual(harness.cache_disk_report(root)["objectCount"], 1)

    def test_default_behaviour_is_unchanged_when_unset(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness.set_cache_root(None)
            self.assertEqual(harness.cache_dir(root), root / "cache")


class OfflinePreconditionGateTest(unittest.TestCase):
    """§3 et §5 — jamais d'arrêt d'agent sur précondition invalide."""

    def tearDown(self) -> None:
        harness.set_cache_root(None)

    def test_offline_refuses_to_run_without_a_precondition_file(self) -> None:
        """Reproduction exacte : cache vidé par l'abandon, offline refusé."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "runtime").mkdir(parents=True)
            self.assertIsNone(harness.load_offline_precondition(root))

    def test_incomplete_precondition_is_refused_like_a_missing_one(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "runtime").mkdir(parents=True)
            for content in ("{}", "pas du json", json.dumps({"cachedTrackId": 78})):
                harness.precondition_path(root).write_text(content, encoding="utf-8")
                self.assertIsNone(
                    harness.load_offline_precondition(root),
                    f"précondition acceptée à tort : {content[:20]}",
                )

    def test_complete_precondition_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "runtime").mkdir(parents=True)
            harness.write_offline_precondition(root, {
                "cachedTrackId": 78, "cachedTrackSizeBytes": SMALL_SIZE,
                "cachedTrackHash": SMALL_HASH, "uncachedTrackId": 79,
                "uncachedStreamPath": "/api/tracks/79/stream",
            })
            loaded = harness.load_offline_precondition(root)
        self.assertIsNotNone(loaded)
        self.assertEqual(loaded["cachedTrackId"], 78)

    def test_offline_mode_refuses_before_any_network_call(self) -> None:
        """Le refus est décidé sur le laissez-passer, pas sur un statut HTTP."""
        source = CACHE_TEST.read_text(encoding="utf-8")
        offline = source.split('if args.mode == "offline":', 1)[1]
        offline = offline.split("# --- MISS complet", 1)[0]
        guard = offline.index("OFFLINE_PRECONDITION_MISSING")
        first_request = offline.index("prove_cache_hit")
        self.assertLess(guard, first_request)

    def test_precondition_is_cleared_when_checks_fail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "runtime").mkdir(parents=True)
            harness.precondition_path(root).write_text("{}", encoding="utf-8")
            harness.clear_precondition(root)
            self.assertFalse(harness.precondition_path(root).exists())

    def test_evicted_object_is_never_reported_as_an_offline_hit(self) -> None:
        """L'objet évincé doit faire échouer le test, pas passer pour un HIT."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            harness.set_cache_root(root / "runtime/cache-finalize-offline")
            self.assertFalse(harness.object_path(root, SMALL_HASH).exists())
            report = harness.cache_disk_report(root)
        self.assertEqual(report["objectCount"], 0)
        # Le contrôle correspondant existe et porte sur la présence de l'objet.
        source = CACHE_TEST.read_text(encoding="utf-8")
        self.assertIn('"cacheObjectStillPresent": still_present', source)

    def test_offline_mode_declares_every_required_assertion(self) -> None:
        source = CACHE_TEST.read_text(encoding="utf-8")
        for field in (
            "cachedTrackId", "cachedHashPrefix", "cacheObjectPresentBeforeStop",
            "indexEntryPresentBeforeStop", "offlineGetStatus", "offlineHeadStatus",
            "offlineRangeStatus", "offlineCacheHitObserved",
            "upstreamContactedOnOfflineHit", "uncachedMissStatus",
            "internal401NotExposed",
        ):
            self.assertIn(f'"{field}"', source, f"champ hors ligne manquant : {field}")

    def test_precheck_declares_every_blocking_condition(self) -> None:
        source = CACHE_TEST.read_text(encoding="utf-8")
        for check in (
            "objectCountIsOne", "indexEntryCountIsOne", "expectedObjectPresent",
            "expectedObjectSizeMatched", "expectedHashMatched", "cacheHitProven",
            "uncachedTrackSelected",
        ):
            self.assertIn(f'"{check}"', source, f"contrôle bloquant manquant : {check}")

    def test_uncached_track_is_chosen_before_the_agent_is_stopped(self) -> None:
        """`choose_abort_track` exige un HEAD 200 : impossible agent arrêté."""
        source = CACHE_TEST.read_text(encoding="utf-8")
        precheck = source.split('if args.mode == "offline-precheck":', 1)[1]
        precheck = precheck.split('if args.mode == "offline":', 1)[0]
        self.assertIn("choose_abort_track", precheck)
        offline = source.split('if args.mode == "offline":', 1)[1]
        offline = offline.split("# --- MISS complet", 1)[0]
        self.assertNotIn("choose_abort_track", offline)
        self.assertIn("uncachedStreamPath", offline)


class ScenarioCapacityReportTest(unittest.TestCase):
    """§4 — chaque rapport publie sa configuration de capacité."""

    def tearDown(self) -> None:
        harness.set_cache_root(None)

    def test_capacity_report_publishes_every_required_field(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "runtime").mkdir(parents=True)
            harness.set_cache_root(root / "runtime/cache-abort")
            before = harness.cache_disk_report(root)
            after = harness.cache_disk_report(root)
            report = harness.capacity_report(
                root,
                {"AUDIO_CACHE_ROOT": str(root / "runtime/cache-abort"),
                 "AUDIO_CACHE_MAX_BYTES": "42"},
                "abort", before, after,
            )
        for field in ("scenario", "cacheMaxBytes", "objectCountBefore",
                      "objectCountAfter", "indexEntryCountBefore",
                      "indexEntryCountAfter", "evictionsObserved"):
            self.assertIn(field, report)
        self.assertEqual(report["scenario"], "abort")
        self.assertEqual(report["cacheMaxBytes"], 42)
        self.assertEqual(report["evictionsObserved"], 0)

    def test_evictions_are_counted_on_the_current_scenario_only(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "runtime"
            runtime.mkdir(parents=True)
            # Journal ARCHIVÉ d'un scénario précédent : ses évictions ne
            # doivent pas polluer le compte du scénario en cours.
            (runtime / "api.stdout.log.20260727T000000Z").write_text(
                json.dumps({"event": "CACHE_EVICTED", "requestId": "vieux"}) + "\n",
                encoding="utf-8",
            )
            (runtime / "api.stdout.log").write_text(
                json.dumps({"event": "CACHE_HIT", "requestId": "neuf"}) + "\n",
                encoding="utf-8",
            )
            self.assertEqual(log_reader.count_event(root, "CACHE_EVICTED"), 0)
            self.assertEqual(
                log_reader.count_event(root, "CACHE_EVICTED", current_only=False), 1
            )


class RunnerOrchestrationTest(unittest.TestCase):
    """§1, §2 et §8 — ordre, isolation et garanties du runner."""

    def setUp(self) -> None:
        self.source = RUNNER.read_text(encoding="utf-8")

    def test_offline_only_switch_exists(self) -> None:
        self.assertIn("[switch] $OfflineOnly", self.source)

    def test_offline_runs_before_abort_and_eviction_in_full_mode(self) -> None:
        full = self.source.split("elseif ($OfflineOnly) {", 1)[1].split("else {", 1)[1]
        offline = full.index("Invoke-OfflineScenario")
        abort = full.index("--mode abort")
        eviction = full.index("--mode eviction")
        self.assertLess(offline, abort, "le hors ligne doit précéder l'abandon")
        self.assertLess(abort, eviction)

    def test_abort_and_eviction_switch_to_their_own_cache(self) -> None:
        full = self.source.split("elseif ($OfflineOnly) {", 1)[1].split("else {", 1)[1]
        self.assertIn("vps_phase5_switch_scenario.sh\" abort", full)
        self.assertIn("vps_phase5_switch_scenario.sh\" eviction", full)

    def test_agent_is_never_stopped_before_the_precheck(self) -> None:
        body = self.source.split("function Invoke-OfflineScenario", 1)[1]
        precheck = body.index("--mode offline-precheck")
        stop = body.index("Stop-StorageAgent")
        self.assertLess(precheck, stop, "précondition obligatoire avant l'arrêt")

    def test_agent_restart_is_in_a_finally_block(self) -> None:
        body = self.source.split("function Invoke-OfflineScenario", 1)[1]
        body = body.split("function Copy-ToVps", 1)[0]
        self.assertIn("} finally {", body)
        self.assertIn("Restore-StorageAgent", body)
        after_finally = body.split("} finally {", 1)[1]
        self.assertIn("Restore-StorageAgent", after_finally)

    def test_outer_finally_also_restores_the_agent(self) -> None:
        outer = self.source.rsplit("} finally {", 1)[1]
        self.assertIn("Restore-StorageAgent", outer)

    def test_only_one_parallel_api_and_always_on_localhost_3001(self) -> None:
        self.assertIn("127.0.0.1:3001", self.source)
        code = code_only(self.source).lower()
        for forbidden in ("caddy", "wireguard", "netsh advfirewall", "new-netfirewallrule"):
            self.assertNotIn(forbidden, code)

    def test_switch_script_is_shipped_and_validated(self) -> None:
        self.assertIn("vps_phase5_switch_scenario.sh", self.source)

    def test_offline_summary_reports_host_side_fields(self) -> None:
        body = self.source.split("function Invoke-OfflineScenario", 1)[1]
        for field in ("agentStopped", "agentRestarted", "listenerRestored",
                      "publicDomainHealthy"):
            self.assertIn(field, body)


class ScenarioScriptsTest(unittest.TestCase):
    """§1 et §7 — bascule sans API concurrente, nettoyage de toutes les racines."""

    def test_setup_accepts_a_scenario_and_defaults_to_offline_capable(self) -> None:
        source = SETUP.read_text(encoding="utf-8")
        self.assertIn('SCENARIO="${1:-finalize-offline}"', source)
        self.assertIn('--scenario "${SCENARIO}"', source)

    def test_switch_never_leaves_two_apis_running(self) -> None:
        source = SWITCH.read_text(encoding="utf-8")
        kill = source.index("kill ")
        listener = source.index("sport = :3001")
        start = source.index("nohup node dist/server.js")
        self.assertLess(kill, listener)
        self.assertLess(listener, start)

    def test_switch_starts_each_scenario_on_an_empty_cache(self) -> None:
        source = SWITCH.read_text(encoding="utf-8")
        self.assertIn('rm -rf -- "${ROOT}/runtime/cache-${SCENARIO}"', source)
        self.assertIn("phase5-offline-precondition.json", source)

    def test_switch_rejects_an_unknown_scenario(self) -> None:
        self.assertIn("unknown_scenario", SWITCH.read_text(encoding="utf-8"))

    def test_cleanup_removes_every_cache_root_and_secret(self) -> None:
        source = CLEANUP.read_text(encoding="utf-8")
        self.assertIn('rm -rf -- "${ROOT}"/runtime/cache-*', source)
        self.assertIn("phase5-offline-precondition.json", source)
        self.assertIn("remainingCacheRoots", source)
        self.assertIn('test "${caches}" -eq 0', source)
        self.assertIn('test "${secrets}" -eq 0', source)
        self.assertIn('test "${listeners}" -eq 0', source)

    def test_no_script_touches_caddy_wireguard_or_the_firewall(self) -> None:
        for path in (SETUP, SWITCH, CLEANUP, CACHE_TEST, WRITE_ENV):
            source = code_only(path.read_text(encoding="utf-8")).lower()
            for forbidden in ("caddy", "wireguard", "wg-quick", "iptables", "nft ", "ufw "):
                self.assertNotIn(forbidden, source, f"{path.name} touche {forbidden}")

    def test_no_scenario_script_leaks_a_secret_value(self) -> None:
        for path in (SETUP, SWITCH, CLEANUP, WRITE_ENV):
            source = path.read_text(encoding="utf-8")
            self.assertNotIn("STORAGE_AGENT_SHARED_SECRET=", source)
            self.assertEqual([line for line in source.splitlines() if "eyJ" in line], [])


class EvictionScenarioIsolationTest(unittest.TestCase):
    """§2 étape D — l'éviction se prouve chez elle, jamais sur l'état offline."""

    def test_eviction_mode_fills_its_own_first_object(self) -> None:
        source = CACHE_TEST.read_text(encoding="utf-8")
        eviction = source.split("# --- eviction", 1)[1]
        self.assertIn("evict-first", eviction)
        self.assertIn('"previousObjectEvicted"', eviction)
        self.assertIn('"evictionEventObserved"', eviction)

    def test_full_mode_no_longer_chains_the_abort_scenario(self) -> None:
        """Le point de départ du défaut : abandon enchaîné dans le même cache."""
        source = CACHE_TEST.read_text(encoding="utf-8")
        block = source.split('if args.mode in ("full", "finalize"):', 1)[1]
        block = block.split("# --- Modes utilisant la seconde piste", 1)[0]
        self.assertNotIn("run_abort_scenario", block)
        self.assertIn("noEvictionOnFinalizeScenario", block)

    def test_abort_scenario_asserts_no_eviction_happened(self) -> None:
        source = CACHE_TEST.read_text(encoding="utf-8")
        self.assertIn('"noEvictionOnAbortScenario"', source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
