#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="${HOME}/homespotify-phase5"
pid="$(cat "${ROOT}/runtime/api.pid")"
kill "${pid}"
timeout 20s tail --pid="${pid}" -f /dev/null || true
test "$(ss -ltnH '( sport = :3001 )' 2>/dev/null | wc -l)" -eq 0
pushd "${ROOT}/api" >/dev/null
nohup node dist/server.js >>"${ROOT}/runtime/api.stdout.log" \
  2>>"${ROOT}/runtime/api.stderr.log" &
printf '%s\n' "$!" >"${ROOT}/runtime/api.pid"
popd >/dev/null
deadline=$((SECONDS + 60))
while (( SECONDS < deadline )); do
  if timeout 10s python3 - <<'PY'
import urllib.request
try:
    with urllib.request.urlopen("http://127.0.0.1:3001/health", timeout=5) as response:
        raise SystemExit(0 if response.status == 200 else 1)
except Exception:
    raise SystemExit(1)
PY
  then
    echo '{"status":"phase5-api-restarted","bind":"127.0.0.1:3001"}'
    exit 0
  fi
  sleep 0.5
done
exit 124
