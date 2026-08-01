import Database from 'better-sqlite3';
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  exportStorageIndex,
  formatStorageIndexSummary,
  STORAGE_INDEX_VERSION,
} from './storage-index-export.js';

let root: string;
let musicDir: string;
let dbPath: string;
let outputPath: string;

/** Base minimale : seule la table `tracks` est nécessaire à l'export. */
function createDatabase(rows: { id: number; path: string; hash: string }[]): void {
  const db = new Database(dbPath);
  db.exec(
    'CREATE TABLE tracks (id INTEGER PRIMARY KEY, hash TEXT NOT NULL, path TEXT NOT NULL)',
  );
  const insert = db.prepare('INSERT INTO tracks (id, hash, path) VALUES (?, ?, ?)');
  for (const row of rows) insert.run(row.id, row.hash, row.path);
  db.close();
}

function writeTrack(relativeWindowsPath: string): void {
  const absolute = join(musicDir, relativeWindowsPath);
  mkdirSync(join(absolute, '..'), { recursive: true });
  writeFileSync(absolute, 'audio');
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'hs-index-export-'));
  musicDir = join(root, 'music');
  dbPath = join(root, 'test.db');
  outputPath = join(root, 'out', 'index.json');
  mkdirSync(musicDir, { recursive: true });
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

function readIndex(): {
  version: number;
  generatedAt: string;
  entries: Record<string, { relativePath: string }>;
} {
  return JSON.parse(readFileSync(outputPath, 'utf-8')) as ReturnType<typeof readIndex>;
}

describe('exportStorageIndex', () => {
  it('exporte les pistes valides et normalise les backslashes', async () => {
    writeTrack('Artiste\\Album\\Piste.flac');
    writeTrack('Artiste\\Album\\Autre.flac');
    createDatabase([
      { id: 1, hash: 'h1', path: 'Artiste\\Album\\Piste.flac' },
      { id: 2, hash: 'h2', path: 'Artiste\\Album\\Autre.flac' },
    ]);

    const summary = await exportStorageIndex({ dbPath, musicDir, outputPath });

    expect(summary).toMatchObject({
      tracksInspected: 2,
      entriesExported: 2,
      validFiles: 2,
      invalidPaths: 0,
      missingFiles: 0,
    });
    const index = readIndex();
    expect(index.version).toBe(STORAGE_INDEX_VERSION);
    expect(index.entries['1']).toEqual({ relativePath: 'Artiste/Album/Piste.flac' });
    expect(index.entries['2']).toEqual({ relativePath: 'Artiste/Album/Autre.flac' });
    expect(Date.parse(index.generatedAt)).not.toBeNaN();
  });

  it('produit un index consommable par le Storage Agent', async () => {
    // Le contrat entre les deux workspaces est vérifié ici de façon
    // structurelle : clés canoniques, unique champ `relativePath`.
    writeTrack('Artiste\\Album\\Piste.flac');
    createDatabase([{ id: 7, hash: 'h', path: 'Artiste\\Album\\Piste.flac' }]);
    await exportStorageIndex({ dbPath, musicDir, outputPath });

    const index = readIndex();
    expect(Object.keys(index)).toEqual(['version', 'generatedAt', 'entries']);
    expect(Object.keys(index.entries)).toEqual(['7']);
    expect(Object.keys(index.entries['7'] ?? {})).toEqual(['relativePath']);
  });

  it('exclut et compte un fichier absent', async () => {
    writeTrack('Artiste\\Present.flac');
    createDatabase([
      { id: 1, hash: 'h1', path: 'Artiste\\Present.flac' },
      { id: 2, hash: 'h2', path: 'Artiste\\Absent.flac' },
    ]);

    const summary = await exportStorageIndex({ dbPath, musicDir, outputPath });

    expect(summary.entriesExported).toBe(1);
    expect(summary.missingFiles).toBe(1);
    expect(summary.anomalies).toEqual([{ trackId: 2, kind: 'missing_file' }]);
    expect(readIndex().entries['2']).toBeUndefined();
  });

  it('exclut et compte un chemin invalide, absolu ou traversant', async () => {
    createDatabase([
      { id: 1, hash: 'h1', path: 'C:\\Windows\\notepad.exe' },
      { id: 2, hash: 'h2', path: '..\\..\\secret.txt' },
      { id: 3, hash: 'h3', path: '' },
      { id: 4, hash: 'h4', path: '\\\\serveur\\partage\\x.flac' },
    ]);

    const summary = await exportStorageIndex({ dbPath, musicDir, outputPath });

    expect(summary.entriesExported).toBe(0);
    expect(summary.invalidPaths).toBe(4);
    expect(readIndex().entries).toEqual({});
  });

  it('n’écrit jamais dans la base SQLite', async () => {
    writeTrack('Artiste\\Piste.flac');
    createDatabase([{ id: 1, hash: 'h1', path: 'Artiste\\Piste.flac' }]);
    const before = statSync(dbPath);
    const bytesBefore = readFileSync(dbPath);

    await exportStorageIndex({ dbPath, musicDir, outputPath });

    const after = statSync(dbPath);
    expect(after.size).toBe(before.size);
    // Comparaison octet à octet : ni écriture, ni journal, ni migration.
    expect(readFileSync(dbPath).equals(bytesBefore)).toBe(true);
    expect(existsSync(`${dbPath}-wal`)).toBe(false);
  });

  it('échoue clairement si la base n’existe pas', async () => {
    await expect(
      exportStorageIndex({ dbPath: join(root, 'absente.db'), musicDir, outputPath }),
    ).rejects.toThrowError();
  });

  it('écrit de façon atomique et ne laisse aucun temporaire', async () => {
    writeTrack('Artiste\\Piste.flac');
    createDatabase([{ id: 1, hash: 'h1', path: 'Artiste\\Piste.flac' }]);

    await exportStorageIndex({ dbPath, musicDir, outputPath });

    expect(existsSync(outputPath)).toBe(true);
    expect(existsSync(`${outputPath}.tmp`)).toBe(false);
  });

  it('remplace un index existant sans passer par un état tronqué', async () => {
    writeTrack('Artiste\\Piste.flac');
    createDatabase([{ id: 1, hash: 'h1', path: 'Artiste\\Piste.flac' }]);
    mkdirSync(join(root, 'out'), { recursive: true });
    writeFileSync(outputPath, '{"version":1,"generatedAt":"2020-01-01T00:00:00.000Z","entries":{}}');

    await exportStorageIndex({ dbPath, musicDir, outputPath });

    expect(Object.keys(readIndex().entries)).toEqual(['1']);
    expect(existsSync(`${outputPath}.tmp`)).toBe(false);
  });

  it('ne modifie aucun fichier audio', async () => {
    writeTrack('Artiste\\Piste.flac');
    createDatabase([{ id: 1, hash: 'h1', path: 'Artiste\\Piste.flac' }]);
    const audioPath = join(musicDir, 'Artiste', 'Piste.flac');
    const before = statSync(audioPath);

    await exportStorageIndex({ dbPath, musicDir, outputPath });

    const after = statSync(audioPath);
    expect(after.mtimeMs).toBe(before.mtimeMs);
    expect(readFileSync(audioPath, 'utf-8')).toBe('audio');
  });
});

describe('formatStorageIndexSummary', () => {
  it('affiche le résumé attendu, sans aucun chemin', async () => {
    writeTrack('Artiste\\Album\\Piste.flac');
    createDatabase([
      { id: 1, hash: 'h1', path: 'Artiste\\Album\\Piste.flac' },
      { id: 2, hash: 'h2', path: 'Artiste\\Album\\Absent.flac' },
      { id: 3, hash: 'h3', path: 'C:\\Windows\\notepad.exe' },
    ]);

    const summary = await exportStorageIndex({ dbPath, musicDir, outputPath });
    const lines = formatStorageIndexSummary(summary);
    const text = lines.join('\n');

    expect(lines[1]).toBe('1 pistes exportées');
    expect(lines[2]).toBe('1 fichiers valides');
    expect(lines[3]).toBe('1 chemin(s) invalide(s)');
    expect(lines[4]).toBe('1 fichier(s) absent(s)');
    // Aucun chemin, absolu ou relatif, ne doit apparaître.
    expect(text).not.toContain(musicDir);
    expect(text).not.toContain('Artiste');
    expect(text).not.toContain('.flac');
    expect(text).not.toContain('C:\\');
    expect(text).toContain('piste #2 — missing_file');
    expect(text).toContain('piste #3 — invalid_path');
  });
});
