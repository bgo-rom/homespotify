#!/usr/bin/env python3
"""Régression de l'outillage de STAGING Phase 6.2.

Ces tests portent sur l'outillage, pas sur le VPS : aucun n'ouvre de connexion
SSH, aucun ne touche à un service. Ils verrouillent les propriétés dont la
perte produirait un dépôt silencieusement faux ou dangereux — un secret dans
une ligne de commande, un cleanup qui déborde de sa racine, des pochettes
absentes sans NO-GO, une piste de test synthétique, un `server.js` démarré par
un préflight.
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import phase6_covers as covers  # noqa: E402
import phase6_env as shadow_env  # noqa: E402
import phase6_manifest as manifest  # noqa: E402
import phase6_select_tracks as tracks  # noqa: E402
import phase6_staging as staging  # noqa: E402

ORCHESTRATOR = HERE / "run_phase6_shadow_deploy.ps1"
STAGE_PREFLIGHT = HERE / "vps_phase6_stage_preflight.sh"
STAGING_CLEANUP = HERE / "vps_phase6_staging_cleanup.sh"
PROBE = HERE / "phase6_probe_agent.mjs"
ENV_TEMPLATE = HERE / "api-shadow.env.template"

FAKE_SECRET_A = "A" * 64
FAKE_SECRET_B = "B" * 96
FAKE_SECRET_C = "premium-key-test-only"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def code_only(text: str, *, style: str = "hash") -> str:
    """Texte débarrassé des commentaires.

    Ces scripts CITENT `server.js`, `systemctl` ou `LUCIDA` pour documenter
    qu'ils ne les utilisent pas. Une recherche brute confondrait la
    documentation de la garantie avec sa violation.

    Le marqueur de commentaire dépend du langage, et se tromper est
    silencieusement destructeur : en style « slash », `*` ouvre une ligne de
    JSDoc, mais en shell `*)` ouvre une branche de `case` — filtrer `*`
    partout effacerait précisément les garde-fous qu'on veut vérifier.
    """
    markers = ("#",) if style == "hash" else ("//", "*", "/*")
    return "\n".join(
        line for line in text.splitlines()
        if not line.strip().startswith(markers)
    )


def code_of(path: Path) -> str:
    """`code_only()` avec le style de commentaire du fichier."""
    style = "slash" if path.suffix == ".mjs" else "hash"
    return code_only(read(path), style=style)


# ===========================================================================
# Bornage de la racine de staging
# ===========================================================================
class StagingGuardTest(unittest.TestCase):
    def test_staging_root_is_the_documented_unprivileged_path(self) -> None:
        self.assertEqual(
            str(staging.STAGING_ROOT), "/home/debian/homespotify-phase6-staging"
        )
        # Aucune racine privilégiée : la Phase 6.2 n'écrit ni sous /opt, ni
        # sous /var/lib, ni sous /etc.
        for forbidden in ("/opt", "/var/lib", "/etc"):
            self.assertFalse(str(staging.STAGING_ROOT).startswith(forbidden))

    def test_paths_under_the_staging_root_are_accepted(self) -> None:
        for path in (staging.STAGING_ROOT, staging.RELEASES_DIR,
                     staging.COVERS_DIR, staging.SECRETS_DIR,
                     staging.ENV_FILE_STAGED, staging.BUNDLE_DIR):
            self.assertEqual(staging.assert_under_staging_root(path), path)

    def test_dangerous_targets_are_refused(self) -> None:
        for target in ("", " ", "/", "/home", "/home/debian", "/opt", "/var",
                       "/var/lib", "/etc", "/usr", "/root"):
            with self.assertRaises(staging.StagingPathError, msg=target):
                staging.assert_under_staging_root(target)

    def test_traversal_and_relative_paths_are_refused(self) -> None:
        for target in ("/home/debian/homespotify-phase6-staging/../../etc/passwd",
                       "/home/debian/homespotify-phase6-staging/..",
                       "homespotify-phase6-staging", "./staging"):
            with self.assertRaises(staging.StagingPathError, msg=target):
                staging.assert_under_staging_root(target)

    def test_other_phases_are_never_deletable(self) -> None:
        for target in ("/home/debian/homespotify-phase45",
                       "/home/debian/homespotify-phase45/api/node_modules",
                       "/home/debian/homespotify-phase5/data",
                       "/etc/caddy/Caddyfile", "/etc/wireguard/wg0.conf"):
            with self.assertRaises(staging.StagingPathError, msg=target):
                staging.assert_under_staging_root(target)

    def test_service_roots_are_out_of_scope_for_phase_62(self) -> None:
        # Les racines du SERVICE appartiennent à la Phase 6.3. Les accepter
        # ici rendrait le cleanup de staging capable de casser un service.
        for target in ("/opt/homespotify-api-shadow",
                       "/opt/homespotify-api-shadow/releases/x",
                       "/var/lib/homespotify-shadow",
                       "/etc/homespotify/api-shadow.env"):
            with self.assertRaises(staging.StagingPathError, msg=target):
                staging.assert_under_staging_root(target)

    def test_release_directory_is_marked_staging(self) -> None:
        path = staging.release_staging_path("20260728T101500Z-a6fea6d7-1234abcd")
        self.assertTrue(str(path).endswith(".staging"))
        self.assertIn("/releases/", str(path))
        for invalid in ("", ".", "..", "a/b"):
            with self.assertRaises(staging.StagingPathError):
                staging.release_staging_path(invalid)


class StagingCleanupScriptTest(unittest.TestCase):
    def setUp(self) -> None:
        self.text = read(STAGING_CLEANUP)
        self.code = code_of(STAGING_CLEANUP)

    def test_the_only_deletable_root_is_written_in_the_script(self) -> None:
        self.assertIn('ROOT="/home/debian/homespotify-phase6-staging"', self.code)
        # Aucune cible n'est prise en argument : `rm -rf "$1"` est la forme
        # exacte qui efface une machine quand la variable est vide.
        self.assertNotIn('rm -rf -- "$1"', self.code)
        self.assertNotIn('rm -rf "$1"', self.code)
        self.assertIn('rm -rf --one-file-system -- "${ROOT}"', self.code)

    def test_every_deletion_passes_the_guard(self) -> None:
        self.assertIn('guard "${ROOT}"', self.code)
        for refusal in ("CIBLE_VIDE", "REMONTEE_INTERDITE", "CIBLE_INTERDITE",
                        "CHEMIN_PROTEGE", "RACINE_EST_UN_LIEN",
                        "HORS_RACINE_STAGING"):
            self.assertIn(refusal, self.code)

    def test_other_phases_are_named_as_protected(self) -> None:
        for protected in ("homespotify-phase45", "homespotify-phase5",
                          "/etc/caddy", "/etc/wireguard"):
            self.assertIn(protected, self.code)

    def test_final_report_publishes_the_required_counters(self) -> None:
        for field in ("remainingStagingFiles", "remainingSecretFiles",
                      "remainingListeners", "port3002Free"):
            self.assertIn(field, self.code)

    def test_cleanup_proves_the_other_phases_survived(self) -> None:
        self.assertIn("bundleSourcePresent", self.code)
        self.assertIn("homeDebianPresent", self.code)
        self.assertIn('test "${BUNDLE_SOURCE_PRESENT}" -eq 1', self.code)
        self.assertIn('test "${HOME_PRESENT}" -eq 1', self.code)

    def test_cleanup_never_touches_systemd_or_the_network(self) -> None:
        for forbidden in ("systemctl stop", "systemctl disable", "useradd",
                          "caddy reload", "ufw", "iptables", "wg-quick"):
            self.assertNotIn(forbidden, self.code)


# ===========================================================================
# Pochettes
# ===========================================================================
class CoversTest(unittest.TestCase):
    def _covers(self, root: Path, count: int = 3) -> None:
        root.mkdir(parents=True, exist_ok=True)
        for index in range(count):
            (root / f"cover-{index}.jpg").write_bytes(b"\xff\xd8\xff" + bytes([index]) * 64)

    def test_manifest_lists_relative_paths_only(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "covers"
            self._covers(root)
            (root / "album").mkdir()
            (root / "album" / "front.png").write_bytes(b"\x89PNG" + b"z" * 32)
            report = covers.build_cover_manifest(root)

            self.assertEqual(report["coverFileCount"], 4)
            for entry in report["files"]:
                self.assertFalse(entry["path"].startswith("/"))
                self.assertNotIn(":", entry["path"])   # aucun "C:\..."
                self.assertNotIn("\\", entry["path"])
                self.assertEqual(len(entry["sha256"]), 64)
            self.assertIn("album/front.png", [e["path"] for e in report["files"]])

    def test_payload_equals_its_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "covers"
            self._covers(root, 5)
            report = covers.build_cover_manifest(root)
            self.assertEqual(covers.verify_cover_manifest(root, report), [])

    def test_verification_detects_missing_extra_and_altered_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "covers"
            self._covers(root, 3)
            report = covers.build_cover_manifest(root)

            (root / "cover-0.jpg").unlink()
            (root / "cover-9.jpg").write_bytes(b"\xff\xd8\xffnew")
            (root / "cover-1.jpg").write_bytes(b"\xff\xd8\xffaltered-content")
            problems = covers.verify_cover_manifest(root, report)
            self.assertTrue(any(p.startswith("MANQUANT") for p in problems))
            self.assertTrue(any(p.startswith("EN_TROP") for p in problems))
            self.assertTrue(any(p.startswith(("TAILLE", "EMPREINTE")) for p in problems))

    def test_absent_covers_are_an_explicit_no_go(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "covers"
            root.mkdir()
            (root / ".gitkeep").write_text("")
            with self.assertRaises(covers.CoversEmptyError):
                covers.build_cover_manifest(root)

    def test_no_go_verdict_is_published_by_the_cli(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "covers"
            root.mkdir()
            result = subprocess.run(
                [sys.executable, str(HERE / "phase6_covers.py"), "--root", str(root)],
                capture_output=True, text=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            report = json.loads(result.stdout.strip().splitlines()[-1])
            self.assertFalse(report["ok"])
            self.assertEqual(report["verdict"], "NO-GO")
            self.assertEqual(report["error"], "COVERS_ABSENTES")

    def test_symlinks_are_refused_never_followed(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "covers"
            self._covers(root, 2)
            outside = Path(temp) / "secret.jpg"
            outside.write_bytes(b"\xff\xd8\xffhors-perimetre")
            try:
                (root / "link.jpg").symlink_to(outside)
            except (OSError, NotImplementedError):
                self.skipTest("création de lien symbolique non permise ici")
            with self.assertRaises(covers.CoversError) as caught:
                covers.build_cover_manifest(root)
            self.assertIn("symbolique", str(caught.exception))

    def test_non_image_files_are_refused_by_allowlist(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "covers"
            self._covers(root, 2)
            for noise in ("runtime.db", "agent.log", ".env", "track.flac",
                          "backup.zip", "notes.txt"):
                (root / noise).write_bytes(b"x" * 16)
            report = covers.build_cover_manifest(root)
            kept = [entry["path"] for entry in report["files"]]
            self.assertEqual(len(kept), 2)
            for noise in ("runtime.db", "agent.log", "track.flac"):
                self.assertNotIn(noise, kept)
            self.assertGreaterEqual(report["refusedCount"], 5)

    def test_audio_and_secrets_can_never_enter_the_payload(self) -> None:
        for name in ("track.flac", "track.wav", "runtime.db", ".env",
                     "api.key", "server.log"):
            self.assertNotIn(Path(name).suffix.lower(), covers.ALLOWED_SUFFIXES)


# ===========================================================================
# Sélection des pistes
# ===========================================================================
class TrackSelectionTest(unittest.TestCase):
    def _database(self, path: Path, rows: list[tuple]) -> None:
        connection = sqlite3.connect(path)
        connection.execute(
            "CREATE TABLE tracks (id INTEGER PRIMARY KEY, hash TEXT, "
            "path TEXT, size_bytes INTEGER)"
        )
        connection.executemany("INSERT INTO tracks VALUES (?,?,?,?)", rows)
        connection.commit()
        connection.close()

    def _real(self, index: int, size: int) -> tuple:
        return (index, f"{index:064x}", f"Artiste/Album/{index:02d} Titre.flac", size)

    def test_two_real_tracks_are_selected_automatically(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            db = Path(temp) / "snapshot.db"
            self._database(db, [self._real(i, 5_000_000 + i * 1_000_000)
                                for i in range(1, 9)])
            report = tracks.select(db)
            self.assertTrue(report["ok"])
            self.assertGreaterEqual(len(report["candidates"]), 2)
            first, second = report["candidates"][0], report["candidates"][1]
            self.assertNotEqual(first["trackId"], second["trackId"])

    def test_only_id_size_and_a_short_hash_prefix_are_published(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            db = Path(temp) / "snapshot.db"
            self._database(db, [self._real(i, 4_000_000) for i in range(1, 5)])
            report = tracks.select(db)
            for candidate in report["candidates"]:
                self.assertEqual(set(candidate), {"trackId", "sizeBytes", "hashPrefix"})
                # Ni titre, ni artiste, ni album, ni chemin : ce sont des
                # données personnelles, un rapport de déploiement n'en a pas
                # besoin.
                self.assertEqual(len(candidate["hashPrefix"]),
                                 tracks.HASH_PREFIX_LENGTH)
                self.assertLess(len(candidate["hashPrefix"]), 64)

    def test_synthetic_and_stale_rows_are_refused(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            db = Path(temp) / "snapshot.db"
            self._database(db, [
                self._real(1, 6_000_000),
                self._real(2, 7_000_000),
                # hash non conforme (semé à la main)
                (3, "not-a-sha256", "Artiste/Album/03.flac", 8_000_000),
                (4, None, "Artiste/Album/04.flac", 8_000_000),
                # trop petit pour être un morceau réel
                (5, f"{5:064x}", "Artiste/Album/05.flac", 512),
                # chemins de harnais / fixtures
                (6, f"{6:064x}", "tests/fixtures/probe.flac", 9_000_000),
                (7, f"{7:064x}", "phase5-harness/sample.flac", 9_000_000),
                (8, f"{8:064x}", "storage/synthetic/gate0.flac", 9_000_000),
                # extension non audio
                (9, f"{9:064x}", "Artiste/Album/09.txt", 9_000_000),
            ])
            report = tracks.select(db)
            selected = {item["trackId"] for item in report["candidates"]}
            self.assertEqual(selected, {1, 2})
            self.assertEqual(report["eligibleCount"], 2)

    def test_selection_is_deterministic(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            db = Path(temp) / "snapshot.db"
            self._database(db, [self._real(i, 3_000_000 + (i % 3) * 1_000_000)
                                for i in range(1, 12)])
            first = tracks.select(db)["candidates"]
            second = tracks.select(db)["candidates"]
            self.assertEqual(first, second)

    def test_insufficient_eligible_tracks_falls_back_explicitly(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            db = Path(temp) / "snapshot.db"
            self._database(db, [self._real(1, 6_000_000)])
            with self.assertRaises(tracks.TrackSelectionError):
                tracks.select(db)
            result = subprocess.run(
                [sys.executable, str(HERE / "phase6_select_tracks.py"), "--db", str(db)],
                capture_output=True, text=True, check=False,
            )
            report = json.loads(result.stdout.strip().splitlines()[-1])
            self.assertFalse(report["ok"])
            self.assertIn("TrackIdCached", report["fallback"])

    def test_snapshot_is_opened_read_only(self) -> None:
        source = read(HERE / "phase6_select_tracks.py")
        self.assertIn("mode=ro", source)


# ===========================================================================
# Environnement et secrets
# ===========================================================================
class ShadowEnvironmentTest(unittest.TestCase):
    def _rendered(self) -> str:
        return shadow_env.render(read(ENV_TEMPLATE), {
            "AUDIO_REMOTE_SHARED_SECRET": FAKE_SECRET_A,
            "AUTH_TOKEN_SECRET": FAKE_SECRET_B,
            "ANTRA_API_KEY": FAKE_SECRET_C,
})

    def test_rendered_environment_is_complete_and_conformant(self) -> None:
        summary = shadow_env.summarize(self._rendered())
        self.assertTrue(summary["ok"], summary["problems"])
        for flag in ("secretsPresent", "secretLengthsValid", "nodeEnvProduction",
                     "logLevelInfo", "hostLoopback", "port3002",
                     "audioStorageModeCached", "cacheMax12GiB",
                     "cacheMinFree6GiB", "backupsDisabled", "allPathsAbsolute",
                     "noLucidaVariable"):
            self.assertTrue(summary[flag], flag)
        self.assertEqual(summary["secretCount"], 3)
        self.assertEqual(summary["secretsPrinted"], 0)

    def test_missing_secrets_are_refused(self) -> None:
        for secrets in ({}, {"AUTH_TOKEN_SECRET": FAKE_SECRET_B},
                        {"AUDIO_REMOTE_SHARED_SECRET": FAKE_SECRET_A},
                        {"AUDIO_REMOTE_SHARED_SECRET": "", "AUTH_TOKEN_SECRET": "", "ANTRA_API_KEY": FAKE_SECRET_C}):
            with self.assertRaises(shadow_env.EnvError):
                shadow_env.render(read(ENV_TEMPLATE), secrets)

    def test_short_secrets_are_refused(self) -> None:
        with self.assertRaises(shadow_env.EnvError):
            shadow_env.render(read(ENV_TEMPLATE), {
                "AUDIO_REMOTE_SHARED_SECRET": "trop-court",
                "AUTH_TOKEN_SECRET": FAKE_SECRET_B,
                "ANTRA_API_KEY": FAKE_SECRET_C,
})

    def test_an_uninjected_template_never_validates(self) -> None:
        summary = shadow_env.summarize(read(ENV_TEMPLATE))
        self.assertFalse(summary["ok"])
        self.assertTrue(any("SECRET_NON_INJECTE" in problem
                            for problem in summary["problems"]))

    def test_no_report_field_ever_carries_a_secret(self) -> None:
        summary = shadow_env.summarize(self._rendered())
        serialized = json.dumps(summary)
        self.assertNotIn(FAKE_SECRET_A, serialized)
        self.assertNotIn(FAKE_SECRET_B, serialized)
        # Ni valeur, ni préfixe, ni empreinte : un hash de secret court est
        # attaquable par force brute, donc il en révèle la valeur.
        self.assertNotIn(FAKE_SECRET_A[:8], serialized)
        self.assertNotIn(FAKE_SECRET_B[:8], serialized)
        for banned in ("sha256", "hash", "digest", "fingerprint"):
            self.assertNotIn(banned, serialized.lower())

    def test_problem_messages_name_the_key_never_the_value(self) -> None:
        text = self._rendered().replace(
            f"AUTH_TOKEN_SECRET={FAKE_SECRET_B}", "AUTH_TOKEN_SECRET=court")
        problems = shadow_env.validate_env_text(text)
        self.assertIn("SECRET_TROP_COURT AUTH_TOKEN_SECRET", problems)
        self.assertNotIn("court", " ".join(problems).replace("TROP_COURT", ""))

    def test_lucida_variables_are_refused(self) -> None:
        text = self._rendered() + "LUCIDA_SCRIPT_PATH=/tmp/x.py\n"
        problems = shadow_env.validate_env_text(text)
        self.assertTrue(any(p.startswith("VARIABLE_LUCIDA_INTERDITE")
                            for p in problems))

    def test_relative_paths_are_refused(self) -> None:
        text = self._rendered().replace(
            "DB_PATH=/var/lib/homespotify-shadow/data/runtime.db",
            "DB_PATH=./data/runtime.db")
        self.assertIn("CHEMIN_NON_ABSOLU DB_PATH",
                      shadow_env.validate_env_text(text))

    def test_secrets_are_read_from_stdin_never_from_argv(self) -> None:
        source = read(HERE / "phase6_env.py")
        self.assertIn("sys.stdin.buffer.read()", source)
        # Aucun argument nommé ne peut porter un secret.
        for banned in ('add_argument("--secret', 'add_argument("--auth',
                       'add_argument("--shared'):
            self.assertNotIn(banned, source)

    def test_cli_accepts_secrets_on_stdin_and_writes_a_private_file(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp) / "api-shadow.env"
            payload = json.dumps({"AUDIO_REMOTE_SHARED_SECRET": FAKE_SECRET_A,
                                  "AUTH_TOKEN_SECRET": FAKE_SECRET_B,
                                  "ANTRA_API_KEY": FAKE_SECRET_C,
})
            result = subprocess.run(
                [sys.executable, str(HERE / "phase6_env.py"),
                 "--template", str(ENV_TEMPLATE), "--out", str(out)],
                input=payload, capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            # La sortie du CLI ne contient aucune valeur secrète.
            self.assertNotIn(FAKE_SECRET_A, result.stdout)
            self.assertNotIn(FAKE_SECRET_B, result.stdout)
            self.assertTrue(out.is_file())
            self.assertIn(FAKE_SECRET_A, out.read_text(encoding="utf-8"))
            if os.name != "nt":
                self.assertEqual(oct(out.stat().st_mode & 0o777), "0o600")

    def test_a_utf8_bom_on_stdin_does_not_look_like_a_bad_secret(self) -> None:
        # PowerShell 5.1 préfixe un BOM à ce qu'il envoie sur stdin d'un
        # processus natif. Sans tolérance, le rendu échoue en
        # « SECRETS_ILLISIBLES » sur une charge parfaitement valide.
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp) / "api-shadow.env"
            payload = "﻿" + json.dumps({
                "AUDIO_REMOTE_SHARED_SECRET": FAKE_SECRET_A,
                "AUTH_TOKEN_SECRET": FAKE_SECRET_B,
                "ANTRA_API_KEY": FAKE_SECRET_C,
})
            result = subprocess.run(
                [sys.executable, str(HERE / "phase6_env.py"),
                 "--template", str(ENV_TEMPLATE), "--out", str(out)],
                input=payload, capture_output=True, text=True,
                encoding="utf-8", check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(out.is_file())

    def test_no_committed_file_contains_a_secret_value(self) -> None:
        template = read(ENV_TEMPLATE)
        self.assertIn("AUDIO_REMOTE_SHARED_SECRET=__A_INJECTER__", template)
        self.assertIn("AUTH_TOKEN_SECRET=__A_INJECTER__", template)


# ===========================================================================
# Orchestrateur : mode StageOnly
# ===========================================================================
class StageOnlyOrchestratorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.text = read(ORCHESTRATOR)
        self.code = code_of(ORCHESTRATOR)

    def stage_only_branch(self) -> str:
        """Le corps du SEUL mode StageOnly.

        Depuis la Phase 6.3, l'orchestrateur sait aussi installer : il
        mentionne donc legitimement /opt, systemd et `dist/server.js`.
        Chercher ces motifs dans tout le fichier confondrait « le mode
        staging n'installe rien » avec « le script ne sait pas installer ».
        C'est la branche, et elle seule, qui porte la garantie.
        """
        start = self.code.index("if ($StageOnly) {")
        end = self.code.index("# MODE ROLLBACK-INSTALL") if "# MODE ROLLBACK-INSTALL" in self.code             else self.code.index("if ($RollbackInstall) {")
        return self.code[start:end]

    def test_stage_only_and_cleanup_staging_are_declared(self) -> None:
        self.assertIn("[switch] $StageOnly", self.code)
        self.assertIn("[switch] $CleanupStaging", self.code)
        self.assertIn("[string] $SourceCoversPath", self.code)

    def test_stage_only_still_installs_nothing(self) -> None:
        # La Phase 6.3 arme l'installation. La garantie du mode staging n'est
        # donc plus « le script ne sait pas installer » mais « ce mode-la
        # n'installe rien » — verifiee sur sa branche.
        branch = self.stage_only_branch()
        for forbidden in ("systemctl enable", "systemctl start", "useradd",
                          "systemd-analyze", "dist/server.js",
                          "vps_phase6_activate_shadow.sh"):
            self.assertNotIn(forbidden, branch)

    def test_boot_activation_is_never_performed(self) -> None:
        # `systemctl enable` ferait revenir seul un shadow non qualifie apres
        # un redemarrage du VPS. Aucun mode ne le fait ; le setup distant ne
        # le fait que derriere --enable, jamais appele ici.
        self.assertNotIn("systemctl enable", self.code)
        self.assertIn("--verify-only", self.code)
        self.assertIn("bootEnabled", self.code)
        self.assertIn("le service a été activé au démarrage", self.code)

    def test_cutover_is_never_performed(self) -> None:
        self.assertIn("cutoverPerformed = $false", self.code)
        for forbidden in ("caddy reload", "systemctl restart caddy",
                          "reverse_proxy", "certbot", "reboot"):
            self.assertNotIn(forbidden, self.code)

    def test_stage_only_never_starts_the_application(self) -> None:
        # Le seul `node` distant invoqué est la sonde HEAD, qui n'ouvre aucun
        # listener.
        self.assertIn("phase6_probe_agent.mjs", self.code)
        self.assertNotIn("node dist/", self.code)
        self.assertNotIn("npm install", self.code)
        self.assertNotIn("pnpm install", self.code)

    def test_stage_only_writes_only_under_the_staging_root(self) -> None:
        self.assertIn("$RemoteStagingRoot = '/home/debian/homespotify-phase6-staging'",
                      self.code)
        branch = self.stage_only_branch()
        for privileged in ("/opt/homespotify", "/var/lib/homespotify",
                           "/etc/homespotify", "/etc/systemd"):
            self.assertNotIn(privileged, branch)

    def test_secrets_are_never_passed_as_arguments(self) -> None:
        # Aucun paramètre de secret, et le rendu reçoit son entrée par le
        # pipeline (stdin), pas par la ligne de commande.
        for banned in ("$AuthTokenSecret", "$SharedSecret", "$Secret ",
                       "-AuthTokenSecret", "-SharedSecret",
                       "--secret", "--auth-token"):
            self.assertNotIn(banned, self.code)
        self.assertIn("$payloadJson | & python", self.code)

    def test_secret_input_is_masked_or_read_from_configuration(self) -> None:
        self.assertIn("Read-Host -AsSecureString", self.code)
        self.assertNotIn("Read-Host -Prompt 'AUTH", self.code)
        self.assertIn("SecretsFromWindowsConfig", self.code)
        self.assertIn("Read-SecretFromEnvFile", self.code)

    def test_the_shadow_never_inherits_the_production_signing_key(self) -> None:
        # Partager `AUTH_TOKEN_SECRET` rendrait les jetons du shadow valides
        # en production. La réutilisation existe, mais elle est un choix
        # explicite, jamais le défaut.
        self.assertIn("New-ShadowAuthSecret", self.code)
        self.assertIn("[switch] $ReuseProductionAuthSecret", self.code)
        self.assertIn("if ($ReuseProductionAuthSecret) {", self.code)
        self.assertIn("RandomNumberGenerator", self.code)

    def test_the_generated_secret_is_long_enough_and_never_printed(self) -> None:
        self.assertIn("New-Object byte[] 48", self.code)   # 96 caractères hex
        for line in self.code.splitlines():
            if "Step " in line or "Write-Host" in line:
                self.assertNotIn("$hex", line)
                self.assertNotIn("$auth", line)

    def test_secrets_are_refused_before_any_ssh_connection(self) -> None:
        # `Get-ShadowSecrets` doit précéder la première connexion.
        acquisition = self.code.index("$secrets = Get-ShadowSecrets")
        first_ssh = self.code.index("$prepareResult = Invoke-Ssh")
        self.assertLess(acquisition, first_ssh)
        self.assertIn('Fail "secret absent : $($pair[0])"', self.code)
        self.assertIn('Fail "secret trop court : $($pair[0])"', self.code)

    def test_no_secret_value_is_ever_printed(self) -> None:
        for line in self.code.splitlines():
            if "Write-Host" in line or "Step " in line or "Write-Output" in line:
                self.assertNotIn("ConvertFrom-SecureStringPlain", line)
                self.assertNotIn("$secrets.", line)
        self.assertIn("secretsPrinted = 0", self.code)

    def test_the_clear_environment_file_never_survives(self) -> None:
        self.assertIn("finally {", self.code)
        self.assertIn("Remove-Item -Force -LiteralPath $envTemp", self.code)
        self.assertIn("New-PrivateTempFile", self.code)
        self.assertIn("SetAccessRuleProtection($true, $false)", self.code)

    def test_dry_run_still_opens_no_ssh_connection(self) -> None:
        dry_run = self.code[self.code.index("if ($DryRun) {"):
                            self.code.index("if ($CleanupStaging) {")]
        for banned in ("Invoke-Ssh", "Invoke-Scp", "& ssh", "& scp"):
            self.assertNotIn(banned, dry_run)
        self.assertIn("sshConnectionsOpened = $script:SshConnections", dry_run)

    def test_remote_scripts_travel_encoding_independently(self) -> None:
        # Un BOM en tête du script distant fait répondre `bash` par
        # « set: command not found » — un symptôme sans rapport visible avec
        # sa cause. Le base64 supprime la classe entière.
        self.assertIn("[Convert]::ToBase64String", self.code)
        self.assertIn("base64 -d | $shell$remoteArgs", self.code)
        self.assertIn("bash -s --", self.code)
        self.assertIn("$OutputEncoding = New-Object System.Text.UTF8Encoding($false)",
                      self.code)

    def test_remote_scripts_are_normalised_to_lf(self) -> None:
        # `.gitattributes` extrait les `.ps1` en CRLF. Un `\r` en fin de la
        # ligne `set -Eeuo pipefail` fait échouer bash avec « set: pipefail :
        # invalid option name » — un message qui ne désigne pas sa cause.
        self.assertIn('$normalized = $ScriptText -replace "`r`n", "`n"', self.code)
        self.assertIn("[Text.Encoding]::UTF8.GetBytes($normalized)", self.code)

    def test_no_secret_travels_on_the_remote_command_line(self) -> None:
        # Ce qui passe en ligne de commande distante est le script encodé et
        # des chemins publics. Les secrets vivent dans le fichier 0600.
        self.assertIn("$command = \"echo $encoded | base64 -d | $shell$remoteArgs\"",
                      self.code)
        for line in self.code.splitlines():
            if "& ssh " in line or "$command =" in line:
                self.assertNotIn("$secrets", line)
                self.assertNotIn("ConvertFrom-SecureStringPlain", line)

    def test_ssh_connections_are_counted(self) -> None:
        self.assertIn("$script:SshConnections++", self.code)
        self.assertIn("sshConnectionsOpened = $script:SshConnections", self.code)

    def test_a_dirty_worktree_blocks_staging(self) -> None:
        self.assertIn("git status --porcelain", self.code)
        self.assertIn("Fail 'arbre de travail non propre'", self.code)

    def test_source_maps_block_the_transfer(self) -> None:
        self.assertIn("-Filter '*.map'", self.code)
        self.assertIn("source maps présentes", self.code)

    def test_local_manifest_is_verified_before_transfer(self) -> None:
        verify = self.code.index("phase6_manifest_verify.py")
        first_ssh = self.code.index("$prepareResult = Invoke-Ssh")
        self.assertLess(verify, first_ssh)

    def test_bundle_source_is_copied_never_moved(self) -> None:
        self.assertIn('cp -a "`$SRC/." "`$MODULES/"', self.code)
        for destructive in ("mv ", "rm -rf `$SRC", "rm -rf \"`$SRC"):
            self.assertNotIn(f'{destructive}"`$SRC', self.code)
        self.assertIn("SOURCE_ALTEREE", self.code)

    def test_the_report_publishes_every_required_field(self) -> None:
        for field in ("releaseId", "fileCount", "artifactBytes", "snapshotBytes",
                      "coverFileCount", "coverBytes", "bundleVerified",
                      "nativeModulesVerified", "sqliteVerified",
                      "manifestVerified", "environmentVerified", "port3002Free",
                      "serviceAbsent", "sshConnectionsOpened", "secretsPrinted",
                      "productionModified", "ok"):
            self.assertIn(field, self.code)

    def test_staging_stops_before_installation(self) -> None:
        branch = self.stage_only_branch()
        self.assertIn("exit 0", branch)
        for installation in ("vps_phase6_install_release.sh",
                             "vps_phase6_systemd_setup.sh",
                             "vps_phase6_start_shadow.sh"):
            self.assertNotIn(installation, branch)


# ===========================================================================
# Préflight distant
# ===========================================================================
class StagePreflightTest(unittest.TestCase):
    def setUp(self) -> None:
        self.text = read(STAGE_PREFLIGHT)
        self.code = code_of(STAGE_PREFLIGHT)

    def test_preflight_never_executes_the_application(self) -> None:
        self.assertNotIn("node dist/server.js", self.code)
        self.assertNotIn("dist/server.js", self.code)
        self.assertIn('"serverJsExecuted":false', self.code)

    def test_preflight_creates_no_service_and_no_user(self) -> None:
        for forbidden in ("useradd", "systemctl enable", "systemctl start",
                          "systemctl daemon-reload", "systemd-analyze"):
            self.assertNotIn(forbidden, self.code)

    def test_preflight_is_bounded_to_the_staging_root(self) -> None:
        self.assertIn('ALLOWED_ROOT="/home/debian/homespotify-phase6-staging"',
                      self.code)
        self.assertIn("STAGING_HORS_RACINE", self.code)
        self.assertIn("RELEASE_HORS_STAGING", self.code)

    def test_preflight_checks_the_frozen_runtime(self) -> None:
        self.assertIn('REQUIRED_NODE="v22.18.0"', self.code)
        self.assertIn('REQUIRED_ABI="127"', self.code)
        self.assertIn('REQUIRED_ARCH="x64"', self.code)
        for refusal in ("NODE_VERSION_INATTENDUE", "ABI_INATTENDU",
                        "ARCH_INATTENDUE"):
            self.assertIn(refusal, self.code)

    def test_preflight_really_loads_better_sqlite3_and_the_snapshot(self) -> None:
        self.assertIn('require(process.env.HS_BUNDLE + "/better-sqlite3")', self.code)
        self.assertIn("integrity_check", self.code)
        self.assertIn("foreign_key_check", self.code)
        self.assertIn("__drizzle_migrations", self.code)
        self.assertIn("readonly: true", self.code)

    def test_the_bundle_content_lives_under_a_directory_named_node_modules(self) -> None:
        # Défaut trouvé en exécution réelle : Node ne résout les dépendances
        # pairs qu'à travers des répertoires nommés EXACTEMENT `node_modules`.
        # Déposé sous `<bundle-id>/`, `better_sqlite3.node` est présent, son
        # empreinte est juste, et le premier `require` échoue sur
        # `Cannot find module 'bindings'`. Le nom fait partie du contrat.
        self.assertIn('MODULES="${BUNDLE}/node_modules"', self.code)
        self.assertIn('export HS_BUNDLE="${MODULES}"', self.code)
        self.assertNotIn('export HS_BUNDLE="${BUNDLE}"', self.code)
        for native in ("NATIVE_SQLITE", "NATIVE_ARGON"):
            for line in self.code.splitlines():
                if line.startswith(f"{native}="):
                    self.assertIn("${MODULES}/", line)

        # La même règle vaut pour le préflight et l'installation de la
        # Phase 6.3 : le défaut y était latent, il n'y attend plus.
        legacy = code_of(HERE / "vps_phase6_preflight.sh")
        self.assertIn('MODULES="${BUNDLE}/node_modules"', legacy)
        self.assertIn('export HS_BUNDLE="${MODULES}"', legacy)
        install = code_of(HERE / "vps_phase6_install_release.sh")
        self.assertIn('ln -sfn "${BUNDLE}/node_modules" "${STAGING}/node_modules"',
                      install)

    def test_failure_details_are_json_escaped(self) -> None:
        # Un `detail` non échappé porte la sortie d'un sous-processus, donc des
        # guillemets : le JSON devient invalide et l'appelant échoue sur
        # l'analyse au lieu d'afficher la cause. L'erreur disparaît exactement
        # au moment où elle compte.
        self.assertIn("json_escape", self.code)
        self.assertIn('"$(json_escape "${2:-}")"', self.code)

    def test_preflight_proves_the_phase45_source_is_unchanged(self) -> None:
        self.assertIn('BUNDLE_SOURCE="/home/debian/homespotify-phase45/api/node_modules"',
                      self.code)
        self.assertIn("BUNDLE_SOURCE_DIVERGENTE", self.code)
        # Lecture seule : aucune écriture dans l'arbre Phase 4.5.
        self.assertNotIn("rm ", self.code.replace("rmSync", ""))

    def test_preflight_refuses_source_maps_and_env_files(self) -> None:
        self.assertIn("SOURCE_MAP_PRESENTE", self.code)
        self.assertIn("ENV_DANS_RELEASE", self.code)

    def test_preflight_requires_covers(self) -> None:
        self.assertIn("COVERS_ABSENTES", self.code)
        self.assertIn("COVERS_VIDES", self.code)
        self.assertIn("phase6_covers.py", self.code)

    def test_preflight_checks_the_port_the_service_and_the_privileged_roots(self) -> None:
        self.assertIn("PORT_3002_OCCUPE", self.code)
        self.assertIn("SERVICE_SHADOW_PRESENT", self.code)
        self.assertIn("OPT_MODIFIE", self.code)
        self.assertIn("VARLIB_MODIFIE", self.code)

    def test_preflight_checks_the_secret_file_permissions(self) -> None:
        self.assertIn("ENV_PERMISSIONS", self.code)
        self.assertIn('[ "${ENV_MODE}" = "600" ]', self.code)

    def test_preflight_verifies_caddy_is_unchanged(self) -> None:
        self.assertIn("CADDYFILE_MODIFIE", self.code)
        self.assertIn("caddyUnchanged", self.code)
        # Constat, jamais action.
        for action in ("caddy reload", "systemctl restart caddy",
                       "wg-quick", "ufw", "iptables"):
            self.assertNotIn(action, self.code)

    def test_preflight_leaves_no_trace_of_its_own_execution(self) -> None:
        # Constaté en exécution réelle : les imports Python déposaient un
        # `tools/__pycache__` dans le staging. Le répertoire cessait d'être
        # exactement ce qui avait été transféré, ce qui vide de son sens la
        # comparaison au manifeste.
        self.assertIn("export PYTHONDONTWRITEBYTECODE=1", self.code)

    def test_preflight_never_prints_a_secret(self) -> None:
        self.assertIn("--validate", self.code)
        self.assertNotIn("cat ", self.code)
        self.assertNotIn("AUTH_TOKEN_SECRET=", self.code)


# ===========================================================================
# Sonde Storage Agent
# ===========================================================================
class AgentProbeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.text = read(PROBE)
        self.code = code_of(PROBE)

    def test_probe_reads_the_secret_from_the_env_file_not_from_argv(self) -> None:
        self.assertIn("readFileSync(envPath", self.code)
        self.assertIn("AUDIO_REMOTE_SHARED_SECRET", self.code)
        # `process.argv` ne porte que le chemin du fichier et des entiers.
        self.assertIn("trackArgs.map(Number)", self.code)

    def test_probe_opens_no_listener(self) -> None:
        for forbidden in ("createServer", "listen(", "fastify", "express"):
            self.assertNotIn(forbidden, self.code)
        self.assertIn("serverStarted: false", self.code)
        self.assertIn("listenersOpened: 0", self.code)

    def test_probe_publishes_no_personal_data(self) -> None:
        for banned in ("title", "artist", "album", "path:"):
            self.assertNotIn(banned, self.code.split("console.log")[-1])

    def test_probe_writes_nothing_to_disk(self) -> None:
        for forbidden in ("writeFileSync", "createWriteStream", "mkdirSync",
                          "appendFileSync"):
            self.assertNotIn(forbidden, self.code)

    def test_probe_signs_like_the_real_client(self) -> None:
        # Même chaîne canonique que `hmac-client.ts` : sinon la sonde
        # prouverait la disponibilité d'un chemin que l'API n'emprunte pas.
        self.assertIn("x-hs-timestamp", self.code)
        self.assertIn("x-hs-nonce", self.code)
        self.assertIn("x-hs-content-sha256", self.code)
        self.assertIn("x-hs-signature", self.code)
        self.assertIn("/internal/storage/tracks/", self.code)


# ===========================================================================
# Cohérence transversale
# ===========================================================================
class CrossCuttingTest(unittest.TestCase):
    STAGING_SCRIPTS = (
        "run_phase6_shadow_deploy.ps1", "vps_phase6_stage_preflight.sh",
        "vps_phase6_staging_cleanup.sh", "phase6_staging.py",
        "phase6_covers.py", "phase6_env.py", "phase6_select_tracks.py",
        "phase6_probe_agent.mjs",
    )

    def test_no_script_contains_a_secret_value(self) -> None:
        import re

        # Une longue chaîne hexadécimale ou base64 dans un script de
        # déploiement est un secret jusqu'à preuve du contraire.
        suspicious = re.compile(r"(?<![0-9a-f])[0-9a-f]{40,}(?![0-9a-f])")
        allowed = {
            # SHA-256 du corps vide : constante publique du protocole HMAC.
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        }
        for name in self.STAGING_SCRIPTS:
            for match in suspicious.findall(read(HERE / name)):
                self.assertIn(match, allowed, f"{name} : chaîne suspecte")

    def test_no_script_touches_caddy_wireguard_or_the_firewall(self) -> None:
        for name in self.STAGING_SCRIPTS:
            code = code_of(HERE / name)
            # Les ACTIONS sont bannies, pas les mots : `systemctl is-active
            # wg-quick@wg0` est une LECTURE, et l'interdire empecherait de
            # prouver que WireGuard n'a pas bouge.
            for action in ("caddy reload", "systemctl restart caddy",
                           "systemctl stop caddy", "wg-quick up", "wg-quick down",
                           "ufw allow", "ufw enable",
                           "iptables -A", "nft add", "resolvectl"):
                self.assertNotIn(action, code, f"{name} : {action}")

    def test_no_script_touches_a_windows_service(self) -> None:
        for name in self.STAGING_SCRIPTS:
            code = code_of(HERE / name)
            for action in ("Stop-Service", "Start-Service", "Restart-Service",
                           "Set-Service", "sc.exe"):
                self.assertNotIn(action, code, f"{name} : {action}")

    def test_no_script_writes_to_the_production_database(self) -> None:
        for name in self.STAGING_SCRIPTS:
            code = code_of(HERE / name)
            for action in ("DELETE FROM", "DROP TABLE", "UPDATE tracks",
                           "INSERT INTO tracks", "ALTER TABLE"):
                self.assertNotIn(action, code, f"{name} : {action}")

    def test_scripts_parse(self) -> None:
        for name in self.STAGING_SCRIPTS:
            path = HERE / name
            if path.suffix == ".sh":
                result = subprocess.run(["bash", "-n", str(path)],
                                        capture_output=True, text=True, check=False)
                self.assertEqual(result.returncode, 0, f"{name}: {result.stderr}")
            elif path.suffix == ".py":
                import py_compile

                py_compile.compile(str(path), doraise=True)

    def test_the_generated_package_json_carries_no_bom(self) -> None:
        # Défaut trouvé au premier démarrage réel : `Set-Content -Encoding
        # utf8` ajoute un BOM sous Windows PowerShell 5.1, et
        # `dist/routes/admin.js` fait un `JSON.parse` de ce fichier au
        # chargement. L'API refusait de démarrer ; aucun contrôle de manifeste
        # ne pouvait le voir, puisque le fichier était intact et son empreinte
        # juste.
        build = read(HERE / "build_shadow_artifact.ps1")
        self.assertIn("[IO.File]::WriteAllText(", build)
        self.assertIn("New-Object System.Text.UTF8Encoding($false)", build)
        self.assertNotIn("Set-Content -LiteralPath (Join-Path $staging 'package.json')",
                         build)

    def test_no_artifact_file_starts_with_a_bom(self) -> None:
        # Contrôle de bout en bout sur l'artefact assemblé, s'il existe : un
        # BOM en tête d'un fichier lu par `JSON.parse` ou par `import` est un
        # défaut qui ne se voit qu'à l'exécution.
        staging = Path("F:/dev/homespotify-phase6-staging/artifact")
        if not staging.is_dir():
            self.skipTest("artefact non assemblé")
        offenders = [
            path.relative_to(staging).as_posix()
            for path in staging.rglob("*")
            if path.is_file() and path.suffix in (".json", ".js", ".sql")
            and path.read_bytes().startswith(b"\xef\xbb\xbf")
        ]
        self.assertEqual(offenders, [], f"BOM en tête de : {offenders[:5]}")

    def test_shell_scripts_carry_no_carriage_return(self) -> None:
        # Un `.sh` en CRLF est refusé par bash de façon illisible. Un outil qui
        # réécrit ces fichiers sous Windows introduit le défaut sans le voir :
        # ce test le voit.
        for path in sorted(HERE.glob("*.sh")):
            self.assertNotIn(b"\r", path.read_bytes(), path.name)

    def test_staging_layout_matches_between_python_and_shell(self) -> None:
        shell = read(STAGE_PREFLIGHT)
        self.assertIn(str(staging.STAGING_ROOT), shell)
        self.assertIn(staging.BUNDLE_ID, shell)
        self.assertIn(str(staging.BUNDLE_SOURCE), shell)
        cleanup = read(STAGING_CLEANUP)
        self.assertIn(str(staging.STAGING_ROOT), cleanup)

    def test_manifest_exclusions_still_cover_maps_and_secrets(self) -> None:
        for excluded in ("dist/server.js.map", "config/.env", "data/runtime.db",
                         "node_modules/x/index.js", "audio/track.flac"):
            self.assertTrue(manifest.is_excluded(excluded), excluded)
        for kept in ("dist/server.js", "package.json", "drizzle/0001_init.sql"):
            self.assertFalse(manifest.is_excluded(kept), kept)

    def test_data_directory_names_are_anchored_at_the_top_level(self) -> None:
        # Défaut trouvé au premier démarrage réel : `storage` exclu à
        # n'importe quel niveau écartait `dist/storage/`, soit TOUTE la couche
        # de stockage audio — les douze fichiers que la Phase 6 existe pour
        # qualifier. Le manifeste restait cohérent avec lui-même et le
        # transfert exact : seul un `import` réel pouvait le révéler.
        for kept in ("dist/storage/local-file-storage.js",
                     "dist/storage/audio-storage.js",
                     "dist/storage/cache/cached-audio-storage.js",
                     "dist/storage/remote/storage-agent-client.js",
                     "dist/routes/tracks.js", "dist/db/client.js"):
            self.assertFalse(manifest.is_excluded(kept), kept)
        # À la racine de l'artefact, ces noms restent des données.
        for excluded in ("storage/music/track.flac", "logs/api.log",
                         "cache/audio/x.bin", "backups/db.sqlite",
                         "tests/fixture.js"):
            self.assertTrue(manifest.is_excluded(excluded), excluded)

    def test_never_legitimate_directories_are_excluded_at_any_depth(self) -> None:
        for excluded in ("dist/node_modules/x.js", "dist/__pycache__/a.pyc",
                         "dist/routes/__tests__/spec.js", "a/b/.git/config",
                         "dist/coverage/report.js"):
            self.assertTrue(manifest.is_excluded(excluded), excluded)

    def test_the_whole_storage_layer_survives_the_filter(self) -> None:
        # Contrôle de bout en bout sur le vrai `dist` : aucun `.js` de runtime
        # ne doit disparaître silencieusement de l'artefact.
        dist = Path(__file__).resolve().parents[2] / "services" / "api" / "dist"
        if not dist.is_dir():
            self.skipTest("dist absent : lancer le build d'abord")
        # Les chemins sont évalués tels qu'ils apparaissent DANS L'ARTEFACT,
        # c'est-à-dire préfixés par `dist/`. C'est cette forme qui compte :
        # `storage/x.js` seul serait légitimement écarté comme répertoire de
        # données de premier niveau.
        dropped = [
            f"dist/{path.relative_to(dist).as_posix()}"
            for path in dist.rglob("*.js")
            if path.is_file()
            and manifest.is_excluded(f"dist/{path.relative_to(dist).as_posix()}")
        ]
        self.assertEqual(dropped, [], f"code runtime écarté : {dropped[:8]}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
