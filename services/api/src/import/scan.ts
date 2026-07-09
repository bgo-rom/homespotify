import { readdir } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import type { Db } from '../db/client.js';
import { importFromPath, ImportError, type ImportDirs, type Provenance } from './import-service.js';

/**
 * Liste récursive des .wav sous `root`. `node:path` gère les `\` Windows nativement.
 * `exclude` : dossiers à ne pas parcourir (typiquement la bibliothèque gérée, si elle
 * se trouve sous `root` — évite de re-scanner les copies déjà rangées).
 */
export async function findWavFiles(root: string, exclude: string[] = []): Promise<string[]> {
  const resolvedRoot = resolve(root);
  const excluded = new Set(exclude.map((p) => resolve(p)));
  const out: string[] = [];
  async function walk(dir: string): Promise<void> {
    const resolvedDir = resolve(dir);
    // On ne saute JAMAIS la racine explicitement demandée (ex. scanner directement
    // `storage/imports`) ; on n'exclut les dossiers gérés que rencontrés en descendant,
    // pour éviter de re-scanner les copies déjà rangées dans la bibliothèque.
    if (resolvedDir !== resolvedRoot && excluded.has(resolvedDir)) return;
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      return; // dossier illisible (droits, lien cassé) → ignoré, pas fatal
    }
    for (const entry of entries) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(full);
      } else if (entry.isFile() && /\.wav$/i.test(entry.name)) {
        out.push(full);
      }
    }
  }
  await walk(root);
  return out.sort();
}

export interface ScanSummary {
  total: number;
  imported: number;
  duplicates: number;
  failed: number;
  errors: { file: string; reason: string }[];
}

export interface ScanProgress {
  file: string;
  index: number;
  total: number;
  status: 'imported' | 'duplicate' | 'failed';
  detail?: string;
}

/**
 * Ingère en masse tous les WAV d'un dossier local dans la bibliothèque gérée.
 * Déduplication par hash (fichiers déjà en base ignorés). Un échec par fichier
 * n'interrompt pas le lot.
 */
export async function scanDirectory(
  db: Db,
  dirs: ImportDirs,
  root: string,
  provenance: Provenance,
  onProgress?: (p: ScanProgress) => void,
): Promise<ScanSummary> {
  // Exclut les dossiers gérés au cas où ils seraient sous `root` (évite de re-scanner les copies)
  const files = await findWavFiles(root, [dirs.musicDir, dirs.incomingDir, dirs.coversDir]);
  const summary: ScanSummary = {
    total: files.length,
    imported: 0,
    duplicates: 0,
    failed: 0,
    errors: [],
  };

  let index = 0;
  for (const file of files) {
    index += 1;
    try {
      const outcome = await importFromPath(db, dirs, file, provenance);
      if (outcome.status === 'imported') {
        summary.imported += 1;
        onProgress?.({ file, index, total: files.length, status: 'imported' });
      } else {
        summary.duplicates += 1;
        onProgress?.({
          file, index, total: files.length,
          status: 'duplicate', detail: `id ${outcome.existingId}`,
        });
      }
    } catch (err) {
      const reason = err instanceof ImportError ? err.message : String(err);
      summary.failed += 1;
      summary.errors.push({ file, reason });
      onProgress?.({ file, index, total: files.length, status: 'failed', detail: reason });
    }
  }
  return summary;
}
