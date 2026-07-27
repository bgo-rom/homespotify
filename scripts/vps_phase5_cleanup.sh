#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${HOME}/homespotify-phase5"
if [[ -f "${ROOT}/runtime/api.pid" ]]; then
  pid="$(cat "${ROOT}/runtime/api.pid" 2>/dev/null || true)"
  [[ "${pid}" =~ ^[0-9]+$ ]] && kill "${pid}" 2>/dev/null || true
  [[ "${pid}" =~ ^[0-9]+$ ]] && timeout 10s tail --pid="${pid}" -f /dev/null 2>/dev/null || true
  [[ "${pid}" =~ ^[0-9]+$ ]] && kill -KILL "${pid}" 2>/dev/null || true
fi
rm -f -- "${ROOT}/api/.env" "${ROOT}/.hmac-secret"
rm -f -- "${ROOT}/runtime/phase5-offline-precondition.json"
# TOUTES les racines de cache, y compris celles des scenarios isoles
# (`runtime/cache-finalize-offline`, `cache-abort`, `cache-eviction`).
rm -rf -- "${ROOT}/cache"
rm -rf -- "${ROOT}"/runtime/cache-*
listeners="$(ss -ltnH '( sport = :3001 )' 2>/dev/null | wc -l)"
secrets="$(find "${ROOT}" -maxdepth 3 -type f \( -name '.env' -o -name '.hmac-secret' \) 2>/dev/null | wc -l)"
caches="$(find "${ROOT}" -maxdepth 2 -type d -name 'cache*' 2>/dev/null | wc -l)"
printf '{"status":"clean","remainingSecretFiles":%s,"remainingCacheRoots":%s,"remainingListeners":%s}\n' \
  "${secrets}" "${caches}" "${listeners}"
test "${secrets}" -eq 0
test "${caches}" -eq 0
test "${listeners}" -eq 0
