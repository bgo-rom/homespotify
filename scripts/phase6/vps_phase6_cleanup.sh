#!/usr/bin/env bash
# Desinstallation complete du shadow Phase 6. Idempotent et BORNE.
#
# GARDE-FOU
# ---------
# Chaque suppression passe par `guard()`, qui refuse tout chemin hors des deux
# racines shadow et tout chemin protege. Les arbres des Phases 4.5 et 5, Caddy,
# WireGuard et les services Windows ne sont jamais touches — ce n'est pas une
# intention, c'est verifie a chaque appel.
set -Eeuo pipefail

ROOT="/opt/homespotify-api-shadow"
STATE="/var/lib/homespotify-shadow"
ENV_FILE="/etc/homespotify/api-shadow.env"
SERVICE="homespotify-api-shadow.service"
UNIT="/etc/systemd/system/${SERVICE}"
OVERRIDE="/etc/systemd/system/${SERVICE}.d"

PROTECTED="/home/debian/homespotify-phase45 /home/debian/homespotify-phase5 /etc/caddy /etc/wireguard"

fail() { printf 'PHASE6_ERROR step=%s detail=%s\n' "$1" "${2:-}" >&2; exit 1; }

guard() {
  local target="$1"
  case "${target}" in
    /|"") fail CHEMIN_INTERDIT "${target}" ;;
    *..*) fail REMONTEE_INTERDITE "${target}" ;;
  esac
  local protected
  for protected in ${PROTECTED}; do
    case "${target}" in
      "${protected}"|"${protected}"/*) fail CHEMIN_PROTEGE "${target}" ;;
    esac
  done
  case "${target}" in
    "${ROOT}"|"${ROOT}"/*|"${STATE}"|"${STATE}"/*|"${ENV_FILE}"|"${UNIT}"|"${OVERRIDE}"|"${OVERRIDE}"/*) return 0 ;;
    *) fail HORS_RACINE_SHADOW "${target}" ;;
  esac
}

remove() { guard "$1"; rm -rf -- "$1"; }

if systemctl list-unit-files "${SERVICE}" --no-legend 2>/dev/null | grep -q "${SERVICE}"; then
  systemctl stop "${SERVICE}" 2>/dev/null || true
  systemctl disable "${SERVICE}" 2>/dev/null || true
fi
remove "${OVERRIDE}"
remove "${UNIT}"
systemctl daemon-reload 2>/dev/null || true

remove "${ROOT}"
remove "${STATE}"
remove "${ENV_FILE}"

LISTENERS="$(ss -ltnH '( sport = :3002 )' 2>/dev/null | wc -l)"
SECRETS="$(find /etc/homespotify -maxdepth 1 -name 'api-shadow.env*' 2>/dev/null | wc -l)"
REMAINING=0
for path in "${ROOT}" "${STATE}" "${ENV_FILE}" "${UNIT}"; do
  [ -e "${path}" ] && REMAINING=$((REMAINING + 1))
done
# Preuve que les arbres des phases precedentes ont survecu.
PRESERVED=0
for path in ${PROTECTED}; do
  [ -e "${path}" ] && PRESERVED=$((PRESERVED + 1))
done

printf '{"status":"clean","remainingShadowPaths":%s,"remainingSecretFiles":%s,"listeners3002":%s,"preservedProtectedPaths":%s}\n' \
  "${REMAINING}" "${SECRETS}" "${LISTENERS}" "${PRESERVED}"
test "${REMAINING}" -eq 0
test "${SECRETS}" -eq 0
test "${LISTENERS}" -eq 0
