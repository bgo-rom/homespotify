#!/usr/bin/env python3
"""Écrit le .env 0600 de l'API cache parallèle sans afficher de valeur.

ISOLATION PAR SCÉNARIO — le défaut réel du 2026-07-27 (4e exécution)
--------------------------------------------------------------------
Une SEULE limite de cache servait tous les scénarios :

    AUDIO_CACHE_MAX_BYTES = max(smallSize, secondSize) + 1

Cette valeur est délibérément CONTRADICTOIRE : elle garantit que les deux
objets ne tiennent jamais ensemble, ce qui rend l'éviction déterministe… et
rend impossible tout scénario qui a besoin des deux, ou d'un objet survivant
à un second remplissage. Conséquence observée : le scénario d'abandon sur la
piste 79 déclenchait `CACHE_EVICTION_STARTED` puis
`CACHE_EVICTED contentHashPrefix=cf43ef5cb02c sizeBytes=9165881`, l'objet de
la piste 78 disparaissait, et le test hors ligne qui suivait ne pouvait
QUE répondre 503 — verdict correct du provider sur une précondition détruite
par le harnais lui-même.

Chaque scénario reçoit donc désormais SA racine de cache et SA capacité :

    finalize-offline : capacité large, aucune éviction attendue ;
    abort            : cache vide, capacité large (l'abandon ne doit jamais
                       avoir à évincer une entrée utile pour démarrer) ;
    eviction         : capacité volontairement serrée, seul scénario où
                       l'éviction LRU est le sujet du test.
"""

from __future__ import annotations

import argparse
import json
import os
import secrets
from pathlib import Path

from phase5_track_selection import candidate_tracks

# Scénarios isolés. La valeur est le nom du répertoire de cache, sous
# `runtime/`, afin que le nettoyage du harnais les retrouve par motif.
SCENARIOS = ("finalize-offline", "abort", "eviction")


def cache_root_for(root: Path, scenario: str) -> Path:
    return root / "runtime" / f"cache-{scenario}"


def cache_max_bytes_for(scenario: str, small_size: int, second_size: int) -> int:
    """Capacité PAR SCÉNARIO, jamais une limite unique réutilisée.

    Le facteur 2 sur la somme laisse la place aux deux objets ET à un `.part`
    en cours : aucune éviction ne peut se déclencher par surprise pendant une
    finalisation ou un abandon. Seul `eviction` garde la limite serrée.
    """
    if scenario == "eviction":
        return max(small_size, second_size) + 1
    return (small_size + second_size) * 2


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--secret-file", required=True)
    parser.add_argument("--state-file", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--scenario", choices=SCENARIOS, default="finalize-offline")
    args = parser.parse_args()
    root = Path(args.root)
    secret = Path(args.secret_file)
    if secret.stat().st_mode & 0o077:
        raise SystemExit("SECRET_MODE_INVALID")
    hmac_secret = secret.read_text(encoding="utf-8").strip()
    if len(hmac_secret) < 32:
        raise SystemExit("HMAC_SECRET_TOO_SHORT")
    state = json.loads(Path(args.state_file).read_text(encoding="utf-8"))
    small_size = int(state["smallTrackSize"])
    # Sélection PARTAGÉE avec vps_phase5_cache_test.py. Les deux doivent
    # retenir la même piste, sans quoi le cache serait dimensionné pour une
    # piste et éprouvé avec une autre — et l'éviction cesserait d'être
    # déterministe. Le plancher de taille écarte au passage la piste périmée
    # de 4 096 octets injectée par la Phase 4.5 (voir phase5_track_selection).
    candidates = candidate_tracks(
        str(root / "data" / "runtime.db"),
        state["userId"],
        (int(state["smallTrackId"]),),
    )
    if not candidates:
        raise SystemExit("SECOND_CACHE_TRACK_MISSING")
    second_size = candidates[0].size_bytes
    cache_root = cache_root_for(root, args.scenario)
    max_bytes = cache_max_bytes_for(args.scenario, small_size, second_size)
    values = {
        # PAS "test" : `app.ts` construit Fastify avec
        # `logger: { enabled: config.nodeEnv !== "test" }`. En "test" le
        # logger est ENTIEREMENT desactive, `app.log.*` devient inerte, et
        # les callbacks passes aux providers n'ecrivent plus rien : les
        # journaux CACHE_* disparaissent, stdout et stderr restent a zero
        # octet. "production" est aussi ce que fera le deploiement reel ;
        # AUTH_TOKEN_SECRET fait 64 caracteres, au-dessus du minimum exige.
        "NODE_ENV": "production",
        "HOST": "127.0.0.1",
        "PORT": "3001",
        "DB_PATH": str(root / "data" / "runtime.db"),
        "MUSIC_DIR": str(root / "runtime" / "music"),
        "INCOMING_DIR": str(root / "runtime" / "imports"),
        "HOMESPOTIFY_IMPORT_ROOT": str(root / "runtime" / "imports"),
        "COVERS_DIR": str(root / "runtime" / "covers"),
        "OFFLINE_CACHE_DIR": str(root / "runtime" / "offline"),
        "BACKUP_ENABLED": "false",
        "DISCOVERY_ENABLED": "false",
        "SPOTIFY_DISCOVERY_ENABLED": "false",
        "APPLE_MUSIC_DISCOVERY_ENABLED": "false",
        "DEEZER_DISCOVERY_ENABLED": "false",
        "AUDIO_STORAGE_MODE": "cached",
        "AUDIO_REMOTE_BASE_URL": "http://10.8.0.2:3100",
        "AUDIO_REMOTE_SHARED_SECRET": hmac_secret,
        "AUDIO_REMOTE_CONNECT_TIMEOUT_MS": "2000",
        "AUDIO_REMOTE_HEADERS_TIMEOUT_MS": "5000",
        "AUDIO_REMOTE_BODY_IDLE_TIMEOUT_MS": "15000",
        "AUDIO_REMOTE_MAX_CONNECTIONS": "8",
        "AUDIO_CACHE_ROOT": str(cache_root),
        "AUDIO_CACHE_MAX_BYTES": str(max_bytes),
        "AUDIO_CACHE_MIN_FREE_BYTES": str(64 * 1024 * 1024),
        "AUDIO_CACHE_TEMP_MAX_AGE_MS": "60000",
        "AUDIO_CACHE_FILL_ON_FULL_GET": "true",
        "AUDIO_CACHE_VERIFY_ON_HIT": "size",
        "AUDIO_CACHE_EVICTION_TARGET_RATIO": "0.90",
        "AUTH_TOKEN_SECRET": secrets.token_hex(32),
        "LOG_LEVEL": "info",
    }
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.writelines(f"{key}={value}\n" for key, value in values.items())
    # Résumé NON SENSIBLE : ni secret, ni jeton, ni chemin de bibliothèque.
    # Il rend la configuration de capacité vérifiable dans le rapport, au lieu
    # d'être une constante implicite du code.
    print(json.dumps({
        "status": "phase5-env-written",
        "scenario": args.scenario,
        "cacheRoot": str(cache_root),
        "cacheMaxBytes": max_bytes,
        "smallTrackSizeBytes": small_size,
        "secondTrackSizeBytes": second_size,
        "evictionExpected": args.scenario == "eviction",
    }))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
