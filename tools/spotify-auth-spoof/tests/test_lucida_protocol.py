from __future__ import annotations

import importlib.util
import io
import json
import os
import subprocess
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'lucida_dl_final.py'


def load_module():
    spec = importlib.util.spec_from_file_location('lucida_protocol_under_test', SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f'Impossible de charger {SCRIPT}')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_cli(*args: str) -> subprocess.CompletedProcess[str]:
    """
    Lance le script comme le fera le backend : flux texte UTF-8 strict.

    PYTHONIOENCODING est aussi transmis comme ce sera le cas côté Node. Le
    script v10.1 se configure lui-même, mais cette variable rend le contrat du
    test explicite et protège les anciennes versions de Python sous Windows.
    """
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    env["PYTHONUTF8"] = "1"

    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="strict",
        env=env,
        check=False,
    )


class LucidaProtocolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_module()

    def test_emit_event_produces_one_valid_utf8_json_line(self) -> None:
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            self.module.emit_event({
                'type': 'stage',
                'stage': 'searching',
                'message': 'Recherche de l’artiste Émilie',
            })

        lines = buffer.getvalue().splitlines()
        self.assertEqual(len(lines), 1)
        payload = json.loads(lines[0])
        self.assertEqual(payload['type'], 'stage')
        self.assertEqual(payload['message'], 'Recherche de l’artiste Émilie')
        self.assertIn('Émilie', lines[0])

    def test_canonical_title_accepts_track_number_and_explicit_badge(self) -> None:
        self.assertEqual(self.module.canonical_title('1. creeper'), 'creeper')
        self.assertEqual(self.module.canonical_title('Creeper Explicit'), 'creeper')
        self.assertEqual(self.module.canonical_title('Creeper E'), 'creeper')

    def test_canonical_title_rejects_partial_wrong_song(self) -> None:
        self.assertNotEqual(
            self.module.canonical_title('Midnight Creeper'),
            self.module.canonical_title('creeper'),
        )

    def test_release_normalization(self) -> None:
        self.assertEqual(
            self.module.canonical_release_name('creeper + seed E 2025'),
            'creeper seed',
        )
        self.assertEqual(
            self.module.canonical_release_name('Album creeper + seed Explicit'),
            'creeper seed',
        )

    def test_exact_artist_does_not_accept_luther_allison(self) -> None:
        self.assertTrue(self.module.context_has_exact_artist('by Luther', 'Luther'))
        self.assertFalse(
            self.module.context_has_exact_artist(
                'Midnight Creeper\nLuther Allison',
                'Luther',
            )
        )

    def test_invalid_timeout_json_is_machine_readable_without_network(self) -> None:
        result = run_cli(
            'Test',
            '--json',
            '--download-timeout',
            '5',
        )
        self.assertEqual(result.returncode, 2)
        stdout_lines = [line for line in result.stdout.splitlines() if line.strip()]
        self.assertEqual(len(stdout_lines), 1)
        event = json.loads(stdout_lines[0])
        self.assertEqual(event['type'], 'error')
        self.assertEqual(event['code'], 'INVALID_ARGUMENT')
        self.assertNotIn('Traceback', result.stdout)
        self.assertIsInstance(result.stderr, str)

    def test_non_qobuz_service_is_rejected_without_network(self) -> None:
        result = run_cli(
            'Test',
            '--json',
            '--service',
            'Deezer',
        )
        self.assertEqual(result.returncode, 2)
        events = [json.loads(line) for line in result.stdout.splitlines() if line.strip()]
        self.assertEqual(events[-1]['code'], 'INVALID_ARGUMENT')
        self.assertIsInstance(result.stderr, str)


if __name__ == '__main__':
    unittest.main(verbosity=2)
