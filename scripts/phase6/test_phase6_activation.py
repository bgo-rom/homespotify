#!/usr/bin/env python3
"""Régression de l'outillage d'ACTIVATION Phase 6.3.

Ces tests portent sur l'outillage, pas sur le VPS : aucun n'ouvre de connexion
SSH, aucun ne démarre de service. Ils verrouillent les propriétés dont la
perte produirait une activation dangereuse — un `current` qui pointe vers un
répertoire incomplet, un listener public, un service qui revient seul après un
redémarrage du VPS, un jeton dans une ligne de commande, une base de
production écrasée.
"""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from test_phase6_staging import code_of, read  # noqa: E402


def script_params(text: str) -> str:
    """Le bloc `param()` du script, et lui seul.

    Les casts locaux (`[string]$x`) et les paramètres de FONCTION portent la
    même syntaxe sans créer la collision recherchée : seuls les paramètres du
    script vivent dans la portée où les affectations de premier niveau les
    écrasent.
    """
    start = text.index("param(")
    depth, index = 0, start + len("param")
    for index in range(start + len("param"), len(text)):
        if text[index] == "(":
            depth += 1
        elif text[index] == ")":
            depth -= 1
            if depth == 0:
                break
    return text[start:index + 1]


ACTIVATE = HERE / "vps_phase6_activate_shadow.sh"
START = HERE / "vps_phase6_start_shadow.sh"
MONITOR = HERE / "vps_phase6_monitor.sh"
SETUP = HERE / "vps_phase6_systemd_setup.sh"
UNIT = HERE / "homespotify-api-shadow.service"
TOKEN = HERE / "phase6_shadow_token.mjs"
TESTS = HERE / "vps_phase6_shadow_tests.py"
ORCHESTRATOR = HERE / "run_phase6_shadow_deploy.ps1"


# ===========================================================================
# Installation immuable
# ===========================================================================
class ActivateScriptTest(unittest.TestCase):
    def setUp(self) -> None:
        self.code = code_of(ACTIVATE)

    def test_bounded_to_the_qualified_staging_root(self) -> None:
        self.assertIn('ALLOWED_STAGING="/home/debian/homespotify-phase6-staging"',
                      self.code)
        self.assertIn("STAGING_HORS_RACINE", self.code)
        self.assertIn("RELEASE_ID_INVALIDE", self.code)

    def test_current_is_created_last_and_only_when_complete(self) -> None:
        # L'invariant central : `current` ne doit jamais désigner un
        # répertoire en cours de copie.
        promote = self.code.index("mv -T \"${INCOMING}\" \"${TARGET}\"")
        current = self.code.index('ln -sfn "${TARGET}" "${ROOT}/current.new"')
        self.assertLess(promote, current)
        for check in ("phase6_manifest_verify.py", "vps_phase6_preflight.sh"):
            self.assertLess(self.code.index(check), current, check)
        self.assertIn('mv -T "${ROOT}/current.new" "${ROOT}/current"', self.code)
        self.assertIn("CURRENT_INCOHERENT", self.code)

    def test_release_is_verified_before_being_promoted(self) -> None:
        # La copie va d'abord dans `.incoming-<id>`, et une vérification qui
        # échoue la supprime : un répertoire à moitié valide ne doit pas
        # pouvoir être promu par une exécution ultérieure.
        self.assertIn('INCOMING="${ROOT}/releases/.incoming-${RELEASE_ID}"', self.code)
        self.assertIn('rm -rf -- "${INCOMING}"; fail MANIFESTE_DIVERGENT', self.code)
        self.assertIn('rm -rf -- "${INCOMING}"; fail PREFLIGHT_ECHEC', self.code)

    def test_no_symlink_may_leave_the_shadow_roots(self) -> None:
        self.assertIn("SYMLINK_HORS_RACINE", self.code)
        self.assertIn('LINK_TARGET="$(readlink -f "${TARGET}/node_modules")"', self.code)

    def test_bundle_keeps_the_node_modules_contract(self) -> None:
        self.assertIn('"${BUNDLE}/node_modules"', self.code)
        self.assertIn("better_sqlite3.node", self.code)

    def test_an_existing_database_is_never_overwritten(self) -> None:
        # Une base en place appartient à une exécution en cours. L'écraser
        # détruirait son état sans que personne l'ait demandé.
        self.assertIn('if [ ! -f "${STATE}/data/runtime.db" ]; then', self.code)
        self.assertNotIn('rm -f "${STATE}/data/runtime.db"', self.code)

    def test_permissions_are_set_not_merely_removed(self) -> None:
        # Défaut trouvé en exécution réelle : `chmod -R go-w` ne sait
        # qu'ENLEVER des droits. La release arrivait en 0705 — le groupe sans
        # aucun droit — et le service, dont c'est le groupe primaire, échouait
        # en CHDIR avec « Permission denied », en boucle de redémarrage. Le
        # message parlait de répertoire de travail, jamais de permissions.
        self.assertNotIn("chmod -R go-w", self.code)
        self.assertIn('chmod -R u=rwX,g=rX,o= "${INCOMING}"', self.code)
        self.assertIn('chmod -R u=rwX,g=rX,o= "${BUNDLE}"', self.code)

    def test_readability_is_proven_under_the_service_identity(self) -> None:
        # Vérifier en root prouverait que root peut lire. Le seul contrôle qui
        # vaut est fait sous l'identité qui échoue réellement.
        for check in ("RELEASE_NON_TRAVERSABLE", "DIST_NON_LISIBLE",
                      "BUNDLE_NON_LISIBLE"):
            self.assertIn(check, self.code, check)
        self.assertIn('sudo -u "${USER_NAME}" test -x "${CURRENT}"', self.code)

    def test_disposable_directories_must_be_empty(self) -> None:
        for refusal in ("CACHE_NON_VIDE", "INCOMING_NON_VIDE", "VARIANTES_NON_VIDES"):
            self.assertIn(refusal, self.code)

    def test_installed_database_is_compared_to_its_source(self) -> None:
        self.assertIn("SQLITE_DIVERGENTE", self.code)
        self.assertIn("integrity_check", self.code)
        self.assertIn("__drizzle_migrations", self.code)
        self.assertIn("readonly: true", self.code)

    def test_covers_are_verified_against_their_manifest(self) -> None:
        self.assertIn("COVERS_DIVERGENTES", self.code)
        self.assertIn("covers-manifest.json", self.code)

    def test_environment_is_root_only_and_validated(self) -> None:
        self.assertIn("install -o root -g root -m 0600", self.code)
        self.assertIn("ENV_MODE_INVALIDE", self.code)
        self.assertIn('phase6_env.py" --validate "${ENV_FILE}"', self.code)
        # Aucune valeur n'est lue ni affichée.
        self.assertNotIn("cat ", self.code)
        self.assertNotIn("AUTH_TOKEN_SECRET=", self.code)

    def test_installation_never_starts_the_service(self) -> None:
        # Installer et démarrer sont deux étapes : fusionnées, un échec
        # laisserait une machine déjà démarrée avant qu'on puisse constater.
        for forbidden in ("systemctl start", "systemctl restart",
                          "systemctl enable"):
            self.assertNotIn(forbidden, self.code)
        self.assertIn('"serviceStarted":false', self.code)
        self.assertIn('"bootEnabled":false', self.code)

    def test_installation_leaves_no_python_bytecode(self) -> None:
        self.assertIn("export PYTHONDONTWRITEBYTECODE=1", self.code)

    def test_installation_touches_nothing_public(self) -> None:
        for forbidden in ("caddy", "wg-quick up", "ufw", "iptables", "nft add",
                          "npm install", "reboot"):
            self.assertNotIn(forbidden, self.code)


# ===========================================================================
# Démarrage contrôlé
# ===========================================================================
class StartScriptTest(unittest.TestCase):
    def setUp(self) -> None:
        self.code = code_of(START)

    def test_preconditions_are_checked_before_start(self) -> None:
        start = self.code.index('systemctl start "${SERVICE}"')
        for check in ("PORT_OCCUPE", "CURRENT_ABSENT", "DIST_ABSENT",
                      "ENV_ABSENT", "DB_ABSENTE", "UNITE_ABSENTE",
                      "REPERTOIRE_NON_INSCRIPTIBLE"):
            self.assertLess(self.code.index(check), start, check)

    def test_write_access_is_proven_as_the_service_user(self) -> None:
        # Vérifier en root prouverait que root peut écrire, ce que personne ne
        # doutait. Le test se fait sous l'identité du service.
        self.assertIn('sudo -u "${USER_NAME}" test -w', self.code)
        self.assertIn('sudo -u "${USER_NAME}" test -r "${STATE}/data/runtime.db"', self.code)

    def test_code_readability_is_checked_before_starting(self) -> None:
        # Sans ce contrôle, systemd échoue en CHDIR et relance en boucle : 17
        # redémarrages avant qu'un humain lise le journal, pour une cause que
        # le message ne nomme pas.
        start = self.code.index('systemctl start "${SERVICE}"')
        for check in ("RELEASE_NON_TRAVERSABLE", "DIST_NON_LISIBLE",
                      "BUNDLE_NON_LISIBLE"):
            self.assertLess(self.code.index(check), start, check)

    def test_a_public_listener_stops_the_service_immediately(self) -> None:
        self.assertIn("LISTENER_PUBLIC", self.code)
        self.assertIn('WILDCARD=', self.code)
        self.assertIn('IPV6=', self.code)
        self.assertIn('WG=', self.code)
        # L'arrêt précède le refus : le service ne doit pas rester joignable
        # le temps qu'on lise le rapport.
        public = self.code.index("fail LISTENER_PUBLIC")
        stop = self.code.rindex('systemctl stop "${SERVICE}"', 0, public)
        self.assertLess(stop, public)

    def test_only_one_loopback_listener_is_accepted(self) -> None:
        self.assertIn("LISTENER_LOOPBACK_ABSENT", self.code)
        self.assertIn("LISTENERS_MULTIPLES", self.code)
        self.assertIn("ECOUTES_PUBLIQUES_MODIFIEES", self.code)

    def test_failure_stops_the_service_and_keeps_the_evidence(self) -> None:
        self.assertIn('"serviceStopped":true', self.code)
        self.assertIn('"releaseRetained":true', self.code)
        self.assertIn("journalctl", self.code)

    def test_no_blind_retry(self) -> None:
        # Une seconde tentative identique donne le même résultat, en écrasant
        # les journaux utiles sous les siens.
        self.assertEqual(self.code.count('systemctl start "${SERVICE}"'), 1)
        self.assertNotIn("for attempt in", self.code)

    def test_start_never_enables_at_boot(self) -> None:
        self.assertNotIn("systemctl enable", self.code)
        self.assertIn("systemctl is-enabled", self.code)

    def test_a_failed_unit_is_not_waited_out(self) -> None:
        self.assertIn('[ "${STATE_NOW}" = "failed" ] && break', self.code)


# ===========================================================================
# Unité systemd
# ===========================================================================
class SystemdTest(unittest.TestCase):
    def setUp(self) -> None:
        self.unit = read(UNIT)
        self.setup = code_of(SETUP)

    def test_every_required_directive_is_present(self) -> None:
        for directive in (
            "User=homespotify", "Group=homespotify",
            "WorkingDirectory=/opt/homespotify-api-shadow/current",
            "EnvironmentFile=/etc/homespotify/api-shadow.env",
            "ExecStart=/usr/local/bin/node dist/server.js",
            "Restart=on-failure", "UMask=0027", "NoNewPrivileges=true",
            "PrivateTmp=true", "ProtectSystem=strict", "ProtectHome=true",
            "ReadWritePaths=/var/lib/homespotify-shadow",
            "RestrictAddressFamilies=AF_UNIX AF_INET",
            "CapabilityBoundingSet=",
        ):
            self.assertIn(directive, self.unit, directive)

    def test_no_memory_cap_during_qualification(self) -> None:
        # Un plafond posé avant le soak tuerait le processus pendant une
        # écriture, et les redémarrages masqueraient un vrai défaut.
        self.assertNotIn("MemoryMax", "\n".join(
            line for line in self.unit.splitlines() if not line.startswith("#")))

    def test_setup_verifies_the_unit_before_writing_to_etc(self) -> None:
        verify = self.setup.index("systemd-analyze verify")
        install = self.setup.index('install -o root -g root -m 0644 "${UNIT_SOURCE}"')
        self.assertLess(verify, install)
        self.assertIn("--verify-only", self.setup)

    def test_boot_activation_requires_an_explicit_flag(self) -> None:
        self.assertIn('if [ "${MODE}" = "--enable" ]; then', self.setup)
        self.assertIn('ENABLED="disabled"', self.setup)
        self.assertIn("bootEnabled", self.setup)

    def test_directories_are_not_world_readable(self) -> None:
        self.assertIn('install -d -o root -g "${USER_NAME}" -m 0750', self.setup)
        self.assertIn("install -d -o root -g root -m 0750 /etc/homespotify", self.setup)
        self.assertNotIn("-m 0755", self.setup)

    def test_a_permissive_environment_file_is_refused(self) -> None:
        self.assertIn("ENV_MODE_INVALIDE", self.setup)


# ===========================================================================
# Jeton shadow
# ===========================================================================
class ShadowTokenTest(unittest.TestCase):
    def setUp(self) -> None:
        self.code = code_of(TOKEN)

    def test_the_token_is_never_printed(self) -> None:
        self.assertIn("tokenPrinted: false", self.code)
        self.assertIn("secretPrinted: false", self.code)
        self.assertIn("usernamePrinted: false", self.code)
        # La seule sortie est le rapport ; le jeton part dans un fichier.
        self.assertEqual(self.code.count("console.log"), 2)  # 1 échec + 1 succès
        self.assertNotIn("console.log(token", self.code)

    def test_the_token_file_is_created_private(self) -> None:
        # `openSync(path, 'w', 0o600)` : le fichier NAÎT avec ses permissions.
        # Un writeFileSync suivi d'un chmod laisserait une fenêtre.
        self.assertIn("openSync(outPath, 'w', 0o600)", self.code)
        self.assertNotIn("writeFileSync", self.code)

    def test_no_production_secret_is_involved(self) -> None:
        self.assertIn("productionSecretUsed: false", self.code)
        self.assertIn("AUTH_TOKEN_SECRET", self.code)
        # Le secret vient du fichier d'environnement du SHADOW.
        self.assertIn("readFileSync(envPath", self.code)

    def test_the_payload_matches_the_application_contract(self) -> None:
        # `signAccessToken()` : {sub, username, role, type:'access'} en HS256.
        for field in ("sub:", "username:", "role:", "type: 'access'"):
            self.assertIn(field, self.code)
        self.assertIn("alg: 'HS256'", self.code)
        self.assertIn("createHmac('sha256', secret)", self.code)

    def test_only_a_usable_account_is_selected(self) -> None:
        # Le garde refuse les comptes inactifs et ceux en changement de mot de
        # passe imposé : un jeton refusé ne prouverait rien.
        self.assertIn("is_active = 1", self.code)
        self.assertIn("must_change_password = 0", self.code)

    def test_the_disposable_copy_is_opened_read_only(self) -> None:
        self.assertIn("readonly: true", self.code)


# ===========================================================================
# Tests fonctionnels
# ===========================================================================
class ShadowTestsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.code = code_of(TESTS)

    def test_the_token_arrives_by_file_never_by_argument(self) -> None:
        # Un `--token <valeur>` serait lisible dans /proc/<pid>/cmdline par
        # tout compte de la machine et resterait dans l'historique du shell.
        self.assertIn('"--token-file"', self.code)
        self.assertNotIn('add_argument("--token",', self.code)
        self.assertIn("tokenPrinted", self.code)

    def test_hits_are_proven_by_correlated_events(self) -> None:
        self.assertIn("journal_events", self.code)
        self.assertIn('record.get("requestId") == request_id', self.code)
        for event in ("CACHE_HIT", "CACHE_FILL_STARTED", "CACHE_FILL_COMPLETED",
                      "REMOTE_STORAGE_REQUEST_STARTED"):
            self.assertIn(event, self.code)

    def test_every_required_test_is_present(self) -> None:
        for name in ("T1_health200", "T2_integrityOk", "T3_listingAuthorised",
                     "T4_coverMatchesManifest", "T5_missSucceeded",
                     "T5_hashExact", "T5_fillStarted", "T5_fillCompleted",
                     "T6_cacheHitObserved", "T6_upstreamNotContacted",
                     "T7_emptyBody", "T8_contentRangeCorrect",
                     "T9_notSynthetic", "T10_cacheHitAfterRestart",
                     "T11_persistsAcrossRestart"):
            self.assertIn(name, self.code, name)

    def test_expected_values_are_read_from_the_database_not_hardcoded(self) -> None:
        # Codées en dur, elles deviendraient fausses à la prochaine release ;
        # lues de la base, le test compare le service à sa source de vérité.
        self.assertIn("def track_expectations", self.code)
        self.assertIn("SELECT size_bytes AS sizeBytes, hash FROM tracks", self.code)

    def test_only_the_shadow_service_is_restarted(self) -> None:
        self.assertIn('subprocess.run(["systemctl", "restart", SERVICE]', self.code)
        self.assertIn('SERVICE = "homespotify-api-shadow.service"', self.code)
        for forbidden in ("caddy", "wg-quick", "reboot"):
            self.assertNotIn(forbidden, self.code)

    def test_the_disposable_write_has_no_external_effect(self) -> None:
        # Un favori : écriture en base, rien d'autre. Aucun import réel,
        # aucune acquisition, aucun courriel, aucun traitement externe.
        self.assertIn("/api/favorites", self.code)
        for forbidden in ("/api/imports", "/api/acquisition", "/api/discovery",
                          "lucida", "smtp"):
            self.assertNotIn(forbidden, self.code.lower())

    def test_the_disposable_write_is_undone(self) -> None:
        self.assertIn("T11_cleanupSucceeded", self.code)
        self.assertIn('request("DELETE", f"/api/favorites/', self.code)

    def test_tests_run_only_against_loopback(self) -> None:
        self.assertIn('HOST, PORT = "127.0.0.1", 3002', self.code)
        self.assertNotIn("0.0.0.0", self.code)
        self.assertNotIn("music.romainbegot.fr", self.code)


# ===========================================================================
# Surveillance
# ===========================================================================
class MonitorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.code = code_of(MONITOR)

    def test_min_max_and_final_are_published(self) -> None:
        # Une moyenne lisserait exactement le pic qu'on cherche.
        for metric in ("rssKb", "fileDescriptors", "threads", "cacheBytes"):
            self.assertIn(f'"{metric}":{{"min":%s,"max":%s,"final":%s}}', self.code)

    def test_required_metrics_are_collected(self) -> None:
        for metric in ("cpuSeconds", "dbBytes", "walBytes", "shmBytes",
                       "nRestarts", "journalErrors", "journalWarnings",
                       "cacheFiles", "productionHealth"):
            self.assertIn(metric, self.code)

    def test_a_restart_during_monitoring_is_a_failure(self) -> None:
        # Un PID qui change invalide toutes les mesures de tendance.
        self.assertIn("PID_CHANGE", self.code)

    def test_public_listeners_are_rechecked_at_every_sample(self) -> None:
        self.assertIn("publicListenerAnomalies", self.code)
        self.assertIn("loopbackListenerAnomalies", self.code)

    def test_monitoring_is_read_only(self) -> None:
        for forbidden in ("systemctl start", "systemctl stop",
                          "systemctl restart", "rm ", "install ", "chmod"):
            self.assertNotIn(forbidden, self.code)

    def test_it_does_not_claim_to_replace_the_soak(self) -> None:
        self.assertIn('"soakReplaced":false', self.code)


# ===========================================================================
# Encodage — défaut trouvé en Phase 6.3
# ===========================================================================
class PowerShellPitfallsTest(unittest.TestCase):
    def test_no_local_variable_shadows_a_switch_parameter(self) -> None:
        # Défaut trouvé en exécution réelle : `$activate = Invoke-Ssh ...`
        # n'était pas une variable locale mais le paramètre `[switch]
        # $Activate` — PowerShell ne distingue pas la casse. L'affectation
        # d'un hashtable à un switch lève une erreur de conversion en pleine
        # exécution, APRÈS que l'étape distante a déjà eu lieu.
        import re

        text = read(ORCHESTRATOR)
        switches = {m.group(1).lower()
                    for m in re.finditer(r"\[switch\]\s*\$(\w+)", script_params(text))}
        assigned = {m.group(1).lower()
                    for m in re.finditer(r"^\s*\$(\w+)\s*=", text, re.M)}
        self.assertEqual(sorted(switches & assigned), [],
                         "variable locale homonyme d'un paramètre switch")

    def test_no_local_variable_shadows_a_typed_parameter(self) -> None:
        # Même piège, conséquences plus discrètes : écraser un `[string]`
        # passe silencieusement et fausse une étape ultérieure.
        import re

        text = read(ORCHESTRATOR)
        typed = {m.group(1).lower()
                 for m in re.finditer(r"\[(?:string|int)\]\s*\$(\w+)", script_params(text))}
        assigned = {m.group(1).lower()
                    for m in re.finditer(r"^\s*\$(\w+)\s*=", text, re.M)}
        self.assertEqual(sorted(typed & assigned), [],
                         "variable locale homonyme d'un paramètre typé")


class RemoteVerificationTest(unittest.TestCase):
    def test_privileged_checks_are_run_with_sudo(self) -> None:
        # Défaut trouvé en exécution réelle : `/opt/homespotify-api-shadow`
        # est en 0750 root:homespotify. Un contrôle lancé en `debian` reçoit
        # « permission refusée », et un `|| echo ABSENT` traduit cela en
        # « absent » — le rapport affirme alors que rien n'est installé alors
        # que tout l'est. Un contrôle incapable de distinguer « absent » de
        # « non autorisé » ne constate rien.
        code = code_of(ORCHESTRATOR)
        activate = code[code.index("if ($Activate) {"):]
        for privileged in ("/etc/homespotify/api-shadow.env",
                           "/var/lib/homespotify-shadow/data/runtime.db"):
            for line in activate.splitlines():
                if privileged in line and ("stat " in line or "sha256sum" in line):
                    self.assertIn("sudo -n", line, line.strip()[:80])


class PreinstallCheckTest(unittest.TestCase):
    def setUp(self) -> None:
        self.code = code_of(HERE / "vps_phase6_preinstall_check.sh")

    def test_shell_expansions_live_in_a_shell_script(self) -> None:
        # Défaut trouvé en exécution réelle : ce contrôle vivait dans un
        # here-string PowerShell. Les `$4` d'`awk` et l'ancre `:3002$` y
        # étaient interpolés par PowerShell AVANT d'atteindre bash, donc
        # `awk '{print }'` sur du vide : le contrôle du port renvoyait
        # TOUJOURS zéro. Il n'a jamais rien vérifié.
        self.assertIn("awk '{print $4}'", self.code)
        self.assertIn('grep -c ":${PORT}\\$"', self.code)
        orchestrator = code_of(ORCHESTRATOR)
        self.assertIn("vps_phase6_preinstall_check.sh", orchestrator)
        # Plus aucun `awk` dans un here-string de l'orchestrateur.
        self.assertNotIn("awk '{print $4}'", orchestrator)

    def test_it_reports_the_state_it_is_asked_about(self) -> None:
        for field in ("installedRelease", "serviceState", "serviceEnabled",
                      "port3002Listeners", "port3002Public", "homespotifyUnits",
                      "userState", "optPresent", "statePresent", "etcPresent",
                      "caddyActive", "caddySha256", "wireguard",
                      "storageAgentReachable", "publicHealth", "publicRoot",
                      "diskAvailBytes", "cacheAudioObjects"):
            self.assertIn(field, self.code, field)

    def test_the_cache_index_is_not_mistaken_for_smuggled_audio(self) -> None:
        # L'index du cache est écrit par le service à son démarrage. Le
        # confondre avec un objet audio préexistant ferait échouer toute
        # réinstallation.
        self.assertIn("-not -path '*/metadata/*'", self.code)
        self.assertIn("-not -path '*/metadata/*'",
                      code_of(HERE / "vps_phase6_activate_shadow.sh"))

    def test_systemctl_defaults_do_not_concatenate(self) -> None:
        # Défaut trouvé dans le rapport final : `systemctl is-enabled` ÉCRIT
        # sa réponse sur stdout ET sort en code non nul. Un `|| echo disabled`
        # ajoute donc sa valeur à celle déjà imprimée : « disableddisabled ».
        # Un champ de rapport que personne ne peut comparer ne rapporte rien.
        for path in (HERE / "vps_phase6_preinstall_check.sh",
                     HERE / "vps_phase6_start_shadow.sh",
                     HERE / "run_phase6_shadow_deploy.ps1"):
            code = code_of(path)
            for pattern in ("|| echo disabled", "|| echo inactive",
                            "|| echo unknown"):
                self.assertNotIn(pattern, code, f"{path.name} : {pattern}")

    def test_the_check_writes_nothing(self) -> None:
        for forbidden in ("install ", "mkdir", "rm ", "chmod", "chown",
                          "systemctl start", "systemctl stop", "useradd"):
            self.assertNotIn(forbidden, self.code, forbidden)


class EncodingTest(unittest.TestCase):
    def test_powershell_scripts_are_utf8_with_bom(self) -> None:
        # Windows PowerShell 5.1 lit un `.ps1` SANS BOM avec l'encodage ANSI.
        # Le tiret cadratin « — » (E2 80 94) y devient « â€" », et l'octet
        # 0x94 est un guillemet fermant typographique que le parseur traite
        # comme un délimiteur de chaîne : la chaîne se termine au milieu, et
        # l'erreur signalée désigne un mot quelconque de la phrase. Le BOM
        # supprime la classe entière — et accessoirement rend les accents
        # lisibles dans la console.
        for path in sorted(HERE.glob("*.ps1")):
            with self.subTest(file=path.name):
                self.assertTrue(path.read_bytes().startswith(b"\xef\xbb\xbf"),
                                f"{path.name} : BOM UTF-8 absent")

    def test_shell_scripts_still_carry_no_carriage_return(self) -> None:
        for path in sorted(HERE.glob("*.sh")):
            self.assertNotIn(b"\r", path.read_bytes(), path.name)

    def test_powershell_scripts_parse(self) -> None:
        if sys.platform != "win32":
            self.skipTest("parseur PowerShell indisponible hors Windows")
        for path in sorted(HERE.glob("*.ps1")):
            command = (
                "$e=$null;"
                f"[void][System.Management.Automation.Language.Parser]::ParseFile('{path}',"
                "[ref]$null,[ref]$e);"
                "if($e -and $e.Count){exit 1}else{exit 0}"
            )
            result = subprocess.run(
                ["powershell", "-NoProfile", "-NonInteractive", "-Command", command],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, f"{path.name} : parse échoué")


# ===========================================================================
# Orchestrateur — mode Activate
# ===========================================================================
class ActivateOrchestratorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.code = code_of(ORCHESTRATOR)

    def test_activate_refuses_an_application_change_since_the_release(self) -> None:
        # L'invariant est « le code installé est le code qualifié ». Exiger
        # que RIEN n'ait bougé dans le dépôt rendrait la phase impossible :
        # elle écrit forcément son propre outillage d'installation.
        self.assertIn("$artifactSources = @('services/api', 'services/storage-agent', 'packages')",
                      self.code)
        self.assertIn("changement applicatif depuis la release", self.code)
        self.assertIn("refaire un -StageOnly", self.code)

    def test_activate_proves_the_content_by_manifest_digest(self) -> None:
        # Preuve directe et indépendante des chemins : le manifeste ne dépend
        # que du contenu de l'artefact, jamais de l'horodatage ni du commit.
        self.assertIn("$expectedManifest = $ReleaseId.Split('-')[2]", self.code)
        self.assertIn("empreinte de manifeste divergente", self.code)
        self.assertIn("manifestSha256", code_of(HERE / "vps_phase6_preinstall_check.sh"))

    def test_activate_proves_production_is_untouched(self) -> None:
        self.assertIn("$prodBefore", self.code)
        self.assertIn("$prodDbAfter", self.code)
        self.assertIn("windowsServicesUnchanged", self.code)
        self.assertIn("Fail 'Caddyfile modifié'", self.code)

    def test_activate_refuses_a_public_listener(self) -> None:
        self.assertIn("Fail 'listener public sur 3002'", self.code)
        self.assertIn("port3002Public", self.code)

    def test_activate_never_enables_at_boot(self) -> None:
        self.assertIn("Fail 'le service a été activé au démarrage'", self.code)
        self.assertNotIn("--enable", self.code)

    def test_remote_output_is_never_reflowed(self) -> None:
        # Défaut trouvé en exécution réelle : `Out-String` replie à la largeur
        # de la console. Une ligne JSON longue en ressortait coupée, et
        # l'orchestrateur échouait sur « chaîne inachevée » APRÈS un démarrage
        # parfaitement réussi — l'outil de rapport faisait échouer ce qu'il
        # devait constater.
        self.assertNotIn("Out-String", self.code)
        self.assertIn('($output | ForEach-Object { "$_" }) -join', self.code)

    def test_a_reflowed_json_line_is_reassembled(self) -> None:
        # Une ligne JSON longue peut ressortir coupée par l'hôte PowerShell.
        # Chercher « la dernière ligne qui commence par { » donnait un
        # fragment, et l'analyse échouait sur une commande distante qui avait
        # réussi.
        self.assertIn("$buffer += $lines[$j]", self.code)
        self.assertIn("ConvertFrom-Json -ErrorAction Stop", self.code)

    def test_privileged_reads_run_as_root(self) -> None:
        # Un contrôle incapable de distinguer « absent » de « non autorisé »
        # ne constate rien : `/opt/homespotify-api-shadow` est en 0750.
        self.assertIn("[switch] $AsRoot", self.code)
        self.assertIn("if ($AsRoot) { 'sudo -n bash -s --' }", self.code)
        self.assertIn("-AsRoot", self.code)

    def test_resuming_requires_the_installation_to_match(self) -> None:
        # Idempotence explicite : une installation déjà en place n'est
        # acceptée que si elle porte exactement la release visée. Toute autre
        # est un état inconnu, et un état inconnu ne se surinstalle pas.
        self.assertIn("installation existante non conforme", self.code)
        self.assertIn("$pre.installedRelease -ne $ReleaseId", self.code)
        self.assertIn("le port 3002 est occupé par autre chose que le shadow visé",
                      self.code)

    def test_the_token_file_is_destroyed(self) -> None:
        self.assertIn("rm -f '$tokenFile'", self.code)
        self.assertIn("tokenRemoved", self.code)

    def test_staging_is_kept_when_the_verdict_is_not_green(self) -> None:
        self.assertIn("if ($verdict -and -not $KeepStaging) {", self.code)
        self.assertIn("staging CONSERVÉ", self.code)

    def test_the_report_publishes_every_required_field(self) -> None:
        for field in ("preInstall", "systemd", "install", "start", "token",
                      "tests", "monitor", "postChecks", "production",
                      "stagingRemoved", "bootEnabled", "publicPortsAdded",
                      "cutoverPerformed", "sshConnectionsOpened",
                      "secretsPrinted", "tokenPrinted"):
            self.assertIn(field, self.code, field)


if __name__ == "__main__":
    unittest.main(verbosity=2)
