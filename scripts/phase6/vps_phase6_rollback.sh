#!/usr/bin/env bash
# Rollback shadow : `current` revient sur `previous`. Idempotent.
#
# La release fautive est CONSERVEE. Supprimer ce qu'on vient de constater
# defaillant, c'est detruire la seule piece a conviction ; le disque coute
# moins cher qu'un diagnostic impossible.
set -Eeuo pipefail

ROOT="/opt/homespotify-api-shadow"
SERVICE="homespotify-api-shadow.service"

fail() { printf 'PHASE6_ERROR step=%s detail=%s\n' "$1" "${2:-}" >&2; exit 1; }

test -L "${ROOT}/previous" || fail PREVIOUS_ABSENT "aucune release anterieure"
PREVIOUS="$(readlink -f "${ROOT}/previous")"
test -d "${PREVIOUS}" || fail PREVIOUS_INCOMPLET "${PREVIOUS}"
test -f "${PREVIOUS}/dist/server.js" || fail PREVIOUS_INCOMPLET "dist absent"

FAULTY=""
if [ -L "${ROOT}/current" ]; then FAULTY="$(readlink -f "${ROOT}/current")"; fi
if [ "${FAULTY}" = "${PREVIOUS}" ]; then
  printf '{"ok":true,"rolledBack":false,"reason":"current est deja previous"}\n'
  exit 0
fi

systemctl stop "${SERVICE}" || true

ln -sfn "${PREVIOUS}" "${ROOT}/current.new"
mv -T "${ROOT}/current.new" "${ROOT}/current"

systemctl start "${SERVICE}"

deadline=$((SECONDS + 60))
while (( SECONDS < deadline )); do
  if curl -fsS --max-time 5 "http://127.0.0.1:3002/health" >/dev/null 2>&1; then
    printf '{"ok":true,"rolledBack":true,"current":"%s","faultyRetained":"%s","health":200}\n' \
      "${PREVIOUS}" "${FAULTY}"
    exit 0
  fi
  sleep 1
done
fail HEALTH_TIMEOUT_APRES_ROLLBACK "${PREVIOUS}"
