#!/usr/bin/env python3
"""Inventaire et manifeste des pochettes destinées au shadow.

POURQUOI UN MANIFESTE DÉDIÉ
---------------------------
Les pochettes ne sont pas dans l'artefact applicatif : elles sont des DONNÉES,
copiées séparément. Sans manifeste propre, un transfert partiel produirait un
shadow qui affiche 140 pochettes sur 156 — un défaut qui ne se voit pas dans
un statut HTTP, seulement à l'œil, plus tard, sur le téléphone. Le manifeste
rend le transfert vérifiable à l'octet près.

CE QUI EST REFUSÉ, ET POURQUOI
------------------------------
- **Liens symboliques** : un lien peut pointer hors de `COVERS_DIR`, donc
  faire sortir du périmètre un fichier qu'on n'a jamais eu l'intention de
  copier. Refusés, jamais suivis.
- **`..` dans un chemin relatif** : même raison, par une autre porte.
- **Toute extension hors de l'allowlist image** : `COVERS_DIR` de production
  peut contenir un `.db`, un journal ou un `.env` déposé par erreur. Une
  liste noire oublie toujours un cas ; une allowlist ne se trompe que dans le
  sens sûr.

POCHETTES ABSENTES = NO-GO
--------------------------
Un `COVERS_DIR` vide n'est pas « un détail à régler plus tard » : le shadow
qualifie la parité fonctionnelle, et une bibliothèque sans pochette n'est pas
la bibliothèque. `build_cover_manifest()` lève donc `CoversEmptyError`, et
l'appelant doit produire un NO-GO explicite — pas un répertoire vide silencieux.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path, PurePosixPath
from typing import Any

COVER_MANIFEST_NAME = "covers-manifest.json"
COVER_MANIFEST_VERSION = 1

# Allowlist : seules ces extensions entrent dans le shadow.
ALLOWED_SUFFIXES = frozenset({".jpg", ".jpeg", ".png", ".webp", ".avif"})

# Fichiers tolérés dans le répertoire source mais JAMAIS transférés : ils ne
# sont ni une erreur ni une pochette.
IGNORED_NAMES = frozenset({".gitkeep", ".gitignore", "thumbs.db", ".ds_store"})


class CoversError(RuntimeError):
    """Inventaire de pochettes refusé."""


class CoversEmptyError(CoversError):
    """Aucune pochette exploitable : NO-GO fonctionnel, pas un avertissement."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def classify(root: Path) -> tuple[list[tuple[str, Path]], list[str], list[str]]:
    """Trie le contenu de `root` en (retenus, ignorés, refusés).

    Un refus n'est pas fatal ici — il devient une ligne du rapport. Ce qui est
    fatal, c'est qu'il ne reste rien à transférer, ou qu'un lien symbolique
    soit présent : ce dernier signale un `COVERS_DIR` dont la topologie n'est
    pas celle qu'on croit, et il faut l'examiner avant de copier quoi que ce
    soit.
    """
    kept: list[tuple[str, Path]] = []
    ignored: list[str] = []
    refused: list[str] = []

    for path in sorted(root.rglob("*"), key=lambda p: p.as_posix()):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            refused.append(f"LIEN_SYMBOLIQUE {relative}")
            continue
        if not path.is_file():
            continue
        if ".." in PurePosixPath(relative).parts:
            refused.append(f"REMONTEE {relative}")
            continue
        name = path.name.lower()
        if name in IGNORED_NAMES:
            ignored.append(relative)
            continue
        if path.suffix.lower() not in ALLOWED_SUFFIXES:
            refused.append(f"EXTENSION_NON_AUTORISEE {relative}")
            continue
        kept.append((relative, path))
    return kept, ignored, refused


def build_cover_manifest(root: Path) -> dict[str, Any]:
    """Manifeste des pochettes : chemins RELATIFS, taille, SHA-256.

    Aucun chemin absolu n'entre dans le manifeste : il révélerait
    l'organisation du disque de production sans rien apporter à la
    vérification, qui est relative par nature.
    """
    if not root.is_dir():
        raise CoversError(f"répertoire de pochettes absent : {root.name}")
    kept, ignored, refused = classify(root)
    symlinks = [item for item in refused if item.startswith("LIEN_SYMBOLIQUE")]
    if symlinks:
        raise CoversError(f"liens symboliques présents : {len(symlinks)}")
    if not kept:
        raise CoversEmptyError("aucune pochette exploitable")

    entries = [
        {"path": relative, "sizeBytes": path.stat().st_size,
         "sha256": sha256_file(path)}
        for relative, path in kept
    ]
    canonical = json.dumps(
        [[e["path"], e["sizeBytes"], e["sha256"]] for e in entries],
        separators=(",", ":"), ensure_ascii=False,
    )
    return {
        "manifestVersion": COVER_MANIFEST_VERSION,
        "coverFileCount": len(entries),
        "coverBytes": sum(e["sizeBytes"] for e in entries),
        "ignoredCount": len(ignored),
        "refusedCount": len(refused),
        "refused": refused[:20],
        "manifestSha256": hashlib.sha256(canonical.encode("utf-8")).hexdigest(),
        "files": entries,
    }


def verify_cover_manifest(root: Path, manifest: dict[str, Any]) -> list[str]:
    """Écarts entre un répertoire et son manifeste. Liste vide = conforme."""
    problems: list[str] = []
    declared = {e["path"]: e for e in manifest.get("files", [])}
    kept, _, _ = classify(root)
    present = {relative: path for relative, path in kept}

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
    return problems


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Manifeste des pochettes.")
    parser.add_argument("--root", required=True)
    parser.add_argument("--out", help="écrit le manifeste ici")
    parser.add_argument("--verify", action="store_true",
                        help="vérifie --root contre le manifeste de --out")
    args = parser.parse_args()
    root = Path(args.root)

    try:
        if args.verify:
            manifest = json.loads(Path(args.out).read_text(encoding="utf-8"))
            problems = verify_cover_manifest(root, manifest)
            print(json.dumps({
                "ok": not problems,
                "coverFileCount": manifest.get("coverFileCount"),
                "coverBytes": manifest.get("coverBytes"),
                "manifestSha256": manifest.get("manifestSha256"),
                "problemCount": len(problems), "problems": problems[:20],
            }))
            return 0 if not problems else 1

        manifest = build_cover_manifest(root)
    except CoversEmptyError as error:
        # NO-GO explicite : la cause est nommée, elle ne se déduit pas d'un
        # compteur à zéro dans un rapport.
        print(json.dumps({"ok": False, "error": "COVERS_ABSENTES",
                          "verdict": "NO-GO", "detail": str(error)}))
        return 1
    except CoversError as error:
        print(json.dumps({"ok": False, "error": "COVERS_REFUSEES",
                          "detail": str(error)}))
        return 1

    if args.out:
        Path(args.out).write_text(
            json.dumps(manifest, indent=1, ensure_ascii=False), encoding="utf-8")
    print(json.dumps({
        "ok": True, "coverFileCount": manifest["coverFileCount"],
        "coverBytes": manifest["coverBytes"],
        "manifestSha256": manifest["manifestSha256"],
        "ignoredCount": manifest["ignoredCount"],
        "refusedCount": manifest["refusedCount"],
        "refused": manifest["refused"],
    }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
