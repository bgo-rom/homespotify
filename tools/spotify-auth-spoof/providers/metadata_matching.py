"""Normalisation et rapprochement strict des pistes et fichiers."""

from __future__ import annotations

import json
import re
import subprocess
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping

from .base_provider import TrackTarget

DURATION_TOLERANCE_SECONDS = 3
_SPACE_RE = re.compile(r"\s+")
_PUNCT_RE = re.compile(r"[^\w\s]", re.UNICODE)
_HTML_PREFIXES = (b"<!doctype html", b"<html", b"{", b"[")


def normalize_metadata(value: str | None) -> str:
    if not value:
        return ""
    folded = unicodedata.normalize("NFKD", value)
    without_marks = "".join(
        char for char in folded if not unicodedata.combining(char)
    )
    return _SPACE_RE.sub(
        " ",
        _PUNCT_RE.sub(" ", without_marks.casefold()),
    ).strip()


@dataclass(frozen=True)
class VisibleTrackCandidate:
    title: str
    artist: str
    album: str | None = None
    duration_seconds: int | None = None
    year: int | None = None
    locator: Any = None


def candidate_matches(
    target: TrackTarget,
    candidate: VisibleTrackCandidate,
    tolerance_seconds: int = DURATION_TOLERANCE_SECONDS,
) -> bool:
    if normalize_metadata(candidate.title) != normalize_metadata(target.title):
        return False
    if normalize_metadata(candidate.artist) != normalize_metadata(target.artist):
        return False
    if target.album and candidate.album:
        if normalize_metadata(candidate.album) != normalize_metadata(target.album):
            return False
    if (
        target.duration_seconds is not None
        and candidate.duration_seconds is not None
        and abs(target.duration_seconds - candidate.duration_seconds)
        > tolerance_seconds
    ):
        return False
    return True


def exact_candidates(
    target: TrackTarget,
    candidates: Iterable[VisibleTrackCandidate],
) -> list[VisibleTrackCandidate]:
    return [item for item in candidates if candidate_matches(target, item)]


@dataclass(frozen=True)
class FileProbe:
    codec: str
    duration_seconds: float
    title: str | None
    artist: str | None
    album: str | None
    format_name: str


def probe_audio(path: Path, ffprobe_path: str = "ffprobe") -> FileProbe:
    with path.open("rb") as stream:
        prefix = stream.read(64).lstrip().lower()
    if any(prefix.startswith(marker) for marker in _HTML_PREFIXES):
        raise ValueError("Le fichier contient du HTML ou du JSON.")

    completed = subprocess.run(
        [
            ffprobe_path,
            "-v",
            "error",
            "-show_entries",
            "format=format_name,duration:format_tags=title,artist,album",
            "-show_entries",
            "stream=codec_type,codec_name",
            "-of",
            "json",
            str(path),
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=30,
    )
    if completed.returncode != 0:
        raise ValueError("ffprobe ne peut pas lire le fichier audio.")
    try:
        payload: Mapping[str, Any] = json.loads(completed.stdout)
        streams = payload.get("streams", [])
        audio_stream = next(
            stream
            for stream in streams
            if stream.get("codec_type") == "audio"
        )
        format_data = payload.get("format", {})
        tags = {
            str(key).casefold(): str(value)
            for key, value in format_data.get("tags", {}).items()
        }
        duration = float(format_data["duration"])
    except (KeyError, TypeError, ValueError, StopIteration) as exc:
        raise ValueError("Réponse ffprobe audio invalide.") from exc
    if duration <= 0:
        raise ValueError("Durée audio invalide.")
    return FileProbe(
        codec=str(audio_stream.get("codec_name", "")),
        duration_seconds=duration,
        title=tags.get("title"),
        artist=tags.get("artist") or tags.get("album_artist"),
        album=tags.get("album"),
        format_name=str(format_data.get("format_name", "")),
    )


def verify_file_metadata(
    target: TrackTarget,
    probe: FileProbe,
    tolerance_seconds: int = DURATION_TOLERANCE_SECONDS,
) -> tuple[bool, bool, str]:
    if (
        target.duration_seconds is not None
        and abs(probe.duration_seconds - target.duration_seconds)
        > tolerance_seconds
    ):
        return False, False, "MANUAL_FILE_DURATION_MISMATCH"
    title_present = bool(normalize_metadata(probe.title))
    artist_present = bool(normalize_metadata(probe.artist))
    if not title_present or not artist_present:
        return False, True, "MANUAL_FILE_CONFIRMATION_REQUIRED"
    if normalize_metadata(probe.title) != normalize_metadata(target.title):
        return False, False, "MANUAL_FILE_METADATA_MISMATCH"
    if normalize_metadata(probe.artist) != normalize_metadata(target.artist):
        return False, False, "MANUAL_FILE_METADATA_MISMATCH"
    if target.album and probe.album:
        if normalize_metadata(probe.album) != normalize_metadata(target.album):
            return False, False, "MANUAL_FILE_METADATA_MISMATCH"
    return True, False, "OK"
