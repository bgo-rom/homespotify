#!/usr/bin/env python3
import requests, pyjson5, json, sys

r = requests.get('https://lucida.to/search?service=qobuz&country=GB&query=Josman+Intro', 
                 headers={'User-Agent':'Mozilla/5.0'}, timeout=30)
html = r.text
start = html.find('const data = [')
start += len('const data = ')
bc = 0; ins = False; esc = False; end = start
for i in range(start, len(html)):
    c = html[i]
    if esc: esc=False; continue
    if c=='\\': esc=True; continue
    if c=='"' and not ins: ins=True
    elif c=='"' and ins: ins=False
    elif not ins:
        if c in '[{': bc+=1
        elif c in ']}': bc-=1
        if bc==0 and html[i:i+2]=='];': end=i+1; break

data = pyjson5.loads(html[start:end])
print(f'Length: {len(data)}')

for i, item in enumerate(data):
    if isinstance(item, dict):
        print(f'Item {i}: keys={list(item.keys())[:10]}')
        if 'data' in item:
            d = item['data']
            if isinstance(d, dict):
                print(f'  data keys: {list(d.keys())[:10]}')
                for k,v in d.items():
                    if isinstance(v, dict):
                        print(f'    {k}: keys={list(v.keys())[:10]}')
                        if 'results' in v:
                            res = v['results']
                            print(f'    results type: {type(res).__name__}')
                            if isinstance(res, dict):
                                print(f'    results keys: {list(res.keys())[:10]}')
                                if 'results' in res:
                                    inner = res['results']
                                    print(f'    inner keys: {list(inner.keys())[:10]}')
                                    if 'tracks' in inner:
                                        tracks = inner['tracks']
                                        print(f'    tracks count: {len(tracks)}')
                                        for t in tracks[:5]:
                                            artists = [a.get("name","") for a in t.get("artists",[])]
                                            print(f'      {t.get("title","?")} by {artists}')
                                    if 'albums' in inner:
                                        print(f'    albums count: {len(inner["albums"])}')

# Sauvegarder pour inspection
with open('storage/imports/lucida_raw.json', 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False, default=str)
print('\nSaved to storage/imports/lucida_raw.json')