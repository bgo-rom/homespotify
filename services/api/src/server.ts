import { buildApp } from './app.js';
import { loadConfig, loadDotEnv } from './config.js';

// Secrets locaux (LASTFM_API_KEY…) : .env jamais commité (cf. .gitignore).
loadDotEnv();
const config = loadConfig();

// buildApp applique les migrations AVANT d'enregistrer la moindre route. Si le
// schéma ne peut pas être mis à jour, l'exception remonte ici : on journalise
// et on sort en code 1 — jamais de démarrage avec un schéma incomplet.
let app: ReturnType<typeof buildApp>;
try {
  app = buildApp(config);
} catch (err) {
  console.error('[FATAL] Impossible de démarrer : échec des migrations de schéma.', err);
  process.exit(1);
}

let shuttingDown = false;
async function shutdown(signal: string): Promise<void> {
  if (shuttingDown) return;
  shuttingDown = true;
  app.log.info({ signal }, 'arrêt du serveur');
  try {
    await app.close();
    process.exit(0);
  } catch (err) {
    app.log.error({ err }, "échec de l'arrêt propre");
    process.exit(1);
  }
}

process.on('SIGINT', () => void shutdown('SIGINT'));
process.on('SIGTERM', () => void shutdown('SIGTERM'));

try {
  await app.listen({ host: config.host, port: config.port });
} catch (err) {
  app.log.error({ err }, 'échec du démarrage');
  process.exit(1);
}
