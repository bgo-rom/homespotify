#!/usr/bin/env python3
"""
Lucida.to FLAC Downloader — Selenium Automation v4
Structure confirmée :
  - input#download[type='text'] pour la recherche
  - input#go[type='submit'] pour soumettre
  - select pour choisir le service (Qobuz priorisé pour FLAC)

Usage:
  python lucida_selenium_dl.py "Josman" "Intro"
  python lucida_selenium_dl.py --spotify-url "https://open.spotify.com/track/6qvyN6NTUpdfOJRYjtSSd7"
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

try:
    from selenium import webdriver
    from selenium.webdriver.chrome.options import Options
    from selenium.webdriver.common.by import By
    from selenium.webdriver.common.keys import Keys
    from selenium.webdriver.support.ui import WebDriverWait, Select
    from selenium.webdriver.support import expected_conditions as EC
    from selenium.common.exceptions import TimeoutException, WebDriverException
    SELENIUM_AVAILABLE = True
except ImportError:
    SELENIUM_AVAILABLE = False
    print("[!] Selenium non disponible. Installez-le avec: pip install selenium", file=sys.stderr)


def download_with_selenium(stream_url: str, output_dir: str, artist: str = "", track: str = "") -> str | None:
    """
    Utilise Selenium pour automatiser lucida.to et télécharger un fichier FLAC.
    """
    if not SELENIUM_AVAILABLE:
        print("  [-] Selenium non disponible", file=sys.stderr)
        return None

    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)

    chrome_opts = Options()
    chrome_opts.add_argument("--headless=new")
    chrome_opts.add_argument("--no-sandbox")
    chrome_opts.add_argument("--disable-dev-shm-usage")
    chrome_opts.add_argument("--disable-gpu")
    chrome_opts.add_argument("--window-size=1920,1080")
    chrome_opts.add_argument("--disable-blink-features=AutomationControlled")
    chrome_opts.add_experimental_option("excludeSwitches", ["enable-automation"])

    prefs = {
        "download.default_directory": str(output_path),
        "download.directory_upgrade": True,
        "download.prompt_for_download": False,
        "plugins.always_open_pdf_externally": True,
    }
    chrome_opts.add_experimental_option("prefs", prefs)

    driver = None
    try:
        driver = webdriver.Chrome(options=chrome_opts)
        driver.execute_cdp_cmd("Page.addScriptToEvaluateOnNewDocument", {
            "source": "Object.defineProperty(navigator, 'webdriver', {get: () => undefined})"
        })
    except WebDriverException as e:
        print(f"  [!] Chrome failed: {e}", file=sys.stderr)
        return None

    try:
        print("  [1/7] Ouverture de lucida.to...", file=sys.stderr)
        driver.get("https://lucida.to/")
        wait = WebDriverWait(driver, 30)

        # Attendre que le Cloudflare challenge passe ET que l'input soit prêt
        print("  [2/7] Attente du chargement (Cloudflare + JS)...", file=sys.stderr)
        search_input = wait.until(EC.presence_of_element_located((By.ID, "download")))
        search_input = wait.until(EC.element_to_be_clickable((By.ID, "download")))
        print("  [~] Page chargée!", file=sys.stderr)

        # Sélectionner Qobuz comme service (priorité FLAC)
        print("  [3/7] Sélection du service Qobuz...", file=sys.stderr)
        try:
            service_select = driver.find_element(By.CSS_SELECTOR, "select")
            select = Select(service_select)
            # Qobuz = index 1 (index 0 = "Sélectionnez un service...")
            select.select_by_value("qobuz")
            print("  [~] Qobuz sélectionné", file=sys.stderr)
        except Exception:
            # Essayer de trouver le select autrement
            all_selects = driver.find_elements(By.TAG_NAME, "select")
            if all_selects:
                select = Select(all_selects[0])
                for idx, opt in enumerate(select.options):
                    print(f"    Option {idx}: {opt.text}", file=sys.stderr)
                # Qobuz est généralement le premier service après le placeholder
                if len(select.options) > 1:
                    select.select_by_index(1)
                print("  [~] Service sélectionné", file=sys.stderr)

        # Saisir l'URL
        print("  [4/7] Saisie de l'URL...", file=sys.stderr)
        search_input.click()
        search_input.clear()
        search_input.send_keys(stream_url)
        time.sleep(2)

        # Screenshot après saisie
        driver.save_screenshot(str(output_path / "lucida_after_input.png"))

        # Cliquer sur le bouton Go !
        print("  [5/7] Soumission...", file=sys.stderr)
        go_button = driver.find_element(By.ID, "go")
        go_button.click()
        print("  [~] Soumis!", file=sys.stderr)

        # Attendre le traitement (lucida.to prend du temps)
        print("  [6/7] Attente du traitement (20s)...", file=sys.stderr)
        time.sleep(20)

        # Screenshot après traitement
        driver.save_screenshot(str(output_path / "lucida_after_processing.png"))

        # Dump du DOM pour voir les résultats
        page_text = driver.execute_script("return document.body.textContent.substring(0, 2000);")
        print(f"  [~] Page: {page_text[:300]}", file=sys.stderr)

        # Chercher les boutons de téléchargement dans les résultats
        print("  [~] Recherche des boutons de téléchargement...", file=sys.stderr)
        
        # Lucida.to affiche les résultats avec des boutons pour chaque qualité
        # Chercher tous les boutons visibles
        all_buttons = driver.find_elements(By.TAG_NAME, "button")
        all_download_links = driver.find_elements(By.CSS_SELECTOR, "a[download], a[href*='download']")
        
        print(f"  [~] {len(all_buttons)} boutons, {len(all_download_links)} liens download", file=sys.stderr)
        
        # Lister les boutons
        for btn in all_buttons[:10]:
            if btn.is_displayed():
                btn_text = btn.text.strip()
                btn_class = btn.get_attribute("class") or ""
                print(f"    [BUTTON] '{btn_text}' class={btn_class[:50]}", file=sys.stderr)
        
        for link in all_download_links[:10]:
            if link.is_displayed():
                link_text = link.text.strip()
                link_href = (link.get_attribute("href") or "")[:80]
                print(f"    [LINK] '{link_text}' -> {link_href}", file=sys.stderr)

        # Lucida.to utilise souvent des boutons avec des icônes de téléchargement
        # ou des boutons qui déclenchent le téléchargement via JavaScript
        # Essayer de cliquer sur le premier bouton de résultat
        
        # Chercher les éléments de résultat
        results = driver.execute_script("""
            var results = [];
            // Lucida affiche les résultats dans des divs avec des infos de piste
            var allElements = document.querySelectorAll('[class*="result"], [class*="track"], [class*="item"], tr, .download-row');
            allElements.forEach(function(el) {
                if (el.offsetParent && el.children.length > 0) {
                    var text = el.textContent.trim().substring(0, 200);
                    var btns = el.querySelectorAll('button, a');
                    var btnInfo = Array.from(btns).map(b => ({
                        tag: b.tagName,
                        text: b.textContent.trim(),
                        class: b.className,
                        href: b.href || null
                    }));
                    if (btnInfo.length > 0 || text.length > 10) {
                        results.push({text: text, buttons: btnInfo});
                    }
                }
            });
            return results.slice(0, 10);
        """)
        
        print(f"  [~] {len(results)} résultat(s) trouvé(s)", file=sys.stderr)
        for r in results[:3]:
            print(f"    • {r['text'][:100]}", file=sys.stderr)
            for b in r.get('buttons', [])[:3]:
                print(f"      -> [{b['tag']}] {b['text']}", file=sys.stderr)

        # Essayer de cliquer sur tous les boutons visibles (sauf les nav)
        clicked = False
        for btn in all_buttons:
            try:
                if btn.is_displayed():
                    btn_text = btn.text.strip().lower()
                    btn_class = (btn.get_attribute("class") or "").lower()
                    
                    # Ignorer les boutons de navigation et de langue
                    if any(x in btn_class for x in ["nav", "header", "footer", "lang", "update"]):
                        continue
                    if btn_text in ["update", "faq", "donate", "accueil"]:
                        continue
                    
                    # Cliquer sur le bouton
                    print(f"  [~] Clic sur bouton: '{btn_text[:30]}'", file=sys.stderr)
                    btn.click()
                    time.sleep(12)
                    clicked = True
                    break
            except Exception:
                continue

        # Si aucun bouton cliqué, essayer les liens
        if not clicked:
            for link in all_download_links:
                try:
                    if link.is_displayed():
                        link_text = link.text.strip().lower()
                        if link_text not in ["faq", "donate", "accueil"]:
                            print(f"  [~] Clic sur lien: '{link_text[:30]}'", file=sys.stderr)
                            link.click()
                            time.sleep(12)
                            clicked = True
                            break
                except Exception:
                    continue

        # Vérifier les fichiers téléchargés
        print("  [7/7] Vérification des fichiers...", file=sys.stderr)
        time.sleep(5)

        flac_files = sorted(output_path.glob("*.flac"), key=lambda p: p.stat().st_mtime, reverse=True)
        mp3_files = sorted(output_path.glob("*.mp3"), key=lambda p: p.stat().st_mtime, reverse=True)

        start_time = time.time() - 240
        recent_flac = [f for f in flac_files if f.stat().st_mtime > start_time]
        recent_mp3 = [f for f in mp3_files if f.stat().st_mtime > start_time]

        if recent_flac:
            result_file = str(recent_flac[0])
            size = recent_flac[0].stat().st_size
            print(f"  [+] FLAC: {result_file} ({size/1024/1024:.1f} MB)", file=sys.stderr)

            ffprobe = shutil.which("ffprobe")
            if ffprobe:
                try:
                    r = subprocess.run(
                        [ffprobe, "-v", "quiet",
                         "-show_entries", "stream=codec_name,sample_rate,channels,bits_per_raw_sample",
                         "-show_entries", "format=size,bit_rate,duration",
                         "-of", "default=noprint_wrappers=1", result_file],
                        capture_output=True, text=True, timeout=10
                    )
                    for line in r.stdout.strip().split("\n"):
                        print(f"    {line}", file=sys.stderr)
                except Exception:
                    pass

            return result_file

        if recent_mp3:
            result_file = str(recent_mp3[0])
            size = recent_mp3[0].stat().st_size
            print(f"  [+] MP3: {result_file} ({size/1024:.0f} KB)", file=sys.stderr)
            return result_file

        # Screenshot final
        driver.save_screenshot(str(output_path / "lucida_final.png"))
        print("  [-] Aucun fichier audio trouvé. Voir screenshots debug.", file=sys.stderr)
        return None

    finally:
        if driver:
            driver.quit()


def main():
    parser = argparse.ArgumentParser(description="Lucida.to FLAC Downloader (Selenium v4)")
    parser.add_argument("artist", nargs="?", default=None, help="Nom de l'artiste")
    parser.add_argument("track", nargs="?", default=None, help="Nom de la piste")
    parser.add_argument("--spotify-url", "-s", help="URL Spotify directe")
    parser.add_argument("--output", "-o", default="storage/imports", help="Répertoire de sortie")

    args = parser.parse_args()

    if not args.spotify_url and args.artist and args.track:
        query = urllib.parse.quote(f"{args.artist} {args.track}")
        args.spotify_url = f"https://open.spotify.com/search/{query}"

    if not args.spotify_url:
        print("[-] Artiste/Piste ou URL Spotify requise", file=sys.stderr)
        sys.exit(1)

    print(f"URL: {args.spotify_url}", file=sys.stderr)
    result = download_with_selenium(args.spotify_url, args.output, args.artist or "", args.track or "")

    if result:
        print(f"\n✅ SUCCÈS: {result}", flush=True)
        sys.exit(0)
    else:
        print("\n❌ ÉCHEC - Voir screenshots debug dans storage/imports/", flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()