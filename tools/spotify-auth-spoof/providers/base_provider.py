"""Contrat commun des fournisseurs d'acquisition."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Mapping, Protocol

EventCallback = Callable[[dict[str, Any]], None]


class AcquisitionStatus(str, Enum):
    SUCCESS = "SUCCESS"
    MANUAL_ACTION_REQUIRED = "MANUAL_ACTION_REQUIRED"
    MANUAL_FILE_CONFIRMATION_REQUIRED = "MANUAL_FILE_CONFIRMATION_REQUIRED"
    NOT_FOUND = "NOT_FOUND"
    PROVIDER_CHALLENGE = "PROVIDER_CHALLENGE"
    PROVIDER_RATE_LIMITED = "PROVIDER_RATE_LIMITED"
    PROVIDER_UNAVAILABLE = "PROVIDER_UNAVAILABLE"
    PROVIDER_INVALID_RESPONSE = "PROVIDER_INVALID_RESPONSE"
    PROVIDER_ERROR = "PROVIDER_ERROR"
    CANCELLED = "CANCELLED"


@dataclass(frozen=True)
class TrackTarget:
    title: str
    artist: str
    album: str | None = None
    duration_seconds: int | None = None
    year: int | None = None


@dataclass(frozen=True)
class ProviderOptions:
    timeout_seconds: int = 600
    file_stability_seconds: int = 3
    download_directory: Path | None = None
    base_url: str | None = None
    visible: bool = True
    dry_run: bool = False
    ffprobe_path: str = "ffprobe"


@dataclass(frozen=True)
class AcquisitionResult:
    status: AcquisitionStatus
    provider: str
    public_message: str
    local_file_path: Path | None = None
    error_code: str | None = None
    metadata: Mapping[str, Any] = field(default_factory=dict)


class AcquisitionProvider(Protocol):
    provider_name: str

    def acquire(
        self,
        target: TrackTarget,
        output_dir: Path,
        event_callback: EventCallback | None,
        options: ProviderOptions,
    ) -> AcquisitionResult:
        ...


def emit(
    callback: EventCallback | None,
    event_type: str,
    **payload: Any,
) -> None:
    if callback is not None:
        callback({"type": event_type, **payload})
