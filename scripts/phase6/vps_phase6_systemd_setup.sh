#!/usr/bin/env bash
# Installation du service shadow et de son arborescence d'etat. Idempotent.
#
# `--verify-only` s'arrete apres `systemd-analyze verify` : l'unite est
# controlee AVANT d'etre activee, jamais decouverte invalide au demarrage.
#
# Usage : vps_phase6_systemd_setup.sh <unit-source> [--verify-only]
set -Eeuo pipefail

# Pas d'apostrophe dans le message : a l'interieur de ${var:?mot}, bash
# interprete le mot comme du texte a quoter, et une apostrophe isolee y ouvre
# un contexte de citation qui casse tout le script.
UNIT_SOURCE="${1:?chemin du fichier unite requis}"
MODE="${2:-}"
SERVICE="homespotify-api-shadow.service"
UNIT="/etc/systemd/system/${SERVICE}"
ROOT="/opt/homespotify-api-shadow"
STATE="/var/lib/homespotify-shadow"
ENV_FILE="/etc/homespotify/api-shadow.env"
USER_NAME="homespotify"

fail() { printf 'PHASE6_ERROR step=%s detail=%s\n' "$1" "${2:-}" >&2; exit 1; }

test -f "${UNIT_SOURCE}" || fail UNITE_ABSENTE "${UNIT_SOURCE}"

# Controle syntaxique avant toute ecriture dans /etc.
TEMP_UNIT="$(mktemp -d)/${SERVICE}"
cp -- "${UNIT_SOURCE}" "${TEMP_UNIT}"
systemd-analyze verify "${TEMP_UNIT}" 2>&1 | tee /tmp/phase6-unit-verify.log
if grep -qiE 'error|failed|not found' /tmp/phase6-unit-verify.log; then
  fail UNITE_INVALIDE "voir /tmp/phase6-unit-verify.log"
fi
rm -rf -- "$(dirname "${TEMP_UNIT}")"

if [ "${MODE}" = "--verify-only" ]; then
  printf '{"ok":true,"verified":true,"installed":false}\n'
  exit 0
fi

# Compte de service : sans shell, sans home, sans privilege.
if ! id -u "${USER_NAME}" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "${USER_NAME}"
fi

# 0750 et non 0755 : le code du shadow n'a aucune raison d'etre lisible
# par tout compte de la machine. Le service traverse par son groupe.
install -d -o root -g "${USER_NAME}" -m 0750 "${ROOT}" "${ROOT}/releases" \
  "${ROOT}/dependency-bundles" "${ROOT}/tools"
install -d -o "${USER_NAME}" -g "${USER_NAME}" -m 0750 \
  "${STATE}" "${STATE}/data" "${STATE}/cache" "${STATE}/cache/audio" \
  "${STATE}/covers" "${STATE}/imports" "${STATE}/imports/incoming" \
  "${STATE}/offline-variants" "${STATE}/music-unused"
# root:root : systemd lit l'EnvironmentFile en root, AVANT de deposer les
# privileges. Le service n'a donc pas besoin d'entrer dans ce repertoire.
install -d -o root -g root -m 0750 /etc/homespotify

# Le fichier de secrets n'est jamais cree avec un contenu ici : il est injecte
# separement, en 0600. On se contente de refuser un mode trop permissif.
if [ -f "${ENV_FILE}" ]; then
  MODE_ENV="$(stat -c '%a' "${ENV_FILE}")"
  [ "${MODE_ENV}" = "600" ] || fail ENV_MODE_INVALIDE "${MODE_ENV}"
fi

install -o root -g root -m 0644 "${UNIT_SOURCE}" "${UNIT}"
systemctl daemon-reload
# PAS de `systemctl enable` pendant la qualification. Un service active au
# demarrage revient seul apres un redemarrage du VPS : un shadow non
# qualifie se relancerait sans que personne l'ait decide. L'activation au
# boot est une decision de bascule, pas une etape d'installation.
ENABLED="disabled"
if [ "${MODE}" = "--enable" ]; then
  systemctl enable "${SERVICE}" >/dev/null
  ENABLED="enabled"
fi

printf '{"ok":true,"verified":true,"installed":true,"unit":"%s","user":"%s","bootEnabled":"%s"}\n' "${UNIT}" "${USER_NAME}" "${ENABLED}"
