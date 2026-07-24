#!/usr/bin/env python3
"""Deezer MP3 320kbps Downloader — Meilleure qualité gratuite pour rap français."""
import urllib.request
import json
import time
import hashlib
import subprocess
from pathlib import Path

OUTPUT = Path(r"storage/imports")
TRACK_ID = 1684004267  # Josman - Intro

# 1. Get track info
req = urllib.request.Request(f"https://api.deezer.com/track/{TRACK_ID}")
with urllib.request.urlopen(req) as r:
    d = json.loads(r.read())

title = d["title"]
artist = d["artist"]["name"]
md5 = d.get("MD5_ORIGIN", "")
print(f"Track: {artist} - {title}")
print(f"MD5: {md5}")
print(f"FILESIZE_MP3_320: {d.get('FILESIZE_MP3_320', 0)}")

# 2. Build stream URL with proper token
ts = int(time.time())
token_str = f"ArAlG160Dm5p9xMlr2{md5}player"
token = hashlib.md5(token_str.encode()).hexdigest()

# Deezer CDN URL for MP3 320
url = f"https://cdns-preview-{md5[0]}.dzcdn.net/mobile/1/{md5}.mp3?token={token}&algo=ormuse&title={artist}+-%20{title}"
print(f"URL: {url}")

# 3. Download
safe = f"{artist} - {title}"
out = OUTPUT / f"{safe} [Deezer 320].mp3"

req2 = urllib.request.Request(url, headers={
    "User-Agent": "Deezer/5.0",
    "Referer": "https://www.deezer.com/"
})

try:
    with urllib.request.urlopen(req2, timeout=30) as resp:
        data = resp.read()
    with open(out, "wb") as f:
        f.write(data)
    print(f"Downloaded: {out} ({len(data)/1024:.0f} KB)")
    
    # 4. Analyze
    cmd = ["ffprobe", "-v", "quiet", "-show_entries", 
           "stream=codec_name,sample_rate,channels,bits_per_raw_sample",
           "-show_entries", "format=size,bit_rate,duration",
           "-of", "default=noprint_wrappers=1", str(out)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    print(f"\n{r.stdout}")
    
except Exception as e:
    print(f"Error: {e}")
    
    # Fallback: use the MD5 direct URL
    url2 = f"https://e-cdns-proxy-d.dzcdn.net/stream/{md5}?d=320&token={token}"
    print(f"Fallback URL: {url2}")
    
    req3 = urllib.request.Request(url2, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req3, timeout=30) as resp:
        data = resp.read()
    with open(out, "wb") as f:
        f.write(data)
    print(f"Downloaded (fallback): {out} ({len(data)/1024:.0f} KB)")