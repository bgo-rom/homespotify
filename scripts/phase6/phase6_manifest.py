#!/usr/bin/env python3
"""Manifeste d'artefact shadow : construction, empreinte, vérification.

PROPRIÉTÉ CENTRALE — REPRODUCTIBILITÉ
-------------------------------------
Le manifeste est une fonction pure du CONTENU de l'artefact : chemins relatifs
en séparateurs POSIX, triés, avec taille et SHA-256. Ni horodatage, ni ordre de
parcours du système de fichiers, ni chemin absolu n'y entrent. Deux assemblages
du même contenu produisent donc le même `manifestSha256`, ce qui rend le
contrôle de transfert exact plutôt qu'indicatif.

Le `releaseId` combine l'horodatage UTC, le commit et l'empreinte du
manifeste : `20260728T101500Z-033f4f51-9a3bd2c1`. L'horodatage rend
l'identifiant unique et ordonnable ; l'empreinte rend la release vérifiable.

CE QUE L'ARTEFACT NE CONTIENT JAMAIS
------------------------------------
Sources non nécessaires au runtime, tests, `.env`, bases SQLite, audio,
`node_modules` Windows, journaux, caches, imports réels, clés, diagnostics,
données utilisateur. La liste d'exclusion est appliquée par `is_excluded()` et
vérifiée par les tests : une exclusion oubliée est un défaut, pas un détail.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

MANIFEST_VERSION = 1
MANIFEST_NAME = "manifest.json"

# Motifs interdits dans un artefact. Comparaison sur le chemin POSIX relatif,
# en minuscules, pour être insensible à la casse de Windows.
EXCLUDED_NAMES = frozenset({
    ".env", ".env.local", ".env.production", ".hmac-secret",
    "node_modules", "__pycache__", ".git", ".ds_store", "thumbs.db",
})
EXCLUDED_SUFFIXES = (
    ".db", ".db-wal", ".db-shm", ".sqlite", ".sqlite3",
    ".flac", ".mp3", ".wav", ".m4a", ".ogg", ".opus",
    ".log", ".pem", ".key", ".pfx", ".p12", ".crt",
    ".test.ts", ".test.js", ".spec.ts", ".map",
)
# Répertoires exclus À N'IMPORTE QUEL NIVEAU. Aucun de ces noms ne désigne
# jamais du code applicatif légitime.
EXCLUDED_DIR_ANYWHERE = frozenset({
    "node_modules", "__pycache__", ".git", "coverage", "__tests__",
})

# Répertoires de DONNÉES, exclus au PREMIER NIVEAU seulement.
#
# POURQUOI L'ANCRAGE EST INDISPENSABLE
# ------------------------------------
# Ces noms désignent des répertoires de données à la racine du dépôt
# (`storage/`, `logs/`, `cache/`, `backups/`). Les exclure à n'importe quel
# niveau écartait aussi `dist/storage/` — c'est-à-dire TOUTE la couche de
# stockage audio, les douze fichiers que la Phase 6 existe précisément pour
# qualifier. L'artefact partait sans eux, et rien ne le voyait : le manifeste
# était cohérent avec lui-même, le transfert exact, et le défaut n'apparaissait
# qu'au premier `import` réel. Voir L-112.
EXCLUDED_TOP_LEVEL_DIRS = frozenset({
    "logs", "cache", "storage", "backups", "diagnostics", "test", "tests",
})


def is_excluded(relative: str) -> bool:
    """Vrai si ce chemin relatif ne doit jamais entrer dans un artefact."""
    posix = PurePosixPath(relative.replace("\\", "/"))
    lowered = [part.lower() for part in posix.parts]
    directories = lowered[:-1]
    if any(part in EXCLUDED_DIR_ANYWHERE for part in directories):
        return True
    if directories and directories[0] in EXCLUDED_TOP_LEVEL_DIRS:
        return True
    name = lowered[-1] if lowered else ""
    if name in EXCLUDED_NAMES:
        return True
    return any(name.endswith(suffix) for suffix in EXCLUDED_SUFFIXES)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def collect_files(root: Path) -> list[tuple[str, Path]]:
    """Fichiers retenus, en chemins relatifs POSIX triés."""
    found: list[tuple[str, Path]] = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        if relative == MANIFEST_NAME or is_excluded(relative):
            continue
        found.append((relative, path))
    return sorted(found, key=lambda item: item[0])


def build_entries(root: Path) -> list[dict[str, Any]]:
    return [
        {"path": relative, "sizeBytes": path.stat().st_size, "sha256": sha256_file(path)}
        for relative, path in collect_files(root)
    ]


def manifest_digest(entries: Iterable[dict[str, Any]]) -> str:
    """Empreinte du manifeste : dépend du contenu, jamais de l'horodatage."""
    canonical = json.dumps(
        [[e["path"], e["sizeBytes"], e["sha256"]] for e in entries],
        separators=(",", ":"), ensure_ascii=False, sort_keys=False,
    )
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def make_release_id(built_at: str, commit: str, digest: str) -> str:
    """`<utc>-<commit8>-<manifest8>` — unique, ordonnable et vérifiable."""
    stamp = built_at.replace("-", "").replace(":", "").replace("Z", "Z")
    return f"{stamp}-{commit[:8]}-{digest[:8]}"


def build_manifest(root: Path, *, commit: str, built_at: str,
                   node_version: str, node_abi: str, arch: str,
                   bundle_id: str) -> dict[str, Any]:
    entries = build_entries(root)
    digest = manifest_digest(entries)
    return {
        "manifestVersion": MANIFEST_VERSION,
        "releaseId": make_release_id(built_at, commit, digest),
        "commit": commit,
        "builtAt": built_at,
        "requiredNodeVersion": node_version,
        "requiredNodeAbi": node_abi,
        "requiredArch": arch,
        "dependencyBundleId": bundle_id,
        "fileCount": len(entries),
        "totalBytes": sum(e["sizeBytes"] for e in entries),
        "manifestSha256": digest,
        "files": entries,
    }


def verify_manifest(root: Path, manifest: dict[str, Any]) -> list[str]:
    """Écarts entre un manifeste et un répertoire. Liste vide = conforme."""
    problems: list[str] = []
    declared = {e["path"]: e for e in manifest.get("files", [])}
    present = {relative: path for relative, path in collect_files(root)}
    for missing in sorted(set(declared) - set(present)):
        problems.append(f"MANQUANT {missing}")
    for extra in sorted(set(present) - set(declared)):
        problems.append(f"EN_TROP {extra}")
    for relative in sorted(set(declared) & set(present)):
        path, entry = present[relative], declared[relative]
        if path.stat().st_size != entry["sizeBytes"]:
            problems.append(f"TAILLE {relative}")
        elif sha256_file(path) != entry["sha256"]:
            problems.append(f"EMPREINTE {relative}")
    recomputed = manifest_digest(manifest.get("files", []))
    if recomputed != manifest.get("manifestSha256"):
        problems.append("MANIFEST_SHA256_INCOHERENT")
    return problems
