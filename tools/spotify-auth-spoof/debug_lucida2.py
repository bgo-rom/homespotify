#!/usr/bin/env python3
import requests, pyjson5, json

for service in ["deezer", "soundcloud", "tidal"]:
    print(f"\n=== Testing {service} ===")
    r = requests.get(
        f'https://lucida.to/search?service={service}&country=FR&query=Josman+Intro',
        headers={'User-Agent': 'Mozilla/5.0'}, timeout=30
    )
    html = r.text
    s = html.find('const data = [') + len('const data = [')
    bc = 0; ins = False; esc = False; end = s
    for i in range(s, len(html)):
        c = html[i]
        if esc: esc = False; continue
        if c == '\\': esc = True; continue
        if c == '"' and not ins: ins = True
        elif c == '"' and ins: ins = False
        elif not ins:
            if c in '[{': bc += 1
            elif c in ']}': bc -= 1
            if bc == 0 and html[i:i+2] == '];': end = i + 1; break
    
    data = pyjson5.loads(html[s:end])
    res = data[1]['data']['results']
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

print("\nDone.")