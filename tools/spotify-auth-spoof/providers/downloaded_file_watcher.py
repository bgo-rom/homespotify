"""Surveillance bornée des nouveaux fichiers audio d'une session."""

from __future__ import annotations

import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Iterable

ALLOWED_AUDIO_EXTENSIONS = {
    ".flac",
    ".wav",
    ".mp3",
    ".m4a",
    ".aac",
    ".ogg",
    ".opus",
}
TEMPORARY_EXTENSIONS = {".crdownload", ".part", ".tmp"}
MIN_AUDIO_BYTES = 16 * 1024


@dataclass(frozen=True)
class FileFingerprint:
    size: int
    mtime_ns: int


@dataclass(frozen=True)
class DownloadSnapshot:
    started_at_utc: datetime
    files: dict[Path, FileFingerprint]


def take_snapshot(directory: Path) -> DownloadSnapshot:
    directory.mkdir(parents=True, exist_ok=True)
    files: dict[Path, FileFingerprint] = {}
    for path in directory.iterdir():
        if not path.is_file():
            continue
        stat = path.stat()
        files[path.resolve()] = FileFingerprint(stat.st_size, stat.st_mtime_ns)
    return DownloadSnapshot(datetime.now(timezone.utc), files)


def new_audio_candidates(
    directory: Path,
    snapshot: DownloadSnapshot,
) -> list[Path]:
    started_ns = int(snapshot.started_at_utc.timestamp() * 1_000_000_000)
    found: list[Path] = []
    for path in directory.iterdir():
        if not path.is_file():
            continue
        resolved = path.resolve()
        suffix = path.suffix.casefold()
        if suffix in TEMPORARY_EXTENSIONS or suffix not in ALLOWED_AUDIO_EXTENSIONS:
            continue
        stat = path.stat()
        if stat.st_size < MIN_AUDIO_BYTES or stat.st_mtime_ns < started_ns:
            continue
        before = snapshot.files.get(resolved)
        if before is not None:
            continue
        found.append(resolved)
    return sorted(found, key=lambda item: item.name.casefold())


def is_stable(
    path: Path,
    observations: int = 3,
    interval_seconds: float = 1.0,
    sleeper: Callable[[float], None] = time.sleep,
) -> bool:
    if observations < 2:
        raise ValueError("Deux observations au minimum sont requises.")
    sizes: list[int] = []
    for index in range(observations):
        try:
            stat = path.stat()
        except FileNotFoundError:
            return False
        sizes.append(stat.st_size)
        if index + 1 < observations:
            sleeper(interval_seconds)
    return sizes[0] >= MIN_AUDIO_BYTES and len(set(sizes)) == 1


def stable_candidates(
    paths: Iterable[Path],
    stability_seconds: int,
    sleeper: Callable[[float], None] = time.sleep,
) -> list[Path]:
    observations = 3
    interval = max(0.1, stability_seconds / (observations - 1))
    return [
        path
        for path in paths
        if is_stable(path, observations, interval, sleeper)
    ]
