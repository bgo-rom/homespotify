import { describe, expect, it } from 'vitest';
import { parseRangeHeader } from './range.js';

describe('parseRangeHeader', () => {
  const SIZE = 1000;

  it('sans en-tête → réponse complète', () => {
    expect(parseRangeHeader(undefined, SIZE)).toBe('full');
  });

  it('bytes=0-499 → bornes exactes', () => {
    expect(parseRangeHeader('bytes=0-499', SIZE)).toEqual({ start: 0, end: 499 });
  });

  it('bytes=500- → jusqu à la fin', () => {
    expect(parseRangeHeader('bytes=500-', SIZE)).toEqual({ start: 500, end: 999 });
  });

  it('bytes=-200 → suffixe (200 derniers octets)', () => {
    expect(parseRangeHeader('bytes=-200', SIZE)).toEqual({ start: 800, end: 999 });
  });

  it('fin au-delà de la taille → bornée', () => {
    expect(parseRangeHeader('bytes=900-5000', SIZE)).toEqual({ start: 900, end: 999 });
  });

  it('suffixe plus grand que le fichier → fichier entier', () => {
    expect(parseRangeHeader('bytes=-5000', SIZE)).toEqual({ start: 0, end: 999 });
  });

  it('début hors fichier → unsatisfiable (416)', () => {
    expect(parseRangeHeader('bytes=1000-', SIZE)).toBe('unsatisfiable');
  });

  it('bornes inversées → unsatisfiable', () => {
    expect(parseRangeHeader('bytes=500-100', SIZE)).toBe('unsatisfiable');
  });

  it('syntaxe invalide ou multi-range → réponse complète (permis par la RFC)', () => {
    expect(parseRangeHeader('bytes=abc', SIZE)).toBe('full');
    expect(parseRangeHeader('bytes=0-100,200-300', SIZE)).toBe('full');
    expect(parseRangeHeader('items=0-10', SIZE)).toBe('full');
  });

  it('fichier vide → unsatisfiable', () => {
    expect(parseRangeHeader('bytes=0-', 0)).toBe('unsatisfiable');
  });
});
