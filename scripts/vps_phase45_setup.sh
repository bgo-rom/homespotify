#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${HOME}/homespotify-phase45"
INCOMING="${ROOT}/incoming"
APP="${ROOT}/api"
BAD_APP="${ROOT}/api-bad-auth"
DATA="${ROOT}/data"
RUNTIME="${ROOT}/runtime"
SECRET_FILE="${ROOT}/.hmac-secret"
DIAGNOSTICS="${ROOT}/diagnostics"
CLEANUP_SCRIPT="${INCOMING}/vps_phase45_cleanup.sh"
STEP="initialization"
FAILED_LINE="unknown"
FAILED_COMMAND="unknown"

record_error() {
  local exit_code=$?
  FAILED_LINE="${BASH_LINENO[0]:-unknown}"
  FAILED_COMMAND="${BASH_COMMAND%% *}"
  return "${exit_code}"
}

sanitize_log() {
  local source_file="$1"
  local destination_file="$2"
  python3 - "${source_file}" "${destination_file}" "${APP}/.env" "${BAD_APP}/.env" <<'PY'
import re
import sys
from pathlib import Path

source_path, destination_path, *env_paths = map(Path, sys.argv[1:])
text = source_path.read_text(encoding="utf-8", errors="replace") if source_path.is_file() else ""

sensitive_values = []
for env_path in env_paths:
    if not env_path.is_file():
        continue
    for raw in env_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" not in raw:
            continue
        key, value = raw.split("=", 1)
        if any(marker in key.upper() for marker in ("SECRET", "TOKEN", "SIGNATURE", "AUTHORIZATION", "NONCE")):
            if len(value) >= 4:
                sensitive_values.append(value)

for value in sorted(sensitive_values, key=len, reverse=True):
    text = text.replace(value, "[REDACTED]")

text = re.sub(
    r"(?im)^(authorization|x-hs-signature|x-hs-nonce)\s*:\s*.*$",
    r"\1: [REDACTED]",
    text,
)
text = re.sub(r"(?i)\b[A-Z]:\\[^\r\n]*", "[WINDOWS_PATH_REDACTED]", text)
destination_path.write_text(text, encoding="utf-8")
PY
}

configuration_names() {
  local env_file="$1"
  python3 - "${env_file}" <<'PY'
import sys
from pathlib import Path

required = {
    "NODE_ENV", "HOST", "PORT", "DB_PATH", "MUSIC_DIR", "INCOMING_DIR",
    "HOMESPOTIFY_IMPORT_ROOT", "COVERS_DIR", "OFFLINE_CACHE_DIR",
    "BACKUP_ENABLED", "DISCOVERY_ENABLED", "SPOTIFY_DISCOVERY_ENABLED",
    "APPLE_MUSIC_DISCOVERY_ENABLED", "DEEZER_DISCOVERY_ENABLED",
    "AUDIO_STORAGE_MODE", "AUDIO_REMOTE_BASE_URL",
    "AUDIO_REMOTE_SHARED_SECRET", "AUDIO_REMOTE_CONNECT_TIMEOUT_MS",
    "AUDIO_REMOTE_HEADERS_TIMEOUT_MS", "AUDIO_REMOTE_BODY_IDLE_TIMEOUT_MS",
    "AUDIO_REMOTE_MAX_CONNECTIONS", "AUTH_TOKEN_SECRET", "LOG_LEVEL",
}
present = set()
path = Path(sys.argv[1])
if path.is_file():
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" in raw and not raw.lstrip().startswith("#"):
            present.add(raw.split("=", 1)[0].strip())
print("CONFIG_PRESENT_NAMES=" + ",".join(sorted(required & present)))
print("CONFIG_MISSING_NAMES=" + ",".join(sorted(required - present)))
if required - present:
    raise SystemExit(1)
PY
}

listener_count() {
  local port="$1"
  ss -ltnH "( sport = :${port} )" 2>/dev/null | wc -l
}

process_state() {
  local pid="$1"
  ps -o stat= -p "${pid}" 2>/dev/null | tr -d '[:space:]'
}

diagnose_api() {
  local label="$1"
  local port="$2"
  local app_dir="$3"
  local pid_file="$4"
  local stdout_file="$5"
  local stderr_file="$6"
  local exit_file="$7"
  local metadata_file="${DIAGNOSTICS}/${label}.metadata.txt"
  local safe_stdout="${DIAGNOSTICS}/${label}.stdout.log"
  local safe_stderr="${DIAGNOSTICS}/${label}.stderr.log"
  local pid="absent"
  local state="absent"
  local exit_code="indisponible"

  [[ -f "${pid_file}" ]] && pid="$(cat "${pid_file}")"
  if [[ "${pid}" =~ ^[0-9]+$ ]]; then
    state="$(process_state "${pid}")"
    [[ -n "${state}" ]] || state="termine"
  fi
  [[ -f "${exit_file}" ]] && exit_code="$(cat "${exit_file}")"

  {
    printf 'LABEL=%s\n' "${label}"
    printf 'PID=%s\n' "${pid}"
    printf 'PROCESS_STATE=%s\n' "${state}"
    printf 'EXIT_CODE=%s\n' "${exit_code}"
    printf 'LISTENER_COUNT=%s\n' "$(listener_count "${port}")"
    printf 'WORKING_DIRECTORY=%s\n' "${app_dir}"
    if [[ -f "${app_dir}/dist/server.js" ]]; then
      printf 'ENTRY_BYTES=%s\n' "$(stat -c '%s' "${app_dir}/dist/server.js")"
      printf 'ENTRY_SHA256=%s\n' "$(sha256sum "${app_dir}/dist/server.js" | cut -d' ' -f1)"
      if (cd "${app_dir}" && node --check dist/server.js >/dev/null 2>&1); then
        printf 'ENTRY_SYNTAX_CHECK=ok\n'
      else
        printf 'ENTRY_SYNTAX_CHECK=failed\n'
      fi
      if (cd "${app_dir}" && node -e "require('better-sqlite3')" >/dev/null 2>&1); then
        printf 'SQLITE_NATIVE_LOAD_CHECK=ok\n'
      else
        printf 'SQLITE_NATIVE_LOAD_CHECK=failed\n'
      fi
    fi
    configuration_names "${app_dir}/.env"
  } >"${metadata_file}"

  sanitize_log "${stdout_file}" "${safe_stdout}"
  sanitize_log "${stderr_file}" "${safe_stderr}"

  echo "DIAGNOSTIC_${label}_BEGIN"
  cat "${metadata_file}"
  echo "${label}_STDOUT_LAST_200_BEGIN"
  tail -n 200 "${safe_stdout}"
  echo "${label}_STDOUT_LAST_200_END"
  echo "${label}_STDERR_LAST_200_BEGIN"
  tail -n 200 "${safe_stderr}"
  echo "${label}_STDERR_LAST_200_END"
  echo "DIAGNOSTIC_${label}_END"
}

collect_failure_diagnostics() {
  mkdir -p -- "${DIAGNOSTICS}"
  diagnose_api \
    "api-3001" 3001 "${APP}" "${RUNTIME}/api.pid" \
    "${RUNTIME}/api-3001.stdout.log" "${RUNTIME}/api-3001.stderr.log" \
    "${RUNTIME}/api-3001.exit-code"
  diagnose_api \
    "api-3002" 3002 "${BAD_APP}" "${RUNTIME}/api-bad.pid" \
    "${RUNTIME}/api-3002.stdout.log" "${RUNTIME}/api-3002.stderr.log" \
    "${RUNTIME}/api-3002.exit-code"
}

on_exit() {
  local exit_code=$?
  trap - EXIT
  trap - ERR
  if [[ "${exit_code}" -eq 0 ]]; then
    return
  fi
  printf 'PHASE45_ERROR script=%s line=%s exit=%s step=%s command=%s\n' \
    "$(basename "$0")" "${FAILED_LINE}" "${exit_code}" "${STEP}" "${FAILED_COMMAND}" >&2
  set +e
  collect_failure_diagnostics
  if [[ -x "${CLEANUP_SCRIPT}" ]]; then
    bash "${CLEANUP_SCRIPT}"
  else
    rm -f -- "${SECRET_FILE}" "${APP}/.env" "${BAD_APP}/.env"
  fi
  exit "${exit_code}"
}

trap record_error ERR
trap on_exit EXIT
trap 'STEP="signal_term"; exit 143' TERM
trap 'STEP="signal_int"; exit 130' INT
trap 'STEP="signal_hup"; exit 129' HUP

STEP="validate_root"
case "${ROOT}" in
  "${HOME}/homespotify-phase45") ;;
  *) echo "REFUS: racine Phase 4.5 inattendue" >&2; exit 2 ;;
esac

STEP="validate_tools"
for command in node npm python3 timeout; do
  command -v "${command}" >/dev/null 2>&1 || {
    echo "PREREQUIS_ABSENT=${command}" >&2
    exit 2
  }
done

STEP="validate_inputs"
test -f "${INCOMING}/api-artifact/dist/server.js"
test -f "${INCOMING}/api-artifact/package.json"
test -f "${INCOMING}/api-artifact/drizzle/meta/_journal.json"
test -f "${INCOMING}/homespotify.db"
test -f "${SECRET_FILE}"

secret_mode="$(stat -c '%a' "${SECRET_FILE}")"
test "${secret_mode}" = "600" || {
  echo "SECRET_MODE_INVALIDE=${secret_mode}" >&2
  exit 2
}

STEP="prepare_directories"
rm -rf -- "${APP}" "${BAD_APP}" "${DATA}" "${RUNTIME}" "${DIAGNOSTICS}"
mkdir -p -- "${APP}" "${DATA}" "${RUNTIME}" \
  "${RUNTIME}/music" "${RUNTIME}/imports" "${RUNTIME}/covers" "${RUNTIME}/offline"
cp -a -- "${INCOMING}/api-artifact/." "${APP}/"
cp -- "${INCOMING}/homespotify.db" "${DATA}/source-backup.db"
cp -- "${DATA}/source-backup.db" "${DATA}/runtime.db"

STEP="prepare_sqlite_copy"
python3 - "${DATA}/source-backup.db" "${DATA}/runtime.db" "${RUNTIME}/phase45.json" <<'PY'
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone

source_path, runtime_path, output_path = sys.argv[1:]

source = sqlite3.connect(f"file:{source_path}?mode=ro", uri=True)
try:
    integrity = source.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        raise SystemExit("SOURCE_SQLITE_INTEGRITY_FAILED")
    source_track_count = source.execute("SELECT count(*) FROM tracks").fetchone()[0]
finally:
    source.close()

database = sqlite3.connect(runtime_path)
try:
    database.execute("PRAGMA foreign_keys=ON")
    integrity = database.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        raise SystemExit("RUNTIME_SQLITE_INTEGRITY_FAILED")

    principal = database.execute(
        """
        SELECT u.id, u.username, u.role
        FROM users u
        JOIN user_tracks ut ON ut.user_id = u.id AND ut.is_visible = 1
        JOIN tracks t ON t.id = ut.track_id
        WHERE u.is_active = 1 AND u.must_change_password = 0
        ORDER BY CASE u.role WHEN 'OWNER' THEN 0 ELSE 1 END, u.id
        LIMIT 1
        """
    ).fetchone()
    if principal is None:
        raise SystemExit("NO_VALIDATION_PRINCIPAL")
    user_id, username, role = principal

    tracks = database.execute(
        """
        SELECT t.id, t.size_bytes, t.hash
        FROM tracks t
        JOIN user_tracks ut ON ut.track_id = t.id
        WHERE ut.user_id = ? AND ut.is_visible = 1 AND t.size_bytes > 2048
        ORDER BY t.size_bytes ASC
        """,
        (user_id,),
    ).fetchall()
    if not tracks:
        raise SystemExit("NO_STREAMABLE_TRACK")
    small_track = tracks[0]
    large_track = tracks[-1]

    stale_track_id = database.execute("SELECT coalesce(max(id), 0) + 1000000 FROM tracks").fetchone()[0]
    now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    database.execute(
        """
        INSERT INTO tracks (
          id, hash, path, original_extension, mime_type, size_bytes,
          duration_seconds, title, artist, album, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            stale_track_id,
            "f" * 64,
            "phase45-validation-only.invalid",
            ".flac",
            "audio/flac",
            4096,
            1.0,
            "Phase45 validation",
            "Phase45",
            "Phase45",
            now,
        ),
    )
    database.execute(
        """
        INSERT INTO user_tracks (
          user_id, track_id, added_at, added_by_user_id, source, is_visible
        ) VALUES (?, ?, ?, ?, 'ADMIN', 1)
        """,
        (user_id, stale_track_id, now, user_id),
    )

    pending_offline = database.execute(
        """
        SELECT count(*) FROM track_offline_variants
        WHERE status IN ('PENDING', 'ENCODING')
        """
    ).fetchone()[0]
    if pending_offline:
        raise SystemExit("PENDING_OFFLINE_JOBS_PRESENT")

    database.commit()
    with open(output_path, "x", encoding="utf-8") as handle:
        json.dump(
            {
                "userId": user_id,
                "username": username,
                "role": role,
                "smallTrackId": small_track[0],
                "smallTrackSize": small_track[1],
                "smallTrackHash": small_track[2],
                "largeTrackId": large_track[0],
                "largeTrackSize": large_track[1],
                "staleTrackId": stale_track_id,
                "sourceTrackCount": source_track_count,
            },
            handle,
        )
    os.chmod(output_path, 0o600)
finally:
    database.close()
PY

STEP="install_dependencies"
(
  cd "${APP}"
  npm install --omit=dev --no-audit --no-fund
)

cp -a -- "${APP}" "${BAD_APP}"
cp -- "${DATA}/runtime.db" "${DATA}/bad-auth.db"

STEP="write_isolated_configuration"
python3 - "${SECRET_FILE}" "${APP}/.env" "${BAD_APP}/.env" "${ROOT}" <<'PY'
import os
import secrets
import sys

secret_path, good_env_path, bad_env_path, root = sys.argv[1:]
with open(secret_path, "r", encoding="utf-8") as handle:
    hmac_secret = handle.read().strip()
if len(hmac_secret) < 32:
    raise SystemExit("HMAC_SECRET_TOO_SHORT")

auth_secret = secrets.token_hex(32)
bad_hmac_secret = secrets.token_hex(32)

def content(port: int, db_name: str, remote_secret: str) -> str:
    values = {
        # Le mode test désactive explicitement les watchers d'import et les
        # analyseurs de fond. L'instance reste un vrai serveur HTTP, mais ne
        # lance aucun travail asynchrone susceptible de muter son clone SQLite.
        "NODE_ENV": "test",
        "HOST": "127.0.0.1",
        "PORT": str(port),
        "DB_PATH": f"{root}/data/{db_name}",
        "MUSIC_DIR": f"{root}/runtime/music",
        "INCOMING_DIR": f"{root}/runtime/imports",
        "HOMESPOTIFY_IMPORT_ROOT": f"{root}/runtime/imports",
        "COVERS_DIR": f"{root}/runtime/covers",
        "OFFLINE_CACHE_DIR": f"{root}/runtime/offline",
        "BACKUP_ENABLED": "false",
        "DISCOVERY_ENABLED": "false",
        "SPOTIFY_DISCOVERY_ENABLED": "false",
        "APPLE_MUSIC_DISCOVERY_ENABLED": "false",
        "DEEZER_DISCOVERY_ENABLED": "false",
        "AUDIO_STORAGE_MODE": "remote",
        "AUDIO_REMOTE_BASE_URL": "http://10.8.0.2:3100",
        "AUDIO_REMOTE_SHARED_SECRET": remote_secret,
        "AUDIO_REMOTE_CONNECT_TIMEOUT_MS": "2000",
        "AUDIO_REMOTE_HEADERS_TIMEOUT_MS": "5000",
        "AUDIO_REMOTE_BODY_IDLE_TIMEOUT_MS": "15000",
        "AUDIO_REMOTE_MAX_CONNECTIONS": "8",
        "AUTH_TOKEN_SECRET": auth_secret,
        "LOG_LEVEL": "info",
    }
    return "".join(f"{key}={value}\n" for key, value in values.items())

for path, data in (
    (good_env_path, content(3001, "runtime.db", hmac_secret)),
    (bad_env_path, content(3002, "bad-auth.db", bad_hmac_secret)),
):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(data)
PY

preflight_api() {
  local label="$1"
  local port="$2"
  local app_dir="$3"
  local db_file="$4"
  local env_file="${app_dir}/.env"

  echo "PREFLIGHT_${label}_BEGIN"
  node --version
  npm --version
  (
    cd "${app_dir}"
    printf 'PWD=%s\n' "$(pwd)"
    test -f dist/server.js
    printf 'ENTRY_EXISTS=yes\n'
    printf 'ENTRY_BYTES=%s\n' "$(stat -c '%s' dist/server.js)"
    printf 'ENTRY_MODE=%s\n' "$(stat -c '%a' dist/server.js)"
    printf 'ENTRY_SHA256=%s\n' "$(sha256sum dist/server.js | cut -d' ' -f1)"
    test -f package.json
    printf 'PACKAGE_JSON_EXISTS=yes\n'
    printf 'APP_DIRECTORY_MODE=%s\n' "$(stat -c '%a' .)"
    printf 'APP_DIRECTORY_OWNER=%s\n' "$(stat -c '%U:%G' .)"
    test -f drizzle/meta/_journal.json
    printf 'MIGRATION_JOURNAL_EXISTS=yes\n'
    test -d node_modules/better-sqlite3
    printf 'BETTER_SQLITE3_MODULE_EXISTS=yes\n'
    node --check dist/server.js
    printf 'ENTRY_SYNTAX_OK=yes\n'
    node -e "require('better-sqlite3'); console.log('SQLITE_NATIVE_OK=yes')"
  )
  test -f "${db_file}"
  printf 'SQLITE_COPY_EXISTS=yes\n'
  printf 'SQLITE_COPY_BYTES=%s\n' "$(stat -c '%s' "${db_file}")"
  printf 'SQLITE_COPY_MODE=%s\n' "$(stat -c '%a' "${db_file}")"
  printf 'SQLITE_PARENT_MODE=%s\n' "$(stat -c '%a' "$(dirname "${db_file}")")"
  printf 'SQLITE_PARENT_OWNER=%s\n' "$(stat -c '%U:%G' "$(dirname "${db_file}")")"
  test -r "${db_file}" && test -w "${db_file}"
  test -r "$(dirname "${db_file}")" && test -w "$(dirname "${db_file}")" && test -x "$(dirname "${db_file}")"
  printf 'SQLITE_WAL_PARENT_WRITABLE=yes\n'
  (
    cd "${app_dir}"
    node - "${db_file}" <<'NODE'
const Database = require("better-sqlite3");
const database = new Database(process.argv[2]);
const integrity = database.pragma("integrity_check", { simple: true });
database.close();
if (integrity !== "ok") process.exit(1);
console.log("SQLITE_NATIVE_OPEN_RW_OK=yes");
NODE
  )
  printf 'PORT_%s_LISTENERS_BEFORE=%s\n' "${port}" "$(listener_count "${port}")"
  test "$(listener_count "${port}")" -eq 0
  test "$(stat -c '%a' "${env_file}")" = "600"
  printf 'ENV_MODE=600\n'
  configuration_names "${env_file}"
  test -s "${env_file}"
  echo "PREFLIGHT_${label}_END"
}

STEP="preflight_api_3001"
preflight_api "api-3001" 3001 "${APP}" "${DATA}/runtime.db"
STEP="preflight_api_3002"
preflight_api "api-3002" 3002 "${BAD_APP}" "${DATA}/bad-auth.db"

start_api() {
  local app_dir="$1"
  local pid_file="$2"
  local stdout_file="$3"
  local stderr_file="$4"
  pushd "${app_dir}" >/dev/null
  : >"${stdout_file}"
  : >"${stderr_file}"
  nohup node dist/server.js >"${stdout_file}" 2>"${stderr_file}" &
  printf '%s\n' "$!" >"${pid_file}"
  popd >/dev/null
}

wait_health() {
  local port="$1"
  local pid_file="$2"
  local exit_file="$3"
  local deadline=$((SECONDS + 60))
  local pid
  pid="$(cat "${pid_file}")"
  while (( SECONDS < deadline )); do
    local state
    state="$(process_state "${pid}")"
    if [[ -z "${state}" || "${state}" == Z* ]]; then
      set +e
      wait "${pid}"
      local exit_code=$?
      set -e
      printf '%s\n' "${exit_code}" >"${exit_file}"
      echo "API_${port}_EXITED exitCode=${exit_code}" >&2
      return 1
    fi
    if python3 - "${port}" <<'PY'
import sys
import urllib.request
port = sys.argv[1]
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2) as response:
        raise SystemExit(0 if response.status == 200 else 1)
except Exception:
    raise SystemExit(1)
PY
    then
      return 0
    fi
    sleep 0.5
  done
  echo "API_${port}_HEALTH_TIMEOUT" >&2
  return 1
}

STEP="start_api_3001"
start_api \
  "${APP}" "${RUNTIME}/api.pid" \
  "${RUNTIME}/api-3001.stdout.log" "${RUNTIME}/api-3001.stderr.log"
STEP="wait_api_3001"
wait_health 3001 "${RUNTIME}/api.pid" "${RUNTIME}/api-3001.exit-code"

STEP="start_api_3002"
start_api \
  "${BAD_APP}" "${RUNTIME}/api-bad.pid" \
  "${RUNTIME}/api-3002.stdout.log" "${RUNTIME}/api-3002.stderr.log"
STEP="wait_api_3002"
wait_health 3002 "${RUNTIME}/api-bad.pid" "${RUNTIME}/api-3002.exit-code"

STEP="report_ready"
python3 - "${RUNTIME}/phase45.json" "${RUNTIME}/api.pid" "${RUNTIME}/api-bad.pid" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    phase = json.load(handle)
print(
    json.dumps(
        {
            "status": "ready",
            "sourceTrackCount": phase["sourceTrackCount"],
            "smallTrackId": phase["smallTrackId"],
            "largeTrackId": phase["largeTrackId"],
            "staleTrackId": phase["staleTrackId"],
            "apiPid": int(open(sys.argv[2], encoding="utf-8").read()),
            "badAuthApiPid": int(open(sys.argv[3], encoding="utf-8").read()),
            "binds": ["127.0.0.1:3001", "127.0.0.1:3002"],
            "backupEnabled": False,
            "importsRootIsolated": True,
            "productionDatabaseUsed": False,
        }
    )
)
PY

STEP="complete"
