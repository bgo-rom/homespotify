#!/usr/bin/env python3
"""Debug lucida.to avec Playwright pour attendre le JS."""
import json, time
from pathlib import Path
from playwright.sync_api import sync_playwright

def extract_json_from_page(page):
    """Extraire les données JSON de la page."""
    # Essayer d'évaluer le JavaScript directement
    try:
        data = page.evaluate("""() => {
            // Chercher dans les balises script
            const scripts = document.querySelectorAll('script');
            for (const script of scripts) {
                const text = script.textContent || '';
                const idx = text.indexOf('const data = [');
                if (idx !== -1) {
                    const start = idx + 'const data = ['.length;
                    let bc = 0, ins = false, esc = false, end = start;
                    for (let i = start; i < text.length; i++) {
                        const c = text[i];
                        if (esc) { esc = false; continue; }
                        if (c === '\\\\') { esc = true; continue; }
                        if (c === '"' && !ins) ins = true;
                        else if (c === '"' && ins) ins = false;
                        else if (!ins) {
                            if (c === '[' || c === '{') bc++;
                            else if (c === ']' || c === '}') {
                                bc--;
                                if (bc === 0 && text.substring(i, i+2) === '];') {
                                    end = i + 1;
                                    break;
                                }
                            }
                        }
                    }
                    if (end > start) {
                        return text.substring(start, end);
                    }
                }
            }
            return null;
        }""")
        return data
    except Exception as e:
        return str(e)

def test_service(service: str):
    print(f"\n{'='*60}")
    print(f"  Testing {service}")
    print(f"{'='*60}")
    
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context(
            user_agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
        )
        page = context.new_page()
        
        url = f"https://lucida.to/search?service={service}&country=FR&query=Josman+Intro"
        print(f"  URL: {url}")
        
        try:
            page.goto(url, wait_until="networkidle", timeout=30000)
            page.wait_for_timeout(3000)
            
            # Screenshot
            page.screenshot(path=f"storage/imports/lucida_{service}_page.png")
            
            # Extraire JSON
            json_str = extract_json_from_page(page)
            print(f"  JSON extracted: {json_str is not None}")
            
            if json_str:
                print(f"  JSON length: {len(json_str)}")
                print(f"  JSON preview: {json_str[:200]}")
                
                # Sauvegarder
                with open(f"storage/imports/lucida_{service}_raw.json", "w", encoding="utf-8") as f:
                    f.write(json_str)
                
                # Parser avec Python
                import pyjson5
                data = pyjson5.loads(json_str)
                print(f"  Items: {len(data)}")
                
                if len(data) > 1:
                    res = data[1].get('data', {}).get('results', {})
                    print(f"  success: {res.get('success')}")
                    if not res.get('success'):
                        print(f"  error: {res.get('error', 'N/A')[:200]}")
                    else:
                        inner = res.get('results', {})
                        tracks = inner.get('tracks', [])
                        print(f"  tracks: {len(tracks)}")
                        for t in tracks[:3]:
                            artists = [a.get('name', '') for a in t.get('artists', [])]
                            print(f"    {t.get('title', '?')} by {artists}")
                            print(f"    url: {t.get('url', 'N/A')}")
            else:
                # Sauvegarder HTML
                html = page.content()
                with open(f"storage/imports/lucida_{service}_full.html", "w", encoding="utf-8") as f:
                    f.write(html)
                print(f"  HTML saved: {len(html)} chars")
                
        except Exception as e:
            print(f"  Error: {e}")
        finally:
            browser.close()

for service in ["deezer", "soundcloud", "tidal"]:
    test_service(service)

print("\nDone.")