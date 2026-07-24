#!/usr/bin/env python3
"""
VECTEUR 1 — AUTH SPOOFING : Spotify Web Player Identity Hijack (v10)

Correction critique : le TOTP genere des codes 10 chiffres au lieu de 6.
Le GenerateCode de otpauth utilise modulo 10^digits pour limiter a 6 chiffres.
"""

import hashlib
import hmac
import struct
import time
import json
import sys

SPOTIFY_TOTP_SECRET = (
    "GM3TMMJTGYZTQNZVGM4DINJZHA4TGOBY"
    "GMZTCMRTGEYDSMJRHE4TEOBUG4YTCMRU"
    "GQ4DQOJUGQYTAMRRGA2TCMJSHE3TCMBY"
)
SPOTIFY_TOTP_VERSION = 61


def decode_base32(secret: str) -> bytes:
    """Decodage Base32 conforme a RFC 4648."""
    b32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    secret = secret.upper().replace(" ", "").rstrip("=")
    bits = ""
    for c in secret:
        if c in b32:
            bits += format(b32.index(c), "05b")
    out = []
    for i in range(0, len(bits) - 7, 8):
        out.append(int(bits[i:i+8], 2))
    return bytes(out)


def generate_totp(secret: str, timestamp: int, digits: int = 6) -> str:
    """TOTP conforme a RFC 6238 avec modulo pour limiter les chiffres."""
    key = decode_base32(secret)
    msg = struct.pack(">Q", timestamp // 30)
    h = hmac.new(key, msg, hashlib.sha1).digest()
    o = h[-1] & 0x0F
    code = struct.unpack(">I", h[o:o+4])[0] & 0x7FFFFFFF
    # MODULO pour 6 chiffres (comme otpauth.GenerateCode)
    code = code % (10 ** digits)
    return str(code).zfill(digits)


def run_with_selenium() -> dict | None:
    from selenium import webdriver
    from selenium.webdriver.chrome.options import Options
    from selenium.webdriver.support.ui import WebDriverWait
    from selenium.common.exceptions import TimeoutException, WebDriverException

    chrome_opts = Options()
    chrome_opts.add_argument("--headless=new")
    chrome_opts.add_argument("--no-sandbox")
    chrome_opts.add_argument("--disable-dev-shm-usage")
    chrome_opts.add_argument("--disable-gpu")
    chrome_opts.add_argument("--window-size=1920,1080")
    chrome_opts.add_argument("--lang=en-US")

    try:
        driver = webdriver.Chrome(options=chrome_opts)
    except WebDriverException as e:
        print(f"    [!] Chrome failed: {e}", file=sys.stderr)
        return None

    try:
        print("    [1/4] Opening Spotify Web Player...", file=sys.stderr)
        driver.get("https://open.spotify.com/")

        # Attendre React + sp_dc
        print("    [2/4] Waiting for sp_dc (max 45s)...", file=sys.stderr)
        try:
            WebDriverWait(driver, 45).until(
                lambda d: "sp_dc" in {c["name"] for c in d.get_cookies()}
            )
            print("    [+] sp_dc obtenu !", file=sys.stderr)
        except TimeoutException:
            cookies = driver.get_cookies()
            names = {c["name"] for c in cookies}
            print(f"    [!] sp_dc timeout. Cookies: {names}", file=sys.stderr)

        # Token via TOTP
        print("    [3/4] Calling /api/token with TOTP...", file=sys.stderr)
        now = int(time.time())

        for window in range(6):
            totp_time = now + 30 * (window - 1)  # -30, 0, +30, +60, +90, +120
            totp_code = generate_totp(SPOTIFY_TOTP_SECRET, totp_time)
            print(f"    [>] t={totp_time} code={totp_code}", file=sys.stderr)

            try:
                result = WebDriverWait(driver, 10).until(
                    lambda d: d.execute_async_script(f"""
                        const callback = arguments[arguments.length - 1];
                        const url = '/api/token?reason=init&productType=web-player&totp={totp_code}&totpServer={totp_code}&totpVer={SPOTIFY_TOTP_VERSION}';
                        fetch(url, {{
                            method: 'GET',
                            credentials: 'include',
                            headers: {{ 'Accept': 'application/json' }}
                        }})
                        .then(async r => {{
                            const text = await r.text();
                            try {{ return JSON.parse(text); }}
                            catch {{ return {{ error: true, raw: text.substring(0, 200), status: r.status }}; }}
                        }})
                        .then(data => callback(data))
                        .catch(err => callback({{ error: true, message: err.message }}));
                    """)
                )
                at = result.get("accessToken") or result.get("access_token")
                if at:
                    return result
                print(f"    [!] {json.dumps(result)[:150]}", file=sys.stderr)
            except TimeoutException:
                print(f"    [!] timeout", file=sys.stderr)

        # Fallback : token stocke par le web-player
        print("    [4/4] Extracting stored token...", file=sys.stderr)
        try:
            stored = driver.execute_script("""
                const items = {
                    ls_token: localStorage.getItem('token'),
                    ls_auth: localStorage.getItem('auth_state'),
                    ss_token: sessionStorage.getItem('token'),
                };
                for (const [k, v] of Object.entries(items)) {
                    if (v) {
                        try { return JSON.parse(v); } catch {}
                    }
                }
                return null;
            """)
            if stored and ("accessToken" in stored or "access_token" in stored):
                return stored
        except Exception as e:
            print(f"    [!] storage read error: {e}", file=sys.stderr)

        return None

    finally:
        driver.quit()


def main() -> None:
    now = int(time.time())
    totp = generate_totp(SPOTIFY_TOTP_SECRET, now)

    print("=" * 60)
    print("  SPOTIFY AUTH SPOOFING — VECTEUR 1 (v10)")
    print("=" * 60)
    print(f"  TOTP Secret     : {SPOTIFY_TOTP_SECRET[:20]}...")
    print(f"  TOTP Version    : {SPOTIFY_TOTP_VERSION}")
    print(f"  TOTP Code (6ch) : {totp}")
    print("=" * 60)

    result = run_with_selenium()

    if result is None:
        print("\n[-] ECHEC.", file=sys.stderr)
        sys.exit(1)

    access_token = result.get("accessToken") or result.get("access_token") or ""
    if not access_token:
        print(f"\n[-] Pas de token: {json.dumps(result, default=str)[:400]}", file=sys.stderr)
        sys.exit(1)

    token_type = result.get("token_type", "Bearer")
    expires_in = result.get("expires_in", "?")
    refresh = result.get("refreshToken") or result.get("refresh_token") or ""
    scope = result.get("scope", "")

    print(f"\n[+] STATUT        : SUCCESS")
    print(f"[+] TOKEN TYPE    : {token_type}")
    print(f"[+] EXPIRES IN    : {expires_in}s")
    if scope:
        print(f"[+] SCOPE         : {scope}")
    print("-" * 60)
    print(f"[+] ACCESS TOKEN  : {access_token}")
    print("-" * 60)
    if refresh:
        print(f"[+] REFRESH TOKEN : {refresh[:50]}...")
    print("=" * 60)
    print(f"\nSPOTIFY_TOKEN={access_token}", flush=True)


if __name__ == "__main__":
    main()