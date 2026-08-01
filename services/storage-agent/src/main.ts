/**
 * Point d'entrée du Storage Agent.
 *
 * Phase 2 : exécution manuelle en développement local uniquement. L'agent
 * écoute par défaut sur 127.0.0.1:3100 — aucune exposition réseau, aucun
 * service Windows, aucune règle de pare-feu. Le bind sur 10.8.0.2 et
 * l'installation WinSW appartiennent à la Phase 3.
 */
import { loadDotEnv, loadStorageAgentConfig } from './config.js';
import { buildStorageAgent } from './server.js';

async function main(): Promise<void> {
  // Le chemin du fichier d'environnement est explicite en service Windows :
  // WinSW 2.x n'a pas d'élément `envFile`, et le secret n'a rien à faire dans
  // le XML du service. `STORAGE_AGENT_ENV_FILE` ne porte qu'un chemin.
  loadDotEnv(process.env.STORAGE_AGENT_ENV_FILE ?? '.env');
  const config = loadStorageAgentConfig();
  const app = buildStorageAgent({ config });

  const shutdown = (signal: string): void => {
    // Arrêt gracieux : Fastify laisse les flux en cours se terminer.
    app.log.info({ event: 'STORAGE_AGENT_SHUTDOWN', signal }, 'STORAGE_AGENT_SHUTDOWN');
    void app.close().then(() => process.exit(0));
  };
  process.once('SIGINT', () => shutdown('SIGINT'));
  process.once('SIGTERM', () => shutdown('SIGTERM'));

  await app.listen({ host: config.host, port: config.port });
  // La configuration n'est PAS journalisée : ni secret, ni racine musicale.
  app.log.info(
    {
      event: 'STORAGE_AGENT_STARTED',
      host: config.host,
      port: config.port,
      maxConcurrentStreams: config.maxConcurrentStreams,
      indexEntryCount: app.storageAgent.indexStore.current?.entries.size ?? 0,
    },
    'STORAGE_AGENT_STARTED',
  );
}

main().catch((error: unknown) => {
  console.error(
    'Storage Agent : démarrage impossible —',
    error instanceof Error ? error.message : 'erreur inconnue',
  );
  process.exitCode = 1;
});
