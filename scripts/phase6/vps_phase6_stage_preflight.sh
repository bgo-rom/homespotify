#!/usr/bin/env bash
# Preflight Phase 6.2 : controles DISTANTS depuis le staging, sans service.
#
# CE QUE CE SCRIPT NE FAIT JAMAIS
# -------------------------------
# Il n'execute pas `dist/server.js`, ne cree ni utilisateur ni unite systemd,
# n'ouvre aucun listener, n'ecrit rien hors de la racine de staging et ne
# touche ni Caddy, ni WireGuard, ni le pare-feu. Un preflight qui demarrerait
# l'application pour « verifier qu'elle demarre » ne serait plus un preflight :
# ce serait le deploiement, sans aucun des garde-fous prevus pour lui.
#
# CE QU'IL PROUVE
# ---------------
# Que la release deposee est complete et intacte, que le bundle natif se
# charge REELLEMENT sous cet ABI, que la copie SQLite est lisible et coherente
# sur cette machine, que le fichier de secrets est en 0600, que le port 3002
# est libre et qu'aucun service shadow n'existe encore.
#
# Usage : vps_phase6_stage_preflight.sh <staging-root> <release-dir> [caddy-sha-attendu]
set -Eeuo pipefail

# Aucun `.pyc` ecrit par les outils : sans cela, chaque execution depose un
# `tools/__pycache__` et le staging cesse d'etre EXACTEMENT ce qui a ete
# transfere. Un preflight qui modifie ce qu'il verifie n'est plus un controle.
export PYTHONDONTWRITEBYTECODE=1

STAGING="${1:?racine de staging requise}"
RELEASE="${2:?repertoire de release requis}"
CADDY_EXPECTED="${3:-}"

REQUIRED_NODE="v22.18.0"
REQUIRED_ABI="127"
REQUIRED_ARCH="x64"
BUNDLE_ID="linux-x64-node22.18.0-abi127"
SERVICE="homespotify-api-shadow.service"
ALLOWED_ROOT="/home/debian/homespotify-phase6-staging"
BUNDLE_SOURCE="/home/debian/homespotify-phase45/api/node_modules"

# Le detail est ECHAPPE : il contient souvent la sortie d'un sous-processus,
# donc des guillemets et des retours a la ligne. Injecte tel quel, il produit
# un JSON invalide, et l'appelant echoue sur l'analyse au lieu d'afficher la
# cause reelle — l'erreur devient invisible au moment ou elle compte.
json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' <<<"${1:-}"
}
fail() {
  printf '{"ok":false,"error":"%s","detail":"%s"}\n' "$1" "$(json_escape "${2:-}")"
  exit 1
}

# --- Bornage : ce script ne lit rien hors du staging (hors sources en RO) ---
case "${STAGING}" in
  "${ALLOWED_ROOT}") : ;;
  *) fail STAGING_HORS_RACINE "${STAGING}" ;;
esac
case "${RELEASE}" in
  "${STAGING}"/releases/*) : ;;
  *) fail RELEASE_HORS_STAGING "${RELEASE}" ;;
esac

BUNDLE="${STAGING}/dependency-bundles/${BUNDLE_ID}"
# Node ne resout les dependances pairs qu'a travers des repertoires nommes
# exactement `node_modules`. Un bundle depose sous `<bundle-id>/` directement
# charge son `.node` mais echoue sur `require("bindings")`.
MODULES="${BUNDLE}/node_modules"
SNAPSHOT="${STAGING}/data/sqlite/runtime-shadow.db"
COVERS="${STAGING}/data/covers"
ENVFILE="${STAGING}/secrets/api-shadow.env"
TOOLS="${STAGING}/tools"

test -d "${RELEASE}" || fail RELEASE_ABSENTE "${RELEASE}"
test -d "${MODULES}" || fail BUNDLE_ABSENT "${MODULES}"
test -f "${SNAPSHOT}" || fail SNAPSHOT_ABSENT sqlite
test -d "${COVERS}" || fail COVERS_ABSENTES covers
test -f "${ENVFILE}" || fail ENV_ABSENT secrets

# --- 1. Runtime gele --------------------------------------------------------
NODE_VERSION="$(node -v)"
NODE_ABI="$(node -p 'process.versions.modules')"
NODE_ARCH="$(node -p 'process.arch')"
[ "${NODE_VERSION}" = "${REQUIRED_NODE}" ] || fail NODE_VERSION_INATTENDUE "${NODE_VERSION}"
[ "${NODE_ABI}" = "${REQUIRED_ABI}" ] || fail ABI_INATTENDU "${NODE_ABI}"
[ "${NODE_ARCH}" = "${REQUIRED_ARCH}" ] || fail ARCH_INATTENDUE "${NODE_ARCH}"

# --- 2. Manifeste applicatif ------------------------------------------------
MANIFEST_JSON="$(python3 "${TOOLS}/phase6_manifest_verify.py" "${RELEASE}")" \
  || fail MANIFESTE_DIVERGENT "$(echo "${MANIFEST_JSON}" | head -c 300)"
echo "${MANIFEST_JSON}" | grep -q '"ok": true\|"ok":true' || fail MANIFESTE_DIVERGENT manifest
RELEASE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["releaseId"])' "${RELEASE}/manifest.json")"
FILE_COUNT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fileCount"])' "${RELEASE}/manifest.json")"
COMMIT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "${RELEASE}/manifest.json")"

# Aucune source map ne doit avoir survecu au transfert.
MAP_COUNT="$(find "${RELEASE}" -name '*.map' -type f | wc -l)"
[ "${MAP_COUNT}" -eq 0 ] || fail SOURCE_MAP_PRESENTE "${MAP_COUNT}"
ENV_IN_RELEASE="$(find "${RELEASE}" -name '.env*' -type f | wc -l)"
[ "${ENV_IN_RELEASE}" -eq 0 ] || fail ENV_DANS_RELEASE "${ENV_IN_RELEASE}"

# --- 3. Pochettes -----------------------------------------------------------
COVERS_JSON="$(python3 "${TOOLS}/phase6_covers.py" --root "${COVERS}" \
  --out "${STAGING}/data/covers-manifest.json" --verify)" \
  || fail COVERS_DIVERGENTES "$(echo "${COVERS_JSON}" | head -c 300)"
COVER_COUNT="$(echo "${COVERS_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["coverFileCount"])')"
COVER_BYTES="$(echo "${COVERS_JSON}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["coverBytes"])')"
[ "${COVER_COUNT}" -gt 0 ] || fail COVERS_VIDES 0

# --- 4. Bundle natif : hashes, puis chargement REEL -------------------------
NATIVE_SQLITE="${MODULES}/better-sqlite3/build/Release/better_sqlite3.node"
NATIVE_ARGON="${MODULES}/@node-rs/argon2-linux-x64-gnu/argon2.linux-x64-gnu.node"
test -f "${NATIVE_SQLITE}" || fail MODULE_NATIF_ABSENT better_sqlite3.node
test -f "${NATIVE_ARGON}" || fail MODULE_NATIF_ABSENT argon2.linux-x64-gnu.node
SHA_SQLITE="$(sha256sum "${NATIVE_SQLITE}" | cut -d' ' -f1)"
SHA_ARGON="$(sha256sum "${NATIVE_ARGON}" | cut -d' ' -f1)"

# La source Phase 4.5 doit etre INCHANGEE : le staging en est une copie, pas
# un deplacement. Comparer les empreintes le prouve a chaque execution.
SRC_OK=false
if [ -f "${BUNDLE_SOURCE}/better-sqlite3/build/Release/better_sqlite3.node" ]; then
  SRC_SHA="$(sha256sum "${BUNDLE_SOURCE}/better-sqlite3/build/Release/better_sqlite3.node" | cut -d' ' -f1)"
  [ "${SRC_SHA}" = "${SHA_SQLITE}" ] && SRC_OK=true
fi
[ "${SRC_OK}" = true ] || fail BUNDLE_SOURCE_DIVERGENTE phase45

export HS_BUNDLE="${MODULES}"
export HS_SNAPSHOT="${SNAPSHOT}"
SMOKE="$(node --input-type=commonjs -e '
const fs = require("fs"), os = require("os"), path = require("path");
const out = { node: process.version, abi: process.versions.modules };
let dir = null;
try {
  const Database = require(process.env.HS_BUNDLE + "/better-sqlite3");
  // (a) base temporaire neuve : prouve le CRUD sous cet ABI.
  dir = fs.mkdtempSync(path.join(os.tmpdir(), "hs-phase62-"));
  const probe = new Database(path.join(dir, "probe.sqlite"));
  probe.pragma("journal_mode = WAL");
  probe.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)");
  probe.prepare("INSERT INTO t (v) VALUES (?)").run("stage");
  out.tempSelected = probe.prepare("SELECT v FROM t WHERE id=1").get().v;
  probe.close();
  // (b) snapshot reel, en LECTURE SEULE : la copie transferee doit etre
  // coherente sur CETTE machine, pas seulement sur celle qui la produit.
  const snap = new Database(process.env.HS_SNAPSHOT, { readonly: true, fileMustExist: true });
  out.integrity = snap.pragma("integrity_check", { simple: true });
  out.foreignKeyViolations = snap.pragma("foreign_key_check").length;
  out.migrations = snap.prepare("SELECT count(*) AS n FROM __drizzle_migrations").get().n;
  out.trackCount = snap.prepare("SELECT count(*) AS n FROM tracks").get().n;
  snap.close();
  out.ok = out.tempSelected === "stage" && out.integrity === "ok"
    && out.foreignKeyViolations === 0 && out.migrations > 0;
} catch (error) {
  out.ok = false; out.error = String(error && error.message).slice(0, 200);
} finally {
  if (dir) { try { fs.rmSync(dir, { recursive: true, force: true }); } catch {} out.tempRemoved = !fs.existsSync(dir); }
}
console.log(JSON.stringify(out));
' 2>&1)" || fail SMOKE_ECHEC "$(echo "${SMOKE}" | head -c 300)"
echo "${SMOKE}" | grep -q '"ok":true' || fail SMOKE_ECHEC "$(echo "${SMOKE}" | head -c 300)"

# --- 5. Environnement : conformite sans affichage de valeur -----------------
ENV_MODE="$(stat -c '%a' "${ENVFILE}")"
[ "${ENV_MODE}" = "600" ] || fail ENV_PERMISSIONS "${ENV_MODE}"
ENV_JSON="$(python3 "${TOOLS}/phase6_env.py" --validate "${ENVFILE}")" \
  || fail ENV_NON_CONFORME "$(echo "${ENV_JSON}" | head -c 300)"

# --- 6. Absence de service, de listener, et Caddy inchange -----------------
LISTENERS_3002="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -c ':3002$' || true)"
[ "${LISTENERS_3002}" -eq 0 ] || fail PORT_3002_OCCUPE "${LISTENERS_3002}"
SERVICE_COUNT="$(systemctl list-unit-files 2>/dev/null | grep -c "${SERVICE}" || true)"
[ "${SERVICE_COUNT}" -eq 0 ] || fail SERVICE_SHADOW_PRESENT "${SERVICE_COUNT}"
USER_COUNT="$(getent passwd homespotify >/dev/null 2>&1 && echo 1 || echo 0)"
OPT_PRESENT="$([ -e /opt/homespotify-api-shadow ] && echo 1 || echo 0)"
STATE_PRESENT="$([ -e /var/lib/homespotify-shadow ] && echo 1 || echo 0)"
[ "${OPT_PRESENT}" -eq 0 ] || fail OPT_MODIFIE 1
[ "${STATE_PRESENT}" -eq 0 ] || fail VARLIB_MODIFIE 1

CADDY_SHA="$(sha256sum /etc/caddy/Caddyfile 2>/dev/null | cut -d' ' -f1)"
CADDY_UNCHANGED=true
if [ -n "${CADDY_EXPECTED}" ] && [ "${CADDY_SHA}" != "${CADDY_EXPECTED}" ]; then
  CADDY_UNCHANGED=false
fi
[ "${CADDY_UNCHANGED}" = true ] || fail CADDYFILE_MODIFIE divergent

# --- 7. Permissions du staging ---------------------------------------------
STAGING_OWNER="$(stat -c '%U' "${STAGING}")"
SECRETS_MODE="$(stat -c '%a' "${STAGING}/secrets")"

printf '{"ok":true,"releaseId":"%s","commit":"%s","fileCount":%s,"node":"%s","abi":"%s","arch":"%s","betterSqlite3Sha256":"%s","argon2Sha256":"%s","bundleSourceUnchanged":true,"coverFileCount":%s,"coverBytes":%s,"sourceMapCount":0,"envMode":"%s","stagingOwner":"%s","secretsMode":"%s","port3002Free":true,"serviceAbsent":true,"systemUserPresent":%s,"optUntouched":true,"varLibUntouched":true,"caddySha256":"%s","caddyUnchanged":%s,"serverJsExecuted":false,"smoke":%s,"env":%s}\n' \
  "${RELEASE_ID}" "${COMMIT}" "${FILE_COUNT}" "${NODE_VERSION}" "${NODE_ABI}" "${NODE_ARCH}" \
  "${SHA_SQLITE}" "${SHA_ARGON}" "${COVER_COUNT}" "${COVER_BYTES}" "${ENV_MODE}" \
  "${STAGING_OWNER}" "${SECRETS_MODE}" "${USER_COUNT}" "${CADDY_SHA}" "${CADDY_UNCHANGED}" \
  "${SMOKE}" "${ENV_JSON}"
