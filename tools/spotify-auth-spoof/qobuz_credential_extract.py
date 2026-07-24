#!/usr/bin/env python3
"""
VECTEUR 3 — DOM SCRAPING & CREDENTIAL THEFT (Qobuz)
Extrait les app_id et app_secret depuis le bundle JavaScript de Qobuz.

Stratégie :
  1. Charger play.qobuz.com en headless (Selenium)
  2. Extraire tous les scripts du DOM
  3. Parser le JS avec regex pour trouver app_id / app_secret / client_id / client_secret
  4. Afficher les credentials trouvés
"""

import json
import re
import sys
import time
import urllib.request
import urllib.error

# ─── Cibles ───────────────────────────────────────────────────────────────────
QOBUZ_HOME    = "https://play.qobuz.com"
QOBUZ_LOGIN   = "https://play.qobuz.com/login"

# Patterns regex pour les credentials Qobuz
CREDENTIAL_PATTERNS = [
    # app_id / app_secret dans les objets de config
    (r'app[_-]?id\s*[:=]\s*["\']([a-zA-Z0-9_-]{10,50})["\']', 'app_id'),
    (r'app[_-]?secret\s*[:=]\s*["\']([a-zA-Z0-9_-]{10,100})["\']', 'app_secret'),
    # client_id / client_secret (OAuth)
    (r'client[_-]?id\s*[:=]\s*["\']([a-zA-Z0-9_.@-]{10,80})["\']', 'client_id'),
    (r'client[_-]?secret\s*[:=]\s*["\']([a-zA-Z0-9_.@-]{10,100})["\']', 'client_secret'),
    # Patterns Qobuz spécifiques
    (r'["\']client_id["\']\s*:\s*["\']([a-zA-Z0-9_.@-]+)["\']', 'client_id_v2'),
    (r'["\']client_secret["\']\s*:\s*["\']([a-zA-Z0-9_.@-]+)["\']', 'client_secret_v2'),
    (r'qobuz[_-]?client[_-]?id\s*[:=]\s*["\']([a-zA-Z0-9_.@-]+)["\']', 'qobuz_client_id'),
    # Token et clés API
    (r'api[_-]?key\s*[:=]\s*["\']([a-zA-Z0-9_-]{16,64})["\']', 'api_key'),
    (r'access[_-]?token\s*[:=]\s*["\']([a-zA-Z0-9_.=-]{20,200})["\']', 'access_token'),
    # URL du bundle (pour extraction en cascade)
    (r'https?://[^"\'> ]+\.(js|min\.js|bundle\.js)[^"\'> ]*', 'js_bundle_url'),
]


def extract_credentials_from_js(js_content: str) -> dict:
    """Parse le JS avec les patterns regex et retourne les credentials trouvés."""
    found = {}
    for pattern, name in CREDENTIAL_PATTERNS:
        matches = re.findall(pattern, js_content, re.IGNORECASE)
        if matches:
            # Déduplique et filtre les faux positifs
            unique = list(dict.fromkeys(matches))  # preserve order
            # Filtre les URL de bundle du dict principal
            if name == 'js_bundle_url':
                found.setdefault('js_bundles', []).extend(unique[:5])
            else:
                # Garde max 3 valeurs par type
                existing = found.get(name, [])
                for m in unique[:3]:
                    if m not in existing:
                        existing.append(m)
                found[name] = existing
    return found


def fetch_page_source(url: str, ua: str = None) -> str:
    """Fetch le HTML/JS brut d'une URL."""
    if not ua:
        ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    req = urllib.request.Request(url)
    req.add_header("User-Agent", ua)
    req.add_header("Accept", "text/html,application/xhtml+xml,application/json,*/*")
    req.add_header("Accept-Language", "en-US,en;q=0.9")

    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return resp.read().decode("utf-8", errors="replace")
    except Exception as e:
        print(f"    [!] Fetch {url}: {e}", file=sys.stderr)
        return ""


def extract_js_urls(html: str) -> list[str]:
    """Extrait les URLs de scripts JS du HTML."""
    # <script src="..."> et import()
    urls = []
    for m in re.findall(r'<script[^>]+src=["\']([^"\']+)["\']', html):
        if m.endswith('.js') or '.js?' in m:
            urls.append(m)
    for m in re.findall(r'import\(["\']([^"\']+\.js[^"\']*)["\']\)', html):
        urls.append(m)
    return urls[:10]  # max 10


def resolve_url(base: str, path: str) -> str:
    """Résout une URL relative."""
    if path.startswith("http"):
        return path
    if path.startswith("//"):
        return "https:" + path
    if path.startswith("/"):
        return base + path
    # Relative
    base = base.rsplit("/", 1)[0]
    return f"{base}/{path}"


def run_extract() -> dict:
    """Extraction complète des credentials Qobuz."""
    all_credentials = {}

    # Etape 1 : Fetch la page principale
    print("    [1/4] Fetching Qobuz homepage...", file=sys.stderr)
    html = fetch_page_source(QOBUZ_HOME)
    if html:
        print(f"    [+] Homepage: {len(html)} chars", file=sys.stderr)
        creds = extract_credentials_from_js(html)
        all_credentials.update(creds)

        # Etape 2 : Extraire et fetch les bundles JS
        print("    [2/4] Extracting JS bundles from HTML...", file=sys.stderr)
        js_urls = extract_js_urls(html)
        print(f"    [+] Found {len(js_urls)} JS URLs", file=sys.stderr)

        for js_url in js_urls:
            full_url = resolve_url(QOBUZ_HOME, js_url)
            print(f"    [>] Fetching {full_url[:80]}...", file=sys.stderr)
            js_content = fetch_page_source(full_url)
            if js_content:
                print(f"       {len(js_content)} chars", file=sys.stderr)
                creds = extract_credentials_from_js(js_content)
                for k, v in creds.items():
                    if k == 'js_bundles':
                        all_credentials.setdefault('js_bundles', []).extend(v[:3])
                    elif k in all_credentials:
                        for item in v:
                            if item not in all_credentials[k]:
                                all_credentials[k].append(item)
                    else:
                        all_credentials[k] = v

        # Etape 3 : Fetch la page login (souvent contient les OAuth credentials)
        print("    [3/4] Fetching Qobuz login page...", file=sys.stderr)
        login_html = fetch_page_source(QOBUZ_LOGIN)
        if login_html:
            creds = extract_credentials_from_js(login_html)
            for k, v in creds.items():
                if k in all_credentials and k != 'js_bundles':
                    for item in v:
                        if item not in all_credentials[k]:
                            all_credentials[k].append(item)
                elif k != 'js_bundles':
                    all_credentials[k] = v

        # Etape 4 : Essayer Selenium pour le JS exécuté
        print("    [4/4] Selenium fallback for runtime JS...", file=sys.stderr)
        selenium_creds = try_selenium_extract()
        for k, v in selenium_creds.items():
            if k in all_credentials and k != 'js_bundles':
                for item in v:
                    if item not in all_credentials[k]:
                        all_credentials[k].append(item)
            elif k != 'js_bundles':
                all_credentials[k] = v

    return all_credentials


def try_selenium_extract() -> dict:
    """Fallback Selenium pour extraire les variables JS du runtime."""
    creds = {}
    try:
        from selenium import webdriver
        from selenium.webdriver.chrome.options import Options
        from selenium.webdriver.support.ui import WebDriverWait
        from selenium.common.exceptions import WebDriverException, TimeoutException

        opts = Options()
        opts.add_argument("--headless=new")
        opts.add_argument("--no-sandbox")
        opts.add_argument("--disable-dev-shm-usage")
        opts.add_argument("--disable-gpu")

        driver = webdriver.Chrome(options=opts)
        try:
            driver.get(QOBUZ_HOME)
            WebDriverWait(driver, 20).until(
                lambda d: d.execute_script("return document.readyState") == "complete"
            )

            # Extrait le contenu de tous les scripts
            all_js = driver.execute_script("""
                var scripts = document.querySelectorAll('script');
                var all = '';
                scripts.forEach(s => { all += s.textContent + '\\n'; });
                return all.substring(0, 500000);
            """)
            if all_js:
                creds = extract_credentials_from_js(all_js)

            # Cherche dans les variables globales
            global_vars = driver.execute_script("""
                var result = {};
                var keys = ['QobuzConfig', 'qobuzConfig', 'appConfig', 'APP_CONFIG',
                           'CLIENT_ID', 'client_id', 'APP_ID', 'app_id',
                           'CLIENT_SECRET', 'client_secret', 'APP_SECRET', 'app_secret',
                           'config', 'window.config'];
                for (var k of keys) {
                    try {
                        var v = window[k];
                        if (v && typeof v === 'object') result[k] = JSON.stringify(v);
                        else if (v) result[k] = String(v);
                    } catch {}
                }
                return result;
            """)
            if global_vars:
                for k, v in global_vars.items():
                    if isinstance(v, str) and len(v) > 10:
                        # Parse le JSON si possible
                        try:
                            obj = json.loads(v)
                            sub_creds = extract_credentials_from_js(json.dumps(obj))
                            for sk, sv in sub_creds.items():
                                if sk != 'js_bundles':
                                    creds.setdefault(sk, []).extend(sv[:3])
                        except json.JSONDecodeError:
                            pass

        finally:
            driver.quit()
    except (WebDriverException, ImportError) as e:
        print(f"    [!] Selenium skipped: {e}", file=sys.stderr)

    return creds


# ─── Main ─────────────────────────────────────────────────────────────────────
def main() -> None:
    print("=" * 60)
    print("  QOBUZ CREDENTIAL THEFT — VECTEUR 3")
    print("=" * 60)

    result = run_extract()

    # Affichage
    print("\n" + "=" * 60)
    print("  RESULTATS")
    print("=" * 60)

    # Credentials principaux
    found_any = False

    for key_type in ['client_id', 'client_id_v2', 'qobuz_client_id', 'app_id']:
        if result.get(key_type):
            found_any = True
            print(f"\n  [{key_type.upper()}]")
            for v in result[key_type]:
                print(f"    {v}")

    for key_type in ['client_secret', 'client_secret_v2', 'app_secret']:
        if result.get(key_type):
            found_any = True
            print(f"\n  [{key_type.upper()}]")
            for v in result[key_type]:
                print(f"    {v}")

    for key_type in ['api_key', 'access_token']:
        if result.get(key_type):
            found_any = True
            print(f"\n  [{key_type.upper()}]")
            for v in result[key_type]:
                print(f"    {v[:50]}...")

    if result.get('js_bundles'):
        print(f"\n  [JS BUNDLES FOUND]")
        for u in result['js_bundles'][:3]:
            print(f"    {u[:100]}")

    if not found_any:
        print("\n  [-] Aucun credential trouvé directement.", file=sys.stderr)
        print("      Le JS est probablement minifié avec des noms de variables obscures.", file=sys.stderr)
        print("      Solution : utiliser l'endpoint /login avec le client_id connu.", file=sys.stderr)

    print("\n" + "=" * 60)

    # Sauvegarde JSON
    with open("tools/spotify-auth-spoof/qobuz_credentials.json", "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
    print("  Credentials sauvegardés dans qobuz_credentials.json", file=sys.stderr)

    # Sortie machine-readable
    client_ids = result.get('client_id') or result.get('client_id_v2') or result.get('qobuz_client_id') or []
    client_secrets = result.get('client_secret') or result.get('client_secret_v2') or []
    if client_ids and client_secrets:
        print(f"\nQOBUZ_CLIENT_ID={client_ids[0]}", flush=True)
        print(f"QOBUZ_CLIENT_SECRET={client_secrets[0]}", flush=True)
    elif client_ids:
        print(f"\nQOBUZ_CLIENT_ID={client_ids[0]}", flush=True)


if __name__ == "__main__":
    main()