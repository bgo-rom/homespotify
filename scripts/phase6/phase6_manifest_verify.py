#!/usr/bin/env python3
"""Vérifie qu'un répertoire correspond exactement à son `manifest.json`.

Exécuté sur le VPS avant toute promotion : un transfert tronqué, un fichier
en trop ou une empreinte divergente doivent arrêter la release, pas produire
un service qui démarre « à peu près ».
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from phase6_manifest import MANIFEST_NAME, verify_manifest  # noqa: E402


def main() -> int:
    if len(sys.argv) != 2:
        print(json.dumps({"ok": False, "error": "USAGE"}))
        return 2
    root = Path(sys.argv[1])
    manifest_path = root / MANIFEST_NAME
    if not manifest_path.is_file():
        print(json.dumps({"ok": False, "error": "MANIFESTE_ABSENT"}))
        return 1
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    problems = verify_manifest(root, manifest)
    print(json.dumps({
        "ok": not problems,
        "releaseId": manifest.get("releaseId"),
        "fileCount": manifest.get("fileCount"),
        "manifestSha256": manifest.get("manifestSha256"),
        "problems": problems[:20],
        "problemCount": len(problems),
    }))
    return 0 if not problems else 1


if __name__ == "__main__":
    raise SystemExit(main())
