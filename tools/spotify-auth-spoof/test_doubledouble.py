#!/usr/bin/env python3
"""Test Doubledouble.top - exploration manuelle pour comprendre le workflow."""
from playwright.sync_api import sync_playwright

p = sync_playwright().start()
b = p.chromium.launch(headless=False, args=["--no-sandbox"])
pg = b.new_page()

# 1. Ouvrir Doubledouble
print("==> Navigation vers Doubledouble...")
pg.goto("https://eu.doubledouble.top/", wait_until="domcontentloaded", timeout=60000)
pg.wait_for_timeout(5000)
pg.screenshot(path="storage/imports/debug/dd/dd_01_homepage.png", full_page=True)

# 2. Rechercher un album Qobuz
qobuz_url = "https://www.qobuz.com/us-en/album/lifestyles-guala/m7mqu37d7v1ka"
print(f"==> Recherche du lien Qobuz: {qobuz_url}")

input_elem = pg.locator('input[type="text"], input[type="search"], input[placeholder], input').first
print(f"==> Input trouvé, remplissage...")
input_elem.fill(qobuz_url)
input_elem.press("Enter")

pg.wait_for_timeout(10000)
pg.screenshot(path="storage/imports/debug/dd/dd_02_after_search.png", full_page=True)

print("\n==> URL actuelle:", pg.url)
print("\n==> Contenu de la page (extrait):")
content = pg.content()[:5000]
print(content)

# Lister les boutons
print("\n==> BOUTONS:")
for btn in pg.locator('button').all():
    try:
        txt = btn.inner_text().strip()
        if txt:
            print(f"  button: '{txt}'")
    except Exception:
        pass

# Lister les liens
print("\n==> LIENS (premiers 30):")
for i, a in enumerate(pg.locator('a').all()[:30]):
    try:
        txt = a.inner_text().strip()[:60]
        href = a.get_attribute("href") or ""
        print(f"  [{i}] href={href[:80]} text='{txt}'")
    except Exception:
        pass

# Chercher les éléments avec le nom de l'album
print("\n==> ÉLÉMENTS CONTENANT 'lifestyles' ou 'guala':")
for elem in pg.locator('[class*="result"], [class*="album"], [class*="track"]').all()[:20]:
    try:
        txt = elem.inner_text().strip().lower()
        if "lifestyles" in txt or "guala" in txt:
            print(f"  '{elem.inner_text().strip()[:100]}'")
    except Exception:
        pass

print("\n==> PAUSE - inspecte la page manuellement, puis appuie sur Entrée pour continuer...")
input()

# Continuer : cliquer sur Download si visible
print("\n==> Clic sur Download...")
dl_btn = pg.locator('button#dl-button, button:has-text("Download")').first
try:
    dl_btn.click(timeout=10000)
    pg.wait_for_timeout(5000)
    pg.screenshot(path="storage/imports/debug/dd/dd_03_after_download_click.png", full_page=True)
    print("==> URL:", pg.url)
except Exception as e:
    print(f"==> Erreur clic Download: {e}")

print("\n==> PAUSE - complète le Cloudflare si nécessaire, appuie sur Entrée...")
input()

pg.screenshot(path="storage/imports/debug/dd/dd_04_after_cloudflare.png", full_page=True)

# Chercher le bouton HERE
print("\n==> LIENS APRÈS CLOUDFLARE:")
for i, a in enumerate(pg.locator('a').all()[:30]):
    try:
        txt = a.inner_text().strip()[:60]
        href = a.get_attribute("href") or ""
        print(f"  [{i}] href={href[:80]} text='{txt}'")
    except Exception:
        pass

print("\n==> PAUSE - appuie sur Entrée pour cliquer sur HERE...")
input()

# Cliquer sur HERE
try:
    here = pg.locator('a:has-text("HERE"), a:has-text("here")').first
    here.click(timeout=10000)
    print("==> Clic sur HERE fait!")
except Exception as e:
    print(f"==> Erreur clic HERE: {e}")

pg.wait_for_timeout(5000)
pg.screenshot(path="storage/imports/debug/dd/dd_05_after_here.png", full_page=True)

print("\n==> PAUSE - vérifie le téléchargement, appuie sur Entrée...")
input()

b.close()
p.stop()