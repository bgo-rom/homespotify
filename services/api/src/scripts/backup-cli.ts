import { resolve } from 'node:path';
import { loadConfig, loadDotEnv } from '../config.js';
import { createServerBackup } from '../operations/server-backup.js';

loadDotEnv();
const config = loadConfig();
const destination = argument('--destination');
const includeMedia = process.argv.includes('--include-media');

const manifest = await createServerBackup({
  dbPath: resolve(config.dbPath),
  coversDir: resolve(config.coversDir),
  musicDir: resolve(config.musicDir),
  destinationDir: resolve(destination),
  includeMedia,
});

process.stdout.write(
  `${JSON.stringify({
    destination: resolve(destination),
    createdAt: manifest.createdAt,
    databaseBytes: manifest.database.bytes,
    coversIncluded: manifest.covers.included,
    mediaIncluded: manifest.media.included,
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
