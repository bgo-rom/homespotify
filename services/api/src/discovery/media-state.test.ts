import { describe, expect, it } from 'vitest';
import { canTransition, isMediaReady, shouldResolveMedia } from './media-state.js';

describe('machine à états média', () => {
  it('autorise le cycle nominal, interdit les sauts illégaux', () => {
    expect(canTransition('DISCOVERED', 'MEDIA_RESOLVING')).toBe(true);
    expect(canTransition('MEDIA_RESOLVING', 'MEDIA_READY')).toBe(true);
    expect(canTransition('MEDIA_RESOLVING', 'MEDIA_UNAVAILABLE')).toBe(true);
    expect(canTransition('MEDIA_READY', 'MEDIA_RESOLVING')).toBe(true); // ré-résolution
    // Un état terminal négatif ne revient jamais.
    expect(canTransition('PERMANENTLY_REJECTED', 'MEDIA_RESOLVING')).toBe(false);
    expect(canTransition('DISCOVERED', 'MEDIA_READY')).toBe(false); // saute la résolution
  });

  it('shouldResolveMedia : neuf oui, prêt non, en cours non, rejeté non', () => {
    const now = 1_000_000_000_000;
    const ttl = 3600_000;
    expect(shouldResolveMedia('DISCOVERED', null, now, ttl)).toBe(true);
    expect(shouldResolveMedia('IDENTITY_RESOLVED', null, now, ttl)).toBe(true);
    expect(shouldResolveMedia('MEDIA_READY', new Date(now).toISOString(), now, ttl)).toBe(false);
    expect(shouldResolveMedia('MEDIA_RESOLVING', null, now, ttl)).toBe(false);
    expect(shouldResolveMedia('PERMANENTLY_REJECTED', null, now, ttl)).toBe(false);
  });

  it('un négatif redevient éligible après expiration du TTL', () => {
    const now = 1_000_000_000_000;
    const ttl = 3600_000;
    const fresh = new Date(now - 1000).toISOString();
    const stale = new Date(now - ttl - 1000).toISOString();
    expect(shouldResolveMedia('MEDIA_UNAVAILABLE', fresh, now, ttl)).toBe(false);
    expect(shouldResolveMedia('MEDIA_UNAVAILABLE', stale, now, ttl)).toBe(true);
    expect(shouldResolveMedia('RETRYABLE_ERROR', stale, now, ttl)).toBe(true);
  });

  it('isMediaReady', () => {
    expect(isMediaReady('MEDIA_READY')).toBe(true);
    expect(isMediaReady('DISCOVERED')).toBe(false);
  });
});
