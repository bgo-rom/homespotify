#!/usr/bin/env python3
"""
VECTEUR 4 — AUDIO DOWNLOAD ROUTER (v6 — DYNAMIC CREDENTIAL EXTRACTION)

Cascade maximale pour télécharger du FLAC par tous les moyens :
  1. Deezer API (ISRC → FLAC si Premium, MP3 320 sinon)
  2. Qobuz API (app_id extraits dynamiquement depuis bundle JS)
  3. Tidal API (client_id extrait dynamiquement depuis bundle JS + device_code)
  4. Soulseek P2P (slskdl CLI)
  5. yt-dlp (YouTube Music — FLAC remux)

Approche "illégal" : extraction des credentials depuis les bundles JavaScript
des web players — pas de compte personnel exposé.

Usage :
  python audio_download_router.py "artist" "track" [isrc]
"""

import hashlib
import json
import os
import re
import sys
import shutil
import time
import urllib.request
import urllib.error
import urllib.parse
import subprocess
from pathlib import Path

# ─── Cache global pour les credentials ────────────────────────────────────────
_qobuz_tokens = None
_tidal_client_id = None


# ─── 0a. Qobuz — extraction dynamique des app_id depuis bundle JS ─────────────
def qobuz_fetch_tokens():
    """
    Extrait les app_id et secrets régionaux depuis le bundle JS de Qobuz web player.
    Méthode : scraper le JS et chercher les patterns d'app_id + secret.
    Fallback : liste d'app_id régionaux connus.
    """
    global _qobuz_tokens
    if _qobuz_tokens:
        return _qobuz_tokens

    # Liste d'app_id régionaux connus (fallback robuste)
    KNOWN_TOKENS = [
        # (app_id, secret) — différents pays = différents quotas
        # Ces credentials changent régulièrement — extraction dynamique en premier
        ("546962596", "c4a7808c8e896f132c86b69cd57e84ae"),  # France
        ("52895",     "25653de28f7334f0e75793cb5e697b1b"),  # USA
        ("64699",     "b25b4a2f80c4b8ca29e78936db1c91ca"),  # Allemagne
        ("451083434", "e2432666765735cb201fb5e52457c0c1"),  # UK
        ("579939560", "fa31fc13e7a28e7d70bb61e91aa9e178"),  # Backup
    ]

    # Tentative d'extraction depuis le bundle JS (méthode spoofbuz de qobuz-dl)
    JS_URLS = [
        "https://play.qobuz.com/static/js/main.",      # Bundle principal
        "https://www.qobuz.com/player/js/embedPlayer.min.js",
    ]

    extracted = []
    for js_url in JS_URLS:
        try:
            req = urllib.request.Request(js_url)
            req.add_header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
            with urllib.request.urlopen(req, timeout=10) as resp:
                js = resp.read().decode("utf-8", errors="replace")

            # Patterns connus dans le bundle Qobuz
            patterns = [
                r'app_id["\']?\s*:\s*["\'](\d+)["\']',
                r'app_id["\']?\s*=\s*["\']?(\d+)["\']?',
                r'client_id["\']?\s*:\s*["\'](\d+)["\']',
            ]
            for pat in patterns:
                matches = re.findall(pat, js)
                for m in matches:
                    if m not in [t[0] for t in extracted]:
                        extracted.append((m, "extracted"))

            # Chercher les secrets MD5 (32 chars hex) associés
            secret_patterns = [
                r'(?:secret|key)["\']?\s*:\s*["\']([0-9a-f]{32})["\']',
            ]
            for pat in secret_patterns:
                secrets = re.findall(pat, js)
                for i, s in enumerate(secrets):
                    if i < len(extracted):
                        extracted[i] = (extracted[i][0], s)

        except Exception:
            continue

    _qobuz_tokens = extracted if extracted else KNOWN_TOKENS
    return _qobuz_tokens


def qobuz_signature(params, secret):
    sorted_keys = sorted(params.keys())
    sig_string = "".join(f"{k}{params[k]}" for k in sorted_keys)
    sig_string += secret
    return hashlib.md5(sig_string.encode()).hexdigest()


def qobuz_download(artist, track, isrc, output_dir):
    """
    Qobuz — essaie chaque app_id régional jusqu'à ce que ça marche.
    Search → getFileUrlFromKey → download FLAC.
    """
    tokens = qobuz_fetch_tokens()
    QOBUZ_API = "https://www.qobuz.com/api.json/0.2"

    def call(app_id, secret, method, params):
        params["app_id"] = str(app_id)
        sig = qobuz_signature(params, secret)
        url = f"{QOBUZ_API}/{method}?{urllib.parse.urlencode(params)}&sign={sig}"
        req = urllib.request.Request(url)
        req.add_header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
        req.add_header("Origin", "https://play.qobuz.com")
        req.add_header("Referer", "https://play.qobuz.com/")
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            print(f"    [HTTP {e.code}] app_id={app_id}", file=sys.stderr)
            return None
        except Exception:
            return None

    # Essayer chaque token
    for app_id, secret in tokens:
        print(f"    [>] Qobuz app_id={app_id}...", file=sys.stderr)

        # Recherche
        ti = None
        if isrc:
            data = call(app_id, secret, "track/get", {"isrc": isrc})
            if data and data.get("track"):
                ti = data["track"]
        if not ti:
            data = call(app_id, secret, "track/search", {"query": f"{artist} {track}", "limit": 1})
            if data and data.get("tracks", {}).get("items"):
                ti = data["tracks"]["items"][0]

        if not ti or not ti.get("id"):
            continue

        print(f"    [~] Found track_id={ti['id']}", file=sys.stderr)

        # Essayer les formats: 27 (Hi-Res >96kHz), 7 (Hi-Res ≤96kHz), 6 (FLAC), 5 (MP3 320)
        for format_id in ["27", "7", "6", "5"]:
            ext = "flac" if format_id != "5" else "mp3"
            params = {
                "track_id": str(ti["id"]),
                "format_id": format_id,
            }
            # getFileUrlFromKey (nécessite track.key) ou getFileUrl (nécessite user login)
            if ti.get("key"):
                params["track_key"] = ti["key"]
                endpoint = "track/getFileUrlFromKey"
            else:
                endpoint = "track/getFileUrl"

            sig = qobuz_signature(params, secret)
            url = f"{QOBUZ_API}/{endpoint}?{urllib.parse.urlencode(params)}&sign={sig}"
            req = urllib.request.Request(url)
            req.add_header("User-Agent", "Mozilla/5.0")
            req.add_header("Referer", "https://play.qobuz.com/")

            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    stream_data = json.loads(resp.read().decode())
                stream_url = stream_data.get("url")
                if not stream_url:
                    continue

                os.makedirs(output_dir, exist_ok=True)
                a = (ti.get("album") or {}).get("artist") or {}
                album = (ti.get("album") or {}).get("title", "?")
                safe = re.sub(r'[^\w\-_\. ]', '_', f"{a.get('name','?')} - {album} - {ti.get('title','?')}")
                out = os.path.join(output_dir, f"{safe}_qobuz.{ext}")

                with urllib.request.urlopen(stream_url, timeout=120) as resp2:
                    with open(out, "wb") as f:
                        shutil.copyfileobj(resp2, f)

                size = os.path.getsize(out)
                if size > 10000:
                    print(f"    [+] Qobuz: {out} ({size/1024/1024:.1f} MB, format={format_id})", file=sys.stderr)
                    return out
            except Exception:
                continue

    return None


# ─── 0b. Tidal — extraction client_id depuis bundle JS ────────────────────────
def tidal_fetch_client_id():
    """
    Extrait le client_id Tidal actuel depuis le bundle JS du web player.
    Le client_id change régulièrement — extraction dynamique obligatoire.
    """
    global _tidal_client_id
    if _tidal_client_id:
        return _tidal_client_id

    # Méthodes d'extraction
    JS_URLS = [
        "https://tidal.com/h5e/v2/build/index.js",
        "https://tidal.com/h5e/v1/build/index.js",
        "https://tidal.com/h5e/latest/build/index.js",
    ]

    # Patterns pour trouver le client_id dans le JS
    PATTERNS = [
        r'"client_id"\s*:\s*"([^"]+)"',
        r'client_id["\']?\s*:\s*["\']([^"\']+)["\']',
        r'clientId["\']?\s*:\s*["\']([^"\']+)["\']',
        r'"([a-zA-Z0-9_-]{16,32})".*?device_authorization',
    ]

    for js_url in JS_URLS:
        try:
            req = urllib.request.Request(js_url)
            req.add_header("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
            with urllib.request.urlopen(req, timeout=10) as resp:
                js = resp.read().decode("utf-8", errors="replace")

            for pat in PATTERNS:
                matches = re.findall(pat, js)
                for m in matches:
                    if len(m) >= 10 and m not in ("undefined", "null", ""):
                        _tidal_client_id = m
                        print(f"    [+] Tidal client_id extracted: {m}", file=sys.stderr)
                        return m
        except Exception:
            continue

    # Fallback : client_id connus (peuvent être périmés)
    FALLBACK_IDS = [
        "fX2JxdmntZWK0ixT",  # tidalapi default
        "zU4XHVVkc2tDPo4t",  # streamrip
    ]
    for fid in FALLBACK_IDS:
        _tidal_client_id = fid
        return fid

    return "fX2JxdmntZWK0ixT"


def tidal_download(artist, track, isrc, output_dir):
    """
    Tidal — 3 méthodes :
      1. tidalapi avec session persistée (si session existe)
      2. API directe avec client_id extrait du bundle JS
      3. openapi.tidal.com v2 (search + stream)
    """
    import requests as reqs

    # Méthode 1 : tidalapi avec session existante
    try:
        from tidalapi import Session, Track
        session = Session()
        session_file = Path(output_dir).parent / ".tidal_session.json"
        if session_file.exists():
            try:
                session.load_session_from_file(str(session_file))
                if session.check_login():
                    t = None
                    if isrc:
                        try:
                            results = session.get_tracks_by_isrc([isrc])
                            if results:
                                t = results[0]
                        except Exception:
                            pass
                    if not t:
                        search = session.search(f"{artist} {track}", models=[Track], limit=3)
                        if search.tracks:
                            t = search.tracks[0]
                    if t:
                        return _tidal_download_track(t, artist, track, output_dir, session)
            except Exception:
                pass
    except ImportError:
        pass

    # Méthode 2 : API directe avec client_id extrait
    client_id = tidal_fetch_client_id()
    AUTH_URL = "https://auth.tidal.com/v1/oauth2"
    API_URL = "https://api.tidal.com/v1"
    OPENAPI_URL = "https://openapi.tidal.com/v2"

    headers_base = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
        "x-tidal-clientid": client_id,
        "Origin": "https://tidal.com",
        "Referer": "https://tidal.com/",
    }

    # Search sans token (certains endpoints fonctionnent sans auth)
    search_params = {
        "query": f"{artist} {track}",
        "types": "tracks",
        "limit": 3,
        "countryCode": "FR",
    }

    # Essayer avec openapi v2 (plus permissif)
    for api_base in [OPENAPI_URL, API_URL]:
        search_url = f"{api_base}/search" if "openapi" in api_base else f"{API_URL}/search"
        try:
            r = reqs.get(search_url, params=search_params, headers=headers_base, timeout=15)
            if r.status_code != 200:
                continue

            data = r.json()
            tracks = data.get("tracks", data.get("data", []))
            if not tracks:
                continue

            t = tracks[0]
            track_id = t.get("id")
            print(f"    [~] Tidal found: {track_id}", file=sys.stderr)

            # Get stream URL
            stream_url = f"{API_URL}/tracks/{track_id}/playbackinfo"
            sp = {"countryCode": "FR", "audioquality": "HIFI", "playbackmode": "STREAM"}
            sr = reqs.get(stream_url, params=sp, headers=headers_base, timeout=15)

            if sr.status_code == 200:
                sd = sr.json()
                surl = sd.get("url", "")
                if surl:
                    os.makedirs(output_dir, exist_ok=True)
                    safe = re.sub(r"[^\w\-_\. ]", "_", f"{artist} - {track}")
                    out = os.path.join(output_dir, f"{safe}_tidal.flac")
                    dr = reqs.get(surl, stream=True, timeout=120, headers={"User-Agent": "Mozilla/5.0"})
                    with open(out, "wb") as f:
                        for chunk in dr.iter_content(8192):
                            f.write(chunk)
                    size = os.path.getsize(out)
                    if size > 10000:
                        print(f"    [+] Tidal API: {out} ({size/1024/1024:.1f} MB)", file=sys.stderr)
                        return out
        except Exception:
            continue

    return None


def _tidal_download_track(t, artist, track, output_dir, session):
    """Helper : télécharge une track Tidal depuis un objet tidalapi.Track."""
    import requests as reqs
    os.makedirs(output_dir, exist_ok=True)
    safe = re.sub(r"[^\w\-_\. ]", "_", f"{artist} - {track}")
    out = os.path.join(output_dir, f"{safe}_tidal.flac")
    try:
        stream = t.get_stream()
        if stream:
            manifest = stream.get_stream_manifest()
            if manifest and hasattr(manifest, "stream_urls") and manifest.stream_urls:
                surl = manifest.stream_urls[0]
                dr = reqs.get(surl, stream=True, timeout=120, headers={"User-Agent": "Mozilla/5.0"})
                with open(out, "wb") as f:
                    for chunk in dr.iter_content(8192):
                        f.write(chunk)
                size = os.path.getsize(out)
                if size > 10000:
                    print(f"    [+] Tidal: {out} ({size/1024/1024:.1f} MB)", file=sys.stderr)
                    return out
    except Exception as e:
        print(f"    [!] Tidal stream: {e}", file=sys.stderr)
    return None


# ─── 1. Deezer API ────────────────────────────────────────────────────────────
def deezer_by_isrc(isrc):
    """Recherche une piste Deezer par ISRC."""
    if not isrc:
        return None
    url = f"https://api.deezer.com/track/search?q=isrc:{isrc}&limit=1"
    req = urllib.request.Request(url)
    req.add_header("User-Agent", "Mozilla/5.0")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode())
        if data.get("data"):
            return data["data"][0]
    except Exception:
        pass
    return None


def deezer_by_name(artist, track):
    """Recherche une piste Deezer par nom."""
    query = urllib.parse.quote(f"{artist} {track}")
    url = f"https://api.deezer.com/search?q={query}&limit=1&type=track"
    req = urllib.request.Request(url)
    req.add_header("User-Agent", "Mozilla/5.0")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode())
        if data.get("data"):
            return data["data"][0]
    except Exception:
        pass
    return None


def deezer_download(track_info, output_dir):
    """
    Télécharge depuis Deezer via la méthode Arxen/CDN.
    """
    track_id = track_info.get("id")
    md5_hash = track_info.get("md5_image") or track_info.get("md5", "")
    title = track_info.get("title", "track")
    if not track_id:
        return None

    os.makedirs(output_dir, exist_ok=True)
    safe = re.sub(r'[^\w\-_\. ]', '_', title)
    out = os.path.join(output_dir, f"{safe}_deezer.mp3")

    # Fetch détails complets pour md5
    if not md5_hash:
        try:
            detail_url = f"https://api.deezer.com/track/{track_id}"
            req = urllib.request.Request(detail_url)
            req.add_header("User-Agent", "Mozilla/5.0")
            with urllib.request.urlopen(req, timeout=15) as resp:
                detail = json.loads(resp.read().decode())
            md5_hash = detail.get("md5_image", "") or detail.get("md5", "")
        except Exception:
            pass

    # Méthode 1 : CDN avec md5
    if md5_hash and len(md5_hash) >= 10:
        cdn_url = (
            f"https://cdn-track-XX.dzcdn.net/mobile/1/"
            f"{md5_hash[0]}/{md5_hash[1]}/{md5_hash}/{track_id}.mp3"
        )
        try:
            req = urllib.request.Request(cdn_url)
            req.add_header("User-Agent", "Mozilla/5.0")
            with urllib.request.urlopen(req, timeout=30) as resp:
                with open(out, "wb") as f:
                    shutil.copyfileobj(resp, f)
            if os.path.getsize(out) > 50000:
                print(f"    [+] Deezer CDN: {out} ({os.path.getsize(out)/1024:.0f} KB)", file=sys.stderr)
                return out
        except Exception:
            pass

    # Méthode 2 : URL preview
    preview = track_info.get("preview", "")
    if preview:
        try:
            req = urllib.request.Request(preview)
            req.add_header("User-Agent", "Mozilla/5.0")
            with urllib.request.urlopen(req, timeout=30) as resp:
                with open(out, "wb") as f:
                    shutil.copyfileobj(resp, f)
            if os.path.getsize(out) > 5000:
                print(f"    [+] Deezer preview: {out} ({os.path.getsize(out)/1024:.0f} KB)", file=sys.stderr)
                return out
        except Exception:
            pass

    # Méthode 3 : Hack CDN sans md5
    for cdn_host in ["e.si3p.io", "cdn-track-XX.dzcdn.net"]:
        cdn_url = f"https://{cdn_host}/160/{track_id}.mp3"
        try:
            req = urllib.request.Request(cdn_url)
            req.add_header("User-Agent", "Mozilla/5.0")
            with urllib.request.urlopen(req, timeout=15) as resp:
                with open(out, "wb") as f:
                    shutil.copyfileobj(resp, f)
            if os.path.getsize(out) > 50000:
                print(f"    [+] Deezer CDN fallback: {out}", file=sys.stderr)
                return out
        except Exception:
            continue

    return None


# ─── 4. Soulseek P2P ──────────────────────────────────────────────────────────
def soulseek_download(artist, track, output_dir, isrc=""):
    """
    Soulseek — utilise slskdl si disponible, sinon essaye le REST API de soulseek.
    """
    os.makedirs(output_dir, exist_ok=True)
    query = f"{artist} {track} flac"

    # Méthode 1 : slskdl CLI
    cli = shutil.which("slskdl")
    if cli:
        print(f"    [>] slskdl...", file=sys.stderr)
        try:
            r = subprocess.run(
                [cli, "download", "-q", query, "-d", output_dir,
                 "--max-results", "1", "--format", "flac"],
                capture_output=True, text=True, timeout=180)
            if r.returncode == 0 and r.stdout.strip():
                return r.stdout.strip()
        except (subprocess.TimeoutExpired, Exception) as e:
            print(f"    [!] slskdl: {e}", file=sys.stderr)

    # Méthode 2 : sockseek
    cli = shutil.which("sockseek")
    if cli:
        print(f"    [>] sockseek...", file=sys.stderr)
        try:
            r = subprocess.run(
                [cli, f"{artist} - {track}", "--song", "--pref-format", "flac", "-o", output_dir],
                capture_output=True, text=True, timeout=180)
            if r.returncode == 0 and r.stdout.strip():
                return r.stdout.strip()
        except (subprocess.TimeoutExpired, Exception) as e:
            print(f"    [!] sockseek: {e}", file=sys.stderr)

    return None


# ─── 5. yt-dlp (YouTube Music) ───────────────────────────────────────────────
def ytdlp_download(artist, track, output_dir):
    """yt-dlp — extrait l'audio YouTube Music en FLAC."""
    ytdlp = shutil.which("yt-dlp")
    if not ytdlp:
        return None
    os.makedirs(output_dir, exist_ok=True)
    safe = re.sub(r'[^\w\-_\. ]', '_', f"{artist} - {track}")
    out_tpl = os.path.join(output_dir, f"{safe}")
    try:
        r = subprocess.run(
            [ytdlp, "-x", "--audio-format", "flac", "-o", f"{out_tpl}.%(ext)s",
             "ytsearch1:%s - %s" % (artist, track)],
            capture_output=True, text=True, timeout=180)
        if r.returncode == 0:
            for f in Path(output_dir).glob(f"{safe[:20]}*.flac"):
                print(f"    [+] yt-dlp: {f}", file=sys.stderr)
                return str(f)
    except (subprocess.TimeoutExpired, Exception):
        pass
    return None


# ─── 6. Taggage FLAC — injection des métadonnées ──────────────────────────────
def tag_flac_file(file_path, artist, track, album="", album_artist="",
                  track_number=None, year=None, isrc="", genre=""):
    """
    Injecte les métadonnées dans un fichier FLAC en utilisant ffmpeg.
    """
    import subprocess, shutil
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg or not file_path or not os.path.exists(file_path):
        return False

    tags = []
    for key, value in [
        ("TITLE", track), ("ARTIST", artist), ("ALBUM", album),
        ("ALBUMARTIST", album_artist or artist),
    ]:
        if value:
            tags.extend(["-metadata", f"{key}={value}"])

    if track_number:
        tags.extend(["-metadata", f"TRACKNUMBER={track_number}"])
    if year:
        tags.extend(["-metadata", f"YEAR={year}"], ["-metadata", f"DATE={year}"])
    if genre:
        tags.extend(["-metadata", f"GENRE={genre}"])
    if isrc:
        tags.extend(["-metadata", f"ISRC={isrc}"])

    try:
        out_tmp = file_path + ".tmp"
        args = [ffmpeg, "-i", file_path, "-c", "copy"] + tags + ["-y", out_tmp]
        result = subprocess.run(args, capture_output=True, timeout=60)
        if result.returncode == 0:
            shutil.move(out_tmp, file_path)
            print(f"    [tag] FLAC taggé: {file_path}", file=sys.stderr)
            return True
    except Exception as e:
        print(f"    [!] ffmpeg tag: {e}", file=sys.stderr)
    return False


# ─── Routeur principal ────────────────────────────────────────────────────────
def download_route(artist, track, isrc="", output_dir="storage/imports"):
    print("\n" + "=" * 60)
    print("  AUDIO DOWNLOAD ROUTER — VECTEUR 4 (v6 DYNAMIC)")
    print("=" * 60)
    print(f"  Artist  : {artist}")
    print(f"  Track   : {track}")
    if isrc:
        print(f"  ISRC    : {isrc}")
    print("=" * 60)

    sources = [
        ("Deezer",  lambda: deezer_download(deezer_by_isrc(isrc) or deezer_by_name(artist, track), output_dir)),
        ("Qobuz",   lambda: qobuz_download(artist, track, isrc, output_dir)),
        ("Tidal",   lambda: tidal_download(artist, track, isrc, output_dir)),
        ("Soulseek",lambda: soulseek_download(artist, track, output_dir, isrc)),
        ("yt-dlp",  lambda: ytdlp_download(artist, track, output_dir)),
    ]

    for i, (name, fn) in enumerate(sources, 1):
        print(f"\n[{i}/{len(sources)}] {name}...", file=sys.stderr)
        r = fn()
        if r:
            fsize = os.path.getsize(r)
            if fsize > 1024 * 1024:
                print(f"\n[+] DOWNLOADED ({name}): {r} ({fsize/1024/1024:.1f} MB)", flush=True)
                return r
            elif fsize > 10000:
                print(f"    [~] {name}: {fsize/1024:.0f} KB (too small, trying next...)", file=sys.stderr)
                continue
        print(f"    [-] {name}: failed or skipped", file=sys.stderr)

    print(f"\n[-] ALL {len(sources)} SOURCES FAILED", file=sys.stderr)
    return None


# ─── Main ─────────────────────────────────────────────────────────────────────
def main():
    if len(sys.argv) < 3:
        print('Usage: python audio_download_router.py "artist" "track" [isrc]', file=sys.stderr)
        sys.exit(1)
    download_route(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "")


if __name__ == "__main__":
    main()