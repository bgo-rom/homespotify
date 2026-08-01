from __future__ import annotations

import importlib
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

from providers.base_provider import AcquisitionStatus, TrackTarget
from providers.downloaded_file_watcher import (
    DownloadSnapshot,
    FileFingerprint,
    MIN_AUDIO_BYTES,
    is_stable,
    new_audio_candidates,
)
from providers.metadata_matching import (
    FileProbe,
    VisibleTrackCandidate,
    exact_candidates,
    normalize_metadata,
    verify_file_metadata,
)
from providers.monochrome_manual_provider import (
    SEARCH_SELECTORS,
    build_search_query,
    locate_search_input,
    select_exact_visible_result,
)


class FakeInput:
    def __init__(self, identity: str, visible: bool = True) -> None:
        self.identity = identity
        self.visible = visible
        self.fills: list[str] = []
        self.presses: list[str] = []

    def is_visible(self) -> bool:
        return self.visible

    def is_enabled(self) -> bool:
        return True

    def evaluate(self, _script: str):
        return self.identity

    def fill(self, value: str) -> None:
        self.fills.append(value)

    def press(self, value: str) -> None:
        self.presses.append(value)


class FakeInputLocator:
    def __init__(self, values):
        self.values = values

    def count(self):
        return len(self.values)

    def nth(self, index):
        return self.values[index]


class FakeRow:
    def __init__(self, text: str, attributes: dict[str, str] | None = None):
        self.text = text
        self.attributes = attributes or {}
        self.scrolled = False
        self.highlighted = False

    def inner_text(self, timeout=None):
        del timeout
        return self.text

    def get_attribute(self, name):
        return self.attributes.get(name)

    def scroll_into_view_if_needed(self):
        self.scrolled = True

    def evaluate(self, _script):
        self.highlighted = True


class FakeRowLocator:
    def __init__(self, rows):
        self.rows = rows

    def count(self):
        return len(self.rows)

    def nth(self, index):
        return self.rows[index]


class FakePage:
    def __init__(self, inputs=None, rows=None):
        self.inputs = inputs or {}
        self.rows = rows or []

    def locator(self, selector):
        if selector.startswith("[data-track-id]"):
            return FakeRowLocator(self.rows)
        return FakeInputLocator(self.inputs.get(selector, []))


class MetadataMatchingTests(unittest.TestCase):
    def setUp(self):
        self.target = TrackTarget(
            "Lifestyles",
            "Guala",
            "Lifestyles",
            127,
        )

    def test_normalization_is_case_and_accent_insensitive(self):
        self.assertEqual(normalize_metadata("  GUÁLA! "), "guala")

    def test_exact_title_and_artist_match(self):
        matches = exact_candidates(
            self.target,
            [VisibleTrackCandidate("LIFESTYLES", "GUALA", "Lifestyles", 129)],
        )
        self.assertEqual(len(matches), 1)

    def test_partial_title_is_refused(self):
        self.assertEqual(
            exact_candidates(
                self.target,
                [VisibleTrackCandidate("Lifestyle", "Guala")],
            ),
            [],
        )

    def test_partial_artist_is_refused(self):
        self.assertEqual(
            exact_candidates(
                self.target,
                [VisibleTrackCandidate("Lifestyles", "Guala feat. X")],
            ),
            [],
        )

    def test_other_artist_is_refused(self):
        self.assertEqual(
            exact_candidates(
                self.target,
                [VisibleTrackCandidate("Lifestyles", "E-40")],
            ),
            [],
        )

    def test_duration_outside_tolerance_is_refused(self):
        self.assertEqual(
            exact_candidates(
                self.target,
                [VisibleTrackCandidate("Lifestyles", "Guala", duration_seconds=131)],
            ),
            [],
        )

    def test_file_tags_match(self):
        valid, confirmation, reason = verify_file_metadata(
            self.target,
            FileProbe("flac", 126.5, "Lifestyles", "GUALA", "Lifestyles", "flac"),
        )
        self.assertTrue(valid)
        self.assertFalse(confirmation)
        self.assertEqual(reason, "OK")

    def test_missing_tags_require_confirmation(self):
        valid, confirmation, reason = verify_file_metadata(
            self.target,
            FileProbe("flac", 127, None, None, None, "flac"),
        )
        self.assertFalse(valid)
        self.assertTrue(confirmation)
        self.assertEqual(reason, "MANUAL_FILE_CONFIRMATION_REQUIRED")

    def test_metadata_mismatch_is_refused(self):
        valid, confirmation, reason = verify_file_metadata(
            self.target,
            FileProbe("flac", 127, "Lifestyle", "Rich Gang", None, "flac"),
        )
        self.assertFalse(valid)
        self.assertFalse(confirmation)
        self.assertEqual(reason, "MANUAL_FILE_METADATA_MISMATCH")


class NavigationTests(unittest.TestCase):
    def test_query_order_is_title_then_artist(self):
        self.assertEqual(
            build_search_query(TrackTarget("Lifestyles", "Guala")),
            "Lifestyles Guala",
        )

    def test_progressive_search_field_is_unique(self):
        field = FakeInput("search")
        page = FakePage({SEARCH_SELECTORS[1]: [field]})
        self.assertIs(locate_search_input(page), field)

    def test_duplicate_selectors_for_same_field_are_deduplicated(self):
        first = FakeInput("same")
        second = FakeInput("same")
        page = FakePage(
            {
                SEARCH_SELECTORS[0]: [first],
                SEARCH_SELECTORS[1]: [second],
            }
        )
        self.assertIs(locate_search_input(page), first)

    def test_ambiguous_search_fields_are_refused(self):
        page = FakePage(
            {SEARCH_SELECTORS[0]: [FakeInput("a"), FakeInput("b")]}
        )
        with self.assertRaisesRegex(
            ValueError,
            "MONOCHROME_SEARCH_FIELD_AMBIGUOUS",
        ):
            locate_search_input(page)

    def test_exact_result_is_highlighted_without_click(self):
        row = FakeRow(
            "Lifestyles\nGUALA\n2023\n2:07",
            {"data-album": "Lifestyles"},
        )
        selected = select_exact_visible_result(
            FakePage(rows=[row]),
            TrackTarget("Lifestyles", "Guala", "Lifestyles", 127),
        )
        self.assertIs(selected.locator, row)
        self.assertTrue(row.scrolled)
        self.assertTrue(row.highlighted)
        self.assertFalse(hasattr(row, "click"))

    def test_ambiguous_exact_results_are_refused(self):
        rows = [
            FakeRow("Lifestyles\nGuala\n2:07"),
            FakeRow("Lifestyles\nGuala\n2:07"),
        ]
        with self.assertRaisesRegex(
            ValueError,
            "MONOCHROME_AMBIGUOUS_MATCH",
        ):
            select_exact_visible_result(
                FakePage(rows=rows),
                TrackTarget("Lifestyles", "Guala", duration_seconds=127),
            )

    def test_no_exact_result_is_refused(self):
        with self.assertRaisesRegex(
            ValueError,
            "MONOCHROME_NO_EXACT_MATCH",
        ):
            select_exact_visible_result(
                FakePage(rows=[FakeRow("Lifestyle\nRich Gang")]),
                TrackTarget("Lifestyles", "Guala"),
            )

    def test_source_contains_no_download_click_or_private_endpoint(self):
        module = importlib.import_module(
            "providers.monochrome_manual_provider"
        )
        source = Path(module.__file__).read_text(encoding="utf-8")
        self.assertNotIn(".click(", source)
        self.assertNotIn("context.cookies", source)
        self.assertNotIn("/api/download", source)
        self.assertNotIn("page.on(\"request", source)


class WatcherTests(unittest.TestCase):
    def test_old_file_is_ignored(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            old = root / "old.flac"
            old.write_bytes(b"x" * MIN_AUDIO_BYTES)
            stat = old.stat()
            snapshot = DownloadSnapshot(
                datetime.now(timezone.utc),
                {old.resolve(): FileFingerprint(stat.st_size, stat.st_mtime_ns)},
            )
            self.assertEqual(new_audio_candidates(root, snapshot), [])

    def test_new_audio_file_is_detected(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            snapshot = DownloadSnapshot(
                datetime.fromtimestamp(0, timezone.utc),
                {},
            )
            fresh = root / "fresh.flac"
            fresh.write_bytes(b"x" * MIN_AUDIO_BYTES)
            self.assertEqual(new_audio_candidates(root, snapshot), [fresh.resolve()])

    def test_temporary_file_is_ignored(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            snapshot = DownloadSnapshot(
                datetime.fromtimestamp(0, timezone.utc),
                {},
            )
            (root / "fresh.crdownload").write_bytes(b"x" * MIN_AUDIO_BYTES)
            self.assertEqual(new_audio_candidates(root, snapshot), [])

    def test_unstable_size_is_ignored(self):
        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "changing.flac"
            path.write_bytes(b"x" * MIN_AUDIO_BYTES)

            def mutate(_seconds):
                path.write_bytes(path.read_bytes() + b"x")

            self.assertFalse(is_stable(path, sleeper=mutate))

    def test_html_renamed_is_rejected_before_ffprobe(self):
        from providers.metadata_matching import probe_audio

        with tempfile.TemporaryDirectory() as raw:
            path = Path(raw) / "fake.flac"
            path.write_text("<!doctype html><html></html>", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "HTML"):
                probe_audio(path)


if __name__ == "__main__":
    unittest.main(verbosity=2)
