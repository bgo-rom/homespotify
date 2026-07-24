#!/usr/bin/env python3
"""
Lucida.to Downloader — v9
=========================

Flux reproduit:
1. Recherche du morceau via l'API publique Deezer pour identifier titre/artiste.
2. Saisie dans Lucida avec du texte: "artiste titre" (jamais avec l'URL Deezer).
3. Sélection du service Qobuz avant le clic sur Go.
4. Vérification stricte titre + artiste + album dans les résultats Lucida.
5. Si nécessaire, ouverture de l’album, dépliage de la tracklist et sélection
   exacte de la piste demandée.
6. Clic uniquement sur le contrôle de téléchargement de la piste vérifiée.
7. Détection des erreurs Fetch, timeout et nouvelles tentatives.
8. Vérification finale des métadonnées et de la durée du fichier.

Usage:
  python lucida_dl_final_v9.py "Josman Intro"
  python lucida_dl_final_v9.py "Josman Intro" --visible
  python lucida_dl_final_v9.py "Josman Intro" --index 1
  python lucida_dl_final_v9.py "Josman Intro" --lucida-index 0
  python lucida_dl_final_v9.py "Josman Intro" --list
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import time
import unicodedata
from pathlib import Path
from urllib.parse import quote, unquote, urlparse

try:
    from playwright.sync_api import (
        BrowserContext,
        Locator,
        Page,
        sync_playwright,
    )
except ImportError:
    print(
        "[!] Installe Playwright:\n"
        "    pip install playwright requests\n"
        "    playwright install chromium",
        file=sys.stderr,
    )
    sys.exit(1)

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


BASE_URL = "https://lucida.to"
OUTPUT_DIR = "storage/imports"
AUDIO_EXTENSIONS = (".flac", ".mp3", ".wav", ".ogg", ".m4a", ".opus", ".aac")
ERROR_MARKERS = (
    "an error occurred trying to process your request",
    "try again in a moment",
    "uh-oh!",
    "access denied",
    "verify you are human",
    "checking your browser",
)

DOWNLOAD_FETCH_ERROR_MARKERS = (
    "failed to fetch",
    "fetch failed",
    "fetch error",
    "networkerror when attempting to fetch resource",
    "network request failed",
    "load failed",
    "an error occurred while fetching",
    "an error occurred trying to process your request",
    "try again in a moment",
)


def normalize_text(value: str | None) -> str:
    """Normalisation souple pour comparer titres, artistes et libellés."""
    value = value or ""
    value = unicodedata.normalize("NFKD", value)
    value = "".join(char for char in value if not unicodedata.combining(char))
    value = value.casefold()
    value = re.sub(r"[^a-z0-9]+", " ", value)
    return " ".join(value.split())


def canonical_title(value: str | None) -> str:
    """
    Normalise un titre pour une comparaison stricte.

    Exemples acceptés comme identiques:
    - "1. creeper" et "creeper"
    - "Intro E" et "Intro" lorsque E représente le badge Explicit
    """
    normalized = normalize_text(value)
    normalized = re.sub(r"^\d+\s+", "", normalized)
    normalized = re.sub(r"\s+(?:e|explicit)$", "", normalized)
    return normalized.strip()



def canonical_release_name(value: str | None) -> str:
    """
    Normalise un nom d'album.

    Lucida peut ajouter visuellement un badge Explicit « E », une année,
    ou des préfixes comme « from ». Ces éléments ne font pas partie du nom.
    """
    normalized = normalize_text(value)
    normalized = re.sub(r"^(?:from|album)\s+", "", normalized)
    normalized = re.sub(r"\s+\d{4}$", "", normalized)
    normalized = re.sub(r"\s+(?:e|explicit)$", "", normalized)
    return normalized.strip()


def semantic_lines(value: str | None) -> list[str]:
    """Produit des variantes normalisées des lignes visibles d'une carte."""
    variants: list[str] = []

    for raw_line in (value or "").splitlines():
        line = normalize_text(raw_line)
        if not line:
            continue

        candidates = {
            line,
            re.sub(r"^\d+\s+", "", line),
            re.sub(r"^(?:by|from)\s+", "", line),
            re.sub(r"\s+\d{4}$", "", line),
        }

        for candidate in candidates:
            candidate = candidate.strip()
            if candidate and candidate not in variants:
                variants.append(candidate)

    return variants



def context_has_exact_artist(context: str, artist: str) -> bool:
    expected = normalize_text(artist)
    if not expected:
        return True

    for line in semantic_lines(context):
        cleaned = re.sub(r"^(?:by|artist)\s+", "", line).strip()
        cleaned = re.sub(r"\s+(?:e|explicit)$", "", cleaned).strip()

        if cleaned == expected:
            return True

    return False


def context_has_exact_album(context: str, album: str) -> bool:
    expected = canonical_release_name(album)
    if not expected:
        return True

    return any(
        canonical_release_name(line) == expected
        for line in semantic_lines(context)
    )


def locator_card_text(locator: Locator) -> str:
    """
    Retourne le plus petit parent ressemblant à une carte de résultat.

    Cela évite de comparer avec tout le texte de la page, ce qui avait permis
    à "Midnight Creeper — Luther Allison" de gagner grâce aux sous-chaînes
    "Creeper" et "Luther".
    """
    try:
        value = locator.evaluate(
            """
            (element) => {
                let node = element;
                let fallback = (element.innerText || "").trim();

                for (let level = 0; level < 8 && node; level += 1) {
                    const text = (node.innerText || "").trim();
                    const lines = text
                        .split(/\\r?\\n/)
                        .map((line) => line.trim())
                        .filter(Boolean);

                    if (text) {
                        fallback = text;
                    }

                    if (
                        lines.length >= 2 &&
                        text.length <= 1200 &&
                        !["BODY", "HTML"].includes(node.tagName)
                    ) {
                        return text;
                    }

                    node = node.parentElement;
                }

                return fallback;
            }
            """
        )
        return str(value or "")
    except Exception:
        return ""


def locator_section_name(locator: Locator) -> str:
    """Essaie d'identifier si le résultat se trouve sous Tracks ou Albums."""
    try:
        value = locator.evaluate(
            """
            (element) => {
                const wanted = new Set(["tracks", "albums"]);
                let node = element;

                const normalized = (value) =>
                    (value || "").trim().toLowerCase().replace(/:$/, "");

                while (node && node !== document.body) {
                    let sibling = node.previousElementSibling;

                    while (sibling) {
                        const candidates = [];

                        if (/^H[1-6]$/.test(sibling.tagName)) {
                            candidates.push(sibling);
                        }

                        candidates.push(
                            ...Array.from(
                                sibling.querySelectorAll("h1,h2,h3,h4,h5,h6")
                            )
                        );

                        for (let index = candidates.length - 1; index >= 0; index -= 1) {
                            const label = normalized(candidates[index].innerText);
                            if (wanted.has(label)) {
                                return label;
                            }
                        }

                        const directLabel = normalized(sibling.innerText);
                        if (wanted.has(directLabel)) {
                            return directLabel;
                        }

                        sibling = sibling.previousElementSibling;
                    }

                    node = node.parentElement;
                }

                return "";
            }
            """
        )
        return normalize_text(str(value or ""))
    except Exception:
        return ""


def safe_filename(filename: str) -> str:
    """Nettoie un nom de fichier pour Windows."""
    filename = unquote(filename).strip().strip(".")
    filename = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", filename)
    filename = re.sub(r"\s+", " ", filename).strip()
    return filename[:240] or "track.flac"


def create_session(user_agent: str | None = None) -> requests.Session:
    session = requests.Session()
    session.headers.update(
        {
            "Accept": "*/*",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": f"{BASE_URL}/",
        }
    )
    if user_agent:
        session.headers["User-Agent"] = user_agent

    retry = Retry(
        total=3,
        connect=3,
        read=3,
        backoff_factor=1,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["GET"],
    )
    adapter = HTTPAdapter(max_retries=retry)
    session.mount("https://", adapter)
    session.mount("http://", adapter)
    return session


def search_deezer(query: str, limit: int = 8) -> list[dict]:
    """Recherche publique Deezer utilisée seulement pour identifier le morceau."""
    url = f"https://api.deezer.com/search?q={quote(query)}&limit={limit}"

    try:
        response = create_session().get(url, timeout=20)
        response.raise_for_status()
        payload = response.json()

        results: list[dict] = []
        for track in payload.get("data", []):
            results.append(
                {
                    "title": track.get("title", ""),
                    "title_short": track.get("title_short", "") or track.get("title", ""),
                    "artist_name": track.get("artist", {}).get("name", ""),
                    "album_title": track.get("album", {}).get("title", ""),
                    "duration": int(track.get("duration", 0) or 0),
                }
            )
        return results
    except Exception as exc:
        print(f"  [!] Recherche Deezer indisponible: {exc}", file=sys.stderr)
        return []


def body_contains_error(page: Page) -> str | None:
    try:
        body = page.locator("body").inner_text(timeout=3_000)
    except Exception:
        return None

    normalized = normalize_text(body)
    for marker in ERROR_MARKERS:
        if normalize_text(marker) in normalized:
            return marker
    return None


def save_debug(page: Page, debug_dir: Path, name: str) -> None:
    try:
        page.screenshot(path=str(debug_dir / f"{name}.png"), full_page=True)
    except Exception:
        pass

    try:
        (debug_dir / f"{name}.html").write_text(
            page.content(),
            encoding="utf-8",
        )
    except Exception:
        pass


def locator_label(locator: Locator) -> str:
    """Texte visible ou valeur d'un contrôle."""
    try:
        text = (locator.inner_text(timeout=1_000) or "").strip()
    except Exception:
        text = ""

    if text:
        return text

    for attribute in ("value", "aria-label", "title", "alt"):
        try:
            value = locator.get_attribute(attribute)
        except Exception:
            value = None
        if value:
            return value.strip()

    return ""


def locator_context(locator: Locator) -> str:
    """Récupère le texte des premiers parents afin d'identifier une carte résultat."""
    try:
        value = locator.evaluate(
            """
            (element) => {
                let node = element;
                const chunks = [];
                for (let level = 0; level < 5 && node; level += 1) {
                    const text = (node.innerText || "").trim();
                    if (text && !chunks.includes(text)) {
                        chunks.push(text);
                    }
                    node = node.parentElement;
                }
                return chunks.join("\\n---\\n");
            }
            """
        )
        return str(value or "")
    except Exception:
        return ""



def score_result_candidate(
    own_text: str,
    context_text: str,
    title: str,
    artist: str,
    album: str,
) -> int:
    """
    Compatibilité interne: ne donne désormais des points qu'aux égalités
    strictes. Les simples sous-chaînes ne sont plus acceptées.
    """
    own_title = canonical_title(own_text)
    expected_title = canonical_title(title)
    expected_album = canonical_release_name(album)

    artist_ok = context_has_exact_artist(context_text, artist)
    album_ok = context_has_exact_album(context_text, album)

    if own_title == expected_title and artist_ok and album_ok:
        return 1000

    if (
        expected_album
        and canonical_release_name(own_text) == expected_album
        and artist_ok
    ):
        return 900

    return -10_000



def find_lucida_result(
    page: Page,
    title: str,
    artist: str,
    album: str,
    forced_index: int | None,
) -> dict | None:
    """
    Sélection sûre du résultat Lucida.

    Priorité:
    1. Une piste dont le titre, l'artiste ET l'album correspondent exactement.
    2. Sinon, l'album exact de l'artiste exact. La piste sera ensuite choisie
       dans sa tracklist.

    Une correspondance partielle comme:
      cible:  Creeper — Luther
      trouvé: Midnight Creeper — Luther Allison
    est obligatoirement refusée.
    """
    expected_title = canonical_title(title)
    expected_album = canonical_release_name(album)

    clickables = page.locator(
        'a:visible, button:visible, [role="button"]:visible'
    )
    count = min(clickables.count(), 500)

    exact_tracks: list[dict] = []
    exact_albums: list[dict] = []
    diagnostics: list[tuple[str, str, str]] = []

    for index in range(count):
        candidate = clickables.nth(index)

        try:
            if not candidate.is_visible():
                continue
        except Exception:
            continue

        own_text = locator_label(candidate)
        own_title = canonical_title(own_text)
        own_album = canonical_release_name(own_text)

        if not own_title:
            continue

        context = locator_card_text(candidate)
        section = locator_section_name(candidate)
        artist_ok = context_has_exact_artist(context, artist)
        album_ok = context_has_exact_album(context, album)

        # Conserver quelques résultats proches uniquement pour le diagnostic.
        if (
            expected_title
            and (
                expected_title in own_title
                or own_title in expected_title
            )
        ):
            diagnostics.append((own_text, section, context))

        is_exact_track = (
            own_title == expected_title
            and artist_ok
            and album_ok
            and section != "albums"
        )

        is_exact_album = (
            bool(expected_album)
            and own_album == expected_album
            and artist_ok
            and section != "tracks"
        )

        if is_exact_track:
            exact_tracks.append(
                {
                    "kind": "track",
                    "locator": candidate,
                    "label": own_text,
                    "context": context,
                    "section": section,
                }
            )

        if is_exact_album:
            exact_albums.append(
                {
                    "kind": "album",
                    "locator": candidate,
                    "label": own_text,
                    "context": context,
                    "section": section,
                }
            )

    # Dédupliquer les mêmes cartes/ancres.
    def deduplicate(items: list[dict]) -> list[dict]:
        unique: list[dict] = []
        seen: set[str] = set()

        for item in items:
            key = (
                f"{item['kind']}|"
                f"{normalize_text(item['label'])}|"
                f"{normalize_text(item['context'])[:600]}"
            )
            if key in seen:
                continue
            seen.add(key)
            unique.append(item)

        return unique

    exact_tracks = deduplicate(exact_tracks)
    exact_albums = deduplicate(exact_albums)
    verified = exact_tracks + exact_albums

    print("  [VÉRIFICATION] Cible attendue:", file=sys.stderr)
    print(f"      Titre   : {title!r}", file=sys.stderr)
    print(f"      Artiste : {artist!r}", file=sys.stderr)
    print(f"      Album   : {album!r}", file=sys.stderr)
    print(
        f"      Correspondances exactes: "
        f"{len(exact_tracks)} piste(s), {len(exact_albums)} album(s)",
        file=sys.stderr,
    )

    for position, item in enumerate(verified[:10]):
        compact = " | ".join(
            line.strip()
            for line in item["context"].splitlines()
            if line.strip()
        )
        print(
            f"      [{position}] {item['kind'].upper()} "
            f"{item['label']!r} — {compact[:220]!r}",
            file=sys.stderr,
        )

    if not verified:
        print(
            "  [!] Aucune correspondance EXACTE. "
            "Le téléchargement est annulé pour éviter le mauvais morceau.",
            file=sys.stderr,
        )

        if diagnostics:
            print(
                "  [~] Résultats ressemblants refusés:",
                file=sys.stderr,
            )
            for own, section, context in diagnostics[:8]:
                compact = " | ".join(
                    line.strip()
                    for line in context.splitlines()
                    if line.strip()
                )
                print(
                    f"      - section={section or '?'} "
                    f"élément={own!r} carte={compact[:180]!r}",
                    file=sys.stderr,
                )

        return None

    if forced_index is not None:
        if forced_index < 0 or forced_index >= len(verified):
            print(
                f"  [!] --lucida-index {forced_index} invalide: "
                f"{len(verified)} résultat(s) exact(s).",
                file=sys.stderr,
            )
            return None
        selected = verified[forced_index]
    else:
        # Une piste exacte gagne toujours. À défaut, on ouvre l'album exact.
        selected = verified[0]

    print(
        f"  [VÉRIFICATION] Résultat retenu: "
        f"{selected['kind']} {selected['label']!r}",
        file=sys.stderr,
    )
    return selected


def wait_for_search_results(
    page: Page,
    title: str,
    artist: str,
    timeout_seconds: int = 90,
) -> bool:
    deadline = time.monotonic() + timeout_seconds
    title_n = normalize_text(title)
    artist_n = normalize_text(artist)
    previous = ""

    while time.monotonic() < deadline:
        error = body_contains_error(page)
        if error:
            print(f"  [!] Lucida affiche une erreur: {error}", file=sys.stderr)
            return False

        try:
            body = page.locator("body").inner_text(timeout=3_000)
        except Exception:
            page.wait_for_timeout(1_000)
            continue

        body_n = normalize_text(body)
        has_title = not title_n or title_n in body_n
        has_artist = not artist_n or artist_n in body_n
        has_results_heading = "tracks" in body_n or "results" in body_n

        if has_title and has_artist and has_results_heading:
            return True

        if body_n != previous:
            print(
                f"  [~] Recherche Lucida en cours: {body[-250:]!r}",
                file=sys.stderr,
            )
            previous = body_n

        page.wait_for_timeout(1_000)

    print("  [!] Délai dépassé en attendant les résultats Lucida.", file=sys.stderr)
    return False



def wait_for_media_page(
    page: Page,
    selection_kind: str,
    timeout_seconds: int = 60,
) -> bool:
    """Attend soit une fiche piste, soit une fiche album."""
    deadline = time.monotonic() + timeout_seconds

    while time.monotonic() < deadline:
        error = body_contains_error(page)
        if error:
            print(f"  [!] Lucida affiche une erreur: {error}", file=sys.stderr)
            return False

        try:
            body_n = normalize_text(
                page.locator("body").inner_text(timeout=3_000)
            )
        except Exception:
            page.wait_for_timeout(1_000)
            continue

        if selection_kind == "track" and "download track" in body_n:
            return True

        if (
            selection_kind == "album"
            and "tracklist" in body_n
            and "download full album" in body_n
        ):
            return True

        page.wait_for_timeout(1_000)

    expected = (
        "download track"
        if selection_kind == "track"
        else "tracklist + download full album"
    )
    print(
        f"  [!] La fiche n'a pas affiché {expected!r}.",
        file=sys.stderr,
    )
    return False


def select_search_service(page: Page, service_name: str = "Qobuz") -> bool:
    """
    Sélectionne le service de recherche avant le clic sur Go.

    Lucida contient plusieurs listes déroulantes (service, région, langue).
    On parcourt donc les options de chaque select et on ne modifie que celui
    qui possède réellement l'option demandée.
    """
    wanted = normalize_text(service_name)
    selects = page.locator("select:visible")

    print(
        f"  [~] Recherche du service {service_name!r} "
        f"dans {selects.count()} liste(s) déroulante(s)...",
        file=sys.stderr,
    )

    for select_index in range(selects.count()):
        select = selects.nth(select_index)

        try:
            options = select.locator("option")
            option_descriptions: list[str] = []

            for option_index in range(options.count()):
                option = options.nth(option_index)
                label = (option.inner_text(timeout=1_000) or "").strip()
                value = (option.get_attribute("value") or "").strip()
                option_descriptions.append(label or value)

                if wanted not in (
                    normalize_text(label),
                    normalize_text(value),
                ):
                    continue

                if value:
                    select.select_option(value=value)
                else:
                    select.select_option(label=label)

                # Vérifier ce que le navigateur a réellement sélectionné.
                selected_label = select.locator("option:checked").inner_text(
                    timeout=2_000
                ).strip()

                print(
                    f"  [~] Service sélectionné: {selected_label} "
                    f"(select #{select_index})",
                    file=sys.stderr,
                )
                return normalize_text(selected_label) == wanted

            print(
                f"      select #{select_index}: "
                f"{', '.join(option_descriptions[:20])}",
                file=sys.stderr,
            )
        except Exception as exc:
            print(
                f"      select #{select_index}: lecture impossible ({exc})",
                file=sys.stderr,
            )

    print(
        f"  [!] Le service {service_name!r} est introuvable dans les options.",
        file=sys.stderr,
    )
    return False


def select_original_quality(page: Page) -> None:
    """Sélectionne 'Original format (highest quality)' quand cette option existe."""
    selects = page.locator("select:visible")

    for index in range(selects.count()):
        select = selects.nth(index)

        try:
            options = select.locator("option")
            for option_index in range(options.count()):
                option = options.nth(option_index)
                label = (option.inner_text() or "").strip()
                label_n = normalize_text(label)

                if "original format" in label_n or "highest quality" in label_n:
                    value = option.get_attribute("value")
                    if value is not None:
                        select.select_option(value=value)
                    else:
                        select.select_option(label=label)

                    print(
                        f"  [~] Qualité sélectionnée: {label}",
                        file=sys.stderr,
                    )
                    return
        except Exception:
            continue



def find_download_track_control(page: Page) -> Locator | None:
    """Bouton global exact d'une fiche de piste."""
    controls = page.locator(
        'button:visible, a:visible, input[type="submit"]:visible, '
        'input[type="button"]:visible, [role="button"]:visible'
    )

    for index in range(controls.count()):
        control = controls.nth(index)
        label = normalize_text(locator_label(control))

        if label == "download track":
            return control

    return None


def find_download_full_album_control(page: Page) -> Locator | None:
    """Trouve le bouton global de la fiche album, utilisé pour vérifier la carte."""
    controls = page.locator(
        'button:visible, a:visible, input[type="submit"]:visible, '
        'input[type="button"]:visible, [role="button"]:visible'
    )

    for index in range(controls.count()):
        control = controls.nth(index)
        if normalize_text(locator_label(control)) == "download full album":
            return control

    return None



def page_identity_lines(page: Page) -> list[str]:
    """
    Lit les lignes sémantiques de la fiche entière.

    La v8 inspectait uniquement le petit parent HTML du bouton
    « download full album ». Sur Lucida, ce parent ne contient que le bouton,
    tandis que le titre et l'artiste se trouvent dans un autre bloc au-dessus.
    """
    try:
        body_text = page.locator("body").inner_text(timeout=5_000)
    except Exception:
        return []

    return semantic_lines(body_text)


def exact_line_matches(
    lines: list[str],
    expected: str,
    normalizer,
) -> list[str]:
    expected_normalized = normalizer(expected)
    if not expected_normalized:
        return []

    return [
        line
        for line in lines
        if normalizer(line) == expected_normalized
    ]



def verify_track_page_identity(
    page: Page,
    title: str,
    artist: str,
    album: str,
) -> bool:
    """
    Vérifie la fiche piste avec le texte de la page entière.

    On exige des lignes exactes, pas de simples sous-chaînes.
    """
    if find_download_track_control(page) is None:
        return False

    lines = page_identity_lines(page)
    title_matches = exact_line_matches(lines, title, canonical_title)
    artist_matches = [
        line
        for line in lines
        if re.sub(
            r"^(?:by|artist)\s+",
            "",
            normalize_text(line),
        ).strip() == normalize_text(artist)
    ]
    album_matches = exact_line_matches(
        lines,
        album,
        canonical_release_name,
    )

    title_ok = bool(title_matches)
    artist_ok = bool(artist_matches)
    album_ok = not album or bool(album_matches)

    print(
        f"  [VÉRIFICATION FICHE PISTE] "
        f"titre={title_ok}, artiste={artist_ok}, album={album_ok}",
        file=sys.stderr,
    )
    print(
        f"      lignes titre={title_matches[:3]!r}",
        file=sys.stderr,
    )
    print(
        f"      lignes artiste={artist_matches[:3]!r}",
        file=sys.stderr,
    )
    print(
        f"      lignes album={album_matches[:3]!r}",
        file=sys.stderr,
    )

    return title_ok and artist_ok and album_ok



def verify_album_page_identity(
    page: Page,
    artist: str,
    album: str,
) -> bool:
    """
    Vérifie la fiche album à partir de toute la page.

    Important: le titre/artiste de l'album et le bouton
    « download full album » ne sont pas dans le même petit conteneur HTML.
    """
    if find_download_full_album_control(page) is None:
        print(
            "  [VÉRIFICATION FICHE ALBUM] "
            "bouton « download full album » absent",
            file=sys.stderr,
        )
        return False

    lines = page_identity_lines(page)
    album_matches = exact_line_matches(
        lines,
        album,
        canonical_release_name,
    )
    artist_matches = [
        line
        for line in lines
        if re.sub(
            r"^(?:by|artist)\s+",
            "",
            normalize_text(line),
        ).strip() == normalize_text(artist)
    ]

    try:
        body_normalized = normalize_text(
            page.locator("body").inner_text(timeout=5_000)
        )
    except Exception:
        body_normalized = ""

    album_ok = bool(album_matches)
    artist_ok = bool(artist_matches)
    structure_ok = (
        "tracklist" in body_normalized
        and "download full album" in body_normalized
    )

    print(
        f"  [VÉRIFICATION FICHE ALBUM] "
        f"album={album_ok}, artiste={artist_ok}, structure={structure_ok}",
        file=sys.stderr,
    )
    print(
        f"      lignes album={album_matches[:3]!r}",
        file=sys.stderr,
    )
    print(
        f"      lignes artiste={artist_matches[:3]!r}",
        file=sys.stderr,
    )

    return album_ok and artist_ok and structure_ok



def expand_tracklist(page: Page) -> bool:
    """Ouvre la section tracklist et confirme qu'elle contient des pistes."""
    controls = page.locator(
        'summary:visible, button:visible, [role="button"]:visible, '
        'a:visible'
    )

    tracklist_control = None

    for index in range(controls.count()):
        control = controls.nth(index)
        label = normalize_text(locator_label(control))

        if label == "tracklist":
            tracklist_control = control
            break

    if tracklist_control is not None:
        try:
            # Pour <summary>, le parent <details open> indique l'état.
            tag_name = tracklist_control.evaluate(
                "(element) => element.tagName.toLowerCase()"
            )
            already_open = False

            if tag_name == "summary":
                already_open = bool(
                    tracklist_control.evaluate(
                        "(element) => element.parentElement?.open === true"
                    )
                )

            if not already_open:
                print("  [~] Ouverture de la tracklist...", file=sys.stderr)
                tracklist_control.click(timeout=10_000)

        except Exception as exc:
            print(
                f"  [~] Clic tracklist non confirmé ({exc}); "
                "vérification du contenu...",
                file=sys.stderr,
            )

    deadline = time.monotonic() + 15

    while time.monotonic() < deadline:
        try:
            body = page.locator("body").inner_text(timeout=3_000)
        except Exception:
            page.wait_for_timeout(500)
            continue

        lines = semantic_lines(body)

        # Une ligne numérotée suivie d'un titre indique une tracklist ouverte.
        has_numbered_track = any(
            re.match(r"^\d+\s+\S+", line)
            for line in lines
        )

        if has_numbered_track:
            print(
                "  [~] Tracklist ouverte et pistes visibles.",
                file=sys.stderr,
            )
            return True

        page.wait_for_timeout(500)

    print(
        "  [!] La section tracklist n'a pas affiché ses pistes.",
        file=sys.stderr,
    )
    return False


def find_album_track_row(page: Page, title: str) -> Locator | None:
    """Trouve le plus petit conteneur correspondant exactement à la piste."""
    expected = canonical_title(title)
    rows = page.locator(
        'li:visible, tr:visible, [role="row"]:visible, '
        'div:visible, p:visible'
    )

    candidates: list[tuple[int, int, Locator, str]] = []
    count = min(rows.count(), 1600)

    for index in range(count):
        row = rows.nth(index)

        try:
            row_text = (row.inner_text(timeout=700) or "").strip()
        except Exception:
            continue

        if not row_text or len(row_text) > 500:
            continue

        lines = semantic_lines(row_text)
        exact_line = any(canonical_title(line) == expected for line in lines)
        if not exact_line:
            continue

        controls_count = row.locator(
            'a, button, [role="button"], input[type="button"], '
            'input[type="submit"]'
        ).count()
        if controls_count == 0:
            continue

        # Le conteneur le plus petit est normalement la ligne de la piste,
        # pas tout le bloc tracklist.
        candidates.append((len(row_text), index, row, row_text))

    if not candidates:
        return None

    candidates.sort(key=lambda item: (item[0], item[1]))
    chosen = candidates[0]

    print(
        f"  [VÉRIFICATION TRACKLIST] Ligne exacte trouvée: "
        f"{chosen[3]!r}",
        file=sys.stderr,
    )
    return chosen[2]


def describe_control(control: Locator) -> dict:
    """Informations utiles pour reconnaître l'icône de téléchargement."""
    data: dict[str, str | None] = {}

    for attribute in (
        "href",
        "download",
        "title",
        "aria-label",
        "class",
        "data-tooltip",
    ):
        try:
            data[attribute] = control.get_attribute(attribute)
        except Exception:
            data[attribute] = None

    data["label"] = locator_label(control)

    try:
        data["html"] = control.inner_html(timeout=800)[:500]
    except Exception:
        data["html"] = ""

    return data


def find_row_download_control(row: Locator, title: str) -> Locator | None:
    """
    Trouve uniquement l'icône Download située dans la ligne exacte de la piste.

    Le bouton "download full album" est impossible à sélectionner car la
    recherche est limitée au conteneur de la piste.
    """
    expected_title = canonical_title(title)
    controls = row.locator(
        'a:visible, button:visible, [role="button"]:visible, '
        'input[type="button"]:visible, input[type="submit"]:visible'
    )

    scored: list[tuple[int, int, Locator, dict]] = []
    fallback: list[tuple[int, Locator, dict]] = []

    for index in range(controls.count()):
        control = controls.nth(index)
        info = describe_control(control)

        label = normalize_text(str(info.get("label") or ""))
        title_attr = normalize_text(str(info.get("title") or ""))
        aria = normalize_text(str(info.get("aria-label") or ""))
        class_name = normalize_text(str(info.get("class") or ""))
        html = normalize_text(str(info.get("html") or ""))
        href = str(info.get("href") or "")
        href_n = normalize_text(href)
        download_attr = info.get("download")

        # Ne jamais cliquer sur le titre lui-même.
        if canonical_title(label) == expected_title:
            continue

        # Rejeter les liens externes vers Qobuz/Deezer/etc.
        external_service = any(
            domain in href.lower()
            for domain in (
                "qobuz.com",
                "deezer.com",
                "spotify.com",
                "tidal.com",
                "soundcloud.com",
                "amazon.",
                "music.yandex.",
            )
        )
        if external_service:
            continue

        combined = " ".join(
            value
            for value in (
                label,
                title_attr,
                aria,
                class_name,
                html,
                href_n,
            )
            if value
        )

        score = 0
        if download_attr is not None:
            score += 500
        if "download" in combined:
            score += 350
        if any(
            marker in combined
            for marker in (
                "arrow down",
                "arrowdown",
                "down arrow",
                "fa download",
                "icon download",
                "download icon",
            )
        ):
            score += 250
        if "download" in href_n:
            score += 200

        if any(word in combined for word in ("external", "copy link", "permalink")):
            score -= 400

        if score > 0:
            scored.append((score, index, control, info))
        else:
            # L'icône Download est généralement le premier contrôle interne
            # immédiatement après le titre de la piste.
            fallback.append((index, control, info))

    if scored:
        scored.sort(key=lambda item: (-item[0], item[1]))
        chosen = scored[0]
        print(
            f"  [VÉRIFICATION TRACKLIST] Contrôle Download identifié: "
            f"{chosen[3]}",
            file=sys.stderr,
        )
        return chosen[2]

    if fallback:
        # Fallback prudent: premier contrôle interne non externe de la ligne.
        chosen = fallback[0]
        print(
            f"  [VÉRIFICATION TRACKLIST] Icône sans libellé; "
            f"premier contrôle interne retenu: {chosen[2]}",
            file=sys.stderr,
        )
        return chosen[1]

    return None


def find_album_track_download_control(
    page: Page,
    title: str,
) -> Locator | None:
    if not expand_tracklist(page):
        print("  [!] Impossible d'ouvrir la tracklist.", file=sys.stderr)
        return None

    deadline = time.monotonic() + 15

    while time.monotonic() < deadline:
        row = find_album_track_row(page, title)
        if row is not None:
            control = find_row_download_control(row, title)
            if control is not None:
                return control

        page.wait_for_timeout(750)

    print(
        f"  [!] Piste exacte {title!r} introuvable dans la tracklist.",
        file=sys.stderr,
    )
    return None


def find_verified_download_control(
    page: Page,
    selection_kind: str,
    title: str,
    artist: str,
    album: str,
) -> Locator | None:
    """
    Retourne un contrôle seulement après validation complète de l'identité.
    """
    select_original_quality(page)

    if selection_kind == "track":
        if not verify_track_page_identity(page, title, artist, album):
            print(
                "  [!] L'identité de la fiche piste ne correspond pas. "
                "Téléchargement bloqué.",
                file=sys.stderr,
            )
            return None
        return find_download_track_control(page)

    if selection_kind == "album":
        if not verify_album_page_identity(page, artist, album):
            print(
                "  [!] L'identité de la fiche album ne correspond pas. "
                "Téléchargement bloqué.",
                file=sys.stderr,
            )
            return None
        return find_album_track_download_control(page, title)

    return None


def detect_download_fetch_error(page: Page) -> str | None:
    """Détecte les messages d'erreur réseau affichés dans la page."""
    try:
        body = page.locator("body").inner_text(timeout=2_000)
    except Exception:
        return None

    body_normalized = normalize_text(body)
    for marker in DOWNLOAD_FETCH_ERROR_MARKERS:
        if normalize_text(marker) in body_normalized:
            return marker

    return None


def wait_for_download_attempt(
    page: Page,
    attempt_state: dict,
    timeout_seconds: int,
) -> tuple[str, object | None]:
    """
    Attend sans bloquer aveuglément pendant plusieurs minutes.

    Résultats:
    - ("download", Download)
    - ("fetch_error", message)
    - ("timeout", None)
    """
    deadline = time.monotonic() + timeout_seconds

    while time.monotonic() < deadline:
        download = attempt_state.get("download")
        if download is not None:
            return "download", download

        fetch_error = attempt_state.get("fetch_error")
        if fetch_error:
            return "fetch_error", str(fetch_error)

        page_error = detect_download_fetch_error(page)
        if page_error:
            return "fetch_error", page_error

        page.wait_for_timeout(1_000)

    return "timeout", None



def prepare_download_retry(
    page: Page,
    debug_dir: Path,
    attempt: int,
    selection_kind: str,
    title: str,
    artist: str,
    album: str,
) -> bool:
    """Prépare une nouvelle tentative sans perdre la piste vérifiée."""
    save_debug(page, debug_dir, f"download_attempt_{attempt}_failed")

    try:
        page.keyboard.press("Escape")
    except Exception:
        pass

    try:
        page.evaluate("window.stop()")
    except Exception:
        pass

    page.wait_for_timeout(2_500)

    control = find_verified_download_control(
        page,
        selection_kind,
        title,
        artist,
        album,
    )
    if control is not None:
        return True

    print(
        "  [~] Le contrôle vérifié a disparu; rechargement de la fiche...",
        file=sys.stderr,
    )

    try:
        page.reload(wait_until="domcontentloaded", timeout=60_000)
    except Exception as exc:
        print(f"  [!] Rechargement impossible: {exc}", file=sys.stderr)
        return False

    if not wait_for_media_page(
        page,
        selection_kind=selection_kind,
        timeout_seconds=60,
    ):
        return False

    return find_verified_download_control(
        page,
        selection_kind,
        title,
        artist,
        album,
    ) is not None


def download_with_cookies(
    url: str,
    cookies: list[dict],
    user_agent: str,
    output_dir: Path,
    fallback_filename: str,
) -> str | None:
    """Fallback HTTP utilisant la même session logique que le navigateur."""
    output_dir.mkdir(parents=True, exist_ok=True)
    destination = output_dir / safe_filename(fallback_filename)

    try:
        session = create_session(user_agent=user_agent)

        for cookie in cookies:
            session.cookies.set(
                cookie["name"],
                cookie["value"],
                domain=cookie.get("domain") or None,
                path=cookie.get("path") or "/",
            )

        response = session.get(
            url,
            stream=True,
            timeout=300,
            allow_redirects=True,
        )
        response.raise_for_status()

        content_type = response.headers.get("content-type", "").lower()
        if "text/html" in content_type or "application/json" in content_type:
            raise RuntimeError(
                f"La réponse n'est pas un fichier audio ({content_type})."
            )

        disposition = response.headers.get("content-disposition", "")
        filename_match = re.search(
            r"""filename\*?=(?:UTF-8''|["'])?([^;"']+)""",
            disposition,
            flags=re.IGNORECASE,
        )
        if filename_match:
            destination = output_dir / safe_filename(filename_match.group(1))

        total = int(response.headers.get("content-length", "0") or 0)
        downloaded = 0

        with destination.open("wb") as file_handle:
            for chunk in response.iter_content(chunk_size=1024 * 256):
                if not chunk:
                    continue
                file_handle.write(chunk)
                downloaded += len(chunk)

                if total:
                    percent = downloaded / total * 100
                    print(
                        f"  [~] {percent:5.1f}% "
                        f"({downloaded / 1024 / 1024:.1f}/"
                        f"{total / 1024 / 1024:.1f} Mo)",
                        end="\r",
                        file=sys.stderr,
                    )

        print(file=sys.stderr)
        print(
            f"  [~] Téléchargé: {destination.name} "
            f"({destination.stat().st_size / 1024 / 1024:.1f} Mo)",
            file=sys.stderr,
        )
        return str(destination)

    except Exception as exc:
        print(f"  [!] Échec du fallback HTTP: {exc}", file=sys.stderr)
        if destination.exists():
            destination.unlink()
        return None


def download_from_lucida(
    search_query: str,
    target_title: str,
    target_artist: str,
    target_album: str,
    output_dir: str,
    visible: bool,
    lucida_index: int | None,
    search_service: str = "Qobuz",
    download_timeout_seconds: int = 75,
    download_retries: int = 2,
    target_duration: int = 0,
) -> str | None:
    output_path = Path(output_dir)
    debug_dir = output_path / "debug"
    output_path.mkdir(parents=True, exist_ok=True)
    debug_dir.mkdir(parents=True, exist_ok=True)

    print(
        f"  [~] Recherche envoyée à Lucida: {search_query!r}",
        file=sys.stderr,
    )

    captured_audio_urls: list[str] = []

    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(
                headless=not visible,
            )
            context: BrowserContext = browser.new_context(
                viewport={"width": 1440, "height": 1000},
                locale="en-US",
                accept_downloads=True,
            )
            page = context.new_page()
            page.set_default_timeout(10_000)

            # État de la tentative de téléchargement en cours. Les callbacks
            # réseau et console peuvent ainsi interrompre rapidement l'attente.
            download_attempt_state = {
                "active": False,
                "download": None,
                "fetch_error": None,
            }

            def on_download(download) -> None:
                if download_attempt_state["active"]:
                    download_attempt_state["download"] = download

            def on_console(message) -> None:
                if "[i18n]: 'my' locale is non-standard." in message.text:
                    return

                message_text = message.text or ""
                message_normalized = normalize_text(message_text)

                if (
                    download_attempt_state["active"]
                    and message.type == "error"
                    and any(
                        normalize_text(marker) in message_normalized
                        for marker in DOWNLOAD_FETCH_ERROR_MARKERS
                    )
                ):
                    download_attempt_state["fetch_error"] = (
                        f"Console: {message_text}"
                    )

                if message.type in ("error", "warning"):
                    print(
                        f"  [CONSOLE] {message.type}: {message_text}",
                        file=sys.stderr,
                    )

            def on_request_failed(request) -> None:
                if "/cdn-cgi/rum" in request.url:
                    return

                failure = request.failure or "échec réseau inconnu"
                print(
                    f"  [REQ FAIL] {request.method} {request.url} "
                    f"— {failure}",
                    file=sys.stderr,
                )

                if (
                    download_attempt_state["active"]
                    and request.resource_type in ("xhr", "fetch")
                    and "/api/stats/recent-download" not in request.url
                ):
                    download_attempt_state["fetch_error"] = (
                        f"{request.resource_type.upper()} "
                        f"{request.method} {request.url}: {failure}"
                    )

            def on_response(response) -> None:
                url = response.url
                path = urlparse(url).path.lower()
                content_type = response.headers.get("content-type", "").lower()
                disposition = response.headers.get(
                    "content-disposition",
                    "",
                ).lower()

                audio_url = any(path.endswith(ext) for ext in AUDIO_EXTENSIONS)
                audio_type = content_type.startswith("audio/")
                audio_attachment = (
                    "attachment" in disposition
                    and any(ext in disposition for ext in AUDIO_EXTENSIONS)
                )

                if audio_url or audio_type or audio_attachment:
                    if url not in captured_audio_urls:
                        captured_audio_urls.append(url)
                        print(
                            f"  [~] URL audio détectée: {url[:160]}",
                            file=sys.stderr,
                        )

                if (
                    download_attempt_state["active"]
                    and response.request.resource_type in ("xhr", "fetch")
                    and response.status >= 400
                    and "/api/stats/recent-download" not in url
                ):
                    download_attempt_state["fetch_error"] = (
                        f"HTTP {response.status} sur "
                        f"{response.request.resource_type.upper()} {url}"
                    )

            page.on("download", on_download)
            page.on("console", on_console)
            page.on("requestfailed", on_request_failed)
            page.on("response", on_response)

            print(f"  [1/6] Ouverture de {BASE_URL}...", file=sys.stderr)
            response = page.goto(
                BASE_URL,
                wait_until="domcontentloaded",
                timeout=60_000,
            )

            status = response.status if response else None
            print(
                f"  [HTTP] {status} — {page.url}",
                file=sys.stderr,
            )

            if status is not None and status >= 400:
                save_debug(page, debug_dir, "http_error")
                browser.close()
                return None

            page.wait_for_timeout(2_000)
            save_debug(page, debug_dir, "01_home")

            search_input = page.locator(
                'input#download, input[name="url"], '
                'input[placeholder*="search" i], '
                'input[placeholder*="URL" i]'
            ).first
            go_button = page.locator(
                'input#go, input[type="submit"], '
                'button[type="submit"], button:has-text("Go")'
            ).first

            if not search_input.count() or not search_input.is_visible():
                print("  [!] Champ de recherche Lucida introuvable.", file=sys.stderr)
                save_debug(page, debug_dir, "no_search_input")
                browser.close()
                return None

            if not go_button.count() or not go_button.is_visible():
                print("  [!] Bouton Go de Lucida introuvable.", file=sys.stderr)
                save_debug(page, debug_dir, "no_go_button")
                browser.close()
                return None

            print("  [2/6] Saisie de la recherche texte...", file=sys.stderr)
            search_input.fill(search_query)

            print(
                f"  [3/6] Sélection du service {search_service}...",
                file=sys.stderr,
            )
            if not select_search_service(page, search_service):
                save_debug(page, debug_dir, "service_not_found")
                browser.close()
                return None

            save_debug(page, debug_dir, "02_search_ready")

            print("  [4/6] Clic sur Go et attente des résultats...", file=sys.stderr)
            go_button.click()

            if not wait_for_search_results(
                page,
                title=target_title,
                artist=target_artist,
                timeout_seconds=90,
            ):
                save_debug(page, debug_dir, "search_failed")
                browser.close()
                return None

            save_debug(page, debug_dir, "03_results")

            print("  [5/6] Vérification stricte du résultat...", file=sys.stderr)
            selection = find_lucida_result(
                page=page,
                title=target_title,
                artist=target_artist,
                album=target_album,
                forced_index=lucida_index,
            )

            if selection is None:
                save_debug(page, debug_dir, "no_exact_matching_result")
                browser.close()
                return None

            selection_kind = selection["kind"]
            selection["locator"].click(timeout=15_000)

            if not wait_for_media_page(
                page,
                selection_kind=selection_kind,
                timeout_seconds=60,
            ):
                save_debug(page, debug_dir, "media_page_failed")
                browser.close()
                return None

            save_debug(page, debug_dir, f"04_{selection_kind}")

            print(
                f"  [6/6] Téléchargement vérifié via "
                f"{'la fiche piste' if selection_kind == 'track' else 'la tracklist de l’album'}...",
                file=sys.stderr,
            )

            total_attempts = max(1, download_retries + 1)

            for attempt in range(1, total_attempts + 1):
                download_control = find_verified_download_control(
                    page,
                    selection_kind,
                    target_title,
                    target_artist,
                    target_album,
                )
                if download_control is None:
                    print(
                        "  [!] Contrôle de téléchargement vérifié introuvable.",
                        file=sys.stderr,
                    )

                    if (
                        attempt < total_attempts
                        and prepare_download_retry(
                            page,
                            debug_dir,
                            attempt,
                            selection_kind,
                            target_title,
                            target_artist,
                            target_album,
                        )
                    ):
                        continue

                    save_debug(page, debug_dir, "no_download_track")
                    break

                captured_audio_urls.clear()
                download_attempt_state["active"] = True
                download_attempt_state["download"] = None
                download_attempt_state["fetch_error"] = None

                print(
                    f"  [~] Tentative de téléchargement "
                    f"{attempt}/{total_attempts} "
                    f"(timeout {download_timeout_seconds}s)...",
                    file=sys.stderr,
                )

                try:
                    download_control.click(timeout=15_000)
                except Exception as exc:
                    download_attempt_state["active"] = False
                    reason = f"clic impossible: {exc}"
                    outcome = "click_error"
                    payload = reason
                else:
                    outcome, payload = wait_for_download_attempt(
                        page=page,
                        attempt_state=download_attempt_state,
                        timeout_seconds=download_timeout_seconds,
                    )
                    download_attempt_state["active"] = False

                if outcome == "download":
                    download = payload
                    filename = safe_filename(
                        download.suggested_filename
                        or f"{target_artist} - {target_title}.flac"
                    )
                    destination = output_path / filename
                    download.save_as(destination)

                    if not verify_downloaded_file(
                        str(destination),
                        target_title,
                        target_artist,
                        target_album,
                        target_duration,
                    ):
                        save_debug(
                            page,
                            debug_dir,
                            "downloaded_file_identity_mismatch",
                        )
                        browser.close()
                        return None

                    size = destination.stat().st_size
                    print(
                        f"  [~] Téléchargé et vérifié: {destination.name} "
                        f"({size / 1024 / 1024:.1f} Mo)",
                        file=sys.stderr,
                    )
                    browser.close()
                    return str(destination)

                if outcome == "fetch_error":
                    print(
                        f"  [!] Erreur Fetch détectée: {payload}",
                        file=sys.stderr,
                    )
                elif outcome == "timeout":
                    print(
                        f"  [!] Aucun téléchargement après "
                        f"{download_timeout_seconds}s.",
                        file=sys.stderr,
                    )
                else:
                    print(f"  [!] {payload}", file=sys.stderr)

                if attempt < total_attempts:
                    delay_seconds = min(3 * attempt, 8)
                    print(
                        f"  [~] Nouvelle tentative automatique dans "
                        f"{delay_seconds}s...",
                        file=sys.stderr,
                    )
                    page.wait_for_timeout(delay_seconds * 1_000)

                    if not prepare_download_retry(
                        page,
                        debug_dir,
                        attempt,
                        selection_kind,
                        target_title,
                        target_artist,
                        target_album,
                    ):
                        print(
                            "  [!] Impossible de préparer la nouvelle tentative.",
                            file=sys.stderr,
                        )
                        break

            # Dernier recours: utiliser une URL audio déjà interceptée.
            if captured_audio_urls:
                print(
                    "  [~] Toutes les tentatives par clic ont échoué; "
                    "essai avec l'URL audio interceptée...",
                    file=sys.stderr,
                )
                cookies = context.cookies()
                user_agent = page.evaluate("navigator.userAgent")
                fallback_url = captured_audio_urls[-1]
                browser.close()

                fallback_path = download_with_cookies(
                    url=fallback_url,
                    cookies=cookies,
                    user_agent=user_agent,
                    output_dir=output_path,
                    fallback_filename=f"{target_artist} - {target_title}.flac",
                )

                if (
                    fallback_path
                    and verify_downloaded_file(
                        fallback_path,
                        target_title,
                        target_artist,
                        target_album,
                        target_duration,
                    )
                ):
                    return fallback_path

                return None

            save_debug(page, debug_dir, "download_all_attempts_failed")
            browser.close()
            return None

    except Exception as exc:
        print(f"  [!] Erreur générale: {exc}", file=sys.stderr)
        import traceback

        traceback.print_exc(file=sys.stderr)
        return None


def probe_downloaded_identity(filepath: str) -> dict:
    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        return {"error": "ffprobe introuvable"}

    command = [
        ffprobe,
        "-v",
        "quiet",
        "-show_entries",
        "format=duration:format_tags=title,artist,album,album_artist",
        "-of",
        "json",
        filepath,
    ]

    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

        if result.returncode != 0 or not result.stdout.strip():
            return {
                "error": result.stderr.strip() or "ffprobe a échoué"
            }

        return json.loads(result.stdout)
    except Exception as exc:
        return {"error": str(exc)}


def verify_downloaded_file(
    filepath: str,
    title: str,
    artist: str,
    album: str,
    expected_duration: int,
) -> bool:
    """
    Dernière barrière de sécurité après le téléchargement.

    Quand les tags existent, titre/artiste/album doivent correspondre.
    La durée est également comparée à Deezer avec une tolérance raisonnable.
    """
    identity = probe_downloaded_identity(filepath)

    if "error" in identity:
        print(
            f"  [VÉRIFICATION FICHIER] Impossible de lire les tags: "
            f"{identity['error']}. Validation DOM conservée.",
            file=sys.stderr,
        )
        return True

    audio_format = identity.get("format", {})
    tags = {
        normalize_text(key): str(value)
        for key, value in (audio_format.get("tags") or {}).items()
    }

    actual_title = tags.get("title", "")
    actual_artist = tags.get("artist", "") or tags.get("album artist", "")
    actual_album = tags.get("album", "")

    mismatches: list[str] = []

    if actual_title and canonical_title(actual_title) != canonical_title(title):
        mismatches.append(
            f"titre reçu={actual_title!r}, attendu={title!r}"
        )

    if actual_artist and normalize_text(actual_artist) != normalize_text(artist):
        mismatches.append(
            f"artiste reçu={actual_artist!r}, attendu={artist!r}"
        )

    if (
        actual_album
        and album
        and canonical_release_name(actual_album)
        != canonical_release_name(album)
    ):
        mismatches.append(
            f"album reçu={actual_album!r}, attendu={album!r}"
        )

    try:
        actual_duration = float(audio_format.get("duration", 0) or 0)
    except (TypeError, ValueError):
        actual_duration = 0.0

    if expected_duration > 0 and actual_duration > 0:
        tolerance = max(12.0, expected_duration * 0.08)
        difference = abs(actual_duration - expected_duration)

        if difference > tolerance:
            mismatches.append(
                f"durée reçue={actual_duration:.1f}s, "
                f"attendue≈{expected_duration}s"
            )

    print(
        "  [VÉRIFICATION FICHIER] "
        f"title={actual_title or '?'}, "
        f"artist={actual_artist or '?'}, "
        f"album={actual_album or '?'}, "
        f"duration={actual_duration:.1f}s",
        file=sys.stderr,
    )

    if mismatches:
        print(
            "  [!] MAUVAIS FICHIER DÉTECTÉ:",
            file=sys.stderr,
        )
        for mismatch in mismatches:
            print(f"      - {mismatch}", file=sys.stderr)

        path = Path(filepath)
        if path.exists():
            path.unlink()

        print(
            "  [!] Le fichier incorrect a été supprimé automatiquement.",
            file=sys.stderr,
        )
        return False

    print(
        "  [VÉRIFICATION FICHIER] Correspondance validée.",
        file=sys.stderr,
    )
    return True


def analyze_audio(filepath: str) -> dict:
    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        return {"error": "ffprobe introuvable"}

    try:
        command = [
            ffprobe,
            "-v",
            "quiet",
            "-show_entries",
            "stream=codec_name,sample_rate,channels,bits_per_raw_sample",
            "-show_entries",
            "format=format_name,size,bit_rate,duration",
            "-of",
            "json",
            filepath,
        ]
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

        if result.returncode != 0 or not result.stdout.strip():
            return {"error": result.stderr.strip() or "ffprobe a échoué"}

        return json.loads(result.stdout)
    except Exception as exc:
        return {"error": str(exc)}


def print_audio_info(info: dict) -> None:
    if "error" in info:
        print(f"  Analyse audio ignorée: {info['error']}", file=sys.stderr)
        return

    streams = info.get("streams", [])
    audio_format = info.get("format", {})

    if streams:
        stream = streams[0]
        print(f"  Codec:       {stream.get('codec_name', '?')}")
        print(f"  Sample rate: {stream.get('sample_rate', '?')} Hz")
        print(f"  Canaux:      {stream.get('channels', '?')}")
        bits = stream.get("bits_per_raw_sample")
        if bits:
            print(f"  Bit depth:   {bits} bits")

    try:
        size = float(audio_format.get("size", 0))
        duration = float(audio_format.get("duration", 0))
        print(f"  Format:      {audio_format.get('format_name', '?')}")
        print(f"  Taille:      {size / 1024 / 1024:.1f} Mo")
        print(f"  Durée:       {duration:.1f} s")
    except (TypeError, ValueError):
        pass


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Recherche texte Lucida puis téléchargement du morceau sélectionné.",
    )
    parser.add_argument("query", help='Recherche, par exemple "Josman Intro"')
    parser.add_argument(
        "--output",
        "-o",
        default=OUTPUT_DIR,
        help=f"Dossier de sortie (défaut: {OUTPUT_DIR})",
    )
    parser.add_argument(
        "--index",
        "-i",
        type=int,
        default=0,
        help="Index du résultat Deezer utilisé pour identifier le morceau",
    )
    parser.add_argument(
        "--lucida-index",
        type=int,
        default=None,
        help="Force un résultat parmi les candidats Lucida affichés dans le terminal",
    )
    parser.add_argument(
        "--service",
        default="Qobuz",
        help="Service Lucida utilisé pour la recherche (défaut: Qobuz)",
    )
    parser.add_argument(
        "--download-timeout",
        type=int,
        default=75,
        help="Secondes maximales par tentative de téléchargement (défaut: 75)",
    )
    parser.add_argument(
        "--download-retries",
        type=int,
        default=2,
        help="Nombre de nouvelles tentatives après la première (défaut: 2)",
    )
    parser.add_argument(
        "--list",
        "-l",
        action="store_true",
        help="Affiche seulement les résultats Deezer",
    )
    parser.add_argument(
        "--visible",
        action="store_true",
        help="Affiche Chromium pendant l'exécution",
    )
    args = parser.parse_args()

    if args.download_timeout < 10:
        parser.error("--download-timeout doit être au minimum de 10 secondes")
    if args.download_retries < 0 or args.download_retries > 10:
        parser.error("--download-retries doit être compris entre 0 et 10")

    print("=" * 66, file=sys.stderr)
    print("  LUCIDA.TO DOWNLOADER — v9", file=sys.stderr)
    print("=" * 66, file=sys.stderr)
    print(f"  Recherche utilisateur: {args.query}", file=sys.stderr)

    results = search_deezer(args.query)

    if results:
        print("\n  Résultats Deezer servant à identifier le titre:", file=sys.stderr)
        for index, result in enumerate(results):
            marker = " <<" if index == args.index else ""
            duration = result["duration"]
            minutes, seconds = divmod(duration, 60)
            print(
                f"  [{index}] {result['title']} — {result['artist_name']} "
                f"[{result['album_title']}] {minutes}:{seconds:02d}{marker}",
                file=sys.stderr,
            )

        if args.list:
            return

        if args.index < 0 or args.index >= len(results):
            print(
                f"\n  [!] Index Deezer invalide: {args.index}. "
                f"Choisis entre 0 et {len(results) - 1}.",
                file=sys.stderr,
            )
            sys.exit(1)

        selected = results[args.index]
        target_title = selected["title_short"] or selected["title"]
        target_artist = selected["artist_name"]
        target_album = selected["album_title"]
        target_duration = selected["duration"]
        lucida_query = f"{target_artist} {target_title}".strip()
    else:
        if args.list:
            print("  Aucun résultat Deezer.", file=sys.stderr)
            return

        # Le téléchargement reste possible même si l'API Deezer est indisponible.
        target_title = args.query
        target_artist = ""
        target_album = ""
        target_duration = 0
        lucida_query = args.query

    print("\n  Sélection:", file=sys.stderr)
    print(f"  Titre:    {target_title}", file=sys.stderr)
    print(f"  Artiste:  {target_artist or '(inconnu)'}", file=sys.stderr)
    print(f"  Album:    {target_album or '(inconnu)'}", file=sys.stderr)
    print(f"  Lucida:   {lucida_query}", file=sys.stderr)

    result_path = download_from_lucida(
        search_query=lucida_query,
        target_title=target_title,
        target_artist=target_artist,
        target_album=target_album,
        output_dir=args.output,
        visible=args.visible,
        lucida_index=args.lucida_index,
        search_service=args.service,
        download_timeout_seconds=args.download_timeout,
        download_retries=args.download_retries,
        target_duration=target_duration,
    )

    if not result_path or not Path(result_path).exists():
        print(
            f"\n  [!] Échec. Fichiers de diagnostic: {args.output}/debug/",
            file=sys.stderr,
        )
        sys.exit(1)

    print("\n  Analyse du fichier:", file=sys.stderr)
    print(f"  Chemin: {result_path}", file=sys.stderr)
    print_audio_info(analyze_audio(result_path))
    print("\nTerminé.", file=sys.stderr)


if __name__ == "__main__":
    main()
