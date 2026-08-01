"""Provider Monochrome visible avec action Download exclusivement humaine."""

from __future__ import annotations

import re
import shutil
import time
from pathlib import Path
from typing import Any, Callable, Iterable

from .base_provider import (
    AcquisitionResult,
    AcquisitionStatus,
    EventCallback,
    ProviderOptions,
    TrackTarget,
    emit,
)
from .downloaded_file_watcher import (
    new_audio_candidates,
    stable_candidates,
    take_snapshot,
)
from .metadata_matching import (
    VisibleTrackCandidate,
    exact_candidates,
    probe_audio,
    verify_file_metadata,
)

DEFAULT_BASE_URL = "https://monochrome.tf/"
SEARCH_SELECTORS = (
    'input[type="search"]:visible',
    'input[placeholder*="Search for tracks" i]:visible',
    'input[placeholder*="artists" i]:visible',
    'input[placeholder*="albums" i]:visible',
)
_DURATION_RE = re.compile(r"\b(?:(\d+):)?(\d{1,2}):(\d{2})\b")


def build_search_query(target: TrackTarget) -> str:
    return f"{target.title.strip()} {target.artist.strip()}".strip()


def locate_search_input(page: Any) -> Any:
    matches: list[Any] = []
    seen: set[str] = set()
    for selector in SEARCH_SELECTORS:
        locator = page.locator(selector)
        for index in range(locator.count()):
            candidate = locator.nth(index)
            if not candidate.is_visible() or not candidate.is_enabled():
                continue
            identity = candidate.evaluate(
                "(node) => node.id || node.name || node.outerHTML"
            )
            if identity in seen:
                continue
            seen.add(identity)
            matches.append(candidate)
    if len(matches) != 1:
        raise ValueError("MONOCHROME_SEARCH_FIELD_AMBIGUOUS")
    return matches[0]


def _parse_duration(text: str) -> int | None:
    match = _DURATION_RE.search(text)
    if not match:
        return None
    hours = int(match.group(1) or 0)
    return hours * 3600 + int(match.group(2)) * 60 + int(match.group(3))


def visible_result_candidates(page: Any) -> list[VisibleTrackCandidate]:
    rows = page.locator(
        '[data-track-id]:visible, [role="row"]:visible, '
        'table tbody tr:visible, article:visible, li:visible'
    )
    candidates: list[VisibleTrackCandidate] = []
    for index in range(min(rows.count(), 250)):
        row = rows.nth(index)
        text = row.inner_text(timeout=1_000).strip()
        if not text:
            continue
        lines = [line.strip() for line in text.splitlines() if line.strip()]
        if len(lines) < 2:
            continue
        title = row.get_attribute("data-title") or lines[0]
        artist = row.get_attribute("data-artist") or lines[1]
        album = row.get_attribute("data-album")
        duration_raw = row.get_attribute("data-duration")
        duration = (
            int(duration_raw)
            if duration_raw and duration_raw.isdigit()
            else _parse_duration(text)
        )
        candidates.append(
            VisibleTrackCandidate(
                title=title,
                artist=artist,
                album=album,
                duration_seconds=duration,
                locator=row,
            )
        )
    return candidates


def select_exact_visible_result(
    page: Any,
    target: TrackTarget,
) -> VisibleTrackCandidate:
    matches = exact_candidates(target, visible_result_candidates(page))
    if not matches:
        raise ValueError("MONOCHROME_NO_EXACT_MATCH")
    if len(matches) > 1:
        raise ValueError("MONOCHROME_AMBIGUOUS_MATCH")
    selected = matches[0]
    selected.locator.scroll_into_view_if_needed()
    selected.locator.evaluate(
        """node => {
          node.dataset.homespotifyExactMatch = "true";
          node.style.outline = "4px solid #22c55e";
          node.style.outlineOffset = "3px";
          node.style.backgroundColor = "rgba(34, 197, 94, 0.16)";
        }"""
    )
    return selected


class MonochromeManualProvider:
    provider_name = "MONOCHROME_MANUAL"

    def __init__(
        self,
        playwright_factory: Callable[[], Any] | None = None,
        clock: Callable[[], float] = time.monotonic,
        sleeper: Callable[[float], None] = time.sleep,
    ) -> None:
        self._playwright_factory = playwright_factory
        self._clock = clock
        self._sleeper = sleeper

    def acquire(
        self,
        target: TrackTarget,
        output_dir: Path,
        event_callback: EventCallback | None,
        options: ProviderOptions,
    ) -> AcquisitionResult:
        if not options.visible:
            return AcquisitionResult(
                AcquisitionStatus.PROVIDER_ERROR,
                self.provider_name,
                "Monochrome exige Chromium visible.",
                error_code="MONOCHROME_VISIBLE_REQUIRED",
            )
        if options.download_directory is None:
            return AcquisitionResult(
                AcquisitionStatus.PROVIDER_ERROR,
                self.provider_name,
                "Le dossier Downloads Monochrome n’est pas configuré.",
                error_code="MONOCHROME_DOWNLOAD_DIRECTORY_REQUIRED",
            )

        snapshot = take_snapshot(options.download_directory)
        output_dir.mkdir(parents=True, exist_ok=True)
        playwright_factory = self._playwright_factory
        if playwright_factory is None:
            from playwright.sync_api import sync_playwright

            playwright_factory = sync_playwright

        try:
            with playwright_factory() as playwright:
                browser = playwright.chromium.launch(
                    headless=False,
                    downloads_path=str(options.download_directory),
                )
                context = browser.new_context(accept_downloads=True)
                page = context.new_page()
                page.goto(
                    options.base_url or DEFAULT_BASE_URL,
                    wait_until="domcontentloaded",
                )
                page.wait_for_load_state("domcontentloaded")
                page.wait_for_timeout(1_000)
                search = locate_search_input(page)
                query = build_search_query(target)
                search.fill(query)
                search.press("Enter")
                emit(
                    event_callback,
                    "stage",
                    stage="waiting_results",
                    provider="Monochrome",
                    message="Recherche Monochrome en cours.",
                )
                result_deadline = self._clock() + min(
                    60,
                    options.timeout_seconds,
                )
                selected = None
                while self._clock() < result_deadline:
                    try:
                        selected = select_exact_visible_result(page, target)
                        break
                    except ValueError as exc:
                        if str(exc) != "MONOCHROME_NO_EXACT_MATCH":
                            raise
                        page.wait_for_timeout(500)
                if selected is None:
                    raise ValueError("MONOCHROME_NO_EXACT_MATCH")
                emit(
                    event_callback,
                    "selected",
                    provider="Monochrome",
                    title=selected.title,
                    artist=selected.artist,
                    album=selected.album or "",
                    duration=selected.duration_seconds or 0,
                )
                emit(
                    event_callback,
                    "stage",
                    stage="waiting_manual_download",
                    provider="Monochrome",
                    message=(
                        "Le morceau exact est affiché. "
                        "Clique manuellement sur Download."
                    ),
                )
                result = self._wait_for_manual_file(
                    target,
                    snapshot,
                    output_dir,
                    event_callback,
                    options,
                )
                browser.close()
                return result
        except KeyboardInterrupt:
            return AcquisitionResult(
                AcquisitionStatus.CANCELLED,
                self.provider_name,
                "Acquisition Monochrome annulée.",
                error_code="CANCELLED",
            )
        except ValueError as exc:
            code = str(exc)
            status = (
                AcquisitionStatus.NOT_FOUND
                if code
                in {
                    "MONOCHROME_NO_EXACT_MATCH",
                    "MONOCHROME_AMBIGUOUS_MATCH",
                }
                else AcquisitionStatus.PROVIDER_INVALID_RESPONSE
            )
            return AcquisitionResult(
                status,
                self.provider_name,
                "Aucune correspondance Monochrome exacte et unique.",
                error_code=code,
            )
        except Exception:
            return AcquisitionResult(
                AcquisitionStatus.PROVIDER_ERROR,
                self.provider_name,
                "Monochrome n’est pas disponible.",
                error_code="MONOCHROME_PROVIDER_ERROR",
            )

    def _wait_for_manual_file(
        self,
        target: TrackTarget,
        snapshot: Any,
        output_dir: Path,
        event_callback: EventCallback | None,
        options: ProviderOptions,
    ) -> AcquisitionResult:
        deadline = self._clock() + options.timeout_seconds
        rejected: set[Path] = set()
        confirmation_required = False
        while self._clock() < deadline:
            found = [
                path
                for path in new_audio_candidates(
                    options.download_directory,
                    snapshot,
                )
                if path not in rejected
            ]
            stable = stable_candidates(
                found,
                options.file_stability_seconds,
                self._sleeper,
            )
            accepted: list[tuple[Path, Any]] = []
            for path in stable:
                try:
                    probe = probe_audio(path, options.ffprobe_path)
                    suffix = path.suffix.casefold()
                    real_format = probe.format_name.casefold()
                    if (
                        suffix == ".flac"
                        and "flac" not in real_format
                    ) or (
                        suffix == ".wav"
                        and not {
                            "wav",
                            "wave",
                        }.intersection(real_format.split(","))
                    ) or suffix not in {".flac", ".wav"}:
                        rejected.add(path)
                        emit(
                            event_callback,
                            "error",
                            code="MONOCHROME_FILE_FORMAT_REJECTED",
                            provider="Monochrome",
                            message=(
                                "Le format réel n’est pas un WAV/FLAC "
                                "importable."
                            ),
                        )
                        continue
                    valid, needs_confirmation, reason = verify_file_metadata(
                        target,
                        probe,
                    )
                except ValueError:
                    rejected.add(path)
                    continue
                if needs_confirmation:
                    confirmation_required = True
                    rejected.add(path)
                elif valid:
                    accepted.append((path, probe))
                else:
                    rejected.add(path)
                    emit(
                        event_callback,
                        "error",
                        code=reason,
                        provider="Monochrome",
                        message="Le fichier téléchargé ne correspond pas à la cible.",
                    )
            if len(accepted) > 1:
                return AcquisitionResult(
                    AcquisitionStatus.MANUAL_ACTION_REQUIRED,
                    self.provider_name,
                    "Plusieurs fichiers correspondent ; intervention requise.",
                    error_code="MONOCHROME_MULTIPLE_MATCHING_FILES",
                )
            if len(accepted) == 1:
                source, probe = accepted[0]
                destination = output_dir / source.name
                shutil.copy2(source, destination)
                return AcquisitionResult(
                    AcquisitionStatus.SUCCESS,
                    self.provider_name,
                    "Fichier Monochrome vérifié.",
                    local_file_path=destination,
                    metadata={
                        "codec": probe.codec,
                        "durationSeconds": probe.duration_seconds,
                    },
                )
            self._sleeper(0.5)
        if confirmation_required:
            return AcquisitionResult(
                AcquisitionStatus.MANUAL_FILE_CONFIRMATION_REQUIRED,
                self.provider_name,
                "Les tags sont absents ; confirmation explicite requise.",
                error_code="MANUAL_FILE_CONFIRMATION_REQUIRED",
            )
        return AcquisitionResult(
            AcquisitionStatus.PROVIDER_ERROR,
            self.provider_name,
            "Le délai du téléchargement manuel est expiré.",
            error_code="MONOCHROME_MANUAL_TIMEOUT",
        )
