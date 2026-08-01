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

    def test_403_cf_mitigated_is_provider_challenge(self) -> None:
        event = self.module.classify_initial_provider_response(
            403,
            {'Cf-Mitigated': 'ChAlLeNgE'},
            '',
        )
        self.assertEqual(event['code'], 'PROVIDER_CHALLENGE')
        self.assertFalse(event['retryable'])

    def test_403_security_page_is_provider_challenge(self) -> None:
        event = self.module.classify_initial_provider_response(
            403,
            {},
            'Performing security verification',
        )
        self.assertEqual(event['code'], 'PROVIDER_CHALLENGE')

    def test_ordinary_403_is_generic_http_error(self) -> None:
        event = self.module.classify_initial_provider_response(
            403,
            {},
            'Forbidden',
        )
        self.assertEqual(event['code'], 'PROVIDER_HTTP_ERROR')

    def test_429_uses_numeric_retry_after(self) -> None:
        event = self.module.classify_initial_provider_response(
            429,
            {'Retry-After': '1200'},
            '',
        )
        self.assertEqual(event['code'], 'PROVIDER_RATE_LIMITED')
        self.assertEqual(event['retryAfterSeconds'], 1200)

    def test_429_invalid_retry_after_uses_prudent_default(self) -> None:
        event = self.module.classify_initial_provider_response(
            429,
            {'Retry-After': 'pas-une-date'},
            '',
        )
        self.assertEqual(event['retryAfterSeconds'], 900)

    def test_503_is_provider_unavailable(self) -> None:
        event = self.module.classify_initial_provider_response(503, {}, '')
        self.assertEqual(event['code'], 'PROVIDER_UNAVAILABLE')

    def test_200_has_no_provider_error(self) -> None:
        self.assertIsNone(
            self.module.classify_initial_provider_response(200, {}, ''),
        )

    def test_security_marker_is_detected_even_with_http_200(self) -> None:
        event = self.module.classify_initial_provider_response(
            200,
            {},
            'Verify you are human',
        )
        self.assertEqual(event['code'], 'PROVIDER_CHALLENGE')

    def test_explicit_search_page_error_is_not_mapped_to_search_failed(self) -> None:
        clock = FakeClock()
        page = FakeVerificationPage([
            ready_observation(body=(
                "uh-oh! An error occurred. Unexpected token '<' "
                "is not valid JSON"
            )),
        ], clock)

        event = self.module.classify_search_wait_failure(page)

        self.assertEqual(event['code'], 'LUCIDA_ERROR')
        self.assertEqual(event['provider'], 'Lucida')
        self.assertNotIn('<html', event['message'])

    def test_search_page_challenge_keeps_provider_challenge_code(self) -> None:
        clock = FakeClock()
        page = FakeVerificationPage([
            ready_observation(body='Performing security verification'),
        ], clock)

        event = self.module.classify_search_wait_failure(page)

        self.assertEqual(event['code'], 'PROVIDER_CHALLENGE')
        self.assertFalse(event['retryable'])

    def test_provider_event_is_valid_ndjson_without_human_stdout(self) -> None:
        event = self.module.classify_initial_provider_response(
            403,
            {'cf-mitigated': 'challenge'},
            '',
        )
        buffer = io.StringIO()
        with redirect_stdout(buffer):
            self.module.emit_event(event)
        lines = buffer.getvalue().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertEqual(json.loads(lines[0]), event)
        self.assertNotIn('HTTP', lines[0])
        self.assertNotIn('<html', lines[0].lower())

    def test_challenge_classification_does_not_retry_or_resolve(self) -> None:
        calls = {'count': 0}

        def forbidden_network_call():
            calls['count'] += 1

        event = self.module.classify_initial_provider_response(
            403,
            {'cf-mitigated': 'challenge'},
            'Verify you are human',
        )
        self.assertEqual(event['code'], 'PROVIDER_CHALLENGE')
        self.assertEqual(calls['count'], 0)

    def test_interactive_mode_requires_visible_without_network(self) -> None:
        result = run_cli(
            'Test',
            '--json',
            '--interactive-verification',
        )
        self.assertEqual(result.returncode, 2)
        events = [
            json.loads(line)
            for line in result.stdout.splitlines()
            if line.strip()
        ]
        self.assertEqual(events, [{
            'type': 'error',
            'code': 'INVALID_ARGUMENT',
            'message': '--interactive-verification exige --visible',
        }])

    def test_verification_timeout_bounds_without_network(self) -> None:
        result = run_cli(
            'Test',
            '--json',
            '--visible',
            '--interactive-verification',
            '--verification-timeout',
            '29',
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(
            json.loads(result.stdout.splitlines()[0])['code'],
            'INVALID_ARGUMENT',
        )


class FakeClock:
    def __init__(self) -> None:
        self.value = 0.0

    def __call__(self) -> float:
        return self.value

    def advance(self, milliseconds: int) -> None:
        self.value += milliseconds / 1000


class FakeLocator:
    def __init__(self, page, kind: str) -> None:
        self.page = page
        self.kind = kind

    @property
    def first(self):
        return self

    def count(self) -> int:
        return 1 if self.page.current.get(f'{self.kind}_exists', False) else 0

    def is_visible(self) -> bool:
        return bool(self.page.current.get(f'{self.kind}_visible', False))

    def is_enabled(self) -> bool:
        return bool(self.page.current.get(f'{self.kind}_enabled', False))

    def inner_text(self, timeout=None) -> str:
        del timeout
        return str(self.page.current.get('body', ''))

    def click(self):
        self.page.clicks += 1

    def fill(self, _value):
        self.page.fills += 1


class FakeVerificationPage:
    def __init__(self, observations, clock: FakeClock) -> None:
        self.observations = observations
        self.index = 0
        self.clock = clock
        self.clicks = 0
        self.fills = 0
        self.reloads = 0
        self.locator_calls = []

    @property
    def current(self):
        return self.observations[min(self.index, len(self.observations) - 1)]

    @property
    def url(self) -> str:
        return str(self.current.get('url', 'https://lucida.to/'))

    def locator(self, selector: str):
        self.locator_calls.append(selector)
        if selector == 'body':
            return FakeLocator(self, 'body')
        if 'input#download' in selector:
            return FakeLocator(self, 'search')
        return FakeLocator(self, 'go')

    def wait_for_timeout(self, milliseconds: int) -> None:
        self.clock.advance(milliseconds)
        if self.index < len(self.observations) - 1:
            self.index += 1

    def reload(self):
        self.reloads += 1


def ready_observation(**overrides):
    value = {
        'url': 'https://lucida.to/',
        'body': 'Lucida search',
        'body_exists': True,
        'body_visible': True,
        'body_enabled': True,
        'search_exists': True,
        'search_visible': True,
        'search_enabled': True,
        'go_exists': True,
        'go_visible': True,
        'go_enabled': True,
    }
    value.update(overrides)
    return value


class ManualProviderVerificationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_module()

    def wait(self, observations, timeout=3):
        clock = FakeClock()
        page = FakeVerificationPage(observations, clock)
        events = []
        result = self.module.wait_for_manual_provider_verification(
            page,
            timeout,
            events.append,
            monotonic=clock,
        )
        return result, page, events

    def test_waiting_event_is_structured_ndjson_compatible(self) -> None:
        result, _page, events = self.wait([
            ready_observation(),
            ready_observation(),
        ])
        self.assertTrue(result)
        self.assertEqual(events, [{
            'type': 'stage',
            'stage': 'waiting_user_verification',
            'message': 'Une vérification manuelle est nécessaire dans Chromium.',
            'provider': 'Lucida',
        }])
        json.dumps(events[0], ensure_ascii=False)

    def test_wait_is_strictly_passive(self) -> None:
        result, page, _events = self.wait([
            ready_observation(),
            ready_observation(),
        ])
        self.assertTrue(result)
        self.assertEqual(page.clicks, 0)
        self.assertEqual(page.fills, 0)
        self.assertEqual(page.reloads, 0)

    def test_missing_form_keeps_waiting_until_timeout(self) -> None:
        result, _page, _events = self.wait([
            ready_observation(
                search_exists=False,
                search_visible=False,
                search_enabled=False,
            ),
        ], timeout=2)
        self.assertFalse(result)

    def test_one_ready_observation_is_not_enough(self) -> None:
        result, _page, _events = self.wait([
            ready_observation(),
            ready_observation(search_visible=False),
        ], timeout=2)
        self.assertFalse(result)

    def test_two_ready_observations_resume(self) -> None:
        result, page, _events = self.wait([
            ready_observation(),
            ready_observation(),
        ])
        self.assertTrue(result)
        self.assertGreaterEqual(page.clock.value, 1.0)

    def test_persistent_challenge_marker_never_resumes(self) -> None:
        result, _page, _events = self.wait([
            ready_observation(body='Verify you are human'),
        ], timeout=2)
        self.assertFalse(result)

    def test_other_domain_is_rejected(self) -> None:
        result, _page, _events = self.wait([
            ready_observation(url='https://example.com/'),
            ready_observation(url='https://example.com/'),
        ], timeout=2)
        self.assertFalse(result)

    def test_timeout_returns_false_without_terminal_error(self) -> None:
        result, _page, events = self.wait([
            ready_observation(search_exists=False),
        ], timeout=1)
        self.assertFalse(result)
        self.assertEqual(events[0]['stage'], 'waiting_user_verification')
        self.assertFalse(any(event['type'] == 'error' for event in events))

    def test_cancellation_propagates_without_page_action(self) -> None:
        clock = FakeClock()
        page = FakeVerificationPage([ready_observation()], clock)

        def cancel(_milliseconds):
            raise KeyboardInterrupt()

        page.wait_for_timeout = cancel
        with self.assertRaises(KeyboardInterrupt):
            self.module.wait_for_manual_provider_verification(
                page,
                3,
                None,
                monotonic=clock,
            )
        self.assertEqual(page.clicks, 0)
        self.assertEqual(page.fills, 0)
        self.assertEqual(page.reloads, 0)

    def test_form_locators_can_be_recreated_after_validation(self) -> None:
        result, page, _events = self.wait([
            ready_observation(),
            ready_observation(),
        ])
        self.assertTrue(result)
        calls_after_wait = len(page.locator_calls)
        search, go = self.module.provider_form_controls(page)
        self.assertTrue(search.is_visible())
        self.assertTrue(go.is_enabled())
        self.assertEqual(len(page.locator_calls), calls_after_wait + 2)


if __name__ == '__main__':
    unittest.main(verbosity=2)
