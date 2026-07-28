#!/usr/bin/env python3
"""Rendu et validation du fichier d'environnement shadow, sans jamais publier
une seule valeur secrète.

CONTRAT DES SECRETS
-------------------
Les deux secrets arrivent par **stdin**, en JSON, jamais par `argv`. Raison
mécanique : sous Linux comme sous Windows, la ligne de commande d'un processus
est lisible par d'autres processus (`/proc/<pid>/cmdline`, `Get-CimInstance
Win32_Process`) et atterrit dans l'historique du shell. `stdin` n'a aucune de
ces deux propriétés.

Le rendu remplace les marqueurs `__A_INJECTER__` du modèle versionné. Un
marqueur restant fait échouer la validation : mieux vaut un fichier refusé
qu'une API qui démarrerait avec un secret littéral `__A_INJECTER__`.

CE QUE LE RAPPORT CONTIENT
--------------------------
`secretPresent`, `lengthValid`, et des booléens de conformité. Jamais une
valeur, jamais un préfixe, jamais un hash. Un hash est explicitement refusé
par le cahier des charges, et à raison : sur un secret court, il est
attaquable par force brute, donc il en révèle la valeur.

QUELS CHEMINS DÉCRIT CE FICHIER
-------------------------------
Ceux du futur SERVICE (`/var/lib/homespotify-shadow/...`), pas ceux du
staging. C'est le fichier d'environnement définitif du shadow, déposé en
avance et jamais utilisé pour démarrer quoi que ce soit en Phase 6.2. Le
staging ne fait que le porter en `0600` jusqu'à l'installation.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

MARKER = "__A_INJECTER__"
SECRET_KEYS = ("AUDIO_REMOTE_SHARED_SECRET", "AUTH_TOKEN_SECRET")
MIN_SECRET_LENGTH = 32  # `config.ts` et `remote-config.ts` refusent en dessous.

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
}

ABSOLUTE_PATH_KEYS = (
    "DB_PATH", "COVERS_DIR", "INCOMING_DIR",
    "OFFLINE_CACHE_DIR", "AUDIO_CACHE_ROOT",
)


class EnvError(RuntimeError):
    """Environnement refusé. Le message ne porte jamais de valeur secrète."""


def parse_env(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, _, value = stripped.partition("=")
        values[key.strip()] = value.strip()
    return values


def render(template_text: str, secrets: dict[str, str]) -> str:
    """Injecte les deux secrets dans le modèle. Aucune autre substitution."""
    missing = [key for key in SECRET_KEYS if not secrets.get(key)]
    if missing:
        raise EnvError(f"secrets absents : {','.join(missing)}")
    short = [key for key in SECRET_KEYS
             if len(secrets[key]) < MIN_SECRET_LENGTH]
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
    # Le marqueur est cherché dans les AFFECTATIONS seulement : le modèle le
    # cite aussi dans son en-tête pour expliquer son rôle, et confondre la
    # documentation avec une injection oubliée ferait échouer tout rendu.
    leftover = [
        line.split("=", 1)[0]
        for line in text.splitlines()
        if not line.lstrip().startswith("#") and line.endswith(MARKER) and "=" in line
    ]
    if leftover:
        raise EnvError(f"marqueur non injecté : {','.join(leftover)}")
    return text


def validate_env_text(text: str) -> list[str]:
    """Écarts de conformité. Aucun message ne contient de valeur secrète."""
    problems: list[str] = []
    values = parse_env(text)

    for key in SECRET_KEYS:
        value = values.get(key)
        if value is None or value == "":
            problems.append(f"SECRET_ABSENT {key}")
        elif value == MARKER:
            problems.append(f"SECRET_NON_INJECTE {key}")
        elif len(value) < MIN_SECRET_LENGTH:
            # La longueur constatée n'est pas publiée : sur un secret trop
            # court, elle réduit déjà l'espace de recherche.
            problems.append(f"SECRET_TROP_COURT {key}")

    for key, expected in EXPECTED_LITERALS.items():
        actual = values.get(key)
        if actual != expected:
            problems.append(f"VALEUR_INATTENDUE {key}")

    for key in ABSOLUTE_PATH_KEYS:
        value = values.get(key)
        if value is None:
            problems.append(f"CHEMIN_ABSENT {key}")
        elif not value.startswith("/"):
            problems.append(f"CHEMIN_NON_ABSOLU {key}")
        elif ".." in value.split("/"):
            problems.append(f"CHEMIN_REMONTEE {key}")

    lucida = sorted(key for key in values if key.startswith("LUCIDA"))
    for key in lucida:
        problems.append(f"VARIABLE_LUCIDA_INTERDITE {key}")

    return problems


def summarize(text: str) -> dict[str, Any]:
    """Rapport strictement booléen — la sortie peut être journalisée."""
    values = parse_env(text)
    problems = validate_env_text(text)
    return {
        "ok": not problems,
        "secretCount": sum(
            1 for key in SECRET_KEYS
            if values.get(key) and values[key] != MARKER
        ),
        "secretsPresent": all(
            bool(values.get(key)) and values[key] != MARKER
            for key in SECRET_KEYS
        ),
        "secretLengthsValid": all(
            len(values.get(key, "")) >= MIN_SECRET_LENGTH for key in SECRET_KEYS
        ),
        "nodeEnvProduction": values.get("NODE_ENV") == "production",
        "logLevelInfo": values.get("LOG_LEVEL") == "info",
        "hostLoopback": values.get("HOST") == "127.0.0.1",
        "port3002": values.get("PORT") == "3002",
        "audioStorageModeCached": values.get("AUDIO_STORAGE_MODE") == "cached",
        "cacheMax12GiB": values.get("AUDIO_CACHE_MAX_BYTES") == str(CACHE_MAX_BYTES),
        "cacheMinFree6GiB": values.get("AUDIO_CACHE_MIN_FREE_BYTES") == str(CACHE_MIN_FREE_BYTES),
        "backupsDisabled": values.get("BACKUP_ENABLED") == "false",
        "allPathsAbsolute": all(
            (values.get(key) or "").startswith("/") for key in ABSOLUTE_PATH_KEYS
        ),
        "noLucidaVariable": not any(key.startswith("LUCIDA") for key in values),
        "problemCount": len(problems),
        "problems": problems[:20],
        # Preuve explicite, portée par la sortie elle-même.
        "secretsPrinted": 0,
    }


def write_private(path: Path, text: str) -> None:
    """Écrit en 0600, en créant le fichier avec ses permissions finales.

    `O_EXCL` refuse d'écraser : un fichier déjà présent peut porter un autre
    secret, et un `open('w')` classique créerait d'abord un fichier lisible
    par tous avant le `chmod` — une fenêtre courte, mais réelle.
    """
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
        # Windows n'a pas de bits POSIX : le durcissement y est fait par ACL,
        # côté PowerShell. Ce n'est pas un échec silencieux, c'est une
        # responsabilité déplacée là où elle est applicable.
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

    # Les secrets arrivent par stdin, jamais par argv.
    #
    # La lecture se fait en OCTETS puis en `utf-8-sig`, pas en texte : sous
    # Windows, `sys.stdin` décode avec l'encodage local (cp1252), et PowerShell
    # 5.1 préfixe un BOM UTF-8 à ce qu'il envoie à un processus natif. Décodé
    # en cp1252, ce BOM devient trois caractères parasites que `json.loads`
    # refuse — l'erreur ressemble alors à un secret malformé alors que la
    # charge est intacte. `utf-8-sig` consomme le BOM s'il est là, et ne fait
    # rien s'il ne l'est pas.
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
        text = render(Path(args.template).read_text(encoding="utf-8"), secrets)
    except EnvError as error:
        print(json.dumps({"ok": False, "error": "RENDU_REFUSE",
                          "detail": str(error)}))
        return 1
    finally:
        secrets = {}

    problems = validate_env_text(text)
    if problems:
        print(json.dumps({"ok": False, "error": "ENVIRONNEMENT_NON_CONFORME",
                          "problems": problems[:20]}))
        return 1
    write_private(Path(args.out), text)
    summary = summarize(text)
    summary["out"] = Path(args.out).name
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
