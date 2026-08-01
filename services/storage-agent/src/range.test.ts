import { describe, expect, it } from 'vitest';
import { isMultiRange, parseRangeHeader } from './range.js';

const SIZE = 16;

describe('parseRangeHeader', () => {
  it('absence de Range → fichier complet', () => {
    expect(parseRangeHeader(undefined, SIZE)).toEqual({ kind: 'full' });
  });

  it('bytes=N-M', () => {
    expect(parseRangeHeader('bytes=2-5', SIZE)).toEqual({ kind: 'partial', start: 2, end: 5 });
  });

  it('bytes=N- va jusqu’à la fin', () => {
    expect(parseRangeHeader('bytes=10-', SIZE)).toEqual({ kind: 'partial', start: 10, end: 15 });
  });

  it('bytes=-N prend les N derniers octets', () => {
    expect(parseRangeHeader('bytes=-4', SIZE)).toEqual({ kind: 'partial', start: 12, end: 15 });
  });

  it('suffixe plus grand que le fichier → fichier entier en 206', () => {
    expect(parseRangeHeader('bytes=-999', SIZE)).toEqual({ kind: 'partial', start: 0, end: 15 });
  });

  it('borne supérieure dépassant la taille est ramenée à la dernière position', () => {
    expect(parseRangeHeader('bytes=4-999', SIZE)).toEqual({ kind: 'partial', start: 4, end: 15 });
  });

  it('start >= taille → insatisfaisable', () => {
    expect(parseRangeHeader('bytes=16-', SIZE)).toEqual({ kind: 'unsatisfiable' });
    expect(parseRangeHeader('bytes=99-120', SIZE)).toEqual({ kind: 'unsatisfiable' });
  });

  it('start > end → insatisfaisable', () => {
    expect(parseRangeHeader('bytes=8-3', SIZE)).toEqual({ kind: 'unsatisfiable' });
  });

  it('suffixe nul → insatisfaisable', () => {
    expect(parseRangeHeader('bytes=-0', SIZE)).toEqual({ kind: 'unsatisfiable' });
  });

  it('fichier vide : toute plage est insatisfaisable', () => {
    expect(parseRangeHeader('bytes=0-', 0)).toEqual({ kind: 'unsatisfiable' });
    expect(parseRangeHeader('bytes=0-0', 0)).toEqual({ kind: 'unsatisfiable' });
  });

  it('fichier vide sans Range → complet', () => {
    expect(parseRangeHeader(undefined, 0)).toEqual({ kind: 'full' });
  });

  it('multi-range refusé : Range ignoré, réponse complète', () => {
    // Comportement identique à l'API publique : jamais de multipart/byteranges.
    expect(parseRangeHeader('bytes=0-1,4-5', SIZE)).toEqual({ kind: 'full' });
  });

  it('syntaxe non reconnue → Range ignoré', () => {
    expect(parseRangeHeader('octets=0-1', SIZE)).toEqual({ kind: 'full' });
    expect(parseRangeHeader('bytes=abc', SIZE)).toEqual({ kind: 'full' });
    expect(parseRangeHeader('bytes=-', SIZE)).toEqual({ kind: 'full' });
  });
});

describe('isMultiRange', () => {
  it('détecte le multi-range pour le journal', () => {
    expect(isMultiRange('bytes=0-1,4-5')).toBe(true);
    expect(isMultiRange('bytes=0-1')).toBe(false);
    expect(isMultiRange(undefined)).toBe(false);
  });
});
