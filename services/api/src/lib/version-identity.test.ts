import { describe, expect, it } from 'vitest';
import {
  hasAltVersionMarker,
  sameVersion,
  versionFingerprint,
} from './version-identity.js';

describe('version-identity', () => {
  it('donne une empreinte vide à une version studio', () => {
    expect(versionFingerprint('addiction')).toBe('');
    expect(versionFingerprint('LONOWN addiction')).toBe('');
    expect(versionFingerprint(null, undefined, '')).toBe('');
  });

  it('reconnaît la famille vitesse/tonalité absente de l’ancien motif de fusion', () => {
    expect(versionFingerprint('addiction (Slowed)')).toBe('slowed');
    expect(versionFingerprint('addiction (Sped Up)')).toBe('sped up');
    expect(versionFingerprint('addiction (Speed Up)')).toBe('speed up');
    expect(versionFingerprint('addiction - Nightcore')).toBe('nightcore');
    expect(versionFingerprint('addiction (Slowed + Reverb)')).toBe('slowed + reverb');
  });

  it('sépare une variante longue de sa variante courte', () => {
    expect(versionFingerprint('addiction (Ultra Slowed)')).toBe('ultra slowed');
    expect(
      sameVersion(
        versionFingerprint('addiction (Ultra Slowed)'),
        versionFingerprint('addiction (Slowed)'),
      ),
    ).toBe(false);
  });

  it('conserve les marqueurs historiques', () => {
    expect(versionFingerprint('Song (Live)')).toBe('live');
    expect(versionFingerprint('Song (Remix)')).toBe('remix');
    expect(versionFingerprint('Song', 'Unplugged Sessions')).toBe('unplugged');
  });

  it('est insensible à l’ordre, à la casse et aux espaces multiples', () => {
    expect(versionFingerprint('Song (LIVE) (Remix)')).toBe(
      versionFingerprint('Song (remix) [live]'),
    );
    expect(versionFingerprint('Song (Sped   Up)')).toBe('sped up');
  });

  it('refuse d’assimiler studio et version alternative, dans les deux sens', () => {
    const studio = versionFingerprint('addiction');
    const slowed = versionFingerprint('addiction (Slowed)');
    expect(sameVersion(studio, slowed)).toBe(false);
    expect(sameVersion(slowed, studio)).toBe(false);
    expect(sameVersion(studio, versionFingerprint('addiction'))).toBe(true);
  });

  it('expose la détection simple utilisée par le scoring', () => {
    expect(hasAltVersionMarker('addiction (Slowed)')).toBe(true);
    expect(hasAltVersionMarker('addiction')).toBe(false);
  });
});
