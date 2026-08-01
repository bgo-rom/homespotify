#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${HOME}/homespotify-phase45"
APP="${ROOT}/api"
RUNTIME="${ROOT}/runtime"
INCOMING="${ROOT}/incoming"
STEP="initialization"
FAILED_LINE="unknown"
FAILED_COMMAND="unknown"

record_error() {
  local exit_code=$?
  FAILED_LINE="${BASH_LINENO[0]:-unknown}"
  FAILED_COMMAND="${BASH_COMMAND%% *}"
  return "${exit_code}"
}

cleanup_on_error() {
  local exit_code=$?
  trap - EXIT ERR TERM INT HUP
  if [[ "${exit_code}" -ne 0 ]]; then
    printf 'PHASE45_ERROR script=%s line=%s exit=%s step=%s command=%s\n' \
      "$(basename "$0")" "${FAILED_LINE}" "${exit_code}" "${STEP}" "${FAILED_COMMAND}" >&2
    bash "${INCOMING}/vps_phase45_cleanup.sh" || true
  fi
  exit "${exit_code}"
}

trap record_error ERR
trap cleanup_on_error EXIT
trap 'STEP="signal_term"; exit 143' TERM
trap 'STEP="signal_int"; exit 130' INT
trap 'STEP="signal_hup"; exit 129' HUP

STEP="validate_reusable_installation"
case "${ROOT}" in
  "${HOME}/homespotify-phase45") ;;
  *) exit 2 ;;
esac
test -f "${APP}/dist/server.js"
test -f "${APP}/package.json"
test -f "${APP}/drizzle/meta/_journal.json"
test -d "${APP}/node_modules/better-sqlite3"
test -f "${ROOT}/data/runtime.db"
test -f "${RUNTIME}/phase45.json"
test -f "${ROOT}/.hmac-secret"
test "$(stat -c '%a' "${ROOT}/.hmac-secret")" = "600"
test ! -e "${APP}/.env"
test "$(ss -ltnH '( sport = :3001 or sport = :3002 )' 2>/dev/null | wc -l)" -eq 0

STEP="write_configuration"
PYTHONUNBUFFERED=1 python3 -u \
  "${INCOMING}/vps_phase45_write_request_id_env.py" \
  --root "${ROOT}" \
  --secret-file "${ROOT}/.hmac-secret" \
  --output "${APP}/.env"
test "$(stat -c '%a' "${APP}/.env")" = "600"

STEP="start_api_3001"
rm -f -- "${RUNTIME}/api.pid" "${RUNTIME}/request-id-api.stdout.log" "${RUNTIME}/request-id-api.stderr.log"
pushd "${APP}" >/dev/null
nohup node dist/server.js \
  >"${RUNTIME}/request-id-api.stdout.log" \
  2>"${RUNTIME}/request-id-api.stderr.log" &
printf '%s\n' "$!" >"${RUNTIME}/api.pid"
popd >/dev/null

STEP="wait_api_3001"
deadline=$((SECONDS + 60))
while (( SECONDS < deadline )); do
  pid="$(cat "${RUNTIME}/api.pid")"
  state="$(ps -o stat= -p "${pid}" 2>/dev/null | tr -d '[:space:]')"
  if [[ -z "${state}" || "${state}" == Z* ]]; then
    wait "${pid}" || exit $?
    exit 1
  fi
  if PYTHONUNBUFFERED=1 python3 -u - 3001 <<'PY'
import sys
import urllib.request

try:
    with urllib.request.urlopen(
        f"http://127.0.0.1:{sys.argv[1]}/health",
        timeout=20,
    ) as response:
        raise SystemExit(0 if response.status == 200 else 1)
except Exception:
    raise SystemExit(1)
PY
  then
    STEP="complete"
    echo '{"status":"request-id-api-ready","bind":"127.0.0.1:3001","npmInstallPerformed":false}'
    exit 0
  fi
  sleep 0.5
done

echo "API_3001_HEALTH_TIMEOUT" >&2
exit 124
