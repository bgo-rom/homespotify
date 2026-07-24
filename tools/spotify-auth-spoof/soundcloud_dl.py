#!/usr/bin/env python3
"""
SoundCloud FLAC/WAV Downloader — Audio original sans re-encodage
Utilise yt-dlp pour extraire le meilleur format audio disponible sur SoundCloud.
SoundCloud stocke les uploads originaux (souvent WAV/FLAC) avant conversion.
"""
import subprocess
import json
import sys
import re
import urllib.request
import urllib.parse
from pathlib import Path

OUTPUT_DIR = Path(r"storage/imports")
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

def search_soundcloud(artist: str, title: str) -> str:
    """Rechercher sur SoundCloud et retourner la meilleure URL."""
    query = f"{artist} {title}"
    url = f"https://soundcloud.com/search?q={urllib.parse.quote(query)}&filter=best&duration=&genre=&performance_label=&type=tracks"
    
    req = urllib.request.Request(url, headers={
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    })
    
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            html = resp.read().decode("utf-8", errors="ignore")
        
        # Extraire les URLs des tracks
        import html as html_mod
        pattern = r'href="(/sets/[^"]+|/[^/]+/[^/]+/[^"]+)"'
        matches = re.findall(pattern, html)
        
        print(f"\n🔍 Résultats SoundCloud pour '{query}' :")
        for i, match in enumerate(matches[:5]):
            full_url = f"https://soundcloud.com{match}"
            print(f"  {i+1}. {full_url}")
        
        if matches:
            return f"https://soundcloud.com{matches[0]}"
        
        # Fallback : recherche YouTube Music pour la version audio pure
        return None
        
    except Exception as e:
        print(f"   Erreur SoundCloud : {e}")
        return None


def download_soundcloud(sc_url: str, artist: str, title: str) -> Path:
    """Télécharger depuis SoundCloud en qualité maximale sans conversion."""
    safe_name = re.sub(r'[^\w\s-]', '', f"{artist} - {title}").strip()
    output_template = str(OUTPUT_DIR / f"{safe_name}.%(ext)s")
    
    # yt-dlp avec SoundCloud : extraire le format original sans re-encodage
    cmd = [
        "yt-dlp",
        "-f", "bestaudio",  # Meilleur format audio disponible (pas de conversion)
        "--no-playlist",
        "--embed-thumbnail",
        "--embed-metadata",
        "-o", output_template,
        "--restrict-filenames",
        "--no-color",
        "--newline",
        "--extractor-args", "soundcloud:client_version=latest",
        sc_url
    ]
    
    print(f"\n📥 Téléchargement depuis SoundCloud...")
    result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    
    print(result.stdout[-800:] if len(result.stdout) > 800 else result.stdout)
    if result.returncode != 0:
        print(f"⚠️  stderr : {result.stderr[:500]}")
    
    # Trouver le fichier créé
    new_files = sorted(OUTPUT_DIR.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True)
    for f in new_files:
        if f.suffix.lower() in ('.flac', '.wav', '.ogg', '.opus', '.mp3', '.m4a'):
            return f
    
    return None


def download_ytmusic_audio(artist: str, title: str) -> Path:
    """
    Fallback : YouTube Music — extraire l'audio original du fichier source.
    YouTube stocke l'audio en Opus à 160kbps, mais c'est l'audio original
    sans compression vidéo, donc meilleur que l'extraction depuis un clip.
    """
    # Chercher l'audio pur sur YouTube Music
    search_url = f"https://music.youtube.com/search?q={urllib.parse.quote(f'{artist} {title}')}"
    
    safe_name = re.sub(r'[^\w\s-]', '', f"{artist} - {title}").strip()
    output_template = str(OUTPUT_DIR / f"{safe_name}.%(ext)s")
    
    # D'abord trouver l'URL du track audio pur (pas le clip)
    import urllib.request
    req = urllib.request.Request(search_url, headers={
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    })
    
    # Utiliser yt-dlp pour chercher et télécharger directement
    cmd = [
        "yt-dlp",
        "--flat-playlist",
        "-o", "%(id)s.%(ext)s",
        "--print", "%(id)s|%(title)s|%(url)s",
        "--playlist-items", "1:3",
        search_url
    ]
    
    print(f"\n🔍 Recherche audio sur YouTube Music...")
    result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    
    lines = result.stdout.strip().split("\n")
    audio_url = None
    for line in lines:
        if "|" in line and "watch?v=" in line:
            parts = line.split("|")
            if "Intro" in parts[1] or artist.split()[0] in parts[1].lower():
                audio_url = f"https://www.youtube.com/watch?v={parts[0]}"
                print(f"   Trouvé : {parts[1]} → {audio_url}")
                break
    
    if not audio_url and lines:
        # Prendre le premier résultat
        parts = lines[0].split("|")
        video_id = parts[0] if "|" in parts[0] else None
        if video_id:
            audio_url = f"https://www.youtube.com/watch?v={video_id}"
    
    if not audio_url:
        print("   ❌ Aucun résultat trouvé sur YouTube Music")
        return None
    
    # Télécharger l'audio en format original (Opus = meilleure qualité YouTube)
    cmd = [
        "yt-dlp",
        "-f", "bestaudio[ext=webm]/bestaudio",  # Opus en webm = meilleure qualité
        "--no-playlist",
        "--embed-thumbnail",
        "--embed-metadata",
        "-o", output_template,
        "--restrict-filenames",
        "--no-color",
        "--newline",
        audio_url
    ]
    
    print(f"\n📥 Téléchargement audio depuis YouTube Music...")
    print(f"   URL : {audio_url}")
    result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    
    print(result.stdout[-500:] if len(result.stdout) > 500 else result.stdout)
    
    # Trouver le fichier
    new_files = sorted(OUTPUT_DIR.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True)
    for f in new_files:
        if f.suffix.lower() in ('.opus', '.webm', '.m4a', '.mp3'):
            # Renommer avec extension correcte
            final = OUTPUT_DIR / f"{safe_name}{f.suffix}"
            if f.name != final.name:
                f.rename(final)
            return final
    
    return None


def analyze_file(filepath: Path):
    """Analyser le fichier audio téléchargé."""
    cmd = [
        "ffprobe", "-v", "quiet",
        "-print_format", "json",
        "-show_streams", "-show_format",
        str(filepath)
    ]
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    data = json.loads(result.stdout)
    
    stream = data["streams"][0]
    fmt = data["format"]
    
    print(f"\n{'='*50}")
    print(f"  ANALYSE QUALITÉ AUDIO")
    print(f"{'='*50}")
    print(f"  Fichier : {filepath.name}")
    print(f"  Taille : {int(fmt.get('size', 0)) / 1024 / 1024:.1f} MB")
    print(f"  Codec : {stream.get('codec_name')}")
    print(f"  Sample Rate : {stream.get('sample_rate')} Hz")
    print(f"  Bit Depth : {stream.get('bits_per_raw_sample', '?')} bit")
    print(f"  Canaux : {stream.get('channels')} ({stream.get('channel_layout')})")
    print(f"  Durée : {float(stream.get('duration', fmt.get('duration', 0))):.2f}s")
    print(f"  Bitrate : {fmt.get('bit_rate', '?')} bps")
    
    # Analyser les tags
    tags = fmt.get("tags", {})
    if tags:
        print(f"\n  MÉTADONNÉES :")
        for key in ['title', 'artist', 'album', 'date', 'genre', 'ISRC']:
            if key in tags:
                print(f"    {key}: {tags[key]}")


def main():
    ARTIST = "Josman"
    TITLE = "Intro"
    
    print("=" * 60)
    print(f"  SOUND CLOUD / YOUTUBE MUSIC DOWNLOADER")
    print(f"  {ARTIST} - {TITLE}")
    print(f"  Audio original SANS re-encodage")
    print("=" * 60)
    
    # Étape 1 : SoundCloud
    print("\n🎵 Étape 1 : Recherche sur SoundCloud...")
    sc_url = search_soundcloud(ARTIST, TITLE)
    
    filepath = None
    if sc_url:
        filepath = download_soundcloud(sc_url, ARTIST, TITLE)
    
    # Étape 2 : Fallback YouTube Music
    if not filepath:
        print(f"\n🎵 Étape 2 : Fallback YouTube Music...")
        filepath = download_ytmusic_audio(ARTIST, TITLE)
    
    if filepath and filepath.exists():
        print(f"\n✅ Téléchargé : {filepath}")
        analyze_file(filepath)
        return 0
    
    print("\n❌ Échec du téléchargement")
    return 1


if __name__ == "__main__":
    sys.exit(main())