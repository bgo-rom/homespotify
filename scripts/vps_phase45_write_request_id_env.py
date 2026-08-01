#!/usr/bin/env python3
"""Crée la configuration 0600 de l'API ciblée requestId, sans rien afficher."""

from __future__ import annotations

import argparse
import os
import secrets
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--secret-file", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    root = Path(args.root)
    secret_path = Path(args.secret_file)
    output_path = Path(args.output)
    if secret_path.stat().st_mode & 0o077:
        raise SystemExit("SECRET_MODE_INVALID")
    hmac_secret = secret_path.read_text(encoding="utf-8").strip()
    if len(hmac_secret) < 32:
        raise SystemExit("HMAC_SECRET_TOO_SHORT")

    values = {
        "NODE_ENV": "test",
        "HOST": "127.0.0.1",
        "PORT": "3001",
        "DB_PATH": str(root / "data" / "runtime.db"),
        "MUSIC_DIR": str(root / "runtime" / "music"),
        "INCOMING_DIR": str(root / "runtime" / "imports"),
        "HOMESPOTIFY_IMPORT_ROOT": str(root / "runtime" / "imports"),
        "COVERS_DIR": str(root / "runtime" / "covers"),
        "OFFLINE_CACHE_DIR": str(root / "runtime" / "offline"),
        "BACKUP_ENABLED": "false",
        "DISCOVERY_ENABLED": "false",
        "SPOTIFY_DISCOVERY_ENABLED": "false",
        "APPLE_MUSIC_DISCOVERY_ENABLED": "false",
        "DEEZER_DISCOVERY_ENABLED": "false",
        "AUDIO_STORAGE_MODE": "remote",
        "AUDIO_REMOTE_BASE_URL": "http://10.8.0.2:3100",
        "AUDIO_REMOTE_SHARED_SECRET": hmac_secret,
        "AUDIO_REMOTE_CONNECT_TIMEOUT_MS": "2000",
        "AUDIO_REMOTE_HEADERS_TIMEOUT_MS": "5000",
        "AUDIO_REMOTE_BODY_IDLE_TIMEOUT_MS": "15000",
        "AUDIO_REMOTE_MAX_CONNECTIONS": "8",
        "AUTH_TOKEN_SECRET": secrets.token_hex(32),
        "LOG_LEVEL": "info",
    }

    descriptor = os.open(
        output_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
        0o600,
    )
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.writelines(f"{key}={value}\n" for key, value in values.items())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
