import { describe, expect, it } from 'vitest';
import { loadConfig } from './config.js';

describe('loadConfig', () => {
  it('applique les valeurs par défaut', () => {
    const config = loadConfig({});
    expect(config).toEqual({
      nodeEnv: 'development',
      host: '127.0.0.1',
      port: 3000,
      dbPath: './data/homespotify.db',
      logLevel: 'info',
      musicDir: '../../storage/music',
      incomingDir: '../../storage/imports',
      coversDir: '../../storage/covers',
      maxUploadBytes: 200 * 1024 * 1024,
    });
  });

  it('rejette une limite upload sous 150 Mo (contrainte WAV)', () => {
    expect(() => loadConfig({ MAX_UPLOAD_MB: '50' })).toThrow(/MAX_UPLOAD_MB/);
  });

  it('lit les variables fournies', () => {
    const config = loadConfig({
      NODE_ENV: 'production',
      HOST: '0.0.0.0',
      PORT: '8080',
      DB_PATH: '/data/db/app.db',
      LOG_LEVEL: 'warn',
    });
    expect(config.nodeEnv).toBe('production');
    expect(config.port).toBe(8080);
    expect(config.dbPath).toBe('/data/db/app.db');
  });

  it('rejette un PORT invalide', () => {
    expect(() => loadConfig({ PORT: 'abc' })).toThrow(/PORT/);
    expect(() => loadConfig({ PORT: '70000' })).toThrow(/PORT/);
  });

  it('rejette un NODE_ENV inconnu', () => {
    expect(() => loadConfig({ NODE_ENV: 'staging' })).toThrow(/NODE_ENV/);
  });
});
