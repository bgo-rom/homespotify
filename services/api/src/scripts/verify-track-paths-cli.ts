/**
 * Vérification en LECTURE SEULE des chemins de la table `tracks`.
 *
 * Contrôle que chaque chemin stocké (format Windows avec `\`) se normalise en
 * chemin portable, se résout sous MUSIC_DIR sans traversal, et désigne un
 * fichier réellement présent. C'est le critère d'acceptation n°6 de la Phase 1
 * du plan de migration VPS.
 *
 * Garanties :
 * - la base est ouverte en `readonly` — aucune écriture possible ;
 * - aucun fichier audio n'est ouvert ni modifié (seulement `stat`) ;
 * - aucun chemin complet n'est affiché : uniquement des compteurs et, pour les
 *   anomalies, l'identifiant de piste et le motif.
 *
 * Usage :
 *   pnpm --filter @homespotify/api run verify:paths
 */
import Database from 'better-sqlite3';
import { stat } from 'node:fs/promises';
import { loadConfig, loadDotEnv } from '../config.js';
import {
  AudioStorageError,
  trackStorageReference,
} from '../storage/audio-storage.js';
import { LocalFileStorageProvider } from '../storage/local-file-storage.js';

interface TrackRow {
  id: number;
  path: string;
  hash: string;
}

interface Anomaly {
  trackId: number;
  kind: 'absolute' | 'traversal' | 'invalid' | 'missing' | 'not_a_file';
  detail: string;
}

async function main(): Promise<void> {
  loadDotEnv();
  const config = loadConfig();

  // readonly + fileMustExist : impossible de créer ou de modifier quoi que ce soit.
  const db = new Database(config.dbPath, {
    readonly: true,
    fileMustExist: true,
  });

  const rows = db
    .prepare('SELECT id, path, hash FROM tracks ORDER BY id')
    .all() as TrackRow[];
  db.close();

  const provider = new LocalFileStorageProvider(config.musicDir);

  let resolved = 0;
  let windowsSeparators = 0;
  const anomalies: Anomaly[] = [];

  for (const row of rows) {
    if (row.path.includes('\\')) windowsSeparators += 1;

    let absolutePath: string;
    try {
      const reference = trackStorageReference(row);
      absolutePath = provider.resolvePath(reference);
    } catch (error) {
      const code =
        error instanceof AudioStorageError ? error.code : 'INVALID_REFERENCE';
      anomalies.push({
        trackId: row.id,
        kind: code === 'PATH_TRAVERSAL' ? 'traversal' : 'invalid',
        detail: error instanceof Error ? error.message : 'erreur inconnue',
      });
      continue;
    }

    try {
      const info = await stat(absolutePath);
      if (!info.isFile()) {
        anomalies.push({
          trackId: row.id,
          kind: 'not_a_file',
          detail: 'la référence ne désigne pas un fichier régulier',
        });
        continue;
      }
      resolved += 1;
    } catch {
      anomalies.push({
        trackId: row.id,
        kind: 'missing',
        detail: 'fichier introuvable sur le disque',
      });
    }
  }

  const absolute = anomalies.filter((a) => a.kind === 'invalid').length;
  const traversal = anomalies.filter((a) => a.kind === 'traversal').length;
  const missing = anomalies.filter(
    (a) => a.kind === 'missing' || a.kind === 'not_a_file',
  ).length;

  console.log('--- Vérification des chemins de la bibliothèque (lecture seule) ---');
  console.log(`${rows.length} chemins inspectés`);
  console.log(`${resolved} fichiers résolus`);
  console.log(`${absolute} chemin(s) invalide(s) ou absolu(s)`);
  console.log(`${traversal} tentative(s) de traversal`);
  console.log(`${missing} fichier(s) manquant(s)`);
  console.log(`${windowsSeparators} chemin(s) au format Windows (séparateur \\)`);

  if (anomalies.length > 0) {
    console.log('\n--- Anomalies (identifiants seuls, aucun chemin affiché) ---');
    for (const anomaly of anomalies.slice(0, 50)) {
      console.log(`  piste #${anomaly.trackId} — ${anomaly.kind} : ${anomaly.detail}`);
    }
    if (anomalies.length > 50) {
      console.log(`  … et ${anomalies.length - 50} autre(s)`);
    }
    process.exitCode = 1;
    return;
  }

  console.log('\nRésultat : toutes les références sont valides et résolues.');
}

main().catch((error: unknown) => {
  console.error(
    'Vérification interrompue :',
    error instanceof Error ? error.message : error,
  );
  process.exitCode = 1;
});
