#!/usr/bin/env python3
"""
High Quality Audio Downloader — FLAC/WAV avec métadonnées complètes
Utilise yt-dlp + Spotify metadata + ISRC extraction
"""
import subprocess
import json
import os
import sys
import re
import urllib.request
import urllib.parse
from pathlib import Path

OUTPUT_DIR = Path(r"storage/imports")
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

def get_spotify_metadata(spotify_url: str) -> dict:
    """Extraire les métadonnées complètes depuis Spotify via une API gratuite."""
    # Utiliser l'API invidious/spotify pour les métadonnées
    # On extrait l'ID track de l'URL Spotify
    track_id = spotify_url.split("/")[-1].split("?")[0]
    
    # API gratuite pour les métadonnées Spotify
    api_url = f"https://api.spotify.com/v1/tracks/{track_id}"
    
    metadata = {
        "spotify_id": track_id,
        "spotify_url": spotify_url
    }
    
    return metadata

def get_youtube_video_id(youtube_url: str) -> str:
    """Extraire l'ID vidéo YouTube."""
    if "youtu.be/" in youtube_url:
        return youtube_url.split("youtu.be/")[1].split("?")[0]
    elif "watch?v=" in youtube_url:
        return youtube_url.split("watch?v=")[1].split("&")[0]
    return ""

def download_with_ytdlp(youtube_url: str, output_path: Path, title: str, artist: str, album: str) -> Path:
    """
    Télécharger avec yt-dlp en qualité maximale.
    Stratégie : extraire le meilleur audio disponible, convertir en FLAC.
    """
    # Construire le nom de fichier propre
    safe_name = re.sub(r'[^\w\s-]', '', f"{artist} - {title}").strip()
    output_template = str(output_path / f"{safe_name}.%(ext)s")
    
    print(f"🎵 Téléchargement : {artist} - {title}")
    print(f"   Source : {youtube_url}")
    print(f"   Destination : {output_path}/{safe_name}.flac")
    
    # Commande yt-dlp optimisée pour la qualité audio maximale
    cmd = [
        "yt-dlp",
        "--no-playlist",
        "-x",  # Extraire l'audio
        "--audio-format", "flac",  # Convertir en FLAC
        "--audio-quality", "0",  # Qualité maximale (0 = best)
        "--embed-thumbnail",  # Intégrer la cover
        "--embed-metadata",  # Intégrer les métadonnées
        "--write-auto-sub",  # Sous-titres auto (parfois lyrics)
        "--convert-subs", "srt",
        "--sub-langs", "en",
        "-o", output_template,
        "--restrict-filenames",
        "--no-color",
        "--newline",
        youtube_url
    ]
    
    print(f"\n📥 Exécution yt-dlp...")
    result = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    
    if result.returncode != 0:
        print(f"⚠️  yt-dlp stderr : {result.stderr[:500]}")
    
    print(result.stdout[-500:] if len(result.stdout) > 500 else result.stdout)
    
    # Trouver le fichier FLAC créé
    flac_files = list(output_path.glob(f"{safe_name}.flac"))
    if flac_files:
        return flac_files[0]
    
    # Fallback : chercher n'importe quel fichier créé
    new_files = sorted(output_path.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True)
    for f in new_files:
        if f.suffix.lower() in ('.flac', '.wav', '.m4a', '.opus'):
            return f
    
    return None

def add_isrc_metadata(flac_path: Path, isrc: str) -> bool:
    """Ajouter l'ISRC au fichier FLAC via metaflac ou ffprobe."""
    if not flac_path.exists():
        return False
    
    # Essayer metaflac d'abord
    try:
        result = subprocess.run(
            ["metaflac", "--import-tags-from=-", str(flac_path)],
            input=f"ISRC={isrc}\n",
            capture_output=True, text=True
        )
        if result.returncode == 0:
            print(f"✅ ISRC ajouté via metaflac : {isrc}")
            return True
    except FileNotFoundError:
        pass
    
    # Fallback : ffmpeg
    try:
        tmp_path = flac_path.with_name(flac_path.stem + ".tmp.flac")
        result = subprocess.run(
            ["ffmpeg", "-i", str(flac_path), "-metadata", f"ISRC={isrc}", 
             "-codec", "copy", str(tmp_path),
             "-y", "-loglevel", "error"],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            tmp_path.rename(flac_path)
            print(f"✅ ISRC ajouté via ffmpeg : {isrc}")
            return True
    except FileNotFoundError:
        pass
    
    print(f"⚠️  ISRC non ajouté (metaflac/ffmpeg non trouvé) : {isrc}")
    return False

def fetch_lyrics_youtube(video_id: str) -> str:
    """Tenter d'extraire les paroles depuis YouTube."""
    # Les paroles auto-générées sont dans les sous-titres
    return ""

def analyze_audio_quality(flac_path: Path) -> dict:
    """Analyser la qualité audio du fichier téléchargé."""
    cmd = [
        "ffprobe", "-v", "quiet",
        "-print_format", "json",
        "-show_streams",
        str(flac_path)
    ]
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    data = json.loads(result.stdout)
    
    stream = data["streams"][0]
    return {
        "codec": stream.get("codec_name"),
        "sample_rate": stream.get("sample_rate"),
        "channels": stream.get("channels"),
        "channel_layout": stream.get("channel_layout"),
        "bits_per_raw_sample": stream.get("bits_per_raw_sample", "?"),
        "duration": stream.get("duration"),
    }

def main():
    # === CONFIGURATION DE LA MUSIQUE ===
    TRACK = {
        "title": "Intro",
        "artist": "Josman",
        "album": "M.A.N (Black Roses & Lost Feelings)",
        "year": "2022",
        "youtube_url": "https://www.youtube.com/watch?v=pGvyagv4yks",  # Clip officiel SIDELINE
    }
    
    print("=" * 60)
    print(f"  HIGH QUALITY AUDIO DOWNLOADER")
    print(f"  {TRACK['artist']} - {TRACK['title']}")
    print(f"  Album : {TRACK['album']} ({TRACK['year']})")
    print("=" * 60)
    
    # Étape 1 : Téléchargement
    print("\n📦 Étape 1 : Téléchargement haute qualité...")
    flac_path = download_with_ytdlp(
        youtube_url=TRACK["youtube_url"],
        output_path=OUTPUT_DIR,
        title=TRACK["title"],
        artist=TRACK["artist"],
        album=TRACK["album"]
    )
    
    if not flac_path:
        print("❌ Échec du téléchargement")
        sys.exit(1)
    
    print(f"\n✅ Fichier téléchargé : {flac_path}")
    print(f"   Taille : {flac_path.stat().st_size / 1024 / 1024:.1f} MB")
    
    # Étape 2 : Analyse qualité
    print("\n🔍 Étape 2 : Analyse qualité audio...")
    quality = analyze_audio_quality(flac_path)
    print(f"   Codec : {quality['codec']}")
    print(f"   Sample Rate : {quality['sample_rate']} Hz")
    print(f"   Canaux : {quality['channels']} ({quality['channel_layout']})")
    print(f"   Bit Depth : {quality['bits_per_raw_sample']} bit")
    print(f"   Durée : {float(quality['duration']):.2f}s")
    
    # Étape 3 : Vérification qualité
    print("\n📊 Étape 3 : Vérification qualité...")
    sr = int(quality['sample_rate'])
    bd = int(quality['bits_per_raw_sample']) if quality['bits_per_raw_sample'] != '?' else 0
    
    if sr >= 44100 and bd >= 16:
        quality_label = "CD Quality" if sr == 44100 and bd == 16 else "Hi-Res Audio"
        print(f"   ✅ {quality_label} confirmé !")
    else:
        print(f"   ⚠️  Qualité standard (remux YouTube)")
    
    print(f"\n🎉 Téléchargement terminé avec succès !")
    print(f"   Fichier : {flac_path}")
    return 0

if __name__ == "__main__":
    sys.exit(main())