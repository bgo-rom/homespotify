#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${HOME}/homespotify-phase45"
RUNTIME="${ROOT}/runtime"
STEP="initialization"
FAILED_LINE="unknown"
FAILED_COMMAND="unknown"

record_error() {
  local exit_code=$?
  FAILED_LINE="${BASH_LINENO[0]:-unknown}"
  FAILED_COMMAND="${BASH_COMMAND%% *}"
  return "${exit_code}"
}

cleanup() {
  local original_exit=$?
  trap - EXIT ERR TERM INT HUP
  set +e
  STEP="stop_parallel_apis"

  for pid_file in "${RUNTIME}/api.pid" "${RUNTIME}/api-bad.pid"; do
    if [[ -f "${pid_file}" ]]; then
      pid="$(cat "${pid_file}")"
      if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
        kill -TERM "${pid}"
        for _ in $(seq 1 40); do
          kill -0 "${pid}" 2>/dev/null || break
          sleep 0.25
        done
        kill -0 "${pid}" 2>/dev/null && kill -KILL "${pid}"
      fi
    fi
  done

  STEP="remove_secrets"
  rm -f -- \
    "${ROOT}/.hmac-secret" \
    "${ROOT}/api/.env" \
    "${ROOT}/api-bad-auth/.env"

  STEP="verify_cleanup"
  remaining="$(find "${ROOT}" -maxdepth 3 -type f \
    \( -name '.hmac-secret' -o -name '.env' \) -print | wc -l)"
  listeners="$(ss -ltnH '( sport = :3001 or sport = :3002 )' 2>/dev/null | wc -l)"

  printf '{"status":"clean","remainingSecretFiles":%s,"remainingListeners":%s}\n' \
    "${remaining}" "${listeners}"

  if [[ "${remaining}" -ne 0 || "${listeners}" -ne 0 ]]; then
    printf 'PHASE45_ERROR script=%s line=%s exit=1 step=%s command=cleanup_verification\n' \
      "$(basename "$0")" "${FAILED_LINE}" "${STEP}" >&2
    exit 1
  fi
  if [[ "${original_exit}" -ne 0 ]]; then
    printf 'PHASE45_ERROR script=%s line=%s exit=%s step=%s command=%s\n' \
      "$(basename "$0")" "${FAILED_LINE}" "${original_exit}" "${STEP}" "${FAILED_COMMAND}" >&2
    exit "${original_exit}"
  fi
  exit 0
}

trap record_error ERR
trap cleanup EXIT
trap 'STEP="signal_term"; exit 143' TERM
trap 'STEP="signal_int"; exit 130' INT
trap 'STEP="signal_hup"; exit 129' HUP

STEP="validate_root"
case "${ROOT}" in
  "${HOME}/homespotify-phase45") ;;
  *) exit 2 ;;
esac

STEP="complete"
