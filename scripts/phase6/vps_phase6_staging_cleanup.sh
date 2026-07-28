#!/usr/bin/env bash
# Suppression integrale de la racine de staging Phase 6.2. Rien d'autre.
#
# PORTEE
# ------
# Ce script ne connait QU'UN SEUL chemin supprimable, ecrit en dur ci-dessous.
# Il n'accepte aucune cible en argument. C'est la difference entre un outil et
# une arme : `rm -rf "$1"` avec une variable vide efface une machine, et cette
# classe d'incident n'arrive jamais aux gens qui pensaient que ca leur
# arriverait.
#
# La Phase 6.2 n'ecrit que sous cette racine. La supprimer suffit donc a
# revenir a l'etat d'avant : aucun service, aucun utilisateur, aucun fichier
# dans /opt, /var/lib ou /etc, aucun listener.
set -Eeuo pipefail

ROOT="/home/debian/homespotify-phase6-staging"

# Chemins que ce script doit refuser meme si `ROOT` etait altere par erreur.
FORBIDDEN="/ /home /home/debian /opt /var /var/lib /etc /usr /root /boot /srv"
PROTECTED="/home/debian/homespotify-phase45 /home/debian/homespotify-phase5 /etc/caddy /etc/wireguard"

fail() { printf '{"ok":false,"error":"%s","detail":"%s"}\n' "$1" "${2:-}"; exit 1; }

guard() {
  local target="${1:-}"
  [ -n "${target}" ] || fail CIBLE_VIDE ""
  case "${target}" in
    *..*) fail REMONTEE_INTERDITE "${target}" ;;
    /*) : ;;
    *) fail CHEMIN_RELATIF "${target}" ;;
  esac
  local forbidden
  for forbidden in ${FORBIDDEN}; do
    [ "${target}" = "${forbidden}" ] && fail CIBLE_INTERDITE "${target}"
  done
  local protected
  for protected in ${PROTECTED}; do
    case "${target}" in
      "${protected}"|"${protected}"/*) fail CHEMIN_PROTEGE "${target}" ;;
    esac
  done
  # Un lien symbolique sortirait de la racine tout en ayant l'air d'y etre :
  # on supprime le lien, jamais sa cible.
  [ -L "${target}" ] && fail RACINE_EST_UN_LIEN "${target}"
  case "${target}" in
    "${ROOT}"|"${ROOT}"/*) return 0 ;;
    *) fail HORS_RACINE_STAGING "${target}" ;;
  esac
}

guard "${ROOT}"

# Aucun lien symbolique sortant ne doit etre suivi : `find -xdev -type l` les
# recense, ils sont supprimes en tant que liens par le `rm -rf` qui suit, et
# leur nombre est publie pour que le rapport le constate plutot que le supposer.
SYMLINKS=0
if [ -d "${ROOT}" ]; then
  SYMLINKS="$(find "${ROOT}" -xdev -type l 2>/dev/null | wc -l)"
fi

if [ -e "${ROOT}" ]; then
  rm -rf --one-file-system -- "${ROOT}"
fi

REMAINING_FILES=0
[ -e "${ROOT}" ] && REMAINING_FILES="$(find "${ROOT}" -type f 2>/dev/null | wc -l)"
REMAINING_SECRETS=0
[ -e "${ROOT}/secrets" ] && REMAINING_SECRETS="$(find "${ROOT}/secrets" -type f 2>/dev/null | wc -l)"
LISTENERS="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -c ':3002$' || true)"

# Preuve que rien d'autre n'a bouge.
PRESERVED=0
for path in ${PROTECTED}; do
  [ -e "${path}" ] && PRESERVED=$((PRESERVED + 1))
done
BUNDLE_SOURCE_PRESENT=0
[ -d /home/debian/homespotify-phase45/api/node_modules ] && BUNDLE_SOURCE_PRESENT=1
HOME_PRESENT=0
[ -d /home/debian ] && HOME_PRESENT=1
SERVICE_COUNT="$(systemctl list-unit-files 2>/dev/null | grep -c 'homespotify-api-shadow' || true)"

printf '{"ok":true,"root":"%s","rootRemoved":%s,"symlinksFound":%s,"remainingStagingFiles":%s,"remainingSecretFiles":%s,"remainingListeners":%s,"port3002Free":%s,"preservedProtectedPaths":%s,"bundleSourcePresent":%s,"homeDebianPresent":%s,"shadowServiceCount":%s}\n' \
  "${ROOT}" "$([ -e "${ROOT}" ] && echo false || echo true)" "${SYMLINKS}" \
  "${REMAINING_FILES}" "${REMAINING_SECRETS}" "${LISTENERS}" \
  "$([ "${LISTENERS}" -eq 0 ] && echo true || echo false)" \
  "${PRESERVED}" "${BUNDLE_SOURCE_PRESENT}" "${HOME_PRESENT}" "${SERVICE_COUNT}"

test ! -e "${ROOT}"
test "${LISTENERS}" -eq 0
test "${BUNDLE_SOURCE_PRESENT}" -eq 1
test "${HOME_PRESENT}" -eq 1
