import { readFileSync } from 'node:fs';
import Fastify, { type FastifyError, type FastifyInstance } from 'fastify';
import { type AppConfig } from './config.js';
import { createDb, type DbHandle } from './db/client.js';
import { runMigrations, isDbInitialized } from './db/migrate.js';

const pkg = JSON.parse(
  readFileSync(new URL('../package.json', import.meta.url), 'utf-8'),
) as { name: string; version: string };

export const CURRENT_PHASE = 'Phase 1 — backend minimal';

declare module 'fastify' {
  interface FastifyInstance {
    dbHandle: DbHandle;
    config: AppConfig;
  }
}

export function buildApp(config: AppConfig): FastifyInstance {
  const app = Fastify({
    logger: {
      level: config.logLevel,
      // pino est le logger natif de Fastify ; en test on ne veut aucun bruit
      enabled: config.nodeEnv !== 'test',
    },
  });

  const dbHandle = createDb(config.dbPath);
  // Idempotent et rapide : sûr à chaque démarrage pour un serveur mono-utilisateur.
  runMigrations(dbHandle);

  app.decorate('config', config);
  app.decorate('dbHandle', dbHandle);

  app.addHook('onClose', async () => {
    dbHandle.sqlite.close();
  });

  app.setErrorHandler((error: FastifyError, request, reply) => {
    request.log.error({ err: error }, 'unhandled error');
    const statusCode = error.statusCode && error.statusCode >= 400 ? error.statusCode : 500;
    const message =
      statusCode >= 500 && config.nodeEnv === 'production'
        ? 'Internal Server Error'
        : error.message;
    reply.status(statusCode).send({ statusCode, error: 'error', message });
  });

  app.setNotFoundHandler((request, reply) => {
    reply.status(404).send({
      statusCode: 404,
      error: 'not_found',
      message: `Route ${request.method} ${request.url} inconnue`,
    });
  });

  app.get('/health', async () => ({
    status: 'ok',
    timestamp: new Date().toISOString(),
    uptimeSeconds: Math.round(process.uptime()),
  }));

  app.get('/version', async () => ({
    name: pkg.name,
    version: pkg.version,
    environment: config.nodeEnv,
  }));

  app.get('/api/status', async () => ({
    phase: CURRENT_PHASE,
    backendReady: true,
    database: isDbInitialized(dbHandle) ? 'initialized' : 'not_initialized',
  }));

  return app;
}
