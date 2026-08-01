import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, sep } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import {
  AudioStorageError,
  toPortableRelativePath,
  trackStorageReference,
  type TrackStorageReference,
} from './audio-storage.js';
import { LocalFileStorageProvider } from './local-file-storage.js';
import {
  AudioStorageConfigError,
  createAudioStorageProvider,
  DEFAULT_AUDIO_STORAGE_MODE,
  parseAudioStorageMode,
} from './provider-factory.js';
import { RemoteWindowsStorageProvider } from './remote/remote-windows-storage.js';
import { CachedAudioStorageProvider } from './cache/cached-audio-storage.js';

const base = mkdtempSync(join(tmpdir(), 'homespotify-storage-'));
const musicRoot = join(base, 'music');
const outsideFile = join(base, 'secret.txt');

const CONTENT = Buffer.from('0123456789ABCDEF');

function reference(relativePath: string): TrackStorageReference {
  return { trackId: 1, relativePath, contentHash: 'hash-test' };
}

beforeAll(() => {
  mkdirSync(join(musicRoot, 'Artiste', 'Album'), { recursive: true });
  writeFileSync(join(musicRoot, 'Artiste', 'Album', 'Piste.flac'), CONTENT);
  writeFileSync(outsideFile, 'ne doit jamais être servi');
});

afterAll(() => {
  rmSync(base, { recursive: true, force: true });
});

describe('toPortableRelativePath', () => {
  it('convertit les séparateurs Windows en séparateurs portables', () => {
    // Forme réelle des 157 chemins en base au 2026-07-25.
    expect(toPortableRelativePath('Artiste\\Album\\Piste.flac')).toBe(
      'Artiste/Album/Piste.flac',
    );
  });

  it('laisse un chemin déjà portable inchangé', () => {
    expect(toPortableRelativePath('Artiste/Album/Piste.flac')).toBe(
      'Artiste/Album/Piste.flac',
    );
  });

  it('accepte un chemin mixte', () => {
    expect(toPortableRelativePath('Artiste\\Album/Piste.flac')).toBe(
      'Artiste/Album/Piste.flac',
    );
  });

  it('réduit les séparateurs consécutifs', () => {
    expect(toPortableRelativePath('Artiste\\\\Album//Piste.flac')).toBe(
      'Artiste/Album/Piste.flac',
    );
  });

  it('supprime les segments « . »', () => {
    expect(toPortableRelativePath('Artiste\\.\\Album\\Piste.flac')).toBe(
      'Artiste/Album/Piste.flac',
    );
  });

  it('préserve espaces, accents, apostrophes et Unicode', () => {
    expect(
      toPortableRelativePath("Édith Piaf\\Non, je ne regrette rien\\01 - L'hymne.flac"),
    ).toBe("Édith Piaf/Non, je ne regrette rien/01 - L'hymne.flac");
    expect(toPortableRelativePath('日本語\\アルバム\\曲.flac')).toBe(
      '日本語/アルバム/曲.flac',
    );
    expect(toPortableRelativePath('Sigur Rós\\( )\\Untitled #3.flac')).toBe(
      'Sigur Rós/( )/Untitled #3.flac',
    );
  });

  it('refuse une remontée de répertoire (slash)', () => {
    expect(() => toPortableRelativePath('../secret.txt')).toThrowError(
      AudioStorageError,
    );
    expect(() => toPortableRelativePath('Artiste/../../secret.txt')).toThrowError(
      /remontée/,
    );
  });

  it('refuse une remontée de répertoire (backslash)', () => {
    expect(() => toPortableRelativePath('..\\secret.txt')).toThrowError(
      AudioStorageError,
    );
    expect(() =>
      toPortableRelativePath('Artiste\\..\\..\\secret.txt'),
    ).toThrowError(/remontée/);
  });

  it('refuse un chemin absolu Windows', () => {
    expect(() => toPortableRelativePath('C:\\Music\\Piste.flac')).toThrowError(
      /absolu Windows/,
    );
    expect(() => toPortableRelativePath('f:/Music/Piste.flac')).toThrowError(
      /absolu Windows/,
    );
  });

  it('refuse un chemin absolu Unix', () => {
    expect(() => toPortableRelativePath('/etc/passwd')).toThrowError(/absolu/);
  });

  it('refuse un chemin UNC', () => {
    // `\\serveur\partage` devient `//serveur/partage` : rejeté comme absolu.
    expect(() =>
      toPortableRelativePath('\\\\serveur\\partage\\Piste.flac'),
    ).toThrowError(/absolu ou UNC/);
  });

  it('refuse un chemin commençant par un séparateur', () => {
    expect(() => toPortableRelativePath('\\Artiste\\Piste.flac')).toThrowError(
      AudioStorageError,
    );
  });

  it('refuse un chemin vide ou sans segment exploitable', () => {
    expect(() => toPortableRelativePath('')).toThrowError(/vide/);
    expect(() => toPortableRelativePath('   ')).toThrowError(/vide/);
    expect(() => toPortableRelativePath('.')).toThrowError(/aucun segment/);
    expect(() => toPortableRelativePath('.\\.\\.')).toThrowError(/aucun segment/);
  });

  it('expose un code d’erreur exploitable par l’appelant', () => {
    try {
      toPortableRelativePath('../x');
      expect.unreachable('doit lever');
    } catch (error) {
      expect(error).toBeInstanceOf(AudioStorageError);
      expect((error as AudioStorageError).code).toBe('PATH_TRAVERSAL');
    }
  });

  it('accepte un nom de fichier sans dossier', () => {
    expect(toPortableRelativePath('Piste.flac')).toBe('Piste.flac');
  });
});

describe('trackStorageReference', () => {
  it('normalise le chemin issu de la base sans la modifier', () => {
    const row = { id: 42, path: 'Artiste\\Album\\Piste.flac', hash: 'abc123' };
    const ref = trackStorageReference(row);

    expect(ref).toEqual({
      trackId: 42,
      relativePath: 'Artiste/Album/Piste.flac',
      contentHash: 'abc123',
    });
    // La ligne source reste intacte : aucune écriture en base.
    expect(row.path).toBe('Artiste\\Album\\Piste.flac');
  });
});

describe('LocalFileStorageProvider', () => {
  const provider = new LocalFileStorageProvider(musicRoot);

  it('résout un chemin sous la racine', () => {
    expect(provider.resolvePath(reference('Artiste/Album/Piste.flac'))).toBe(
      resolve(musicRoot, 'Artiste', 'Album', 'Piste.flac'),
    );
  });

  it('stat retourne la taille exacte et la date de modification', async () => {
    const info = await provider.stat(reference('Artiste/Album/Piste.flac'));

    expect(info.sizeBytes).toBe(CONTENT.length);
    expect(info.source).toBe('local');
    expect(info.modifiedAt).toBeInstanceOf(Date);
  });

  it('stat sur un fichier absent lève NOT_FOUND', async () => {
    await expect(provider.stat(reference('Artiste/Absent.flac'))).rejects.toMatchObject(
      { code: 'NOT_FOUND' },
    );
  });

  it('stat sur un répertoire lève NOT_A_FILE', async () => {
    await expect(provider.stat(reference('Artiste/Album'))).rejects.toMatchObject({
      code: 'NOT_A_FILE',
    });
  });

  it('lit le fichier entier', async () => {
    const stream = await provider.createReadStream(
      reference('Artiste/Album/Piste.flac'),
    );
    const chunks: Buffer[] = [];
    for await (const chunk of stream) chunks.push(chunk as Buffer);

    expect(Buffer.concat(chunks)).toEqual(CONTENT);
  });

  it('lit une plage d’octets, bornes incluses', async () => {
    const stream = await provider.createReadStream(
      reference('Artiste/Album/Piste.flac'),
      { start: 2, end: 5 },
    );
    const chunks: Buffer[] = [];
    for await (const chunk of stream) chunks.push(chunk as Buffer);

    // Sémantique identique à HTTP Range : 2..5 inclus = 4 octets.
    expect(Buffer.concat(chunks).toString()).toBe('2345');
  });

  it('ferme le flux après lecture complète', async () => {
    const stream = await provider.createReadStream(
      reference('Artiste/Album/Piste.flac'),
    );
    for await (const _chunk of stream) {
      // consommation intégrale
    }
    expect(stream.destroyed || stream.readableEnded).toBe(true);
  });

  it('signale l’erreur disque sur un flux de fichier absent', async () => {
    const stream = await provider.createReadStream(reference('Absent.flac'));
    const error = await new Promise<NodeJS.ErrnoException>((resolvePromise) => {
      stream.once('error', resolvePromise);
    });
    expect(error.code).toBe('ENOENT');
  });

  describe('protection anti-traversal', () => {
    it('refuse une référence qui sort de la racine', () => {
      // Référence fabriquée SANS passer par toPortableRelativePath : c'est
      // exactement le cas que la seconde barrière doit intercepter.
      expect(() => provider.resolvePath(reference('../secret.txt'))).toThrowError(
        /sort de la racine/,
      );
    });

    it('refuse une référence désignant la racine elle-même', () => {
      expect(() => provider.resolvePath(reference('.'))).toThrowError(
        /racine de stockage/,
      );
    });

    it('refuse un chemin absolu injecté', () => {
      expect(() => provider.resolvePath(reference(outsideFile))).toThrowError(
        AudioStorageError,
      );
    });

    it('refuse un préfixe de racine trompeur', () => {
      // `<root>-autre` commence par `<root>` sans être dedans : la comparaison
      // doit inclure le séparateur.
      const sibling = new LocalFileStorageProvider(musicRoot);
      expect(() =>
        sibling.resolvePath(reference(`..${sep}music-autre${sep}x.flac`)),
      ).toThrowError(/sort de la racine/);
    });
  });

  describe('healthCheck', () => {
    it('retourne online quand la racine existe', async () => {
      const health = await provider.healthCheck();
      expect(health.status).toBe('online');
      if (health.status === 'online') {
        expect(health.source).toBe('local');
        expect(health.latencyMs).toBeGreaterThanOrEqual(0);
      }
    });

    it('retourne offline quand la racine est absente', async () => {
      const absent = new LocalFileStorageProvider(join(base, 'nexiste-pas'));
      const health = await absent.healthCheck();
      expect(health.status).toBe('offline');
    });

    it('retourne degraded quand la racine est un fichier', async () => {
      const notADir = new LocalFileStorageProvider(outsideFile);
      const health = await notADir.healthCheck();
      expect(health.status).toBe('degraded');
    });
  });
});

describe('parseAudioStorageMode', () => {
  it('applique « local » par défaut', () => {
    expect(parseAudioStorageMode(undefined)).toBe('local');
    expect(parseAudioStorageMode('')).toBe('local');
    expect(parseAudioStorageMode('   ')).toBe('local');
    expect(DEFAULT_AUDIO_STORAGE_MODE).toBe('local');
  });

  it('accepte les trois modes prévus', () => {
    expect(parseAudioStorageMode('local')).toBe('local');
    expect(parseAudioStorageMode('remote')).toBe('remote');
    expect(parseAudioStorageMode('cached')).toBe('cached');
  });

  it('refuse une valeur inconnue sans repli silencieux', () => {
    // Un repli sur « local » masquerait une faute de frappe en production.
    expect(() => parseAudioStorageMode('locale')).toThrowError(
      AudioStorageConfigError,
    );
    expect(() => parseAudioStorageMode('LOCAL')).toThrowError(/AUDIO_STORAGE_MODE/);
  });
});

describe('createAudioStorageProvider', () => {
  it('construit le provider local', () => {
    const provider = createAudioStorageProvider('local', { musicDir: musicRoot });
    expect(provider).toBeInstanceOf(LocalFileStorageProvider);
  });

  it('exige une config pour remote puis construit le provider distant', () => {
    expect(() =>
      createAudioStorageProvider('remote', { musicDir: musicRoot }),
    ).toThrowError(/configuration distante valide/);
    const provider = createAudioStorageProvider('remote', {
      musicDir: musicRoot,
      remote: {
        baseUrl: 'http://127.0.0.1:3100',
        sharedSecret: 'x'.repeat(32),
        connectTimeoutMs: 2_000,
        headersTimeoutMs: 5_000,
        bodyIdleTimeoutMs: 15_000,
        maxConnections: 8,
      },
    });
    expect(provider).toBeInstanceOf(RemoteWindowsStorageProvider);
    void provider.close?.();
  });

  it('exige les deux configs puis construit le provider cached', async () => {
    expect(() =>
      createAudioStorageProvider('cached', { musicDir: musicRoot }),
    ).toThrowError(/configurations distante et cache/);
    const cacheRoot = join(base, 'audio-cache');
    const provider = createAudioStorageProvider('cached', {
      musicDir: musicRoot,
      remote: {
        baseUrl: 'http://127.0.0.1:3100',
        sharedSecret: 'x'.repeat(32),
        connectTimeoutMs: 2_000,
        headersTimeoutMs: 5_000,
        bodyIdleTimeoutMs: 15_000,
        maxConnections: 8,
      },
      cache: {
        root: cacheRoot,
        maxBytes: 1024,
        minFreeBytes: 1,
        tempMaxAgeMs: 1000,
        fillOnFullGet: true,
        verifyOnHit: 'size',
        evictionTargetRatio: 0.9,
      },
    });
    expect(provider).toBeInstanceOf(CachedAudioStorageProvider);
    await provider.close?.();
  });
});
