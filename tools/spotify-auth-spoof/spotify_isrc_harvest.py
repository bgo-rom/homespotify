#!/usr/bin/env python3
"""
VECTEUR 2 — ISRC HARVESTING : Spotify Shadow API Metadata Exfiltration (v2)
Conversion Base62→GID + extraction ISRC depuis spclient.wg.spotify.com
"""

import json
import sys
import urllib.request
import urllib.error

SPCLIENT_ENDPOINT = "https://spclient.wg.spotify.com/metadata/4/track/{gid}?market=from_token"
BASE62_ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"


def spotify_id_to_gid(entity_id: str) -> str:
    """Convertit un ID Spotify (Base62) en GID Hexadécimal (32 caractères)."""
    value = 0
    for char in entity_id:
        idx = BASE62_ALPHABET.index(char)
        value = value * 62 + idx
    return format(value, 'x').zfill(32)


def extract_isrc(response: dict) -> tuple[str | None, list[str]]:
    """
    Parcourt recursivement le JSON pour trouver l'ISRC.
    Retourne (isrc, chemins_trouvés) pour le debug.
    """
    paths_found = []

    def walk(obj, path=""):
        if isinstance(obj, dict):
            # Check direct keys qui pourraient contenir l'ISRC
            for key in ["isrc", "ISRC", "external_id", "externalId"]:
                if key in obj:
                    val = obj[key]
                    paths_found.append(f"{path}.{key} = {json.dumps(val)[:100]}")
                    if isinstance(val, str) and val.upper().startswith(("US", "GB", "FR", "DE", "JP", "GB", "AU")):
                        return val.upper()
                    if isinstance(val, list):
                        for item in val:
                            if isinstance(item, dict):
                                if item.get("type") == "isrc":
                                    v = item.get("id") or item.get("value") or item.get("external_id")
                                    if v:
                                        return str(v).strip().upper()
                            elif isinstance(item, str) and len(item) == 12:
                                return item.strip().upper()
            for k, v in obj.items():
                result = walk(v, f"{path}.{k}")
                if result:
                    return result
        elif isinstance(obj, list):
            for i, item in enumerate(obj):
                result = walk(item, f"{path}[{i}]")
                if result:
                    return result
        return None

    isrc = walk(response)
    return isrc, paths_found


def harvest_isrc(spotify_id: str, bearer_token: str, retries: int = 3) -> dict:
    """Frappe l'API spclient pour extraire les métadonnées d'une piste."""
    gid = spotify_id_to_gid(spotify_id)
    url = SPCLIENT_ENDPOINT.format(gid=gid)

    headers = {
        "Authorization": f"Bearer {bearer_token}",
        "Accept": "application/json",
        "User-Agent": "spotify/1.2.14 (web-player)",
    }

    last_error = None
    for attempt in range(1, retries + 1):
        req = urllib.request.Request(url)
        for k, v in headers.items():
            req.add_header(k, v)

        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                isrc, paths = extract_isrc(data)

                result = {
                    "success": True,
                    "spotify_id": spotify_id,
                    "gid": gid,
                    "isrc": isrc,
                    "track_name": data.get("name"),
                    "artist_name": (data.get("primary_artist") or {}).get("name"),
                    "album_name": (data.get("album_group") or {}).get("name"),
                    "debug_paths": paths[:10],
                }

                # Sauvegarde le JSON brut pour debug
                with open("tools/spotify-auth-spoof/spclient_raw.json", "w", encoding="utf-8") as f:
                    json.dump(data, f, indent=2, ensure_ascii=False)

                return result

        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8", errors="replace")[:300]
            last_error = f"HTTP {e.code}: {err_body}"
            if e.code in (401, 404):
                break

    return {"success": False, "spotify_id": spotify_id, "gid": gid, "error": last_error}


def main() -> None:
    if len(sys.argv) >= 3:
        spotify_id = sys.argv[1]
        bearer_token = sys.argv[2]
    elif len(sys.argv) == 2:
        spotify_id = sys.argv[1]
        bearer_token = ""
        import time
        time.sleep(0.5)
        for line in sys.stdin:
            if line.startswith("SPOTIFY_TOKEN="):
                bearer_token = line.split("=", 1)[1].strip()
                break
    else:
        print("Usage: python spotify_isrc_harvest.py <SPOTIFY_TRACK_ID> <BEARER_TOKEN>", file=sys.stderr)
        sys.exit(1)

    if not bearer_token:
        print("[!] Bearer Token vide.", file=sys.stderr)
        sys.exit(1)

    print("=" * 60)
    print("  SPOTIFY ISRC HARVESTING — VECTEUR 2 (v2)")
    print("=" * 60)
    print(f"  Spotify ID    : {spotify_id}")
    print("=" * 60)

    result = harvest_isrc(spotify_id, bearer_token)

    if result["success"]:
        print(f"\n[+] Piste         : {result.get('track_name', 'N/A')}")
        print(f"[+] Artiste       : {result.get('artist_name', 'N/A')}")
        print(f"[+] Album         : {result.get('album_name', 'N/A')}")
        print(f"[+] GID (Hex)     : {result['gid']}")
        if result.get("isrc"):
            print(f"[+] ISRC          : {result['isrc']}")
        else:
            print("[?] ISRC          : NON TROUVÉ")
            print("    Chemins explorés dans le JSON :", file=sys.stderr)
            for p in result.get("debug_paths", []):
                print(f"      {p}", file=sys.stderr)
            print("    JSON brut sauvegardé dans spclient_raw.json", file=sys.stderr)

        print("-" * 60)
        print(f"\n[+] ISRC extrait : {result.get('isrc', 'N/A')}")
        print("=" * 60)
        print(f"\nISRC={result.get('isrc', '')}", flush=True)
    else:
        print(f"\n[-] ECHEC : {result.get('error', 'inconnu')}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()