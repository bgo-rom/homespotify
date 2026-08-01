import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { makeFlac } from '../test/flac.js';
import {
  detectDownloadedFiles,
  isConfined,
  listTemporaryArtifacts,
  pathKey,
  snapshotDirectoryKeys,
} from './downloaded-file-detector.js';

let staging: string;

const fastStability = {
  allowedExtensions: ['.flac'],
  stabilityIntervalMs: 1,
  stabilityChecks: 1,
  maxStabilityChecks: 5,
};

function write(name: string, data: Buffer): string {
  const path = join(staging, name);
  mkdirSync(join(path, '..'), { recursive: true });
  writeFileSync(path, data);
  return path;
}

beforeEach(() => {
  staging = mkdtempSync(join(tmpdir(), 'homespotify-detect-'));
});

afterEach(() => {
  rmSync(staging, { recursive: true, force: true });
});

describe('snapshotDirectoryKeys', () => {
  it('retourne un inventaire vide pour un dossier absent', async () => {
    expect((await snapshotDirectoryKeys(join(staging, 'absent'))).size).toBe(0);
  });

  it('parcourt les sous-dossiers', async () => {
    write(join('Guala', 'Lifestyles (2025)', '01 - Lifestyles.flac'), makeFlac());
    const keys = await snapshotDirectoryKeys(staging);
    expect(keys.size).toBe(1);
    expect([...keys][0]).toContain('lifestyles');
  });
});

describe('detectDownloadedFiles — acceptation', () => {
  it('détecte un FLAC valide créé par le job', async () => {
    write('01 - Lifestyles.flac', makeFlac({ seconds: 180 }));
    const result = await detectDownloadedFiles(staging, fastStability);
    expect(result.accepted).toHaveLength(1);
    expect(result.accepted[0]?.analysis.durationSeconds).toBeCloseTo(180, 0);
  });

  it('ignore un fichier déjà présent avant le job', async () => {
    const existing = write('ancien.flac', makeFlac({ seconds: 120 }));
    const known = new Set([pathKey(existing)]);
    write('nouveau.flac', makeFlac({ seconds: 200 }));

    const result = await detectDownloadedFiles(staging, {
      ...fastStability,
      knownPaths: known,
    });
    expect(result.accepted).toHaveLength(1);
    expect(result.accepted[0]?.absolutePath).toContain('nouveau.flac');
  });
});

describe('detectDownloadedFiles — refus', () => {
  it('ignore les fichiers temporaires et les extensions non autorisées', async () => {
    write('a.flac.part', makeFlac());
    write('b.enc.m4a', makeFlac());
    write('c.tmp', makeFlac());
    write('d.crdownload', makeFlac());
    write('cover.jpg', Buffer.from('image'));
    write('notes.txt', Buffer.from('texte'));

    const result = await detectDownloadedFiles(staging, fastStability);
    expect(result.accepted).toHaveLength(0);
    expect(result.rejected).toHaveLength(0);
  });

  it('rejette un fichier vide', async () => {
    write('vide.flac', Buffer.alloc(0));
    const result = await detectDownloadedFiles(staging, fastStability);
    expect(result.accepted).toHaveLength(0);
    expect(result.rejected[0]?.reasonCode).toBe('empty');
  });

  it('rejette un fichier illisible', async () => {
    write('faux.flac', Buffer.from('ceci n’est pas du FLAC'));
    const result = await detectDownloadedFiles(staging, fastStability);
    expect(result.accepted).toHaveLength(0);
    expect(result.rejected[0]?.reasonCode).toBe('unreadable');
  });

  it('distingue un format hors specs d’un fichier illisible', async () => {
    // Cas RÉEL observé : certaines sources livrent du FLAC 32 bits, parfaitement
    // lisible mais hors politique d'ingestion (16/24 bits). Le confondre avec
    // « illisible » ferait chercher une corruption inexistante.
    write('hires32.flac', makeFlac({ bitDepth: 32, seconds: 127 }));
    const result = await detectDownloadedFiles(staging, fastStability);

    expect(result.accepted).toHaveLength(0);
    expect(result.rejected[0]?.reasonCode).toBe('format_rejected');
    expect(result.rejected[0]?.reason).toMatch(/Specs|Format refusé/i);
  });

  it('rejette un extrait de 30 s quand la piste attendue est bien plus longue', async () => {
    write('extrait.flac', makeFlac({ seconds: 30 }));
    const result = await detectDownloadedFiles(staging, {
      ...fastStability,
      expectedDurationSeconds: 210,
    });
    expect(result.accepted).toHaveLength(0);
    expect(result.rejected[0]?.reasonCode).toBe('excerpt_too_short');
  });

  it('accepte une piste courte quand la durée attendue le confirme', async () => {
    write('interlude.flac', makeFlac({ seconds: 30 }));
    const result = await detectDownloadedFiles(staging, {
      ...fastStability,
      expectedDurationSeconds: 32,
    });
    expect(result.accepted).toHaveLength(1);
  });
});

describe('nettoyage et confinement', () => {
  it('ne liste QUE les artefacts temporaires, jamais un FLAC complet', async () => {
    write('complet.flac', makeFlac({ seconds: 180 }));
    write('partiel.flac.part', Buffer.from('inachevé'));

    const temporary = await listTemporaryArtifacts(staging);
    expect(temporary).toHaveLength(1);
    expect(temporary[0]).toContain('.part');
  });

  it('refuse tout chemin hors de la racine autorisée', () => {
    expect(isConfined(staging, join(staging, 'a', 'b.flac'))).toBe(true);
    expect(isConfined(staging, join(staging, '..', 'evasion.flac'))).toBe(false);
  });
});
