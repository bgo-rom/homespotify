#!/usr/bin/env python3
"""Inspect Monochrome.tf SPA DOM after search - check for login requirement."""
from playwright.sync_api import sync_playwright

p = sync_playwright().start()
b = p.chromium.launch(headless=True, args=['--no-sandbox'])
pg = b.new_page()
pg.goto('https://monochrome.tf', wait_until='domcontentloaded', timeout=60000)
pg.wait_for_timeout(5000)

# Check if logged in
els = pg.evaluate('''() => {
  const all = document.querySelectorAll('a[href*="login"], a[href*="sign"], a[href*="auth"], [id*="login"], [id*="sign"], [id*="auth"], [class*="login"], [class*="sign"], [class*="auth"]');
  return Array.from(all).map(e => ({
    text: e.textContent.trim().substring(0, 50),
    className: e.className,
    id: e.id,
    href: e.getAttribute('href') || ''
  }));
}''')
print(f'Login/sign/auth elements: {len(els)}')
for i, e in enumerate(els[:10]):
    print(f'  [{i}] class={e["className"][:50]} id={e["id"][:40]} href={e["href"][:60]} text={e["text"][:50]}')

# Check for any user/profile/account indicators
userEls = pg.evaluate('''() => {
  const all = document.querySelectorAll('[class*="user"], [class*="profile"], [class*="account"], [id*="user"], [id*="profile"], [id*="account"]');
  return Array.from(all).map(e => ({
    text: e.textContent.trim().substring(0, 50),
    className: e.className,
    id: e.id
  }));
}''')
print(f'User/profile/account elements: {len(userEls)}')
for i, e in enumerate(userEls[:5]):
    print(f'  [{i}] class={e["className"][:50]} id={e["id"][:40]} text={e["text"][:50]}')

# Search for Guala Lifestyles
pg.click('#search-input')
pg.fill('#search-input', 'Guala Lifestyles')
pg.keyboard.press('Enter')
pg.wait_for_timeout(8000)

# Check the SPA content for search results
content = pg.evaluate('''() => {
  const all = document.querySelectorAll('div');
  return Array.from(all).filter(d => d.textContent.trim().toLowerCase().includes("guala") || d.textContent.trim().toLowerCase().includes("lifestyle")).map(d => ({
    text: d.textContent.trim().substring(0, 150),
    className: d.className,
    id: d.id
  }));
}''')
print(f'Search result elements with Guala/Lifestyle: {len(content)}')
for i, c in enumerate(content[:10]):
    print(f'  [{i}] class={c["className"][:60]} id={c["id"][:40]} text={c["text"][:120]}')

# Check if search results are visible
visible = pg.evaluate('''() => {
  const all = document.querySelectorAll('div');
  return Array.from(all).filter(d => {
    const t = d.textContent.trim().toLowerCase();
    return (t.includes("guala") || t.includes("lifestyle")) && d.offsetParent !== null;
  }).map(d => ({
    text: d.textContent.trim().substring(0, 150),
    className: d.className,
    id: d.id,
    visible: d.offsetParent !== null
  }));
}''')
print(f'Visible search result elements: {len(visible)}')
for i, v in enumerate(visible[:10]):
    print(f'  [{i}] class={v["className"][:60]} id={v["id"][:40]} visible={v["visible"]} text={v["text"][:120]}')

# Check for any button with download text
buttons = pg.evaluate('''() => {
  return Array.from(document.querySelectorAll('button')).map(b => ({
    text: b.textContent.trim(),
    className: b.className,
    id: b.id
  }));
}''')
print(f'All buttons: {len(buttons)}')
for i, b in enumerate(buttons[:20]):
    print(f'  [{i}] class={b["className"][:50]} text={b["text"][:50]}')

# Check for any download link
downloads = pg.evaluate('''() => {
  const all = document.querySelectorAll('a[href]');
  return Array.from(all).filter(a => {
    const t = a.textContent.trim().toLowerCase();
    return t.includes("download") || t.includes("flac") || t.includes("mp3");
  }).map(a => ({
    text: a.textContent.trim(),
    href: a.getAttribute('href'),
    className: a.className
  }));
}''')
print(f'Download/FLAC links: {len(downloads)}')
for i, d in enumerate(downloads[:10]):
    print(f'  [{i}] class={d["className"][:50]} href={d["href"][:80]} text={d["text"][:60]}')

pg.screenshot(path='storage/imports/debug/monochrome/spa_check2.png', full_page=True)
b.close()
p.stop()
print('Done')