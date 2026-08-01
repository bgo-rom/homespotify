import { describe, expect, it } from 'vitest';
import type { DownloadCandidate } from './candidate-resolver.js';
import {
  DownloadCandidateOrchestrator,
  isFallbackEligible,
} from './candidate-orchestrator.js';

function candidate(provider: string, url: string, sourceRank = 50): DownloadCandidate {
  return {
    provider: provider as DownloadCandidate['provider'],
    url,
    title: 'Lifestyles',
    artist: 'Guala',
    album: 'Lifestyles',
    durationSeconds: 180,
    isrc: null,
    confidence: 80,
    sourceRank,
  artworkUrl: null,
  };
}

describe('isFallbackEligible', () => {
  it('autorise le repli sur les échecs TECHNIQUES d’une source', () => {
    for (const code of [
      'ATTEMPT_TIMEOUT', // délai de métadonnées / miroir muet
      'ANTRA_SUMMARY_ERROR', // miroir indisponible, source non disponible
      'ANTRA_TRACK_FAILED',
      'ENGINE_EXIT_ERROR', // authentification provider absente
      'NO_TRACK_DOWNLOADED', // aucun fichier produit
      'NO_FILE_DETECTED',
      'EXCERPT_TOO_SHORT', // extrait incomplet
      'UNREADABLE',
    ]) {
      expect(isFallbackEligible(code), code).toBe(true);
    }
  });

  it('interdit le repli après une annulation utilisateur', () => {
    expect(isFallbackEligible('CANCELLED')).toBe(false);
  });

  it('interdit le repli quand le problème est local ou serveur', () => {
    for (const code of [
      'SPAWN_FAILED',
      'TIMEOUT',
      'INTERNAL_ERROR',
      'LOCAL_IMPORT_FAILED',
      'LOCAL_IMPORT_REVIEW_REQUIRED',
      'LOCAL_IMPORT_TRACK_MISSING',
    ]) {
      expect(isFallbackEligible(code), code).toBe(false);
    }
  });

  it('interdit le repli sans code d’erreur connu', () => {
    expect(isFallbackEligible(null)).toBe(false);
    expect(isFallbackEligible('CODE_INCONNU')).toBe(false);
  });
});

describe('DownloadCandidateOrchestrator', () => {
  const far = Date.now() + 60_000;

  it('parcourt les candidats dans l’ordre reçu', () => {
    const orchestrator = new DownloadCandidateOrchestrator(
      [
        candidate('spotify', 'https://open.spotify.com/track/1'),
        candidate('deezer', 'https://www.deezer.com/track/2'),
      ],
      { deadlineAt: far },
    );

    const first = orchestrator.next({ cancelled: false, lastErrorCode: null });
    expect(first.candidate?.provider).toBe('spotify');
    orchestrator.beginAttempt(first.candidate!, new Date().toISOString());

    const second = orchestrator.next({
      cancelled: false,
      lastErrorCode: 'ATTEMPT_TIMEOUT',
    });
    expect(second.candidate?.provider).toBe('deezer');
  });

  it('ne rejoue jamais deux fois la même URL', () => {
    const url = 'https://open.spotify.com/track/1';
    const orchestrator = new DownloadCandidateOrchestrator(
      [candidate('spotify', url), candidate('itunes', url)],
      { deadlineAt: far },
    );

    const first = orchestrator.next({ cancelled: false, lastErrorCode: null });
    orchestrator.beginAttempt(first.candidate!, new Date().toISOString());
    const second = orchestrator.next({
      cancelled: false,
      lastErrorCode: 'NO_FILE_DETECTED',
    });
    expect(second.candidate).toBeNull();
    expect(second.stopReason).toBe('exhausted');
  });

  it('s’arrête sur annulation, sans essayer le candidat suivant', () => {
    const orchestrator = new DownloadCandidateOrchestrator(
      [
        candidate('spotify', 'https://open.spotify.com/track/1'),
        candidate('deezer', 'https://www.deezer.com/track/2'),
      ],
      { deadlineAt: far },
    );
    const first = orchestrator.next({ cancelled: false, lastErrorCode: null });
    orchestrator.beginAttempt(first.candidate!, new Date().toISOString());

    const decision = orchestrator.next({ cancelled: true, lastErrorCode: 'CANCELLED' });
    expect(decision.candidate).toBeNull();
    expect(decision.stopReason).toBe('cancelled');
  });

  it('s’arrête quand l’erreur n’autorise pas le repli', () => {
    const orchestrator = new DownloadCandidateOrchestrator(
      [
        candidate('spotify', 'https://open.spotify.com/track/1'),
        candidate('deezer', 'https://www.deezer.com/track/2'),
      ],
      { deadlineAt: far },
    );
    const first = orchestrator.next({ cancelled: false, lastErrorCode: null });
    orchestrator.beginAttempt(first.candidate!, new Date().toISOString());

    const decision = orchestrator.next({
      cancelled: false,
      lastErrorCode: 'LOCAL_IMPORT_FAILED',
    });
    expect(decision.stopReason).toBe('not_eligible');
  });

  it('respecte le délai GLOBAL même si des candidats restent', () => {
    let clock = 0;
    const orchestrator = new DownloadCandidateOrchestrator(
      [
        candidate('spotify', 'https://open.spotify.com/track/1'),
        candidate('deezer', 'https://www.deezer.com/track/2'),
      ],
      { deadlineAt: 1_000, now: () => clock },
    );
    const first = orchestrator.next({ cancelled: false, lastErrorCode: null });
    expect(first.candidate).not.toBeNull();
    orchestrator.beginAttempt(first.candidate!, new Date().toISOString());

    clock = 1_500;
    const decision = orchestrator.next({
      cancelled: false,
      lastErrorCode: 'ATTEMPT_TIMEOUT',
    });
    expect(decision.candidate).toBeNull();
    expect(decision.stopReason).toBe('global_timeout');
    expect(orchestrator.remainingCount()).toBeGreaterThan(0);
  });

  it('conserve l’historique ordonné des tentatives et de leurs codes', () => {
    const orchestrator = new DownloadCandidateOrchestrator(
      [
        candidate('spotify', 'https://open.spotify.com/track/1'),
        candidate('deezer', 'https://www.deezer.com/track/2'),
      ],
      { deadlineAt: far },
    );

    const first = orchestrator.next({ cancelled: false, lastErrorCode: null });
    const firstOrder = orchestrator.beginAttempt(first.candidate!, '2026-08-01T10:00:00Z');
    orchestrator.endAttempt(firstOrder, 'failed', 'ATTEMPT_TIMEOUT', '2026-08-01T10:01:00Z');

    const second = orchestrator.next({
      cancelled: false,
      lastErrorCode: 'ATTEMPT_TIMEOUT',
    });
    const secondOrder = orchestrator.beginAttempt(second.candidate!, '2026-08-01T10:01:00Z');
    orchestrator.endAttempt(secondOrder, 'succeeded', null, '2026-08-01T10:02:00Z');

    const history = orchestrator.history();
    expect(history).toHaveLength(2);
    expect(history[0]).toMatchObject({
      order: 1,
      provider: 'spotify',
      outcome: 'failed',
      errorCode: 'ATTEMPT_TIMEOUT',
    });
    expect(history[1]).toMatchObject({
      order: 2,
      provider: 'deezer',
      outcome: 'succeeded',
      errorCode: null,
    });
    // Aucun secret, aucun chemin serveur dans l'historique persisté.
    const serialized = JSON.stringify(history);
    expect(serialized).not.toMatch(/[A-Za-z]:\\/);
    expect(serialized).not.toMatch(/token|secret|api[_-]?key/i);
  });

  it('épuise proprement une liste vide', () => {
    const orchestrator = new DownloadCandidateOrchestrator([], { deadlineAt: far });
    expect(
      orchestrator.next({ cancelled: false, lastErrorCode: null }).stopReason,
    ).toBe('exhausted');
  });
});
