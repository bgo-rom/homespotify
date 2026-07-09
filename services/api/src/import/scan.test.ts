import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { createDb, type DbHandle } from '../db/client.js';
import { runMigrations } from '../db/migrate.js';
import { findAudioFiles, scanDirectory } from './scan.js';
import type { ImportDirs } from './import-service.js';
import { makeWav } from '../test/wav.js';
import { makeFlac } from '../test/flac.js';

let base: string;
let handle: DbHandle;
let dirs: ImportDirs;
let library: string;

beforeEach(() => {
  base = mkdtempSync(join(tmpdir(), 'homespotify-scan-'));
  library = join(base, 'source'); // bibliothèque WAV existante de l'utilisateur
  dirs = {
    musicDir: join(base, 'music'),
    incomingDir: join(base, 'imports'),
    coversDir: join(base, 'covers'),
  };
  for (const d of [library, dirs.musicDir, dirs.incomingDir, dirs.coversDir]) {
    mkdirSync(d, { recursive: true });
  }
  handle = createDb(':memory:');
  runMigrations(handle);
});

afterEach(() => {
  handle.sqlite.close();
  rmSync(base, { recursive: true, force: true });
});

describe('findAudioFiles', () => {
  it('trouve les .wav récursivement (sous-dossiers, casse), ignore le reste', () => {
    mkdirSync(join(library, 'Artiste', 'Album'), { recursive: true });
    writeFileSync(join(library, 'a.wav'), makeWav());
    writeFileSync(join(library, 'Artiste', 'Album', 'b.WAV'), makeWav({ seconds: 0.06 }));
    writeFileSync(join(library, 'notes.txt'), 'pas un wav');
    writeFileSync(join(library, 'cover.jpg'), 'pas un wav');
    const found = findAudioFiles(library);
    return found.then((files) => {
      expect(files).toHaveLength(2);
      expect(files.every((f) => /\.wav$/i.test(f))).toBe(true);
    });
  });

  it('scanne la racine même si elle figure dans la liste d\'exclusion (staging), ignore .gitkeep', async () => {
    // Reproduit le bug : root == dossier exclu (ex. storage/imports). Noms avec
    // espaces/parenthèses/accents.
    writeFileSync(join(library, 'Britney (All Black).wav'), makeWav());
    writeFileSync(join(library, 'LA FÈVE -  Finis-les.wav'), makeWav({ seconds: 0.06 }));
    writeFileSync(join(library, '.gitkeep'), '');

    const files = await findAudioFiles(library, [library]); // la racine est exclue…
    expect(files).toHaveLength(2); // …mais scannée quand même
    expect(files.every((f) => /\.wav$/i.test(f))).toBe(true);
  });

  it('trouve aussi les .flac (casse ignorée) et ignore les non-audio', async () => {
    writeFileSync(join(library, 'a.FLAC'), makeFlac());
    writeFileSync(join(library, 'b.Wav'), makeWav());
    writeFileSync(join(library, 'c.txt'), 'pas audio');
    const files = await findAudioFiles(library);
    expect(files).toHaveLength(2);
    expect(files.every((f) => /\.(wav|flac)$/i.test(f))).toBe(true);
  });
});

describe('scanDirectory', () => {
  it('ingère tous les WAV et copie dans la bibliothèque gérée (original préservé)', async () => {
    writeFileSync(join(library, 'one.wav'), makeWav({ title: 'Un', artist: 'A', seconds: 0.1 }));
    mkdirSync(join(library, 'sub'));
    writeFileSync(join(library, 'sub', 'two.wav'), makeWav({ title: 'Deux', artist: 'B', seconds: 0.12 }));

    const summary = await scanDirectory(handle.db, dirs, library, 'rip_cd');
    expect(summary).toMatchObject({ total: 2, imported: 2, duplicates: 0, failed: 0 });

    // Originaux toujours là (copie, pas déplacement)
    await expect(findAudioFiles(library)).resolves.toHaveLength(2);
    // Et rangés dans la bibliothèque gérée
    const managed = await findAudioFiles(dirs.musicDir);
    expect(managed).toHaveLength(2);
  });

  it('déduplique au re-scan : rien de nouveau importé', async () => {
    writeFileSync(join(library, 'x.wav'), makeWav({ title: 'X', seconds: 0.2 }));
    const first = await scanDirectory(handle.db, dirs, library, 'rip_cd');
    expect(first.imported).toBe(1);

    const second = await scanDirectory(handle.db, dirs, library, 'rip_cd');
    expect(second).toMatchObject({ total: 1, imported: 0, duplicates: 1, failed: 0 });
  });

  it('déduplique un même contenu présent sous deux noms/chemins', async () => {
    const wav = makeWav({ title: 'Copie', seconds: 0.15 });
    writeFileSync(join(library, 'original.wav'), wav);
    mkdirSync(join(library, 'backup'));
    writeFileSync(join(library, 'backup', 'copie.wav'), wav); // contenu identique → même hash

    const summary = await scanDirectory(handle.db, dirs, library, 'achat');
    expect(summary).toMatchObject({ total: 2, imported: 1, duplicates: 1, failed: 0 });
  });

  it('compte les fichiers invalides en échec sans interrompre le lot', async () => {
    writeFileSync(join(library, 'bon.wav'), makeWav({ title: 'Bon', seconds: 0.1 }));
    writeFileSync(join(library, 'faux.wav'), Buffer.from('pas un vrai wav'));
    writeFileSync(join(library, 'hires.wav'), makeWav({ sampleRate: 96000, seconds: 0.1 }));

    const summary = await scanDirectory(handle.db, dirs, library, 'rip_cd');
    expect(summary.total).toBe(3);
    expect(summary.imported).toBe(1);
    expect(summary.failed).toBe(2); // faux (illisible) + hires (specs refusées)
    expect(summary.errors).toHaveLength(2);
  });

  it('ne re-scanne pas la bibliothèque gérée si elle est sous le dossier scanné', async () => {
    // musicDir placé DANS la source → sans exclusion, le 2e scan verrait les copies
    const nestedDirs: ImportDirs = {
      musicDir: join(library, '_managed'),
      incomingDir: join(library, '_incoming'),
      coversDir: join(library, '_covers'),
    };
    for (const d of Object.values(nestedDirs)) mkdirSync(d, { recursive: true });
    writeFileSync(join(library, 'song.wav'), makeWav({ title: 'Song', seconds: 0.2 }));

    const first = await scanDirectory(handle.db, nestedDirs, library, 'rip_cd');
    expect(first).toMatchObject({ total: 1, imported: 1 });

    // Re-scan : la copie gérée sous library/_managed ne doit PAS être vue comme un nouveau fichier
    const second = await scanDirectory(handle.db, nestedDirs, library, 'rip_cd');
    expect(second.total).toBe(1); // seulement l'original, pas la copie gérée
    expect(second.duplicates).toBe(1);
  });

  it('ingère quand la racine scannée EST le dossier de staging configuré (storage/imports)', async () => {
    // Cas réel du bug : l'utilisateur pointe le scan directement sur incomingDir.
    writeFileSync(join(dirs.incomingDir, 'BIA - WE ON GO.wav'), makeWav({ title: 'WE ON GO', artist: 'BIA', seconds: 0.2 }));
    writeFileSync(join(dirs.incomingDir, 'LA FÈVE -  Finis-les.wav'), makeWav({ title: 'Finis-les', artist: 'LA FÈVE', seconds: 0.21 }));
    writeFileSync(join(dirs.incomingDir, '.gitkeep'), '');

    const summary = await scanDirectory(handle.db, dirs, dirs.incomingDir, 'rip_cd');
    expect(summary).toMatchObject({ total: 2, imported: 2, duplicates: 0, failed: 0 });
  });

  it('importe un FLAC (bit-perfect, rangé en .flac)', async () => {
    writeFileSync(join(library, 'chanson.flac'), makeFlac({ seconds: 0.2 }));
    const summary = await scanDirectory(handle.db, dirs, library, 'achat');
    expect(summary).toMatchObject({ total: 1, imported: 1, failed: 0 });
    const managed = await findAudioFiles(dirs.musicDir);
    expect(managed).toHaveLength(1);
    expect(managed[0]!.endsWith('.flac')).toBe(true);
  });

  it('provenance propagée au statut qualité', async () => {
    writeFileSync(join(library, 'ia.wav'), makeWav({ title: 'IA', seconds: 0.1 }));
    await scanDirectory(handle.db, dirs, library, 'upscale_ia');
    const row = handle.sqlite.prepare('SELECT status, provenance FROM track_quality').get() as {
      status: string;
      provenance: string;
    };
    expect(row).toEqual({ status: 'lossy', provenance: 'upscale_ia' });
  });
});
