import { describe, expect, it } from 'vitest';
import {
  buildSignedHeaders as buildAgentHeaders,
  canonicalString as agentCanonicalString,
  signCanonical as signAgentCanonical,
} from '../../../../storage-agent/src/hmac-auth.js';
import {
  EMPTY_BODY_SHA256,
  buildSignedHeaders,
  canonicalString,
  generateNonce,
  signCanonical,
} from './hmac-client.js';

const VECTOR = {
  secret: '0123456789abcdef0123456789abcdef',
  method: 'head',
  pathWithQuery: '/internal/storage/tracks/158?probe=phase4',
  timestamp: 1_785_000_000,
  nonce: '0123456789abcdef0123456789abcdef',
  contentSha256: EMPTY_BODY_SHA256,
};

describe('client HMAC du Storage Agent', () => {
  it('rejoue exactement le même vecteur que l’implémentation serveur', () => {
    expect(canonicalString(VECTOR)).toBe(agentCanonicalString(VECTOR));
    expect(signCanonical(VECTOR.secret, VECTOR)).toBe(
      signAgentCanonical(VECTOR.secret, VECTOR),
    );
  });

  it('produit les mêmes headers déterministes que le serveur', () => {
    const options = {
      secret: VECTOR.secret,
      method: VECTOR.method,
      pathWithQuery: VECTOR.pathWithQuery,
      timestamp: VECTOR.timestamp,
      nonce: VECTOR.nonce,
      requestId: 'public-request-42',
    };
    expect(buildSignedHeaders(options)).toEqual(buildAgentHeaders(options));
  });

  it('inclut méthode, query, timestamp, nonce et hash du corps vide', () => {
    const headers = buildSignedHeaders({
      secret: VECTOR.secret,
      method: 'GET',
      pathWithQuery: '/internal/storage/health?full=1',
      timestamp: VECTOR.timestamp,
      nonce: VECTOR.nonce,
    });
    expect(headers['x-hs-timestamp']).toBe(String(VECTOR.timestamp));
    expect(headers['x-hs-nonce']).toBe(VECTOR.nonce);
    expect(headers['x-hs-content-sha256']).toBe(EMPTY_BODY_SHA256);
    expect(headers['x-hs-signature']).toMatch(/^[0-9a-f]{64}$/);
    expect(
      buildSignedHeaders({
        secret: VECTOR.secret,
        method: 'HEAD',
        pathWithQuery: '/internal/storage/health?full=1',
        timestamp: VECTOR.timestamp,
        nonce: VECTOR.nonce,
      })['x-hs-signature'],
    ).not.toBe(headers['x-hs-signature']);
  });

  it('génère un nonce cryptographique de 256 bits distinct', () => {
    const first = generateNonce();
    const second = generateNonce();
    expect(first.length).toBeGreaterThanOrEqual(22);
    expect(second).not.toBe(first);
  });

  it('une query ou un mauvais secret change la signature', () => {
    const base = signCanonical(VECTOR.secret, VECTOR);
    expect(
      signCanonical(VECTOR.secret, {
        ...VECTOR,
        pathWithQuery: '/internal/storage/tracks/158?probe=autre',
      }),
    ).not.toBe(base);
    expect(signCanonical('x'.repeat(32), VECTOR)).not.toBe(base);
  });
});
