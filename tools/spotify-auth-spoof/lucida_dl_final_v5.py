#!/usr/bin/env python3
"""
Lucida.to FLAC Downloader — Final v5 (Recherche Texte)
======================================================

Nouveau fonctionnement:
1. Recherche Deezer pour identifier titre/artiste
2. Envoi du texte "Artiste - Titre" dans lucida.to (PAS l'URL)
3. Attente de la liste "Tracks"
4. Sélection automatique du bon morceau
5. Ouverture de la fiche
6. Sélection "Original format (highest quality)"
7. Clic sur "download track"
8. Sauvegarde dans storage/imports

Usage:
  python lucida_dl_final_v5.py "Josman Intro"
  python lucida_dl_final_v5.py "Josman Intro" --visible
  python lucida_dl_final_v5.py "Josman Intro" --list
  python lucida_dl_final_v5.py "Josman Intro" --index 1
  python lucida_dl_final_v5.py "Josman Intro" --lucida-index 1
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import quote

try:
    from playwright.sync_api import sync_playwright
except ImportError:
    print("[!] pip install playwright && playwright install chromium", file=sys.stderr)
    sys.exit(1)

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

BASE_URL = "https://lucida.to"
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)
OUTPUT_DIR = "storage/imports"


def create_session() -> requests.Session:
    session = requests.Session()
    session.headers.update({
        "User-Agent": USER_AGENT,
        "Accept": "*/*",
        "Accept-Language": "en-US,en;q=0.9",
    })
    retry = Retry(total=3, backoff_factor=1, status_forcelist=[429, 500, 502, 503])
    session.mount("https://", HTTPAdapter(max_retries=retry))
    session.mount("http://", HTTPAdapter(max_retries=retry))
    return session


def search_deezer(query: str, limit: int = 5) -> list:
    """Rechercher un track via l'API publique Deezer."""
    url = f"https://api.deezer.com/search?q={quote(query)}&limit={limit}"
    try:
        session = create_session()
        resp = session.get(url, timeout=15)
        resp.raise_for_status()
        data = resp.json()
        results = []
        for track in data.get("data", []):
            results.append({
                "title": track.get("title", ""),
                "artist_name": track.get("artist", {}).get("name", ""),
                "album_title": track.get("album", {}).get("title", ""),
                "duration": track.get("duration", 0),
            })
        return results
    except Exception as e:
        print(f"  [!] Erreur Deezer API: {e}", file=sys.stderr)
        return []


def download_via_playwright(search_text: str, expected_title: str, expected_artist: str, output_dir: str, visible: bool = False, lucida_index: int = -1) -> str | None:
    """
    Utilise Playwright pour interagir avec lucida.to en mode recherche texte.
    """
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)
    debug_dir = output_path / "debug"
    debug_dir.mkdir(parents=True, exist_ok=True)

    print(f"  [~] Playwright{' (visible)' if visible else ' (headless)'}: recherche '{search_text}'", file=sys.stderr)

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(
                headless=not visible,
                args=[
                    "--disable-blink-features=AutomationControlled",
                    "--no-sandbox",
                ],
            )
            context = browser.new_context(
                user_agent=USER_AGENT,
                viewport={"width": 1920, "height": 1080},
                locale="en-US",
                accept_downloads=True,
            )
            page = context.new_page()

            # Init script minimal
            context.add_init_script("""
                Object.defineProperty(navigator, 'webdriver', { get: () => false });
            """)

            # Logging
            def handle_console_message(msg):
                if "[i18n]: 'my' locale is non-standard." in msg.text:
                    return
                print(f"  [CONSOLE] {msg.type}: {msg.text}", file=sys.stderr)

            def handle_request_failed(request):
                if "/cdn-cgi/rum" in request.url:
                    return
                print(f"  [REQ FAIL] {request.method} {request.url} — {request.failure}", file=sys.stderr)

            page.on("console", handle_console_message)
            page.on("pageerror", lambda error: print(f"  [PAGE ERROR] {error}", file=sys.stderr))
            page.on("requestfailed", handle_request_failed)

            # Interception réseau
            download_urls = []

            def handle_response(response):
                url = response.url
                if any(ext in url.lower() for ext in [".flac", ".mp3", ".wav", ".ogg", ".m4a"]):
                    download_urls.append(url)
                    print(f"  [~] URL audio: {url[:100]}", file=sys.stderr)
                elif "attachment" in response.headers.get("content-disposition", ""):
                    download_urls.append(url)
                    print(f"  [~] URL attachment: {url[:100]}", file=sys.stderr)

            page.on("response", handle_response)

            # ── 1. Navigation vers lucida.to ──
            print(f"  [1/6] Chargement de {BASE_URL}...", file=sys.stderr)
            response = page.goto(BASE_URL, wait_until="domcontentloaded", timeout=60000)
            status = response.status if response else None
            print(f"  [HTTP] Statut: {status}", file=sys.stderr)

            page.wait_for_timeout(3000)
            page.screenshot(path=str(debug_dir / "step1_home.png"), full_page=True)

            if status is not None and status >= 400:
                print(f"  [!] Lucida refuse la navigation: HTTP {status}.", file=sys.stderr)
                browser.close()
                return None

            # Laisser SvelteKit s'initialiser
            page.wait_for_timeout(5000)

            # ── 2. Recherche texte ──
            print(f"  [2/6] Recherche: '{search_text}'", file=sys.stderr)

            url_input = page.locator('input#download').first
            if url_input.count() and url_input.is_visible():
                url_input.fill(search_text)
                print(f"  [~] Texte saisi", file=sys.stderr)
            else:
                print("  [!] Pas d'input URL visible!", file=sys.stderr)
                page.screenshot(path=str(debug_dir / "no_input.png"), full_page=True)
                browser.close()
                return None

            # Appuyer sur Enter pour rechercher
            page.keyboard.press("Enter")
            print(f"  [~] Enter pressé", file=sys.stderr)

            # ── 3. Attente des résultats "Tracks" ──
            print(f"  [3/6] Attente des résultats...", file=sys.stderr)

            found_tracks = False
            for elapsed in range(5, 61, 5):
                page.wait_for_timeout(5_000)
                body = page.locator("body").inner_text(timeout=3000)

                if "Tracks" in body or "tracks" in body.lower():
                    found_tracks = True
                    print(f"  [~] Résultats trouvés après {elapsed}s!", file=sys.stderr)
                    page.screenshot(path=str(debug_dir / f"step3_results_{elapsed}s.png"), full_page=True)
                    (debug_dir / f"step3_results_{elapsed}s.html").write_text(page.content(), encoding="utf-8")
                    break
                else:
                    print(f"  [~] {elapsed}s: pas encore de résultats", file=sys.stderr)

            if not found_tracks:
                print("  [!] Aucun résultat après 60s.", file=sys.stderr)
                page.screenshot(path=str(debug_dir / "no_results.png"), full_page=True)
                browser.close()
                return None

            # Lister les résultats Tracks
            print(f"  [~] Lister les tracks...", file=sys.stderr)

            # Chercher les liens de tracks (généralement dans une liste)
            track_links = page.locator("a[href^='/track/']").all()
            print(f"  [DOM] {len(track_links)} liens /track/ trouvés", file=sys.stderr)

            track_candidates = []
            for i, link in enumerate(track_links):
                try:
                    text = (link.text_content() or "").strip()
                    href = link.get_attribute("href") or ""
                    print(f"  [TRACK {i}] text={text[:120]!r} href={href!r}", file=sys.stderr)
                    track_candidates.append({"text": text, "href": href, "element": link})
                except Exception:
                    continue

            if not track_candidates:
                print("  [!] Aucun lien track trouvé.", file=sys.stderr)
                page.screenshot(path=str(debug_dir / "no_track_links.png"), full_page=True)
                browser.close()
                return None

            # Trouver le meilleur match
            title_lower = expected_title.lower()
            artist_lower = expected_artist.lower()

            best_match = None
            best_score = 0

            for i, candidate in enumerate(track_candidates):
                text_lower = candidate["text"].lower()
                score = 0
                if title_lower in text_lower:
                    score += 10
                if artist_lower in text_lower:
                    score += 10
                # Match partiel
                for word in title_lower.split():
                    if word in text_lower and len(word) > 3:
                        score += 2
                for word in artist_lower.split():
                    if word in text_lower and len(word) > 3:
                        score += 2

                print(f"  [MATCH {i}] score={score} text={candidate['text'][:80]!r}", file=sys.stderr)

                if score > best_score:
                    best_score = score
                    best_match = candidate

            # Si lucida_index spécifié, utiliser ce résultat
            if lucida_index >= 0 and lucida_index < len(track_candidates):
                best_match = track_candidates[lucida_index]
                print(f"  [~] Utilisation du résultat #{lucida_index}", file=sys.stderr)

            if not best_match or best_score == 0:
                print("  [!] Aucun match trouvé pour le titre/artiste.", file=sys.stderr)
                page.screenshot(path=str(debug_dir / "no_match.png"), full_page=True)
                browser.close()
                return None

            print(f"  [~] Track sélectionné: {best_match['text'][:100]}", file=sys.stderr)

            # ── 4. Ouvrir la fiche track ──
            print(f"  [4/6] Ouverture de la fiche track...", file=sys.stderr)
            best_match["element"].click()
            page.wait_for_timeout(5000)
            page.screenshot(path=str(debug_dir / "step4_track_page.png"), full_page=True)
            print(f"  [~] URL track: {page.url}", file=sys.stderr)

            # ── 5. Sélectionner "Original format (highest quality)" ──
            print(f"  [5/6] Sélection format audio...", file=sys.stderr)

            # Chercher le select de format
            format_select = page.locator("select[name='format'], select#format").first
            if format_select.count() and format_select.is_visible():
                # Essayer de sélectionner "Original format"
                try:
                    format_select.select_option("original")
                    print(f"  [~] Format: original", file=sys.stderr)
                except Exception:
                    # Essayer par texte
                    try:
                        format_select.select_option(label="* Original format (highest quality)")
                        print(f"  [~] Format: original (par label)", file=sys.stderr)
                    except Exception:
                        print(f"  [~] Format: défaut (pas de sélection)", file=sys.stderr)
            else:
                print(f"  [~] Pas de select format (format par défaut)", file=sys.stderr)

            page.wait_for_timeout(2000)

            # ── 6. Clic sur "download track" ──
            print(f"  [6/6] Téléchargement...", file=sys.stderr)

            # Chercher le bouton "download track" (strict)
            download_btn = None
            download_selectors = [
                page.get_by_role("button", name=re.compile(r"^\\s*download\\s+track\\s*$", re.IGNORECASE)),
                page.locator('a[download]:has-text("download track"):above'),
                page.locator('button:has-text("download track"):above'),
            ]

            for selector in download_selectors:
                if selector.count() > 0:
                    btn = selector.first
                    if btn.is_visible():
                        btn_text = (btn.text_content() or "").strip().lower()
                        # Exclure les faux positifs
                        if "recent" not in btn_text and "library" not in btn_text:
                            download_btn = btn
                            print(f"  [~] Bouton Download trouvé: '{btn_text}'", file=sys.stderr)
                            break

            # Fallback: chercher n'importe quel bouton avec "download"
            if not download_btn:
                all_buttons = page.locator("button:visible, a[download]:visible").all()
                for btn in all_buttons:
                    try:
                        text = (btn.text_content() or "").strip().lower()
                        if "download" in text and "track" in text:
                            if "recent" not in text and "library" not in text:
                                download_btn = btn
                                print(f"  [~] Bouton Download (fallback): '{text}'", file=sys.stderr)
                                break
                    except Exception:
                        continue

            if download_btn:
                try:
                    with page.expect_download(timeout=120000) as dl_info:
                        download_btn.click()
                    dl = dl_info.value
                    filename = dl.suggested_filename or "track.flac"
                    filename = re.sub(r'[^\w\-.() ]', '_', filename)
                    save_path = output_path / filename
                    dl.save_as(save_path)
                    size = save_path.stat().st_size
                    print(f"  [~] ✅ {save_path.name} ({size/1024/1024:.1f} MB)", file=sys.stderr)
                    browser.close()
                    return str(save_path)
                except Exception as e:
                    print(f"  [!] Download attendu mais pas reçu: {e}", file=sys.stderr)
            else:
                print("  [!] Pas de bouton 'download track' trouvé!", file=sys.stderr)

            # Diagnostic final
            page.screenshot(path=str(debug_dir / "final.png"), full_page=True)
            (debug_dir / "final.html").write_text(page.content(), encoding="utf-8")
            print(f"  [~] {len(download_urls)} URL(s) capturée(s) via réseau", file=sys.stderr)
            browser.close()

            if download_urls:
                return download_with_cookies(download_urls[-1], context.cookies(), "track.flac", str(output_path))

            return None

    except Exception as e:
        print(f"  [!] Erreur: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        return None


def download_with_cookies(url: str, cookies: list, filename: str, output_dir: str) -> str | None:
    """Télécharger avec les cookies du navigateur Playwright."""
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)
    save_path = output_path / (filename or "track.flac")

    try:
        session = create_session()
        for cookie in cookies:
            session.cookies.set(cookie["name"], cookie["value"], domain=cookie.get("domain", ""))

        resp = session.get(url, stream=True, timeout=300, allow_redirects=True)
        resp.raise_for_status()

        cd = resp.headers.get("content-disposition", "")
        if "filename=" in cd:
            fn = re.search(r'filename[^;=\n]*=([^\s"\\\']*)', cd)
            if fn:
                filename = fn.group(1).strip('"\'')
                save_path = output_path / filename

        total = int(resp.headers.get("content-length", 0))
        downloaded = 0
        with open(save_path, "wb") as f:
            for chunk in resp.iter_content(chunk_size=8192):
                f.write(chunk)
                downloaded += len(chunk)
                if total:
                    pct = downloaded / total * 100
                    print(f"  [~] {pct:.0f}% ({downloaded/1024/1024:.1f}/{total/1024/1024:.1f} MB)", end="\r", file=sys.stderr)

        size = save_path.stat().st_size
        print(f"\n  [~] ✅ {save_path.name} ({size/1024/1024:.1f} MB)", file=sys.stderr)
        return str(save_path)
    except Exception as e:
        print(f"  [!] Download error: {e}", file=sys.stderr)
        if save_path.exists():
            save_path.unlink()
        return None


def analyze_audio(filepath: str) -> dict:
    """Analyser un fichier audio avec ffprobe."""
    ffprobe = shutil.which("ffprobe") or shutil.which("ffmpeg")
    if not ffprobe:
        return {"error": "ffprobe/ffmpeg non trouve"}
    try:
        cmd = [
            ffprobe, "-v", "quiet",
            "-show_entries", "stream=codec_name,sample_rate,channels,bits_per_raw_sample",
            "-show_entries", "format=format_name,size,bit_rate,duration",
            "-of", "json", filepath
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        return json.loads(result.stdout)
    except Exception as e:
        return {"error": str(e)}


def print_audio_info(info: dict):
    """Afficher les informations audio."""
    if "error" in info:
        return
    streams = info.get("streams", [])
    fmt = info.get("format", {})
    if streams:
        s = streams[0]
        print(f"  Codec:      {s.get('codec_name', '?')}")
        print(f"  Sample Rate: {s.get('sample_rate', '?')} Hz")
        print(f"  Channels:    {s.get('channels', '?')}")
        bps = s.get("bits_per_raw_sample", "?")
        if bps != "?":
            print(f"  Bit Depth:   {bps} bits")
    print(f"  Format:     {fmt.get('format_name', '?')}")
    size = float(fmt.get("size", 0))
    print(f"  Size:       {size/1024/1024:.1f} MB")
    dur = float(fmt.get("duration", 0))
    print(f"  Duration:   {dur:.1f}s")


def main():
    parser = argparse.ArgumentParser(
        description="Lucida.to FLAC Downloader — Final v5 (Recherche Texte)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("query", help="Artiste + titre (ex: 'Josman Intro')")
    parser.add_argument("--output", "-o", default=OUTPUT_DIR)
    parser.add_argument("--list", "-l", action="store_true")
    parser.add_argument("--index", "-i", type=int, default=0, help="Index Deezer")
    parser.add_argument("--visible", action="store_true", help="Mode navigateur visible")
    parser.add_argument("--lucida-index", type=int, default=-1, help="Index Lucida (force le résultat)")
    args = parser.parse_args()

    print("=" * 60, file=sys.stderr)
    print("  LUCIDA.TO FLAC DOWNLOADER — Final v5", file=sys.stderr)
    print("=" * 60, file=sys.stderr)
    print(f"  Query: {args.query}", file=sys.stderr)
    print("=" * 60, file=sys.stderr)

    # ── 1. Recherche Deezer ──
    print(f"\n  [1/3] Recherche Deezer...", file=sys.stderr)
    results = search_deezer(args.query)

    if not results:
        print("\n  [!] Aucun resultat.", file=sys.stderr)
        sys.exit(1)

    print(f"\n  [{len(results)}] resultats:", file=sys.stderr)
    for i, r in enumerate(results):
        marker = " <<" if i == args.index else ""
        print(f"  [{i}] {r['title']} — {r['artist_name']}{marker}", file=sys.stderr)

    if args.list:
        sys.exit(0)

    # ── 2. Téléchargement ──
    idx = min(args.index, len(results) - 1)
    selected = results[idx]
    search_text = f"{selected['artist_name']} {selected['title']}"
    print(f"\n  [2/3] Telechargement...", file=sys.stderr)
    print(f"  [~] Recherche Lucida: '{search_text}'", file=sys.stderr)

    result_path = download_via_playwright(
        search_text=search_text,
        expected_title=selected['title'],
        expected_artist=selected['artist_name'],
        output_dir=args.output,
        visible=args.visible,
        lucida_index=args.lucida_index,
    )

    # ── 3. Analyse ──
    if result_path and Path(result_path).exists():
        size = Path(result_path).stat().st_size
        print(f"\n  [3/3] Analyse:", file=sys.stderr)
        print(f"  File: {result_path}", file=sys.stderr)
        print(f"  Size: {size/1024/1024:.1f} MB", file=sys.stderr)
        info = analyze_audio(result_path)
        print_audio_info(info)
        print(f"\nDone!", file=sys.stderr)
    else:
        print(f"\n  [!] Echec.", file=sys.stderr)
        print(f"  Debug: {args.output}/debug/", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()