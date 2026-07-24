#!/usr/bin/env python3
"""
Deezer HTML Scraper — Extraire l'URL de stream complète depuis la page HTML
La page web contient le MD5 et l'URL de stream en JavaScript.
"""
import urllib.request
import json
import re
import subprocess
from pathlib import Path

OUTPUT = Path(r"storage/imports")
TRACK_ID = 1684004267

print(f"🎵 Scraping la page Deezer du track {TRACK_ID}...")

# Télécharger la page HTML de Deezer
url = f"https://www.deezer.com/fr/track/{TRACK_ID}"
req = urllib.request.Request(url, headers={
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "fr-FR,fr;q=0.9",
})

with urllib.request.urlopen(req, timeout=20) as r:
    html = r.read().decode("utf-8", errors="ignore")

print(f"  Page téléchargée: {len(html)} caractères")

# === Extraire le JSON de données injectées dans la page ===
# Deezer injecte les données dans des balises <script> avec des clés comme:
# - window.__PRELOADED_STATE__
# - ou dans des données JSON avec MD5, TRACK_TOKEN, etc.

patterns = [
    r'"md5"\s*:\s*"([^"]+)"',
    r'"MD5_ORIGIN"\s*:\s*"([^"]+)"',
    r'"track_token"\s*:\s*"([^"]+)"',
    r'"TRACK_TOKEN"\s*:\s*"([^"]+)"',
    r'"hmac"\s*:\s*"([^"]+)"',
    r'"preview"\s*:\s*"([^"]+)"',
    r'"stream_token"\s*:\s*"([^"]+)"',
]

md5 = ""
track_token = ""
hmac = ""

for pattern_name, pattern in [
    ("MD5", r'"md5"\s*:\s*"([^"]+)"'),
    ("MD5_ORIGIN", r'"MD5_ORIGIN"\s*:\s*"([^"]+)"'),
]:
    matches = re.findall(pattern, html)
    if matches:
        md5 = matches[-1]  # Prendre le dernier (souvent le bon)
        print(f"  ✅ {pattern_name} trouvé: {md5}")
        break

for pattern_name, pattern in [
    ("TRACK_TOKEN", r'"TRACK_TOKEN"\s*:\s*"([^"]+)"'),
    ("track_token", r'"track_token"\s*:\s*"([^"]+)"'),
]:
    matches = re.findall(pattern, html)
    if matches:
        track_token = matches[-1]
        print(f"  ✅ {pattern_name} trouvé: {track_token[:40]}...")
        break

# Chercher aussi le PRELOADED_STATE
preloaded = re.search(r'window\.__PRELOADED_STATE__\s*=\s*({.*?});\s*</script>', html, re.DOTALL)
if preloaded:
    try:
        state = json.loads(preloaded.group(1))
        # Parcourir le state pour trouver les infos audio
        def find_in_dict(d, key):
            if isinstance(d, dict):
                for k, v in d.items():
                    if key.lower() in k.lower():
                        print(f"  Trouvé {k}: {str(v)[:80]}")
                    find_in_dict(v, key)
            elif isinstance(d, list):
                for item in d:
                    find_in_dict(item, key)
        
        print("\n🔍 Recherche dans le state...")
        find_in_dict(state, "md5")
        find_in_dict(state, "token")
        find_in_dict(state, "stream")
    except:
        pass

# === Si on a le MD5, construire l'URL directe ===
if md5:
    print(f"\n📥 MD5: {md5}")
    
    # Format CDN Deezer pour MP3
    # Le proxy letter est déterminé par le track ID
    proxy_letter = chr(97 + (TRACK_ID % 26))  # a-z
    
    # Essayer plusieurs formats d'URL
    urls_to_try = [
        f"https://e-cdns-proxy-{proxy_letter}.dzcdn.net/stream/c-{TRACK_ID}.mp3?algo=ormuse&title=Josman+-%20Intro&token={track_token}_{TRACK_ID}" if track_token else None,
        f"https://cdns-preview-{md5[0]}.dzcdn.net/mobile/1/{md5}.mp3",
        f"https://e-cdns-proxy-{proxy_letter}.dzcdn.net/mobile/1/{md5}.mp3",
        f"https://cdns-preview-{md5[0]}.dzcdn.net/stream/{md5}.mp3",
    ]
    
    artist = "Josman"
    title = "Intro"
    out = OUTPUT / f"{artist} - {title} [Deezer Scraper].mp3"
    
    for i, stream_url in enumerate(urls_to_try):
        if not stream_url:
            continue
        print(f"\n  Tentative {i+1}: {stream_url[:80]}...")
        
        req2 = urllib.request.Request(stream_url, headers={
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
            "Referer": "https://www.deezer.com/",
            "Accept": "*/*",
        })
        
        try:
            with urllib.request.urlopen(req2, timeout=20) as r:
                data = r.read()
            
            if len(data) > 10000:  # Plus de 10KB = probablement le vrai fichier
                with open(out, "wb") as f:
                    f.write(data)
                
                size_mb = len(data) / 1024 / 1024
                print(f"  ✅ Téléchargé: {size_mb:.2f} MB")
                
                # Analyser
                cmd = [
                    "ffprobe", "-v", "quiet",
                    "-show_entries", "stream=codec_name,sample_rate,channels",
                    "-show_entries", "format=size,bit_rate,duration",
                    "-of", "default=noprint_wrappers=1",
                    str(out)
                ]
                r = subprocess.run(cmd, capture_output=True, text=True)
                print(f"\n  🔍 Analyse:\n  {r.stdout}")
                break
            else:
                print(f"  ❌ Trop petit: {len(data)} bytes")
        except Exception as e:
            print(f"  ❌ Erreur: {e}")
else:
    print("\n❌ Aucun MD5 trouvé dans la page HTML")
    print("   Le track peut-être protégé par DRM sur Deezer")
    
    # Sauvegarder le HTML pour débogage
    debug_file = Path("tools/spotify-auth-spoof/deezer_page_debug.html")
    with open(debug_file, "w", encoding="utf-8") as f:
        f.write(html[:50000])
    print(f"   Page sauvegardée pour débogage: {debug_file}")

print("\n💡 Le rap français sur Deezer est souvent en MP3 320kbps uniquement.")
print("   Pour du vrai FLAC, il faut un compte Deezer HiFi ou Qobuz.")