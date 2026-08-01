/**
 * Parité avec les primitives de la Phase 1
 * (`services/api/src/storage/audio-storage.test.ts`). Le jeu de cas est
 * volontairement le même : toute divergence de comportement entre les deux
 * implémentations doit faire rougir ce fichier.
 */
import { mkdirSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PathSafetyError, resolveWithinRoot, toPortableRelativePath } from './path-safety.js';

const base = mkdtempSync(join(tmpdir(), 'hs-path-safety-'));
const musicRoot = join(base, 'music');

beforeAll(() => {
  mkdirSync(musicRoot, { recursive: true });
  // Dossier voisin dont le nom PRÉFIXE la racine : piège classique d'une
  // comparaison `startsWith(root)` sans séparateur.
  mkdirSync(join(base, 'music-public'), { recursive: true });
});

afterAll(() => {
  rmSync(base, { recursive: true, force: true });
});

describe('toPortableRelativePath', () => {
  it('convertit les séparateurs Windows', () => {
    expect(toPortableRelativePath('Artiste\\Album\\Piste.flac')).toBe(
      'Artiste/Album/Piste.flac',
    );
  });

  it('laisse un chemin déjà portable inchangé', () => {
    expect(toPortableRelativePath('Artiste/Album/Piste.flac')).toBe(
      'Artiste/Album/Piste.flac',
    );
  });

  it('réduit les séparateurs consécutifs et supprime les segments « . »', () => {
    expect(toPortableRelativePath('Artiste\\\\Album//./Piste.flac')).toBe(
      'Artiste/Album/Piste.flac',
    );
  });

  it('préserve accents, espaces et Unicode', () => {
    expect(
      toPortableRelativePath("Édith Piaf\\Non, je ne regrette rien\\01 - L'hymne.flac"),
    ).toBe("Édith Piaf/Non, je ne regrette rien/01 - L'hymne.flac");
    expect(toPortableRelativePath('日本語\\アルバム\\曲.flac')).toBe('日本語/アルバム/曲.flac');
  });

  it('refuse un chemin vide', () => {
    expect(() => toPortableRelativePath('')).toThrowError(PathSafetyError);
    expect(() => toPortableRelativePath('   ')).toThrowError(PathSafetyError);
  });

  it('refuse un chemin sans segment exploitable', () => {
    expect(() => toPortableRelativePath('.')).toThrowError(/aucun segment/);
    expect(() => toPortableRelativePath('.\\.\\.')).toThrowError(/aucun segment/);
  });

  it('refuse une remontée de répertoire, slash comme backslash', () => {
    for (const candidate of [
      '../secret.txt',
      '..\\secret.txt',
      'Artiste/../../secret.txt',
      'Artiste\\..\\..\\secret.txt',
    ]) {
      let captured: unknown;
      try {
        toPortableRelativePath(candidate);
      } catch (error) {
        captured = error;
      }
      expect(captured).toBeInstanceOf(PathSafetyError);
      expect((captured as PathSafetyError).reason).toBe('TRAVERSAL');
    }
  });

  it('refuse un chemin absolu Windows', () => {
    expect(() => toPortableRelativePath('C:\\Music\\Piste.flac')).toThrowError(
      /absolu Windows/,
    );
    expect(() => toPortableRelativePath('f:/Music/Piste.flac')).toThrowError(/absolu Windows/);
  });

  it('refuse un chemin absolu Unix', () => {
    expect(() => toPortableRelativePath('/etc/passwd')).toThrowError(/absolu/);
    expect(() => toPortableRelativePath('\\Artiste\\Piste.flac')).toThrowError(/absolu/);
  });

  it('refuse un chemin UNC', () => {
    let captured: unknown;
    try {
      toPortableRelativePath('\\\\serveur\\partage\\Piste.flac');
    } catch (error) {
      captured = error;
    }
    expect((captured as PathSafetyError).reason).toBe('UNC');
  });

  it('refuse une valeur non textuelle', () => {
    expect(() => toPortableRelativePath(42)).toThrowError(PathSafetyError);
    expect(() => toPortableRelativePath(null)).toThrowError(PathSafetyError);
    expect(() => toPortableRelativePath({ relativePath: 'x' })).toThrowError(PathSafetyError);
  });
});

describe('resolveWithinRoot', () => {
  it('résout sous la racine', () => {
    expect(resolveWithinRoot(musicRoot, 'Artiste/Album/Piste.flac')).toBe(
      resolve(musicRoot, 'Artiste', 'Album', 'Piste.flac'),
    );
  });

  it('refuse la racine elle-même', () => {
    // `.` seul ne peut pas sortir de `toPortableRelativePath`, mais la seconde
    // barrière doit tenir même si la première est contournée.
    expect(() => resolveWithinRoot(musicRoot, '.')).toThrowError(/racine/);
  });

  it('refuse une sortie de racine', () => {
    expect(() => resolveWithinRoot(musicRoot, '../secret.txt')).toThrowError(/sort de la racine/);
  });

  it('refuse un dossier voisin dont le nom préfixe la racine', () => {
    // `…/music-public/x` commence par `…/music` : seule la comparaison avec le
    // séparateur système l'attrape.
    expect(() => resolveWithinRoot(musicRoot, '../music-public/x.flac')).toThrowError(
      /sort de la racine/,
    );
  });
});
