import { describe, expect, it } from 'vitest';
import {
  MAX_DOWNLOAD_URL_LENGTH,
  normalizeDownloadUrl,
  parseDownloadUrl,
} from './download-url.js';

describe('parseDownloadUrl — acceptation', () => {
  it('accepte une URL Qobuz valide', () => {
    const result = parseDownloadUrl(
      'https://www.qobuz.com/us-en/album/lifestyles-guala/m7mqu37d7v1ka',
    );
    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.host).toBe('www.qobuz.com');
    expect(result.normalizedUrl).toBe(
      'https://www.qobuz.com/us-en/album/lifestyles-guala/m7mqu37d7v1ka',
    );
  });

  it('accepte chaque service réellement géré par le moteur', () => {
    const urls = [
      'https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT',
      'https://music.apple.com/fr/album/random-access-memories/1440783617',
      'https://music.amazon.fr/albums/B00FHRPXWM',
      'https://music.amazon.co.uk/albums/B00FHRPXWM',
      'https://music.youtube.com/watch?v=dQw4w9WgXcQ',
      'https://soundcloud.com/artiste/titre',
      'https://tidal.com/browse/album/77640617',
      'https://listen.tidal.com/album/77640617',
      'https://open.qobuz.com/album/m7mqu37d7v1ka',
      'https://www.deezer.com/fr/album/123456',
      'https://deezer.page.link/abcdef',
    ];
    for (const url of urls) {
      expect(parseDownloadUrl(url).ok, url).toBe(true);
    }
  });
});

describe('parseDownloadUrl — refus', () => {
  it('refuse les schémas dangereux et les chemins locaux', () => {
    const cases: Array<[string, string]> = [
      ['file:///C:/Windows/System32/notepad.exe', 'scheme_not_https'],
      ['javascript:alert(1)', 'scheme_not_https'],
      ['data:text/plain;base64,SGVsbG8=', 'scheme_not_https'],
      ['http://open.spotify.com/track/abc', 'scheme_not_https'],
      // `new URL()` lit `C:` comme un schéma : le refus vient donc du contrôle
      // HTTPS, ce qui reste le bon comportement pour un chemin local.
      ['C:\\Users\\rtuyi\\musique.flac', 'scheme_not_https'],
      ['/etc/passwd', 'malformed'],
    ];
    for (const [url, code] of cases) {
      const result = parseDownloadUrl(url);
      expect(result.ok, url).toBe(false);
      if (result.ok) continue;
      expect(result.code, url).toBe(code);
    }
  });

  it('refuse une valeur qui ressemble à une option de ligne de commande', () => {
    const result = parseDownloadUrl('--output C:\\tmp');
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.code).toBe('looks_like_option');
  });

  it('refuse un domaine hors allowlist, y compris youtube.com simple', () => {
    for (const url of [
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      'https://evil.example.com/track/1',
      // Suffixe trompeur : « notqobuz.com » ne doit jamais passer.
      'https://notqobuz.com/album/1',
      'https://music.amazon.evil.com/albums/1',
    ]) {
      const result = parseDownloadUrl(url);
      expect(result.ok, url).toBe(false);
      if (result.ok) continue;
      expect(result.code, url).toBe('host_not_allowed');
    }
  });

  it('refuse les identifiants intégrés à l’URL', () => {
    const result = parseDownloadUrl('https://user:pass@open.spotify.com/track/1');
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.code).toBe('credentials_in_url');
  });

  it('refuse les caractères de contrôle et les valeurs non textuelles', () => {
    expect(parseDownloadUrl('https://open.spotify.com/track/1\n--x').ok).toBe(false);
    expect(parseDownloadUrl(undefined).ok).toBe(false);
    expect(parseDownloadUrl(42).ok).toBe(false);
    expect(parseDownloadUrl('   ').ok).toBe(false);
  });

  it('refuse une URL trop longue', () => {
    const long = `https://open.spotify.com/track/${'a'.repeat(MAX_DOWNLOAD_URL_LENGTH)}`;
    const result = parseDownloadUrl(long);
    expect(result.ok).toBe(false);
    if (result.ok) return;
    expect(result.code).toBe('too_long');
  });
});

describe('normalizeDownloadUrl', () => {
  it('retire le traçage et le fragment sans toucher aux identifiants', () => {
    expect(
      normalizeDownloadUrl(
        'https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT?si=abc123&utm_source=copy#play',
      ),
    ).toBe('https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT');
  });

  it('conserve les paramètres fonctionnels et les trie', () => {
    expect(
      normalizeDownloadUrl('https://music.youtube.com/watch?list=OLAK5&v=abc&si=x'),
    ).toBe('https://music.youtube.com/watch?list=OLAK5&v=abc');
  });

  it('rend identiques deux écritures de la même ressource', () => {
    const a = parseDownloadUrl(
      'https://OPEN.SPOTIFY.COM/track/4cOdK2wGLETKBW3PvgPWqT/?si=1',
    );
    const b = parseDownloadUrl(
      'https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT',
    );
    expect(a.ok && b.ok).toBe(true);
    if (!a.ok || !b.ok) return;
    expect(a.normalizedUrl).toBe(b.normalizedUrl);
  });
});
