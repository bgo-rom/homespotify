#!/usr/bin/env python3
"""Chemins du déploiement shadow Phase 6, et garde-fou de suppression.

POURQUOI CE MODULE EXISTE
-------------------------
Un script de cleanup qui accepte un chemin en argument est une arme. Les
racines shadow sont donc déclarées ICI, une seule fois, et toute suppression
doit passer par `assert_under_shadow_root()`. Un chemin hors de ces racines
n'est pas « refusé avec un avertissement » : il lève.

NOMS DE VARIABLES : LA DEMANDE ET LE CODE RÉEL
----------------------------------------------
Le cahier des charges Phase 6 nomme deux variables qui n'existent pas dans
`services/api/src/config.ts` :

    demandé              réel (config.ts)      rôle
    AUDIO_CACHE_DIR      AUDIO_CACHE_ROOT      racine du cache audio VPS
    OFFLINE_VARIANTS_DIR OFFLINE_CACHE_DIR     dérivées Opus hors ligne

Ce module utilise les noms RÉELS : un `.env` portant les noms demandés
laisserait les valeurs par défaut relatives s'appliquer silencieusement, ce
qui est exactement le piège que la Phase 6 veut éviter. La disposition des
répertoires, elle, est conforme à la demande.
"""

from __future__ import annotations

from pathlib import PurePosixPath

# --- Racines autorisées -----------------------------------------------------
# Toute écriture et toute suppression de la Phase 6 vit sous l'une d'elles.
RELEASE_ROOT = PurePosixPath("/opt/homespotify-api-shadow")
STATE_ROOT = PurePosixPath("/var/lib/homespotify-shadow")
ENV_FILE = PurePosixPath("/etc/homespotify/api-shadow.env")
UNIT_NAME = "homespotify-api-shadow.service"
UNIT_FILE = PurePosixPath("/etc/systemd/system") / UNIT_NAME

# `ENV_FILE` est un FICHIER précis, pas une racine : /etc/homespotify peut
# contenir la configuration d'autres services et ne doit jamais être effacé.
SHADOW_ROOTS = (RELEASE_ROOT, STATE_ROOT)
SHADOW_FILES = (ENV_FILE, UNIT_FILE)

# Arbres des phases précédentes : jamais touchés par la Phase 6.
PROTECTED_PATHS = (
    PurePosixPath("/home/debian/homespotify-phase45"),
    PurePosixPath("/home/debian/homespotify-phase5"),
    PurePosixPath("/etc/caddy"),
    PurePosixPath("/etc/wireguard"),
)

CURRENT_LINK = RELEASE_ROOT / "current"
PREVIOUS_LINK = RELEASE_ROOT / "previous"
RELEASES_DIR = RELEASE_ROOT / "releases"
BUNDLES_DIR = RELEASE_ROOT / "dependency-bundles"

DATA_DIR = STATE_ROOT / "data"
CACHE_DIR = STATE_ROOT / "cache" / "audio"
COVERS_DIR = STATE_ROOT / "covers"
INCOMING_DIR = STATE_ROOT / "imports" / "incoming"
OFFLINE_VARIANTS_DIR = STATE_ROOT / "offline-variants"
DB_PATH = DATA_DIR / "runtime.db"

SHADOW_HOST = "127.0.0.1"
SHADOW_PORT = 3002

# Profil « équilibré » du Gate 0 : la bibliothèque entière tient en cache avec
# un facteur 4 de croissance, donc l'éviction reste exceptionnelle.
CACHE_MAX_BYTES = 12 * 1024**3
CACHE_MIN_FREE_BYTES = 6 * 1024**3

# Runtime qualifié au Gate 0. Un écart interdit la promotion.
REQUIRED_NODE_VERSION = "v22.18.0"
REQUIRED_NODE_ABI = "127"
REQUIRED_ARCH = "x64"


class ShadowPathError(RuntimeError):
    """Chemin refusé : hors des racines shadow, ou explicitement protégé."""


def assert_under_shadow_root(path: str | PurePosixPath) -> PurePosixPath:
    """Autorise un chemin à être supprimé, ou lève.

    Refuse : les chemins relatifs, `..`, les racines elles-mêmes réduites à
    `/`, tout ce qui vit hors des racines shadow, et tout chemin protégé —
    y compris s'il est syntaxiquement sous une racine shadow.
    """
    candidate = PurePosixPath(str(path))
    if not candidate.is_absolute():
        raise ShadowPathError(f"chemin relatif refusé : {candidate}")
    if ".." in candidate.parts:
        raise ShadowPathError(f"remontée de répertoire refusée : {candidate}")
    for protected in PROTECTED_PATHS:
        if candidate == protected or protected in candidate.parents:
            raise ShadowPathError(f"chemin protégé : {candidate}")
    if candidate in SHADOW_FILES:
        return candidate
    for root in SHADOW_ROOTS:
        if candidate == root or root in candidate.parents:
            return candidate
    raise ShadowPathError(f"hors des racines shadow : {candidate}")


def state_directories() -> tuple[PurePosixPath, ...]:
    """Répertoires d'état à créer, dans l'ordre de création."""
    return (
        STATE_ROOT, DATA_DIR, STATE_ROOT / "cache", CACHE_DIR,
        COVERS_DIR, STATE_ROOT / "imports", INCOMING_DIR, OFFLINE_VARIANTS_DIR,
    )


def release_path(release_id: str) -> PurePosixPath:
    if "/" in release_id or release_id in ("", ".", ".."):
        raise ShadowPathError(f"release-id invalide : {release_id!r}")
    return RELEASES_DIR / release_id
