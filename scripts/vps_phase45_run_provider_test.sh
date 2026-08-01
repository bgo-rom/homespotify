#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${HOME}/homespotify-phase45"
INCOMING="${ROOT}/incoming"
MODE="${1:-full}"
STEP="initialization"
FAILED_LINE="unknown"
FAILED_COMMAND="unknown"

record_error() {
  local exit_code=$?
  FAILED_LINE="${BASH_LINENO[0]:-unknown}"
  FAILED_COMMAND="${BASH_COMMAND%% *}"
  return "${exit_code}"
}

report_exit() {
  local exit_code=$?
  if [[ "${exit_code}" -ne 0 ]]; then
    printf 'PHASE45_ERROR script=%s line=%s exit=%s step=%s command=%s\n' \
      "$(basename "$0")" "${FAILED_LINE}" "${exit_code}" "${STEP}" "${FAILED_COMMAND}" >&2
    if [[ -x "${INCOMING}/vps_phase45_cleanup.sh" ]]; then
      bash "${INCOMING}/vps_phase45_cleanup.sh" || true
    fi
  fi
}

trap record_error ERR
trap report_exit EXIT
trap 'STEP="signal_term"; exit 143' TERM
trap 'STEP="signal_int"; exit 130' INT
trap 'STEP="signal_hup"; exit 129' HUP

case "${MODE}" in
  full)
    STEP="remote_provider_full"
    LIMIT_SECONDS=240
    REQUEST_ID="${2:-phase45-remote-propagation}"
    [[ "${REQUEST_ID}" =~ ^[A-Za-z0-9._:-]{1,96}$ ]]
    MODE_ARGUMENTS=(--request-id "${REQUEST_ID}")
    ;;
  offline)
    STEP="remote_provider_offline"
    LIMIT_SECONDS=60
    MODE_ARGUMENTS=(--offline-check)
    ;;
  request-id)
    STEP="remote_provider_request_id"
    LIMIT_SECONDS=60
    REQUEST_ID="${2:-}"
    [[ "${REQUEST_ID}" =~ ^[A-Za-z0-9._:-]{1,96}$ ]]
    MODE_ARGUMENTS=(--request-id-only --request-id "${REQUEST_ID}")
    ;;
  *)
    STEP="validate_mode"
    exit 2
    ;;
esac

command -v timeout >/dev/null

echo "REMOTE_PROVIDER_${MODE^^}_BEGIN"
echo "REMOTE_PROVIDER_${MODE^^}_RUNNING"
set +e
PYTHONUNBUFFERED=1 timeout --signal=TERM --kill-after=10s "${LIMIT_SECONDS}s" \
  python3 -u "${INCOMING}/vps_phase45_remote_provider_test.py" \
  "${MODE_ARGUMENTS[@]}" \
  --phase-file "${ROOT}/runtime/phase45.json" \
  --app-env "${ROOT}/api/.env" \
  --bad-app-env "${ROOT}/api-bad-auth/.env" \
  --secret-file "${ROOT}/.hmac-secret" \
  --api-pid-file "${ROOT}/runtime/api.pid"
TEST_EXIT=$?
set -e

if [[ "${TEST_EXIT}" -eq 124 ]]; then
  printf 'PHASE45_TIMEOUT step=%s exit=124 limitSeconds=%s\n' \
    "${STEP}" "${LIMIT_SECONDS}" >&2
  exit 124
fi
if [[ "${TEST_EXIT}" -ne 0 ]]; then
  exit "${TEST_EXIT}"
fi

STEP="complete"
echo "REMOTE_PROVIDER_${MODE^^}_END"
