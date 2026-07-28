#!/usr/bin/env python3
"""Racine de staging Phase 6.2, et garde-fou de suppression associé.

POURQUOI UNE RACINE SÉPARÉE DE LA PHASE 6.3
-------------------------------------------
La Phase 6.2 dépose une release COMPLÈTE sur le VPS sans rien activer. Elle
n'a donc aucune raison d'écrire sous `/opt`, `/var/lib` ou `/etc` : ces
chemins appartiennent au service, et le service n'existe pas encore. Tout vit
sous une racine unique, non privilégiée, appartenant à `debian` :

    /home/debian/homespotify-phase6-staging/

Propriété visée : `-CleanupStaging` doit pouvoir supprimer INTÉGRALEMENT
cette racine et ne rien laisser derrière. Corollaire strict — rien
d'important ne doit jamais y vivre, et rien d'autre ne doit jamais être
supprimé par ce chemin de code.

DIFFÉRENCE AVEC `phase6_paths.assert_under_shadow_root()`
---------------------------------------------------------
`phase6_paths` borne les racines du SERVICE (`/opt`, `/var/lib`, l'unité).
Ce module borne la racine de STAGING. Les deux jeux sont disjoints : un
chemin de service passé au cleanup de staging est refusé, et réciproquement.
C'est voulu : un garde-fou qui accepte les deux périmètres ne borne rien.
"""

from __future__ import annotations

from pathlib import PurePosixPath

from phase6_paths import PROTECTED_PATHS, RELEASE_ROOT, STATE_ROOT, ENV_FILE

# --- Racine unique de la Phase 6.2 ------------------------------------------
STAGING_ROOT = PurePosixPath("/home/debian/homespotify-phase6-staging")

RELEASES_DIR = STAGING_ROOT / "releases"
BUNDLES_DIR = STAGING_ROOT / "dependency-bundles"
DATA_DIR = STAGING_ROOT / "data"
COVERS_DIR = DATA_DIR / "covers"
SQLITE_DIR = DATA_DIR / "sqlite"
SECRETS_DIR = STAGING_ROOT / "secrets"
REPORTS_DIR = STAGING_ROOT / "reports"
TOOLS_DIR = STAGING_ROOT / "tools"

ENV_FILE_STAGED = SECRETS_DIR / "api-shadow.env"
BUNDLE_ID = "linux-x64-node22.18.0-abi127"
BUNDLE_DIR = BUNDLES_DIR / BUNDLE_ID

# Le contenu du bundle vit dans un sous-répertoire NOMMÉ `node_modules`, et
# ce nom n'est pas décoratif : Node résout les dépendances pairs en remontant
# l'arborescence à la recherche de répertoires appelés exactement
# `node_modules`. Déposer les paquets directement sous `<bundle-id>/` produit
# un `better_sqlite3.node` présent, chargeable en apparence, et un
# `Cannot find module 'bindings'` au premier `require` — un échec qui ne
# ressemble pas du tout à sa cause.
BUNDLE_MODULES = BUNDLE_DIR / "node_modules"

# Arbre qualifié en Phase 4.5 : source du bundle Linux, traité en LECTURE
# SEULE. Il n'appartient pas à la Phase 6 et ne doit jamais être supprimé,
# déplacé ni modifié — le préflight le vérifie, le cleanup le refuse.
BUNDLE_SOURCE = PurePosixPath("/home/debian/homespotify-phase45/api/node_modules")

# Chemins dont la suppression est refusée quelle que soit la raison invoquée.
# `/home/debian` y figure explicitement : c'est le parent immédiat de la
# racine de staging, donc l'erreur d'un caractère la plus plausible.
FORBIDDEN_DELETE_TARGETS = frozenset({
    "", "/", "/home", "/home/debian", "/opt", "/var", "/var/lib", "/etc",
    "/usr", "/root", "/boot", "/srv",
})

# Racines du SERVICE : hors périmètre de la Phase 6.2. Les lister ici rend le
# refus explicite plutôt qu'accidentel.
OUT_OF_SCOPE_ROOTS = (RELEASE_ROOT, STATE_ROOT, ENV_FILE)


def staging_directories() -> tuple[PurePosixPath, ...]:
    """Répertoires de staging à créer, dans l'ordre de création."""
    return (
        STAGING_ROOT, RELEASES_DIR, BUNDLES_DIR, DATA_DIR, COVERS_DIR,
        SQLITE_DIR, SECRETS_DIR, REPORTS_DIR, TOOLS_DIR,
    )


class StagingPathError(RuntimeError):
    """Chemin refusé : hors de la racine de staging, ou explicitement protégé."""


def assert_under_staging_root(path: str | PurePosixPath) -> PurePosixPath:
    """Autorise un chemin à être supprimé par le cleanup de staging, ou lève.

    L'ordre des contrôles compte. Les refus absolus (`/`, `/home`,
    `/home/debian`, chemins protégés, racines de service) sont évalués AVANT
    l'appartenance à la racine de staging : une chaîne qui satisferait les
    deux doit être refusée, pas acceptée.
    """
    raw = str(path)
    if raw.strip() in FORBIDDEN_DELETE_TARGETS:
        raise StagingPathError(f"cible interdite : {raw!r}")
    candidate = PurePosixPath(raw)
    if not candidate.is_absolute():
        raise StagingPathError(f"chemin relatif refusé : {candidate}")
    if ".." in candidate.parts:
        raise StagingPathError(f"remontée de répertoire refusée : {candidate}")

    for protected in (*PROTECTED_PATHS, BUNDLE_SOURCE):
        if candidate == protected or protected in candidate.parents:
            raise StagingPathError(f"chemin protégé : {candidate}")
    for out_of_scope in OUT_OF_SCOPE_ROOTS:
        if candidate == out_of_scope or out_of_scope in candidate.parents:
            raise StagingPathError(f"hors périmètre Phase 6.2 : {candidate}")

    if candidate == STAGING_ROOT or STAGING_ROOT in candidate.parents:
        return candidate
    raise StagingPathError(f"hors de la racine de staging : {candidate}")


def release_staging_path(release_id: str) -> PurePosixPath:
    """`releases/<release-id>.staging` — jamais une release promue.

    Le suffixe `.staging` est porté par le NOM du répertoire : impossible de
    confondre un dépôt Phase 6.2 avec une release installée, même en lisant
    un journal hors contexte.
    """
    if "/" in release_id or release_id in ("", ".", ".."):
        raise StagingPathError(f"release-id invalide : {release_id!r}")
    return RELEASES_DIR / f"{release_id}.staging"
