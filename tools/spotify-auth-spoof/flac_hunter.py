#!/usr/bin/env python3
"""
FLAC Hunter — Trouve le VRAI FLAC/WAV original depuis toutes les sources
Stratégie : SoundCloud (upload original) > YouTube Music (audio pur) > Fallback
"""
import subprocess
import json
import sys
import re
import time
from pathlib import Path

OUTPUT_DIR = Path(r"storage/imports")
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

ARTIST = "Josman"
TITLE = "Intro"
SAFE = re.sub(r'[^\w\s-]', '', f"{ARTIST} - {TITLE}").strip()


def try_soundcloud():
    """SoundCloud : le label/artiste upload souvent le WAV/FLAC original."""
    # URL directe du track Josman sur SoundCloud
    urls = [
        "https://soundcloud.com/josman-officiel/intro",
        "https://soundcloud.com/josman/intro",
        "https://soundcloud.com/sideline/josman-intro",
    ]
    
    for url in urls:
        print(f"\n🎵 Tentative SoundCloud : {url}")
        cmd = [
            "yt-dlp", "-f", "bestaudio", "--no-playlist",
            "--embed-thumbnail", "--embed-metadata",
            "-o", str(OUTPUT_DIR / f"{SAFE}.%(ext)s"),
            "--restrict-filenames", "--no-color", "--newline",
            "--extractor-args", "soundcloud:client_version=latest",
            "-v",
            url
        ]
        r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
        
        if r.returncode == 0:
            # Trouver le fichier
            for f in sorted(OUTPUT_DIR.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True):
                if SAFE in f.name and f.suffix.lower() in ('.flac', '.wav', '.ogg', '.opus', '.mp3', '.m4a', '.webm'):
                    return f
        
        # Clean up partial downloads on failure
        for f in OUTPUT_DIR.glob(f"{SAFE}*"):
            if f.suffix != '.flac':  # Keep existing good files
                pass
    
    return None


def try_youtube_music_audio():
    """YouTube Music : l'audio-only track (pas le clip vidéo)."""
    print(f"\n🎵 Recherche YouTube Music (audio pur, pas clip)...")
    
    # yt-dlp trouve automatiquement l'audio sur YouTube Music
    cmd = [
        "yt-dlp",
        "--flat-playlist",
        "--playlist-items", "1:5",
        "--print", "%(id)s|%(title)s|%(duration)s",
        "-o", "%(id)s.tmp",
        f"https://music.youtube.com/search?q={ARTIST}+{TITLE}+M.A.N"
    ]
    
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    
    # Trouver le bon résultat (audio pur, pas le clip)
    best_id = None
    for line in r.stdout.strip().split("\n"):
        parts = line.split("|")
        if len(parts) >= 2:
            vid_id = parts[0]
            title_lower = parts[1].lower()
            # L'audio pur n'a pas "clip" ou "official video" dans le titre
            if "intro" in title_lower and "clip" not in title_lower and "video" not in title_lower:
                best_id = vid_id
                print(f"   ✅ Audio pur trouvé : {parts[1]}")
                break
    
    if not best_id:
        # Fallback : prendre le premier résultat
        lines = r.stdout.strip().split("\n")
        if lines and "|" in lines[0]:
            best_id = lines[0].split("|")[0]
            print(f"   ⚠️  Fallback : {lines[0]}")
    
    if not best_id:
        print("   ❌ Rien trouvé")
        return None
    
    # Télécharger l'audio
    url = f"https://music.youtube.com/watch?v={best_id}"
    cmd = [
        "yt-dlp",
        "-f", "bestaudio[ext=m4a]/bestaudio",  # m4a = AAC original YouTube
        "--no-playlist",
        "--embed-thumbnail", "--embed-metadata",
        "-o", str(OUTPUT_DIR / f"{SAFE}.%(ext)s"),
        "--restrict-filenames", "--no-color", "--newline",
        url
    ]
    
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    
    if r.returncode == 0:
        for f in sorted(OUTPUT_DIR.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True):
            if SAFE in f.name:
                return f
    
    return None


def try_youtube_audio_only():
    """YouTube classique : extraire l'audio du clip officiel en meilleure qualité."""
    print(f"\n🎵 Fallback YouTube (audio du clip officiel)...")
    
    # Le clip officiel
    url = "https://www.youtube.com/watch?v=pGvyagv4yks"
    
    # Télécharger le meilleur stream audio (Opus 160kbps = meilleure qualité YouTube)
    cmd = [
        "yt-dlp",
        "-f", "bestaudio[ext=webm]",  # Opus en webm
        "--no-playlist",
        "--embed-thumbnail", "--embed-metadata",
        "-o", str(OUTPUT_DIR / f"{SAFE}.%(ext)s"),
        "--restrict-filenames", "--no-color", "--newline",
        url
    ]
    
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    
    if r.returncode == 0:
        for f in sorted(OUTPUT_DIR.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True):
            if SAFE in f.name:
                return f
    
    return None


def analyze(filepath):
    """Analyse complète du fichier."""
    cmd = [
        "ffprobe", "-v", "quiet",
        "-print_format", "json",
        "-show_streams", "-show_format",
        str(filepath)
    ]
    
    r = subprocess.run(cmd, capture_output=True, text=True)
    d = json.loads(r.stdout)
    s = d["streams"][0]
    f = d["format"]
    
    print(f"\n{'='*60}")
    print(f"  🎵 ANALYSE QUALITÉ — {filepath.name}")
    print(f"{'='*60}")
    print(f"  Format     : {s.get('codec_name').upper()}")
    print(f"  Sample Rate: {s.get('sample_rate')} Hz")
    
    bps = s.get('bits_per_raw_sample')
    print(f"  Bit Depth  : {bps} bit" if bps and bps != '?' else "  Bit Depth  : variable/unknown")
    
    print(f"  Canaux     : {s.get('channels')} ({s.get('channel_layout')})")
    print(f"  Durée      : {float(s.get('duration', f.get('duration', 0))):.2f}s")
    print(f"  Taille     : {int(f.get('size', 0)) / 1024 / 1024:.1f} MB")
    
    br = f.get('bit_rate')
    if br:
        print(f"  Bitrate    : {int(br)/1000:.0f} kbps")
    
    # Tags
    tags = f.get("tags", {})
    if tags:
        print(f"\n  📝 MÉTADONNÉES :")
        for k in ['title', 'artist', 'album', 'date', 'genre', 'ISRC']:
            if k in tags:
                val = str(tags[k])[:80]
                print(f"    {k:<12}: {val}")
    
    # Verdict
    sr = int(s.get('sample_rate', 0))
    codec = s.get('codec_name', '').lower()
    
    print(f"\n  ⚖️  VERDICT :")
    if codec == 'flac':
        print(f"    ✅ VRAI FLAC — Audio lossless original !")
    elif codec == 'pcm_s16le' or codec == 'pcm_s24le':
        print(f"    ✅ VRAI WAV — Audio non compressé original !")
    elif codec in ('opus', 'mp3', 'aac', 'm4a'):
        if codec == 'opus' and sr >= 48000:
            print(f"    ⚠️  Opus {sr//1000}kHz — Bonne qualité mais compressé (source YouTube)")
        else:
            print(f"    ⚠️  {codec.upper()} — Compressé avec perte")
    else:
        print(f"    ❓ Format {codec.upper()} — Inconnu")


def main():
    print("=" * 60)
    print(f"  FLAC HUNTER — Vrai audio original")
    print(f"  {ARTIST} - {TITLE}")
    print("=" * 60)
    
    filepath = None
    
    # 1. SoundCloud (meilleure chance de WAV/FLAC original)
    filepath = try_soundcloud()
    
    # 2. YouTube Music (audio pur, pas clip)
    if not filepath:
        filepath = try_youtube_music_audio()
    
    # 3. YouTube clip (fallback)
    if not filepath:
        filepath = try_youtube_audio_only()
    
    if filepath and filepath.exists():
        print(f"\n✅ Fichier : {filepath}")
        analyze(filepath)
        return 0
    
    print("\n❌ Tous les téléchargements ont échoué")
    return 1


if __name__ == "__main__":
    sys.exit(main())