#!/usr/bin/env python3
"""Inspect Monochrome.tf SPA DOM after search."""
from playwright.sync_api import sync_playwright

p = sync_playwright().start()
b = p.chromium.launch(headless=True, args=['--no-sandbox'])
pg = b.new_page()
pg.goto('https://monochrome.tf', wait_until='domcontentloaded', timeout=60000)
pg.wait_for_timeout(5000)

# Search for Guala Lifestyles
pg.click('#search-input')
pg.fill('#search-input', 'Guala Lifestyles')
pg.keyboard.press('Enter')
pg.wait_for_timeout(8000)

print('URL:', pg.url)
print('Title:', pg.title())

# Find all links
links = pg.evaluate('''() => {
  const allLinks = document.querySelectorAll('a[href]');
  return Array.from(allLinks).map(a => ({
    text: a.textContent.trim(),
    href: a.getAttribute('href'),
    className: a.className
  }));
}''')
print(f'Links found: {len(links)}')
for i, link in enumerate(links[:20]):
    print(f'  [{i}] text={link["text"][:60]} href={link["href"][:80]}')

# Check for result items
results = pg.evaluate('''() => {
  const allDivs = document.querySelectorAll('div');
  return Array.from(allDivs).filter(d => d.textContent.trim().length > 5).map(d => ({
    text: d.textContent.trim().substring(0, 100),
    className: d.className,
    id: d.id
  }));
}''')
print(f'Non-empty divs found: {len(results)}')
for i, r in enumerate(results[:10]):
    print(f'  [{i}] class={r["className"][:50]} text={r["text"][:80]}')

pg.screenshot(path='storage/imports/debug/monochrome/post_search.png', full_page=True)
b.close()
p.stop()
print('Done')