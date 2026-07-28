#!/usr/bin/env python3
"""Tests shadow exécutés SUR le VPS, contre 127.0.0.1:3002.

DISCIPLINE HÉRITÉE DE LA PHASE 5
--------------------------------
Un statut HTTP ne prouve rien. Un HIT n'est un HIT que si un événement
`CACHE_HIT` porte le `requestId` de la requête ; sans journal exploitable, le
verdict est `unknown`, jamais `false`. Ce module réutilise le lecteur de
journaux de la Phase 5, avec journald comme source.

Aucun secret n'est affiché : ni le jeton, ni le contenu de l'`.env`, ni les
chemins de la bibliothèque.

LE JETON ARRIVE PAR FICHIER, JAMAIS PAR ARGUMENT
------------------------------------------------
`--token-file` désigne un fichier `0600`. Un `--token <valeur>` rendrait le
jeton lisible dans `/proc/<pid>/cmdline` par tout compte de la machine, et
l'inscrirait dans l'historique du shell — exactement ce que le contrat des
secrets de la Phase 6.2 interdit.
"""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import secrets
import subprocess
import time
from typing import Any

HOST, PORT = "127.0.0.1", 3002
SERVICE = "homespotify-api-shadow.service"
CACHE_HIT = "CACHE_HIT"
FILL_STARTED = "CACHE_FILL_STARTED"
FILL_COMPLETED = "CACHE_FILL_COMPLETED"
UPSTREAM = "REMOTE_STORAGE_REQUEST_STARTED"

DB_PATH = "/var/lib/homespotify-shadow/data/runtime.db"
BUNDLE = ("/opt/homespotify-api-shadow/dependency-bundles/"
          "linux-x64-node22.18.0-abi127/node_modules")


def request(method: str, path: str, auth: str | None = None,
            range_value: str | None = None, request_id: str | None = None,
            body: dict[str, Any] | None = None) -> dict[str, Any]:
    correlation = request_id or f"phase6-{secrets.token_hex(6)}"
    headers = {"X-Request-Id": correlation}
    if auth:
        headers["Authorization"] = f"Bearer {auth}"
    if range_value:
        headers["Range"] = range_value
    payload = None
    if body is not None:
        payload = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    connection = http.client.HTTPConnection(HOST, PORT, timeout=60)
    started = time.perf_counter()
    connection.request(method, path, body=payload, headers=headers)
    response = connection.getresponse()
    ttfb = (time.perf_counter() - started) * 1000
    digest, size = hashlib.sha256(), 0
    chunks: list[bytes] = []
    while True:
        chunk = response.read(256 * 1024)
        if not chunk:
            break
        digest.update(chunk)
        size += len(chunk)
        if size <= 1024 * 1024:
            chunks.append(chunk)
    content_range = response.getheader("Content-Range")
    content_type = response.getheader("Content-Type")
    connection.close()
    return {
        "status": response.status, "sizeBytes": size, "sha256": digest.hexdigest(),
        "ttfbMs": round(ttfb, 1), "requestId": correlation,
        "contentRange": content_range, "contentType": content_type,
        "body": b"".join(chunks),
    }


def json_body(result: dict[str, Any]) -> Any:
    try:
        return json.loads(result["body"].decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return None


def journal_events(request_id: str, attempts: int = 20, interval_s: float = 0.5) -> list[str]:
    """Événements corrélés, lus dans journald — borné, jamais bloquant."""
    for attempt in range(attempts):
        try:
            raw = subprocess.run(
                ["journalctl", "-u", SERVICE, "-n", "2000", "-o", "cat", "--no-pager"],
                capture_output=True, text=True, timeout=20, check=False,
            ).stdout
        except (OSError, subprocess.TimeoutExpired):
            return []
        names = []
        for line in raw.splitlines():
            start = line.find("{")
            if start < 0:
                continue
            try:
                record = json.loads(line[start:])
            except json.JSONDecodeError:
                continue
            if isinstance(record, dict) and record.get("requestId") == request_id:
                event = record.get("event")
                if isinstance(event, str):
                    names.append(event)
        if names and (CACHE_HIT in names or FILL_COMPLETED in names or UPSTREAM in names):
            return names
        if attempt < attempts - 1:
            time.sleep(interval_s)
    return []


def service_active() -> bool:
    result = subprocess.run(["systemctl", "is-active", SERVICE],
                            capture_output=True, text=True, check=False)
    return result.stdout.strip() == "active"


def listeners_on(port: int) -> int:
    result = subprocess.run(["ss", "-ltnH", f"( sport = :{port} )"],
                            capture_output=True, text=True, check=False)
    return len([line for line in result.stdout.splitlines() if line.strip()])


def sqlite_probe() -> dict[str, Any]:
    """État de la copie jetable, lu par le module natif du bundle."""
    script = (
        'const Database = require(process.env.HS_BUNDLE + "/better-sqlite3");'
        'const db = new Database(process.env.HS_DB, { readonly: true, fileMustExist: true });'
        'const out = {'
        ' integrity: db.pragma("integrity_check", { simple: true }),'
        ' foreignKeyViolations: db.pragma("foreign_key_check").length,'
        ' migrations: db.prepare("SELECT count(*) AS n FROM __drizzle_migrations").get().n,'
        ' tracks: db.prepare("SELECT count(*) AS n FROM tracks").get().n,'
        ' favorites: db.prepare("SELECT count(*) AS n FROM favorites").get().n };'
        'db.close(); console.log(JSON.stringify(out));'
    )
    environment = {**os.environ, "HS_BUNDLE": BUNDLE, "HS_DB": DB_PATH}
    result = subprocess.run(["node", "--input-type=commonjs", "-e", script],
                            capture_output=True, text=True, check=False, env=environment)
    try:
        return json.loads(result.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"error": result.stderr[:200]}


def track_expectations(track_id: int) -> dict[str, Any]:
    """Taille et empreinte attendues, lues dans la copie jetable elle-même.

    Les coder en dur dans le test les rendrait faux le jour où la release
    change ; les lire de la base fait que le test compare le service à sa
    propre source de vérité.
    """
    script = (
        'const Database = require(process.env.HS_BUNDLE + "/better-sqlite3");'
        'const db = new Database(process.env.HS_DB, { readonly: true, fileMustExist: true });'
        'const row = db.prepare("SELECT size_bytes AS sizeBytes, hash FROM tracks WHERE id = ?")'
        '  .get(Number(process.env.HS_TRACK));'
        'db.close(); console.log(JSON.stringify(row || {}));'
    )
    environment = {**os.environ, "HS_BUNDLE": BUNDLE, "HS_DB": DB_PATH,
                   "HS_TRACK": str(track_id)}
    result = subprocess.run(["node", "--input-type=commonjs", "-e", script],
                            capture_output=True, text=True, check=False, env=environment)
    try:
        return json.loads(result.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {}


def read_token(path: str) -> str:
    if not path:
        return ""
    with open(path, encoding="utf-8") as handle:
        return handle.read().strip()


def restart_service() -> bool:
    """Redémarre le SEUL service shadow, puis attend son health."""
    subprocess.run(["systemctl", "restart", SERVICE], check=False,
                   capture_output=True, timeout=90)
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        try:
            probe = request("GET", "/health")
            if probe["status"] == 200:
                return True
        except OSError:
            pass
        time.sleep(1)
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--token-file", default="",
                        help="fichier 0600 contenant le jeton ; jamais affiché")
    parser.add_argument("--track-id", type=int, required=True)
    parser.add_argument("--uncached-track-id", type=int, required=True)
    parser.add_argument("--mode",
                        choices=("health", "read", "cache", "offline", "full"),
                        required=True)
    args = parser.parse_args()
    token = read_token(args.token_file)
    stream = f"/api/tracks/{args.track_id}/stream"
    payload: dict[str, Any] = {"mode": args.mode}
    checks: dict[str, bool] = {}

    if args.mode == "health":
        health = request("GET", "/health")
        payload |= {"healthStatus": health["status"], "serviceActive": service_active(),
                    "listeners3002": listeners_on(PORT), "listeners3001": listeners_on(3001)}
        checks = {
            "healthOk": health["status"] == 200,
            "serviceActive": payload["serviceActive"],
            "listensOnlyOn3002": payload["listeners3002"] == 1,
            "doesNotTouch3001": payload["listeners3001"] == 0,
        }
    elif args.mode == "read":
        tracks = request("GET", "/api/tracks?limit=1", token)
        payload |= {"tracksStatus": tracks["status"]}
        checks = {"libraryReadable": tracks["status"] == 200}
    elif args.mode == "cache":
        miss = request("GET", stream, token)
        miss_events = journal_events(miss["requestId"])
        hit = request("GET", stream, token)
        hit_events = journal_events(hit["requestId"])
        head = request("HEAD", stream, token)
        ranged = request("GET", stream, token, "bytes=0-1023")
        payload |= {
            "missStatus": miss["status"], "missTtfbMs": miss["ttfbMs"],
            "hitStatus": hit["status"], "hitTtfbMs": hit["ttfbMs"],
            "headStatus": head["status"], "rangeStatus": ranged["status"],
            "fillCompleted": FILL_COMPLETED in miss_events,
            "cacheHitObserved": CACHE_HIT in hit_events,
            "upstreamOnHit": UPSTREAM in hit_events,
            "contentMatched": miss["sha256"] == hit["sha256"],
        }
        checks = {
            "missSucceeded": miss["status"] == 200,
            "fillCompleted": payload["fillCompleted"],
            "hitSucceeded": hit["status"] == 200,
            "cacheHitObserved": payload["cacheHitObserved"],
            "upstreamNotContactedOnHit": not payload["upstreamOnHit"],
            "contentMatched": payload["contentMatched"],
            "headEmptyBody": head["status"] == 200 and head["sizeBytes"] == 0,
            "rangeSucceeded": ranged["status"] == 206 and ranged["sizeBytes"] == 1024,
        }
    elif args.mode == "offline":  # Storage Agent arrêté par l'appelant
        hit = request("GET", stream, token)
        hit_events = journal_events(hit["requestId"])
        uncached = request("HEAD", f"/api/tracks/{args.uncached_track_id}/stream", token)
        payload |= {
            "cachedGetStatus": hit["status"], "uncachedStatus": uncached["status"],
            "cacheHitObserved": CACHE_HIT in hit_events,
            "upstreamOnHit": UPSTREAM in hit_events,
        }
        checks = {
            "cachedServedOffline": hit["status"] == 200,
            "cacheHitObserved": payload["cacheHitObserved"],
            "upstreamNotContactedOnHit": not payload["upstreamOnHit"],
            "uncachedReportsUnavailable": uncached["status"] == 503,
            "internal401NotExposed": uncached["status"] != 401,
        }
    else:
        checks, payload = run_full_suite(args, token, stream, payload)

    failed = sorted(name for name, passed in checks.items() if not passed)
    payload |= {"checks": dict(sorted(checks.items())), "failedChecks": failed,
                "ok": not failed, "tokenPrinted": False}
    print(json.dumps(payload))
    return 0 if not failed else 1


def run_full_suite(args, token: str, stream: str,
                   payload: dict[str, Any]) -> tuple[dict[str, bool], dict[str, Any]]:
    """T1 à T11 — la suite d'activation de la Phase 6.3."""
    checks: dict[str, bool] = {}
    results: dict[str, Any] = {}

    # --- T1 : health --------------------------------------------------------
    health = request("GET", "/health")
    results["T1"] = {"healthStatus": health["status"],
                     "listeners3002": listeners_on(PORT),
                     "serviceActive": service_active()}
    checks["T1_health200"] = health["status"] == 200
    checks["T1_singleLoopbackListener"] = results["T1"]["listeners3002"] == 1

    # --- T2 : SQLite après démarrage ---------------------------------------
    sqlite_state = sqlite_probe()
    results["T2"] = sqlite_state
    checks["T2_integrityOk"] = sqlite_state.get("integrity") == "ok"
    checks["T2_noForeignKeyViolation"] = sqlite_state.get("foreignKeyViolations") == 0
    checks["T2_migrationsPresent"] = sqlite_state.get("migrations", 0) >= 18

    # --- T3 : liste des pistes ---------------------------------------------
    listing = request("GET", "/api/tracks?limit=1", token)
    body = json_body(listing) or {}
    total = body.get("total")
    if total is None and isinstance(body.get("pagination"), dict):
        total = body["pagination"].get("total")
    results["T3"] = {"status": listing["status"], "total": total}
    checks["T3_listingAuthorised"] = listing["status"] == 200
    # Cohérence : le total visible ne peut pas dépasser le nombre de pistes de
    # la copie, et doit être non nul — une liste vide passerait un contrôle de
    # statut tout en prouvant que rien n'est lisible.
    checks["T3_totalCoherent"] = (
        isinstance(total, int) and 0 < total <= sqlite_state.get("tracks", 0)
    )

    # --- T4 : pochette ------------------------------------------------------
    cover = request("GET", f"/api/tracks/{args.track_id}/cover", token)
    manifest_match = False
    try:
        with open("/var/lib/homespotify-shadow/covers-manifest.json", encoding="utf-8") as handle:
            declared = {entry["sha256"] for entry in json.load(handle)["files"]}
        manifest_match = cover["sha256"] in declared
    except (OSError, ValueError, KeyError):
        manifest_match = False
    results["T4"] = {"status": cover["status"], "sizeBytes": cover["sizeBytes"],
                     "contentType": cover["contentType"],
                     "sha256Prefix": cover["sha256"][:12],
                     "matchesCoverManifest": manifest_match}
    checks["T4_coverServed"] = cover["status"] == 200 and cover["sizeBytes"] > 0
    checks["T4_coverMatchesManifest"] = manifest_match

    # --- T5 : streaming MISS ------------------------------------------------
    expected = track_expectations(args.track_id)
    miss = request("GET", stream, token)
    miss_events = journal_events(miss["requestId"])
    results["T5"] = {
        "status": miss["status"], "sizeBytes": miss["sizeBytes"],
        "expectedSizeBytes": expected.get("sizeBytes"),
        "sha256Matches": miss["sha256"] == expected.get("hash"),
        "ttfbMs": miss["ttfbMs"],
        "fillStarted": FILL_STARTED in miss_events,
        "fillCompleted": FILL_COMPLETED in miss_events,
        "upstreamContacted": UPSTREAM in miss_events,
    }
    checks["T5_missSucceeded"] = miss["status"] == 200
    checks["T5_sizeExact"] = miss["sizeBytes"] == expected.get("sizeBytes")
    checks["T5_hashExact"] = miss["sha256"] == expected.get("hash")
    checks["T5_upstreamContacted"] = results["T5"]["upstreamContacted"]
    checks["T5_fillStarted"] = results["T5"]["fillStarted"]
    checks["T5_fillCompleted"] = results["T5"]["fillCompleted"]

    # --- T6 : streaming HIT -------------------------------------------------
    hit = request("GET", stream, token)
    hit_events = journal_events(hit["requestId"])
    results["T6"] = {
        "status": hit["status"], "sizeBytes": hit["sizeBytes"],
        "ttfbMs": hit["ttfbMs"],
        "sameContentAsMiss": hit["sha256"] == miss["sha256"],
        "cacheHit": CACHE_HIT in hit_events,
        "upstreamContacted": UPSTREAM in hit_events,
    }
    checks["T6_hitSucceeded"] = hit["status"] == 200
    checks["T6_sizeIdentical"] = hit["sizeBytes"] == miss["sizeBytes"]
    checks["T6_hashIdentical"] = results["T6"]["sameContentAsMiss"]
    checks["T6_cacheHitObserved"] = results["T6"]["cacheHit"]
    checks["T6_upstreamNotContacted"] = not results["T6"]["upstreamContacted"]

    # --- T7 : HEAD sur HIT --------------------------------------------------
    head = request("HEAD", stream, token)
    head_events = journal_events(head["requestId"])
    results["T7"] = {"status": head["status"], "sizeBytes": head["sizeBytes"],
                     "cacheHit": CACHE_HIT in head_events,
                     "upstreamContacted": UPSTREAM in head_events}
    checks["T7_head200"] = head["status"] == 200
    checks["T7_emptyBody"] = head["sizeBytes"] == 0
    checks["T7_cacheHitObserved"] = results["T7"]["cacheHit"]
    checks["T7_upstreamNotContacted"] = not results["T7"]["upstreamContacted"]

    # --- T8 : Range sur HIT -------------------------------------------------
    ranged = request("GET", stream, token, "bytes=0-1023")
    range_events = journal_events(ranged["requestId"])
    expected_range = f"bytes 0-1023/{expected.get('sizeBytes')}"
    results["T8"] = {"status": ranged["status"], "sizeBytes": ranged["sizeBytes"],
                     "contentRange": ranged["contentRange"],
                     "expectedContentRange": expected_range,
                     "cacheHit": CACHE_HIT in range_events,
                     "upstreamContacted": UPSTREAM in range_events}
    checks["T8_partialContent"] = ranged["status"] == 206
    checks["T8_exactBytes"] = ranged["sizeBytes"] == 1024
    checks["T8_contentRangeCorrect"] = ranged["contentRange"] == expected_range
    checks["T8_cacheHitObserved"] = results["T8"]["cacheHit"]
    checks["T8_upstreamNotContacted"] = not results["T8"]["upstreamContacted"]

    # --- T9 : deuxième piste réelle ----------------------------------------
    second = request("HEAD", f"/api/tracks/{args.uncached_track_id}/stream", token)
    second_expected = track_expectations(args.uncached_track_id)
    results["T9"] = {"trackId": args.uncached_track_id, "status": second["status"],
                     "expectedSizeBytes": second_expected.get("sizeBytes"),
                     "hashIsSha256": len(str(second_expected.get("hash", ""))) == 64}
    checks["T9_secondTrackReachable"] = second["status"] == 200
    checks["T9_notSynthetic"] = (
        results["T9"]["hashIsSha256"]
        and (second_expected.get("sizeBytes") or 0) > 1024 * 1024
        and args.uncached_track_id != args.track_id
    )

    # --- T11a : écriture jetable (avant redémarrage) -----------------------
    # Un favori : écriture réelle en base, sans aucun effet extérieur — ni
    # fichier, ni réseau, ni courriel, ni acquisition.
    favorite_created = request("POST", "/api/favorites", token,
                               body={"trackId": args.track_id})
    before = request("GET", "/api/favorites", token)
    before_ids = (json_body(before) or {}).get("trackIds", [])
    results["T11"] = {"postStatus": favorite_created["status"],
                      "presentBeforeRestart": args.track_id in before_ids}
    checks["T11_writeAccepted"] = favorite_created["status"] in (200, 201)
    checks["T11_writeVisible"] = results["T11"]["presentBeforeRestart"]

    # --- T10 : persistance du cache après redémarrage ----------------------
    restarted = restart_service()
    results["T10"] = {"restartSucceeded": restarted}
    if restarted:
        after_restart = request("GET", stream, token)
        after_events = journal_events(after_restart["requestId"])
        results["T10"] |= {
            "status": after_restart["status"],
            "sizeBytes": after_restart["sizeBytes"],
            "hashIdentical": after_restart["sha256"] == miss["sha256"],
            "cacheHit": CACHE_HIT in after_events,
            "upstreamContacted": UPSTREAM in after_events,
            "ttfbMs": after_restart["ttfbMs"],
        }
        checks["T10_servedAfterRestart"] = after_restart["status"] == 200
        checks["T10_cacheHitAfterRestart"] = results["T10"]["cacheHit"]
        checks["T10_upstreamNotContacted"] = not results["T10"]["upstreamContacted"]
        checks["T10_contentIdentical"] = results["T10"]["hashIdentical"]
    else:
        checks["T10_servedAfterRestart"] = False
    checks["T10_restartSucceeded"] = restarted

    # --- T11b : la donnée a survécu au redémarrage -------------------------
    if restarted:
        after = request("GET", "/api/favorites", token)
        after_ids = (json_body(after) or {}).get("trackIds", [])
        results["T11"]["presentAfterRestart"] = args.track_id in after_ids
        checks["T11_persistsAcrossRestart"] = results["T11"]["presentAfterRestart"]
        # L'écriture est annulée : le shadow doit rester dans l'état qu'il
        # avait, pour que le soak de la Phase 6.4 parte d'une base connue.
        removed = request("DELETE", f"/api/favorites/{args.track_id}", token)
        results["T11"]["cleanupStatus"] = removed["status"]
        checks["T11_cleanupSucceeded"] = removed["status"] in (200, 204)
    else:
        checks["T11_persistsAcrossRestart"] = False

    payload |= {"results": results}
    return checks, payload


if __name__ == "__main__":
    raise SystemExit(main())
