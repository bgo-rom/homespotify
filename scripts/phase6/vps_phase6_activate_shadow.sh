#!/usr/bin/env bash
# Phase 6.3 — installation du contenu qualifie en Phase 6.2 dans les
# emplacements shadow definitifs. NE DEMARRE PAS le service.
#
# SEPARATION VOULUE : INSTALLER N'EST PAS DEMARRER
# ------------------------------------------------
# Ce script installe et s'arrete. Le demarrage est une etape distincte, avec
# sa propre attente bornee et sa propre gestion d'echec. Les fusionner
# donnerait un script qui, en cas de probleme, aurait deja tout installe ET
# tout demarre avant qu'on puisse constater quoi que ce soit.
#
# INVARIANT : `current` n'est cree qu'a la toute fin, une fois la release
# complete, verifiee et son bundle relie. Un `current` qui pointerait vers un
# repertoire en cours de copie serait exactement le defaut que la promotion
# atomique existe pour empecher.
#
# Usage : vps_phase6_activate_shadow.sh <staging-root> <release-id>
set -Eeuo pipefail
export PYTHONDONTWRITEBYTECODE=1

STAGING="${1:?racine de staging requise}"
RELEASE_ID="${2:?release-id requis}"

ROOT="/opt/homespotify-api-shadow"
STATE="/var/lib/homespotify-shadow"
ETC="/etc/homespotify"
ENV_FILE="${ETC}/api-shadow.env"
USER_NAME="homespotify"
BUNDLE_ID="linux-x64-node22.18.0-abi127"
ALLOWED_STAGING="/home/debian/homespotify-phase6-staging"

TARGET="${ROOT}/releases/${RELEASE_ID}"
INCOMING="${ROOT}/releases/.incoming-${RELEASE_ID}"
BUNDLE="${ROOT}/dependency-bundles/${BUNDLE_ID}"

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' <<<"${1:-}"; }
fail() { printf '{"ok":false,"error":"%s","detail":"%s"}\n' "$1" "$(json_escape "${2:-}")"; exit 1; }

# --- Bornage ---------------------------------------------------------------
[ "${STAGING}" = "${ALLOWED_STAGING}" ] || fail STAGING_HORS_RACINE "${STAGING}"
case "${RELEASE_ID}" in
  */*|.|..|"") fail RELEASE_ID_INVALIDE "${RELEASE_ID}" ;;
esac
SRC_RELEASE="${STAGING}/releases/${RELEASE_ID}.staging"
test -d "${SRC_RELEASE}" || fail RELEASE_STAGING_ABSENTE "${SRC_RELEASE}"
test -d "${STAGING}/dependency-bundles/${BUNDLE_ID}/node_modules" || fail BUNDLE_STAGING_ABSENT
test -f "${STAGING}/data/sqlite/runtime-shadow.db" || fail SNAPSHOT_ABSENT
test -d "${STAGING}/data/covers" || fail COVERS_ABSENTES
test -f "${STAGING}/secrets/api-shadow.env" || fail ENV_ABSENT
id -u "${USER_NAME}" >/dev/null 2>&1 || fail UTILISATEUR_ABSENT "lancer systemd_setup d'abord"
test -d "${ROOT}" || fail ROOT_ABSENT "lancer systemd_setup d'abord"

# --- 1. Outils dans la racine de service -----------------------------------
install -d -o root -g "${USER_NAME}" -m 0750 "${ROOT}/tools"
# Les outils sont installes sous /opt et non laisses dans le staging : le
# staging est supprime a la fin de la phase, et la Phase 6.4 aura encore
# besoin des tests, de la sonde et de la surveillance.
for tool in phase6_manifest.py phase6_manifest_verify.py phase6_covers.py \
            phase6_env.py phase6_paths.py vps_phase6_preflight.sh \
            phase6_shadow_token.mjs vps_phase6_shadow_tests.py \
            vps_phase6_monitor.sh vps_phase6_start_shadow.sh \
            phase6_probe_agent.mjs; do
  if [ -f "${STAGING}/tools/${tool}" ]; then
    install -o root -g "${USER_NAME}" -m 0640 "${STAGING}/tools/${tool}" "${ROOT}/tools/${tool}"
  fi
done

# --- 2. Bundle immuable ----------------------------------------------------
# Le sous-repertoire s'appelle `node_modules` : c'est un contrat de resolution
# Node, pas une convention de nommage (L-109).
if [ ! -d "${BUNDLE}/node_modules" ]; then
  install -d -o root -g "${USER_NAME}" -m 0750 "${BUNDLE}"
  cp -a "${STAGING}/dependency-bundles/${BUNDLE_ID}/node_modules" "${BUNDLE}/node_modules"
  chown -R root:"${USER_NAME}" "${BUNDLE}"
  # Modes EXPLICITES, jamais un simple retrait de droits. `chmod -R go-w` ne
  # sait qu'enlever : si la source arrive en 0705 — ce que produit un scp
  # depuis Windows — le groupe reste sans aucun droit et le service ne peut
  # meme pas traverser son propre repertoire. `u=rwX,g=rX,o=` POSE le
  # resultat voulu : le service lit son code, ne peut pas le reecrire, et
  # personne d'autre n'y accede.
  chmod -R u=rwX,g=rX,o= "${BUNDLE}"
fi
test -f "${BUNDLE}/node_modules/better-sqlite3/build/Release/better_sqlite3.node" \
  || fail BUNDLE_INCOMPLET better_sqlite3

# --- 3. Release dans un repertoire temporaire, PUIS verification -----------
if [ -d "${TARGET}" ]; then
  # Idempotence : la release est deja promue, on ne recopie rien.
  ALREADY_PROMOTED=true
else
  ALREADY_PROMOTED=false
  rm -rf -- "${INCOMING}"
  install -d -o root -g "${USER_NAME}" -m 0750 "${INCOMING}"
  cp -a "${SRC_RELEASE}/." "${INCOMING}/"
  chown -R root:"${USER_NAME}" "${INCOMING}"
  # Le service lit son code sans pouvoir le reecrire. Modes POSES, pas
  # retires : voir le commentaire du bundle ci-dessus.
  chmod -R u=rwX,g=rX,o= "${INCOMING}"

  # 4. Manifeste : contenu installe == contenu qualifie, a l'octet pres.
  python3 "${ROOT}/tools/phase6_manifest_verify.py" "${INCOMING}" >/dev/null \
    || { rm -rf -- "${INCOMING}"; fail MANIFESTE_DIVERGENT "${INCOMING}"; }

  # 4 bis. Runtime Python Antra : qualifié séparément, puis revérifié ici.
  # Aucun `current` ne bouge avant ces preuves.
  RUNTIME_DESCRIPTOR="${INCOMING}/antra-runtime/runtime.json"
  test -f "${RUNTIME_DESCRIPTOR}" \
    || { rm -rf -- "${INCOMING}"; fail RUNTIME_DESCRIPTOR_ABSENT; }

  mapfile -t RUNTIME_META < <(
    python3 - "${INCOMING}/manifest.json" "${RUNTIME_DESCRIPTOR}" <<'PY'
import json
import re
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
runtime = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
runtime_id = runtime.get("runtimeId", "")
requirements_hash = runtime.get("requirementsSha256", "")
commit = runtime.get("antraCommit", "")

if not re.fullmatch(r"py311-antra-[0-9a-f]{8}-[0-9a-f]{8}", runtime_id):
    raise SystemExit("runtimeId")
if manifest.get("antraRuntimeId") != runtime_id:
    raise SystemExit("manifest runtimeId")
if manifest.get("antraRequirementsSha256") != requirements_hash:
    raise SystemExit("manifest requirements")
if manifest.get("antraCommit") != commit:
    raise SystemExit("manifest commit")
print(runtime_id)
print(requirements_hash)
print(commit)
PY
  ) || { rm -rf -- "${INCOMING}"; fail RUNTIME_DESCRIPTOR_INVALIDE; }

  [ "${#RUNTIME_META[@]}" -eq 3 ] \
    || { rm -rf -- "${INCOMING}"; fail RUNTIME_DESCRIPTOR_INVALIDE; }
  RUNTIME_ID="${RUNTIME_META[0]}"
  RUNTIME_REQUIREMENTS_SHA="${RUNTIME_META[1]}"
  RUNTIME_COMMIT="${RUNTIME_META[2]}"
  RUNTIME_TARGET="${ROOT}/python-runtimes/${RUNTIME_ID}"

  test -x "${RUNTIME_TARGET}/venv/bin/python" \
    || { rm -rf -- "${INCOMING}"; fail RUNTIME_CIBLE_ABSENTE "${RUNTIME_TARGET}"; }
  test -f "${RUNTIME_TARGET}/runtime-meta.json" \
    || { rm -rf -- "${INCOMING}"; fail RUNTIME_META_ABSENT; }
  command -v ffmpeg >/dev/null 2>&1 \
    || { rm -rf -- "${INCOMING}"; fail FFMPEG_ABSENT; }
  command -v ffprobe >/dev/null 2>&1 \
    || { rm -rf -- "${INCOMING}"; fail FFPROBE_ABSENT; }

  python3 - \
    "${RUNTIME_TARGET}/runtime-meta.json" \
    "${RUNTIME_ID}" \
    "${RUNTIME_REQUIREMENTS_SHA}" \
    "${RUNTIME_COMMIT}" <<'PY' \
    || { rm -rf -- "${INCOMING}"; fail RUNTIME_META_DIVERGENT; }
import json
import sys
from pathlib import Path
meta = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = {
    "schemaVersion": 1,
    "runtimeId": sys.argv[2],
    "requirementsSha256": sys.argv[3],
    "antraCommit": sys.argv[4],
}
for key, value in expected.items():
    if meta.get(key) != value:
        raise SystemExit(key)
PY

  chmod 0750 "${INCOMING}/bin/antra-python"
  sudo -u "${USER_NAME}" env \
    HOME="${STATE}/antra/home" \
    XDG_CACHE_HOME="${STATE}/antra/home/.cache" \
    XDG_DATA_HOME="${STATE}/antra/home/.local/share" \
    SLSKD_AUTO_BOOTSTRAP=false \
    ANTRA_SLSKD_AUTO_BOOTSTRAP=false \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONPATH="${INCOMING}/antra-runtime" \
    "${INCOMING}/bin/antra-python" - <<'PY' \
    || { rm -rf -- "${INCOMING}"; fail SMOKE_ANTRA_ECHEC; }
import importlib
for name in ("requests", "yt_dlp", "mutagen", "antra.json_cli"):
    importlib.import_module(name)
PY

  # 5 et 6. ABI, modules natifs, smoke better-sqlite3 reel — depuis la
  # disposition de DESTINATION, seule position ou le resultat vaut quelque
  # chose (L-109).
  bash "${ROOT}/tools/vps_phase6_preflight.sh" "${BUNDLE}" "${INCOMING}" >/dev/null \
    || { rm -rf -- "${INCOMING}"; fail PREFLIGHT_ECHEC "${INCOMING}"; }

  # 7. Renommage atomique. A aucun instant `releases/<id>` n'existe partiel.
  mv -T "${INCOMING}" "${TARGET}"
fi

# 8. Lien du bundle DANS la release. Cible sous /opt : aucun symlink ne sort
# des racines shadow.
ln -sfn "${BUNDLE}/node_modules" "${TARGET}/node_modules"
LINK_TARGET="$(readlink -f "${TARGET}/node_modules")"
case "${LINK_TARGET}" in
  "${ROOT}"/*) : ;;
  *) fail SYMLINK_HORS_RACINE "${LINK_TARGET}" ;;
esac

# --- 9. Donnees jetables ---------------------------------------------------
# La base n'est JAMAIS ecrasee : une base en place appartient a une execution
# en cours, et la remplacer detruirait son etat sans que personne le demande.
DB_INSTALLED=false
if [ ! -f "${STATE}/data/runtime.db" ]; then
  install -o "${USER_NAME}" -g "${USER_NAME}" -m 0640 \
    "${STAGING}/data/sqlite/runtime-shadow.db" "${STATE}/data/runtime.db"
  DB_INSTALLED=true
fi

COVERS_INSTALLED=0
if [ -z "$(ls -A "${STATE}/covers" 2>/dev/null)" ]; then
  cp -a "${STAGING}/data/covers/." "${STATE}/covers/"
  chown -R "${USER_NAME}":"${USER_NAME}" "${STATE}/covers"
  chmod -R u=rwX,g=rX,o= "${STATE}/covers"
fi
COVERS_INSTALLED="$(find "${STATE}/covers" -type f | wc -l)"

# Le manifeste des pochettes accompagne les pochettes : sans lui, un test ne
# peut que constater qu'une image a ete servie, pas qu'elle est LA bonne.
install -o "${USER_NAME}" -g "${USER_NAME}" -m 0640 \
  "${STAGING}/data/covers-manifest.json" "${STATE}/covers-manifest.json"
python3 "${ROOT}/tools/phase6_covers.py" --root "${STATE}/covers" \
  --out "${STATE}/covers-manifest.json" --verify >/dev/null \
  || fail COVERS_DIVERGENTES "apres copie"

# Repertoires jetables : crees VIDES. Aucun import reel, aucune variante
# preexistante, aucun octet de cache.
install -d -o "${USER_NAME}" -g "${USER_NAME}" -m 0750 \
  "${STATE}/imports/incoming" "${STATE}/offline-variants" "${STATE}/cache/audio"

# --- 10. Environnement -----------------------------------------------------
# root:root 0600 : systemd le lit en root avant de deposer les privileges, le
# service lui-meme n'a jamais besoin de l'ouvrir.
install -o root -g root -m 0600 "${STAGING}/secrets/api-shadow.env" "${ENV_FILE}"
ENV_MODE="$(stat -c '%a' "${ENV_FILE}")"
[ "${ENV_MODE}" = "600" ] || fail ENV_MODE_INVALIDE "${ENV_MODE}"
python3 "${ROOT}/tools/phase6_env.py" --validate "${ENV_FILE}" >/dev/null \
  || fail ENV_NON_CONFORME "validation refusee"

# --- 11. `current` — en dernier, jamais avant ------------------------------
ln -sfn "${TARGET}" "${ROOT}/current.new"
mv -T "${ROOT}/current.new" "${ROOT}/current"
CURRENT="$(readlink -f "${ROOT}/current")"
[ "${CURRENT}" = "${TARGET}" ] || fail CURRENT_INCOHERENT "${CURRENT}"
test -f "${CURRENT}/dist/server.js" || fail DIST_ABSENT "${CURRENT}"

# Verifier en root prouverait que root peut lire, ce dont personne ne doutait.
# Le seul controle qui vaut est fait SOUS L'IDENTITE DU SERVICE : c'est elle
# qui echoue, en CHDIR, cinq secondes apres le demarrage.
sudo -u "${USER_NAME}" test -x "${CURRENT}" || fail RELEASE_NON_TRAVERSABLE "${CURRENT}"
sudo -u "${USER_NAME}" test -r "${CURRENT}/dist/server.js" || fail DIST_NON_LISIBLE "${CURRENT}"
sudo -u "${USER_NAME}" test -r "${CURRENT}/node_modules/better-sqlite3/package.json"   || fail BUNDLE_NON_LISIBLE "${CURRENT}/node_modules"

# --- Verifications de sortie ----------------------------------------------
DB_SHA="$(sha256sum "${STATE}/data/runtime.db" | cut -d' ' -f1)"
DB_SIZE="$(stat -c '%s' "${STATE}/data/runtime.db")"
STAGED_SHA="$(sha256sum "${STAGING}/data/sqlite/runtime-shadow.db" | cut -d' ' -f1)"
SQLITE_JSON="$(HS_BUNDLE="${BUNDLE}/node_modules" HS_DB="${STATE}/data/runtime.db" \
  node --input-type=commonjs -e '
const Database = require(process.env.HS_BUNDLE + "/better-sqlite3");
const db = new Database(process.env.HS_DB, { readonly: true, fileMustExist: true });
const out = {
  integrity: db.pragma("integrity_check", { simple: true }),
  foreignKeyViolations: db.pragma("foreign_key_check").length,
  migrations: db.prepare("SELECT count(*) AS n FROM __drizzle_migrations").get().n,
  tracks: db.prepare("SELECT count(*) AS n FROM tracks").get().n,
};
db.close();
console.log(JSON.stringify(out));
')" || fail SQLITE_ILLISIBLE "apres installation"

# Objets AUDIO seulement. L'index du cache (`metadata/cache-index.sqlite`) est
# ecrit par le service a son demarrage : sa presence est normale sur une
# reinstallation, et l'interdire ferait echouer toute reprise. Un objet audio
# preexistant, lui, signalerait une donnee smugglee.
CACHE_FILES="$(find "${STATE}/cache/audio" -type f -not -path '*/metadata/*' 2>/dev/null | wc -l)"
INCOMING_FILES="$(find "${STATE}/imports/incoming" -type f 2>/dev/null | wc -l)"
VARIANT_FILES="$(find "${STATE}/offline-variants" -type f 2>/dev/null | wc -l)"
[ "${CACHE_FILES}" -eq 0 ] || fail CACHE_NON_VIDE "${CACHE_FILES}"
[ "${INCOMING_FILES}" -eq 0 ] || fail INCOMING_NON_VIDE "${INCOMING_FILES}"
[ "${VARIANT_FILES}" -eq 0 ] || fail VARIANTES_NON_VIDES "${VARIANT_FILES}"
# La comparaison d'empreinte n'a de sens QUE si l'on vient d'installer la base.
# Sur une reprise, le service tourne et a deja ecrit dedans (WAL, sessions) :
# exiger l'egalite ferait echouer toute reinstallation sur une propriete qui
# n'a jamais ete promise. Ce qui reste vrai dans les deux cas, c'est la
# coherence — verifiee juste au-dessus par `integrity_check`.
if [ "${DB_INSTALLED}" = true ]; then
  [ "${DB_SHA}" = "${STAGED_SHA}" ] || fail SQLITE_DIVERGENTE "apres copie"
fi

printf '{"ok":true,"releaseId":"%s","current":"%s","alreadyPromoted":%s,"bundleLinked":"%s","dbInstalled":%s,"dbSizeBytes":%s,"dbSha256":"%s","coverFileCount":%s,"cacheFiles":0,"incomingFiles":0,"variantFiles":0,"envMode":"%s","sqlite":%s,"serviceStarted":false,"bootEnabled":false}\n' \
  "${RELEASE_ID}" "${CURRENT}" "${ALREADY_PROMOTED}" "${LINK_TARGET}" \
  "${DB_INSTALLED}" "${DB_SIZE}" "${DB_SHA}" "${COVERS_INSTALLED}" \
  "${ENV_MODE}" "${SQLITE_JSON}"
