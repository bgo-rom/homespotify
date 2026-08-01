"""Entrée CLI NDJSON du fallback manuel Monochrome."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from providers.base_provider import ProviderOptions, TrackTarget
from providers.monochrome_manual_provider import MonochromeManualProvider


def emit_event(event: dict[str, object]) -> None:
    print(json.dumps(event, ensure_ascii=False), flush=True)


def bounded_int(value: str, minimum: int, maximum: int) -> int:
    parsed = int(value)
    if parsed < minimum or parsed > maximum:
        raise argparse.ArgumentTypeError(
            f"valeur attendue entre {minimum} et {maximum}"
        )
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--title", required=True)
    parser.add_argument("--artist", required=True)
    parser.add_argument("--album")
    parser.add_argument("--duration", type=lambda v: bounded_int(v, 1, 86_400))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--download-directory", type=Path, required=True)
    parser.add_argument("--base-url", default="https://monochrome.tf/")
    parser.add_argument(
        "--timeout",
        type=lambda v: bounded_int(v, 30, 1_800),
        default=600,
    )
    parser.add_argument(
        "--stability-seconds",
        type=lambda v: bounded_int(v, 1, 30),
        default=3,
    )
    parser.add_argument("--ffprobe", default="ffprobe")
    parser.add_argument("--dry-run-monochrome", action="store_true")
    args = parser.parse_args()

    target = TrackTarget(
        title=args.title.strip(),
        artist=args.artist.strip(),
        album=args.album.strip() if args.album else None,
        duration_seconds=args.duration,
    )
    if not target.title or not target.artist:
        emit_event(
            {
                "type": "error",
                "code": "INVALID_ARGUMENT",
                "message": "Titre et artiste obligatoires.",
            }
        )
        return 2
    result = MonochromeManualProvider().acquire(
        target,
        args.output.resolve(),
        emit_event,
        ProviderOptions(
            timeout_seconds=args.timeout,
            file_stability_seconds=args.stability_seconds,
            download_directory=args.download_directory.resolve(),
            base_url=args.base_url,
            visible=True,
            dry_run=args.dry_run_monochrome,
            ffprobe_path=args.ffprobe,
        ),
    )
    if result.local_file_path is not None:
        emit_event(
            {
                "type": "success",
                "provider": "Monochrome",
                "filename": result.local_file_path.name,
                "metadata": dict(result.metadata),
                "dryRun": args.dry_run_monochrome,
            }
        )
        return 0
    emit_event(
        {
            "type": "error",
            "provider": "Monochrome",
            "code": result.error_code or result.status.value,
            "message": result.public_message,
        }
    )
    return 3


if __name__ == "__main__":
    raise SystemExit(main())
