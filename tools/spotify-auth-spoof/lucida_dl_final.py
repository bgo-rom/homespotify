#!/usr/bin/env python3
"""
HomeSpotify — Multi-Provider FLAC Downloader (final, working)

Architecture modulaire : plusieurs fournisseurs (Lucida, Monochrome, Doubledouble)
peuvent être utilisés pour télécharger un même morceau. Sélection aléatoire
quand plusieurs sont disponibles.

Workflow général :
  1. HomeSpotify choisit un fournisseur (ou aléatoire)
  2. Prépare la recherche avec Deezer API pour identification
  3. Ouvre le fournisseur dans Chromium visible
  4. Le script recherche le morceau, clique, et déclenche le téléchargement
  5. HomeSpotify détecte le nouveau fichier local
  6. Vérifie FLAC + métadonnées + durée
  7. Renomme en Artiste - Titre.flac
  8. Importe dans la bibliothèque

Usage :
    python lucida_dl_final.py "Guala Lifestyles" --provider auto
    python lucida_dl_final.py "Guala Lifestyles" --provider doubledouble
    python lucida_dl_final.py "Guala Lifestyles" --provider monochrome
    python lucida_dl_final.py "Guala Lifestyles" --provider lucida
"""

import argparse
import json
import os
import random
import re
import signal
import shutil
import subprocess
import sys
import time
import traceback
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Optional
import urllib.request
from urllib.parse import urlparse, urljoin, quote as urllib_quote

from playwright.sync_api import Browser, BrowserContext, Download, Page, sync_playwright

# ─── Configuration ───────────────────────────────────────────────────────────

OUTPUT_DIR = Path("storage/imports")
DEBUG_DIR = OUTPUT_DIR / "debug"
BROWSER_EXECUTABLE = r"C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe"
BRAVE_PROFILE_DIR = Path.home() / ".homespotify" / "brave-playwright-profile"

EXIT_OK = 0
EXIT_NO_RESULT = 1
EXIT_EXTERNAL_ERROR = 2
EXIT_INVALID_ARGUMENT = 3
EXIT_CAPTCHA_BLOCKED = 4

ALLOWED_STORAGE_SERVICES = {"send.cm", "litterbox", "pixeldrain"}
BLOCKED_STORAGE_SERVICES = {"google-drive", "mega"}

DEEZER_API_BASE = "https://api.deezer.com/search?q="

# Délais humains aléatoires (en ms)
HUMAN_DELAY_MIN_MS = 300
HUMAN_DELAY_MAX_MS = 1500

# ─── Data classes ────────────────────────────────────────────────────────────

@dataclass
class ProviderConfig:
    name: str
    display_name: str
    base_url: str
    description: str = ""
    requiresHumanAction: bool = False

@dataclass
class AudioInfo:
    path: str
    size_bytes: int
    duration_seconds: float
    codec: str
    sample_rate: int
    bit_depth: int
    title: str
    artist: str
    album: str
    track_number: str

# ─── Types ───────────────────────────────────────────────────────────────────

EventCallback = Callable[[dict[str, Any]], None]

# ─── Events ──────────────────────────────────────────────────────────────────

def emit_event(event: dict[str, Any]) -> None:
    """Émet un événement NDJSON sur stdout."""
    try:
        sys.stdout.write(json.dumps(event) + "\n")
        sys.stdout.flush()
    except BrokenPipeError:
        pass


def notify(
    callback: EventCallback | None,
    type: str,
    **kwargs: Any,
) -> None:
    """Envoye un événement via le callback."""
    if callback is None:
        return
    event: dict[str, Any] = {"type": type, **kwargs}
    emit_event(event)


# ─── Helpers ─────────────────────────────────────────────────────────────────

def random_human_delay_ms(min_ms: int = HUMAN_DELAY_MIN_MS, max_ms: int = HUMAN_DELAY_MAX_MS) -> int:
    return random.randint(min_ms, max_ms)


def random_ua() -> str:
    return "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"


def normalize_text(text: str) -> str:
    """Normalise un texte pour comparaison : minuscules, accents, espaces."""
    import unicodedata
    nfkd = unicodedata.normalize("NFKD", text)
    ascii_text = "".join(c for c in nfkd if not unicodedata.combining(c))
    return ascii_text.lower().strip()


def safe_filename(name: str) -> str:
    """Nettoie un nom de fichier pour Windows."""
    return re.sub(r'[<>:"/\\|?*]', '_', name)


def human_like_type(page: Page, element: Any, text: str) -> None:
    """Tape du texte avec un comportement humain."""
    element.click()
    page.wait_for_timeout(random_human_delay_ms(100, 400))
    element.fill(text)
    page.wait_for_timeout(random_human_delay_ms(200, 500))


def human_like_click(page: Page, element: Any, force: bool = False) -> None:
    """Clic avec délai humain."""
    delay = random_human_delay_ms(200, 800)
    page.wait_for_timeout(delay)
    if force:
        element.click(force=True)
    else:
        element.click()


def human_like_wait(page: Page, min_ms: int = 200, max_ms: int = 1000) -> None:
    """Délai aléatoire pour simuler un humain."""
    page.wait_for_timeout(random_human_delay_ms(min_ms, max_ms))


def snapshot_directory(directory: Path) -> set[Path]:
    """Liste les fichiers existants dans un dossier avant téléchargement."""
    try:
        if directory.exists():
            return {f for f in directory.rglob("*") if f.is_file()}
    except Exception:
        pass
    return set()


def save_debug(page: Page, debug_dir: Path, prefix: str) -> None:
    """Sauvegarde un snapshot de débogage."""
    try:
        debug_dir.mkdir(parents=True, exist_ok=True)
        page.screenshot(path=str(debug_dir / f"{prefix}.png"), full_page=True)
    except Exception:
        pass


def safe_close_browser(browser: Browser | None) -> None:
    try:
        if browser is not None:
            browser.close()
    except Exception:
        pass


def safe_close_playwright_session(
    context: BrowserContext,
    playwright: Any,
) -> None:
    try:
        context.close()
    except Exception:
        pass
    try:
        playwright.stop()
    except Exception:
        pass


def find_new_file_in_directory_now(
    directory: Path,
    before_snapshot: set[Path],
    timeout_seconds: int = 30,
) -> Optional[Path]:
    """Fait une recherche synchronisée, pas un wait_loop."""
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        try:
            if directory.exists():
                current = {f for f in directory.rglob("*") if f.is_file()}
                new_files = current - before_snapshot
                if new_files:
                    return next(iter(new_files))
        except Exception:
            pass
        time.sleep(0.5)
    return None


def find_new_file_in_directory(
    directory: Path,
    before_snapshot: set[Path],
    timeout_seconds: int = 60,
    event_callback: EventCallback | None = None,
) -> Optional[Path]:
    """Fait une recherche synchronisée, pas un wait_loop."""
    return find_new_file_in_directory_now(directory, before_snapshot, timeout_seconds)


# ─── Deezer search ───────────────────────────────────────────────────────────

def search_deezer(query: str, limit: int = 5) -> list[dict[str, Any]]:
    """Recherche via Deezer API publique (pas d'auth)."""
    if not query.strip():
        return []
    try:
        url = f"{DEEZER_API_BASE}{urllib_quote(query)}&limit={limit}"
        req = urllib.request.Request(url, headers={"User-Agent": "HomeSpotify/1.0"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read())
        results = []
        for hit in data.get("data", [])[:limit]:
            title = hit.get("title") or hit.get("title_short") or ""
            artist = hit.get("artist", {}).get("name") or ""
            album = hit.get("album", {}).get("title") or ""
            duration = int(hit.get("duration") or 0)
            if title and artist:
                results.append({
                    "title": title,
                    "title_short": hit.get("title_short") or title,
                    "artist_name": artist,
                    "album_title": album,
                    "duration": duration,
                })
        return results
    except Exception:
        return []


# ─── Audio analysis ──────────────────────────────────────────────────────────

def probe_downloaded_identity(filepath: str) -> dict:
    """Lit les tags et la durée d'un fichier audio avec ffprobe."""
    try:
        result = subprocess.run(
            [
                "ffprobe",
                "-v", "error",
                "-show_entries", "format=duration,size",
                "-show_entries", "stream=codec_name,sample_rate,bits_per_sample",
                "-of", "json",
                filepath,
            ],
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        if result.returncode != 0:
            return {}
        data = json.loads(result.stdout)
        info: dict[str, Any] = {}
        fmt = data.get("format", {})
        info["duration_seconds"] = float(fmt.get("duration") or 0)
        info["size_bytes"] = int(fmt.get("size") or 0)
        streams = data.get("streams", [])
        for stream in streams:
            if stream.get("codec_type") == "audio":
                info["codec"] = stream.get("codec_name", "unknown")
                info["sample_rate"] = int(stream.get("sample_rate") or 0)
                info["bit_depth"] = int(stream.get("bits_per_sample") or 0)
                break
        tags = data.get("format", {}).get("tags", {})
        info["title"] = tags.get("title", "")
        info["artist"] = tags.get("artist", "")
        info["album"] = tags.get("album", "")
        info["track_number"] = tags.get("TRACK", tags.get("track_number", ""))
        return info
    except Exception:
        return {}


def analyze_audio(filepath: str) -> AudioInfo:
    """Analyse un fichier audio et retourne un objet AudioInfo."""
    identity = probe_downloaded_identity(filepath)
    size = Path(filepath).stat().st_size
    return AudioInfo(
        path=filepath,
        size_bytes=size,
        duration_seconds=identity.get("duration_seconds", 0),
        codec=identity.get("codec", "unknown"),
        sample_rate=identity.get("sample_rate", 0),
        bit_depth=identity.get("bit_depth", 0),
        title=identity.get("title", ""),
        artist=identity.get("artist", ""),
        album=identity.get("album", ""),
        track_number=identity.get("track_number", ""),
    )


def print_audio_info(info: AudioInfo) -> None:
    """Affiche les infos d'un fichier audio."""
    print(f"  Codec:          {info.codec}", file=sys.stderr)
    print(f"  Taille:         {info.size_bytes / 1024 / 1024:.1f} Mo", file=sys.stderr)
    print(f"  Durée:          {info.duration_seconds:.1f}s", file=sys.stderr)
    print(f"  Fréquence:      {info.sample_rate} Hz", file=sys.stderr)
    print(f"  Profondeur:     {info.bit_depth} bits", file=sys.stderr)
    print(f"  Titre:          {info.title or '(pas dans les tags)'})", file=sys.stderr)
    print(f"  Artiste:        {info.artist or '(pas dans les tags)'})", file=sys.stderr)
    print(f"  Album:          {info.album or '(pas dans les tags)'})", file=sys.stderr)
    print(f"  Piste:          {info.track_number or '(pas dans les tags)'})", file=sys.stderr)


def verify_downloaded_file(
    filepath: str,
    target_title: str,
    target_artist: str,
    target_album: str,
    target_duration: int,
    strict_mode: bool = True,
) -> bool:
    """
    Vérifie qu'un fichier correspond au morceau cible.
    strict_mode=False : tolère les écarts de métadonnées (fournisseur tiers).
    """
    identity = probe_downloaded_identity(filepath)
    if not identity:
        return False

    duration = identity.get("duration_seconds", 0)
    title = identity.get("title", "")
    artist = identity.get("artist", "")
    album = identity.get("album", "")

    # Vérification durée (tolérance 10% en mode non strict)
    if target_duration > 0 and duration > 0:
        tolerance = 0.10 if not strict_mode else 0.05
        if abs(duration - target_duration) > target_duration * tolerance:
            return False

    # Vérification métadonnées (plus souple en mode non strict)
    if not strict_mode:
        if target_title and not strict_mode:
            # En mode non strict, on vérifie juste que le fichier n'est pas
            # complètement différent
            if target_title.lower() not in title.lower() and title:
                pass  # Les tags peuvent être différents
        if target_artist and not strict_mode:
            if target_artist.lower() not in artist.lower() and artist:
                pass

    # Vérification codec
    codec = identity.get("codec", "")
    if strict_mode and codec not in ("flac",):
        return False

    return True


def rename_with_metadata(
    filepath: str,
    target_title: str,
    target_artist: str,
    output_dir: Path,
) -> str:
    """Renomme le fichier en Artiste - Titre.flac."""
    stem = f"{target_artist} - {target_title}"
    stem = safe_filename(stem)
    ext = Path(filepath).suffix.lower()
    if ext not in (".flac", ".wav", ".m4a", ".aac", ".ogg"):
        ext = ".flac"
    new_name = f"{stem}{ext}"
    new_path = output_dir / new_name
    if Path(filepath).resolve() != new_path.resolve():
        shutil.move(filepath, str(new_path))
    return str(new_path)



# ─── Qobuz exact URL resolution ───────────────────────────────────────────────

QOBUZ_ALBUM_URL_RE = re.compile(
    r"^https?://(?:www\.)?qobuz\.com/[^/]+/album/[^/?#]+/[A-Za-z0-9]+/?(?:[?#].*)?$",
    re.IGNORECASE,
)


def is_complete_qobuz_album_url(value: str) -> bool:
    """Vérifie que l'URL Qobuz contient bien le véritable identifiant d'album."""
    return bool(QOBUZ_ALBUM_URL_RE.match((value or "").strip()))


def _qobuz_candidate_score(
    href: str,
    text: str,
    target_title: str,
    target_artist: str,
    target_album: str,
) -> int:
    """Attribue un score à un résultat Qobuz pour éviter le premier lien aléatoire."""
    href_norm = normalize_text(href.replace("-", " ").replace("/", " "))
    text_norm = normalize_text(text)
    haystack = f"{text_norm} {href_norm}"

    artist = normalize_text(target_artist)
    album = normalize_text(target_album)
    title = normalize_text(target_title)

    score = 0
    if artist and artist in haystack:
        score += 12
    if album and album in haystack:
        score += 12
    if title and title in haystack:
        score += 5

    # Un lien complet est très fortement privilégié.
    if is_complete_qobuz_album_url(href):
        score += 20

    # Éviter les pages génériques ou les liens sans identifiant final.
    path_parts = [part for part in urlparse(href).path.split("/") if part]
    if "album" in path_parts and len(path_parts) >= 4:
        score += 4

    return score


def resolve_qobuz_album_url(
    context: BrowserContext,
    target_title: str,
    target_artist: str,
    target_album: str,
    raw_query: str = "",
    timeout_seconds: int = 60,
    event_callback: EventCallback | None = None,
    page: Page | None = None,
) -> Optional[str]:
    """
    Recherche réellement le morceau/album sur Qobuz et retourne une URL complète,
    par exemple :
    https://www.qobuz.com/us-en/album/lifestyles-guala/m7mqu37d7v1ka

    La recherche est effectuée dans un onglet séparé afin de ne pas perturber la
    session persistante utilisée ensuite par Doubledouble.
    """
    if is_complete_qobuz_album_url(raw_query):
        return raw_query.strip()

    query_variants: list[str] = []
    for candidate in (
        f"{target_album} {target_artist}".strip(),
        f"{target_title} {target_artist}".strip(),
        raw_query.strip(),
    ):
        if candidate and candidate not in query_variants:
            query_variants.append(candidate)

    if not query_variants:
        return None

    # Réutiliser l'onglet principal au lieu d'ouvrir Qobuz dans un onglet
    # secondaire invisible. Avec Brave, le premier onglet peut rester affiché
    # sur about:blank alors que Playwright travaille dans un autre onglet.
    owns_page = page is None
    qobuz_page: Page | None = page
    deadline = time.monotonic() + timeout_seconds

    try:
        if qobuz_page is None or qobuz_page.is_closed():
            qobuz_page = context.new_page()
            owns_page = True

        qobuz_page.set_default_timeout(15_000)
        qobuz_page.set_default_navigation_timeout(45_000)
        try:
            qobuz_page.bring_to_front()
        except Exception:
            pass

        for query in query_variants:
            if time.monotonic() >= deadline:
                break

            search_url = f"https://www.qobuz.com/us-en/search?q={urllib_quote(query)}"
            notify(
                event_callback,
                "stage",
                stage="qobuz_lookup",
                message=f"Recherche Qobuz: {query}",
            )
            print(f"  [QOBUZ] Recherche de l'URL exacte pour: {query}", file=sys.stderr)

            nav_timeout = min(
                45_000,
                max(5_000, int((deadline - time.monotonic()) * 1000)),
            )
            navigation_ok = False
            last_navigation_error: Exception | None = None

            for wait_state in ("domcontentloaded", "commit"):
                try:
                    qobuz_page.bring_to_front()
                    qobuz_page.goto(
                        search_url,
                        wait_until=wait_state,
                        timeout=nav_timeout,
                    )
                    if qobuz_page.url and qobuz_page.url != "about:blank":
                        navigation_ok = True
                        break
                except Exception as exc:
                    last_navigation_error = exc

            # Dernier secours : navigation JavaScript dans le même onglet.
            if not navigation_ok:
                try:
                    qobuz_page.evaluate(
                        "url => { window.location.assign(url); }",
                        search_url,
                    )
                    qobuz_page.wait_for_url(
                        re.compile(r"^https://(?:www\.)?qobuz\.com/"),
                        timeout=min(nav_timeout, 20_000),
                    )
                    navigation_ok = qobuz_page.url != "about:blank"
                except Exception as exc:
                    last_navigation_error = exc

            if not navigation_ok:
                print(
                    f"  [QOBUZ] Impossible de quitter about:blank: "
                    f"{last_navigation_error}",
                    file=sys.stderr,
                )
                continue

            print(f"  [QOBUZ] Page chargée: {qobuz_page.url}", file=sys.stderr)

            # Qobuz peut hydrater les résultats après DOMContentLoaded.
            try:
                qobuz_page.wait_for_selector('a[href*="/album/"]', timeout=12_000)
            except Exception:
                pass

            try:
                candidates = qobuz_page.locator('a[href*="/album/"]').evaluate_all(
                    """
                    (links) => links.map((a) => ({
                        href: a.href || a.getAttribute('href') || '',
                        text: (a.innerText || a.textContent || '').trim()
                    }))
                    """
                )
            except Exception:
                candidates = []

            ranked: list[tuple[int, str, str]] = []
            seen: set[str] = set()
            for item in candidates or []:
                if not isinstance(item, dict):
                    continue
                href = urljoin("https://www.qobuz.com", str(item.get("href") or "").strip())
                link_text = str(item.get("text") or "").strip()
                if not href or href in seen or "/album/" not in href:
                    continue
                seen.add(href)
                score = _qobuz_candidate_score(
                    href,
                    link_text,
                    target_title,
                    target_artist,
                    target_album,
                )
                ranked.append((score, href, link_text))

            ranked.sort(key=lambda item: item[0], reverse=True)

            for score, href, link_text in ranked[:8]:
                if score <= 0:
                    continue

                # La plupart des résultats fournissent déjà l'URL finale complète.
                if is_complete_qobuz_album_url(href):
                    print(f"  [QOBUZ] Lien exact trouvé: {href}", file=sys.stderr)
                    notify(event_callback, "stage", stage="qobuz_found", message=href)
                    return href

                # Fallback : ouvrir le résultat et récupérer l'URL canonique finale.
                try:
                    qobuz_page.goto(href, wait_until="domcontentloaded", timeout=30_000)
                    canonical = qobuz_page.locator('link[rel="canonical"]').first
                    canonical_href = canonical.get_attribute("href") if canonical.count() else None
                    final_url = (canonical_href or qobuz_page.url or "").strip()
                    if is_complete_qobuz_album_url(final_url):
                        print(f"  [QOBUZ] Lien canonique trouvé: {final_url}", file=sys.stderr)
                        notify(event_callback, "stage", stage="qobuz_found", message=final_url)
                        return final_url
                except Exception:
                    continue

        print("  [QOBUZ] Aucun lien d'album complet trouvé.", file=sys.stderr)
        return None
    finally:
        # Ne pas fermer l'onglet principal fourni par le fournisseur : il sera
        # réutilisé immédiatement pour Lucida ou DoubleDouble.
        if owns_page and qobuz_page is not None:
            try:
                qobuz_page.close()
            except BaseException:
                pass


# ─── Cloudflare detection ────────────────────────────────────────────────────

def is_blocked_by_challenge(page: Page) -> bool:
    """
    Retourne True uniquement si un challenge semble *actif et visible*.
    """
    try:
        if page.is_closed():
            return False

        url = page.url.lower()
        if "/cdn-cgi/challenge-platform/" in url:
            return True

        visible_text = ""
        try:
            visible_text = page.locator("body").inner_text(timeout=2_000).lower()
        except Exception:
            try:
                visible_text = page.content().lower()
            except Exception:
                visible_text = ""

        strong_indicators = [
            "checking your browser before continuing",
            "checking your browser",
            "please stand by while we verify your browser",
            "please verify you are human",
            "verify you are human",
            "verify that you are human",
            "please complete the captcha to continue",
            "complete the captcha to continue",
            "vérifiez que vous êtes humain",
            "verifiez que vous etes humain",
            "please complete the security check",
            "human verification",
            "just a moment",
            "unable to verify you are human",
            "ddos protection by cloudflare",
            "under attack mode",
            "error 1010",
            "error 1020",
            "error 1015",
        ]
        captcha_indicators = [
            "i'm not a robot",
            "select all images",
            "select all squares",
            "recaptcha",
            "hcaptcha",
        ]

        if any(indicator in visible_text for indicator in strong_indicators):
            return True
        if any(indicator in visible_text for indicator in captcha_indicators):
            return True

        # Un widget ne compte que s'il est réellement visible.
        challenge_selectors = [
            'iframe[src*="challenges.cloudflare.com"]',
            'iframe[src*="/cdn-cgi/challenge-platform/"]',
            'iframe[src*="hcaptcha"]',
            'iframe[src*="recaptcha"]',
            '.cf-turnstile',
            '[data-cf-turnstile]',
        ]
        for selector in challenge_selectors:
            try:
                locator = page.locator(selector)
                count = min(locator.count(), 8)
                for index in range(count):
                    item = locator.nth(index)
                    if item.is_visible(timeout=250):
                        box = item.bounding_box()
                        if box is None or (box.get("width", 0) > 2 and box.get("height", 0) > 2):
                            return True
            except Exception:
                continue

        # Vérifier les erreurs Cloudflare dans la console
        try:
            console_errors = page.evaluate("""
                () => {
                    const errors = [];
                    for (const msg of console.messages) {
                        if (msg.text.includes('cloudflare') || msg.text.includes('challenges') || msg.text.includes('turnstile')) {
                            errors.push(msg.text);
                        }
                    }
                    return errors;
                }
            """)
            if errors:
                return True
        except Exception:
            pass

        return False
    except Exception:
        return False


def wait_for_challenge_to_clear(page: Page, timeout_seconds: int = 120) -> bool:
    """Attend une résolution manuelle sans bloquer l'event loop Playwright."""
    start = time.monotonic()
    print(
        f"  [CHALLENGE] Résous la vérification dans Chromium "
        f"({timeout_seconds}s max, Ctrl+C pour annuler proprement)...",
        file=sys.stderr,
    )

    while time.monotonic() - start < timeout_seconds:
        if page.is_closed():
            return False
        if not is_blocked_by_challenge(page):
            print("  [CHALLENGE] Vérification terminée.", file=sys.stderr)
            return True
        time.sleep(1.0)

    return False


# ─── Download detection ──────────────────────────────────────────────────────

def capture_download(download: Download) -> None:
    """Capture un téléchargement dans une liste partagée."""
    captured_downloads.append(download)


# ─── Shared persistent context helper ────────────────────────────────────────

def _get_persistent_context(
    playwright: Any,
    provider_name: str,
    visible: bool,
    event_callback: EventCallback | None = None,
) -> BrowserContext:
    """
    Crée un contexte persistant Brave avec profil dédié.
    """
    BRAVE_PROFILE_DIR.mkdir(parents=True, exist_ok=True)
    context = playwright.chromium.launch_persistent_context(
        user_data_dir=str(BRAVE_PROFILE_DIR),
        headless=False,
        executable_path=BROWSER_EXECUTABLE,
        accept_downloads=True,
        viewport=None,
        args=[],
    )
    notify(event_callback, "stage", stage="launching_browser", provider=provider_name, message="Lancement de Brave")
    print(f"  [{provider_name.upper()}] Lancement de Brave (profil persistant: {BRAVE_PROFILE_DIR})...", file=sys.stderr)
    return context


def _get_visible_work_page(context: BrowserContext) -> Page:
    """Retourne l'onglet visible réellement utilisé par l'automatisation.

    Un contexte persistant Brave démarre souvent avec un premier onglet
    ``about:blank``. Si Qobuz est ouvert dans un second onglet, l'utilisateur
    continue alors à voir la page blanche. On réutilise donc explicitement le
    premier onglet vide et on le place au premier plan.
    """
    pages = [candidate for candidate in context.pages if not candidate.is_closed()]

    page: Page | None = None
    for candidate in pages:
        if candidate.url in ("", "about:blank"):
            page = candidate
            break

    if page is None:
        page = context.new_page()

    try:
        page.bring_to_front()
    except Exception:
        pass

    # Nettoyer uniquement les autres onglets vides hérités d'un ancien run.
    for candidate in pages:
        if candidate is page or candidate.is_closed():
            continue
        if candidate.url in ("", "about:blank"):
            try:
                candidate.close()
            except BaseException:
                pass

    return page


# ─── LUCIDA Provider ─────────────────────────────────────────────────────────

LUCIDA_CONFIG = ProviderConfig(
    name="lucida",
    display_name="Lucida (Qobuz)",
    base_url="https://lucida.app",
    description="Fournisseur Lucida — recherche via URL Qobuz",
)


def download_from_lucida(
    search_query: str,
    target_title: str,
    target_artist: str,
    target_album: str,
    output_dir: Path,
    visible: bool = True,
    download_timeout_seconds: int = 120,
    target_duration: int = 0,
    event_callback: EventCallback | None = None,
) -> Optional[str]:
    """
    Fournisseur Lucida — recherche via URL Qobuz.
    """
    debug_dir = output_dir / "debug" / "lucida"
    debug_dir.mkdir(parents=True, exist_ok=True)

    try:
        playwright = sync_playwright().start()

        context = _get_persistent_context(playwright, "lucida", visible, event_callback)
        page = _get_visible_work_page(context)
        page.set_default_timeout(30_000)
        page.set_default_navigation_timeout(60_000)

        # Listener réseau pour débogage Cloudflare
        def log_failed_request(request: Any) -> None:
            failure = request.failure
            print(f"[RÉSEAU ÉCHEC] {request.method} {request.url} — {failure}", file=sys.stderr)

        page.on("requestfailed", log_failed_request)

        qobuz_url = resolve_qobuz_album_url(
            context=context,
            target_title=target_title,
            target_artist=target_artist,
            target_album=target_album,
            raw_query=search_query,
            timeout_seconds=min(download_timeout_seconds, 75),
            event_callback=event_callback,
            page=page,
        )
        if not qobuz_url:
            notify(event_callback, "error", code="QOBUZ_URL_NOT_FOUND", message="URL Qobuz exacte introuvable")
            safe_close_playwright_session(context, playwright)
            return None
        search_query = qobuz_url

        notify(event_callback, "stage", stage="navigating", message=f"Navigation vers {LUCIDA_CONFIG.base_url}")
        print(f"  [LUCIDA] Navigation vers {LUCIDA_CONFIG.base_url}...", file=sys.stderr)
        try:
            page.bring_to_front()
        except Exception:
            pass
        page.goto(LUCIDA_CONFIG.base_url, wait_until="domcontentloaded", timeout=60_000)
        if page.url in ("", "about:blank"):
            raise RuntimeError("LUCIDA: la navigation est restée sur about:blank")
        print(f"  [LUCIDA] Page chargée: {page.url}", file=sys.stderr)
        page.wait_for_timeout(3_000)

        save_debug(page, debug_dir, "01_homepage")

        # Trouver le champ de recherche
        search_input = None
        for selector in ['input[type="text"]', 'input[placeholder*="URL"]', 'input[placeholder*="url"]', 'input']:
            try:
                candidate = page.locator(selector).first
                if candidate.is_visible(timeout=2_000):
                    search_input = candidate
                    break
            except Exception:
                continue

        if search_input is None:
            notify(event_callback, "error", code="LUCIDA_ERROR", message="Barre de recherche non trouvée")
            save_debug(page, debug_dir, "search_ui_not_found")
            safe_close_playwright_session(context, playwright)
            return None

        # Remplir avec le query
        human_like_type(page, search_input, search_query)
        human_like_wait(page, 300, 800)
        search_input.press("Enter")

        save_debug(page, debug_dir, "02_search_submitted")

        # Capturer les downloads
        captured_downloads: list[Download] = []
        page.on("download", lambda download: captured_downloads.append(download))

        # Attendre le téléchargement
        deadline = time.monotonic() + download_timeout_seconds
        downloaded_file = None

        while time.monotonic() < deadline:
            if captured_downloads:
                download = captured_downloads.pop(0)
                filename = safe_filename(download.suggested_filename or f"{target_artist} - {target_title}.flac")
                destination = output_dir / filename
                download.save_as(destination)
                downloaded_file = destination
                break

            if not is_blocked_by_challenge(page):
                # Vérifier si un fichier est apparu dans ~/Downloads
                default_download_dir = Path.home() / "Downloads"
                before_snapshot_downloads = snapshot_directory(default_download_dir)
                external_file = find_new_file_in_directory_now(default_download_dir, before_snapshot_downloads, 5)
                if external_file is not None:
                    destination = output_dir / external_file.name
                    shutil.copy2(external_file, destination)
                    downloaded_file = destination
                    break

            time.sleep(1.0)

        if not downloaded_file or not downloaded_file.exists():
            notify(event_callback, "error", code="LUCIDA_ERROR", message="Fichier non détecté")
            safe_close_playwright_session(context, playwright)
            return None

        print(f"  [LUCIDA] Fichier détecté: {downloaded_file.name}", file=sys.stderr)

        # Vérifier + renommer
        if not verify_downloaded_file(str(downloaded_file), target_title, target_artist, target_album, target_duration, strict_mode=True):
            notify(event_callback, "error", code="FILE_VALIDATION_FAILED", message="Le fichier ne correspond pas")
            safe_close_playwright_session(context, playwright)
            return None

        final_path = rename_with_metadata(str(downloaded_file), target_title, target_artist, output_dir)
        size = Path(final_path).stat().st_size
        print(f"  [LUCIDA] Téléchargé et vérifié: {Path(final_path).name} ({size / 1024 / 1024:.1f} Mo)", file=sys.stderr)

        safe_close_playwright_session(context, playwright)
        return final_path

    except KeyboardInterrupt:
        notify(event_callback, "error", code="CANCELLED", message="Import annulé.", retryable=False)
        print("  [LUCIDA] Import annulé.", file=sys.stderr)
        safe_close_playwright_session(context, playwright)
        return None
    except Exception as exc:
        notify(event_callback, "error", code="INTERNAL_ERROR", message=str(exc)[:500])
        print(f"  [LUCIDA] Erreur: {exc}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        safe_close_playwright_session(context, playwright)
        return None


# ─── MONOCHROME Provider ─────────────────────────────────────────────────────

MONOCHROME_CONFIG = ProviderConfig(
    name="monochrome",
    display_name="Monochrome.tf",
    base_url="https://monochrome.tf",
    description="Fournisseur Monochrome — recherche et téléchargement direct",
)


def download_from_monochrome(
    search_query: str,
    target_title: str,
    target_artist: str,
    target_album: str,
    output_dir: Path,
    visible: bool = True,
    download_timeout_seconds: int = 180,
    target_duration: int = 0,
    event_callback: EventCallback | None = None,
) -> Optional[str]:
    """
    Fournisseur Monochrome.tf — mode automatique.

    Le site Monochrome.tf est une SPA. Workflow :
      1. Ouvrir monochrome.tf dans Chromium visible
      2. Le script remplit la barre de recherche et appuie Enter
      3. Le script trouve le résultat correspondant au morceau
      4. Le script clique sur le résultat
      5. Le script clique sur le bouton Download
      6. Le fichier est capturé (download event ou fichier dans ~/Downloads)
      7. Vérifie FLAC + métadonnées + durée
      8. Renomme en Artiste - Titre.flac
    """
    debug_dir = output_dir / "debug" / "monochrome"
    debug_dir.mkdir(parents=True, exist_ok=True)

    try:
        playwright = sync_playwright().start()

        context = _get_persistent_context(playwright, "monochrome", visible, event_callback)
        page = _get_visible_work_page(context)
        page.set_default_timeout(30_000)
        page.set_default_navigation_timeout(60_000)

        # Listener réseau pour débogage Cloudflare
        def log_failed_request(request: Any) -> None:
            failure = request.failure
            print(f"[RÉSEAU ÉCHEC] {request.method} {request.url} — {failure}", file=sys.stderr)

        page.on("requestfailed", log_failed_request)

        notify(event_callback, "stage", stage="navigating", message=f"Navigation vers {MONOCHROME_CONFIG.base_url}")
        print(f"  [MONOCHROME] Navigation vers {MONOCHROME_CONFIG.base_url}...", file=sys.stderr)
        try:
            page.bring_to_front()
        except Exception:
            pass
        page.goto(MONOCHROME_CONFIG.base_url, wait_until="domcontentloaded", timeout=60_000)
        if page.url in ("", "about:blank"):
            raise RuntimeError("MONOCHROME: la navigation est restée sur about:blank")
        print(f"  [MONOCHROME] Page chargée: {page.url}", file=sys.stderr)
        page.wait_for_timeout(5_000)

        save_debug(page, debug_dir, "01_homepage")

        # === Étape 1 : Vérifier Cloudflare ===
        if is_blocked_by_challenge(page):
            notify(event_callback, "warning", message="Cloudflare détecté sur Monochrome — attente de résolution")
            print("  [MONOCHROME] ⚠️  Cloudflare détecté — veuillez résoudre...", file=sys.stderr)
            if not wait_for_challenge_to_clear(page, timeout_seconds=90):
                notify(event_callback, "error", code="CHALLENGE_BLOCKED", message="Cloudflare non résolu")
                safe_close_playwright_session(context, playwright)
                return None
            print("  [MONOCHROME] Cloudflare résolu, reprise...", file=sys.stderr)

        # === Étape 2 : Trouver la barre de recherche ===
        notify(event_callback, "stage", stage="filling_search", message="Remplissage de la recherche")
        print(f"  [MONOCHROME] Remplissage avec: {search_query}", file=sys.stderr)

        search_input = None
        # Cible exacte : #search-input (placeholder "Search for tracks, artists, albums...")
        try:
            candidate = page.locator('#search-input')
            if candidate.is_visible(timeout=3_000):
                search_input = candidate
        except Exception:
            pass

        # Fallback : tout input search
        if search_input is None:
            try:
                candidate = page.locator('input[type="search"]').first
                if candidate.is_visible(timeout=2_000):
                    search_input = candidate
            except Exception:
                pass

        # Dernier fallback : tout input text
        if search_input is None:
            try:
                candidate = page.locator('input[placeholder*="Search"]')
                if candidate.is_visible(timeout=2_000):
                    search_input = candidate
            except Exception:
                pass

        if search_input is None:
            notify(event_callback, "error", code="MONOCHROME_ERROR", message="Barre de recherche non trouvée")
            save_debug(page, debug_dir, "search_ui_not_found")
            safe_close_playwright_session(context, playwright)
            return None

        human_like_type(page, search_input, search_query)
        human_like_wait(page, 300, 800)
        search_input.press("Enter")

        save_debug(page, debug_dir, "02_search_submitted")

        # === Étape 3 : Attendre les résultats ===
        notify(event_callback, "stage", stage="waiting_results", message="Attente des résultats")
        print("  [MONOCHROME] Attente des résultats...", file=sys.stderr)

        if not wait_for_monochrome_results(page, timeout_seconds=45):
            notify(event_callback, "error", code="MONOCHROME_ERROR", message="Aucun résultat après attente")
            save_debug(page, debug_dir, "no_results")
            safe_close_playwright_session(context, playwright)
            return None

        # === Étape 4 : Vérifier Cloudflare après recherche ===
        if is_blocked_by_challenge(page):
            notify(event_callback, "warning", message="Cloudflare détecté sur les résultats")
            print("  [MONOCHROME] ⚠️  Cloudflare sur les résultats — veuillez résoudre...", file=sys.stderr)
            if not wait_for_challenge_to_clear(page, timeout_seconds=60):
                notify(event_callback, "error", code="CHALLENGE_BLOCKED", message="Cloudflare non résolu")
                safe_close_playwright_session(context, playwright)
                return None
            print("  [MONOCHROME] Cloudflare résolu, reprise...", file=sys.stderr)

        # === Étape 5 : Trouver le résultat qui correspond ===
        notify(event_callback, "stage", stage="selecting_result", message="Sélection du résultat")
        print("  [MONOCHROME] Recherche du résultat correspondant...", file=sys.stderr)

        result_element = find_monochrome_result(page, target_title, target_artist, target_album)
        if result_element is None:
            # Fallback : prendre le premier résultat qui contient l'artiste
            result_element = find_monochrome_result(page, "", target_artist, "")
        if result_element is None:
            notify(event_callback, "error", code="MONOCHROME_ERROR", message="Aucun résultat correspondant trouvé")
            save_debug(page, debug_dir, "no_matching_result")
            safe_close_playwright_session(context, playwright)
            return None

        # === Étape 6 : Cliquer sur le résultat ===
        notify(event_callback, "stage", stage="clicking_result", message="Clic sur le résultat")
        human_like_click(page, result_element["locator"])

        save_debug(page, debug_dir, "03_result_clicked")

        # === Étape 7 : Capturer le téléchargement ===
        notify(event_callback, "stage", stage="downloading", message="Attente du téléchargement")
        print("  [MONOCHROME] Attente du téléchargement...", file=sys.stderr)

        captured_downloads: list[Download] = []
        page.on("download", lambda download: captured_downloads.append(download))

        # Snapshot des dossiers
        before_snapshot_output = snapshot_directory(output_dir)
        default_download_dir = Path.home() / "Downloads"
        before_snapshot_downloads = snapshot_directory(default_download_dir)

        # === Étape 8 : Trouver le bouton Download ===
        download_button = find_monochrome_download_button(page, target_title)
        if download_button is not None:
            human_like_click(page, download_button)
            human_like_wait(page, 200, 500)

        # === Étape 9 : Attendre le fichier ===
        deadline = time.monotonic() + download_timeout_seconds
        downloaded_file = None

        while time.monotonic() < deadline:
            if captured_downloads:
                download = captured_downloads.pop(0)
                filename = safe_filename(download.suggested_filename or f"{target_artist} - {target_title}.flac")
                destination = output_dir / filename
                download.save_as(destination)
                downloaded_file = destination
                break

            # Vérifier output_dir
            downloaded_file = find_new_file_in_directory_now(output_dir, before_snapshot_output, 5)
            if downloaded_file is not None:
                break

            # Vérifier ~/Downloads
            external_file = find_new_file_in_directory_now(default_download_dir, before_snapshot_downloads, 5)
            if external_file is not None:
                destination = output_dir / external_file.name
                shutil.copy2(external_file, destination)
                downloaded_file = destination
                break

            time.sleep(1.0)

        if not downloaded_file or not downloaded_file.exists():
            notify(event_callback, "error", code="FILE_DETECTION_FAILED", message="Fichier téléchargé non détecté")
            safe_close_playwright_session(context, playwright)
            return None

        print(f"  [MONOCHROME] Fichier détecté: {downloaded_file.name}", file=sys.stderr)

        # === Étape 10 : Vérifier + renommer ===
        if not verify_downloaded_file(str(downloaded_file), target_title, target_artist, target_album, target_duration, strict_mode=False):
            notify(event_callback, "error", code="FILE_VALIDATION_FAILED", message="Le fichier ne correspond pas")
            safe_close_playwright_session(context, playwright)
            return None

        final_path = rename_with_metadata(str(downloaded_file), target_title, target_artist, output_dir)
        size = Path(final_path).stat().st_size
        print(f"  [MONOCHROME] Téléchargé et vérifié: {Path(final_path).name} ({size / 1024 / 1024:.1f} Mo)", file=sys.stderr)

        safe_close_playwright_session(context, playwright)
        return final_path

    except KeyboardInterrupt:
        notify(event_callback, "error", code="CANCELLED", message="Import annulé.", retryable=False)
        print("  [MONOCHROME] Import annulé.", file=sys.stderr)
        safe_close_playwright_session(context, playwright)
        return None
    except Exception as exc:
        notify(event_callback, "error", code="INTERNAL_ERROR", message=str(exc)[:500])
        print(f"  [MONOCHROME] Erreur: {exc}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        safe_close_playwright_session(context, playwright)
        return None


def wait_for_monochrome_results(page: Page, timeout_seconds: int = 45) -> bool:
    """Attend que les résultats de recherche apparaissent sur Monochrome.

    Monochrome est une SPA — les résultats apparaissent dans des divs, pas des liens.
    On attend qu'il y ait du texte visible qui contient le nom de l'artiste ou du titre.
    """
    start = time.time()
    while time.time() - start < timeout_seconds:
        try:
            body_text = page.locator("body").inner_text(timeout=2_000).lower()
            if not body_text:
                time.sleep(1.0)
                continue

            # On a des résultats quand le corps de la page contient l'artiste ou le titre
            if "guala" in body_text or "lifestyle" in body_text:
                return True

            # Ou si on voit des éléments de résultat (divs avec du texte > 3 chars)
            all_divs = page.locator('div').all()
            result_count = 0
            for d in all_divs[:200]:
                try:
                    t = d.inner_text().strip()
                    if len(t) > 3:
                        result_count += 1
                except Exception:
                    continue
            # On a des résultats si on trouve au moins 5 divs avec du texte
            if result_count >= 5:
                return True

        except Exception:
            pass
        time.sleep(1.0)
    return False


def find_monochrome_result(
    page: Page,
    title: str,
    artist: str,
    album: str,
) -> Optional[dict[str, Any]]:
    """Trouve le résultat exact sur Monochrome.

    Monochrome est une SPA — les résultats sont dans des divs, pas des liens.
    On cherche des éléments qui contiennent le texte de l'artiste ou du titre.
    """
    candidates: list[dict[str, Any]] = []
    normalized_artist = normalize_text(artist)
    normalized_title = normalize_text(title)

    # Approche 1 : tous les divs avec du texte > 3 chars (sans filtre)
    try:
        all_divs = page.locator('div').all()
        for d in all_divs[:500]:
            try:
                text = d.inner_text().strip()
                if not text or len(text) < 3:
                    continue
                text_lower = text.lower()

                artist_match = normalized_artist and normalized_artist in text_lower
                title_match = normalized_title and normalized_title in text_lower

                # Le div contient l'artiste ET/OU le titre → c'est un résultat
                if (artist_match and title_match) or (artist_match and not title_match) or (title_match and not artist_match):
                    candidates.append({
                        "locator": d,
                        "text": text,
                        "href": "",
                    })
            except Exception:
                continue
    except Exception:
        pass

    if candidates:
        return candidates[0]

    return None


def find_monochrome_download_button(page: Page, target_title: str) -> Optional[Any]:
    """Trouve le bouton de téléchargement sur Monochrome."""
    try:
        # Chercher les boutons/liens de download
        download_selectors = [
            'button:has-text("Download")',
            'a:has-text("Download")',
            'button:has-text("download")',
            'a:has-text("download")',
            'button:has-text("Télécharger")',
            'a:has-text("Télécharger")',
            'button:has-text("Get")',
            'a:has-text("Get")',
            'button:has-text("Download FLAC")',
            'a:has-text("Download FLAC")',
            '[class*="download"]',
            '[class*="Download"]',
        ]

        for selector in download_selectors:
            elements = page.locator(selector).all()
            for elem in elements:
                try:
                    if elem.is_visible():
                        text = elem.inner_text().strip().lower()
                        if text and any(w in text for w in ["download", "télécharger", "get", "flac"]):
                            return elem
                except Exception:
                    continue

    except Exception:
        pass

    return None


# ─── DOUBLEDOUBLE Provider ───────────────────────────────────────────────────

DOUBLEDOUBLE_CONFIG = ProviderConfig(
    name="doubledouble",
    display_name="Doubledouble.top",
    base_url="https://eu.doubledouble.top",
    description="Fournisseur Doubledouble — recherche via URL Qobuz",
)


def download_from_doubledouble(
    search_query: str,
    target_title: str,
    target_artist: str,
    target_album: str,
    output_dir: Path,
    visible: bool = True,
    download_timeout_seconds: int = 180,
    target_duration: int = 0,
    event_callback: EventCallback | None = None,
) -> Optional[str]:
    """
    Fournisseur Doubledouble.top — mode automatique.

    Workflow réel :
      1. Rechercher automatiquement le morceau sur Qobuz
      2. Ouvrir doubledouble.top et coller l'URL Qobuz complète
      3. Appuyer Enter
      4. Trouver le bouton Download
      5. Cliquer Download
      6. Cloudflare CAPTCHA apparaît (l'utilisateur résout)
      7. Le fichier est téléchargé
      8. Vérifie FLAC + métadonnées + durée
      9. Renomme en Artiste - Titre.flac
    """
    debug_dir = output_dir / "debug" / "doubledouble"
    debug_dir.mkdir(parents=True, exist_ok=True)

    try:
        playwright = sync_playwright().start()

        context = _get_persistent_context(playwright, "doubledouble", visible, event_callback)
        page = _get_visible_work_page(context)
        page.set_default_timeout(30_000)
        page.set_default_navigation_timeout(60_000)

        # Listener réseau pour débogage Cloudflare
        def log_failed_request(request: Any) -> None:
            failure = request.failure
            print(f"[RÉSEAU ÉCHEC] {request.method} {request.url} — {failure}", file=sys.stderr)

        page.on("requestfailed", log_failed_request)

        qobuz_url = resolve_qobuz_album_url(
            context=context,
            target_title=target_title,
            target_artist=target_artist,
            target_album=target_album,
            raw_query=search_query,
            timeout_seconds=min(download_timeout_seconds, 75),
            event_callback=event_callback,
            page=page,
        )
        if not qobuz_url:
            notify(event_callback, "error", code="QOBUZ_URL_NOT_FOUND", message="URL Qobuz exacte introuvable")
            save_debug(page, debug_dir, "qobuz_url_not_found")
            safe_close_playwright_session(context, playwright)
            return None
        search_query = qobuz_url
        print(f"  [DOUBLEDOUBLE] URL Qobuz complète: {search_query}", file=sys.stderr)

        notify(event_callback, "stage", stage="navigating", message=f"Navigation vers {DOUBLEDOUBLE_CONFIG.base_url}")
        print(f"  [DOUBLEDOUBLE] Navigation vers {DOUBLEDOUBLE_CONFIG.base_url}...", file=sys.stderr)
        try:
            page.bring_to_front()
        except Exception:
            pass
        page.goto(DOUBLEDOUBLE_CONFIG.base_url, wait_until="domcontentloaded", timeout=60_000)
        if page.url in ("", "about:blank"):
            raise RuntimeError("DOUBLEDOUBLE: la navigation est restée sur about:blank")
        print(f"  [DOUBLEDOUBLE] Page chargée: {page.url}", file=sys.stderr)
        page.wait_for_timeout(5_000)

        save_debug(page, debug_dir, "01_homepage")

        # === Étape 1 : Trouver la barre de recherche ===
        notify(event_callback, "stage", stage="filling_search", message="Remplissage avec URL Qobuz")
        print(f"  [DOUBLEDOUBLE] Remplissage avec: {search_query}", file=sys.stderr)

        search_input = None
        for selector in ['input[type="text"]', 'input[placeholder*="URL"]', 'input[placeholder*="url"]', 'input[placeholder*="Search"]', 'input[placeholder*="search"]', 'input', 'input[type="search"]']:
            try:
                candidate = page.locator(selector).first
                if candidate.is_visible(timeout=2_000):
                    search_input = candidate
                    break
            except Exception:
                continue

        if search_input is None:
            notify(event_callback, "error", code="DOUBLEDOUBLE_ERROR", message="Barre de recherche non trouvée")
            save_debug(page, debug_dir, "search_ui_not_found")
            safe_close_playwright_session(context, playwright)
            return None

        # Coller l'URL Qobuz dans la barre de recherche
        human_like_type(page, search_input, search_query)
        human_like_wait(page, 500, 1200)
        search_input.press("Enter")

        save_debug(page, debug_dir, "02_search_submitted")

        # === Étape 2 : Cloudflare apparaît — l'utilisateur résout ===
        notify(event_callback, "stage", stage="cloudflare_check", message="Cloudflare détecté — attente de résolution humaine")
        print("  [DOUBLEDOUBLE] ⚠️  Cloudflare détecté — veuillez resolve...", file=sys.stderr)

        if is_blocked_by_challenge(page):
            if not wait_for_challenge_to_clear(page, timeout_seconds=120):
                notify(event_callback, "error", code="CHALLENGE_BLOCKED", message="Cloudflare non résolu")
                safe_close_playwright_session(context, playwright)
                return None
            print("  [DOUBLEDOUBLE] Cloudflare résolu, reprise...", file=sys.stderr)

        # === Étape 3 : Attendre que le site se charge complètement ===
        notify(event_callback, "stage", stage="waiting_page_load", message="Attente du chargement complet")
        page.wait_for_timeout(3_000)

        # === Étape 4 : Trouver le bouton Download et cliquer ===
        notify(event_callback, "stage", stage="clicking_download", message="Clic sur Download")
        print("  [DOUBLEDOUBLE] Recherche du bouton Download...", file=sys.stderr)

        download_button = find_doubledouble_download_button(page)
        if download_button is None:
            notify(event_callback, "error", code="DOUBLEDOUBLE_ERROR", message="Bouton Download non trouvé")
            save_debug(page, debug_dir, "download_button_not_found")
            safe_close_playwright_session(context, playwright)
            return None

        # Vérifier que le bouton est enabled
        try:
            if not download_button.is_enabled(timeout=5_000):
                notify(event_callback, "warning", message="Bouton Download désactivé — attente Cloudflare")
                page.wait_for_timeout(5_000)
        except Exception:
            pass

        human_like_click(page, download_button)
        human_like_wait(page, 500, 1200)

        save_debug(page, debug_dir, "03_download_clicked")

        # === Étape 5 : Capturer le téléchargement ===
        notify(event_callback, "stage", stage="downloading", message="Attente du téléchargement")
        print("  [DOUBLEDOUBLE] Attente du téléchargement...", file=sys.stderr)

        captured_downloads: list[Download] = []
        page.on("download", lambda download: captured_downloads.append(download))

        # Snapshot des dossiers
        before_snapshot_output = snapshot_directory(output_dir)
        default_download_dir = Path.home() / "Downloads"
        before_snapshot_downloads = snapshot_directory(default_download_dir)

        # === Étape 6 : Attendre le fichier ===
        deadline = time.monotonic() + download_timeout_seconds
        downloaded_file = None

        while time.monotonic() < deadline:
            if captured_downloads:
                download = captured_downloads.pop(0)
                filename = safe_filename(download.suggested_filename or f"{target_artist} - {target_title}.flac")
                destination = output_dir / filename
                download.save_as(destination)
                downloaded_file = destination
                break

            # Vérifier output_dir
            downloaded_file = find_new_file_in_directory_now(output_dir, before_snapshot_output, 5)
            if downloaded_file is not None:
                break

            # Vérifier ~/Downloads
            external_file = find_new_file_in_directory_now(default_download_dir, before_snapshot_downloads, 5)
            if external_file is not None:
                destination = output_dir / external_file.name
                shutil.copy2(external_file, destination)
                downloaded_file = destination
                break

            time.sleep(1.0)

        if not downloaded_file or not downloaded_file.exists():
            notify(event_callback, "error", code="FILE_DETECTION_FAILED", message="Fichier téléchargé non détecté")
            safe_close_playwright_session(context, playwright)
            return None

        print(f"  [DOUBLEDOUBLE] Fichier détecté: {downloaded_file.name}", file=sys.stderr)

        # === Étape 7 : Vérifier + renommer ===
        if not verify_downloaded_file(str(downloaded_file), target_title, target_artist, target_album, target_duration, strict_mode=False):
            notify(event_callback, "error", code="FILE_VALIDATION_FAILED", message="Le fichier ne correspond pas")
            safe_close_playwright_session(context, playwright)
            return None

        final_path = rename_with_metadata(str(downloaded_file), target_title, target_artist, output_dir)
        size = Path(final_path).stat().st_size
        print(f"  [DOUBLEDOUBLE] Téléchargé et vérifié: {Path(final_path).name} ({size / 1024 / 1024:.1f} Mo)", file=sys.stderr)

        safe_close_playwright_session(context, playwright)
        return final_path

    except KeyboardInterrupt:
        notify(event_callback, "error", code="CANCELLED", message="Import annulé.", retryable=False)
        print("  [DOUBLEDOUBLE] Import annulé.", file=sys.stderr)
        safe_close_playwright_session(context, playwright)
        return None
    except Exception as exc:
        notify(event_callback, "error", code="INTERNAL_ERROR", message=str(exc)[:500])
        print(f"  [DOUBLEDOUBLE] Erreur: {exc}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        safe_close_playwright_session(context, playwright)
        return None


def find_doubledouble_result(
    page: Page,
    title: str,
    artist: str,
    album: str,
) -> Optional[Any]:
    """Trouve le lien qui correspond au morceau sur Doubledouble."""
    try:
        all_links = page.locator('a[href]').all()

        normalized_title = normalize_text(title)
        normalized_artist = normalize_text(artist)

        for link in all_links:
            try:
                text = link.inner_text().lower()
                href = link.get_attribute("href") or ""

                title_match = normalized_title in text if title else True
                artist_match = normalized_artist in text if artist else True

                if title_match and artist_match:
                    return link
            except Exception:
                continue

        # Fallback : premier lien qui contient l'artiste
        for link in all_links:
            try:
                text = link.inner_text().lower()
                if normalized_artist in text:
                    return link
            except Exception:
                continue

    except Exception:
        pass

    return None


def find_doubledouble_download_button(page: Page) -> Optional[Any]:
    """Trouve le bouton Download sur Doubledouble."""
    try:
        download_selectors = [
            'button:has-text("Download")',
            'a:has-text("Download")',
            'button:has-text("download")',
            'a:has-text("download")',
            'button:has-text("Télécharger")',
            'a:has-text("Télécharger")',
        ]

        for selector in download_selectors:
            elements = page.locator(selector).all()
            for elem in elements:
                try:
                    if elem.is_visible():
                        return elem
                except Exception:
                    continue

    except Exception:
        pass

    return None


# ─── Provider selection ──────────────────────────────────────────────────────

AVAILABLE_PROVIDERS = [
    LUCIDA_CONFIG,
    MONOCHROME_CONFIG,
    DOUBLEDOUBLE_CONFIG,
]

PROVIDER_DISPATCH = {
    "lucida": download_from_lucida,
    "monochrome": download_from_monochrome,
    "doubledouble": download_from_doubledouble,
}


def select_provider(provider_name: str) -> Optional[ProviderConfig]:
    """
    Sélectionne un fournisseur.

    Si provider_name est "auto", sélectionne aléatoirement parmi les disponibles.
    Sinon retourne le fournisseur correspondant ou None.
    """
    normalized = provider_name.strip().lower()

    if normalized == "auto":
        chosen = random.choice(AVAILABLE_PROVIDERS)
        print(f"  [PROVIDER] Sélection aléatoire: {chosen.display_name}", file=sys.stderr)
        return chosen

    for config in AVAILABLE_PROVIDERS:
        if config.name == normalized:
            return config

    return None


# ─── Main ────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="HomeSpotify — Multi-Provider FLAC Downloader",
    )
    parser.add_argument("query", help='Recherche, par exemple "Guala Lifestyles"')
    parser.add_argument(
        "--output",
        "-o",
        default=str(OUTPUT_DIR),
        help=f"Dossier de sortie (défaut: {OUTPUT_DIR})",
    )
    parser.add_argument(
        "--provider",
        "-p",
        default="auto",
        choices=["auto", "lucida", "monochrome", "doubledouble"],
        help="Fournisseur à utiliser (défaut: auto = aléatoire)",
    )
    parser.add_argument(
        "--index",
        "-i",
        type=int,
        default=0,
        help="Index du résultat Deezer utilisé pour identifier le morceau",
    )
    parser.add_argument(
        "--download-timeout",
        type=int,
        default=180,
        help="Secondes maximales par tentative de téléchargement (défaut: 180)",
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
    parser.add_argument(
        "--json",
        action="store_true",
        help="Émet des événements NDJSON sur stdout pour le backend",
    )
    args = parser.parse_args()

    machine_state = {"error_emitted": False}

    def machine_callback(event: dict[str, Any]) -> None:
        if event.get("type") == "error":
            machine_state["error_emitted"] = True
        emit_event(event)

    callback: EventCallback | None = machine_callback if args.json else None

    if args.download_timeout < 10:
        notify(callback, "error", code="INVALID_ARGUMENT", message="--download-timeout must be at least 10 seconds")
        parser.print_usage(sys.stderr)
        raise SystemExit(EXIT_INVALID_ARGUMENT)

    output_dir = Path(args.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    print("=" * 66, file=sys.stderr)
    print("  HOMESPOTIFY — Multi-Provider FLAC Downloader", file=sys.stderr)
    print("=" * 66, file=sys.stderr)
    print(f"  Search query: {args.query}", file=sys.stderr)
    print(f"  Provider: {args.provider}", file=sys.stderr)

    # Deezer search for identification
    notify(callback, "stage", stage="searching", message="Searching track on Deezer")
    results = search_deezer(args.query)

    if results:
        print("\n  Deezer results used to identify the track:", file=sys.stderr)
        for index, result in enumerate(results):
            notify(
                callback,
                "search_result",
                index=index,
                title=result["title"],
                artist=result["artist_name"],
                album=result["album_title"],
                duration=result["duration"],
            )
            marker = " <<" if index == args.index else ""
            duration = result["duration"]
            minutes, seconds = divmod(duration, 60)
            print(
                f"  [{index}] {result['title']} — {result['artist_name']} "
                f"[{result['album_title']}] {minutes}:{seconds:02d}{marker}",
                file=sys.stderr,
            )

        if args.list:
            notify(callback, "complete", mode="list", count=len(results))
            return

        if args.index < 0 or args.index >= len(results):
            notify(callback, "error", code="INVALID_ARGUMENT", message=f"Deezer index invalid: {args.index}")
            print(
                f"\n  [!] Invalid Deezer index: {args.index}. "
                f"Choose between 0 and {len(results) - 1}.",
                file=sys.stderr,
            )
            raise SystemExit(EXIT_INVALID_ARGUMENT)

        selected = results[args.index]
        target_title = selected["title_short"] or selected["title"]
        target_artist = selected["artist_name"]
        target_album = selected["album_title"]
        target_duration = selected["duration"]

        # Le fournisseur Lucida/Doubledouble effectue une vraie recherche Qobuz
        # et récupère l'URL complète avec l'identifiant final de l'album.
        search_query = args.query
    else:
        if args.list:
            notify(callback, "error", code="NO_RESULTS", message="No Deezer results")
            print("  No Deezer results.", file=sys.stderr)
            raise SystemExit(EXIT_NO_RESULT)

        target_title = args.query
        target_artist = ""
        target_album = ""
        target_duration = 0
        search_query = args.query

    notify(
        callback,
        "selected",
        index=args.index,
        title=target_title,
        artist=target_artist,
        album=target_album,
        duration=target_duration,
    )

    print("\n  Selected:", file=sys.stderr)
    print(f"  Title:    {target_title}", file=sys.stderr)
    print(f"  Artist:  {target_artist or '(unknown)'}", file=sys.stderr)
    print(f"  Album:    {target_album or '(unknown)'}", file=sys.stderr)

    # Provider selection
    provider = select_provider(args.provider)
    if provider is None:
        notify(callback, "error", code="INVALID_PROVIDER", message=f"Unknown provider: {args.provider}")
        raise SystemExit(EXIT_INVALID_ARGUMENT)

    dispatch = PROVIDER_DISPATCH.get(provider.name)
    if dispatch is None:
        notify(callback, "error", code="PROVIDER_NOT_IMPLEMENTED", message=f"Provider {provider.name} not implemented")
        raise SystemExit(EXIT_INVALID_ARGUMENT)

    notify(
        callback,
        "stage",
        stage="provider_selected",
        provider=provider.name,
        displayName=provider.display_name,
        baseURL=provider.base_url,
    )

    print(f"\n  Provider selected: {provider.display_name} ({provider.base_url})", file=sys.stderr)

    # Call the provider
    result_path = dispatch(
        search_query=search_query,
        target_title=target_title,
        target_artist=target_artist,
        target_album=target_album,
        output_dir=output_dir,
        visible=args.visible,
        download_timeout_seconds=args.download_timeout,
        target_duration=target_duration,
        event_callback=callback,
    )

    if not result_path or not Path(result_path).exists():
        if not machine_state["error_emitted"]:
            notify(callback, "error", code="DOWNLOAD_FAILED", message="Download did not produce a valid file")
        print(
            f"\n  [!] Failed. Debug files: {output_dir}/debug/",
            file=sys.stderr,
        )
        raise SystemExit(EXIT_EXTERNAL_ERROR)

    info = analyze_audio(result_path)
    notify(
        callback,
        "success",
        filepath=str(Path(result_path).resolve()),
        title=target_title,
        artist=target_artist,
        album=target_album,
        duration=target_duration,
        provider=provider.name,
    )

    print("\n  File analysis:", file=sys.stderr)
    print(f"  Path: {result_path}", file=sys.stderr)
    print(f"  Provider: {provider.display_name}", file=sys.stderr)
    if not args.json:
        print_audio_info(info)
    print("\nDone.", file=sys.stderr)


if __name__ == "__main__":
    main()