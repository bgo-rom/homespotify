#!/usr/bin/env python3
"""Lecture robuste des journaux JSON de l'API Phase 5.

Reprend les enseignements du parseur Phase 4.5
(`phase45_request_id_log_parser.py`) :

- lecture par la fin, sans charger un journal entier en mémoire ;
- journaux COURANTS et ROTATIFS (`api.stdout.log`, `api.stdout.log.1`, `.gz`
  exclus car illisibles sans décompression, signalés séparément) ;
- tolérance d'un préfixe avant le JSON (horodatage WinSW, `nohup`, etc.) :
  on cherche la première accolade plutôt que d'exiger une ligne pure ;
- décodage `utf-8-sig` tolérant, pour ne pas se faire piéger par un BOM ;
- parsing JSON EXACT, jamais une recherche textuelle approximative :
  `"CACHE_HIT" in line` serait vrai pour un champ `reason` qui la mentionne ;
- tentatives BORNÉES par l'appelant.

Aucune donnée sensible ne sort d'ici : `sanitized_events()` ne retourne que
des noms d'événements et des champs explicitement autorisés. Ni secret, ni
`Authorization`, ni nonce, ni signature, ni chemin musical.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Iterator

# Champs sûrs à publier dans un rapport. Tout le reste est écarté par défaut :
# liste blanche, jamais liste noire.
SAFE_FIELDS = (
    "event",
    "requestId",
    "trackId",
    "contentHashPrefix",
    "statusCode",
    "sizeBytes",
    "bytesWritten",
    "reason",
    "errorCode",
    "totalBytes",
    "diskFreeBytes",
    "activeStreams",
    "durationMs",
)

CACHE_EVENT_PREFIXES = ("CACHE_", "REMOTE_STORAGE_", "STORAGE_AGENT_")


def log_files(root: Path, *, current_only: bool = False) -> list[Path]:
    """Journaux à inspecter : courant d'abord, puis rotatifs.

    `current_only` restreint aux journaux du scénario EN COURS. Le harnais
    archive le journal quand il bascule de scénario ; sans cette restriction,
    un compteur comme `evictionsObserved` additionnerait les évictions de tous
    les scénarios précédents et deviendrait ininterprétable.
    """
    runtime = root / "runtime"
    if not runtime.is_dir():
        return []
    found: list[Path] = []
    for name in ("api.stdout.log", "api.stderr.log"):
        candidate = runtime / name
        if candidate.is_file():
            found.append(candidate)
    if current_only:
        return found
    # Rotatifs : api.stdout.log.1, api.stdout.log.2026-07-27, out.log…
    for candidate in sorted(runtime.glob("*.log.*")):
        if candidate.is_file() and candidate.suffix != ".gz":
            found.append(candidate)
    for candidate in sorted(runtime.glob("*.out.log")):
        if candidate.is_file() and candidate not in found:
            found.append(candidate)
    return found


def tail_lines(path: Path, limit: int = 20000) -> list[str]:
    """Dernières lignes d'un fichier, lues par blocs depuis la fin."""
    try:
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
    except OSError:
        return []
    text = b"".join(reversed(chunks)).decode("utf-8-sig", errors="replace")
    return text.splitlines()[-limit:]


def json_records(lines: list[str]) -> Iterator[dict[str, Any]]:
    """Enregistrements JSON, en tolérant un préfixe avant l'accolade."""
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


def all_records(root: Path, limit: int = 20000) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for path in log_files(root):
        records.extend(json_records(tail_lines(path, limit)))
    return records


def count_event(root: Path, event: str, *, current_only: bool = True) -> int:
    """Occurrences EXACTES d'un événement, par défaut sur le scénario courant."""
    total = 0
    for path in log_files(root, current_only=current_only):
        for record in json_records(tail_lines(path)):
            if record.get("event") == event:
                total += 1
    return total


def records_for(root: Path, request_id: str, limit: int = 20000) -> list[dict[str, Any]]:
    """Enregistrements dont le champ `requestId` vaut EXACTEMENT la valeur."""
    return [r for r in all_records(root, limit) if r.get("requestId") == request_id]


def event_names(records: list[dict[str, Any]]) -> list[str]:
    return [r["event"] for r in records if isinstance(r.get("event"), str)]


def sanitized_events(records: list[dict[str, Any]], keep: int = 40) -> list[dict[str, Any]]:
    """Événements réduits aux champs de la liste blanche."""
    output: list[dict[str, Any]] = []
    for record in records[-keep:]:
        entry = {k: record[k] for k in SAFE_FIELDS if k in record}
        if entry:
            output.append(entry)
    return output


def diagnostics(root: Path) -> dict[str, Any]:
    """De quoi savoir POURQUOI aucune corrélation n'a été trouvée.

    Distingue trois situations qu'un `[]` confondrait :
      - aucun fichier de journal / fichier vide ;
      - des lignes, mais aucun événement du cache (câblage du logger) ;
      - des événements, mais aucun ne porte le `requestId` cherché.
    """
    files = log_files(root)
    records = all_records(root)
    cache_events = [
        name
        for name in event_names(records)
        if name.startswith(CACHE_EVENT_PREFIXES)
    ]
    with_request_id = [r for r in records if isinstance(r.get("requestId"), str)]
    return {
        "logFilesInspected": [p.name for p in files],
        "logFileSizes": [p.stat().st_size for p in files if p.is_file()],
        "logRecordsParsed": len(records),
        "cacheEventsTotal": len(cache_events),
        "distinctCacheEvents": sorted(set(cache_events))[:20],
        "recordsCarryingRequestId": len(with_request_id),
        "logEvidenceAvailable": len(cache_events) > 0,
    }
