import { resolve } from 'node:path';
import { loadConfig, loadDotEnv } from '../config.js';
import { restoreServerBackup } from '../operations/server-backup.js';

loadDotEnv();
const config = loadConfig();
const backupDir = argument('--backup');
if (argument('--confirm') !== 'RESTORE') {
  throw new Error('Confirmation invalide : --confirm RESTORE est obligatoire.');
}

const result = await restoreServerBackup({
  backupDir: resolve(backupDir),
  dbPath: resolve(config.dbPath),
  coversDir: resolve(config.coversDir),
  musicDir: resolve(config.musicDir),
  restoreMedia: process.argv.includes('--restore-media'),
});

process.stdout.write(
  `${JSON.stringify({
    restoredFrom: resolve(backupDir),
    createdAt: result.manifest.createdAt,
    safetyCopyPath: result.safetyCopyPath,
    mediaRestored: process.argv.includes('--restore-media'),
  })}\n`,
);

function argument(name: string): string {
  const index = process.argv.indexOf(name);
  const value = index >= 0 ? process.argv[index + 1] : undefined;
  if (value === undefined || value.startsWith('--')) {
    throw new Error(`Argument obligatoire manquant : ${name}`);
  }
  return value;
}
