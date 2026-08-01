#!/usr/bin/env python3
"""Full inspection of Monochrome.tf search results - wait longer + check login."""
from playwright.sync_api import sync_playwright

p = sync_playwright().start()
b = p.chromium.launch(headless=True, args=['--no-sandbox'])
pg = b.new_page()
pg.goto('https://monochrome.tf', wait_until='domcontentloaded', timeout=60000)
pg.wait_for_timeout(5000)

# Click search input and search for Guala Lifestyles
pg.click('#search-input')
pg.fill('#search-input', 'Guala Lifestyles')
pg.keyboard.press('Enter')

# Wait a long time for SPA to load results
for i in range(30):
    pg.wait_for_timeout(2000)
    url = pg.url
    title = pg.title()
    try:
        body_text = pg.locator('body').inner_text(timeout=2000)
    except Exception:
        body_text = "(timeout)"

    # Check if there's a login page
    login_text = ""
    try:
        login_text = pg.evaluate('''() => {
          const all = document.querySelectorAll('a[href*="login"], a[href*="sign"], a[href*="auth"], [id*="login"], [id*="sign"], [id*="auth"]');
          return Array.from(all).map(e => e.textContent.trim()).join(' | ');
        }''')
    except Exception:
        login_text = ""

    # Check for any track data
    tracks = pg.evaluate('''() => {
      return Array.from(document.querySelectorAll('div')).filter(d => {
        const t = d.textContent.trim().toLowerCase();
        return (t.includes("guala") || t.includes("lifestyle") || t.includes("track") || t.includes("song")) && d.offsetParent !== null;
      }).map(d => ({
        text: d.textContent.trim().substring(0, 100),
        className: d.className,
        id: d.id
      }));
    }''')

    print(f"[{(i+1)*2}s] URL={url} Title={title}")
    print(f"  Body: {body_text[:150]}")
    print(f"  Login elements: {login_text[:100]}")
    print(f"  Track elements: {len(tracks)}")
    for t in tracks[:3]:
        print(f"    class={t['className'][:50]} text={t['text'][:80]}")

pg.screenshot(path='storage/imports/debug/monochrome/post_search3.png', full_page=True)
b.close()
p.stop()
print('Done')