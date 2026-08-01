#!/usr/bin/env python3
"""Full inspection of Monochrome.tf search results."""
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
for i in range(20):
    pg.wait_for_timeout(2000)
    url = pg.url
    title = pg.title()
    try:
        body_text = pg.locator('body').inner_text(timeout=2000)
    except Exception:
        body_text = "(timeout)"
    print(f"[{(i+1)*2}s] URL={url} Title={title}")
    print(f"  Body text: {body_text[:300]}")

    # Check all links
    all_links = pg.evaluate('''() => {
      return Array.from(document.querySelectorAll('a[href]')).map(a => ({
        text: a.textContent.trim(),
        href: a.getAttribute('href')
      }));
    }''')
    print(f"  Links: {len(all_links)}")
    for link in all_links[:5]:
        print(f"    {link['text'][:50]} -> {link['href'][:80]}")

    # Check all divs with text
    all_divs = pg.evaluate('''() => {
      return Array.from(document.querySelectorAll('div')).filter(d => d.textContent.trim().length > 3).map(d => ({
        text: d.textContent.trim(),
        className: d.className,
        id: d.id
      }));
    }''')
    print(f"  Divs with text: {len(all_divs)}")
    for d in all_divs[:10]:
        print(f"    class={d['className'][:50]} text={d['text'][:80]}")

pg.screenshot(path='storage/imports/debug/monochrome/post_search2.png', full_page=True)
b.close()
p.stop()
print('Done')