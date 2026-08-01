/**
 * CLI d'export de l'index du Storage Agent — LECTURE SEULE.
 *
 * Usage :
 *   pnpm --filter @homespotify/api storage-index:export
 *   pnpm --filter @homespotify/api storage-index:export -- --out F:\chemin\index.json
 *
 * Sortie par défaut : `<racine dépôt>/storage/storage-agent/index.json`, valeur
 * cohérente avec `STORAGE_AGENT_INDEX_PATH` de `services/storage-agent/.env.example`.
 *
 * Ce script n'écrit JAMAIS en base et ne touche JAMAIS un fichier audio.
 */
import { loadConfig, loadDotEnv } from '../config.js';
import {
  exportStorageIndex,
  formatStorageIndexSummary,
} from '../storage/storage-index-export.js';

const DEFAULT_OUTPUT = '../../storage/storage-agent/index.json';

function outputPathFromArgv(argv: readonly string[]): string {
  const flagIndex = argv.indexOf('--out');
  if (flagIndex < 0) return DEFAULT_OUTPUT;
  const value = argv[flagIndex + 1];
  if (value === undefined || value.length === 0 || value.startsWith('--')) {
    throw new Error('--out attend un chemin de fichier');
  }
  return value;
}

async function main(): Promise<void> {
  loadDotEnv();
  const config = loadConfig();
  const outputPath = outputPathFromArgv(process.argv.slice(2));

  const summary = await exportStorageIndex({
    dbPath: config.dbPath,
    musicDir: config.musicDir,
    outputPath,
  });

  for (const line of formatStorageIndexSummary(summary)) console.log(line);

  if (summary.invalidPaths > 0 || summary.missingFiles > 0) {
    // Index tout de même produit : il contient les entrées saines. Le code de
    // sortie signale qu'une intervention est nécessaire.
    process.exitCode = 1;
    return;
  }
  console.log('\nRésultat : index écrit atomiquement, toutes les pistes résolues.');
}

main().catch((error: unknown) => {
  console.error(
    'Export interrompu :',
    error instanceof Error ? error.message : 'erreur inconnue',
  );
  process.exitCode = 1;
});
