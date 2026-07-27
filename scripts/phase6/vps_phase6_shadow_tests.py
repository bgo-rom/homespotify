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
"""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import secrets
import subprocess
import time
from typing import Any

HOST, PORT = "127.0.0.1", 3002
SERVICE = "homespotify-api-shadow.service"
CACHE_HIT = "CACHE_HIT"
FILL_COMPLETED = "CACHE_FILL_COMPLETED"
UPSTREAM = "REMOTE_STORAGE_REQUEST_STARTED"


def request(method: str, path: str, auth: str | None = None,
            range_value: str | None = None, request_id: str | None = None) -> dict[str, Any]:
    correlation = request_id or f"phase6-{secrets.token_hex(6)}"
    headers = {"X-Request-Id": correlation}
    if auth:
        headers["Authorization"] = f"Bearer {auth}"
    if range_value:
        headers["Range"] = range_value
    connection = http.client.HTTPConnection(HOST, PORT, timeout=30)
    started = time.perf_counter()
    connection.request(method, path, headers=headers)
    response = connection.getresponse()
    ttfb = (time.perf_counter() - started) * 1000
    digest, size = hashlib.sha256(), 0
    while True:
        chunk = response.read(256 * 1024)
        if not chunk:
            break
        digest.update(chunk)
        size += len(chunk)
    connection.close()
    return {
        "status": response.status, "sizeBytes": size, "sha256": digest.hexdigest(),
        "ttfbMs": round(ttfb, 1), "requestId": correlation,
    }


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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--token", default="", help="jeton d'accès, jamais journalisé")
    parser.add_argument("--track-id", type=int, required=True)
    parser.add_argument("--uncached-track-id", type=int, required=True)
    parser.add_argument("--mode", choices=("health", "read", "cache", "offline"), required=True)
    args = parser.parse_args()
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
        tracks = request("GET", "/api/tracks?limit=1", args.token)
        payload |= {"tracksStatus": tracks["status"]}
        checks = {"libraryReadable": tracks["status"] == 200}
    elif args.mode == "cache":
        miss = request("GET", stream, args.token)
        miss_events = journal_events(miss["requestId"])
        hit = request("GET", stream, args.token)
        hit_events = journal_events(hit["requestId"])
        head = request("HEAD", stream, args.token)
        ranged = request("GET", stream, args.token, "bytes=0-1023")
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
    else:  # offline : Storage Agent arrêté par l'appelant
        hit = request("GET", stream, args.token)
        hit_events = journal_events(hit["requestId"])
        uncached = request("HEAD", f"/api/tracks/{args.uncached_track_id}/stream", args.token)
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

    failed = sorted(name for name, passed in checks.items() if not passed)
    payload |= {"checks": dict(sorted(checks.items())), "failedChecks": failed, "ok": not failed}
    print(json.dumps(payload))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
