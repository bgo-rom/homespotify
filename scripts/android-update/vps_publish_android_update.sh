#!/usr/bin/env bash
# Publication ATOMIQUE d'une mise a jour Android HomeSpotify. Idempotent en
# echec : tant qu'un seul controle n'est pas passe, RIEN n'est publie.
#
# INVARIANT : `latest.json` ne designe jamais une APK absente, partielle ou
# incoherente. L'APK est mise en place et verifiee AVANT que le manifeste ne
# soit publie, et le manifeste bascule par un `mv -T` (operation atomique du
# noyau). Un lecteur ne peut donc pas observer un etat intermediaire.
#
# Usage :
#   vps_publish_android_update.sh <apk-staged> <metadata-staged> [racine]
set -Eeuo pipefail

APK_STAGED="${1:?apk staged requis}"
META_STAGED="${2:?metadata staged requis}"
ROOT="${3:-/var/lib/homespotify-shadow/mobile-updates/android}"

OWNER="homespotify:homespotify"
RELEASES="${ROOT}/releases"
METADATA="${ROOT}/metadata"
LATEST="${ROOT}/latest.json"

fail() { printf 'ANDROID_UPDATE_ERROR step=%s detail=%s\n' "$1" "${2:-}" >&2; exit 1; }

test -f "${APK_STAGED}"  || fail APK_ABSENT "${APK_STAGED}"
test -f "${META_STAGED}" || fail METADATA_ABSENTE "${META_STAGED}"

# 1. Le manifeste doit etre lisible et complet AVANT tout le reste.
read -r VERSION_CODE DECLARED_SIZE DECLARED_SHA <<EOF
$(python3 - "${META_STAGED}" <<'PY'
import json, re, sys

REQUIRED = (
    "platform", "packageName", "versionCode", "versionName", "required",
    "minSupportedVersionCode", "sizeBytes", "sha256", "signingCertSha256",
    "releaseNotes", "publishedAt",
)

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    manifest = json.load(handle)

missing = [field for field in REQUIRED if field not in manifest]
if missing:
    sys.exit("champs manquants: " + ",".join(missing))
if manifest["platform"] != "android":
    sys.exit("platform inattendue")
version_code = manifest["versionCode"]
if not isinstance(version_code, int) or version_code < 1:
    sys.exit("versionCode invalide")
size = manifest["sizeBytes"]
if not isinstance(size, int) or size <= 0:
    sys.exit("sizeBytes invalide")
for field in ("sha256", "signingCertSha256"):
    if not re.fullmatch(r"[0-9a-f]{64}", str(manifest[field])):
        sys.exit(f"{field} invalide")
if manifest["minSupportedVersionCode"] > version_code:
    sys.exit("minSupportedVersionCode > versionCode")

print(version_code, size, manifest["sha256"])
PY
)
EOF
test -n "${VERSION_CODE:-}" || fail METADATA_INVALIDE

# 2. Le fichier transfere est-il EXACTEMENT celui annonce ?
ACTUAL_SIZE="$(stat -c %s "${APK_STAGED}")"
test "${ACTUAL_SIZE}" = "${DECLARED_SIZE}" \
  || fail TAILLE_INCOHERENTE "${ACTUAL_SIZE}!=${DECLARED_SIZE}"
ACTUAL_SHA="$(sha256sum "${APK_STAGED}" | cut -d' ' -f1)"
test "${ACTUAL_SHA}" = "${DECLARED_SHA}" \
  || fail SHA256_INCOHERENT "${ACTUAL_SHA}"

# 3. Une APK commence toujours par la signature ZIP « PK\x03\x04 ».
head -c 4 "${APK_STAGED}" | od -An -tx1 | tr -d ' \n' | grep -qx '504b0304' \
  || fail PAS_UNE_APK

# 4. Aucune regression de versionCode : Android refuserait de toute facon
#    l'installation, autant echouer ici plutot qu'en publiant.
if [ -f "${LATEST}" ]; then
  PUBLISHED="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["versionCode"])' "${LATEST}")"
  if [ "${VERSION_CODE}" -le "${PUBLISHED}" ]; then
    fail VERSION_CODE_NON_CROISSANT "${VERSION_CODE}<=${PUBLISHED}"
  fi
fi

# 5. Une release deja publiee n'est JAMAIS ecrasee : les anciennes APK servent
#    au diagnostic et doivent rester ce qu'elles etaient.
test ! -f "${METADATA}/${VERSION_CODE}.json" \
  || fail RELEASE_DEJA_PUBLIEE "${VERSION_CODE}"

install -d -m 0750 -o homespotify -g homespotify "${ROOT}" "${RELEASES}" "${METADATA}"

TARGET_APK="${RELEASES}/homespotify-${VERSION_CODE}.apk"
TMP_APK="${RELEASES}/.homespotify-${VERSION_CODE}.apk.tmp"
TMP_META="${METADATA}/.${VERSION_CODE}.json.tmp"
TMP_LATEST="${ROOT}/.latest.json.tmp"
trap 'rm -f -- "${TMP_APK}" "${TMP_META}" "${TMP_LATEST}"' EXIT

# 6. APK d'abord : copie hors ligne de mire (nom pointe, non servi), puis
#    bascule atomique vers son nom canonique.
install -m 0640 -o homespotify -g homespotify "${APK_STAGED}" "${TMP_APK}"
python3 - "${TMP_APK}" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
os.fsync(fd)
os.close(fd)
PY
mv -T "${TMP_APK}" "${TARGET_APK}"

# 7. Metadonnees de la version, puis SEULEMENT ENSUITE le manifeste courant.
install -m 0640 -o homespotify -g homespotify "${META_STAGED}" "${TMP_META}"
mv -T "${TMP_META}" "${METADATA}/${VERSION_CODE}.json"

install -m 0640 -o homespotify -g homespotify "${META_STAGED}" "${TMP_LATEST}"
mv -T "${TMP_LATEST}" "${LATEST}"

# 8. Le dossier lui-meme est synchronise : apres un arret brutal, les renommages
#    sont durables.
python3 - "${ROOT}" "${RELEASES}" "${METADATA}" <<'PY'
import os, sys
for path in sys.argv[1:]:
    fd = os.open(path, os.O_RDONLY)
    os.fsync(fd)
    os.close(fd)
PY

trap - EXIT
printf '{"ok":true,"versionCode":%s,"sizeBytes":%s,"sha256":"%s","apk":"%s"}\n' \
  "${VERSION_CODE}" "${DECLARED_SIZE}" "${DECLARED_SHA}" "${TARGET_APK}"
