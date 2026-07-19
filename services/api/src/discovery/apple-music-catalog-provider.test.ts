import { generateKeyPairSync, verify as cryptoVerify } from 'node:crypto';
import { describe, expect, it } from 'vitest';
import {
  AppleMusicCatalogProvider,
  generateAppleDeveloperToken,
} from './apple-music-catalog-provider.js';

// Clé EC P-256 (prime256v1) éphémère : équivalent d'une .p8 MusicKit, jamais
// commitée. Permet de valider la génération/signature JWT sans compte Apple.
function makeEcKeyPair() {
  return generateKeyPairSync('ec', {
    namedCurve: 'prime256v1',
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });
}

function decodeSegment(seg: string): Record<string, unknown> {
  return JSON.parse(Buffer.from(seg.replace(/-/gu, '+').replace(/_/gu, '/'), 'base64').toString());
}

describe('Apple Music — génération du developer token (ES256)', () => {
  it('produit un JWT header/payload conformes, signé et vérifiable', () => {
    const { publicKey, privateKey } = makeEcKeyPair();
    const token = generateAppleDeveloperToken({
      teamId: 'TEAM123456',
      keyId: 'KEY7654321',
      privateKeyPem: privateKey,
      issuedAt: 1_700_000_000,
      ttlSeconds: 3600,
    });
    const [h, p, s] = token.split('.');
    expect(decodeSegment(h!)).toMatchObject({ alg: 'ES256', kid: 'KEY7654321', typ: 'JWT' });
    expect(decodeSegment(p!)).toMatchObject({ iss: 'TEAM123456', iat: 1_700_000_000, exp: 1_700_003_600 });
    // Vérifie la signature P1363 (R||S) avec la clé publique.
    const ok = cryptoVerify(
      'sha256',
      Buffer.from(`${h}.${p}`),
      { key: publicKey, dsaEncoding: 'ieee-p1363' },
      Buffer.from(s!.replace(/-/gu, '+').replace(/_/gu, '/'), 'base64'),
    );
    expect(ok).toBe(true);
  });

  it('met le JWT en cache et le renouvelle avant expiration', () => {
    const { privateKey } = makeEcKeyPair();
    let clock = 1_700_000_000_000;
    const provider = new AppleMusicCatalogProvider({
      teamId: 'T',
      keyId: 'K',
      privateKeyPem: privateKey,
      tokenTtlSeconds: 3600,
      now: () => clock,
    });
    const first = provider.developerToken();
    expect(provider.developerToken()).toBe(first); // caché
    clock += 3600_000; // au-delà de la fenêtre de renouvellement (5 min avant exp)
    expect(provider.developerToken()).not.toBe(first); // régénéré
  });

  it('rejette une clé privée invalide au démarrage', () => {
    expect(
      () =>
        new AppleMusicCatalogProvider({
          teamId: 'T',
          keyId: 'K',
          privateKeyPem: '-----BEGIN PRIVATE KEY-----\nnope\n-----END PRIVATE KEY-----',
        }),
    ).toThrow();
  });
});

describe('Apple Music — matching catalogue', () => {
  const appleSong = (over: Record<string, unknown> = {}) => ({
    id: 'am-1',
    attributes: {
      name: 'Titre',
      artistName: 'Artiste',
      albumName: 'Album',
      isrc: 'FRXXX0000001',
      durationInMillis: 200_000,
      previews: [{ url: 'https://audio.apple.com/p.m4a' }],
      artwork: { url: 'https://is.apple.com/{w}x{h}.jpg', width: 3000, height: 3000 },
      ...over,
    },
  });

  function makeProvider(songs: unknown[]): AppleMusicCatalogProvider {
    const { privateKey } = makeEcKeyPair();
    return new AppleMusicCatalogProvider({
      teamId: 'T',
      keyId: 'K',
      privateKeyPem: privateKey,
      fetchImpl: (async (input: string | URL) => {
        const url = String(input);
        const body = url.includes('filter%5Bisrc%5D')
          ? { data: songs }
          : { results: { songs: { data: songs } } };
        return { ok: true, status: 200, json: async () => body } as Response;
      }) as typeof fetch,
    });
  }

  it('ISRC exact : extrait https + pochette rendue en 600×600', async () => {
    const provider = makeProvider([appleSong()]);
    const match = await provider.findPreview({
      title: 'Titre',
      artist: 'Artiste',
      durationMs: 200_000,
      isrc: 'FRXXX0000001',
    });
    expect(match).toMatchObject({ provider: 'APPLE_MUSIC', confidence: 1.0, catalogId: 'am-1' });
    expect(match?.artworkUrl).toBe('https://is.apple.com/600x600.jpg');
    expect(match?.artworkWidth).toBe(600);
  });

  it('exclut les versions live au profit de la studio', async () => {
    const provider = makeProvider([
      appleSong({ name: 'Titre (Live)' }),
      { ...appleSong(), id: 'am-2' },
    ]);
    const match = await provider.findPreview({ title: 'Titre', artist: 'Artiste', durationMs: null });
    expect(match?.catalogId).toBe('am-2');
  });

  it('identité absente : null', async () => {
    const provider = makeProvider([appleSong({ name: 'Autre', artistName: 'Autre' })]);
    expect(await provider.findPreview({ title: 'Titre', artist: 'Artiste', durationMs: null })).toBeNull();
  });
});
