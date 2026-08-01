import { describe, expect, it } from 'vitest';
import { sanitizeMessage, sanitizeShortField } from './log-sanitizer.js';

describe('sanitizeMessage — secrets', () => {
  it('masque la clé Premium quelle que soit son écriture', () => {
    for (const raw of [
      'ANTRA_API_KEY=sk_live_9f83bc21aa77',
      'antra-api-key: sk_live_9f83bc21aa77',
      '{"api_key": "sk_live_9f83bc21aa77"}',
      'Envoi avec apikey=sk_live_9f83bc21aa77 vers le miroir',
    ]) {
      const output = sanitizeMessage(raw) ?? '';
      expect(output, raw).not.toContain('sk_live_9f83bc21aa77');
      expect(output, raw).toContain('[masqué]');
    }
  });

  it('masque cookies, jetons et mots de passe', () => {
    const output =
      sanitizeMessage(
        'cookie=sp_dc_abcdef123456; password=Motdepasse1; ' +
          'authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sIgNaTuRe',
      ) ?? '';
    expect(output).not.toContain('sp_dc_abcdef123456');
    expect(output).not.toContain('Motdepasse1');
    expect(output).not.toContain('eyJhbGciOiJIUzI1NiJ9');
  });

  it('masque un jeton Amazon et des identifiants dans une URL', () => {
    expect(sanitizeMessage('header Atna|abcdef1234567890')).not.toContain('abcdef');
    expect(sanitizeMessage('https://bob:secret@example.com/x')).not.toContain(
      'secret',
    );
  });
});

describe('sanitizeMessage — chemins locaux', () => {
  it('retire les chemins Windows, UNC et POSIX', () => {
    expect(
      sanitizeMessage('Écrit dans F:\\dev\\homespotify\\storage\\imports\\a.flac'),
    ).not.toContain('homespotify');
    expect(sanitizeMessage('Copie depuis \\\\NAS\\musique\\a.flac')).not.toContain(
      'NAS',
    );
    expect(sanitizeMessage('lu depuis /var/lib/homespotify/x.flac')).not.toContain(
      '/var/lib',
    );
  });
});

describe('sanitizeMessage — forme', () => {
  it('supprime les caractères de contrôle et normalise les espaces', () => {
    expect(sanitizeMessage('a\u0000b\tc\n  d')).toBe('a b c d');
  });

  it('borne la longueur', () => {
    const output = sanitizeMessage('x'.repeat(500)) ?? '';
    expect(output.length).toBeLessThanOrEqual(300);
    expect(output.endsWith('…')).toBe(true);
  });

  it('retourne null pour une entrée vide ou non textuelle', () => {
    expect(sanitizeMessage('   ')).toBeNull();
    expect(sanitizeMessage(undefined)).toBeNull();
    expect(sanitizeMessage(42)).toBeNull();
  });

  it('laisse passer un message ordinaire sans le mutiler', () => {
    expect(sanitizeMessage('Téléchargement terminé (FLAC 24-bit/96kHz)')).toBe(
      'Téléchargement terminé (FLAC 24-bit/96kHz)',
    );
    expect(sanitizeShortField('Guala', 60)).toBe('Guala');
  });
});
