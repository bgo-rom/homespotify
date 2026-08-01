#!/usr/bin/env python3
"""Validation réelle de RemoteWindowsStorageProvider sur l'API VPS parallèle.

Le script n'affiche jamais les secrets, signatures, chemins musicaux, noms de
fichiers ou contenu audio. Les fichiers sont lus par morceaux et ne sont jamais
accumulés en mémoire ni écrits sur disque.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import http.client
import json
import os
import secrets
import socket
import sqlite3
import subprocess
import sys
import time
import re
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Any

EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()
REQUEST_ID = "phase45-remote-propagation"
SAFE_REQUEST_ID = re.compile(r"^[A-Za-z0-9._:-]{1,96}$")


class Report:
    def __init__(self) -> None:
        self.ok = 0
        self.failed = 0
        self.metrics: dict[str, Any] = {}
        self.skipped: list[str] = []

    def check(self, label: str, condition: bool, detail: str = "") -> None:
        if condition:
            self.ok += 1
            print(f"OK   {label}" + (f" ({detail})" if detail else ""))
        else:
            self.failed += 1
            print(f"FAIL {label}" + (f" ({detail})" if detail else ""))

    def skip(self, label: str, reason: str) -> None:
        self.skipped.append(label)
        print(f"SKIP {label} ({reason})")


def read_env(path: Path) -> dict[str, str]:
    assert_mode_600(path)
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key] = value
    return values


def assert_mode_600(path: Path) -> None:
    if path.stat().st_mode & 0o077:
        raise RuntimeError("fichier sensible trop permissif")


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def access_token(auth_secret: str, principal: dict[str, Any]) -> str:
    now = int(time.time())
    header = b64url(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    payload = b64url(
        json.dumps(
            {
                "sub": str(principal["userId"]),
                "username": principal["username"],
                "role": principal["role"],
                "type": "access",
                "iat": now,
                "exp": now + 1800,
            },
            separators=(",", ":"),
        ).encode()
    )
    signature = b64url(
        hmac.new(auth_secret.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest()
    )
    return f"{header}.{payload}.{signature}"


def signed_agent_headers(secret: str, method: str, path: str) -> dict[str, str]:
    timestamp = str(int(time.time()))
    nonce = secrets.token_urlsafe(32)
    canonical = "\n".join([method.upper(), path, timestamp, nonce, EMPTY_SHA256])
    signature = hmac.new(secret.encode(), canonical.encode(), hashlib.sha256).hexdigest()
    return {
        "X-HS-Timestamp": timestamp,
        "X-HS-Nonce": nonce,
        "X-HS-Content-SHA256": EMPTY_SHA256,
        "X-HS-Signature": signature,
        "X-Request-Id": REQUEST_ID,
    }


def request(
    port: int,
    method: str,
    path: str,
    headers: dict[str, str] | None = None,
    *,
    read_limit: int | None = None,
) -> tuple[int, dict[str, str], bytes, float, float]:
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    started = time.perf_counter()
    connection.request(method, path, headers=headers or {})
    response = connection.getresponse()
    ttfb_ms = (time.perf_counter() - started) * 1000
    body = response.read() if read_limit is None else response.read(read_limit)
    elapsed_ms = (time.perf_counter() - started) * 1000
    response_headers = {key.lower(): value for key, value in response.getheaders()}
    connection.close()
    return response.status, response_headers, body, ttfb_ms, elapsed_ms


def agent_request(
    secret: str,
    method: str,
    path: str,
    extra: dict[str, str] | None = None,
    *,
    corrupt: bool = False,
) -> tuple[int, dict[str, str], bytes]:
    headers = signed_agent_headers(secret, method, path)
    if corrupt:
        signature = headers["X-HS-Signature"]
        headers["X-HS-Signature"] = ("0" if signature[0] != "0" else "1") + signature[1:]
    if extra:
        headers.update(extra)
    connection = http.client.HTTPConnection("10.8.0.2", 3100, timeout=20)
    connection.request(method, path, headers=headers)
    response = connection.getresponse()
    body = response.read(65536)
    response_headers = {key.lower(): value for key, value in response.getheaders()}
    status = response.status
    connection.close()
    return status, response_headers, body


def process_rss_kib(pid: int) -> int:
    for line in Path(f"/proc/{pid}/status").read_text(encoding="utf-8").splitlines():
        if line.startswith("VmRSS:"):
            return int(line.split()[1])
    return 0


def established_agent_connections() -> int:
    completed = subprocess.run(
        ["ss", "-tnH", "state", "established", "dst", "10.8.0.2:3100"],
        check=False,
        capture_output=True,
        text=True,
        timeout=20,
    )
    return len([line for line in completed.stdout.splitlines() if line.strip()])


def agent_active_streams(secret: str) -> int:
    status, _, body = agent_request(secret, "GET", "/internal/storage/health")
    if status != 200:
        return -1
    return int(json.loads(body)["activeStreams"])


def run_offline_check(args: argparse.Namespace) -> int:
    phase = json.loads(Path(args.phase_file).read_text(encoding="utf-8"))
    env = read_env(Path(args.app_env))
    token = access_token(env["AUTH_TOKEN_SECRET"], phase)
    status, headers, body, _, _ = request(
        3001,
        "HEAD",
        f"/api/tracks/{phase['smallTrackId']}/stream",
        {"Authorization": f"Bearer {token}", "X-Request-Id": args.request_id},
    )
    ok = status == 503 and status != 401 and "x-hs-error-code" not in headers and not body
    print(
        json.dumps(
            {
                "offlineMappingStatus": status,
                "internal401Exposed": status == 401,
                "internalHeaderExposed": "x-hs-error-code" in headers,
                "headBodyBytes": len(body),
                "ok": ok,
            }
        )
    )
    return 0 if ok else 1


def run_request_id_check(args: argparse.Namespace) -> int:
    phase = json.loads(Path(args.phase_file).read_text(encoding="utf-8"))
    env = read_env(Path(args.app_env))
    token = access_token(env["AUTH_TOKEN_SECRET"], phase)
    status, headers, body, ttfb_ms, _ = request(
        3001,
        "HEAD",
        f"/api/tracks/{phase['smallTrackId']}/stream",
        {
            "Authorization": f"Bearer {token}",
            "X-Request-Id": args.request_id,
        },
    )
    ok = (
        status == 200
        and not body
        and headers.get("x-request-id") == args.request_id
        and "x-hs-error-code" not in headers
    )
    print(
        json.dumps(
            {
                "requestIdProbe": "completed",
                "status": status,
                "responseRequestIdMatched": headers.get("x-request-id") == args.request_id,
                "internalHeaderExposed": "x-hs-error-code" in headers,
                "headBodyBytes": len(body),
                "ttfbMs": round(ttfb_ms, 1),
                "ok": ok,
            },
            separators=(",", ":"),
        )
    )
    return 0 if ok else 1


def run(args: argparse.Namespace) -> int:
    report = Report()
    phase_path = Path(args.phase_file)
    env_path = Path(args.app_env)
    bad_env_path = Path(args.bad_app_env)
    secret_path = Path(args.secret_file)
    assert_mode_600(phase_path)
    assert_mode_600(secret_path)
    phase = json.loads(phase_path.read_text(encoding="utf-8"))
    env = read_env(env_path)
    read_env(bad_env_path)
    agent_secret = secret_path.read_text(encoding="utf-8").strip()
    if len(agent_secret) < 32:
        raise RuntimeError("secret HMAC invalide")
    token = access_token(env["AUTH_TOKEN_SECRET"], phase)
    auth = {"Authorization": f"Bearer {token}", "X-Request-Id": args.request_id}

    small_id = int(phase["smallTrackId"])
    small_size = int(phase["smallTrackSize"])
    large_id = int(phase["largeTrackId"])
    stale_id = int(phase["staleTrackId"])

    status, _, body, _, _ = request(3001, "GET", "/health")
    report.check("health API parallèle", status == 200, str(status))
    report.check("health sans fuite", b"10.8.0.2" not in body and b"secret" not in body.lower())

    status, _, body, _, _ = request(3001, "GET", "/api/tracks?limit=200", auth)
    listed = json.loads(body) if status == 200 else {}
    report.check("liste authentifiée", status == 200 and bool(listed.get("items")), str(status))

    stream_path = f"/api/tracks/{small_id}/stream"
    status, headers, body, head_ttfb, _ = request(3001, "HEAD", stream_path, auth)
    report.check("HEAD public 200", status == 200, str(status))
    report.check("HEAD corps vide", not body, f"{len(body)} octet")
    report.check("HEAD Content-Length", headers.get("content-length") == str(small_size))
    report.check("HEAD Accept-Ranges", headers.get("accept-ranges") == "bytes")
    report.check("HEAD ETag SQLite", headers.get("etag", "").strip('"') == phase["smallTrackHash"])
    try:
        last_modified_valid = parsedate_to_datetime(headers.get("last-modified", "")) is not None
    except (TypeError, ValueError):
        last_modified_valid = False
    report.check("HEAD Last-Modified valide", last_modified_valid)
    report.check("header interne non exposé", "x-hs-error-code" not in headers)
    report.check("requestId public conservé", headers.get("x-request-id") == args.request_id)

    status, headers, body, range_ttfb, _ = request(
        3001, "GET", stream_path, {**auth, "Range": "bytes=0-1023"}
    )
    report.check("Range 0-1023 en 206", status == 206 and len(body) == 1024)
    report.check(
        "Range 0-1023 cohérent",
        headers.get("content-range") == f"bytes 0-1023/{small_size}",
    )

    start = small_size - 1024
    status, headers, body, _, _ = request(
        3001, "GET", stream_path, {**auth, "Range": f"bytes={start}-"}
    )
    report.check("Range N- en 206", status == 206 and len(body) == 1024)
    report.check("Range N- exact", headers.get("content-range") == f"bytes {start}-{small_size - 1}/{small_size}")

    status, headers, body, _, _ = request(
        3001, "GET", stream_path, {**auth, "Range": "bytes=-1024"}
    )
    report.check("Range suffixe en 206", status == 206 and len(body) == 1024)
    report.check("Range suffixe exact", headers.get("content-range") == f"bytes {start}-{small_size - 1}/{small_size}")

    status, headers, body, _, _ = request(
        3001,
        "GET",
        stream_path,
        {**auth, "Range": f"bytes={small_size + 100}-{small_size + 200}"},
    )
    report.check("Range invalide public 416", status == 416, str(status))
    report.check("416 sans header interne", "x-hs-error-code" not in headers)

    status, _, _, _, _ = request(3001, "HEAD", "/api/tracks/2147483647/stream", auth)
    report.check("piste SQLite absente en 404", status == 404, str(status))

    status, headers, _, _, _ = request(
        3001, "HEAD", f"/api/tracks/{stale_id}/stream", auth
    )
    report.check("index agent périmé en 503", status == 503, str(status))
    report.check("503 index sans header interne", "x-hs-error-code" not in headers)

    status, headers, _, _, _ = request(3002, "HEAD", stream_path, auth)
    report.check("auth HMAC interne en 502", status == 502, str(status))
    report.check("aucun 401 interne public", status != 401)
    report.check("502 sans header interne", "x-hs-error-code" not in headers)

    direct_path = f"/internal/storage/tracks/{small_id}"
    status, headers, body = agent_request(
        agent_secret,
        "HEAD",
        direct_path,
        {"Range": f"bytes={small_size + 100}-"},
    )
    report.check(
        "agent INVALID_RANGE header",
        status == 416 and headers.get("x-hs-error-code") == "INVALID_RANGE" and not body,
    )

    status, headers, body = agent_request(
        agent_secret, "HEAD", f"/internal/storage/tracks/{stale_id}"
    )
    report.check(
        "agent TRACK_NOT_INDEXED header",
        status == 404 and headers.get("x-hs-error-code") == "TRACK_NOT_INDEXED" and not body,
    )

    status, headers, _ = agent_request(
        agent_secret, "GET", "/internal/storage/health", corrupt=True
    )
    report.check(
        "agent AUTH_INVALID header",
        status == 401 and headers.get("x-hs-error-code") == "AUTH_INVALID",
    )

    # Lecture complète progressive : hash en flux, aucun Buffer de piste.
    connection = http.client.HTTPConnection("127.0.0.1", 3001, timeout=120)
    started = time.perf_counter()
    connection.request("GET", stream_path, headers=auth)
    response = connection.getresponse()
    full_ttfb = (time.perf_counter() - started) * 1000
    digest = hashlib.sha256()
    received = 0
    while True:
        chunk = response.read(64 * 1024)
        if not chunk:
            break
        received += len(chunk)
        digest.update(chunk)
    full_duration = time.perf_counter() - started
    connection.close()
    report.check("GET complet 200", response.status == 200)
    report.check("GET complet longueur exacte", received == small_size, str(received))
    report.check("GET complet hash exact", digest.hexdigest() == phase["smallTrackHash"])
    report.metrics.update(
        {
            "headTtfbMs": round(head_ttfb, 1),
            "rangeTtfbMs": round(range_ttfb, 1),
            "fullTtfbMs": round(full_ttfb, 1),
            "fullBytes": received,
            "fullDurationSeconds": round(full_duration, 3),
            "fullMebibytesPerSecond": round(
                received / 1024 / 1024 / max(full_duration, 0.001), 3
            ),
        }
    )

    # Connexion persistante API -> agent.
    for _ in range(5):
        request(3001, "HEAD", stream_path, auth)
    keepalive_connections = established_agent_connections()
    report.metrics["establishedAgentConnections"] = keepalive_connections
    report.check("keep-alive agent actif", 1 <= keepalive_connections <= 8, str(keepalive_connections))

    # Backpressure/abandon : lecture lente bornée à 4 Mio puis fermeture.
    api_pid = int(Path(args.api_pid_file).read_text(encoding="utf-8").strip())
    rss_before = process_rss_kib(api_pid)
    slow = http.client.HTTPConnection("127.0.0.1", 3001, timeout=60)
    slow.request("GET", f"/api/tracks/{large_id}/stream", headers=auth)
    slow_response = slow.getresponse()
    slow_received = 0
    rss_peak = rss_before
    while slow_received < 4 * 1024 * 1024:
        chunk = slow_response.read(64 * 1024)
        if not chunk:
            break
        slow_received += len(chunk)
        rss_peak = max(rss_peak, process_rss_kib(api_pid))
        time.sleep(0.01)
    slow.close()
    deadline = time.time() + 8
    active = agent_active_streams(agent_secret)
    while active != 0 and time.time() < deadline:
        time.sleep(0.2)
        active = agent_active_streams(agent_secret)
    rss_delta = max(0, rss_peak - rss_before)
    report.metrics.update(
        {
            "slowReadBytesBeforeAbort": slow_received,
            "apiRssBeforeKiB": rss_before,
            "apiRssPeakKiB": rss_peak,
            "apiRssDeltaKiB": rss_delta,
            "activeStreamsAfterAbort": active,
        }
    )
    report.check("abandon propagé à l'agent", active == 0, str(active))
    report.check("pas de buffering complet observable", rss_delta < 16 * 1024, f"+{rss_delta} KiB")

    # Saturation réelle : huit réponses ouvertes sans lire leur corps.
    held: list[tuple[http.client.HTTPConnection, http.client.HTTPResponse]] = []
    large_path = f"/internal/storage/tracks/{large_id}"
    try:
        for _ in range(8):
            conn = http.client.HTTPConnection("10.8.0.2", 3100, timeout=30)
            conn.request("GET", large_path, headers=signed_agent_headers(agent_secret, "GET", large_path))
            held.append((conn, conn.getresponse()))
        status, headers, _ = agent_request(agent_secret, "GET", large_path)
        report.check(
            "saturation réelle STREAM_LIMIT_REACHED",
            status == 503 and headers.get("x-hs-error-code") == "STREAM_LIMIT_REACHED",
            str(status),
        )
    finally:
        for conn, _ in held:
            conn.close()
    deadline = time.time() + 10
    active = agent_active_streams(agent_secret)
    while active != 0 and time.time() < deadline:
        time.sleep(0.25)
        active = agent_active_streams(agent_secret)
    report.check("slots libérés après saturation", active == 0, str(active))

    report.skip(
        "FILE_NOT_FOUND réel",
        "aucun fichier musical/index réel n'est volontairement altéré",
    )
    report.skip(
        "INDEX_NOT_LOADED/MUSIC_ROOT_UNAVAILABLE réels",
        "leur induction modifierait l'agent de production ; tests contractuels 147/147",
    )
    report.skip(
        "réponse tronquée réelle",
        "simulation couverte par le faux agent, sans altérer le service réel",
    )

    print(
        json.dumps(
            {
                "checksOk": report.ok,
                "checksFailed": report.failed,
                "skippedSafely": report.skipped,
                "requestId": args.request_id,
                "metrics": report.metrics,
            },
            separators=(",", ":"),
        )
    )
    return 0 if report.failed == 0 else 1


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase-file", required=True)
    parser.add_argument("--app-env", required=True)
    parser.add_argument("--bad-app-env", required=True)
    parser.add_argument("--secret-file", required=True)
    parser.add_argument("--api-pid-file", required=True)
    parser.add_argument("--offline-check", action="store_true")
    parser.add_argument("--request-id-only", action="store_true")
    parser.add_argument("--request-id", default=REQUEST_ID)
    args = parser.parse_args()
    if not SAFE_REQUEST_ID.fullmatch(args.request_id):
        parser.error("requestId invalide")
    if args.offline_check and args.request_id_only:
        parser.error("modes incompatibles")
    if args.offline_check:
        return run_offline_check(args)
    if args.request_id_only:
        return run_request_id_check(args)
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
