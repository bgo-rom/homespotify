#!/usr/bin/env python3
"""Lit une valeur entière autorisée dans l'état Phase 4.5.

Ce petit exécutable évite tout code Python imbriqué dans une commande SSH.
Il ne sait lire ni afficher un secret, un chemin de média ou une identité.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

ALLOWED_KEYS = {
    "smallTrackId",
    "largeTrackId",
    "staleTrackId",
    "sourceTrackCount",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("state_file")
    parser.add_argument("key", choices=sorted(ALLOWED_KEYS))
    args = parser.parse_args()

    with Path(args.state_file).open("r", encoding="utf-8") as handle:
        state = json.load(handle)

    value = state.get(args.key)
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise SystemExit(f"PHASE45_STATE_INVALID key={args.key}")
    print(value, flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
