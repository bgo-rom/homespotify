#!/usr/bin/env bash
# Contrôles ABI et modules natifs AVANT toute promotion. Aucun effet de bord.
#
# POURQUOI CES CONTROLES SONT BLOQUANTS
# -------------------------------------
# Le VPS n'a ni gcc, ni make, ni node-gyp (Gate 0, §B.2) : aucun module natif
# n'y est recompilable. Le bundle Linux qualifie donc l'artefact, et un ecart
# de version Node, d'ABI ou d'architecture ne se rattrape pas sur place — il
# se constate a la premiere requete, en production. Ces controles refusent la
# promotion AVANT que `current` ne bouge.
#
# Usage : vps_phase6_preflight.sh <bundle-dir> [release-dir]
set -Eeuo pipefail

BUNDLE="${1:?bundle requis}"
RELEASE="${2:-}"
REQUIRED_NODE="v22.18.0"
REQUIRED_ABI="127"
REQUIRED_ARCH="x64"

fail() { printf '{"ok":false,"error":"%s","detail":"%s"}\n' "$1" "${2:-}" >&2; exit 1; }

test -d "${BUNDLE}" || fail BUNDLE_ABSENT "${BUNDLE}"
# Le contenu vit sous un sous-repertoire nomme exactement `node_modules`.
# Node ne resout les dependances pairs qu'a travers ce nom : depose sous
# `<bundle-id>/` directement, `better_sqlite3.node` se charge en apparence
# puis echoue sur `require("bindings")` — un echec qui ne ressemble pas a sa
# cause. Le nom du repertoire fait partie du contrat, pas de la mise en forme.
MODULES="${BUNDLE}/node_modules"
test -d "${MODULES}" || fail BUNDLE_ABSENT "${MODULES}"
test -d "${MODULES}/better-sqlite3" || fail BUNDLE_INCOMPLET better-sqlite3
NATIVE_SQLITE="${MODULES}/better-sqlite3/build/Release/better_sqlite3.node"
NATIVE_ARGON="${MODULES}/@node-rs/argon2-linux-x64-gnu/argon2.linux-x64-gnu.node"
test -f "${NATIVE_SQLITE}" || fail MODULE_NATIF_ABSENT better_sqlite3.node
test -f "${NATIVE_ARGON}" || fail MODULE_NATIF_ABSENT argon2.linux-x64-gnu.node

NODE_VERSION="$(node -v)"
NODE_ABI="$(node -p 'process.versions.modules')"
NODE_ARCH="$(node -p 'process.arch')"
[ "${NODE_VERSION}" = "${REQUIRED_NODE}" ] || fail NODE_VERSION_INATTENDUE "${NODE_VERSION}"
[ "${NODE_ABI}" = "${REQUIRED_ABI}" ] || fail ABI_INATTENDU "${NODE_ABI}"
[ "${NODE_ARCH}" = "${REQUIRED_ARCH}" ] || fail ARCH_INATTENDUE "${NODE_ARCH}"

SHA_SQLITE="$(sha256sum "${NATIVE_SQLITE}" | cut -d' ' -f1)"
SHA_ARGON="$(sha256sum "${NATIVE_ARGON}" | cut -d' ' -f1)"

# Empreintes attendues, si le bundle en declare : un bundle altere est refuse.
if [ -f "${BUNDLE}/bundle-manifest.json" ]; then
  EXPECTED_SQLITE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("betterSqlite3Sha256",""))' "${BUNDLE}/bundle-manifest.json")"
  EXPECTED_ARGON="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("argon2Sha256",""))' "${BUNDLE}/bundle-manifest.json")"
  [ -z "${EXPECTED_SQLITE}" ] || [ "${EXPECTED_SQLITE}" = "${SHA_SQLITE}" ] || fail HASH_NATIF_DIVERGENT better_sqlite3
  [ -z "${EXPECTED_ARGON}" ] || [ "${EXPECTED_ARGON}" = "${SHA_ARGON}" ] || fail HASH_NATIF_DIVERGENT argon2
fi

# `require` REEL puis CRUD sur une base temporaire supprimee ensuite : la
# presence du fichier .node ne prouve pas qu'il se charge sous cet ABI.
# HS_BUNDLE est exporte AVANT l'appel : le sous-processus node le lit a son
# demarrage, pas apres.
export HS_BUNDLE="${MODULES}"
SMOKE="$(node --input-type=commonjs -e '
const fs = require("fs"), os = require("os"), path = require("path");
const out = { node: process.version, abi: process.versions.modules };
let dir = null;
try {
  const Database = require(process.env.HS_BUNDLE + "/better-sqlite3");
  dir = fs.mkdtempSync(path.join(os.tmpdir(), "hs-phase6-"));
  const db = new Database(path.join(dir, "probe.sqlite"));
  db.pragma("journal_mode = WAL");
  db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)");
  db.prepare("INSERT INTO t (v) VALUES (?)").run("preflight");
  out.selected = db.prepare("SELECT v FROM t WHERE id=1").get().v;
  out.integrity = db.pragma("integrity_check", { simple: true });
  db.close();
  out.ok = out.selected === "preflight" && out.integrity === "ok";
} catch (error) {
  out.ok = false; out.error = String(error && error.message).slice(0, 200);
} finally {
  if (dir) { try { fs.rmSync(dir, { recursive: true, force: true }); } catch {} out.tempRemoved = !fs.existsSync(dir); }
}
console.log(JSON.stringify(out));
' 2>&1)" || fail SMOKE_ECHEC "${SMOKE}"
echo "${SMOKE}" | grep -q '"ok":true' || fail SMOKE_ECHEC "${SMOKE}"

RELEASE_OK="non-verifie"
if [ -n "${RELEASE}" ]; then
  test -f "${RELEASE}/manifest.json" || fail MANIFESTE_ABSENT "${RELEASE}"
  test -f "${RELEASE}/dist/server.js" || fail DIST_ABSENT "${RELEASE}"
  RELEASE_OK="ok"
fi

printf '{"ok":true,"node":"%s","abi":"%s","arch":"%s","betterSqlite3Sha256":"%s","argon2Sha256":"%s","release":"%s","smoke":%s}\n' \
  "${NODE_VERSION}" "${NODE_ABI}" "${NODE_ARCH}" "${SHA_SQLITE}" "${SHA_ARGON}" "${RELEASE_OK}" "${SMOKE}"
