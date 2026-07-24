#!/usr/bin/env python3
"""Test extraction credentials Qobuz depuis le bundle JS."""
import urllib.request
import re
import json
import hashlib

# Step 1: Fetch HTML
resp = urllib.request.urlopen('https://open.qobuz.com/track/1', timeout=15)
html = resp.read().decode()

# Step 2: Find bundle URL
m = re.search(r'src="([^"]+/js/main\.js[^"]*)"', html)
if not m:
    print("Bundle NOT FOUND")
    exit(1)

bundle_url = m.group(1)
if bundle_url.startswith('/'):
    bundle_url = 'https://open.qobuz.com' + bundle_url
print(f"Bundle: {bundle_url}")

# Step 3: Fetch bundle & extract credentials
resp2 = urllib.request.urlopen(bundle_url, timeout=30)
bundle = resp2.read().decode()

cm = re.search(r'app_id:"(?P<app_id>\d{9})",app_secret:"(?P<app_secret>[a-f0-9]{32})"', bundle)
if not cm:
    print("Credentials NOT FOUND in bundle")
    exit(1)

APP_ID = cm.group('app_id')
SECRET = cm.group('app_secret')
print(f"app_id: {APP_ID}")
print(f"app_secret: {SECRET}")

import urllib.parse
import time

# SpotiFLAC signature: path stripped + sorted params + timestamp + secret
def qobuz_signature(path, params, secret):
    normalized = path.strip('/').replace('/', '')
    payload = normalized
    for key in sorted(params.keys()):
        payload += key + str(params[key])
    timestamp = str(int(time.time()))
    payload += timestamp + secret
    return hashlib.md5(payload.encode()).hexdigest(), timestamp

params = {
    'request_id': 1,
    'code': 'fr',
    'app_id': APP_ID,
    'track_id': '40128300'
}
path = 'track/get'
sig, ts = qobuz_signature(path, params, SECRET)
params['request_sig'] = sig
params['request_ts'] = ts
params['app_id'] = APP_ID

url = f'https://www.qobuz.com/api.json/0.2/{path}?' + urllib.parse.urlencode(params)
print(f"Request: {url[:150]}...")

req = urllib.request.Request(url, headers={
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
    'Referer': 'https://play.qobuz.com/'
})

try:
    resp3 = urllib.request.urlopen(req, timeout=15)
    raw = resp3.read().decode()
    print(f"\nRaw response ({len(raw)} chars): {raw[:500]}")
    data = json.loads(raw)
except urllib.error.HTTPError as e:
    raw = e.read().decode()
    print(f"\nHTTP {e.code}: {raw[:500]}")
    data = json.loads(raw) if raw else {}

# Response is flat - track data is at root level
t = data
print(f"\nTrack: {t.get('title', '?')}")
print(f"Key: {t.get('key', 'NO KEY')}")
print(f"Bit depth: {t.get('maximum_bit_depth', '?')}")
print(f"Sample rate: {t.get('maximum_sampling_rate', '?')}")
print(f"Streamable: {t.get('streamable', '?')}")
print(f"Hi-Res: {t.get('hires', '?')}")

# Step 5: If key exists, test getFileUrlFromKey
key = t.get('key')
if key:
    print("\n--- Testing getFileUrlFromKey ---")
    p2 = {
        'request_id': 2,
        'code': 'fr',
        'app_id': APP_ID,
        'track_id': str(t['id']),
        'format_id': '6',
        'track_key': key
    }
    sig2 = ''.join(f'{k}{p2[k]}' for k in sorted(p2.keys())) + SECRET
    p2['sign'] = hashlib.md5(sig2.encode()).hexdigest()
    
    url2 = 'https://www.qobuz.com/api.json/0.2/track/getFileUrlFromKey?' + urllib.parse.urlencode(p2)
    req2 = urllib.request.Request(url2, headers={
        'User-Agent': 'Mozilla/5.0',
        'Referer': 'https://play.qobuz.com/'
    })
    
    try:
        resp4 = urllib.request.urlopen(req2, timeout=15)
        stream = json.loads(resp4.read().decode())
        print(f"Stream URL: {stream.get('url', 'NO URL')[:100]}...")
        print("SUCCESS! Qobuz anonymous download works!")
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()[:200]}")
else:
    print("\nNo key — cannot test getFileUrlFromKey")