import { describe, expect, it } from 'vitest';
import { isArtworkSufficient, validatePreviewUrl } from './media-validation.js';

function fetchReturning(status: number, contentType: string | null, calls: string[] = []): typeof fetch {
  return (async (_url: string | URL, init?: { method?: string }) => {
    calls.push(init?.method ?? 'GET');
    return {
      status,
      headers: { get: (h: string) => (h.toLowerCase() === 'content-type' ? contentType : null) },
    } as unknown as Response;
  }) as typeof fetch;
}

describe('validatePreviewUrl', () => {
  it('rejette une URL non https sans appel réseau', async () => {
    const res = await validatePreviewUrl('http://x/p.m4a');
    expect(res).toMatchObject({ ok: false, reason: 'NOT_HTTPS' });
  });

  it('accepte un 200 audio via HEAD', async () => {
    const calls: string[] = [];
    const res = await validatePreviewUrl('https://x/p.m4a', {
      fetchImpl: fetchReturning(200, 'audio/mp4', calls),
    });
    expect(res.ok).toBe(true);
    expect(calls).toEqual(['HEAD']);
  });

  it('retombe sur GET Range si HEAD non supporté (405)', async () => {
    const calls: string[] = [];
    let first = true;
    const fetchImpl = (async (_u: string | URL, init?: { method?: string }) => {
      calls.push(init?.method ?? 'GET');
      const status = first ? 405 : 206;
      first = false;
      return {
        status,
        headers: { get: () => 'audio/mpeg' },
      } as unknown as Response;
    }) as typeof fetch;
    const res = await validatePreviewUrl('https://x/p.m4a', { fetchImpl });
    expect(res.ok).toBe(true);
    expect(calls).toEqual(['HEAD', 'GET']);
  });

  it('rejette un type MIME non audio', async () => {
    const res = await validatePreviewUrl('https://x/p.m4a', {
      fetchImpl: fetchReturning(200, 'text/html', []),
    });
    expect(res).toMatchObject({ ok: false, reason: 'BAD_MIME' });
  });

  it('tolère l’absence de content-type sur un 2xx', async () => {
    const res = await validatePreviewUrl('https://x/p.m4a', {
      fetchImpl: fetchReturning(200, null, []),
    });
    expect(res.ok).toBe(true);
  });

  it('échec réseau → NETWORK', async () => {
    const fetchImpl = (async () => {
      throw new Error('down');
    }) as typeof fetch;
    const res = await validatePreviewUrl('https://x/p.m4a', { fetchImpl });
    expect(res).toMatchObject({ ok: false, reason: 'NETWORK' });
  });
});

describe('isArtworkSufficient', () => {
  it('exige https + dimensions ≥ minPx', () => {
    expect(isArtworkSufficient('https://x/a.jpg', 600, 600, 500)).toBe(true);
    expect(isArtworkSufficient('https://x/a.jpg', 400, 600, 500)).toBe(false);
    expect(isArtworkSufficient('http://x/a.jpg', 600, 600, 500)).toBe(false);
    expect(isArtworkSufficient(null, 600, 600, 500)).toBe(false);
    expect(isArtworkSufficient('https://x/a.jpg', null, null, 500)).toBe(false);
  });
});
