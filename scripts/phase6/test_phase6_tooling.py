#!/usr/bin/env python3
"""Régression de l'outillage de déploiement shadow Phase 6.

Ces tests portent sur l'OUTILLAGE, pas sur le VPS : aucun n'ouvre de
connexion SSH, aucun ne touche à un service. Ils vérifient ce qui, s'il
cédait, produirait un déploiement silencieusement faux — un artefact
contenant un secret, un cleanup qui déborde de ses racines, un contrôle ABI
absent, une unité systemd qui empêcherait SQLite d'écrire.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import phase6_manifest as manifest  # noqa: E402
import phase6_paths as paths  # noqa: E402

UNIT = HERE / "homespotify-api-shadow.service"
ENV_TEMPLATE = HERE / "api-shadow.env.template"
ORCHESTRATOR = HERE / "run_phase6_shadow_deploy.ps1"
CLEANUP = HERE / "vps_phase6_cleanup.sh"
PREFLIGHT = HERE / "vps_phase6_preflight.sh"
INSTALL = HERE / "vps_phase6_install_release.sh"
ROLLBACK = HERE / "vps_phase6_rollback.sh"
SYSTEMD_SETUP = HERE / "vps_phase6_systemd_setup.sh"
SNAPSHOT_MJS = HERE / "phase6_sqlite_snapshot.mjs"
SNAPSHOT_PS1 = HERE / "snapshot_sqlite_shadow.ps1"
BUILD_PS1 = HERE / "build_shadow_artifact.ps1"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def code_only(text: str) -> str:
    """Texte débarrassé des commentaires.

    Ces scripts CITENT `node-gyp`, `caddy`, `wireguard` ou `LUCIDA` pour
    documenter qu'ils ne les utilisent pas. Une recherche brute confondrait la
    documentation de la garantie avec sa violation.
    """
    return "\n".join(
        line for line in text.splitlines()
        if not line.strip().startswith("#")
    )


# ===========================================================================
# Manifeste
# ===========================================================================


class ManifestTest(unittest.TestCase):
    def _artifact(self, root: Path) -> None:
        (root / "dist").mkdir(parents=True)
        (root / "dist" / "server.js").write_text("console.log(1)\n", encoding="utf-8")
        (root / "dist" / "app.js").write_text("export const a = 1\n", encoding="utf-8")
        (root / "package.json").write_text('{"name":"x"}\n', encoding="utf-8")

    def test_manifest_is_reproducible(self) -> None:
        """Même contenu, même empreinte : le contrôle de transfert est exact."""
        digests = []
        for _ in range(2):
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                self._artifact(root)
                entries = manifest.build_entries(root)
                digests.append(manifest.manifest_digest(entries))
        self.assertEqual(digests[0], digests[1])

    def test_manifest_ignores_file_order_and_absolute_paths(self) -> None:
        with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
            for directory in (a, b):
                self._artifact(Path(directory))
            first = manifest.manifest_digest(manifest.build_entries(Path(a)))
            second = manifest.manifest_digest(manifest.build_entries(Path(b)))
        self.assertEqual(first, second)

    def test_release_id_carries_commit_and_manifest_digest(self) -> None:
        release = manifest.make_release_id("20260728T101500Z", "033f4f51e2346", "9a3bd2c1ff")
        self.assertTrue(release.startswith("20260728T101500Z-"))
        self.assertIn("033f4f51", release)
        self.assertIn("9a3bd2c1", release)

    def test_secrets_and_databases_are_excluded(self) -> None:
        for name in (".env", "api/.env", ".hmac-secret", "data/runtime.db",
                     "data/runtime.db-wal", "x.sqlite", "server.key", "tls.pem",
                     "logs/api.log", "music/track.flac", "a.mp3"):
            with self.subTest(name=name):
                self.assertTrue(manifest.is_excluded(name), name)

    def test_windows_node_modules_is_excluded(self) -> None:
        for name in ("node_modules/better-sqlite3/build/Release/better_sqlite3.node",
                     "dist/node_modules/x.js", "node_modules/.bin/tsc"):
            with self.subTest(name=name):
                self.assertTrue(manifest.is_excluded(name), name)

    def test_tests_and_sources_not_needed_at_runtime_are_excluded(self) -> None:
        for name in ("src/app.test.ts", "src/x.spec.ts", "test/harness.ts",
                     "dist/server.js.map"):
            with self.subTest(name=name):
                self.assertTrue(manifest.is_excluded(name), name)

    def test_runtime_files_are_kept(self) -> None:
        for name in ("dist/server.js", "package.json", "drizzle/0001_init.sql"):
            with self.subTest(name=name):
                self.assertFalse(manifest.is_excluded(name), name)

    def test_excluded_files_never_enter_the_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._artifact(root)
            (root / ".env").write_text("AUTH_TOKEN_SECRET=tres-secret\n", encoding="utf-8")
            (root / "node_modules").mkdir()
            (root / "node_modules" / "x.node").write_bytes(b"\x00")
            entries = manifest.build_entries(root)
        listed = {e["path"] for e in entries}
        self.assertNotIn(".env", listed)
        self.assertFalse(any(p.startswith("node_modules/") for p in listed))
        self.assertIn("dist/server.js", listed)

    def test_staging_equals_manifest_after_pruning(self) -> None:
        """Défaut réel du 2026-07-27 : 207 fichiers assemblés, 107 déclarés.

        Les `.map` étaient exclus du manifeste mais restaient copiés dans le
        staging. Le transfert aurait donc été refusé sur le VPS en `EN_TROP`,
        après coup. Le staging doit être égal au manifeste PAR CONSTRUCTION.
        """
        import phase6_build_manifest as builder

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._artifact(root)
            (root / "dist" / "server.js.map").write_text('{"v":3}\n', encoding="utf-8")
            (root / "dist" / "app.test.js").write_text("x\n", encoding="utf-8")
            (root / ".env").write_text("AUTH_TOKEN_SECRET=tres-secret\n", encoding="utf-8")

            removed = builder.prune_excluded(root)
            built = manifest.build_manifest(
                root, commit="c" * 40, built_at="20260728T101500Z",
                node_version="v22.18.0", node_abi="127", arch="x64",
                bundle_id="linux-x64-node22.18.0-abi127",
            )
            self.assertEqual(manifest.verify_manifest(root, built), [])
            present = {p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file()}
        self.assertIn("dist/server.js.map", removed)
        self.assertIn(".env", removed)
        self.assertNotIn("dist/server.js.map", present)
        self.assertNotIn(".env", present)
        self.assertIn("dist/server.js", present)

    def test_verification_detects_every_kind_of_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self._artifact(root)
            built = manifest.build_manifest(
                root, commit="c" * 40, built_at="20260728T101500Z",
                node_version="v22.18.0", node_abi="127", arch="x64",
                bundle_id="linux-x64-node22.18.0-abi127",
            )
            self.assertEqual(manifest.verify_manifest(root, built), [])
            (root / "dist" / "server.js").write_text("console.log(2)\n", encoding="utf-8")
            self.assertIn("EMPREINTE dist/server.js", manifest.verify_manifest(root, built))
            (root / "dist" / "intrus.js").write_text("x\n", encoding="utf-8")
            self.assertTrue(any(p.startswith("EN_TROP") for p in manifest.verify_manifest(root, built)))
            (root / "package.json").unlink()
            self.assertIn("MANQUANT package.json", manifest.verify_manifest(root, built))


# ===========================================================================
# Garde-fou des chemins
# ===========================================================================


class ShadowPathGuardTest(unittest.TestCase):
    def test_shadow_paths_are_accepted(self) -> None:
        for path in ("/opt/homespotify-api-shadow",
                     "/opt/homespotify-api-shadow/releases/abc",
                     "/var/lib/homespotify-shadow/cache/audio",
                     "/etc/homespotify/api-shadow.env",
                     "/etc/systemd/system/homespotify-api-shadow.service"):
            with self.subTest(path=path):
                self.assertEqual(str(paths.assert_under_shadow_root(path)), path)

    def test_paths_outside_shadow_roots_are_refused(self) -> None:
        for path in ("/", "/etc", "/var/lib", "/opt", "/home/debian",
                     "/etc/homespotify", "/usr/local/bin/node", "/var/lib/homespotify"):
            with self.subTest(path=path):
                with self.assertRaises(paths.ShadowPathError):
                    paths.assert_under_shadow_root(path)

    def test_previous_phase_trees_are_protected(self) -> None:
        """Les arbres Phases 4.5 et 5 ne doivent jamais être supprimables."""
        for path in ("/home/debian/homespotify-phase45",
                     "/home/debian/homespotify-phase5",
                     "/home/debian/homespotify-phase5/cache",
                     "/etc/caddy", "/etc/caddy/Caddyfile", "/etc/wireguard/wg0.conf"):
            with self.subTest(path=path):
                with self.assertRaises(paths.ShadowPathError):
                    paths.assert_under_shadow_root(path)

    def test_relative_and_traversal_paths_are_refused(self) -> None:
        for path in ("relative/x", "/var/lib/homespotify-shadow/../../etc",
                     "/opt/homespotify-api-shadow/../homespotify-phase5"):
            with self.subTest(path=path):
                with self.assertRaises(paths.ShadowPathError):
                    paths.assert_under_shadow_root(path)

    def test_release_id_cannot_escape_the_releases_directory(self) -> None:
        for bad in ("../evil", "a/b", "", ".", ".."):
            with self.subTest(bad=bad):
                with self.assertRaises(paths.ShadowPathError):
                    paths.release_path(bad)
        self.assertEqual(
            str(paths.release_path("20260728T101500Z-033f4f51-9a3bd2c1")),
            "/opt/homespotify-api-shadow/releases/20260728T101500Z-033f4f51-9a3bd2c1",
        )

    def test_shadow_port_is_3002_and_never_3001(self) -> None:
        self.assertEqual(paths.SHADOW_PORT, 3002)
        self.assertEqual(paths.SHADOW_HOST, "127.0.0.1")


# ===========================================================================
# Environnement
# ===========================================================================


class EnvironmentTemplateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.text = read(ENV_TEMPLATE)
        self.values = dict(
            line.split("=", 1) for line in self.text.splitlines()
            if line and not line.startswith("#") and "=" in line
        )

    def test_no_secret_value_is_committed(self) -> None:
        for key in ("AUDIO_REMOTE_SHARED_SECRET", "AUTH_TOKEN_SECRET"):
            self.assertEqual(self.values[key], "__A_INJECTER__")

    def test_binds_locally_on_3002(self) -> None:
        self.assertEqual(self.values["HOST"], "127.0.0.1")
        self.assertEqual(self.values["PORT"], "3002")

    def test_production_mode_and_info_logging(self) -> None:
        # NODE_ENV=test désactiverait entièrement le logger (L-108) : aucune
        # preuve ne serait alors possible pendant les tests shadow.
        self.assertEqual(self.values["NODE_ENV"], "production")
        self.assertEqual(self.values["LOG_LEVEL"], "info")

    def test_cached_mode_over_remote_provider(self) -> None:
        self.assertEqual(self.values["AUDIO_STORAGE_MODE"], "cached")
        self.assertEqual(self.values["AUDIO_REMOTE_BASE_URL"], "http://10.8.0.2:3100")

    def test_balanced_cache_profile(self) -> None:
        self.assertEqual(int(self.values["AUDIO_CACHE_MAX_BYTES"]), 12 * 1024**3)
        self.assertEqual(int(self.values["AUDIO_CACHE_MIN_FREE_BYTES"]), 6 * 1024**3)
        self.assertEqual(int(self.values["AUDIO_CACHE_MAX_BYTES"]), paths.CACHE_MAX_BYTES)
        self.assertEqual(int(self.values["AUDIO_CACHE_MIN_FREE_BYTES"]), paths.CACHE_MIN_FREE_BYTES)

    def test_every_path_is_absolute_and_under_the_shadow_state_root(self) -> None:
        values = {}
        for line in read(ENV_TEMPLATE).splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or "=" not in stripped:
                continue
            key, value = stripped.split("=", 1)
            values[key] = value

        release_paths = {"ANTRA_DIR", "ANTRA_PYTHON"}
        path_keys = {
            key for key in values
            if key.endswith("_DIR") or key.endswith("_ROOT")
            or key.endswith("_PATH") or key in {
                "DB_PATH", "HOME", "PROVIDER_STATS_DB_PATH"
            }
        }
        for key in sorted(path_keys):
            with self.subTest(key=key):
                value = values[key]
                self.assertTrue(value.startswith("/"), key)
                if key in release_paths:
                    self.assertTrue(value.startswith("/opt/homespotify-api-shadow/"), key)
                else:
                    self.assertTrue(value.startswith("/var/lib/homespotify-shadow/"), key)

    def test_uses_real_config_variable_names(self) -> None:
        """`config.ts` lit AUDIO_CACHE_ROOT et OFFLINE_CACHE_DIR.

        Employer les noms du cahier des charges (AUDIO_CACHE_DIR,
        OFFLINE_VARIANTS_DIR) laisserait s'appliquer les défauts relatifs.
        """
        self.assertIn("AUDIO_CACHE_ROOT=", self.text)
        self.assertIn("OFFLINE_CACHE_DIR=", self.text)
        self.assertNotIn("AUDIO_CACHE_DIR=", self.text)
        self.assertNotIn("OFFLINE_VARIANTS_DIR=", self.text)

    def test_backups_and_discovery_are_disabled(self) -> None:
        self.assertEqual(self.values["BACKUP_ENABLED"], "false")
        self.assertEqual(self.values["DISCOVERY_ENABLED"], "false")

    def test_no_lucida_variable(self) -> None:
        """Le modèle CITE Lucida en commentaire pour dire qu'il l'exclut."""
        self.assertNotIn("LUCIDA", code_only(self.text).upper())
        self.assertNotIn("LUCIDA", "".join(self.values))

    def test_db_path_matches_the_declared_shadow_layout(self) -> None:
        self.assertEqual(self.values["DB_PATH"], str(paths.DB_PATH))
        self.assertEqual(self.values["AUDIO_CACHE_ROOT"], str(paths.CACHE_DIR))
        self.assertEqual(self.values["COVERS_DIR"], str(paths.COVERS_DIR))
        self.assertEqual(self.values["INCOMING_DIR"], str(paths.INCOMING_DIR))
        self.assertEqual(self.values["OFFLINE_CACHE_DIR"], str(paths.OFFLINE_VARIANTS_DIR))


# ===========================================================================
# Unité systemd
# ===========================================================================


class SystemdUnitTest(unittest.TestCase):
    def setUp(self) -> None:
        self.text = read(UNIT)

    def test_sections_are_present_and_ordered(self) -> None:
        for section in ("[Unit]", "[Service]", "[Install]"):
            self.assertIn(section, self.text)
        self.assertLess(self.text.index("[Unit]"), self.text.index("[Service]"))
        self.assertLess(self.text.index("[Service]"), self.text.index("[Install]"))

    def test_every_directive_is_a_key_value_pair(self) -> None:
        for line in self.text.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or stripped.startswith("["):
                continue
            self.assertIn("=", stripped, f"directive invalide : {stripped}")

    def test_dedicated_user_and_group(self) -> None:
        self.assertIn("User=homespotify", self.text)
        self.assertIn("Group=homespotify", self.text)

    def test_runs_from_current_symlink_with_absolute_node(self) -> None:
        self.assertIn("WorkingDirectory=/opt/homespotify-api-shadow/current", self.text)
        self.assertIn("ExecStart=/usr/local/bin/node dist/server.js", self.text)
        self.assertIn("EnvironmentFile=/etc/homespotify/api-shadow.env", self.text)

    def test_restart_policy_is_bounded(self) -> None:
        for directive in ("Restart=on-failure", "RestartSec=5", "TimeoutStopSec=30",
                          "KillSignal=SIGTERM", "UMask=0027", "LimitNOFILE=8192"):
            self.assertIn(directive, self.text)

    def test_hardening_directives(self) -> None:
        for directive in ("NoNewPrivileges=true", "PrivateTmp=true",
                          "ProtectSystem=strict", "ProtectHome=true",
                          "CapabilityBoundingSet=", "TasksMax=256"):
            self.assertIn(directive, self.text)

    def test_readwritepaths_is_limited_to_the_shadow_state_root(self) -> None:
        """ProtectSystem=strict sans ReadWritePaths correct casse SQLite."""
        lines = [l.strip() for l in self.text.splitlines() if l.strip().startswith("ReadWritePaths=")]
        self.assertEqual(len(lines), 1)
        value = lines[0].split("=", 1)[1].strip()
        self.assertEqual(value, "/var/lib/homespotify-shadow")
        for forbidden in ("/opt", "/etc", "/home", "/usr", "/var/lib "):
            self.assertNotIn(f"ReadWritePaths={forbidden}", self.text)

    def test_address_families_allow_ipv4_for_the_storage_agent(self) -> None:
        line = next(l for l in self.text.splitlines() if l.startswith("RestrictAddressFamilies="))
        self.assertIn("AF_INET", line)
        self.assertIn("AF_UNIX", line)

    def test_memorymax_is_absent_until_the_soak_provides_a_baseline(self) -> None:
        directives = [l.strip() for l in self.text.splitlines()
                      if l.strip().startswith("MemoryMax=")]
        self.assertEqual(directives, [])

    def test_unit_never_references_caddy_dns_or_the_firewall(self) -> None:
        lowered = "\n".join(l for l in self.text.splitlines()
                            if not l.strip().startswith("#")).lower()
        for forbidden in ("caddy", "wireguard", "iptables", "nftables", "ufw"):
            self.assertNotIn(forbidden, lowered)


# ===========================================================================
# Scripts distants
# ===========================================================================


class RemoteScriptsTest(unittest.TestCase):
    def test_preflight_checks_node_abi_and_arch(self) -> None:
        text = read(PREFLIGHT)
        self.assertIn('REQUIRED_NODE="v22.18.0"', text)
        self.assertIn('REQUIRED_ABI="127"', text)
        self.assertIn('REQUIRED_ARCH="x64"', text)

    def test_preflight_checks_both_native_modules(self) -> None:
        text = read(PREFLIGHT)
        self.assertIn("better_sqlite3.node", text)
        self.assertIn("argon2.linux-x64-gnu.node", text)
        self.assertIn("sha256sum", text)

    def test_preflight_fails_when_bundle_is_missing(self) -> None:
        text = read(PREFLIGHT)
        self.assertIn("BUNDLE_ABSENT", text)
        self.assertIn("MODULE_NATIF_ABSENT", text)

    def test_preflight_really_requires_better_sqlite3(self) -> None:
        text = read(PREFLIGHT)
        self.assertIn("SMOKE_ECHEC", text)
        self.assertIn("mkdtempSync", text)
        self.assertIn("integrity_check", text)
        # La variable doit être exportée AVANT l'appel à node.
        self.assertLess(text.index('export HS_BUNDLE'), text.index('SMOKE="$(node'))

    def test_no_remote_script_runs_npm_install(self) -> None:
        for path in (PREFLIGHT, INSTALL, SYSTEMD_SETUP, ROLLBACK, CLEANUP):
            with self.subTest(script=path.name):
                text = code_only(read(path))
                self.assertNotIn("npm install", text)
                self.assertNotIn("npm ci", text)
                self.assertNotIn("pnpm install", text)
                self.assertNotIn("node-gyp", text)

    def test_install_promotes_atomically(self) -> None:
        text = read(INSTALL)
        self.assertIn("mv -T", text)
        self.assertIn("current.new", text)
        # Le manifeste et le préflight passent AVANT toute bascule.
        self.assertLess(text.index("phase6_manifest_verify.py"), text.index("current.new"))
        self.assertLess(text.index("vps_phase6_preflight.sh"), text.index("current.new"))

    def test_install_records_previous_for_rollback(self) -> None:
        self.assertIn("previous", read(INSTALL))

    def test_rollback_restores_previous_and_keeps_the_faulty_release(self) -> None:
        text = read(ROLLBACK)
        self.assertIn("PREVIOUS_ABSENT", text)
        self.assertIn("faultyRetained", text)
        self.assertNotIn("rm -rf", text)

    def test_cleanup_guards_every_deletion(self) -> None:
        text = read(CLEANUP)
        self.assertIn("guard()", text)
        self.assertIn("HORS_RACINE_SHADOW", text)
        self.assertIn("CHEMIN_PROTEGE", text)
        # Aucune suppression ne contourne le garde-fou.
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith("rm -rf") and "remove()" not in stripped:
                self.assertIn('rm -rf -- "$1"', stripped, f"suppression non gardée : {stripped}")

    def test_cleanup_protects_previous_phase_trees(self) -> None:
        text = read(CLEANUP)
        self.assertIn("homespotify-phase45", text)
        self.assertIn("homespotify-phase5", text)
        self.assertIn("preservedProtectedPaths", text)

    def test_cleanup_confirms_port_3002_is_free(self) -> None:
        text = read(CLEANUP)
        self.assertIn("sport = :3002", text)
        self.assertIn('test "${LISTENERS}" -eq 0', text)

    def test_no_script_touches_caddy_dns_or_firewall(self) -> None:
        """Aucun script ne pilote Caddy, WireGuard, le DNS ni le pare-feu.

        `vps_phase6_cleanup.sh` est la seule exception admise : il CITE
        /etc/caddy et /etc/wireguard dans sa liste de chemins PROTÉGÉS, ce
        qui est l'inverse d'y toucher. Le test l'autorise donc uniquement sur
        la ligne de déclaration `PROTECTED=`, et nulle part ailleurs.
        """
        forbidden_terms = ("caddy", "wireguard", "iptables", "nftables",
                           "ufw ", "named ", "bind9")
        for path in (PREFLIGHT, INSTALL, SYSTEMD_SETUP, ROLLBACK, CLEANUP,
                     HERE / "vps_phase6_shadow_tests.py"):
            with self.subTest(script=path.name):
                for line in code_only(read(path)).lower().splitlines():
                    for forbidden in forbidden_terms:
                        if forbidden not in line:
                            continue
                        self.assertTrue(
                            path is CLEANUP and line.strip().startswith("protected="),
                            f"{path.name} touche {forbidden} : {line.strip()[:70]}",
                        )

    def test_systemd_setup_verifies_before_installing(self) -> None:
        text = read(SYSTEMD_SETUP)
        self.assertIn("systemd-analyze verify", text)
        self.assertIn("--verify-only", text)
        self.assertLess(text.index("systemd-analyze verify"), text.index("systemctl enable"))

    def test_systemd_setup_refuses_a_permissive_env_file(self) -> None:
        self.assertIn("ENV_MODE_INVALIDE", read(SYSTEMD_SETUP))

    def test_shadow_tests_target_3002_and_prove_hits_by_event(self) -> None:
        text = read(HERE / "vps_phase6_shadow_tests.py")
        self.assertIn("PORT = 3002", text.replace("HOST, PORT = \"127.0.0.1\", 3002",
                                                  "PORT = 3002"))
        self.assertIn("CACHE_HIT", text)
        self.assertIn("upstreamNotContactedOnHit", text)
        self.assertIn("internal401NotExposed", text)

    def test_no_script_contains_a_secret_value(self) -> None:
        # Les fichiers de tests portent des fixtures volontaires
        # ("tres-secret", "AAAA…") qui servent de contrôles négatifs : les
        # analyser reviendrait à signaler comme fuite la preuve qu'il n'y en a
        # pas.
        fixtures = {"test_phase6_tooling.py", "test_phase6_staging.py",
                    "test_phase6_activation.py"}
        for path in HERE.glob("*"):
            if not path.is_file() or path.name in fixtures:
                continue
            text = read(path)
            with self.subTest(file=path.name):
                self.assertNotIn("BEGIN OPENSSH PRIVATE KEY", text)
                self.assertNotIn("eyJhbGciOi", text)
                for marker in ("AUTH_TOKEN_SECRET=", "AUDIO_REMOTE_SHARED_SECRET="):
                    for line in text.splitlines():
                        if marker in line and "__A_INJECTER__" not in line:
                            self.assertFalse(
                                any(c.isalnum() for c in line.split(marker, 1)[1][:8]),
                                f"valeur suspecte dans {path.name}: {line[:60]}",
                            )


# ===========================================================================
# Orchestrateur et dry-run
# ===========================================================================


class OrchestratorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.text = read(ORCHESTRATOR)

    def test_declares_dry_run(self) -> None:
        self.assertIn("[switch] $DryRun", self.text)

    def test_dry_run_opens_no_ssh_connection(self) -> None:
        # Depuis la Phase 6.2, l'orchestrateur SAIT ouvrir des connexions. La
        # garantie du dry-run n'est donc plus « le script ne contient aucun
        # SSH » mais « la branche dry-run n'en invoque aucun ». C'est cette
        # branche, et elle seule, qui est découpée ici.
        branch = self.text.split("if ($DryRun) {", 1)[1].split(
            "if ($CleanupStaging) {", 1)[0]
        for forbidden in ("ssh.exe", "scp.exe", "Invoke-Ssh", "Invoke-Scp",
                          "Copy-ToVps"):
            self.assertNotIn(forbidden, branch)
        self.assertIn("sshConnectionsOpened = $script:SshConnections", branch)

    def test_guards_worktree_and_branch(self) -> None:
        self.assertIn("phase6/vps-final-c", self.text)
        self.assertIn("rev-parse --show-toplevel", self.text)
        self.assertIn('Fail "branche inattendue', self.text)

    def test_installation_modes_are_not_armed_before_phase63(self) -> None:
        # La Phase 6.2 arme le STAGING (dépôt sans activation) et son
        # nettoyage. L'installation — utilisateur système, unité systemd,
        # bascule de `current` — reste désarmée dans le code lui-même, pas
        # seulement dans la procédure.
        self.assertIn("appartiennent à la Phase 6.3", self.text)
        for armed_in_62 in ("[switch] $StageOnly", "[switch] $CleanupStaging"):
            self.assertIn(armed_in_62, self.text)
        for reserved in ("vps_phase6_install_release.sh --",
                         "systemctl enable", "systemctl start", "useradd"):
            self.assertNotIn(reserved, self.text)

    def test_requires_an_explicit_mode(self) -> None:
        self.assertIn("préciser -DryRun", self.text)

    def test_build_never_ships_windows_node_modules(self) -> None:
        text = read(BUILD_PS1)
        self.assertIn("node_modules", text)  # cité pour dire qu'il est exclu
        self.assertNotIn("Copy-Item -Recurse -Force -LiteralPath $modules", text)
        self.assertIn("bundle immuable", text)


# ===========================================================================
# VACUUM INTO réel
# ===========================================================================


def node_available() -> bool:
    return shutil.which("node") is not None


def better_sqlite3_path() -> Path | None:
    candidate = REPO / "services" / "api" / "node_modules" / "better-sqlite3"
    return candidate if candidate.is_dir() else None


class SqliteSnapshotTest(unittest.TestCase):
    """Exécute réellement le script de snapshot sur une base temporaire."""

    def setUp(self) -> None:
        if not node_available() or better_sqlite3_path() is None:
            self.skipTest("node ou better-sqlite3 local indisponible")

    def _source(self, path: Path) -> tuple[int, str]:
        db = sqlite3.connect(path)
        try:
            db.execute("PRAGMA journal_mode = WAL")
            db.execute("CREATE TABLE __drizzle_migrations (id INTEGER PRIMARY KEY, hash TEXT)")
            db.executemany("INSERT INTO __drizzle_migrations (hash) VALUES (?)",
                           [(f"h{i}",) for i in range(18)])
            db.execute("CREATE TABLE tracks (id INTEGER PRIMARY KEY, hash TEXT)")
            db.execute("INSERT INTO tracks (hash) VALUES ('a')")
            db.commit()
        finally:
            db.close()
        import hashlib
        return path.stat().st_size, hashlib.sha256(path.read_bytes()).hexdigest()

    def _run(self, source: Path, target: Path) -> tuple[int, dict]:
        result = subprocess.run(
            ["node", str(SNAPSHOT_MJS), str(source), str(target), str(better_sqlite3_path())],
            capture_output=True, text=True, timeout=120, check=False,
        )
        payload = {}
        for line in result.stdout.splitlines():
            if line.strip().startswith("{"):
                payload = json.loads(line)
        return result.returncode, payload

    def test_vacuum_into_produces_a_verified_copy(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "runtime.db"
            size_before, sha_before = self._source(source)
            code, report = self._run(source, root / "copy.db")
            self.assertEqual(code, 0, report)
            self.assertTrue(report.get("ok"), report)
            self.assertEqual(report["integrityCheck"], "ok")
            self.assertEqual(report["foreignKeyViolations"], 0)
            self.assertEqual(report["drizzleMigrations"], 18)
            self.assertEqual(report["sourceUserVersion"], 0)
            self.assertTrue(report["userVersionExpectedZero"])
            # La source est intacte, à l'octet près.
            import hashlib
            self.assertEqual(source.stat().st_size, size_before)
            self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), sha_before)
            self.assertTrue((root / "copy.db").is_file())

    def test_refuses_to_overwrite_an_existing_destination(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "runtime.db"
            self._source(source)
            target = root / "copy.db"
            target.write_bytes(b"deja la")
            code, report = self._run(source, target)
            self.assertNotEqual(code, 0)
            self.assertEqual(report.get("error"), "DESTINATION_EXISTE")
            self.assertEqual(target.read_bytes(), b"deja la")

    def test_missing_source_is_refused(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            code, report = self._run(root / "absente.db", root / "copy.db")
            self.assertNotEqual(code, 0)
            self.assertEqual(report.get("error"), "SOURCE_ABSENTE")

    def test_failed_checks_remove_the_copy(self) -> None:
        """Une base sans __drizzle_migrations doit échouer ET ne rien laisser."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "runtime.db"
            db = sqlite3.connect(source)
            db.execute("CREATE TABLE tracks (id INTEGER PRIMARY KEY)")
            db.commit()
            db.close()
            target = root / "copy.db"
            code, report = self._run(source, target)
            self.assertNotEqual(code, 0)
            self.assertFalse(target.exists(), "la copie non validée doit être supprimée")
            self.assertTrue(report.get("targetRemoved"))


class ScriptSyntaxTest(unittest.TestCase):
    def test_bash_scripts_parse(self) -> None:
        if shutil.which("bash") is None:
            self.skipTest("bash indisponible")
        for path in HERE.glob("*.sh"):
            with self.subTest(script=path.name):
                result = subprocess.run(["bash", "-n", str(path)],
                                        capture_output=True, text=True, check=False)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_python_scripts_compile(self) -> None:
        import py_compile
        for path in HERE.glob("*.py"):
            with self.subTest(script=path.name):
                py_compile.compile(str(path), doraise=True)

    def test_scripts_are_idempotent_by_construction(self) -> None:
        """Les scripts d'installation doivent tolérer d'être rejoués."""
        self.assertIn("deja presente", read(INSTALL))
        self.assertIn("id -u", read(SYSTEMD_SETUP))
        self.assertIn("install -d", read(SYSTEMD_SETUP))
        self.assertIn("deja previous", read(ROLLBACK))


if __name__ == "__main__":
    unittest.main(verbosity=2)
