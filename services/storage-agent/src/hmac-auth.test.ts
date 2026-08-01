import { describe, expect, it } from 'vitest';
import {
  buildSignedHeaders,
  canonicalString,
  EMPTY_BODY_SHA256,
  generateNonce,
  HEADER_CONTENT_SHA256,
  HEADER_NONCE,
  HEADER_SIGNATURE,
  HEADER_TIMESTAMP,
  HmacVerifier,
  NonceCache,
  sha256Hex,
  signCanonical,
} from './hmac-auth.js';

const SECRET = 'c'.repeat(64);
const PATH = '/internal/storage/tracks/1';

function verifier(nowMs: number, cache = new NonceCache(120_000)): HmacVerifier {
  return new HmacVerifier({
    secret: SECRET,
    maxClockSkewSeconds: 60,
    nonceCache: cache,
    now: () => nowMs,
  });
}

function headersFor(
  overrides: Partial<Record<string, string>> = {},
  options: { secret?: string; method?: string; path?: string; timestamp?: number } = {},
): Record<string, string | string[] | undefined> {
  const built = buildSignedHeaders({
    secret: options.secret ?? SECRET,
    method: options.method ?? 'GET',
    pathWithQuery: options.path ?? PATH,
    ...(options.timestamp !== undefined ? { timestamp: options.timestamp } : {}),
  });
  return { ...built, ...overrides };
}

describe('canonicalString', () => {
  it('sépare les cinq éléments par \\n et normalise la méthode', () => {
    expect(
      canonicalString({
        method: 'get',
        pathWithQuery: '/a?b=1',
        timestamp: 42,
        nonce: 'N',
        contentSha256: 'AB',
      }),
    ).toBe(['GET', '/a?b=1', '42', 'N', 'ab'].join('\n'));
  });

  it('SHA-256 du corps vide = constante attendue', () => {
    expect(sha256Hex('')).toBe(EMPTY_BODY_SHA256);
  });
});

describe('generateNonce', () => {
  it('produit au moins 128 bits d’aléa', () => {
    const nonce = generateNonce();
    // base64url de 32 octets = 43 caractères, bien au-delà des 22 minimum.
    expect(nonce.length).toBeGreaterThanOrEqual(22);
    expect(generateNonce()).not.toBe(nonce);
  });
});

describe('HmacVerifier', () => {
  const nowMs = 1_800_000_000_000;
  const nowSeconds = Math.floor(nowMs / 1000);

  function verify(
    headers: Record<string, string | string[] | undefined>,
    options: { method?: string; path?: string; cache?: NonceCache; at?: number } = {},
  ) {
    return verifier(options.at ?? nowMs, options.cache).verify({
      method: options.method ?? 'GET',
      pathWithQuery: options.path ?? PATH,
      headers,
      bodySha256: EMPTY_BODY_SHA256,
    });
  }

  it('accepte une signature valide', () => {
    expect(verify(headersFor({}, { timestamp: nowSeconds }))).toEqual({ ok: true });
  });

  it('refuse une signature altérée', () => {
    const headers = headersFor({}, { timestamp: nowSeconds });
    const signature = String(headers[HEADER_SIGNATURE]);
    // Un seul caractère change : longueur identique, comparaison à temps constant.
    const flipped = (signature[0] === '0' ? '1' : '0') + signature.slice(1);
    const result = verify({ ...headers, [HEADER_SIGNATURE]: flipped });
    expect(result).toEqual({ ok: false, code: 'AUTH_INVALID', reason: 'signature invalide' });
  });

  it('refuse un secret incorrect', () => {
    const headers = headersFor({}, { secret: 'd'.repeat(64), timestamp: nowSeconds });
    expect(verify(headers)).toMatchObject({ ok: false, code: 'AUTH_INVALID' });
  });

  it('refuse une signature de taille différente sans lever', () => {
    // `timingSafeEqual` lève sur des longueurs inégales : la taille doit être
    // validée AVANT la comparaison.
    const headers = headersFor({ [HEADER_SIGNATURE]: 'abcd' }, { timestamp: nowSeconds });
    expect(verify(headers)).toMatchObject({
      ok: false,
      reason: 'signature de format invalide',
    });
  });

  it('refuse un horodatage expiré', () => {
    const headers = headersFor({}, { timestamp: nowSeconds - 61 });
    expect(verify(headers)).toMatchObject({ ok: false, code: 'AUTH_EXPIRED' });
  });

  it('refuse un horodatage dans le futur', () => {
    const headers = headersFor({}, { timestamp: nowSeconds + 61 });
    expect(verify(headers)).toMatchObject({ ok: false, code: 'AUTH_EXPIRED' });
  });

  it('accepte les bords de la fenêtre', () => {
    expect(verify(headersFor({}, { timestamp: nowSeconds - 60 }))).toEqual({ ok: true });
    expect(verify(headersFor({}, { timestamp: nowSeconds + 60 }))).toEqual({ ok: true });
  });

  it('refuse un horodatage non entier', () => {
    const headers = headersFor({ [HEADER_TIMESTAMP]: 'hier' }, { timestamp: nowSeconds });
    expect(verify(headers)).toMatchObject({ ok: false, reason: 'horodatage non entier' });
  });

  for (const header of [HEADER_TIMESTAMP, HEADER_NONCE, HEADER_CONTENT_SHA256, HEADER_SIGNATURE]) {
    it(`refuse l’absence de ${header}`, () => {
      const headers = headersFor({}, { timestamp: nowSeconds });
      delete headers[header];
      expect(verify(headers)).toMatchObject({ ok: false, code: 'AUTH_MISSING' });
    });
  }

  it('refuse un nonce trop court', () => {
    const headers = headersFor({ [HEADER_NONCE]: 'court' }, { timestamp: nowSeconds });
    expect(verify(headers)).toMatchObject({ ok: false, reason: 'nonce de format invalide' });
  });

  it('refuse un en-tête répété (valeur ambiguë)', () => {
    const headers = headersFor({}, { timestamp: nowSeconds });
    const result = verify({ ...headers, [HEADER_NONCE]: ['a', 'b'] });
    expect(result).toMatchObject({ ok: false, code: 'AUTH_MISSING' });
  });

  it('refuse un nonce rejoué', () => {
    const cache = new NonceCache(120_000);
    const headers = headersFor({}, { timestamp: nowSeconds });
    expect(verify(headers, { cache })).toEqual({ ok: true });
    expect(verify(headers, { cache })).toMatchObject({ ok: false, code: 'AUTH_REPLAY' });
  });

  it('ne consomme pas de nonce quand la signature est invalide', () => {
    // Sinon un tiers sans secret pourrait empoisonner le cache anti-rejeu.
    const cache = new NonceCache(120_000);
    const headers = headersFor({}, { secret: 'd'.repeat(64), timestamp: nowSeconds });
    expect(verify(headers, { cache })).toMatchObject({ ok: false });
    expect(cache.size).toBe(0);
  });

  it('refuse une empreinte de corps incorrecte', () => {
    const headers = headersFor({}, { timestamp: nowSeconds });
    // Signature recalculée sur la MAUVAISE empreinte : seule l'empreinte trahit.
    const contentSha256 = sha256Hex('charge utile');
    const nonce = String(headers[HEADER_NONCE]);
    const signature = signCanonical(SECRET, {
      method: 'GET',
      pathWithQuery: PATH,
      timestamp: nowSeconds,
      nonce,
      contentSha256,
    });
    const result = verify({
      ...headers,
      [HEADER_CONTENT_SHA256]: contentSha256,
      [HEADER_SIGNATURE]: signature,
    });
    expect(result).toMatchObject({ ok: false, reason: 'empreinte de corps incorrecte' });
  });

  it('refuse une query string modifiée après signature', () => {
    const headers = headersFor({}, { path: `${PATH}?a=1`, timestamp: nowSeconds });
    expect(verify(headers, { path: `${PATH}?a=2` })).toMatchObject({
      ok: false,
      reason: 'signature invalide',
    });
  });

  it('refuse une méthode modifiée après signature', () => {
    const headers = headersFor({}, { method: 'HEAD', timestamp: nowSeconds });
    expect(verify(headers, { method: 'GET' })).toMatchObject({
      ok: false,
      reason: 'signature invalide',
    });
  });
});

describe('NonceCache', () => {
  it('purge les entrées expirées', () => {
    const cache = new NonceCache(1_000);
    expect(cache.consume('n1', 0)).toBe('accepted');
    expect(cache.consume('n1', 500)).toBe('replay');
    expect(cache.size).toBe(1);
    // Passée la TTL, l'entrée disparaît : le cache reste borné dans le temps.
    expect(cache.consume('n2', 2_000)).toBe('accepted');
    expect(cache.size).toBe(1);
  });

  it('reste borné en nombre d’entrées', () => {
    const cache = new NonceCache(60_000, 2);
    expect(cache.consume('a', 0)).toBe('accepted');
    expect(cache.consume('b', 0)).toBe('accepted');
    expect(cache.consume('c', 0)).toBe('saturated');
    expect(cache.size).toBe(2);
  });
});
