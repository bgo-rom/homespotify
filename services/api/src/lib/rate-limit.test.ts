import { describe, it, expect } from 'vitest';
import type { FastifyReply, FastifyRequest } from 'fastify';
import { createRateLimiter, clientKey } from './rate-limit.js';

/** Fabrique une requête minimale suffisante pour le limiteur. */
function fakeRequest(options: {
  ip?: string;
  forwardedFor?: string | string[];
}): FastifyRequest {
  const headers: Record<string, string | string[] | undefined> = {};
  if (options.forwardedFor !== undefined) headers['x-forwarded-for'] = options.forwardedFor;
  return {
    headers,
    socket: { remoteAddress: options.ip ?? '127.0.0.1' },
  } as unknown as FastifyRequest;
}

/** Reply minimal qui capture le code et les en-têtes émis. */
function fakeReply(): FastifyReply & { _code: number | null; _headers: Record<string, string> } {
  const reply = {
    _code: null as number | null,
    _headers: {} as Record<string, string>,
    header(name: string, value: string) {
      reply._headers[name] = value;
      return reply;
    },
    code(status: number) {
      reply._code = status;
      return reply;
    },
    send() {
      return reply;
    },
  };
  return reply as unknown as FastifyReply & { _code: number | null; _headers: Record<string, string> };
}

describe('createRateLimiter', () => {
  it('laisse passer jusqu’au seuil puis répond 429 avec Retry-After', async () => {
    let nowMs = 1_000_000;
    const limiter = createRateLimiter({ windowMs: 10_000, max: 3 }, { now: () => nowMs });
    const request = fakeRequest({ ip: '203.0.113.7' });

    for (let i = 0; i < 3; i += 1) {
      const reply = fakeReply();
      await limiter(request, reply);
      expect(reply._code).toBeNull(); // pas de blocage sous le seuil
    }

    const blocked = fakeReply();
    await limiter(request, blocked);
    expect(blocked._code).toBe(429);
    expect(Number(blocked._headers['retry-after'])).toBeGreaterThan(0);
  });

  it('réinitialise le compteur après la fenêtre', async () => {
    let nowMs = 0;
    const limiter = createRateLimiter({ windowMs: 5_000, max: 1 }, { now: () => nowMs });
    const request = fakeRequest({ ip: '198.51.100.4' });

    const first = fakeReply();
    await limiter(request, first);
    expect(first._code).toBeNull();

    const second = fakeReply();
    await limiter(request, second);
    expect(second._code).toBe(429);

    // Fenêtre écoulée : le quota repart de zéro.
    nowMs += 5_001;
    const third = fakeReply();
    await limiter(request, third);
    expect(third._code).toBeNull();
  });

  it('compte chaque IP séparément', async () => {
    const limiter = createRateLimiter({ windowMs: 10_000, max: 1 });

    const a1 = fakeReply();
    await limiter(fakeRequest({ ip: '10.0.0.1' }), a1);
    expect(a1._code).toBeNull();

    // Une IP distincte n'est pas affectée par le quota de la première.
    const b1 = fakeReply();
    await limiter(fakeRequest({ ip: '10.0.0.2' }), b1);
    expect(b1._code).toBeNull();

    // Deuxième requête de la première IP : bloquée.
    const a2 = fakeReply();
    await limiter(fakeRequest({ ip: '10.0.0.1' }), a2);
    expect(a2._code).toBe(429);
  });
});

describe('clientKey', () => {
  it('retient la DERNIÈRE entrée X-Forwarded-For (non falsifiable derrière Caddy)', () => {
    // Un client qui pré-remplit XFF insère "1.1.1.1" ; Caddy appose l'IP réelle
    // en dernier. On doit retenir cette dernière valeur, pas celle du client.
    const request = fakeRequest({
      ip: '127.0.0.1',
      forwardedFor: '1.1.1.1, 203.0.113.9',
    });
    expect(clientKey(request)).toBe('203.0.113.9');
  });

  it('retombe sur l’adresse de la socket sans en-tête', () => {
    expect(clientKey(fakeRequest({ ip: '192.0.2.50' }))).toBe('192.0.2.50');
  });
});
