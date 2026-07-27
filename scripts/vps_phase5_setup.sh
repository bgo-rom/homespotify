#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${HOME}/homespotify-phase5"
SOURCE="${HOME}/homespotify-phase45"
# Scenario ISOLE : determine la racine de cache et la capacite (voir
# vps_phase5_write_env.py). Par defaut, celui qui a besoin de conserver son
# objet cache : finalisation, HIT et mode hors ligne.
SCENARIO="${1:-finalize-offline}"
case "${SCENARIO}" in
  finalize-offline|abort|eviction) ;;
  *) echo "PHASE5_ERROR step=validate_scenario reason=unknown_scenario" >&2; exit 2 ;;
esac
STEP="initialization"
trap 'code=$?; if [[ $code -ne 0 ]]; then printf "PHASE5_ERROR line=%s exit=%s step=%s\n" "${BASH_LINENO[0]:-unknown}" "$code" "$STEP" >&2; bash "${ROOT}/incoming/vps_phase5_cleanup.sh" || true; fi' EXIT

STEP="validate_sources"
test -f "${SOURCE}/api/package.json"
test -d "${SOURCE}/api/node_modules/better-sqlite3"
test -f "${SOURCE}/data/runtime.db"
test -f "${SOURCE}/runtime/phase45.json"
test -f "${ROOT}/incoming/dist/server.js"
test -f "${ROOT}/.hmac-secret"
test "$(stat -c '%a' "${ROOT}/.hmac-secret")" = "600"
test "$(ss -ltnH '( sport = :3001 )' 2>/dev/null | wc -l)" -eq 0

STEP="prepare_isolated_app"
# `runtime` contient desormais les racines de cache par scenario
# (`runtime/cache-<scenario>`) : les effacer ici garantit qu'aucun scenario ne
# demarre sur l'etat laisse par un autre.
rm -rf -- "${ROOT}/api" "${ROOT}/data" "${ROOT}/runtime" "${ROOT}/cache"
mkdir -p "${ROOT}/data" "${ROOT}/runtime/music" "${ROOT}/runtime/imports" \
  "${ROOT}/runtime/covers" "${ROOT}/runtime/offline"
cp -a -- "${SOURCE}/api" "${ROOT}/api"
rm -rf -- "${ROOT}/api/dist"
cp -a -- "${ROOT}/incoming/dist" "${ROOT}/api/dist"
cp -- "${SOURCE}/data/runtime.db" "${ROOT}/data/runtime.db"
cp -- "${SOURCE}/runtime/phase45.json" "${ROOT}/runtime/phase5.json"
rm -f -- "${ROOT}/api/.env"

STEP="write_env"
PYTHONUNBUFFERED=1 python3 -u "${ROOT}/incoming/vps_phase5_write_env.py" \
  --root "${ROOT}" --secret-file "${ROOT}/.hmac-secret" \
  --state-file "${ROOT}/runtime/phase5.json" --output "${ROOT}/api/.env" \
  --scenario "${SCENARIO}"
test "$(stat -c '%a' "${ROOT}/api/.env")" = "600"

STEP="start_api"
pushd "${ROOT}/api" >/dev/null
nohup node dist/server.js >"${ROOT}/runtime/api.stdout.log" \
  2>"${ROOT}/runtime/api.stderr.log" &
printf '%s\n' "$!" >"${ROOT}/runtime/api.pid"
popd >/dev/null

STEP="wait_health"
deadline=$((SECONDS + 60))
while (( SECONDS < deadline )); do
  if timeout 20s python3 - 3001 <<'PY'
import sys, urllib.request
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/health", timeout=10) as response:
        raise SystemExit(0 if response.status == 200 else 1)
except Exception:
    raise SystemExit(1)
PY
  then
    STEP="verify_log_capture"
    # Verification PRECOCE de la capture : ne pas decouvrir a la fin du test
    # que stdout est vide. `buildApp` journalise « application des migrations »
    # des le demarrage ; si ce fichier est vide alors que l'API repond, c'est
    # que le logger Fastify est desactive (NODE_ENV=test) ou que les
    # descripteurs ont ete perdus.
    API_PID="$(cat "${ROOT}/runtime/api.pid")"
    test -n "${API_PID}"
    kill -0 "${API_PID}"
    STDOUT_TARGET="$(readlink -f "/proc/${API_PID}/fd/1" 2>/dev/null || echo inconnu)"
    STDERR_TARGET="$(readlink -f "/proc/${API_PID}/fd/2" 2>/dev/null || echo inconnu)"
    LISTENING="$(ss -ltnH '( sport = :3001 )' 2>/dev/null | wc -l)"
    STDOUT_BYTES=0
    for _ in $(seq 1 20); do
      STDOUT_BYTES="$(stat -c '%s' "${ROOT}/runtime/api.stdout.log" 2>/dev/null || echo 0)"
      if [ "${STDOUT_BYTES}" -gt 0 ]; then break; fi
      sleep 0.5
    done
    JSON_LINES="$(grep -c '^{' "${ROOT}/runtime/api.stdout.log" 2>/dev/null || echo 0)"
    if [ "${JSON_LINES}" -gt 0 ]; then CAPTURED=true; else CAPTURED=false; fi
    cat <<JSON
{"status":"phase5-api-ready","scenario":"${SCENARIO}","bind":"127.0.0.1:3001","npmInstallPerformed":false,"apiPid":${API_PID},"listeners":${LISTENING},"stdoutTarget":"${STDOUT_TARGET}","stderrTarget":"${STDERR_TARGET}","stdoutBytes":${STDOUT_BYTES},"structuredLines":${JSON_LINES},"logCaptureVerified":${CAPTURED}}
JSON
    if [ "${JSON_LINES}" -eq 0 ]; then
      echo 'PHASE5_ERROR step=verify_log_capture reason=no_structured_log_captured' >&2
      exit 3
    fi
    exit 0
  fi
  sleep 0.5
done
tail -n 100 "${ROOT}/runtime/api.stderr.log" | sed -E 's/(SECRET|TOKEN|SIGNATURE|AUTHORIZATION)=[^ ]+/\1=[REDACTED]/Ig' >&2
exit 124
