#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${HOME}/homespotify-phase45"
INCOMING="${ROOT}/incoming"
STATE_FILE="${ROOT}/runtime/phase45.json"
SECRET_FILE="${ROOT}/.hmac-secret"
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

case "${ROOT}" in
  "${HOME}/homespotify-phase45") ;;
  *) STEP="validate_root"; exit 2 ;;
esac

STEP="validate_inputs"
for required_file in \
  "${INCOMING}/vps_phase45_state_value.py" \
  "${INCOMING}/vps_storage_agent_smoke_test.py" \
  "${STATE_FILE}" \
  "${SECRET_FILE}"; do
  test -f "${required_file}"
done
test "$(stat -c '%a' "${SECRET_FILE}")" = "600"
command -v timeout >/dev/null

STEP="read_track_id"
TRACK_ID="$(
  PYTHONUNBUFFERED=1 python3 -u \
    "${INCOMING}/vps_phase45_state_value.py" \
    "${STATE_FILE}" \
    smallTrackId
)"

STEP="smoke_agent"
echo "SMOKE_AGENT_BEGIN"
echo "SMOKE_AGENT_RUNNING"
set +e
PYTHONUNBUFFERED=1 timeout --signal=TERM --kill-after=10s 180s \
  python3 -u "${INCOMING}/vps_storage_agent_smoke_test.py" \
  "http://10.8.0.2:3100" \
  "${TRACK_ID}" \
  --secret-file "${SECRET_FILE}"
SMOKE_EXIT=$?
set -e

if [[ "${SMOKE_EXIT}" -eq 124 ]]; then
  echo "PHASE45_TIMEOUT step=smoke_agent exit=124 limitSeconds=180" >&2
  exit 124
fi
if [[ "${SMOKE_EXIT}" -ne 0 ]]; then
  exit "${SMOKE_EXIT}"
fi

STEP="complete"
echo "SMOKE_AGENT_END"
