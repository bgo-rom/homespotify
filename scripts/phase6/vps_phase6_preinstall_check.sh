#!/usr/bin/env bash
# Phase 6.3 — preconditions distantes et snapshot de securite. Lecture seule.
#
# POURQUOI CE SCRIPT EXISTE SEPAREMENT
# ------------------------------------
# Il vivait au depart dans un here-string PowerShell. Les `$4` d'`awk` et les
# ancres `:3002$` y etaient interpretes par PowerShell AVANT d'atteindre bash :
# `awk '{print }'` sur une entree vide, `grep -c ':3002'` sur rien. Le controle
# du port renvoyait donc TOUJOURS zero — il n'a jamais rien verifie, et il
# aurait laisse une installation ecraser un service en cours d'execution.
#
# Un script distant vit dans un fichier `.sh`, ou son seul interprete est bash.
# C'est la regle que l'orchestrateur s'etait fixee ; ce fichier la respecte.
#
# Usage : vps_phase6_preinstall_check.sh <staging-root> <release-id>
set -Eeuo pipefail
export PYTHONDONTWRITEBYTECODE=1

STAGING="${1:?racine de staging requise}"
RELEASE_ID="${2:?release-id requis}"
REL="${STAGING}/releases/${RELEASE_ID}.staging"
PORT=3002
PUBLIC_URL="https://music.romainbegot.fr"

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' <<<"${1:-}"; }
fail() { printf '{"ok":false,"error":"%s","detail":"%s"}\n' "$1" "$(json_escape "${2:-}")"; exit 1; }

test -d "${STAGING}" || fail STAGING_ABSENT "${STAGING}"
test -f "${REL}/manifest.json" || fail MANIFESTE_ABSENT "${REL}"

# --- Artefact qualifie ------------------------------------------------------
read -r RELEASE_DECLARED COMMIT FILE_COUNT MANIFEST_SHA <<<"$(
  python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(m["releaseId"], m["commit"], m["fileCount"], m["manifestSha256"])
' "${REL}/manifest.json")"
RELEASE_FILES="$(find "${REL}" -type f | wc -l)"
SNAPSHOT_BYTES="$(stat -c '%s' "${STAGING}/data/sqlite/runtime-shadow.db")"
COVER_FILES="$(find "${STAGING}/data/covers" -type f | wc -l)"
BUNDLE_ENTRIES="$(ls -1 "${STAGING}/dependency-bundles/linux-x64-node22.18.0-abi127/node_modules" | wc -l)"
ENV_MODE="$(stat -c '%a' "${STAGING}/secrets/api-shadow.env")"

# --- Etat du systeme --------------------------------------------------------
# `awk '{print $4}'` : le `$4` est ici lu par awk, pas par un shell hote.
LISTENERS="$(ss -ltnH 2>/dev/null | awk '{print $4}' | sort -u | tr '\n' ' ')"
PORT_LISTENERS="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -c ":${PORT}\$" || true)"
PORT_PUBLIC="$(ss -ltnH 2>/dev/null | awk '{print $4}' \
  | grep -cE "^(0\.0\.0\.0|\*|\[::\]|10\.8\.0\.[0-9]+):${PORT}\$" || true)"
UNITS="$(systemctl list-unit-files 2>/dev/null | grep -c 'homespotify' || true)"
USER_STATE="$(getent passwd homespotify >/dev/null 2>&1 && echo present || echo absent)"

OPT_PRESENT=false; [ -e /opt/homespotify-api-shadow ] && OPT_PRESENT=true
STATE_PRESENT=false; [ -e /var/lib/homespotify-shadow ] && STATE_PRESENT=true
ETC_PRESENT=false; [ -e /etc/homespotify ] && ETC_PRESENT=true

INSTALLED_RELEASE=""
if [ -L /opt/homespotify-api-shadow/current ]; then
  INSTALLED_RELEASE="$(basename "$(readlink -f /opt/homespotify-api-shadow/current)")"
fi
# `systemctl is-active` et `is-enabled` ECRIVENT leur reponse sur stdout ET
# sortent en code non nul quand elle n'est pas 'active'/'enabled'. Un
# `|| echo <defaut>` ajoute donc SA valeur a celle deja imprimee :
# « disableddisabled ». On neutralise le code de sortie, puis on comble
# seulement si la sortie est vide.
SERVICE_STATE="$(systemctl is-active homespotify-api-shadow.service 2>/dev/null || true)"
: "${SERVICE_STATE:=inactive}"
SERVICE_ENABLED="$(systemctl is-enabled homespotify-api-shadow.service 2>/dev/null || true)"
: "${SERVICE_ENABLED:=disabled}"

# Objets AUDIO en cache, distingues de l'index du cache : l'index est ecrit par
# le service a son demarrage, il n'a rien d'anormal. Un objet audio, si.
CACHE_OBJECTS=0
if [ -d /var/lib/homespotify-shadow/cache/audio ]; then
  CACHE_OBJECTS="$(find /var/lib/homespotify-shadow/cache/audio -type f \
    -not -path '*/metadata/*' 2>/dev/null | wc -l)"
fi

# --- Environnement public : constate, jamais touche ------------------------
CADDY_ACTIVE="$(systemctl is-active caddy 2>/dev/null || true)"
: "${CADDY_ACTIVE:=unknown}"
CADDY_SHA="$(sha256sum /etc/caddy/Caddyfile 2>/dev/null | cut -d' ' -f1)"
WIREGUARD="$(systemctl is-active wg-quick@wg0 2>/dev/null || true)"
: "${WIREGUARD:=unknown}"
AGENT_REACHABLE=false
timeout 6 bash -c 'exec 3<>/dev/tcp/10.8.0.2/3100' >/dev/null 2>&1 && AGENT_REACHABLE=true
PUBLIC_HEALTH="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${PUBLIC_URL}/health" || echo 000)"
PUBLIC_ROOT="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${PUBLIC_URL}/" || echo 000)"

DISK_AVAIL="$(df -B1 --output=avail / | tail -1 | tr -d ' ')"
NODE_VERSION="$(node -v)"
NODE_ABI="$(node -p 'process.versions.modules')"
NODE_ARCH="$(node -p 'process.arch')"

printf '{"ok":true,"releaseId":"%s","commit":"%s","fileCount":%s,"manifestSha256":"%s","releaseFiles":%s,"snapshotBytes":%s,"coverFiles":%s,"bundleEntries":%s,"envMode":"%s","listeners":"%s","port3002Listeners":%s,"port3002Public":%s,"homespotifyUnits":%s,"userState":"%s","optPresent":%s,"statePresent":%s,"etcPresent":%s,"installedRelease":"%s","serviceState":"%s","serviceEnabled":"%s","cacheAudioObjects":%s,"caddyActive":"%s","caddySha256":"%s","wireguard":"%s","storageAgentReachable":%s,"publicHealth":"%s","publicRoot":"%s","diskAvailBytes":%s,"nodeVersion":"%s","nodeAbi":"%s","nodeArch":"%s"}\n' \
  "${RELEASE_DECLARED}" "${COMMIT}" "${FILE_COUNT}" "${MANIFEST_SHA}" "${RELEASE_FILES}" \
  "${SNAPSHOT_BYTES}" "${COVER_FILES}" "${BUNDLE_ENTRIES}" "${ENV_MODE}" \
  "${LISTENERS}" "${PORT_LISTENERS}" "${PORT_PUBLIC}" \
  "${UNITS}" "${USER_STATE}" "${OPT_PRESENT}" "${STATE_PRESENT}" "${ETC_PRESENT}" \
  "${INSTALLED_RELEASE}" "${SERVICE_STATE}" "${SERVICE_ENABLED}" "${CACHE_OBJECTS}" \
  "${CADDY_ACTIVE}" "${CADDY_SHA}" "${WIREGUARD}" "${AGENT_REACHABLE}" \
  "${PUBLIC_HEALTH}" "${PUBLIC_ROOT}" "${DISK_AVAIL}" \
  "${NODE_VERSION}" "${NODE_ABI}" "${NODE_ARCH}"
