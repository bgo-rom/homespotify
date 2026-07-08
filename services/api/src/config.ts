export interface AppConfig {
  nodeEnv: 'development' | 'production' | 'test';
  host: string;
  port: number;
  dbPath: string;
  logLevel: 'fatal' | 'error' | 'warn' | 'info' | 'debug' | 'trace';
}

const NODE_ENVS = ['development', 'production', 'test'] as const;
const LOG_LEVELS = ['fatal', 'error', 'warn', 'info', 'debug', 'trace'] as const;

function oneOf<T extends string>(name: string, value: string, allowed: readonly T[]): T {
  if ((allowed as readonly string[]).includes(value)) return value as T;
  throw new Error(`Config invalide : ${name}="${value}" (attendu : ${allowed.join(', ')})`);
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  const port = Number(env.PORT ?? 3000);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`Config invalide : PORT="${env.PORT}" (entier 1-65535 attendu)`);
  }

  const dbPath = env.DB_PATH ?? './data/homespotify.db';
  if (dbPath.length === 0) {
    throw new Error('Config invalide : DB_PATH vide');
  }

  return {
    nodeEnv: oneOf('NODE_ENV', env.NODE_ENV ?? 'development', NODE_ENVS),
    host: env.HOST ?? '127.0.0.1',
    port,
    dbPath,
    logLevel: oneOf('LOG_LEVEL', env.LOG_LEVEL ?? 'info', LOG_LEVELS),
  };
}
