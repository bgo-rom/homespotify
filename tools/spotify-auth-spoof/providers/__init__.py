"""Fournisseurs d'acquisition HomeSpotify.

Ce paquet n'expose que des contrats et des implémentations interactives
bornées. Aucun endpoint privé ni cookie tiers n'y est utilisé.
"""

from .base_provider import (
    AcquisitionProvider,
    AcquisitionResult,
    AcquisitionStatus,
    ProviderOptions,
    TrackTarget,
)

__all__ = [
    "AcquisitionProvider",
    "AcquisitionResult",
    "AcquisitionStatus",
    "ProviderOptions",
    "TrackTarget",
]
