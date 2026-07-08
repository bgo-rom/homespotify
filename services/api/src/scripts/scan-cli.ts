import { mkdirSync } from 'node:fs';
import { loadConfig } from '../config.js';
import { createDb } from '../db/client.js';
import { runMigrations } from '../db/migrate.js';
import { scanDirectory } from '../import/scan.js';
import { PROVENANCES, type Provenance } from '../import/import-service.js';

// Usage : pnpm --filter @homespotify/api scan -- "C:\\Musique_HomeSpotify" [--provenance rip_cd]
function parseArgs(argv: string[]): { root: string; provenance: Provenance } {
  const args = argv.slice(2);
  let provenance: Provenance = 'inconnue';
  const positional: string[] = [];
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === '--provenance') {
      const v = args[i + 1];
      if (!v || !(PROVENANCES as readonly string[]).includes(v)) {
        throw new Error(`--provenance invalide (attendu : ${PROVENANCES.join(', ')})`);
      }
      provenance = v as Provenance;
      i += 1;
    } else {
      positional.push(args[i]!);
    }
  }
  if (positional.length === 0) {
    throw new Error('Chemin du dossier à scanner manquant. Ex : scan "C:\\Musique_HomeSpotify" --provenance rip_cd');
  }
  return { root: positional[0]!, provenance };
}

async function main(): Promise<number> {
  const { root, provenance } = parseArgs(process.argv);
  const config = loadConfig();
  for (const dir of [config.musicDir, config.incomingDir, config.coversDir]) {
    mkdirSync(dir, { recursive: true });
  }
  const handle = createDb(config.dbPath);
  runMigrations(handle);

  console.log(`Scan de "${root}" (provenance : ${provenance})…`);
  try {
    const summary = await scanDirectory(handle.db, config, root, provenance, (p) => {
      const tag = p.status === 'imported' ? 'OK  ' : p.status === 'duplicate' ? 'SKIP' : 'FAIL';
      console.log(`[${p.index}/${p.total}] ${tag} ${p.file}${p.detail ? ` — ${p.detail}` : ''}`);
    });
    console.log(
      `\nTerminé : ${summary.imported} importés, ${summary.duplicates} déjà présents, ` +
        `${summary.failed} en échec (sur ${summary.total} WAV trouvés).`,
    );
    return summary.failed > 0 ? 1 : 0;
  } finally {
    handle.sqlite.close();
  }
}

main().then(
  (code) => process.exit(code),
  (err) => {
    console.error(`Erreur : ${err instanceof Error ? err.message : String(err)}`);
    process.exit(1);
  },
);
