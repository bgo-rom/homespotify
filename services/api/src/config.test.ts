import { describe, expect, it } from 'vitest';
import { loadConfig } from './config.js';

describe('loadConfig', () => {
  it('applique les valeurs par défaut', () => {
    const config = loadConfig({});
    expect(config).toMatchObject({
      nodeEnv: 'development',
      host: '127.0.0.1',
      port: 3000,
      dbPath: './data/homespotify.db',
      logLevel: 'info',
      musicDir: '../../storage/music',
      incomingDir: '../../storage/imports',
      importRoot: '../../storage/imports',
      coversDir: '../../storage/covers',
      maxUploadBytes: 200 * 1024 * 1024,
      accessTokenTtlSeconds: 900,
      refreshTokenTtlSeconds: 30 * 24 * 60 * 60,
    });
    // Hors production sans AUTH_TOKEN_SECRET : secret éphémère généré.
    expect(config.authTokenSecret.length).toBeGreaterThanOrEqual(32);
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
      AUTH_TOKEN_SECRET: 's'.repeat(48),
    });
    expect(config.nodeEnv).toBe('production');
    expect(config.port).toBe(8080);
    expect(config.dbPath).toBe('/data/db/app.db');
    expect(config.authTokenSecret).toBe('s'.repeat(48));
  });

  it('exige AUTH_TOKEN_SECRET en production', () => {
    expect(() => loadConfig({ NODE_ENV: 'production' })).toThrow(/AUTH_TOKEN_SECRET/);
  });

  it('rejette un AUTH_TOKEN_SECRET trop court', () => {
    expect(() => loadConfig({ AUTH_TOKEN_SECRET: 'court' })).toThrow(/AUTH_TOKEN_SECRET/);
  });

  it('rejette un PORT invalide', () => {
    expect(() => loadConfig({ PORT: 'abc' })).toThrow(/PORT/);
    expect(() => loadConfig({ PORT: '70000' })).toThrow(/PORT/);
  });

  it('rejette un NODE_ENV inconnu', () => {
    expect(() => loadConfig({ NODE_ENV: 'staging' })).toThrow(/NODE_ENV/);
  });

});
