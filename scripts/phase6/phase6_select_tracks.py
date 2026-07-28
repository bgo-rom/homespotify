#!/usr/bin/env python3
"""Sélection de pistes de test réelles depuis le SNAPSHOT SQLite.

POURQUOI AUTOMATISER CE CHOIX
-----------------------------
Exiger deux identifiants saisis à la main, c'est déplacer sur le propriétaire
un travail que la base sait faire, et introduire la classe de défaut la plus
coûteuse de la Phase 5 : un test qui passe sur une piste qui n'existe plus.
Une piste choisie « parce qu'on s'en souvient » peut être périmée, synthétique
ou absente du Storage Agent — et le MISS/HIT qu'elle produit ne prouve rien.

LA SÉLECTION EST FAITE SUR LE SNAPSHOT, JAMAIS SUR LA PRODUCTION
----------------------------------------------------------------
Le snapshot est une copie en lecture seule, déjà validée
(`integrity_check`, `foreign_key_check`). L'interroger n'ouvre pas
`homespotify.db` de production une seconde fois.

CRITÈRES, ET CE QU'ILS ÉCARTENT
-------------------------------
- `hash` = SHA-256 hexadécimal de 64 caractères : écarte les lignes semées à
  la main et les imports interrompus.
- `size_bytes > 1 MiB` : un fichier plus petit n'est pas un morceau réel, et
  ne produirait pas un streaming assez long pour prouver quoi que ce soit.
- Extension audio réelle : écarte les résidus de fixture.
- Motifs de chemin de test (`fixture`, `sample`, `synthetic`, `probe`, `tmp`…) :
  écarte les pistes fabriquées par les harnais des phases précédentes.
- Taille proche de la MÉDIANE : un fichier médian se télécharge en un temps
  représentatif. Le plus gros fichier de la bibliothèque ferait un test lent
  et fragile ; le plus petit, un test qui ne remplit pas le cache.

CE QUI EST PUBLIÉ
-----------------
`trackId`, `sizeBytes`, et un PRÉFIXE de hash limité à 12 caractères. Ni
titre, ni artiste, ni album, ni chemin : ce sont des données personnelles du
propriétaire, et un rapport de déploiement n'a aucune raison de les porter.

CE QUE CE MODULE NE PROUVE PAS
------------------------------
Que le fichier existe encore côté Storage Agent. Seul un `HEAD 200` réel le
prouve, et il est exécuté par l'appelant tant que l'agent est actif. Ce module
produit donc des CANDIDATS ordonnés, pas un verdict.
"""

from __future__ import annotations

import argparse
import json
import re
import sqlite3
from pathlib import Path
from typing import Any

MIN_SIZE_BYTES = 1024 * 1024
HASH_PATTERN = re.compile(r"^[0-9a-f]{64}$")
HASH_PREFIX_LENGTH = 12

REAL_AUDIO_SUFFIXES = (".flac", ".wav", ".m4a", ".mp3", ".ogg", ".opus", ".aiff")
SYNTHETIC_PATH_MARKERS = (
    "fixture", "sample", "synthetic", "probe", "phase4", "phase5", "phase6",
    "tmp/", "temp/", "test", "dummy", "placeholder", "harness", "gate0",
)


class TrackSelectionError(RuntimeError):
    """Aucune sélection sûre possible : bascule sur les paramètres de secours."""


def is_synthetic(path: str) -> bool:
    lowered = path.replace("\\", "/").lower()
    return any(marker in lowered for marker in SYNTHETIC_PATH_MARKERS)


def has_real_audio_suffix(path: str) -> bool:
    return path.lower().endswith(REAL_AUDIO_SUFFIXES)


def eligible_rows(connection: sqlite3.Connection) -> list[dict[str, Any]]:
    """Lignes `tracks` qui satisfont tous les critères d'éligibilité."""
    rows = connection.execute(
        "SELECT id, hash, path, size_bytes FROM tracks "
        "WHERE size_bytes > ? ORDER BY id",
        (MIN_SIZE_BYTES,),
    ).fetchall()
    eligible: list[dict[str, Any]] = []
    for track_id, track_hash, path, size_bytes in rows:
        if not isinstance(track_hash, str) or not HASH_PATTERN.match(track_hash.lower()):
            continue
        if not isinstance(path, str) or not path:
            continue
        if is_synthetic(path) or not has_real_audio_suffix(path):
            continue
        eligible.append({
            "trackId": int(track_id),
            "sizeBytes": int(size_bytes),
            "hashPrefix": track_hash.lower()[:HASH_PREFIX_LENGTH],
        })
    return eligible


def rank_by_median(candidates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Ordonne par proximité à la taille médiane, puis par identifiant.

    Le tri secondaire sur `trackId` rend la sélection DÉTERMINISTE : deux
    exécutions sur le même snapshot proposent les mêmes pistes, donc deux
    rapports sont comparables.
    """
    sizes = sorted(item["sizeBytes"] for item in candidates)
    median = sizes[len(sizes) // 2]
    return sorted(
        candidates,
        key=lambda item: (abs(item["sizeBytes"] - median), item["trackId"]),
    )


def select(db_path: Path, wanted: int = 8) -> dict[str, Any]:
    if not db_path.is_file():
        raise TrackSelectionError(f"snapshot absent : {db_path.name}")
    # `mode=ro` : le snapshot ne peut pas être modifié, même par erreur.
    uri = f"file:{db_path.as_posix()}?mode=ro"
    connection = sqlite3.connect(uri, uri=True)
    try:
        total = connection.execute("SELECT count(*) FROM tracks").fetchone()[0]
        candidates = eligible_rows(connection)
    finally:
        connection.close()

    if len(candidates) < 2:
        raise TrackSelectionError(
            f"pistes éligibles insuffisantes : {len(candidates)} sur {total}"
        )
    ranked = rank_by_median(candidates)
    return {
        "ok": True,
        "trackCount": total,
        "eligibleCount": len(candidates),
        "minSizeBytes": MIN_SIZE_BYTES,
        # Plusieurs candidats sont proposés : l'appelant valide chacun par un
        # `HEAD` réel et retient les deux premiers qui répondent 200. Une
        # piste éligible en base peut avoir disparu du disque.
        "candidates": ranked[:wanted],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Candidats de pistes de test.")
    parser.add_argument("--db", required=True, help="snapshot SQLite (lecture seule)")
    parser.add_argument("--candidates", type=int, default=8)
    args = parser.parse_args()
    try:
        print(json.dumps(select(Path(args.db), args.candidates)))
    except TrackSelectionError as error:
        print(json.dumps({
            "ok": False, "error": "SELECTION_IMPOSSIBLE", "detail": str(error),
            "fallback": "fournir -TrackIdCached et -TrackIdUncached explicitement",
        }))
        return 1
    except sqlite3.Error as error:
        print(json.dumps({
            "ok": False, "error": "SQLITE", "detail": str(error)[:200],
            "fallback": "fournir -TrackIdCached et -TrackIdUncached explicitement",
        }))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
