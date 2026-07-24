#!/usr/bin/env python3
"""
Lucida.to FLAC Downloader — Scraping intelligent de lucida.to
Télécharge du FLAC lossless depuis Qobuz, Tidal, Deezer via lucida.to

Usage:
  python lucida_dl.py "Josman" "Intro"
  python lucida_dl.py "artist" "track" [--output storage/imports]
"""

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import urllib.error
from pathlib import Path

# ─── Configuration ──────────────────────────────────────────────────────────────
LUCIDA_BASE = "https://lucida.to"
OUTPUT_DIR = Path("storage/imports")

# Headers qui simulent un vrai navigateur
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "fr-FR,fr;q=0.9,en;q=0.8",
    "Referer": "https://lucida.to/",
    "Origin": "https://lucida.to",
}


def lucida_search(query: str) -> list:
    """
    Recherche une piste sur lucida.to via l'API.
    Lucida utilise une API REST pour la recherche.
    """
    # Lucida.to a une API de recherche
    # On essaie plusieurs endpoints possibles
    endpoints = [
        f"{LUCIDA_BASE}/api/search?q={urllib.parse.quote(query)}",
        f"{LUCIDA_BASE}/search?q={urllib.parse.quote(query)}",
    ]
    
    for url in endpoints:
        try:
            req = urllib.request.Request(url, headers=HEADERS)
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode())
                return data.get("results", data.get("tracks", []))
        except Exception:
            continue
    
    return []


def lucida_download(track_url: str, output_path: str) -> bool:
    """
    Télécharge une piste depuis lucida.to.
    Lucida génère un URL de téléchargement temporaire.
    """
    # Lucida utilise un endpoint de téléchargement
    # On essaie de récupérer le lien de téléchargement
    endpoints = [
        f"{LUCIDA_BASE}/api/download?url={urllib.parse.quote(track_url)}",
        f"{LUCIDA_BASE}/download?url={urllib.parse.quote(track_url)}",
    ]
    
    for url in endpoints:
        try:
            req = urllib.request.Request(url, headers=HEADERS)
            with urllib.request.urlopen(req, timeout=30) as resp:
                # Le contenu peut être directement le fichier audio
                # ou un JSON avec l'URL de téléchargement
                content_type = resp.headers.get("Content-Type", "")
                if "audio" in content_type or "octet-stream" in content_type:
                    with open(output_path, "wb") as f:
                        f.write(resp.read())
                    return True
                else:
                    data = json.loads(resp.read().decode())
                    if "url" in data:
                        # Télécharger depuis l'URL fournie
                        req2 = urllib.request.Request(data["url"], headers=HEADERS)
                        with urllib.request.urlopen(req2, timeout=120) as resp2:
                            with open(output_path, "wb") as f:
                                f.write(resp2.read())
                        return True
        except Exception:
            continue
    
    return False


def download_flac(artist: str, track: str, output_dir: str = "storage/imports") -> str | None:
    """
    Télécharge du FLAC pour une piste donnée via lucida.to.
    """
    import shutil
    
    print("=" * 60)
    print("  LUCIDA.TO FLAC DOWNLOADER")
    print("=" * 60)
    print(f"  Artiste : {artist}")
    print(f"  Piste   : {track}")
    print(f"  Sortie  : {output_dir}")
    print("=" * 60)
    
    output_path = Path(output_dir)
    output_path.mkdir(parents=True, exist_ok=True)
    
    # Recherche
    print("\n[1/3] Recherche sur lucida.to...", flush=True)
    query = f"{artist} - {track}"
    results = lucida_search(query)
    
    if not results:
        print(f"  [-] Aucun résultat pour '{query}'", file=sys.stderr)
        return None
    
    print(f"  [+] {len(results)} résultat(s) trouvé(s)", flush=True)
    
    # Trouver le meilleur résultat (FLAC prioritaire)
    best = None
    for r in results:
        title = r.get("title", r.get("name", ""))
        artist_name = r.get("artist", r.get("artist_name", ""))
        quality = r.get("quality", r.get("format", ""))
        url = r.get("url", r.get("track_url", ""))
        
        print(f"    • {artist_name} - {title} [{quality}]", file=sys.stderr)
        
        # Prioriser FLAC
        if "flac" in quality.lower() and not best:
            best = r
        elif not best:
            best = r
    
    if not best:
        print("  [-] Aucun résultat FLAC trouvé", file=sys.stderr)
        return None
    
    # Téléchargement
    print(f"\n[2/3] Téléchargement...", flush=True)
    safe_name = re.sub(r'[^\w\-_\. ]', '_', f"{artist} - {track}")
    output_file = output_path / f"{safe_name}.flac"
    
    track_url = best.get("url", best.get("track_url", ""))
    if lucida_download(track_url, str(output_file)):
        size = output_file.stat().st_size
        print(f"  [+] Téléchargé: {output_file} ({size/1024/1024:.1f} MB)", flush=True)
        
        # Analyse
        print(f"\n[3/3] Analyse...", flush=True)
        ffmpeg = shutil.which("ffprobe")
        if ffmpeg:
            try:
                r = subprocess.run(
                    [ffmpeg, "-v", "quiet", "-show_entries",
                     "stream=codec_name,sample_rate,channels,bits_per_raw_sample",
                     "-show_entries", "format=size,bit_rate,duration",
                     "-of", "default=noprint_wrappers=1", str(output_file)],
                    capture_output=True, text=True, timeout=10
                )
                print(f"  {r.stdout}", flush=True)
            except Exception:
                pass
        
        return str(output_file)
    
    print("  [-] Échec du téléchargement", file=sys.stderr)
    return None


def main():
    parser = argparse.ArgumentParser(description="Lucida.to FLAC Downloader")
    parser.add_argument("artist", help="Nom de l'artiste")
    parser.add_argument("track", help="Nom de la piste")
    parser.add_argument("--output", "-o", default="storage/imports", help="Répertoire de sortie")
    
    args = parser.parse_args()
    result = download_flac(args.artist, args.track, args.output)
    
    if result:
        print(f"\n✅ SUCCÈS: {result}", flush=True)
        sys.exit(0)
    else:
        print("\n❌ ÉCHEC", flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()