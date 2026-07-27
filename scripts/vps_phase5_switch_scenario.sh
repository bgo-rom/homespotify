#!/usr/bin/env bash
# Bascule l'API cache parallele vers un AUTRE scenario isole.
#
# Pourquoi ce script existe (defaut reel du 2026-07-27)
# ----------------------------------------------------
# Tous les scenarios partageaient une seule racine de cache et une seule
# limite `AUDIO_CACHE_MAX_BYTES = max(small, second) + 1`, calibree pour
# GARANTIR l'eviction. Le scenario d'abandon evinçait donc l'objet promu par
# la finalisation, et le test hors ligne qui suivait n'avait plus rien a
# servir : 503 correct, precondition detruite par le harnais.
#
# Ce script arrete l'API, archive son journal, reecrit un `.env` 0600 pour le
# scenario demande (racine de cache ET capacite dediees), puis redemarre. Il
# n'y a JAMAIS deux API simultanees : le port 3001 est verifie libre avant le
# redemarrage. Caddy, WireGuard et le pare-feu ne sont pas touches.
set -Eeuo pipefail
ROOT="${HOME}/homespotify-phase5"
SCENARIO="${1:?scenario requis}"
case "${SCENARIO}" in
  finalize-offline|abort|eviction) ;;
  *) echo "PHASE5_ERROR step=validate_scenario reason=unknown_scenario" >&2; exit 2 ;;
esac

test -f "${ROOT}/.hmac-secret"
test "$(stat -c '%a' "${ROOT}/.hmac-secret")" = "600"

if [[ -f "${ROOT}/runtime/api.pid" ]]; then
  pid="$(cat "${ROOT}/runtime/api.pid")"
  if [[ "${pid}" =~ ^[0-9]+$ ]]; then
    kill "${pid}" 2>/dev/null || true
    timeout 20s tail --pid="${pid}" -f /dev/null 2>/dev/null || true
    kill -KILL "${pid}" 2>/dev/null || true
  fi
fi
test "$(ss -ltnH '( sport = :3001 )' 2>/dev/null | wc -l)" -eq 0

# Journal archive par scenario : `evictionsObserved` doit compter les
# evictions DU scenario en cours, pas la somme de tous les precedents. Le
# lecteur de journaux relit quand meme les archives `*.log.*` pour les
# diagnostics.
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
for name in api.stdout.log api.stderr.log; do
  if [[ -f "${ROOT}/runtime/${name}" ]]; then
    mv -- "${ROOT}/runtime/${name}" "${ROOT}/runtime/${name}.${STAMP}"
  fi
done

# Precondition hors ligne : elle appartient a un scenario precis, elle ne doit
# jamais survivre a une bascule.
rm -f -- "${ROOT}/runtime/phase5-offline-precondition.json"

rm -f -- "${ROOT}/api/.env"
PYTHONUNBUFFERED=1 python3 -u "${ROOT}/incoming/vps_phase5_write_env.py" \
  --root "${ROOT}" --secret-file "${ROOT}/.hmac-secret" \
  --state-file "${ROOT}/runtime/phase5.json" --output "${ROOT}/api/.env" \
  --scenario "${SCENARIO}"
test "$(stat -c '%a' "${ROOT}/api/.env")" = "600"

# Cache VIDE au demarrage du scenario : la racine est propre a ce scenario,
# aucun etat d'un autre ne peut subsister.
rm -rf -- "${ROOT}/runtime/cache-${SCENARIO}"

pushd "${ROOT}/api" >/dev/null
nohup node dist/server.js >"${ROOT}/runtime/api.stdout.log" \
  2>"${ROOT}/runtime/api.stderr.log" &
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
    LISTENING="$(ss -ltnH '( sport = :3001 )' 2>/dev/null | wc -l)"
    JSON_LINES="$(grep -c '^{' "${ROOT}/runtime/api.stdout.log" 2>/dev/null || echo 0)"
    printf '{"status":"phase5-scenario-switched","scenario":"%s","bind":"127.0.0.1:3001","listeners":%s,"structuredLines":%s}\n' \
      "${SCENARIO}" "${LISTENING}" "${JSON_LINES}"
    test "${LISTENING}" -eq 1
    exit 0
  fi
  sleep 0.5
done
exit 124
