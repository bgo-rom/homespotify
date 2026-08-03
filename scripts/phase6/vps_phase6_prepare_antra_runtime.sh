#!/usr/bin/env bash
# Prépare le runtime Python Linux immuable d'Antra AVANT toute promotion.
#
# Usage :
#   vps_phase6_prepare_antra_runtime.sh <release-staging-dir> [--install-system-packages]
#
# Sans le drapeau explicite, l'absence de python3-venv, ffmpeg ou ffprobe
# provoque un refus sans modifier la machine.
set -Eeuo pipefail
export PYTHONDONTWRITEBYTECODE=1

RELEASE="${1:?release staging requis}"
MODE="${2:-}"
ROOT="/opt/homespotify-api-shadow"
RUNTIMES="${ROOT}/python-runtimes"
USER_NAME="homespotify"
ALLOWED_RELEASES="/home/debian/homespotify-phase6-staging/releases"

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' \
    <<<"${1:-}"
}
fail() {
  printf '{"ok":false,"error":"%s","detail":"%s"}\n' \
    "$1" "$(json_escape "${2:-}")"
  exit 1
}

[ "$(id -u)" -eq 0 ] || fail ROOT_REQUIS
case "${RELEASE}" in
  "${ALLOWED_RELEASES}"/*.staging) : ;;
  *) fail RELEASE_HORS_STAGING "${RELEASE}" ;;
esac
[ -d "${RELEASE}" ] || fail RELEASE_ABSENTE "${RELEASE}"
[ -f "${RELEASE}/manifest.json" ] || fail MANIFESTE_ABSENT
[ -f "${RELEASE}/antra-runtime/runtime.json" ] || fail DESCRIPTEUR_ABSENT
[ -f "${RELEASE}/antra-runtime/requirements-homespotify-vps.txt" ] \
  || fail REQUIREMENTS_ABSENT
[ -f "${RELEASE}/bin/antra-python" ] || fail LANCEUR_ABSENT
id -u "${USER_NAME}" >/dev/null 2>&1 || fail UTILISATEUR_ABSENT

mapfile -t META < <(
  python3 - \
    "${RELEASE}/manifest.json" \
    "${RELEASE}/antra-runtime/runtime.json" <<'PY'
import json
import re
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
runtime = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))

runtime_id = runtime.get("runtimeId", "")
commit = runtime.get("antraCommit", "")
requirements_hash = runtime.get("requirementsSha256", "")
requirements_file = runtime.get("requirementsFile", "")
python_version = runtime.get("requiredPythonVersion", "")
commands = runtime.get("requiredSystemCommands", [])
file_count = runtime.get("trackedRuntimeFileCount")

if runtime.get("schemaVersion") != 1:
    raise SystemExit("schemaVersion")
if not re.fullmatch(r"py311-antra-[0-9a-f]{8}-[0-9a-f]{8}", runtime_id):
    raise SystemExit("runtimeId")
if not re.fullmatch(r"[0-9a-f]{40}", commit):
    raise SystemExit("antraCommit")
if not re.fullmatch(r"[0-9a-f]{64}", requirements_hash):
    raise SystemExit("requirementsSha256")
if requirements_file != "requirements-homespotify-vps.txt":
    raise SystemExit("requirementsFile")
if python_version != "3.11":
    raise SystemExit("requiredPythonVersion")
if commands != ["ffmpeg", "ffprobe"]:
    raise SystemExit("requiredSystemCommands")
if file_count != 67:
    raise SystemExit("trackedRuntimeFileCount")
if manifest.get("antraRuntimeId") != runtime_id:
    raise SystemExit("manifest runtimeId")
if manifest.get("antraCommit") != commit:
    raise SystemExit("manifest commit")
if manifest.get("antraRequirementsSha256") != requirements_hash:
    raise SystemExit("manifest requirements")

for value in (
    runtime_id,
    commit,
    requirements_hash,
    python_version,
    str(file_count),
):
    print(value)
PY
) || fail DESCRIPTEUR_INVALIDE

[ "${#META[@]}" -eq 5 ] || fail DESCRIPTEUR_INVALIDE
RUNTIME_ID="${META[0]}"
ANTRA_COMMIT="${META[1]}"
REQUIREMENTS_SHA="${META[2]}"
REQUIRED_PYTHON="${META[3]}"
TRACKED_COUNT="${META[4]}"

REQUIREMENTS="${RELEASE}/antra-runtime/requirements-homespotify-vps.txt"
ACTUAL_REQUIREMENTS_SHA="$(sha256sum "${REQUIREMENTS}" | cut -d' ' -f1)"
[ "${ACTUAL_REQUIREMENTS_SHA}" = "${REQUIREMENTS_SHA}" ] \
  || fail REQUIREMENTS_DIVERGENTES

EXPECTED_LAUNCHER="exec \"${RUNTIMES}/${RUNTIME_ID}/venv/bin/python\" \"\$@\""
grep -Fxq "${EXPECTED_LAUNCHER}" "${RELEASE}/bin/antra-python" \
  || fail LANCEUR_DIVERGENT

install_packages=false
case "${MODE}" in
  "") ;;
  --install-system-packages) install_packages=true ;;
  *) fail MODE_INVALIDE "${MODE}" ;;
esac

need_packages=()
python3 -m venv --help >/dev/null 2>&1 || need_packages+=(python3-venv)
command -v ffmpeg >/dev/null 2>&1 || need_packages+=(ffmpeg)
command -v ffprobe >/dev/null 2>&1 || need_packages+=(ffmpeg)

if [ "${#need_packages[@]}" -gt 0 ]; then
  [ "${install_packages}" = true ] \
    || fail PAQUETS_SYSTEME_ABSENTS "$(printf '%s ' "${need_packages[@]}")"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  mapfile -t UNIQUE_PACKAGES < <(
    printf '%s\n' "${need_packages[@]}" | sort -u
  )
  apt-get install -y --no-install-recommends "${UNIQUE_PACKAGES[@]}"
fi

command -v ffmpeg >/dev/null 2>&1 || fail FFMPEG_ABSENT
command -v ffprobe >/dev/null 2>&1 || fail FFPROBE_ABSENT
python3 -m venv --help >/dev/null 2>&1 || fail VENV_ABSENT

PYTHON_VERSION="$(
  python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")'
)"
[ "${PYTHON_VERSION}" = "${REQUIRED_PYTHON}" ] \
  || fail PYTHON_VERSION_INATTENDUE "${PYTHON_VERSION}"

install -d -o root -g "${USER_NAME}" -m 0750 "${RUNTIMES}"
TARGET="${RUNTIMES}/${RUNTIME_ID}"

validate_existing() {
  local target="$1"
  [ -x "${target}/venv/bin/python" ] || return 1
  [ -f "${target}/runtime-meta.json" ] || return 1
  [ -f "${target}/pip-freeze.txt" ] || return 1

  python3 - \
    "${target}/runtime-meta.json" \
    "${RUNTIME_ID}" \
    "${ANTRA_COMMIT}" \
    "${REQUIREMENTS_SHA}" <<'PY'
import json
import sys
from pathlib import Path

meta = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = {
    "schemaVersion": 1,
    "runtimeId": sys.argv[2],
    "antraCommit": sys.argv[3],
    "requirementsSha256": sys.argv[4],
}
for key, value in expected.items():
    if meta.get(key) != value:
        raise SystemExit(key)
PY

  (
    cd "${RELEASE}/antra-runtime"
    sudo -u "${USER_NAME}" env \
      HOME="/var/lib/homespotify-shadow/antra/home" \
      XDG_CACHE_HOME="/var/lib/homespotify-shadow/antra/home/.cache" \
      XDG_DATA_HOME="/var/lib/homespotify-shadow/antra/home/.local/share" \
      SLSKD_AUTO_BOOTSTRAP=false \
      ANTRA_SLSKD_AUTO_BOOTSTRAP=false \
      PYTHONDONTWRITEBYTECODE=1 \
      "${target}/venv/bin/python" - <<'PY'
import importlib
for name in (
    "requests",
    "mutagen",
    "yt_dlp",
    "spotipy",
    "imageio_ffmpeg",
    "pywidevine",
    "websockets",
    "antra.json_cli",
):
    importlib.import_module(name)
PY
  )
}

if [ -d "${TARGET}" ]; then
  validate_existing "${TARGET}" || fail RUNTIME_EXISTANT_INVALIDE "${TARGET}"
  printf '{"ok":true,"runtimeId":"%s","alreadyPresent":true,"python":"%s","requirementsSha256":"%s","antraCommit":"%s","trackedRuntimeFileCount":%s,"ffmpeg":true,"ffprobe":true,"serviceStarted":false,"currentChanged":false}\n' \
    "${RUNTIME_ID}" "${PYTHON_VERSION}" "${REQUIREMENTS_SHA}" \
    "${ANTRA_COMMIT}" "${TRACKED_COUNT}"
  exit 0
fi

INCOMING="${RUNTIMES}/.incoming-${RUNTIME_ID}-$$"
cleanup() {
  rm -rf -- "${INCOMING}"
}
trap cleanup EXIT

[ ! -e "${INCOMING}" ] || fail INCOMING_EXISTANT "${INCOMING}"
python3 -m venv "${INCOMING}/venv"
"${INCOMING}/venv/bin/python" -m pip install \
  --disable-pip-version-check \
  --no-input \
  --no-cache-dir \
  -r "${REQUIREMENTS}"

"${INCOMING}/venv/bin/python" -m pip freeze --all \
  > "${INCOMING}/pip-freeze.txt"
PIP_FREEZE_SHA="$(
  sha256sum "${INCOMING}/pip-freeze.txt" | cut -d' ' -f1
)"

(
  cd "${RELEASE}/antra-runtime"
  env \
    HOME="/var/lib/homespotify-shadow/antra/home" \
    XDG_CACHE_HOME="/var/lib/homespotify-shadow/antra/home/.cache" \
    XDG_DATA_HOME="/var/lib/homespotify-shadow/antra/home/.local/share" \
    SLSKD_AUTO_BOOTSTRAP=false \
    ANTRA_SLSKD_AUTO_BOOTSTRAP=false \
    PYTHONDONTWRITEBYTECODE=1 \
    "${INCOMING}/venv/bin/python" - <<'PY'
import importlib
for name in (
    "requests",
    "mutagen",
    "yt_dlp",
    "spotipy",
    "imageio_ffmpeg",
    "pywidevine",
    "websockets",
    "antra.json_cli",
):
    importlib.import_module(name)
PY
) || fail SMOKE_IMPORT_ECHEC

python3 - \
  "${INCOMING}/runtime-meta.json" \
  "${RUNTIME_ID}" \
  "${ANTRA_COMMIT}" \
  "${REQUIREMENTS_SHA}" \
  "${PYTHON_VERSION}" \
  "${PIP_FREEZE_SHA}" \
  "${TRACKED_COUNT}" <<'PY'
import json
import os
import sys
from pathlib import Path

out = Path(sys.argv[1])
payload = {
    "schemaVersion": 1,
    "runtimeId": sys.argv[2],
    "antraCommit": sys.argv[3],
    "requirementsSha256": sys.argv[4],
    "pythonVersion": sys.argv[5],
    "pipFreezeSha256": sys.argv[6],
    "trackedRuntimeFileCount": int(sys.argv[7]),
}
temporary = out.with_name(out.name + ".tmp")
temporary.write_text(
    json.dumps(payload, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
os.replace(temporary, out)
PY

chown -R root:"${USER_NAME}" "${INCOMING}"
chmod -R u=rwX,g=rX,o= "${INCOMING}"
mv -T "${INCOMING}" "${TARGET}"
trap - EXIT

validate_existing "${TARGET}" || fail RUNTIME_PROMU_INVALIDE "${TARGET}"

printf '{"ok":true,"runtimeId":"%s","alreadyPresent":false,"python":"%s","requirementsSha256":"%s","antraCommit":"%s","trackedRuntimeFileCount":%s,"pipFreezeSha256":"%s","ffmpeg":true,"ffprobe":true,"serviceStarted":false,"currentChanged":false}\n' \
  "${RUNTIME_ID}" "${PYTHON_VERSION}" "${REQUIREMENTS_SHA}" \
  "${ANTRA_COMMIT}" "${TRACKED_COUNT}" "${PIP_FREEZE_SHA}"
