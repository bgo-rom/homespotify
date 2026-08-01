/**
 * Export de l'index `trackId → chemin relatif` destiné au Storage Agent
 * (Phase 2 du plan de migration VPS).
 *
 * Contrat de sûreté :
 * - la base SQLite est ouverte en `readonly` — aucune écriture possible ;
 * - aucun fichier audio n'est ouvert (seulement `stat`) ni modifié ;
 * - les chemins Windows (`\`) sont normalisés en chemins portables (`/`) via
 *   les primitives de la Phase 1, seul point de vérité ;
 * - toute entrée invalide est EXCLUE de l'index et comptée, jamais « réparée » ;
 * - la sortie est écrite dans un fichier temporaire puis renommée : le Storage
 *   Agent ne peut jamais lire un index partiellement écrit ;
 * - aucun chemin, complet ou relatif, n'est affiché — seulement des compteurs
 *   et des identifiants de pistes.
 *
 * La synchronisation automatique de ce fichier vers le PC (et, plus tard,
 * depuis le VPS) n'est PAS traitée ici : elle relève d'une phase ultérieure.
 */
import Database from 'better-sqlite3';
import { stat } from 'node:fs/promises';
import { renameSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { mkdirSync } from 'node:fs';
import {
  AudioStorageError,
  trackStorageReference,
} from './audio-storage.js';
import { LocalFileStorageProvider } from './local-file-storage.js';

/** Version du format d'index. Doit rester alignée sur le Storage Agent. */
export const STORAGE_INDEX_VERSION = 1;

export interface StorageIndexAnomaly {
  trackId: number;
  kind: 'invalid_path' | 'traversal' | 'missing_file' | 'not_a_file';
}

export interface StorageIndexExportSummary {
  tracksInspected: number;
  entriesExported: number;
  validFiles: number;
  invalidPaths: number;
  missingFiles: number;
  anomalies: StorageIndexAnomaly[];
  generatedAt: string;
}

interface TrackRow {
  id: number;
  path: string;
  hash: string;
}

export interface ExportStorageIndexOptions {
  dbPath: string;
  musicDir: string;
  /** Chemin FINAL de l'index. Le temporaire est `<outputPath>.tmp`. */
  outputPath: string;
  now?: () => Date;
}

/**
 * Produit l'index et retourne le résumé.
 *
 * Lève si la base est illisible ; ne lève jamais pour une piste isolée — une
 * anomalie de piste est comptée et exclue, pour qu'un seul chemin cassé ne
 * bloque pas les 157 autres.
 */
export async function exportStorageIndex(
  options: ExportStorageIndexOptions,
): Promise<StorageIndexExportSummary> {
  // readonly + fileMustExist : impossible de créer, migrer ou modifier la base.
  const db = new Database(options.dbPath, { readonly: true, fileMustExist: true });
  let rows: TrackRow[];
  try {
    rows = db.prepare('SELECT id, path, hash FROM tracks ORDER BY id').all() as TrackRow[];
  } finally {
    db.close();
  }

  const provider = new LocalFileStorageProvider(options.musicDir);
  const entries: Record<string, { relativePath: string }> = {};
  const anomalies: StorageIndexAnomaly[] = [];
  let validFiles = 0;

  for (const row of rows) {
    let relativePath: string;
    let absolutePath: string;
    try {
      const reference = trackStorageReference(row);
      // `resolvePath` applique la seconde barrière de confinement : une entrée
      // qui sort de MUSIC_DIR n'entre jamais dans l'index.
      absolutePath = provider.resolvePath(reference);
      relativePath = reference.relativePath;
    } catch (error) {
      const traversal =
        error instanceof AudioStorageError && error.code === 'PATH_TRAVERSAL';
      anomalies.push({ trackId: row.id, kind: traversal ? 'traversal' : 'invalid_path' });
      continue;
    }

    try {
      const info = await stat(absolutePath);
      if (!info.isFile()) {
        anomalies.push({ trackId: row.id, kind: 'not_a_file' });
        continue;
      }
    } catch {
      anomalies.push({ trackId: row.id, kind: 'missing_file' });
      continue;
    }

    validFiles += 1;
    entries[String(row.id)] = { relativePath };
  }

  const generatedAt = (options.now?.() ?? new Date()).toISOString();
  const document = {
    version: STORAGE_INDEX_VERSION,
    generatedAt,
    entries,
  };

  const outputPath = resolve(options.outputPath);
  mkdirSync(dirname(outputPath), { recursive: true });
  const temporaryPath = `${outputPath}.tmp`;
  // Écriture complète puis renommage : sur le même volume, `rename` remplace la
  // cible atomiquement — le Storage Agent lit soit l'ancien index, soit le
  // nouveau, jamais un fichier tronqué.
  writeFileSync(temporaryPath, `${JSON.stringify(document, null, 2)}\n`, 'utf-8');
  renameSync(temporaryPath, outputPath);

  return {
    tracksInspected: rows.length,
    entriesExported: Object.keys(entries).length,
    validFiles,
    invalidPaths: anomalies.filter(
      (anomaly) => anomaly.kind === 'invalid_path' || anomaly.kind === 'traversal',
    ).length,
    missingFiles: anomalies.filter(
      (anomaly) => anomaly.kind === 'missing_file' || anomaly.kind === 'not_a_file',
    ).length,
    anomalies,
    generatedAt,
  };
}

/** Résumé textuel — compteurs et identifiants seulement, aucun chemin. */
export function formatStorageIndexSummary(summary: StorageIndexExportSummary): string[] {
  const lines = [
    '--- Export de l’index Storage Agent (lecture seule) ---',
    `${summary.entriesExported} pistes exportées`,
    `${summary.validFiles} fichiers valides`,
    `${summary.invalidPaths} chemin(s) invalide(s)`,
    `${summary.missingFiles} fichier(s) absent(s)`,
  ];
  if (summary.anomalies.length > 0) {
    lines.push('--- Anomalies (identifiants seuls) ---');
    for (const anomaly of summary.anomalies.slice(0, 50)) {
      lines.push(`  piste #${anomaly.trackId} — ${anomaly.kind}`);
    }
    if (summary.anomalies.length > 50) {
      lines.push(`  … et ${summary.anomalies.length - 50} autre(s)`);
    }
  }
  return lines;
}
