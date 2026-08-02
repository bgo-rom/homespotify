#!/usr/bin/env python3
"""Écrit le `manifest.json` d'un répertoire d'artefact assemblé."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from phase6_manifest import MANIFEST_NAME, build_manifest, is_excluded  # noqa: E402
from phase6_paths import (  # noqa: E402
    REQUIRED_ARCH,
    REQUIRED_NODE_ABI,
    REQUIRED_NODE_VERSION,
)


def prune_excluded(root: Path) -> list[str]:
    """Supprime physiquement du staging tout ce que le manifeste exclut."""

    removed: list[str] = []

    for path in sorted(
        root.rglob("*"),
        key=lambda candidate: len(candidate.parts),
        reverse=True,
    ):
        if not path.is_file():
            continue

        relative = path.relative_to(root).as_posix()

        if relative != MANIFEST_NAME and is_excluded(relative):
            path.unlink()
            removed.append(relative)

    for path in sorted(
        root.rglob("*"),
        key=lambda candidate: len(candidate.parts),
        reverse=True,
    ):
        if path.is_dir() and not any(path.iterdir()):
            path.rmdir()

    return removed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--built-at", required=True)
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--antra-commit", required=True)
    parser.add_argument("--antra-requirements-sha256", required=True)
    parser.add_argument("--antra-runtime-id", required=True)
    args = parser.parse_args()

    root = Path(args.root)

    if not root.is_dir():
        print(json.dumps({"ok": False, "error": "ROOT_ABSENT"}))
        return 1

    removed = prune_excluded(root)

    manifest = build_manifest(
        root,
        commit=args.commit,
        built_at=args.built_at,
        node_version=REQUIRED_NODE_VERSION,
        node_abi=REQUIRED_NODE_ABI,
        arch=REQUIRED_ARCH,
        bundle_id=args.bundle_id,
        antra_commit=args.antra_commit,
        antra_requirements_sha256=args.antra_requirements_sha256,
        antra_runtime_id=args.antra_runtime_id,
    )

    (root / MANIFEST_NAME).write_text(
        json.dumps(
            manifest,
            indent=1,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    from phase6_manifest import verify_manifest  # noqa: PLC0415

    problems = verify_manifest(root, manifest)

    print(
        json.dumps(
            {
                "ok": not problems,
                "releaseId": manifest["releaseId"],
                "fileCount": manifest["fileCount"],
                "totalBytes": manifest["totalBytes"],
                "manifestSha256": manifest["manifestSha256"],
                "antraCommit": manifest["antraCommit"],
                "antraRequirementsSha256": manifest[
                    "antraRequirementsSha256"
                ],
                "antraRuntimeId": manifest["antraRuntimeId"],
                "prunedCount": len(removed),
                "pruned": removed[:10],
                "problems": problems[:10],
            }
        )
    )

    return 0 if not problems else 1


if __name__ == "__main__":
    raise SystemExit(main())
