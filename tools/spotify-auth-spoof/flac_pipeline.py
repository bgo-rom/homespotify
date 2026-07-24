#!/usr/bin/env python3
"""
HomeSpotify FLAC Pipeline — v3
=============================================

Pipeline complet d'acquisition FLAC :
  Spotify URL/ID → Métadonnées complètes → Download FLAC → Taggage → Output

Sources (cascade) :
  1. spotDL         — Spotify → YouTube Music → FLAC (fonctionne sans compte payant)
  2. SpotiFLAC CLI  — Qobuz/Tidal/Deezer (nécessite compte payant)
  3. yt-dlp         — YouTube Music → FLAC remux (fallback direct)
  4. Deezer API     — preview MP3 320 (dernier recours)

Usage :
  python flac_pipeline.py "https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT"
  python flac_pipeline.py --isrc "GBARL9300135"
  python flac_pipeline.py --search "Rick Astley" "Never Gonna Give You Up"
  python flac_pipeline.py --source spotdl <spotify_url>
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import urllib.error
from pathlib import Path
from typing import Optional


# ============================================================
#  TrackInfo — conteneur de métadonnées
# ============================================================

class TrackInfo:
    __slots__ = [
        'title', 'artist', 'album', 'album_artist', 'track_number',
        'disc_number', 'total_tracks', 'year', 'genre', 'isrc',
        'barcode', 'duration', 'cover_url', 'spotify_id',
        'source_name', 'quality_label'
    ]

    def __init__(self, **kwargs):
        for slot in self.__slots__:
            setattr(self, slot, kwargs.get(slot))

    def safe_filename(self, ext='flac'):
        title = self.title or 'unknown'
        prefix = f"{self.track_number:02d}_ " if self.track_number else ""
        safe = re.sub(r'[^\w\-_\. ]', '_', f"{prefix}{title}")
        return safe[:200].rstrip('_ ') + f'.{ext}'

    def to_dict(self):
        return {s: getattr(self, s) for s in self.__slots__ if getattr(self, s) is not None}


# ============================================================
#  0. Spotify — résolution URL → TrackInfo + ISRC
# ============================================================

def spotify_resolve(url_or_id: str, bearer_token: str = None) -> Optional[TrackInfo]:
    if url_or_id.startswith('http'):
        m = re.search(r'track/([a-zA-Z0-9]+)', url_or_id)
        spotify_id = m.group(1) if m else None
    else:
        spotify_id = url_or_id.strip()

    if not spotify_id:
        return None

    if not bearer_token:
        bearer_token = _get_spotify_token()

    if bearer_token:
        try:
            url = f"https://api.spotify.com/v1/tracks/{spotify_id}"
            req = urllib.request.Request(url)
            req.add_header("Authorization", f"Bearer {bearer_token}")
            req.add_header("User-Agent", "Mozilla/5.0")
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode())

            artists = data.get('artists', [])
            albums = data.get('album', {})
            return TrackInfo(
                title=data.get('name'),
                artist=artists[0]['name'] if artists else None,
                album=albums.get('name'),
                album_artist=(albums.get('artists', [{}])[0] or {}).get('name'),
                track_number=data.get('track_number'),
                total_tracks=albums.get('total_tracks'),
                year=str(albums.get('release_year')) if albums.get('release_year') else None,
                isrc=data.get('external_ids', {}).get('isrc'),
                barcode=data.get('external_ids', {}).get('upc'),
                duration=data.get('duration_ms'),
                spotify_id=spotify_id,
            )
        except Exception as e:
            print(f"    [!] Spotify API: {e}", file=sys.stderr)

    # Fallback : spotify_auth_spoof
    try:
        sys.path.insert(0, os.path.dirname(__file__))
        from spotify_auth_spoof import get_spotify_credentials
        creds = get_spotify_credentials()
        if creds:
            ci, cs = creds
            import base64
            token_data = urllib.parse.urlencode({'grant_type': 'client_credentials'}).encode()
            auth = base64.b64encode(f'{ci}:{cs}'.encode()).decode()
            req = urllib.request.Request(
                'https://accounts.spotify.com/api/token',
                data=token_data,
                headers={'Authorization': f'Basic {auth}', 'Content-Type': 'application/x-www-form-urlencoded'},
            )
            with urllib.request.urlopen(req, timeout=15) as resp:
                td = json.loads(resp.read().decode())
            return spotify_resolve(spotify_id, td.get('access_token'))
    except Exception:
        pass

    return None


def _get_spotify_token() -> Optional[str]:
    client_id = os.environ.get('SPOTIFY_CLIENT_ID')
    client_secret = os.environ.get('SPOTIFY_CLIENT_SECRET')
    if not client_id or not client_secret:
        return None
    try:
        import base64
        data = urllib.parse.urlencode({'grant_type': 'client_credentials'}).encode()
        auth = base64.b64encode(f'{client_id}:{client_secret}'.encode()).decode()
        req = urllib.request.Request(
            'https://accounts.spotify.com/api/token',
            data=data,
            headers={'Authorization': f'Basic {auth}', 'Content-Type': 'application/x-www-form-urlencoded'},
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode()).get('access_token')
    except Exception:
        return None


# ============================================================
#  1. spotDL — Spotify → YouTube Music → FLAC (PRIMAIRE)
# ============================================================

def spotdl_download(spotify_url: str, output_dir: str, timeout: int = 180) -> Optional[dict]:
    """
    Utilise spotDL pour télécharger depuis YouTube Music → FLAC.
    Fonctionne sans compte payant. Métadonnées automatiques.
    """
    os.makedirs(output_dir, exist_ok=True)

    # Trouver l'exécutable spotDL
    spotdl = shutil.which('spotdl')
    if not spotdl:
        # Essayer dans Scripts user
        scripts_dir = os.path.join(os.environ.get('APPDATA', ''), 'Python', 'Python310', 'Scripts')
        candidate = os.path.join(scripts_dir, 'spotdl.exe')
        if os.path.exists(candidate):
            spotdl = candidate

    if not spotdl:
        print("    [!] spotDL non trouvé (pip install spotdl)", file=sys.stderr)
        return None

    safe_name = re.sub(r'[^\w\-_\. ]', '_', "download_track")
    out_tpl = os.path.join(output_dir, f"{safe_name}")

    cmd = [
        spotdl,
        '--format', 'flac',
        '--output', f'{out_tpl}',
        '--overwrite', 'skip',
        'download', spotify_url,
    ]

    print(f"    [cmd] {' '.join(cmd)}", file=sys.stderr)

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        if result.returncode == 0:
            # Chercher les fichiers FLAC créés
            for ext in ['flac', 'm4a', 'mp3']:
                recent = sorted(
                    Path(output_dir).glob(f'*.{ext}'),
                    key=lambda p: p.stat().st_mtime, reverse=True
                )
                if recent:
                    f = str(recent[0])
                    size = os.path.getsize(f)
                    if size > 10000:
                        return {'file': f, 'source': 'spotdl', 'quality': 'FLAC (YouTube Music)', 'size': size}
    except subprocess.TimeoutExpired:
        print(f"    [!] spotDL timeout après {timeout}s", file=sys.stderr)
    except Exception as e:
        print(f"    [!] spotDL: {e}", file=sys.stderr)

    return None


# ============================================================
#  2. SpotiFLAC CLI — Qobuz/Tidal (compte payant requis)
# ============================================================

def spotiflac_cli_download(spotify_url: str, output_dir: str,
                           services: list = None, timeout: int = 120) -> Optional[dict]:
    """
    Utilise SpotiFLAC CLI pour télécharger.
    Nécessite un compte Qobuz ou Tidal payant.
    """
    if services is None:
        services = ['qobuz', 'tidal']

    os.makedirs(output_dir, exist_ok=True)

    cmd = [
        sys.executable, '-m', 'SpotiFLAC',
        '--no-extensions-fallback',
        '--timeout', str(timeout),
        '--no-lyrics',
        '--no-enrich',
    ]

    for svc in services:
        cmd.extend(['--service', svc])

    cmd.extend([spotify_url, output_dir])

    print(f"    [cmd] {' '.join(cmd)}", file=sys.stderr)

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 30)
        if result.returncode == 0:
            for ext in ['flac', 'm4a', 'mp3']:
                recent = sorted(
                    Path(output_dir).glob(f'*.{ext}'),
                    key=lambda p: p.stat().st_mtime, reverse=True
                )
                if recent:
                    f = str(recent[0])
                    if os.path.getsize(f) > 10000:
                        return {'file': f, 'source': 'spotiflac', 'quality': 'FLAC'}
    except subprocess.TimeoutExpired:
        print(f"    [!] SpotiFLAC CLI timeout après {timeout}s", file=sys.stderr)
    except Exception as e:
        print(f"    [!] SpotiFLAC CLI: {e}", file=sys.stderr)

    return None


# ============================================================
#  3. yt-dlp — YouTube Music → FLAC remux
# ============================================================

def ytdlp_download(track_info: TrackInfo, output_dir: str) -> Optional[str]:
    ytdlp = shutil.which('yt-dlp')
    if not ytdlp or not track_info.artist or not track_info.title:
        return None

    os.makedirs(output_dir, exist_ok=True)
    safe = re.sub(r'[^\w\-_\. ]', '_', f"{track_info.artist} - {track_info.title}")
    out_tpl = os.path.join(output_dir, safe)

    try:
        result = subprocess.run(
            [ytdlp, '-x', '--audio-format', 'flac', '--embed-thumbnail',
             '-o', f"{out_tpl}.%(ext)s", '--no-playlist',
             f'ytsearch1:{track_info.artist} - {track_info.title}'],
            capture_output=True, text=True, timeout=180
        )
        if result.returncode == 0:
            for f in Path(output_dir).glob(f"{safe[:30]}*.flac"):
                size = f.stat().st_size
                if size > 10000:
                    track_info.source_name = 'yt-dlp'
                    track_info.quality_label = 'FLAC (YouTube remux)'
                    print(f"    [+] yt-dlp: {f} ({size/1024/1024:.1f} MB)", file=sys.stderr)
                    return str(f)
    except (subprocess.TimeoutExpired, Exception) as e:
        print(f"    [!] yt-dlp: {e}", file=sys.stderr)

    return None


# ============================================================
#  4. Deezer — preview MP3 320 (dernier recours)
# ============================================================

def deezer_download(track_info: TrackInfo, output_dir: str) -> Optional[str]:
    track_id = None
    if track_info.isrc:
        try:
            url = f"https://api.deezer.com/track/search?q=isrc:{track_info.isrc}&limit=1"
            req = urllib.request.Request(url)
            req.add_header("User-Agent", "Mozilla/5.0")
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode())
            if data.get('data'):
                track_id = data['data'][0].get('id')
                ti = data['data'][0]
                if not track_info.title:
                    track_info.title = ti.get('title')
                if not track_info.artist:
                    track_info.artist = (ti.get('artist') or {}).get('name')
                if not track_info.album:
                    track_info.album = (ti.get('album') or {}).get('title')
        except Exception:
            pass

    if not track_id and track_info.artist and track_info.title:
        try:
            query = urllib.parse.quote(f"{track_info.artist} {track_info.title}")
            url = f"https://api.deezer.com/search?q={query}&limit=1&type=track"
            req = urllib.request.Request(url)
            req.add_header("User-Agent", "Mozilla/5.0")
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode())
            if data.get('data'):
                track_id = data['data'][0].get('id')
        except Exception:
            pass

    if not track_id:
        return None

    try:
        url = f"https://api.deezer.com/track/{track_id}"
        req = urllib.request.Request(url)
        req.add_header("User-Agent", "Mozilla/5.0")
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode())

        preview = data.get('preview', '')
        if preview:
            os.makedirs(output_dir, exist_ok=True)
            out_path = os.path.join(output_dir, track_info.safe_filename('mp3'))
            req2 = urllib.request.Request(preview)
            req2.add_header("User-Agent", "Mozilla/5.0")
            with urllib.request.urlopen(req2, timeout=30) as resp2:
                with open(out_path, 'wb') as f:
                    shutil.copyfileobj(resp2, f)
            size = os.path.getsize(out_path)
            if size > 5000:
                track_info.source_name = 'deezer'
                track_info.quality_label = 'MP3 320 (preview 30s)'
                print(f"    [+] Deezer: {out_path} ({size/1024:.0f} KB)", file=sys.stderr)
                return out_path
    except Exception:
        pass

    return None


# ============================================================
#  5. Taggage
# ============================================================

def tag_flac(file_path: str, track_info: TrackInfo) -> bool:
    if not file_path or not os.path.exists(file_path):
        return False

    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        return False

    tags = []
    for key, value in [
        ('TITLE', track_info.title), ('ARTIST', track_info.artist),
        ('ALBUM', track_info.album), ('ALBUMARTIST', track_info.album_artist),
        ('TRACKNUMBER', str(track_info.track_number) if track_info.track_number else None),
        ('YEAR', track_info.year), ('DATE', track_info.year),
        ('ISRC', track_info.isrc), ('BARCODE', track_info.barcode),
    ]:
        if value:
            tags.extend(['-metadata', f'{key}={value}'])

    if not tags:
        return False

    try:
        out_tmp = file_path + '.tmp'
        args = [ffmpeg, '-i', file_path, '-c', 'copy'] + tags + ['-y', out_tmp]
        result = subprocess.run(args, capture_output=True, timeout=60)
        if result.returncode == 0:
            shutil.move(out_tmp, file_path)
            print(f"    [tag] Taggé: {file_path}", file=sys.stderr)
            return True
    except Exception as e:
        print(f"    [!] ffmpeg tag: {e}", file=sys.stderr)

    return False


# ============================================================
#  Routeur principal
# ============================================================

def download_flac(track_info: TrackInfo, output_dir: str = 'storage/imports',
                  sources: list = None, force_source: str = None) -> Optional[str]:
    if sources is None:
        sources = ['spotdl', 'spotiflac', 'ytdlp', 'deezer']

    print("\n" + "=" * 60)
    print("  HOMESPOTIFY FLAC PIPELINE v3")
    print("=" * 60)
    print(f"  Piste   : {track_info.title or '?'}")
    print(f"  Artiste : {track_info.artist or '?'}")
    print(f"  Album   : {track_info.album or '?'}")
    if track_info.isrc:
        print(f"  ISRC    : {track_info.isrc}")
    print(f"  Sortie  : {output_dir}")
    print("=" * 60)

    os.makedirs(output_dir, exist_ok=True)

    # ── spotDL (primaire) ─────────────────────────────────────
    if 'spotdl' in sources and not force_source:
        print("\n[1] spotDL...", file=sys.stderr)
        spotify_url = None
        if track_info.spotify_id:
            spotify_url = f"https://open.spotify.com/track/{track_info.spotify_id}"

        if spotify_url:
            result = spotdl_download(spotify_url, output_dir)
            if result and isinstance(result, dict) and result.get('file'):
                file_path = result['file']
                track_info.source_name = result.get('source', 'spotdl')
                track_info.quality_label = result.get('quality', 'FLAC')
                tag_flac(file_path, track_info)
                sha256 = hashlib.sha256()
                with open(file_path, 'rb') as f:
                    for chunk in iter(lambda: f.read(8192), b''):
                        sha256.update(chunk)
                print("\n" + "=" * 60)
                print(f"  TÉLÉCHARGÉ — spotDL (Spotify → YouTube Music)")
                print(f"  Fichier : {file_path}")
                print(f"  Source  : {track_info.source_name}")
                print(f"  SHA-256 : {sha256.hexdigest()}")
                print(f"  Taille  : {os.path.getsize(file_path)/1024/1024:.1f} MB")
                print("=" * 60)
                return file_path

    # ── SpotiFLAC CLI ──────────────────────────────────────────
    if 'spotiflac' in sources and not force_source:
        print("\n[2] SpotiFLAC CLI...", file=sys.stderr)
        spotify_url = None
        if track_info.spotify_id:
            spotify_url = f"https://open.spotify.com/track/{track_info.spotify_id}"
        if not spotify_url and track_info.isrc:
            try:
                url = f"https://api.spotify.com/v1/search?q=isrc:{track_info.isrc}&type=track&limit=1"
                req = urllib.request.Request(url)
                req.add_header("User-Agent", "Mozilla/5.0")
                with urllib.request.urlopen(req, timeout=15) as resp:
                    data = json.loads(resp.read().decode())
                items = data.get('tracks', {}).get('items', [])
                if items:
                    spotify_url = f"https://open.spotify.com/track/{items[0]['id']}"
            except Exception:
                pass

        if spotify_url:
            result = spotiflac_cli_download(spotify_url, output_dir)
            if result and isinstance(result, dict) and result.get('file'):
                file_path = result['file']
                track_info.source_name = 'spotiflac'
                track_info.quality_label = 'FLAC'
                tag_flac(file_path, track_info)
                sha256 = hashlib.sha256()
                with open(file_path, 'rb') as f:
                    for chunk in iter(lambda: f.read(8192), b''):
                        sha256.update(chunk)
                print("\n" + "=" * 60)
                print(f"  TÉLÉCHARGÉ — SpotiFLAC CLI")
                print(f"  Fichier : {file_path}")
                print(f"  SHA-256 : {sha256.hexdigest()}")
                print("=" * 60)
                return file_path

    # ── Fallbacks ──────────────────────────────────────────────
    fallbacks = [
        ('ytdlp', ytdlp_download),
        ('deezer', deezer_download),
    ]

    candidates = [(n, fn) for n, fn in fallbacks if n in sources]
    if force_source:
        candidates = [(n, fn) for n, fn in candidates if n == force_source]

    for i, (name, fn) in enumerate(candidates, 3):
        print(f"\n[{i}] {name}...", flush=True, file=sys.stderr)
        try:
            result = fn(track_info, output_dir)
            if result and os.path.exists(result) and os.path.getsize(result) > 5000:
                tag_flac(result, track_info)
                sha256 = hashlib.sha256()
                with open(result, 'rb') as f:
                    for chunk in iter(lambda: f.read(8192), b''):
                        sha256.update(chunk)
                print("\n" + "=" * 60)
                print(f"  TÉLÉCHARGÉ — {name.upper()}")
                print(f"  Fichier : {result}")
                print(f"  Source  : {track_info.source_name}")
                print(f"  Qualité : {track_info.quality_label}")
                print(f"  SHA-256 : {sha256.hexdigest()}")
                print("=" * 60)
                return result
        except Exception as e:
            print(f"    [!] {name}: {e}", file=sys.stderr)

    print("\n[-] TOUTES LES SOURCES ONT ÉCHOUÉ", file=sys.stderr)
    return None


# ============================================================
#  CLI
# ============================================================

def main():
    parser = argparse.ArgumentParser(description='HomeSpotify FLAC Pipeline v3')
    parser.add_argument('input', nargs='?', default=None, help='URL Spotify ou ID Spotify')
    parser.add_argument('--isrc', help='ISRC direct')
    parser.add_argument('--search', nargs=2, metavar=('ARTIST', 'TITLE'), help='Recherche')
    parser.add_argument('--output', '-o', default='storage/imports', help='Sortie')
    parser.add_argument('--source', '-s', help='Source forcée (spotdl,spotiflac,ytdlp,deezer)')
    parser.add_argument('--sources', help='Liste de sources')
    parser.add_argument('--token', '-t', help='Token Spotify')

    args = parser.parse_args()

    track_info = None
    if args.input:
        track_info = spotify_resolve(args.input, args.token)
    elif args.isrc:
        track_info = TrackInfo(isrc=args.isrc.upper())
    elif args.search:
        track_info = TrackInfo(artist=args.search[0], title=args.search[1])
    else:
        parser.print_help()
        sys.exit(1)

    if not track_info:
        print("[-] Impossible de résoudre la piste", file=sys.stderr)
        sys.exit(1)

    sources = None
    if args.sources:
        sources = [s.strip() for s in args.sources.split(',')]

    result = download_flac(track_info, args.output, sources, args.source)
    if not result:
        sys.exit(1)


if __name__ == '__main__':
    main()