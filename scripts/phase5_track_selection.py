#!/usr/bin/env python3
"""Sélection de pistes partagée par le harnais Phase 5.

Ce module est importé par `vps_phase5_write_env.py` (dimensionnement du cache)
ET par `vps_phase5_cache_test.py` (choix de la piste d'abandon). Les deux
DOIVENT appliquer exactement les mêmes critères : si le cache est dimensionné
pour une piste et que le test en utilise une autre, l'éviction cesse d'être
déterministe et le harnais échoue sans que le code applicatif soit en cause.

Pourquoi un seuil de taille — le défaut réel du 2026-07-27
----------------------------------------------------------
`vps_phase45_setup.sh` insère volontairement une piste PÉRIMÉE dans la base de
validation, pour éprouver le chemin « index distant obsolète » :

    id = max(id) + 1000000 · hash = "f" * 64 · size_bytes = 4096
    path = "phase45-validation-only.invalid" · is_visible = 1

La Phase 5 copie cette base. L'ancienne sélection triait `size_bytes ASC` sans
plancher : la plus petite piste RÉELLE pèse ~9,2 Mo, la piste périmée 4 096
octets. Elle était donc systématiquement choisie, et le Storage Agent
répondait `404 TRACK_NOT_INDEXED` → `INDEX_STALE` → **503** — un diagnostic
correct de bout en bout, sur une piste qui n'aurait jamais dû être retenue.

Le hash `"f" * 64` étant soixante-quatre caractères hexadécimaux valides, une
simple validation de forme ne l'écarte PAS. Le plancher de taille, lui, l'écarte
de façon déterministe, et le contrôle `HEAD` du test le confirme.
"""

from __future__ import annotations

import re
import sqlite3
from typing import Any, NamedTuple

SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")

# Plancher très au-dessus des 4 096 octets de la piste périmée, très en dessous
# de la plus petite piste réelle (~9,2 Mo). Garantit aussi qu'un abandon en
# cours de flux porte sur un fichier assez grand pour être interrompu.
MIN_TRACK_SIZE_BYTES = 1024 * 1024


class SelectedTrack(NamedTuple):
    """Piste choisie dans la base pour un scénario de test."""

    track_id: int
    size_bytes: int
    sha256: str

    @property
    def stream_path(self) -> str:
        """Chemin HTTP de streaming — toujours une `str`, jamais le tuple."""
        return stream_path(self.track_id)

    @property
    def hash_prefix(self) -> str:
        """Préfixe non identifiant, sûr à journaliser."""
        return self.sha256[:12]


def ensure_http_path(value: object, *, argument: str) -> str:
    """Garantit qu'une valeur est utilisable comme chemin HTTP."""
    if not isinstance(value, str):
        raise TypeError(
            f"{argument} doit être une chaîne de chemin HTTP, "
            f"reçu un objet de type {type(value).__name__}"
        )
    if not value.startswith("/"):
        raise ValueError(f"{argument} doit commencer par '/' (chemin absolu attendu)")
    return value


def ensure_track_id(value: object, *, argument: str) -> int:
    """Garantit qu'une valeur est un identifiant de piste exploitable."""
    # `bool` est une sous-classe de `int` : `True` produirait le chemin
    # `/api/tracks/True/stream`, accepté par le typage mais absurde.
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(
            f"{argument} doit être un entier, "
            f"reçu un objet de type {type(value).__name__}"
        )
    if value <= 0:
        raise ValueError(f"{argument} doit être strictement positif")
    return value


def ensure_content_hash(value: object, *, argument: str) -> str:
    """Garantit une empreinte SHA-256 bien formée (forme seulement)."""
    if not isinstance(value, str):
        raise TypeError(
            f"{argument} doit être une chaîne, "
            f"reçu un objet de type {type(value).__name__}"
        )
    if not SHA256_PATTERN.match(value):
        raise ValueError(f"{argument} n'est pas une empreinte SHA-256 hexadécimale")
    return value


def stream_path(track_id: int) -> str:
    """Construit le chemin HTTP de streaming d'une piste, explicitement."""
    return f"/api/tracks/{ensure_track_id(track_id, argument='track_id')}/stream"


def candidate_tracks(
    database_path: str,
    user_id: Any,
    excluded_track_ids: tuple[int, ...],
    *,
    minimum_size_bytes: int = MIN_TRACK_SIZE_BYTES,
    limit: int = 5,
) -> list[SelectedTrack]:
    """Pistes candidates, de la plus petite à la plus grande.

    L'ordre `size_bytes ASC, id ASC` est DÉTERMINISTE : les deux appelants
    obtiennent la même première candidate, donc le même dimensionnement de
    cache et la même piste de test.
    """
    placeholders = ",".join("?" for _ in excluded_track_ids) or "NULL"
    rows = _query(
        database_path,
        f"""
        SELECT t.id, t.size_bytes, t.hash
        FROM tracks t
        JOIN user_tracks ut ON ut.track_id=t.id
        WHERE ut.user_id=?
          AND ut.is_visible=1
          AND t.id NOT IN ({placeholders})
          AND t.size_bytes >= ?
        ORDER BY t.size_bytes ASC, t.id ASC
        LIMIT ?
        """,
        (user_id, *excluded_track_ids, minimum_size_bytes, limit),
    )
    selected: list[SelectedTrack] = []
    for row_id, row_size, row_hash in rows:
        try:
            track = SelectedTrack(
                track_id=ensure_track_id(row_id, argument="candidate.track_id"),
                size_bytes=int(row_size),
                sha256=ensure_content_hash(row_hash, argument="candidate.sha256"),
            )
        except (TypeError, ValueError):
            # Une ligne malformée est ignorée, jamais « réparée » : la piste
            # suivante fera l'affaire, et le compteur de candidates le dira.
            continue
        selected.append(track)
    return selected


def track_exists(database_path: str, track_id: int) -> bool:
    """Présence de la piste dans la copie SQLite du harnais."""
    return bool(
        _query(database_path, "SELECT 1 FROM tracks WHERE id=? LIMIT 1", (track_id,))
    )


def _query(database_path: str, sql: str, parameters: tuple[Any, ...]) -> list[Any]:
    database = sqlite3.connect(database_path)
    try:
        return database.execute(sql, parameters).fetchall()
    finally:
        database.close()
