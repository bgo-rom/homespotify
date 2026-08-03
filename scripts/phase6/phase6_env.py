#!/usr/bin/env python3
"""Rendu et validation du fichier d'environnement shadow sans fuite de secret."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

MARKER = "__A_INJECTER__"
SECRET_KEYS = (
    "AUDIO_REMOTE_SHARED_SECRET",
    "AUTH_TOKEN_SECRET",
    "ANTRA_API_KEY",
)
MIN_SECRET_LENGTH = 32
SECRET_MIN_LENGTHS = {
    "AUDIO_REMOTE_SHARED_SECRET": MIN_SECRET_LENGTH,
    "AUTH_TOKEN_SECRET": MIN_SECRET_LENGTH,
    "ANTRA_API_KEY": 1,
}

CACHE_MAX_BYTES = 12 * 1024**3
CACHE_MIN_FREE_BYTES = 6 * 1024**3

EXPECTED_LITERALS = {
    "NODE_ENV": "production",
    "LOG_LEVEL": "info",
    "HOST": "127.0.0.1",
    "PORT": "3002",
    "AUDIO_STORAGE_MODE": "cached",
    "BACKUP_ENABLED": "false",
    "AUDIO_CACHE_MAX_BYTES": str(CACHE_MAX_BYTES),
    "AUDIO_CACHE_MIN_FREE_BYTES": str(CACHE_MIN_FREE_BYTES),
    "ACQUISITION_LEGACY_ENABLED": "false",
    "ANTRA_SOURCE": "auto",
    "ANTRA_FORMAT": "flac",
    "ANTRA_ALLOWED_EXTENSIONS": ".flac,.wav",
    "ANTRA_MAX_CONCURRENT": "2",
    "ANTRA_JOB_TIMEOUT_MS": "900000",
    "ANTRA_SLSKD_AUTO_BOOTSTRAP": "false",
    "ANTRA_VERBOSE": "false",
    "PYTHONDONTWRITEBYTECODE": "1",
    "SLSKD_AUTO_BOOTSTRAP": "false",
    "FETCH_LYRICS": "false",
    "SAVE_COVER_ART_SIDECAR": "false",
}

ABSOLUTE_PATH_KEYS = (
    "DB_PATH", "COVERS_DIR", "INCOMING_DIR", "HOMESPOTIFY_IMPORT_ROOT",
    "OFFLINE_CACHE_DIR", "MUSIC_DIR", "AUDIO_CACHE_ROOT", "ANTRA_DIR",
    "ANTRA_PYTHON", "ANTRA_OUTPUT_DIR",
    "ANTRA_ENDPOINT_MANIFEST_CACHE_PATH", "PROVIDER_STATS_DB_PATH",
    "HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME",
)
RELEASE_PATH_KEYS = ("ANTRA_DIR", "ANTRA_PYTHON")
STATE_PATH_KEYS = tuple(
    key for key in ABSOLUTE_PATH_KEYS if key not in RELEASE_PATH_KEYS
)


class EnvError(RuntimeError):
    """Environnement refusé sans valeur secrète dans le message."""


def parse_env(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        values[key.strip()] = value.strip()
    return values


def _secret_valid(key: str, value: str) -> bool:
    return bool(value) and value != MARKER and len(value) >= SECRET_MIN_LENGTHS[key]


def render(template_text: str, secrets: dict[str, str]) -> str:
    missing = [key for key in SECRET_KEYS if not secrets.get(key)]
    if missing:
        raise EnvError(f"secrets absents : {','.join(missing)}")
    short = [
        key for key in SECRET_KEYS
        if len(secrets[key]) < SECRET_MIN_LENGTHS[key]
    ]
    if short:
        raise EnvError(f"secrets trop courts : {','.join(short)}")

    rendered_lines: list[str] = []
    for line in template_text.splitlines():
        replaced = line
        for key in SECRET_KEYS:
            if line.startswith(f"{key}={MARKER}"):
                replaced = f"{key}={secrets[key]}"
        rendered_lines.append(replaced)

    text = "\n".join(rendered_lines) + "\n"
    leftover = [
        line.split("=", 1)[0]
        for line in text.splitlines()
        if not line.lstrip().startswith("#")
        and line.endswith(MARKER)
        and "=" in line
    ]
    if leftover:
        raise EnvError(f"marqueur non injecté : {','.join(leftover)}")
    return text


def validate_env_text(text: str) -> list[str]:
    problems: list[str] = []
    values = parse_env(text)

    for key in SECRET_KEYS:
        value = values.get(key)
        if value is None or value == "":
            problems.append(f"SECRET_ABSENT {key}")
        elif value == MARKER:
            problems.append(f"SECRET_NON_INJECTE {key}")
        elif len(value) < SECRET_MIN_LENGTHS[key]:
            problems.append(f"SECRET_TROP_COURT {key}")

    for key, expected in EXPECTED_LITERALS.items():
        if values.get(key) != expected:
            problems.append(f"VALEUR_INATTENDUE {key}")

    for key in ABSOLUTE_PATH_KEYS:
        value = values.get(key)
        if value is None:
            problems.append(f"CHEMIN_ABSENT {key}")
        elif not value.startswith("/"):
            problems.append(f"CHEMIN_NON_ABSOLU {key}")
        elif ".." in value.split("/"):
            problems.append(f"CHEMIN_REMONTEE {key}")

    for key in RELEASE_PATH_KEYS:
        value = values.get(key, "")
        if value and not value.startswith("/opt/homespotify-api-shadow/"):
            problems.append(f"CHEMIN_RELEASE_HORS_RACINE {key}")

    for key in STATE_PATH_KEYS:
        value = values.get(key, "")
        if value and not value.startswith("/var/lib/homespotify-shadow/"):
            problems.append(f"CHEMIN_ETAT_HORS_RACINE {key}")

    for key in sorted(key for key in values if key.startswith("LUCIDA")):
        problems.append(f"VARIABLE_LUCIDA_INTERDITE {key}")
    return problems


def summarize(text: str) -> dict[str, Any]:
    values = parse_env(text)
    problems = validate_env_text(text)
    return {
        "ok": not problems,
        "secretCount": sum(
            1 for key in SECRET_KEYS if _secret_valid(key, values.get(key, ""))
        ),
        "secretsPresent": all(
            bool(values.get(key)) and values[key] != MARKER
            for key in SECRET_KEYS
        ),
        "secretLengthsValid": all(
            len(values.get(key, "")) >= SECRET_MIN_LENGTHS[key]
            for key in SECRET_KEYS
        ),
        "nodeEnvProduction": values.get("NODE_ENV") == "production",
        "logLevelInfo": values.get("LOG_LEVEL") == "info",
        "hostLoopback": values.get("HOST") == "127.0.0.1",
        "port3002": values.get("PORT") == "3002",
        "audioStorageModeCached": values.get("AUDIO_STORAGE_MODE") == "cached",
        "cacheMax12GiB": values.get("AUDIO_CACHE_MAX_BYTES") == str(CACHE_MAX_BYTES),
        "cacheMinFree6GiB": values.get("AUDIO_CACHE_MIN_FREE_BYTES") == str(CACHE_MIN_FREE_BYTES),
        "backupsDisabled": values.get("BACKUP_ENABLED") == "false",
        "antraConfigured": all(
            bool(values.get(key)) for key in (
                "ANTRA_DIR", "ANTRA_PYTHON", "ANTRA_OUTPUT_DIR",
                "ANTRA_ENDPOINT_MANIFEST_CACHE_PATH", "PROVIDER_STATS_DB_PATH",
            )
        ),
        "antraSlskdDisabled": (
            values.get("ANTRA_SLSKD_AUTO_BOOTSTRAP") == "false"
            and values.get("SLSKD_AUTO_BOOTSTRAP") == "false"
        ),
        "allPathsAbsolute": all(
            (values.get(key) or "").startswith("/") for key in ABSOLUTE_PATH_KEYS
        ),
        "allStatePathsBounded": all(
            (values.get(key) or "").startswith("/var/lib/homespotify-shadow/")
            for key in STATE_PATH_KEYS
        ),
        "allReleasePathsBounded": all(
            (values.get(key) or "").startswith("/opt/homespotify-api-shadow/")
            for key in RELEASE_PATH_KEYS
        ),
        "noLucidaVariable": not any(key.startswith("LUCIDA") for key in values),
        "problemCount": len(problems),
        "problems": problems[:20],
        "secretsPrinted": 0,
    }


def write_private(path: Path, text: str) -> None:
    if path.exists():
        path.unlink()
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        os.write(descriptor, text.encode("utf-8"))
    finally:
        os.close(descriptor)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def main() -> int:
    parser = argparse.ArgumentParser(description="Environnement shadow.")
    parser.add_argument("--template")
    parser.add_argument("--out")
    parser.add_argument("--validate", help="valide un fichier existant")
    args = parser.parse_args()

    if args.validate:
        text = Path(args.validate).read_text(encoding="utf-8")
        summary = summarize(text)
        print(json.dumps(summary))
        return 0 if summary["ok"] else 1

    if not args.template or not args.out:
        print(json.dumps({"ok": False, "error": "USAGE"}))
        return 2

    try:
        raw = sys.stdin.buffer.read().decode("utf-8-sig").strip()
        secrets = json.loads(raw or "{}")
    except json.JSONDecodeError:
        print(json.dumps({"ok": False, "error": "SECRETS_ILLISIBLES"}))
        return 1
    if not isinstance(secrets, dict):
        print(json.dumps({"ok": False, "error": "SECRETS_ILLISIBLES"}))
        return 1

    try:
        text = render(
            Path(args.template).read_text(encoding="utf-8-sig"),
            secrets,
        )
    except EnvError as error:
        print(json.dumps({"ok": False, "error": "RENDU_REFUSE", "detail": str(error)}))
        return 1
    finally:
        secrets = {}

    problems = validate_env_text(text)
    if problems:
        print(json.dumps({
            "ok": False,
            "error": "ENVIRONNEMENT_NON_CONFORME",
            "problems": problems[:20],
        }))
        return 1

    write_private(Path(args.out), text)
    summary = summarize(text)
    summary["out"] = Path(args.out).name
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
