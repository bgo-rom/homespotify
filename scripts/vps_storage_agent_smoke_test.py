#!/usr/bin/env python3
"""Client de test HMAC du HomeSpotify Storage Agent — bibliothèque standard uniquement.

Destiné à être exécuté SUR LE VPS (10.8.0.1) contre l'agent du PC Windows
(10.8.0.2:3100), à travers WireGuard.

Protocole (Phase 2) — chaîne canonique, éléments séparés par « \\n » :

    METHOD \\n PATH_WITH_QUERY \\n TIMESTAMP \\n NONCE \\n CONTENT_SHA256

En-têtes : X-HS-Timestamp, X-HS-Nonce, X-HS-Content-SHA256, X-HS-Signature.

Le secret n'est JAMAIS passé en argument de ligne de commande (il apparaîtrait
dans « ps » et dans l'historique du shell). Il est lu :

    1. depuis la variable d'environnement STORAGE_AGENT_SHARED_SECRET, ou
    2. depuis le fichier désigné par --secret-file (mode 0600 attendu).

Le script n'affiche jamais le secret ni une signature complète : seulement une
empreinte non réversible du secret, pour vérifier que les deux extrémités
utilisent bien la même valeur, et un préfixe court des signatures.

Aucune donnée musicale n'est affichée. Au plus 2 Kio sont téléchargés.

Codes de sortie : 0 = tous les contrôles passent, 1 = au moins un échec,
2 = erreur d'utilisation ou de configuration.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import os
import re
import secrets
import stat
import sys
import time
import urllib.error
import urllib.request

BASE_PATH = "/internal/storage"
EMPTY_BODY_SHA256 = hashlib.sha256(b"").hexdigest()
MAX_DOWNLOAD_BYTES = 2048

HEADER_TIMESTAMP = "X-HS-Timestamp"
HEADER_NONCE = "X-HS-Nonce"
HEADER_CONTENT_SHA256 = "X-HS-Content-SHA256"
HEADER_SIGNATURE = "X-HS-Signature"


# --------------------------------------------------------------------------
# Secret
# --------------------------------------------------------------------------


def load_secret(secret_file: str | None) -> str:
    """Lit le secret depuis l'environnement ou un fichier protégé."""
    from_env = os.environ.get("STORAGE_AGENT_SHARED_SECRET")
    if from_env:
        return from_env.strip()

    if not secret_file:
        fail_usage(
            "aucun secret : définir STORAGE_AGENT_SHARED_SECRET ou passer --secret-file"
        )

    if not os.path.isfile(secret_file):
        fail_usage(f"fichier de secret introuvable : {secret_file}")

    mode = stat.S_IMODE(os.stat(secret_file).st_mode)
    if os.name == "posix" and mode & 0o077:
        fail_usage(
            f"fichier de secret trop permissif (mode {mode:04o}) — attendu 0600"
        )

    with open(secret_file, "r", encoding="utf-8") as handle:
        secret = handle.read().strip()

    if not secret:
        fail_usage("fichier de secret vide")
    return secret


def secret_fingerprint(secret: str) -> str:
    """Empreinte non réversible et salée — permet d'apparier les deux extrémités."""
    digest = hashlib.sha256(("HS-AGENT-SECRET-FPR|" + secret).encode("utf-8"))
    return digest.hexdigest()[:16]


def fail_usage(message: str) -> None:
    print(f"ERREUR : {message}", file=sys.stderr)
    raise SystemExit(2)


# --------------------------------------------------------------------------
# Signature
# --------------------------------------------------------------------------


def canonical_string(
    method: str, path_with_query: str, timestamp: int, nonce: str, content_sha256: str
) -> str:
    return "\n".join(
        [method.upper(), path_with_query, str(timestamp), nonce, content_sha256.lower()]
    )


def sign(secret: str, canonical: str) -> str:
    return hmac.new(
        secret.encode("utf-8"), canonical.encode("utf-8"), hashlib.sha256
    ).hexdigest()


def generate_nonce() -> str:
    """256 bits, base64url — bien au-delà du minimum de 128 bits exigé."""
    return secrets.token_urlsafe(32)


def signed_headers(
    secret: str,
    method: str,
    path_with_query: str,
    *,
    timestamp: int | None = None,
    nonce: str | None = None,
    corrupt_signature: bool = False,
) -> dict[str, str]:
    timestamp = int(time.time()) if timestamp is None else timestamp
    nonce = generate_nonce() if nonce is None else nonce
    signature = sign(
        secret,
        canonical_string(
            method, path_with_query, timestamp, nonce, EMPTY_BODY_SHA256
        ),
    )
    if corrupt_signature:
        # Un caractère modifié : format valide (64 hex), signature fausse.
        flipped = "0" if signature[0] != "0" else "1"
        signature = flipped + signature[1:]
    return {
        HEADER_TIMESTAMP: str(timestamp),
        HEADER_NONCE: nonce,
        HEADER_CONTENT_SHA256: EMPTY_BODY_SHA256,
        HEADER_SIGNATURE: signature,
    }


# --------------------------------------------------------------------------
# Transport
# --------------------------------------------------------------------------


class Response:
    __slots__ = ("status", "headers", "body", "elapsed_ms", "ttfb_ms")

    def __init__(
        self,
        status: int,
        headers: dict[str, str],
        body: bytes,
        elapsed_ms: float,
        ttfb_ms: float,
    ) -> None:
        self.status = status
        self.headers = headers
        self.body = body
        self.elapsed_ms = elapsed_ms
        self.ttfb_ms = ttfb_ms

    def header(self, name: str) -> str | None:
        lowered = name.lower()
        for key, value in self.headers.items():
            if key.lower() == lowered:
                return value
        return None


def request(
    base_url: str,
    method: str,
    path_with_query: str,
    headers: dict[str, str],
    *,
    extra_headers: dict[str, str] | None = None,
    timeout: float = 20.0,
) -> Response:
    url = base_url.rstrip("/") + path_with_query
    all_headers = dict(headers)
    if extra_headers:
        all_headers.update(extra_headers)

    req = urllib.request.Request(url, method=method.upper(), headers=all_headers)
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            ttfb = (time.perf_counter() - started) * 1000.0
            body = resp.read(MAX_DOWNLOAD_BYTES)
            elapsed = (time.perf_counter() - started) * 1000.0
            return Response(resp.status, dict(resp.headers.items()), body, elapsed, ttfb)
    except urllib.error.HTTPError as err:
        ttfb = (time.perf_counter() - started) * 1000.0
        body = err.read(MAX_DOWNLOAD_BYTES)
        elapsed = (time.perf_counter() - started) * 1000.0
        return Response(err.code, dict(err.headers.items()), body, elapsed, ttfb)


# --------------------------------------------------------------------------
# Contrôles
# --------------------------------------------------------------------------


class Report:
    def __init__(self) -> None:
        self.passed = 0
        self.failed = 0

    def check(self, label: str, ok: bool, detail: str = "") -> bool:
        if ok:
            self.passed += 1
            print(f"  OK   {label}" + (f" — {detail}" if detail else ""))
        else:
            self.failed += 1
            print(f"  ECHEC {label}" + (f" — {detail}" if detail else ""))
        return ok


def run(base_url: str, track_id: str, secret: str) -> int:
    report = Report()
    health_path = f"{BASE_PATH}/health"
    track_path = f"{BASE_PATH}/tracks/{track_id}"

    print(f"Cible          : {base_url}")
    print(f"Piste de test  : {track_id}")
    print(f"Empreinte secret : {secret_fingerprint(secret)} (non réversible)")
    print()

    # 1 — /health signé -----------------------------------------------------
    print("1. /health signé")
    resp = request(base_url, "GET", health_path, signed_headers(secret, "GET", health_path))
    report.check("statut 200", resp.status == 200, f"reçu {resp.status}")
    body_text = resp.body.decode("utf-8", "replace")
    report.check(
        "statut applicatif healthy",
        '"status":"healthy"' in body_text.replace(" ", ""),
        _summarise_health(body_text),
    )
    leaks = _detect_leaks(body_text)
    report.check(
        "aucune fuite de chemin ni de secret dans /health",
        not leaks,
        ", ".join(leaks),
    )

    # 2 — HEAD signé --------------------------------------------------------
    print("\n2. HEAD signé sur une piste réelle")
    resp = request(base_url, "HEAD", track_path, signed_headers(secret, "HEAD", track_path))
    report.check("statut 200", resp.status == 200, f"reçu {resp.status}")
    content_length = resp.header("Content-Length")
    full_size = int(content_length) if content_length and content_length.isdigit() else -1
    report.check("Content-Length entier > 0", full_size > 0, f"{full_size} octets")
    report.check("Accept-Ranges: bytes", resp.header("Accept-Ranges") == "bytes")
    report.check("corps vide sur HEAD", len(resp.body) == 0, f"{len(resp.body)} octets")

    # 3 — GET Range 0-1023 --------------------------------------------------
    print("\n3. GET Range bytes=0-1023")
    resp = request(
        base_url,
        "GET",
        track_path,
        signed_headers(secret, "GET", track_path),
        extra_headers={"Range": "bytes=0-1023"},
    )
    report.check("statut 206", resp.status == 206, f"reçu {resp.status}")
    report.check("Content-Length = 1024", resp.header("Content-Length") == "1024",
                 str(resp.header("Content-Length")))
    expected_range = f"bytes 0-1023/{full_size}" if full_size > 0 else None
    report.check(
        "Content-Range cohérent",
        expected_range is not None and resp.header("Content-Range") == expected_range,
        str(resp.header("Content-Range")),
    )
    report.check("1024 octets reçus", len(resp.body) == 1024, f"{len(resp.body)} octets")

    # 4 — Range suffixe -----------------------------------------------------
    print("\n4. GET Range suffixe bytes=-512")
    resp = request(
        base_url,
        "GET",
        track_path,
        signed_headers(secret, "GET", track_path),
        extra_headers={"Range": "bytes=-512"},
    )
    report.check("statut 206", resp.status == 206, f"reçu {resp.status}")
    report.check("Content-Length = 512", resp.header("Content-Length") == "512",
                 str(resp.header("Content-Length")))
    if full_size > 0:
        report.check(
            "Content-Range = derniers 512 octets",
            resp.header("Content-Range") == f"bytes {full_size - 512}-{full_size - 1}/{full_size}",
            str(resp.header("Content-Range")),
        )

    # 5 — Range insatisfaisable --------------------------------------------
    print("\n5. GET Range insatisfaisable")
    unsatisfiable = f"bytes={full_size + 1000}-{full_size + 2000}" if full_size > 0 else "bytes=99999999999-"
    resp = request(
        base_url,
        "GET",
        track_path,
        signed_headers(secret, "GET", track_path),
        extra_headers={"Range": unsatisfiable},
    )
    report.check("statut 416", resp.status == 416, f"reçu {resp.status}")

    # 6 — Requête sans signature -------------------------------------------
    print("\n6. Requête sans aucun en-tête de signature")
    resp = request(base_url, "GET", health_path, {})
    report.check("statut 401", resp.status == 401, f"reçu {resp.status}")
    report.check(
        "code AUTH_MISSING",
        '"AUTH_MISSING"' in resp.body.decode("utf-8", "replace"),
        _error_code(resp.body),
    )

    # 7 — Signature invalide ------------------------------------------------
    print("\n7. Signature invalide")
    resp = request(
        base_url,
        "GET",
        health_path,
        signed_headers(secret, "GET", health_path, corrupt_signature=True),
    )
    report.check("statut 401", resp.status == 401, f"reçu {resp.status}")
    report.check(
        "code AUTH_INVALID",
        '"AUTH_INVALID"' in resp.body.decode("utf-8", "replace"),
        _error_code(resp.body),
    )

    # 8 — Rejeu du nonce ----------------------------------------------------
    print("\n8. Rejeu du nonce")
    replay_nonce = generate_nonce()
    replay_ts = int(time.time())
    first = request(
        base_url,
        "GET",
        health_path,
        signed_headers(secret, "GET", health_path, timestamp=replay_ts, nonce=replay_nonce),
    )
    report.check("première utilisation acceptée", first.status == 200, f"reçu {first.status}")
    second = request(
        base_url,
        "GET",
        health_path,
        signed_headers(secret, "GET", health_path, timestamp=replay_ts, nonce=replay_nonce),
    )
    report.check("rejeu refusé en 401", second.status == 401, f"reçu {second.status}")
    report.check(
        "code AUTH_REPLAY",
        '"AUTH_REPLAY"' in second.body.decode("utf-8", "replace"),
        _error_code(second.body),
    )

    # 9 — Latence -----------------------------------------------------------
    print("\n9. Latence — cinq /health consécutifs")
    samples: list[float] = []
    ttfbs: list[float] = []
    for _ in range(5):
        resp = request(base_url, "GET", health_path, signed_headers(secret, "GET", health_path))
        if resp.status != 200:
            report.check("répétition /health en 200", False, f"reçu {resp.status}")
            break
        samples.append(resp.elapsed_ms)
        ttfbs.append(resp.ttfb_ms)
    else:
        report.check("5/5 en 200", True)
        print(
            f"       total  min {min(samples):.1f} ms / moy {sum(samples)/len(samples):.1f} ms"
            f" / max {max(samples):.1f} ms"
        )
        print(
            f"       TTFB   min {min(ttfbs):.1f} ms / moy {sum(ttfbs)/len(ttfbs):.1f} ms"
            f" / max {max(ttfbs):.1f} ms"
        )

    print()
    print(f"RESULTAT : {report.passed} contrôle(s) OK, {report.failed} échec(s)")
    return 0 if report.failed == 0 else 1


def _detect_leaks(body_text: str) -> list[str]:
    """Cherche une vraie fuite : chemin, racine musicale ou secret.

    `musicRootAvailable` est un champ LÉGITIME de /health (booléen). On teste
    donc des clés exactes et des motifs de chemin, jamais une sous-chaîne de
    nom de champ.
    """
    found: list[str] = []
    for exact_key in ('"musicRoot"', '"MUSIC_ROOT"', '"relativePath"', '"path"', '"entries"'):
        if exact_key + ":" in body_text.replace(" ", ""):
            found.append(f"clé {exact_key}")
    if re.search(r"[A-Za-z]:\\\\", body_text):
        found.append("chemin Windows absolu")
    if re.search(r"\.(flac|mp3|m4a|ogg|opus|wav|aac)\b", body_text, re.IGNORECASE):
        found.append("nom de fichier audio")
    for token in ("SHARED_SECRET", "secret"):
        if token in body_text:
            found.append(f"jeton « {token} »")
    return found


def _summarise_health(body_text: str) -> str:
    """Résumé de /health sans aucune donnée musicale ni chemin."""
    keep = ("indexLoaded", "indexEntryCount", "musicRootAvailable", "activeStreams")
    parts = []
    for field in keep:
        marker = f'"{field}":'
        start = body_text.find(marker)
        if start == -1:
            continue
        tail = body_text[start + len(marker):]
        end = min((i for i in (tail.find(","), tail.find("}")) if i != -1), default=len(tail))
        parts.append(f"{field}={tail[:end].strip()}")
    return " ".join(parts)


def _error_code(body: bytes) -> str:
    text = body.decode("utf-8", "replace")
    marker = '"error":"'
    start = text.find(marker)
    if start == -1:
        return "(code absent)"
    tail = text[start + len(marker):]
    end = tail.find('"')
    return tail[:end] if end != -1 else "(code illisible)"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Test HMAC du HomeSpotify Storage Agent (bibliothèque standard uniquement)."
    )
    parser.add_argument("url", help="URL de base, par exemple http://10.8.0.2:3100")
    parser.add_argument("track_id", help="Identifiant d'une piste présente dans l'index")
    parser.add_argument(
        "--secret-file",
        help="Fichier contenant le secret partagé (mode 0600). "
             "Ignoré si STORAGE_AGENT_SHARED_SECRET est défini.",
    )
    args = parser.parse_args()

    if not args.track_id.isdigit():
        fail_usage("track_id doit être un entier décimal")

    secret = load_secret(args.secret_file)
    try:
        return run(args.url, args.track_id, secret)
    except urllib.error.URLError as err:
        print(f"ERREUR de transport : {err.reason}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
