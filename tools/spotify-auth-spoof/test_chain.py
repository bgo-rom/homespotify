#!/usr/bin/env python3
"""Test complet V1 → V2 → V4 en chaîne."""
import json, urllib.request, subprocess, sys, os

TOKEN = "BQByL5rKq-NqE1c8_3wWd0_aB2rwgkepCtQoAD01Z1K6PPA27vLE3rJw16Yplz6-syUGsGvuOM8biPVONc_NOMpVnAnRGDSe45KrpcjQ9pzsk1Qguq80eOcvfWTSkbHG1IWPs0eDWt4N"

print("=" * 60, flush=True)
print("  TEST CHAINE COMPLETE: V1 → V2 → V4", flush=True)
print("=" * 60, flush=True)

# V2: Recherche Spotify → ISRC
print("\n[V2] Spotify Search → ISRC...", flush=True)
req = urllib.request.Request("https://api.spotify.com/v1/search?q=Rick+Astley+Never+Gonna+Give+You+Up&type=track&limit=1")
req.add_header("Authorization", f"Bearer {TOKEN}")
resp = urllib.request.urlopen(req, timeout=10)
data = json.loads(resp.read().decode())
track = data["tracks"]["items"][0]
spotify_id = track["id"]
isrc = track.get("external_ids", {}).get("isrc", "")
track_name = track["name"]
artist_name = track["artists"][0]["name"]
print(f"  Spotify ID: {spotify_id}", flush=True)
print(f"  Track: {track_name}", flush=True)
print(f"  Artist: {artist_name}", flush=True)
print(f"  ISRC: {isrc}", flush=True)

if not isrc:
    print("\n[-] No ISRC from Spotify, trying audio_download_router without ISRC...", flush=True)

# V4: Download
print(f"\n[V4] Audio Download Router...", flush=True)
result = subprocess.run(
    [sys.executable, "audio_download_router.py", artist_name, track_name, isrc],
    capture_output=True, text=True, timeout=300,
    cwd=os.path.dirname(os.path.abspath(__file__))
)
print(result.stdout)
print(result.stderr)

if result.returncode == 0:
    print("\n" + "=" * 60, flush=True)
    print("  ✅ CHAINE COMPLETE REUSSIE!", flush=True)
    print("=" * 60, flush=True)
else:
    print(f"\n[!] Download router returned {result.returncode}", flush=True)