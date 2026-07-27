#!/usr/bin/env bash
# Promotion ATOMIQUE d'une release shadow. Idempotent.
#
# INVARIANT : `current` ne pointe JAMAIS vers un repertoire incomplet.
# L'assemblage se fait dans un staging, tous les controles passent, PUIS le
# staging est renomme vers releases/<id> et le symlink bascule par un
# `mv -T` — une operation atomique du noyau. A aucun instant un lecteur ne
# peut observer un etat intermediaire.
#
# Usage : vps_phase6_install_release.sh <release-id> [--no-restart]
set -Eeuo pipefail

RELEASE_ID="${1:?release-id requis}"
NO_RESTART="${2:-}"
ROOT="/opt/homespotify-api-shadow"
STATE="/var/lib/homespotify-shadow"
STAGING="${ROOT}/staging"
TARGET="${ROOT}/releases/${RELEASE_ID}"
BUNDLES="${ROOT}/dependency-bundles"
SERVICE="homespotify-api-shadow.service"

fail() { printf 'PHASE6_ERROR step=%s detail=%s\n' "$1" "${2:-}" >&2; exit 1; }

case "${RELEASE_ID}" in
  */*|.|..|"") fail RELEASE_ID_INVALIDE "${RELEASE_ID}" ;;
esac

test -d "${STAGING}" || fail STAGING_ABSENT "${STAGING}"
test -f "${STAGING}/manifest.json" || fail MANIFESTE_ABSENT
test -f "${STAGING}/dist/server.js" || fail DIST_ABSENT

# 1. Manifeste : contenu transfere == contenu construit, a l'octet pres.
python3 "${ROOT}/tools/phase6_manifest_verify.py" "${STAGING}" || fail MANIFESTE_INVALIDE

# 2. Bundle de dependances : reference par le manifeste, immuable.
BUNDLE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["dependencyBundleId"])' "${STAGING}/manifest.json")"
BUNDLE="${BUNDLES}/${BUNDLE_ID}"
test -d "${BUNDLE}" || fail BUNDLE_ABSENT "${BUNDLE_ID}"

# 3 et 4. ABI, modules natifs, smoke better-sqlite3 reel.
bash "${ROOT}/tools/vps_phase6_preflight.sh" "${BUNDLE}" "${STAGING}" >/dev/null || fail PREFLIGHT_ECHEC

# Le bundle est reference par lien symbolique : une seule copie immuable sur
# disque, partagee par les releases. Le rollback vers une release anterieure
# retrouve donc SON bundle, pas celui de la release fautive.
ln -sfn "${BUNDLE}" "${STAGING}/node_modules"

# 5. Copie SQLite : installee seulement si absente. Une base deja en place
# appartient a une execution en cours et ne doit pas etre ecrasee.
if [ -f "${STAGING}/runtime.db.staged" ]; then
  if [ -f "${STATE}/data/runtime.db" ]; then
    printf 'PHASE6_INFO base existante conservee\n' >&2
    rm -f -- "${STAGING}/runtime.db.staged"
  else
    install -m 0640 "${STAGING}/runtime.db.staged" "${STATE}/data/runtime.db"
    rm -f -- "${STAGING}/runtime.db.staged"
  fi
fi

# 6. Permissions : le service lit son code sans pouvoir le reecrire.
chmod -R go-w "${STAGING}"
test -d "${STATE}" || fail ETAT_ABSENT "${STATE}"

# 7. Staging -> releases/<id>, atomique. Si la cible existe deja, la release a
# deja ete promue : on ne refait rien (idempotence).
if [ -d "${TARGET}" ]; then
  printf 'PHASE6_INFO release deja presente\n' >&2
  rm -rf -- "${STAGING}"
else
  mv -T "${STAGING}" "${TARGET}"
fi

# 8. Bascule atomique de `current`, avec memorisation de `previous`.
if [ -L "${ROOT}/current" ]; then
  PREVIOUS="$(readlink -f "${ROOT}/current")"
  if [ "${PREVIOUS}" != "${TARGET}" ]; then
    ln -sfn "${PREVIOUS}" "${ROOT}/previous.new"
    mv -T "${ROOT}/previous.new" "${ROOT}/previous"
  fi
fi
ln -sfn "${TARGET}" "${ROOT}/current.new"
mv -T "${ROOT}/current.new" "${ROOT}/current"

# 9 et 10. Redemarrage puis health. L'appelant declenche le rollback si health
# echoue : ce script ne decide pas seul d'annuler.
if [ "${NO_RESTART}" != "--no-restart" ]; then
  systemctl restart "${SERVICE}"
  deadline=$((SECONDS + 60))
  while (( SECONDS < deadline )); do
    if curl -fsS --max-time 5 "http://127.0.0.1:3002/health" >/dev/null 2>&1; then
      printf '{"ok":true,"releaseId":"%s","current":"%s","health":200}\n' \
        "${RELEASE_ID}" "$(readlink -f "${ROOT}/current")"
      exit 0
    fi
    sleep 1
  done
  fail HEALTH_TIMEOUT "${RELEASE_ID}"
fi
printf '{"ok":true,"releaseId":"%s","current":"%s","restarted":false}\n' \
  "${RELEASE_ID}" "$(readlink -f "${ROOT}/current")"
