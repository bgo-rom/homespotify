#!/usr/bin/env python3
"""Recherche une corrélation Phase 4.5 exacte dans les logs JSON de l'agent."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any, Iterator

SAFE_REQUEST_ID = re.compile(r"^[A-Za-z0-9._:-]{1,96}$")
SUCCESS_EVENTS = {"STORAGE_AGENT_REQUEST_COMPLETED"}
SUCCESS_STATUSES = {200, 206}


def tail_lines(path: Path, limit: int) -> list[str]:
    with path.open("rb") as handle:
        handle.seek(0, 2)
        position = handle.tell()
        chunks: list[bytes] = []
        newlines = 0
        while position > 0 and newlines <= limit:
            size = min(64 * 1024, position)
            position -= size
            handle.seek(position)
            chunk = handle.read(size)
            chunks.append(chunk)
            newlines += chunk.count(b"\n")
    return b"".join(reversed(chunks)).decode("utf-8-sig", errors="replace").splitlines()[-limit:]


def json_records(lines: list[str]) -> Iterator[dict[str, Any]]:
    for line in lines:
        start = line.find("{")
        if start < 0:
            continue
        try:
            value = json.loads(line[start:])
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            yield value


def find_correlation(log_root: Path, request_id: str, tail: int) -> dict[str, Any] | None:
    files = sorted(
        (path for path in log_root.glob("*.log") if path.is_file()),
        key=lambda path: path.stat().st_mtime_ns,
        reverse=True,
    )
    for path in files:
        for record in reversed(list(json_records(tail_lines(path, tail)))):
            if record.get("requestId") != request_id:
                continue
            if record.get("event") not in SUCCESS_EVENTS:
                continue
            if record.get("statusCode") not in SUCCESS_STATUSES:
                continue
            method = record.get("method")
            track_id = record.get("trackId")
            if method not in {"HEAD", "GET"} or not isinstance(track_id, int):
                continue
            return {
                "found": True,
                "file": path.name,
                "event": record["event"],
                "requestId": request_id,
                "method": method,
                "trackId": track_id,
                "statusCode": record["statusCode"],
            }
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log-root", required=True)
    parser.add_argument("--request-id", required=True)
    parser.add_argument("--tail", type=int, default=5000)
    args = parser.parse_args()

    if not SAFE_REQUEST_ID.fullmatch(args.request_id):
        raise SystemExit("REQUEST_ID_INVALID")
    if args.tail < 1 or args.tail > 50_000:
        raise SystemExit("TAIL_INVALID")
    log_root = Path(args.log_root)
    if not log_root.is_dir():
        raise SystemExit("LOG_ROOT_INVALID")

    result = find_correlation(log_root, args.request_id, args.tail)
    print(json.dumps(result or {"found": False}, separators=(",", ":")), flush=True)
    return 0 if result is not None else 1


if __name__ == "__main__":
    raise SystemExit(main())
