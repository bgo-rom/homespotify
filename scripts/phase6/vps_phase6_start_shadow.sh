#!/usr/bin/env bash
# Phase 6.3 — demarrage CONTROLE du shadow. Aucune tentative repetee aveugle.
#
# POURQUOI UN SCRIPT SEPARE DE L'INSTALLATION
# -------------------------------------------
# Un echec de demarrage doit laisser la machine dans un etat examinable :
# service arrete, port libre, journaux et release conserves. Fusionner
# installation et demarrage produirait un script qui a deja tout fait avant
# qu'on puisse constater l'echec, et dont la seule reaction possible serait de
# reessayer — ce qui ne diagnostique rien.
#
# En cas d'echec, ce script ARRETE le service et rend le port. Il ne reessaie
# pas : une deuxieme tentative identique donne le meme resultat, en effacant
# les journaux utiles sous ceux de la seconde tentative.
set -Eeuo pipefail

SERVICE="homespotify-api-shadow.service"
ROOT="/opt/homespotify-api-shadow"
STATE="/var/lib/homespotify-shadow"
ENV_FILE="/etc/homespotify/api-shadow.env"
USER_NAME="homespotify"
PORT=3002
DEADLINE_S="${1:-60}"

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' <<<"${1:-}"; }
fail() { printf '{"ok":false,"error":"%s","detail":"%s"}\n' "$1" "$(json_escape "${2:-}")"; exit 1; }

listeners() { ss -ltnH 2>/dev/null | awk '{print $4}' | grep -c "$1" || true; }

# --- Preconditions ---------------------------------------------------------
[ "$(listeners ":${PORT}\$")" -eq 0 ] || fail PORT_OCCUPE "${PORT}"
test -L "${ROOT}/current" || fail CURRENT_ABSENT
CURRENT="$(readlink -f "${ROOT}/current")"
test -f "${CURRENT}/dist/server.js" || fail DIST_ABSENT "${CURRENT}"
test -e "${CURRENT}/node_modules/better-sqlite3" || fail NODE_MODULES_ABSENT
test -f "${ENV_FILE}" || fail ENV_ABSENT
test -f "${STATE}/data/runtime.db" || fail DB_ABSENTE
test -f "/etc/systemd/system/${SERVICE}" || fail UNITE_ABSENTE

# Le service doit pouvoir ECRIRE ses repertoires de donnees. Le verifier avant
# le demarrage evite un echec au premier `INSERT`, plus difficile a lire.
for dir in "${STATE}/data" "${STATE}/cache/audio" "${STATE}/covers" \
           "${STATE}/imports/incoming" "${STATE}/offline-variants"; do
  sudo -u "${USER_NAME}" test -w "${dir}" || fail REPERTOIRE_NON_INSCRIPTIBLE "${dir}"
done
sudo -u "${USER_NAME}" test -r "${STATE}/data/runtime.db" || fail DB_NON_LISIBLE
# Le code doit etre LISIBLE par le service, pas seulement present. Sans ce
# controle, systemd echoue en CHDIR et relance en boucle : le message parle de
# repertoire de travail, jamais de permissions de release.
sudo -u "${USER_NAME}" test -x "${CURRENT}" || fail RELEASE_NON_TRAVERSABLE "${CURRENT}"
sudo -u "${USER_NAME}" test -r "${CURRENT}/dist/server.js" || fail DIST_NON_LISIBLE "${CURRENT}"
sudo -u "${USER_NAME}" test -r "${CURRENT}/node_modules/better-sqlite3/package.json"   || fail BUNDLE_NON_LISIBLE "${CURRENT}"
sudo -u "${USER_NAME}" test -w "${STATE}/data/runtime.db" || fail DB_NON_INSCRIPTIBLE

PUBLIC_BEFORE="$(ss -ltnH 2>/dev/null | awk '{print $4}' | sort -u | tr '\n' ' ')"

# --- Demarrage -------------------------------------------------------------
systemctl start "${SERVICE}"

HEALTH=0
deadline=$((SECONDS + DEADLINE_S))
while (( SECONDS < deadline )); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://127.0.0.1:${PORT}/health" 2>/dev/null || echo 000)"
  if [ "${CODE}" = "200" ]; then HEALTH=200; break; fi
  # Un service qui a deja renonce ne guerira pas en attendant la fin du delai.
  STATE_NOW="$(systemctl show -p ActiveState --value "${SERVICE}")"
  [ "${STATE_NOW}" = "failed" ] && break
  sleep 1
done

ACTIVE="$(systemctl show -p ActiveState --value "${SERVICE}")"
SUB="$(systemctl show -p SubState --value "${SERVICE}")"
MAINPID="$(systemctl show -p MainPID --value "${SERVICE}")"
NRESTARTS="$(systemctl show -p NRestarts --value "${SERVICE}")"

if [ "${HEALTH}" != "200" ] || [ "${ACTIVE}" != "active" ] || [ "${SUB}" != "running" ]; then
  LOGS="$(journalctl -u "${SERVICE}" -n 40 -o cat --no-pager 2>/dev/null | tail -c 1200)"
  systemctl stop "${SERVICE}" 2>/dev/null || true
  printf '{"ok":false,"error":"DEMARRAGE_ECHEC","activeState":"%s","subState":"%s","health":%s,"nRestarts":"%s","port%sFree":%s,"serviceStopped":true,"releaseRetained":true,"logs":"%s"}\n' \
    "${ACTIVE}" "${SUB}" "${HEALTH}" "${NRESTARTS}" "${PORT}" \
    "$([ "$(listeners ":${PORT}\$")" -eq 0 ] && echo true || echo false)" \
    "$(json_escape "${LOGS}")"
  exit 1
fi

# --- Controles d'ecoute ----------------------------------------------------
LOOPBACK="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -c "^127.0.0.1:${PORT}\$" || true)"
WILDCARD="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -cE "^(0\.0\.0\.0|\*):${PORT}\$" || true)"
IPV6="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -c "^\[::\]:${PORT}\$" || true)"
WG="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -c "^10\.8\.0\.[0-9]*:${PORT}\$" || true)"
TOTAL="$(listeners ":${PORT}\$")"

# Un listener public sur le port shadow est un NO-GO immediat : le service est
# arrete avant que quiconque puisse l'atteindre.
if [ "${WILDCARD}" -ne 0 ] || [ "${IPV6}" -ne 0 ] || [ "${WG}" -ne 0 ]; then
  systemctl stop "${SERVICE}" 2>/dev/null || true
  fail LISTENER_PUBLIC "wildcard=${WILDCARD} ipv6=${IPV6} wireguard=${WG}"
fi
[ "${LOOPBACK}" -eq 1 ] || { systemctl stop "${SERVICE}" 2>/dev/null || true; fail LISTENER_LOOPBACK_ABSENT "${LOOPBACK}"; }
[ "${TOTAL}" -eq 1 ] || { systemctl stop "${SERVICE}" 2>/dev/null || true; fail LISTENERS_MULTIPLES "${TOTAL}"; }

PUBLIC_AFTER="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -v "127.0.0.1:${PORT}" | sort -u | tr '\n' ' ')"
[ "${PUBLIC_BEFORE}" = "${PUBLIC_AFTER}" ] || fail ECOUTES_PUBLIQUES_MODIFIEES "${PUBLIC_AFTER}"

ERRORS="$(journalctl -u "${SERVICE}" -p err -n 50 -o cat --no-pager 2>/dev/null | grep -c . || true)"
ENABLED="$(systemctl is-enabled "${SERVICE}" 2>/dev/null || echo disabled)"

printf '{"ok":true,"activeState":"%s","subState":"%s","mainPid":"%s","nRestarts":"%s","health":200,"listenersLoopback":%s,"listenersWildcard":0,"listenersIpv6":0,"listenersWireguard":0,"listenersTotal":%s,"journalErrorLines":%s,"bootEnabled":"%s","current":"%s","publicListenersUnchanged":true}\n' \
  "${ACTIVE}" "${SUB}" "${MAINPID}" "${NRESTARTS}" "${LOOPBACK}" "${TOTAL}" \
  "${ERRORS}" "${ENABLED}" "${CURRENT}"
