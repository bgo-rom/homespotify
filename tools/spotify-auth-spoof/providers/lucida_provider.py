"""Adaptateur du runner Lucida historique vers le contrat commun."""

from __future__ import annotations

from pathlib import Path
from typing import Callable

from .base_provider import (
    AcquisitionResult,
    AcquisitionStatus,
    EventCallback,
    ProviderOptions,
    TrackTarget,
)


class LucidaProvider:
    provider_name = "LUCIDA"

    def __init__(self, acquire_impl: Callable[..., str | None]) -> None:
        self._acquire_impl = acquire_impl

    def acquire(
        self,
        target: TrackTarget,
        output_dir: Path,
        event_callback: EventCallback | None,
        options: ProviderOptions,
    ) -> AcquisitionResult:
        result = self._acquire_impl(
            target=target,
            output_dir=output_dir,
            event_callback=event_callback,
            options=options,
        )
        if result is None:
            return AcquisitionResult(
                AcquisitionStatus.PROVIDER_ERROR,
                self.provider_name,
                "Lucida n’a pas fourni de fichier exploitable.",
                error_code="LUCIDA_ERROR",
            )
        return AcquisitionResult(
            AcquisitionStatus.SUCCESS,
            self.provider_name,
            "Fichier acquis par Lucida.",
            local_file_path=Path(result),
        )
