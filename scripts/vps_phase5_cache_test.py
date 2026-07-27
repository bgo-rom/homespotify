#!/usr/bin/env python3
"""Tests non sensibles du cache via l'API parallèle localhost.

Aucun secret n'est affiché : ni le jeton d'authentification, ni le contenu de
`api/.env`, ni les chemins de la bibliothèque musicale. Les messages d'erreur
des contrôles de type ne mentionnent que des NOMS DE TYPE, jamais les valeurs.

PREUVES, PAS DE STATUTS
-----------------------
Un `200` ne prouve rien à lui seul. Cette version distingue partout ce qui est
OBSERVÉ de ce qui est SUPPOSÉ :

- un HIT n'est un HIT que si un événement `CACHE_HIT` exact porte le
  `requestId` de la requête ;
- un remplissage n'est terminé que sur événement terminal OU objet final
  visible sur le disque, attendu par boucle bornée ;
- le verrou single-flight n'est déclaré libéré que si un SECOND remplissage
  peut réellement démarrer sur la même empreinte — preuve comportementale, pas
  une ligne de journal.

COURSE CONNUE ET DOCUMENTÉE
---------------------------
`CacheFillStream._flush()` valide la taille et l'empreinte, puis `fsync`,
`close`, `rename`, index SQLite, puis `CACHE_FILL_COMPLETED`. Tout cela se
produit APRÈS que le dernier octet a été poussé vers le client. Comme
`serveTrackFile` fixe un `content-length`, le client considère le corps
terminé dès qu'il a reçu ce nombre d'octets, sans attendre le `end` du flux
serveur. La réponse publique peut donc se terminer AVANT la promotion. Compter
les objets immédiatement après un GET est une mesure fausse — pas un défaut du
provider.

ISOLATION DES SCÉNARIOS
-----------------------
Chaque scénario tourne sur SA racine de cache, lue dans `AUDIO_CACHE_ROOT`,
et avec SA capacité (voir `vps_phase5_write_env.py`). Un scénario ne peut donc
plus détruire la précondition d'un autre. Le mode `offline-precheck` refuse
explicitement d'autoriser l'arrêt du Storage Agent tant que l'objet attendu,
son empreinte, l'entrée d'index et un vrai `CACHE_HIT` ne sont pas tous
prouvés — c'est le verrou qui manquait le 2026-07-27.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import http.client
import json
import os
import secrets
import socket
import sqlite3
import time
from pathlib import Path
from typing import Any, Callable, NamedTuple

import phase5_log_reader as logs
from phase5_track_selection import (
    MIN_TRACK_SIZE_BYTES,
    SelectedTrack,
    candidate_tracks,
    ensure_http_path,
    ensure_track_id,
    stream_path,
    track_exists,
)

# Bornes de toutes les attentes : aucune boucle du harnais ne peut pendre.
FILL_TERMINAL_ATTEMPTS = 30
FILL_TERMINAL_INTERVAL_S = 0.5          # 30 x 0,5 s = 15 s
EVENT_ATTEMPTS = 20
EVENT_INTERVAL_S = 0.5                  # 20 x 0,5 s = 10 s
PART_APPEAR_TIMEOUT_S = 15.0
PART_CLEANUP_TIMEOUT_S = 20.0
POLL_INTERVAL_S = 0.25
ABORT_READ_BYTES = 64 * 1024

FILL_COMPLETED = "CACHE_FILL_COMPLETED"
FILL_FAILURES = (
    "CACHE_FILL_FAILED", "CACHE_WRITE_FAILED", "CACHE_FILL_TRUNCATED",
    "CACHE_CORRUPT", "CACHE_CORRUPT_ENTRY",
)
FILL_ABORTED = "CACHE_FILL_ABORTED"
EVICTED = "CACHE_EVICTED"
FILL_BYPASSED = "CACHE_BYPASS"
FILL_STARTED = "CACHE_FILL_STARTED"
CACHE_HIT = "CACHE_HIT"
UPSTREAM_EVENTS = ("REMOTE_STORAGE_REQUEST_STARTED",)


class Response(NamedTuple):
    status: int
    headers: dict[str, str]
    size_bytes: int
    sha256: str
    ttfb_ms: float
    elapsed_s: float
    request_id: str


def env(path: Path) -> dict[str, str]:
    if path.stat().st_mode & 0o077:
        raise RuntimeError("ENV_MODE_INVALID")
    return dict(
        line.split("=", 1)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#") and "=" in line
    )


def b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def token(secret: str, state: dict[str, Any]) -> str:
    now = int(time.time())
    header = b64(b'{"alg":"HS256","typ":"JWT"}')
    payload = b64(
        json.dumps(
            {
                "sub": str(state["userId"]), "username": state["username"],
                "role": state["role"], "type": "access",
                "iat": now, "exp": now + 1800,
            },
            separators=(",", ":"),
        ).encode()
    )
    signature = b64(hmac.new(secret.encode(), f"{header}.{payload}".encode(), hashlib.sha256).digest())
    return f"{header}.{payload}.{signature}"


def new_request_id(label: str) -> str:
    """Identifiant unique. Le format respecte SAFE_REQUEST_ID côté API, qui le
    conserve tel quel — sans quoi Fastify substituerait son propre id et toute
    corrélation serait perdue."""
    return f"phase5-{label}-{secrets.token_hex(6)}"


def request(
    port: int, method: str, path: str, auth: str,
    range_value: str | None = None, request_id: str | None = None,
) -> Response:
    checked_path = ensure_http_path(path, argument="path")
    correlation = request_id or new_request_id("cache")
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    headers = {"Authorization": f"Bearer {auth}", "X-Request-Id": correlation}
    if range_value:
        headers["Range"] = range_value
    started = time.perf_counter()
    connection.request(method, checked_path, headers=headers)
    response = connection.getresponse()
    ttfb = (time.perf_counter() - started) * 1000
    digest = hashlib.sha256()
    size = 0
    while True:
        chunk = response.read(256 * 1024)
        if not chunk:
            break
        digest.update(chunk)
        size += len(chunk)
    elapsed = time.perf_counter() - started
    result = Response(
        response.status, {k.lower(): v for k, v in response.getheaders()},
        size, digest.hexdigest(), ttfb, elapsed, correlation,
    )
    connection.close()
    return result


def tri(value: bool | None) -> str:
    """Trois etats explicites. Une absence de preuve n'est PAS une preuve
    negative : sans journaux, on repond « unknown », jamais « false »."""
    return "unknown" if value is None else ("true" if value else "false")


def public_error_code(response: Response) -> str | None:
    if response.status < 400:
        return None
    return {404: "not_found", 502: "bad_gateway", 503: "service_unavailable"}.get(
        response.status, f"http_{response.status}"
    )


# Racine de cache EFFECTIVE du scénario en cours, fixée une fois par `main()`
# depuis `AUDIO_CACHE_ROOT`. Tant qu'elle n'est pas fixée, le comportement
# historique (`<root>/cache`) est conservé : les tests locaux, qui construisent
# eux-mêmes cette arborescence, restent valides sans changement de signature.
_CACHE_ROOT: Path | None = None


def set_cache_root(path: Path | None) -> None:
    """Fixe la racine de cache du scénario. Appelée une seule fois."""
    global _CACHE_ROOT
    _CACHE_ROOT = Path(path) if path is not None else None


def cache_dir(root: Path) -> Path:
    return _CACHE_ROOT if _CACHE_ROOT is not None else root / "cache"


def object_path(root: Path, content_hash: str) -> Path:
    return cache_dir(root) / "objects" / content_hash[:2] / f"{content_hash}.audio"


def part_files(root: Path, content_hash: str) -> list[Path]:
    return list((cache_dir(root) / "tmp").glob(f"{content_hash}.*.part"))


def wait_until(predicate: Callable[[], bool], timeout_s: float) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(POLL_INTERVAL_S)
    return predicate()


def poll_events(root: Path, request_id: str, stop: Callable[[list[str]], bool]) -> list[str]:
    """Relit les journaux jusqu'à condition terminale, avec bornes strictes."""
    names: list[str] = []
    for attempt in range(EVENT_ATTEMPTS):
        names = logs.event_names(logs.records_for(root, request_id))
        if stop(names):
            return names
        if attempt < EVENT_ATTEMPTS - 1:
            time.sleep(EVENT_INTERVAL_S)
    return names


# ---------------------------------------------------------------------------
# Compteurs disque, séparés
# ---------------------------------------------------------------------------


def cache_disk_report(root: Path) -> dict[str, Any]:
    """`totalCacheDirectoryBytes` ne prouve JAMAIS qu'un objet audio existe."""
    cache = cache_dir(root)
    objects = list((cache / "objects").glob("*/*.audio")) if (cache / "objects").is_dir() else []
    parts = list((cache / "tmp").glob("*.part")) if (cache / "tmp").is_dir() else []
    total = sum(p.stat().st_size for p in cache.rglob("*") if p.is_file()) if cache.is_dir() else 0
    object_bytes = sum(p.stat().st_size for p in objects)
    temp_bytes = sum(p.stat().st_size for p in parts)
    return {
        "objectCount": len(objects),
        "partCount": len(parts),
        "objectBytes": object_bytes,
        "tempBytes": temp_bytes,
        "metadataBytes": total - object_bytes - temp_bytes,
        "totalCacheDirectoryBytes": total,
        "indexEntryCount": cache_index_entries(root),
    }


def cache_index_entries(root: Path) -> int | None:
    database_path = cache_dir(root) / "metadata" / "cache-index.sqlite"
    if not database_path.exists():
        return None
    try:
        database = sqlite3.connect(f"file:{database_path}?mode=ro", uri=True)
        try:
            return int(
                database.execute(
                    "SELECT count(*) FROM cache_entries WHERE complete = 1"
                ).fetchone()[0]
            )
        finally:
            database.close()
    except sqlite3.Error:
        return None


def capacity_report(
    root: Path, values: dict[str, str], scenario: str,
    before: dict[str, Any], after: dict[str, Any],
) -> dict[str, Any]:
    """Publication exigée par §4 : la capacité cesse d'être implicite.

    Sans ces champs, une éviction déclenchée par une limite trop serrée
    ressemble à un défaut du provider. Avec eux, la cause est lisible dans le
    rapport lui-même.
    """
    try:
        max_bytes: int | None = int(values.get("AUDIO_CACHE_MAX_BYTES", ""))
    except ValueError:
        max_bytes = None
    return {
        "scenario": scenario,
        "cacheRoot": values.get("AUDIO_CACHE_ROOT"),
        "cacheMaxBytes": max_bytes,
        "objectCountBefore": before["objectCount"],
        "objectCountAfter": after["objectCount"],
        "indexEntryCountBefore": before["indexEntryCount"],
        "indexEntryCountAfter": after["indexEntryCount"],
        "evictionsObserved": logs.count_event(root, EVICTED),
    }


# ---------------------------------------------------------------------------
# Préconditions du mode hors ligne
# ---------------------------------------------------------------------------

PRECONDITION_FILE = "runtime/phase5-offline-precondition.json"


def precondition_path(root: Path) -> Path:
    return root / PRECONDITION_FILE


def clear_precondition(root: Path) -> None:
    """Aucune précondition périmée ne doit survivre à un échec de contrôle."""
    precondition_path(root).unlink(missing_ok=True)


PRECONDITION_FIELDS = (
    "cachedTrackId", "cachedTrackSizeBytes", "cachedTrackHash", "uncachedStreamPath",
)


def load_offline_precondition(root: Path) -> dict[str, Any] | None:
    """Laissez-passer du mode hors ligne, ou `None` — jamais un demi-état.

    Un fichier absent, illisible ou incomplet vaut REFUS. Sans ce verrou, un
    503 hors ligne resterait ambigu : régression du provider, ou précondition
    détruite par un scénario précédent (le défaut du 2026-07-27) ?
    """
    path = precondition_path(root)
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    if not isinstance(data, dict) or any(field not in data for field in PRECONDITION_FIELDS):
        return None
    return data


def write_offline_precondition(root: Path, data: dict[str, Any]) -> None:
    handle = os.open(precondition_path(root), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(handle, "w", encoding="utf-8") as stream:
        json.dump(data, stream)


# ---------------------------------------------------------------------------
# Attente bornée de la promotion
# ---------------------------------------------------------------------------


class FillOutcome(NamedTuple):
    fill_started: bool
    fill_completed: bool
    fill_failed: bool
    fill_bypassed: bool
    final_object_visible: bool
    index_entry_visible: bool
    final_object_size: int | None
    terminal_reason: str
    finalization_ms: float
    events: list[str]


def wait_for_fill_terminal(
    root: Path, request_id: str, track: SelectedTrack,
    attempts: int = FILL_TERMINAL_ATTEMPTS, interval_s: float = FILL_TERMINAL_INTERVAL_S,
) -> FillOutcome:
    """Attend une condition TERMINALE, jamais un délai arbitraire.

    Le disque fait foi en parallèle des journaux : si la journalisation est
    indisponible, un objet final de la bonne taille reste une preuve de
    promotion. L'inverse n'est pas vrai — un événement sans fichier serait un
    défaut, et il est rapporté comme tel.
    """
    started = time.perf_counter()
    final = object_path(root, track.sha256)
    names: list[str] = []
    reason = "TIMEOUT"
    for attempt in range(attempts):
        names = logs.event_names(logs.records_for(root, request_id))
        visible = final.exists()
        if FILL_COMPLETED in names and visible:
            reason = "COMPLETED"
            break
        if any(name in names for name in FILL_FAILURES):
            reason = next(name for name in names if name in FILL_FAILURES)
            break
        if FILL_BYPASSED in names:
            reason = "BYPASSED"
            break
        if visible and final.stat().st_size == track.size_bytes:
            # Promotion prouvée par le système de fichiers, journaux muets.
            reason = "OBJECT_VISIBLE_WITHOUT_EVENT"
            break
        if attempt < attempts - 1:
            time.sleep(interval_s)
    elapsed_ms = (time.perf_counter() - started) * 1000
    size = final.stat().st_size if final.exists() else None
    return FillOutcome(
        fill_started=FILL_STARTED in names,
        fill_completed=FILL_COMPLETED in names,
        fill_failed=any(name in names for name in FILL_FAILURES),
        fill_bypassed=FILL_BYPASSED in names,
        final_object_visible=final.exists(),
        index_entry_visible=(cache_index_entries(root) or 0) > 0,
        final_object_size=size,
        terminal_reason=reason,
        finalization_ms=round(elapsed_ms, 1),
        events=names,
    )


# ---------------------------------------------------------------------------
# Preuve d'un vrai HIT
# ---------------------------------------------------------------------------


class HitProof(NamedTuple):
    response: Response
    # None = indeterminable faute de journaux exploitables.
    cache_hit_observed: bool | None
    upstream_contacted: bool | None
    hash_matched: bool
    size_matched: bool
    events: list[str]
    log_evidence_available: bool


def prove_cache_hit(
    root: Path, port: int, path: str, auth: str, track: SelectedTrack,
    label: str, range_value: str | None = None, expect_body: bool = True,
) -> HitProof:
    """Un `200` ne suffit pas : il faut un `CACHE_HIT` portant ce requestId."""
    correlation = new_request_id(label)
    response = request(port, "GET" if expect_body else "HEAD", path, auth, range_value, correlation)
    names = poll_events(
        root, correlation,
        lambda seen: CACHE_HIT in seen or any(u in seen for u in UPSTREAM_EVENTS),
    )
    evidence = logs.diagnostics(root)["logEvidenceAvailable"]
    return HitProof(
        response=response,
        cache_hit_observed=(CACHE_HIT in names) if evidence else None,
        upstream_contacted=(any(u in names for u in UPSTREAM_EVENTS)) if evidence else None,
        hash_matched=(response.sha256 == track.sha256) if (expect_body and range_value is None) else True,
        size_matched=(response.size_bytes == track.size_bytes) if (expect_body and range_value is None) else True,
        events=names,
        log_evidence_available=evidence,
    )


# ---------------------------------------------------------------------------
# Sélection de la piste d'abandon
# ---------------------------------------------------------------------------


class AbortTrackChoice(NamedTuple):
    track: SelectedTrack | None
    head_status: int | None
    head_request_id: str | None
    rejected: list[dict[str, Any]]
    skip_reason: str | None


def choose_abort_track(
    root: Path, database_path: str, user_id: Any,
    excluded_track_ids: tuple[int, ...], port: int, auth: str,
) -> AbortTrackChoice:
    candidates = candidate_tracks(database_path, user_id, excluded_track_ids)
    rejected: list[dict[str, Any]] = []
    if not candidates:
        return AbortTrackChoice(
            None, None, None, rejected,
            f"aucune piste visible d'au moins {MIN_TRACK_SIZE_BYTES} octets",
        )
    for candidate in candidates:
        if not track_exists(database_path, candidate.track_id):
            rejected.append({"trackId": candidate.track_id, "reason": "ABSENT_SQLITE"})
            continue
        if object_path(root, candidate.sha256).exists():
            rejected.append({"trackId": candidate.track_id, "reason": "DEJA_EN_CACHE"})
            continue
        correlation = new_request_id("abort-head")
        head = request(port, "HEAD", candidate.stream_path, auth, request_id=correlation)
        if head.status != 200:
            rejected.append({
                "trackId": candidate.track_id, "reason": "HEAD_NON_200",
                "status": head.status, "publicErrorCode": public_error_code(head),
                "requestId": correlation,
            })
            continue
        return AbortTrackChoice(candidate, head.status, correlation, rejected, None)
    return AbortTrackChoice(
        None, None, None, rejected, "aucune candidate ne répond 200 à un HEAD préalable"
    )


# ---------------------------------------------------------------------------
# Scénario d'abandon, avec preuve COMPORTEMENTALE du verrou
# ---------------------------------------------------------------------------


class AbortAttempt(NamedTuple):
    status: int
    bytes_read: int
    part_observed: bool
    part_removed: bool
    events: list[str]
    request_id: str


def _abort_once(
    root: Path, port: int, track: SelectedTrack, auth: str, label: str,
    part_appear_timeout_s: float, part_cleanup_timeout_s: float,
) -> AbortAttempt:
    correlation = new_request_id(label)
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
    connection.request(
        "GET", ensure_http_path(track.stream_path, argument="path"),
        headers={"Authorization": f"Bearer {auth}", "X-Request-Id": correlation},
    )
    response = connection.getresponse()
    status = response.status
    bytes_read = 0
    part_observed = False
    if status == 200:
        bytes_read = len(response.read(ABORT_READ_BYTES))
        part_observed = wait_until(
            lambda: bool(part_files(root, track.sha256)), part_appear_timeout_s
        )
    # Fermeture BRUTALE : c'est un abandon, pas une fin propre.
    try:
        sock = getattr(connection, "sock", None)
        if sock is not None:
            sock.setsockopt(
                socket.SOL_SOCKET, socket.SO_LINGER,
                b"\x01\x00\x00\x00\x00\x00\x00\x00",
            )
    except OSError:
        pass
    connection.close()
    part_removed = wait_until(
        lambda: not part_files(root, track.sha256), part_cleanup_timeout_s
    )
    names = poll_events(
        root, correlation,
        lambda seen: FILL_ABORTED in seen or any(f in seen for f in FILL_FAILURES),
    )
    return AbortAttempt(status, bytes_read, part_observed, part_removed, names, correlation)


class AbortOutcome(NamedTuple):
    first: AbortAttempt
    second: AbortAttempt | None
    terminal_event_observed: bool
    refill_started: bool
    lock_released_behaviorally: bool
    not_promoted: bool


def run_abort_scenario(
    root: Path, port: int, track: SelectedTrack, auth: str, *,
    part_appear_timeout_s: float = PART_APPEAR_TIMEOUT_S,
    part_cleanup_timeout_s: float = PART_CLEANUP_TIMEOUT_S,
) -> AbortOutcome:
    """Abandon, puis PREUVE COMPORTEMENTALE que le verrou a été rendu.

    L'absence immédiate de `CACHE_FILL_ABORTED` ne prouve rien : le journal
    peut être en retard. En revanche, si un SECOND remplissage démarre sur la
    même empreinte, le verrou single-flight est nécessairement libre — sinon
    la requête serait partie en `CACHE_BYPASS / SINGLE_FLIGHT_ACTIVE` sans
    jamais créer de `.part`.
    """
    first = _abort_once(
        root, port, track, auth, "abort", part_appear_timeout_s, part_cleanup_timeout_s
    )
    terminal = FILL_ABORTED in first.events or any(f in first.events for f in FILL_FAILURES)

    second: AbortAttempt | None = None
    refill = False
    if first.status == 200 and first.bytes_read > 0:
        second = _abort_once(
            root, port, track, auth, "abort2",
            part_appear_timeout_s, part_cleanup_timeout_s,
        )
        # Un nouveau `.part`, ou un CACHE_FILL_STARTED : dans les deux cas un
        # remplissage neuf a démarré, donc le verrou était libre.
        refill = second.part_observed or FILL_STARTED in second.events

    return AbortOutcome(
        first=first, second=second,
        terminal_event_observed=terminal,
        refill_started=refill,
        lock_released_behaviorally=refill,
        not_promoted=not object_path(root, track.sha256).exists(),
    )


def agent_active_streams(secret_file: Path, base_url: str) -> int | None:
    if not secret_file.exists() or secret_file.stat().st_mode & 0o077:
        return None
    secret = secret_file.read_text(encoding="utf-8").strip()
    host = base_url.split("//", 1)[-1]
    hostname, _, port_text = host.partition(":")
    path = "/internal/storage/health"
    timestamp = str(int(time.time()))
    nonce = base64.urlsafe_b64encode(os.urandom(32)).rstrip(b"=").decode()
    empty_sha = hashlib.sha256(b"").hexdigest()
    canonical = f"GET\n{path}\n{timestamp}\n{nonce}\n{empty_sha}"
    signature = hmac.new(secret.encode(), canonical.encode(), hashlib.sha256).hexdigest()
    try:
        connection = http.client.HTTPConnection(hostname, int(port_text or 80), timeout=10)
        connection.request("GET", path, headers={
            "X-HS-Timestamp": timestamp, "X-HS-Nonce": nonce,
            "X-HS-Content-SHA256": empty_sha, "X-HS-Signature": signature,
        })
        response = connection.getresponse()
        body = response.read()
        connection.close()
        if response.status != 200:
            return None
        return int(json.loads(body)["activeStreams"])
    except (OSError, ValueError, KeyError, json.JSONDecodeError):
        return None


def api_healthy(port: int) -> bool:
    try:
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        connection.request("GET", "/health")
        status = connection.getresponse().status
        connection.close()
        return status == 200
    except OSError:
        return False


def emit(payload: dict[str, Any], checks: dict[str, bool], root: Path | None = None) -> bool:
    failed = sorted(name for name, passed in checks.items() if not passed)
    payload["checks"] = dict(sorted(checks.items()))
    payload["failedChecks"] = failed
    payload["ok"] = not failed
    if failed and root is not None:
        # En cas d'échec, publier de quoi trancher : journaux absents,
        # journaux présents mais sans événement du cache, ou événements
        # présents mais sans corrélation.
        payload["logDiagnostics"] = logs.diagnostics(root)
        payload["recentCacheEvents"] = logs.sanitized_events(
            [r for r in logs.all_records(root)
             if isinstance(r.get("event"), str)
             and r["event"].startswith(logs.CACHE_EVENT_PREFIXES)]
        )
    print(json.dumps(payload))
    return not failed


def abort_payload(choice: AbortTrackChoice, outcome: AbortOutcome, track: SelectedTrack,
                  database_path: str, streams: int | None) -> dict[str, Any]:
    return {
        "abortTrackId": track.track_id,
        "abortExpectedSizeBytes": track.size_bytes,
        "abortContentHashPrefix": track.hash_prefix,
        "abortPresentInSqlite": track_exists(database_path, track.track_id),
        "abortHeadStatus": choice.head_status,
        "abortHeadRequestId": choice.head_request_id,
        "abortStatus": outcome.first.status,
        "abortRequestId": outcome.first.request_id,
        "abortBytesRead": outcome.first.bytes_read,
        "abortInternalEvents": outcome.first.events,
        "abortTerminalEventObserved": outcome.terminal_event_observed,
        "refillStartedAfterAbort": outcome.refill_started,
        "secondAbortStatus": outcome.second.status if outcome.second else None,
        "secondAbortBytesRead": outcome.second.bytes_read if outcome.second else None,
        "secondAbortPartRemoved": outcome.second.part_removed if outcome.second else None,
        "lockReleasedBehaviorally": outcome.lock_released_behaviorally,
        "agentActiveStreams": streams,
        "rejectedCandidates": choice.rejected,
    }


def abort_checks(outcome: AbortOutcome, streams: int | None, port: int) -> dict[str, bool]:
    return {
        "abortStarted": outcome.first.status == 200 and outcome.first.bytes_read > 0,
        "abortStatusAccepted": outcome.first.status == 200,
        "abortPartObserved": outcome.first.part_observed,
        "abortPartRemoved": outcome.first.part_removed,
        "abortNotPromoted": outcome.not_promoted,
        "refillStartedAfterAbort": outcome.refill_started,
        "secondAbortPartRemoved": bool(outcome.second and outcome.second.part_removed),
        # Verdict fondé sur le comportement, pas sur la présence immédiate
        # d'une ligne de journal.
        "lockReleased": outcome.lock_released_behaviorally,
        "agentStreamsDrained": streams in (None, 0),
        "apiHealthy": api_healthy(port),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument(
        "--mode",
        choices=(
            "full", "offline", "offline-precheck", "restart", "eviction",
            "abort", "finalize",
        ),
        required=True,
    )
    parser.add_argument("--port", type=int, default=3001)
    parser.add_argument("--scenario", default="")
    args = parser.parse_args()
    port, root = args.port, Path(args.root)
    state = json.loads((root / "runtime/phase5.json").read_text(encoding="utf-8"))
    values = env(root / "api/.env")
    # La racine de cache est celle du scénario en cours, JAMAIS une constante :
    # c'est ce qui rend les scénarios réellement indépendants.
    set_cache_root(Path(values["AUDIO_CACHE_ROOT"]))
    scenario = args.scenario or Path(values["AUDIO_CACHE_ROOT"]).name.removeprefix("cache-")
    auth = token(values["AUTH_TOKEN_SECRET"], state)
    database_path = values["DB_PATH"]
    secret_file = root / ".hmac-secret"
    remote_url = values.get("AUDIO_REMOTE_BASE_URL", "")

    small_track_id = ensure_track_id(state["smallTrackId"], argument="state.smallTrackId")
    small = stream_path(small_track_id)
    small_track = SelectedTrack(small_track_id, int(state["smallTrackSize"]), state["smallTrackHash"])

    if args.mode == "restart":
        proof = prove_cache_hit(root, port, small, auth, small_track, "restart", expect_body=False)
        return 0 if emit(
            {"mode": "restart", "status": proof.response.status,
             "ttfbMs": round(proof.response.ttfb_ms, 1), "events": proof.events,
             **cache_disk_report(root)},
            {"headHitSucceeded": proof.response.status == 200,
             "headHitEmptyBody": proof.response.size_bytes == 0,
             "cacheHitObserved": proof.cache_hit_observed is True,
             "upstreamNotContactedOnHit": proof.upstream_contacted is False},
            root,
        ) else 1

    # --- Préconditions du mode hors ligne, AVANT tout arrêt d'agent ---------
    if args.mode == "offline-precheck":
        before = cache_disk_report(root)
        final = object_path(root, small_track.sha256)
        present = final.exists()
        size = final.stat().st_size if present else None
        # Le HIT est prouvé pendant que l'agent est encore actif : si le
        # provider devait aller chercher les octets à distance, on le verrait
        # ici, et l'agent ne serait jamais arrêté.
        hit = prove_cache_hit(root, port, small, auth, small_track, "precheck-hit")
        # La piste NON cachée du test hors ligne est choisie MAINTENANT :
        # `choose_abort_track` s'appuie sur un HEAD 200, impossible à obtenir
        # une fois l'agent arrêté.
        choice = choose_abort_track(
            root, database_path, state["userId"], (small_track_id,), port, auth
        )
        after = cache_disk_report(root)
        checks = {
            "expectedObjectPresent": present,
            "expectedObjectSizeMatched": size == small_track.size_bytes,
            "expectedHashMatched": hit.hash_matched,
            "objectCountIsOne": after["objectCount"] == 1,
            "indexEntryCountIsOne": after["indexEntryCount"] == 1,
            "partCountIsZero": after["partCount"] == 0,
            "cacheHitProven": hit.cache_hit_observed is True,
            "upstreamNotContactedOnHit": hit.upstream_contacted is False,
            "uncachedTrackSelected": choice.track is not None,
        }
        payload = {
            "mode": "offline-precheck",
            "cachedTrackId": small_track_id,
            "cachedHashPrefix": small_track.hash_prefix,
            "cachedObjectSizeBytes": size,
            "uncachedTrackId": choice.track.track_id if choice.track else None,
            "rejectedCandidates": choice.rejected,
            **capacity_report(root, values, scenario, before, after),
            **after,
        }
        if all(checks.values()) and choice.track is not None:
            # Le fichier de précondition est le SEUL laissez-passer pour
            # arrêter le Storage Agent. Il n'est écrit que si tout est prouvé.
            write_offline_precondition(root, {
                "cachedTrackId": small_track_id,
                "cachedTrackSizeBytes": small_track.size_bytes,
                "cachedTrackHash": small_track.sha256,
                "cacheObjectPresentBeforeStop": True,
                "indexEntryPresentBeforeStop": True,
                "cacheHitObservedBeforeStop": True,
                "uncachedTrackId": choice.track.track_id,
                "uncachedStreamPath": choice.track.stream_path,
                "cacheRoot": values["AUDIO_CACHE_ROOT"],
            })
            payload["preconditionWritten"] = True
        else:
            clear_precondition(root)
            payload["preconditionWritten"] = False
        return 0 if emit(payload, checks, root) else 1

    # --- Mode hors ligne : agent arrêté, seul le cache peut répondre --------
    if args.mode == "offline":
        pre = load_offline_precondition(root)
        if pre is None:
            # Jamais de test hors ligne « à l'aveugle » : sans laissez-passer,
            # un 503 ne distinguerait pas une régression d'une précondition
            # détruite. C'est exactement le piège du 2026-07-27.
            print(json.dumps({
                "mode": "offline", "ok": False,
                "failedChecks": ["preconditionAvailable"],
                "reason": "OFFLINE_PRECONDITION_MISSING",
            }))
            return 1
        cached = SelectedTrack(
            ensure_track_id(pre["cachedTrackId"], argument="precondition.cachedTrackId"),
            int(pre["cachedTrackSizeBytes"]),
            pre["cachedTrackHash"],
        )
        before = cache_disk_report(root)
        still_present = object_path(root, cached.sha256).exists()
        get = prove_cache_hit(root, port, cached.stream_path, auth, cached, "offline-get")
        head = prove_cache_hit(
            root, port, cached.stream_path, auth, cached, "offline-head", expect_body=False
        )
        ranged = prove_cache_hit(
            root, port, cached.stream_path, auth, cached, "offline-range", "bytes=0-1023"
        )
        uncached = ensure_http_path(pre["uncachedStreamPath"], argument="precondition.uncachedStreamPath")
        miss = request(port, "HEAD", uncached, auth, request_id=new_request_id("offline-miss"))
        after = cache_disk_report(root)
        payload = {
            "mode": "offline",
            "cachedTrackId": cached.track_id,
            "cachedHashPrefix": cached.hash_prefix,
            "cacheObjectPresentBeforeStop": bool(pre.get("cacheObjectPresentBeforeStop")),
            "indexEntryPresentBeforeStop": bool(pre.get("indexEntryPresentBeforeStop")),
            "cacheObjectStillPresent": still_present,
            "offlineGetStatus": get.response.status,
            "offlineHeadStatus": head.response.status,
            "offlineRangeStatus": ranged.response.status,
            "offlineCacheHitObserved": tri(get.cache_hit_observed),
            "upstreamContactedOnOfflineHit": tri(get.upstream_contacted),
            "uncachedTrackId": pre.get("uncachedTrackId"),
            "uncachedMissStatus": miss.status,
            "uncachedMissPublicErrorCode": public_error_code(miss),
            "uncachedMissRequestId": miss.request_id,
            **capacity_report(root, values, scenario, before, after),
            **after,
        }
        return 0 if emit(payload, {
            # Un objet évincé ne peut JAMAIS passer pour un HIT hors ligne.
            "cacheObjectStillPresent": still_present,
            "offlineGetSucceeded": get.response.status == 200,
            "offlineGetHashMatched": get.hash_matched,
            "offlineHeadSucceeded": head.response.status == 200 and head.response.size_bytes == 0,
            "offlineRangeSucceeded": ranged.response.status == 206 and ranged.response.size_bytes == 1024,
            "offlineCacheHitObserved": get.cache_hit_observed is True,
            "upstreamNotContactedOnOfflineHit": get.upstream_contacted is False,
            "uncachedMissReportedUnavailable": miss.status == 503,
            "internal401NotExposed": miss.status != 401,
        }, root) else 1

    # --- MISS complet, promotion prouvée, puis HIT prouvé -------------------
    if args.mode in ("full", "finalize"):
        before = cache_disk_report(root)
        miss_id = new_request_id("miss")
        miss = request(port, "GET", small, auth, request_id=miss_id)
        fill = wait_for_fill_terminal(root, miss_id, small_track)
        hit = prove_cache_hit(root, port, small, auth, small_track, "hit")
        head = prove_cache_hit(root, port, small, auth, small_track, "head-hit", expect_body=False)
        ranged = prove_cache_hit(root, port, small, auth, small_track, "range-hit", "bytes=0-1023")

        payload: dict[str, Any] = {
            "mode": args.mode,
            "missTtfbMs": round(miss.ttfb_ms, 1), "missStatus": miss.status,
            "missMiBps": round(miss.size_bytes / max(miss.elapsed_s, 0.001) / 1048576, 3),
            "bytes": miss.size_bytes,
            "fillStarted": fill.fill_started, "fillCompleted": fill.fill_completed,
            "fillFailed": fill.fill_failed, "fillBypassed": fill.fill_bypassed,
            "finalObjectVisible": fill.final_object_visible,
            "indexEntryVisible": fill.index_entry_visible,
            "finalObjectSize": fill.final_object_size,
            "fillTerminalReason": fill.terminal_reason,
            "fillFinalizationMs": fill.finalization_ms,
            "fillEvents": fill.events,
            "hitTtfbMs": round(hit.response.ttfb_ms, 1),
            "hitMiBps": round(hit.response.size_bytes / max(hit.response.elapsed_s, 0.001) / 1048576, 3),
            "cacheHitObserved": tri(hit.cache_hit_observed),
            "upstreamContactedOnHit": tri(hit.upstream_contacted),
            "logEvidenceAvailable": hit.log_evidence_available,
            "headHitTtfbMs": round(head.response.ttfb_ms, 1),
            "headCacheHitObserved": tri(head.cache_hit_observed),
            "rangeHitTtfbMs": round(ranged.response.ttfb_ms, 1),
            "rangeCacheHitObserved": tri(ranged.cache_hit_observed),
            **capacity_report(root, values, scenario, before, cache_disk_report(root)),
            **cache_disk_report(root),
        }
        checks = {
            "missSucceeded": miss.status == 200,
            "fillReachedTerminalState": fill.terminal_reason not in ("TIMEOUT",),
            "fillNotFailed": not fill.fill_failed,
            "finalObjectVisible": fill.final_object_visible,
            "indexEntryVisible": fill.index_entry_visible,
            "finalObjectSizeMatched": fill.final_object_size == small_track.size_bytes,
            "hitSucceeded": hit.response.status == 200,
            "cacheHitObserved": hit.cache_hit_observed is True,
            "upstreamNotContactedOnHit": hit.upstream_contacted is False,
            "hitObjectHashMatched": hit.hash_matched,
            "hitObjectSizeMatched": hit.size_matched,
            "headHitSucceeded": head.response.status == 200 and head.response.size_bytes == 0,
            "rangeHitSucceeded": ranged.response.status == 206 and ranged.response.size_bytes == 1024,
            "objectCountValid": cache_disk_report(root)["objectCount"] == 1,
            "partCountValid": cache_disk_report(root)["partCount"] == 0,
            # Sur ce scénario la capacité est large : une éviction ici
            # signifierait un dimensionnement de nouveau contradictoire.
            "noEvictionOnFinalizeScenario": logs.count_event(root, EVICTED) == 0,
        }

        try:
            pid = int((root / "runtime/api.pid").read_text(encoding="utf-8"))
            payload["apiRssKiB"] = next(
                int(line.split()[1])
                for line in Path(f"/proc/{pid}/status").read_text(encoding="utf-8").splitlines()
                if line.startswith("VmRSS:")
            )
        except (OSError, StopIteration, ValueError):
            payload["apiRssKiB"] = None
        # `full` NE POURSUIT PLUS avec l'abandon dans le même cache. C'était la
        # cause exacte de l'échec du 2026-07-27 : l'abandon portait sur une
        # piste plus grosse que la place restante, l'éviction LRU supprimait
        # légitimement l'objet promu juste avant, et le test hors ligne qui
        # suivait n'avait plus rien à servir. L'abandon et l'éviction sont
        # désormais des scénarios SÉPARÉS, sur des racines de cache distinctes,
        # orchestrés par `run_phase5_cache_integration.ps1`.
        return 0 if emit(payload, checks, root) else 1

    # --- Modes utilisant la seconde piste ----------------------------------
    before = cache_disk_report(root)
    choice = choose_abort_track(root, database_path, state["userId"], (small_track_id,), port, auth)
    if choice.track is None:
        print(json.dumps({
            "mode": args.mode, "status": "SKIPPED", "reason": choice.skip_reason,
            "minimumSizeBytes": MIN_TRACK_SIZE_BYTES, "rejectedCandidates": choice.rejected,
        }))
        return 2

    track = choice.track

    if args.mode == "abort":
        outcome = run_abort_scenario(root, port, track, auth)
        streams = agent_active_streams(secret_file, remote_url)
        after = cache_disk_report(root)
        checks = abort_checks(outcome, streams, port)
        # Le cache d'abandon part VIDE et dispose d'une capacité large :
        # l'abandon ne doit avoir aucune raison d'évincer quoi que ce soit.
        checks["noEvictionOnAbortScenario"] = logs.count_event(root, EVICTED) == 0
        return 0 if emit(
            {"mode": "abort", **abort_payload(choice, outcome, track, database_path, streams),
             **capacity_report(root, values, scenario, before, after), **after},
            checks,
            root,
        ) else 1

    # --- eviction : SEUL scénario dont l'éviction LRU est le sujet ----------
    # Le cache y est volontairement dimensionné pour ne pas contenir les deux
    # objets. Cet état n'est JAMAIS réutilisé par le test hors ligne.
    first_id = new_request_id("evict-first")
    first = request(port, "GET", small, auth, request_id=first_id)
    first_fill = wait_for_fill_terminal(root, first_id, small_track)
    miss_id = new_request_id("evict-miss")
    miss = request(port, "GET", track.stream_path, auth, request_id=miss_id)
    fill = wait_for_fill_terminal(root, miss_id, track)
    hit = prove_cache_hit(root, port, track.stream_path, auth, track, "evict-hit")
    report = cache_disk_report(root)
    return 0 if emit(
        {"mode": "eviction", "evictionTrackId": track.track_id,
         "evictionContentHashPrefix": track.hash_prefix,
         "firstTrackId": small_track_id,
         "firstContentHashPrefix": small_track.hash_prefix,
         "firstFillTerminalReason": first_fill.terminal_reason,
         "firstStatus": first.status,
         "missStatus": miss.status, "hitStatus": hit.response.status,
         "fillTerminalReason": fill.terminal_reason,
         "fillFinalizationMs": fill.finalization_ms,
         **capacity_report(root, values, scenario, before, report), **report},
        {"firstObjectPromoted": first_fill.final_object_visible,
         "missSucceeded": miss.status == 200,
         "hitSucceeded": hit.response.status == 200,
         "cacheHitObserved": hit.cache_hit_observed is True,
         "contentMatched": miss.sha256 == track.sha256,
         "previousObjectEvicted": not object_path(root, small_track.sha256).exists(),
         "evictionEventObserved": logs.count_event(root, EVICTED) > 0,
         "newObjectPresent": object_path(root, track.sha256).exists(),
         "objectCountValid": report["objectCount"] == 1},
        root,
    ) else 1


if __name__ == "__main__":
    raise SystemExit(main())
