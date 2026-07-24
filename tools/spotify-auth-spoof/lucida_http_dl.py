#!/usr/bin/env python3
"""
Lucida.to Downloader — v5
=========================

Flux reproduit:
1. Recherche du morceau via l'API publique Deezer pour identifier titre/artiste.
2. Recherche dans Lucida avec du texte: "artiste titre" (jamais avec l'URL Deezer).
3. Sélection automatique du résultat Lucida correspondant.
4. Ouverture de la fiche du morceau.
5. Clic sur "download track" et sauvegarde du fichier.

Usage:
  python lucida_dl_final_v5.py "Josman Intro"
  python lucida_dl_final_v5.py "Josman Intro" --visible
  python lucida_dl_final_v5.py "Josman Intro" --index 1
  python lucida_dl_final_v5.py "Josman Intro" --lucida-index 0
  python lucida_dl_final_v5.py "Josman Intro" --list
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
        TimeoutError as PlaywrightTimeoutError,
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


def normalize_text(value: str | None) -> str:
    """Normalisation souple pour comparer titres, artistes et libellés."""
    value = value or ""
    value = unicodedata.normalize("NFKD", value)
    value = "".join(char for char in value if not unicodedata.combining(char))
    value = value.casefold()
    value = re.sub(r"[^a-z0-9]+", " ", value)
    return " ".join(value.split())


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
    own = normalize_text(own_text)
    context = normalize_text(context_text)
    title_n = normalize_text(title)
    artist_n = normalize_text(artist)
    album_n = normalize_text(album)

    if not own and not context:
        return -10_000

    rejected = (
        "home",
        "faq",
        "donate",
        "recent downloads",
        "download track",
        "lucida downloader library",
        "privacy",
        "status",
        "discord",
        "telegram",
    )
    if any(term in own for term in rejected):
        return -10_000

    score = 0

    # Le lien du titre est normalement le meilleur élément à cliquer.
    if title_n and own == title_n:
        score += 140
    elif title_n and title_n in own:
        score += 95
    elif title_n and own and own in title_n and len(own) >= 4:
        score += 55

    if title_n and title_n in context:
        score += 45

    if artist_n:
        if own == artist_n:
            score += 15
        if artist_n in context:
            score += 70

    if album_n and album_n in context:
        score += 20

    # Une carte qui contient à la fois titre et artiste est très probablement correcte.
    if title_n and artist_n and title_n in context and artist_n in context:
        score += 60

    return score


def find_lucida_result(
    page: Page,
    title: str,
    artist: str,
    album: str,
    forced_index: int | None,
) -> Locator | None:
    """
    Trouve le meilleur lien/bouton dans les résultats Lucida.

    Le DOM exact peut changer: on note chaque élément cliquable selon son propre
    texte et le texte de sa carte parente.
    """
    clickables = page.locator(
        'main a:visible, main button:visible, '
        'a:visible, button:visible, [role="button"]:visible'
    )
    count = min(clickables.count(), 400)
    scored: list[tuple[int, int, Locator, str, str]] = []

    for index in range(count):
        candidate = clickables.nth(index)

        try:
            if not candidate.is_visible():
                continue
        except Exception:
            continue

        own_text = locator_label(candidate)
        context_text = locator_context(candidate)
        score = score_result_candidate(
            own_text=own_text,
            context_text=context_text,
            title=title,
            artist=artist,
            album=album,
        )

        if score > 0:
            scored.append((score, index, candidate, own_text, context_text))

    if not scored:
        return None

    # Évite plusieurs éléments d'une même carte qui auraient exactement le même contexte.
    unique: list[tuple[int, int, Locator, str, str]] = []
    seen_contexts: set[str] = set()

    for item in sorted(scored, key=lambda row: (-row[0], row[1])):
        context_key = normalize_text(item[4])[:500]
        if context_key in seen_contexts:
            continue
        seen_contexts.add(context_key)
        unique.append(item)

    print("  [~] Meilleurs résultats Lucida détectés:", file=sys.stderr)
    for position, (score, _, _, own, context) in enumerate(unique[:8]):
        compact_context = " | ".join(
            line.strip() for line in context.splitlines() if line.strip()
        )
        print(
            f"      [{position}] score={score} "
            f"élément={own[:80]!r} carte={compact_context[:180]!r}",
            file=sys.stderr,
        )

    if forced_index is not None:
        if forced_index < 0 or forced_index >= len(unique):
            print(
                f"  [!] --lucida-index {forced_index} invalide: "
                f"{len(unique)} résultat(s) utilisable(s).",
                file=sys.stderr,
            )
            return None
        selected = unique[forced_index]
    else:
        selected = unique[0]

    score, _, locator, own, _ = selected
    print(
        f"  [~] Résultat Lucida choisi: {own!r} (score {score})",
        file=sys.stderr,
    )
    return locator


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


def wait_for_track_page(page: Page, timeout_seconds: int = 60) -> bool:
    deadline = time.monotonic() + timeout_seconds

    while time.monotonic() < deadline:
        error = body_contains_error(page)
        if error:
            print(f"  [!] Lucida affiche une erreur: {error}", file=sys.stderr)
            return False

        try:
            body_n = normalize_text(page.locator("body").inner_text(timeout=3_000))
        except Exception:
            page.wait_for_timeout(1_000)
            continue

        if "download track" in body_n:
            return True

        page.wait_for_timeout(1_000)

    print("  [!] La fiche du morceau n'a pas affiché « download track ».", file=sys.stderr)
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
    controls = page.locator(
        'button:visible, a:visible, input[type="submit"]:visible, '
        'input[type="button"]:visible, [role="button"]:visible'
    )

    for index in range(controls.count()):
        control = controls.nth(index)
        label = normalize_text(locator_label(control))

        if label == "download track":
            return control

    # Tolérance pour une éventuelle icône ajoutée au libellé accessible.
    for index in range(controls.count()):
        control = controls.nth(index)
        label = normalize_text(locator_label(control))

        if label.startswith("download track") and "library" not in label:
            return control

    return None


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

            def on_console(message) -> None:
                if "[i18n]: 'my' locale is non-standard." in message.text:
                    return
                if message.type in ("error", "warning"):
                    print(
                        f"  [CONSOLE] {message.type}: {message.text}",
                        file=sys.stderr,
                    )

            def on_request_failed(request) -> None:
                if "/cdn-cgi/rum" in request.url:
                    return
                print(
                    f"  [REQ FAIL] {request.method} {request.url} "
                    f"— {request.failure}",
                    file=sys.stderr,
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

            page.on("console", on_console)
            page.on("requestfailed", on_request_failed)
            page.on("response", on_response)

            print(f"  [1/5] Ouverture de {BASE_URL}...", file=sys.stderr)
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

            print("  [2/5] Recherche texte dans Lucida...", file=sys.stderr)
            search_input.fill(search_query)
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

            save_debug(page, debug_dir, "02_results")

            print("  [3/5] Sélection du bon morceau...", file=sys.stderr)
            result = find_lucida_result(
                page=page,
                title=target_title,
                artist=target_artist,
                album=target_album,
                forced_index=lucida_index,
            )

            if result is None:
                print(
                    "  [!] Aucun résultat Lucida suffisamment proche trouvé.",
                    file=sys.stderr,
                )
                save_debug(page, debug_dir, "no_matching_result")
                browser.close()
                return None

            result.click(timeout=15_000)

            if not wait_for_track_page(page, timeout_seconds=60):
                save_debug(page, debug_dir, "track_page_failed")
                browser.close()
                return None

            save_debug(page, debug_dir, "03_track")

            print("  [4/5] Préparation de la meilleure qualité...", file=sys.stderr)
            select_original_quality(page)

            download_control = find_download_track_control(page)
            if download_control is None:
                print(
                    "  [!] Bouton exact « download track » introuvable.",
                    file=sys.stderr,
                )
                save_debug(page, debug_dir, "no_download_track")
                browser.close()
                return None

            print("  [5/5] Clic sur « download track »...", file=sys.stderr)

            try:
                with page.expect_download(timeout=300_000) as download_info:
                    download_control.click(timeout=15_000)

                download = download_info.value
                filename = safe_filename(
                    download.suggested_filename
                    or f"{target_artist} - {target_title}.flac"
                )
                destination = output_path / filename
                download.save_as(destination)

                size = destination.stat().st_size
                print(
                    f"  [~] Téléchargé: {destination.name} "
                    f"({size / 1024 / 1024:.1f} Mo)",
                    file=sys.stderr,
                )
                browser.close()
                return str(destination)

            except PlaywrightTimeoutError:
                print(
                    "  [~] Aucun événement Download reçu; essai avec "
                    "l'URL audio interceptée...",
                    file=sys.stderr,
                )
                save_debug(page, debug_dir, "download_timeout")

                if not captured_audio_urls:
                    browser.close()
                    return None

                cookies = context.cookies()
                user_agent = page.evaluate("navigator.userAgent")
                fallback_url = captured_audio_urls[-1]
                browser.close()

                return download_with_cookies(
                    url=fallback_url,
                    cookies=cookies,
                    user_agent=user_agent,
                    output_dir=output_path,
                    fallback_filename=f"{target_artist} - {target_title}.flac",
                )

    except Exception as exc:
        print(f"  [!] Erreur générale: {exc}", file=sys.stderr)
        import traceback

        traceback.print_exc(file=sys.stderr)
        return None


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

    print("=" * 66, file=sys.stderr)
    print("  LUCIDA.TO DOWNLOADER — v5", file=sys.stderr)
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
        lucida_query = f"{target_artist} {target_title}".strip()
    else:
        if args.list:
            print("  Aucun résultat Deezer.", file=sys.stderr)
            return

        # Le téléchargement reste possible même si l'API Deezer est indisponible.
        target_title = args.query
        target_artist = ""
        target_album = ""
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
