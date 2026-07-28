#!/usr/bin/env bash
# Surveillance initiale du shadow. Lecture seule, bornee dans le temps.
#
# CE QUE CE CONTROLE EST, ET CE QU'IL N'EST PAS
# ---------------------------------------------
# C'est un controle COURT : il detecte une fuite grossiere, une boucle de
# redemarrage, un descripteur qui part en vrille. Il ne remplace pas le soak de
# deux heures de la Phase 6.4, et un resultat vert ici ne dit rien de la tenue
# sur la duree — le dire explicitement evite qu'on s'en serve comme d'une
# preuve qu'il n'est pas.
#
# Les valeurs min/max/final sont publiees plutot qu'une moyenne : une moyenne
# lisse exactement le pic qu'on cherche.
#
# Usage : vps_phase6_monitor.sh [duree_s] [intervalle_s]
set -Eeuo pipefail

SERVICE="homespotify-api-shadow.service"
STATE="/var/lib/homespotify-shadow"
PORT=3002
DURATION="${1:-900}"
INTERVAL="${2:-30}"

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' <<<"${1:-}"; }
fail() { printf '{"ok":false,"error":"%s","detail":"%s"}\n' "$1" "$(json_escape "${2:-}")"; exit 1; }

PID="$(systemctl show -p MainPID --value "${SERVICE}")"
[ -n "${PID}" ] && [ "${PID}" != "0" ] || fail SERVICE_ARRETE "MainPID=${PID}"

samples=0
rss_min=""; rss_max=0; rss_final=0
fd_min=""; fd_max=0; fd_final=0
th_min=""; th_max=0; th_final=0
cache_min=""; cache_max=0; cache_final=0
db_final=0; wal_final=0; shm_final=0
cpu_final=0
listeners_bad=0
public_bad=0

deadline=$((SECONDS + DURATION))
while (( SECONDS < deadline )); do
  CURRENT_PID="$(systemctl show -p MainPID --value "${SERVICE}")"
  if [ "${CURRENT_PID}" != "${PID}" ]; then
    fail PID_CHANGE "le service a redemarre pendant la surveillance"
  fi

  RSS="$(awk '/^VmRSS:/ {print $2}' "/proc/${PID}/status" 2>/dev/null || echo 0)"
  FD="$(ls -1 "/proc/${PID}/fd" 2>/dev/null | wc -l)"
  TH="$(awk '/^Threads:/ {print $2}' "/proc/${PID}/status" 2>/dev/null || echo 0)"
  CACHE="$(du -sb "${STATE}/cache/audio" 2>/dev/null | cut -f1 || echo 0)"

  [ -z "${rss_min}" ] && rss_min="${RSS}"
  [ -z "${fd_min}" ] && fd_min="${FD}"
  [ -z "${th_min}" ] && th_min="${TH}"
  [ -z "${cache_min}" ] && cache_min="${CACHE}"
  (( RSS < rss_min )) && rss_min="${RSS}"
  (( RSS > rss_max )) && rss_max="${RSS}"
  (( FD < fd_min )) && fd_min="${FD}"
  (( FD > fd_max )) && fd_max="${FD}"
  (( TH < th_min )) && th_min="${TH}"
  (( TH > th_max )) && th_max="${TH}"
  (( CACHE < cache_min )) && cache_min="${CACHE}"
  (( CACHE > cache_max )) && cache_max="${CACHE}"
  rss_final="${RSS}"; fd_final="${FD}"; th_final="${TH}"; cache_final="${CACHE}"

  # Un listener public apparu en cours de route est aussi grave qu'au
  # demarrage : le controle est refait a chaque echantillon, pas une fois.
  WILD="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -cE "^(0\.0\.0\.0|\*|\[::\]|10\.8\.0\.[0-9]*):${PORT}\$" || true)"
  (( WILD > 0 )) && public_bad=$((public_bad + 1))
  LOOP="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -c "^127.0.0.1:${PORT}\$" || true)"
  (( LOOP != 1 )) && listeners_bad=$((listeners_bad + 1))

  samples=$((samples + 1))
  sleep "${INTERVAL}"
done

CPU_TICKS="$(awk '{print $14 + $15}' "/proc/${PID}/stat" 2>/dev/null || echo 0)"
cpu_final="$(awk -v t="${CPU_TICKS}" -v h="$(getconf CLK_TCK)" 'BEGIN{printf "%.1f", t/h}')"

db_final="$(stat -c '%s' "${STATE}/data/runtime.db" 2>/dev/null || echo 0)"
wal_final="$(stat -c '%s' "${STATE}/data/runtime.db-wal" 2>/dev/null || echo 0)"
shm_final="$(stat -c '%s' "${STATE}/data/runtime.db-shm" 2>/dev/null || echo 0)"

NRESTARTS="$(systemctl show -p NRestarts --value "${SERVICE}")"
ACTIVE="$(systemctl show -p ActiveState --value "${SERVICE}")"
ERRORS="$(journalctl -u "${SERVICE}" -p err --since "-${DURATION}s" -o cat --no-pager 2>/dev/null | grep -c . || true)"
WARNINGS="$(journalctl -u "${SERVICE}" -p warning --since "-${DURATION}s" -o cat --no-pager 2>/dev/null | grep -c . || true)"
CACHE_FILES="$(find "${STATE}/cache/audio" -type f 2>/dev/null | wc -l)"
PUBLIC="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://music.romainbegot.fr/health 2>/dev/null || echo 000)"

printf '{"ok":true,"durationSeconds":%s,"samples":%s,"mainPid":"%s","pidStable":true,"rssKb":{"min":%s,"max":%s,"final":%s},"fileDescriptors":{"min":%s,"max":%s,"final":%s},"threads":{"min":%s,"max":%s,"final":%s},"cacheBytes":{"min":%s,"max":%s,"final":%s},"cacheFiles":%s,"cpuSeconds":%s,"dbBytes":%s,"walBytes":%s,"shmBytes":%s,"nRestarts":"%s","activeState":"%s","journalErrors":%s,"journalWarnings":%s,"loopbackListenerAnomalies":%s,"publicListenerAnomalies":%s,"productionHealth":%s,"soakReplaced":false}\n' \
  "${DURATION}" "${samples}" "${PID}" \
  "${rss_min}" "${rss_max}" "${rss_final}" \
  "${fd_min}" "${fd_max}" "${fd_final}" \
  "${th_min}" "${th_max}" "${th_final}" \
  "${cache_min}" "${cache_max}" "${cache_final}" "${CACHE_FILES}" \
  "${cpu_final}" "${db_final}" "${wal_final}" "${shm_final}" \
  "${NRESTARTS}" "${ACTIVE}" "${ERRORS}" "${WARNINGS}" \
  "${listeners_bad}" "${public_bad}" "${PUBLIC}"
