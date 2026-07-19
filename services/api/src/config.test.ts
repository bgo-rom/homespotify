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
      nodeFetch: {
        allowedOrigins: [],
        mediaAllowedOrigins: [],
        remoteSearchPathTemplate: '/search?q={query}',
        remoteResolvePathTemplate: '/api/download?trackId={trackId}',
        metadataTimeoutMs: 10_000,
        maxBytes: 200 * 1024 * 1024,
        timeoutMs: 10 * 60_000,
        maxConcurrentJobs: 2,
        maxQueuedJobs: 20,
      },
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

  it('normalise les origines HTTPS autorisées du fetch-node', () => {
    const config = loadConfig({
      NODE_FETCH_ALLOWED_ORIGINS: 'https://audio.example, https://audio.example/,https://backup.example:8443',
      NODE_FETCH_MEDIA_ALLOWED_ORIGINS: 'https://media.example,https://media.example/',
      NODE_FETCH_SEARCH_PATH_TEMPLATE: '/v2/search/{query}',
      NODE_FETCH_REMOTE_RESOLVE_PATH_TEMPLATE: '/v1/resolve/{trackId}',
      NODE_FETCH_METADATA_TIMEOUT_MS: '12000',
      NODE_FETCH_MAX_MB: '350',
      NODE_FETCH_TIMEOUT_MS: '900000',
      NODE_FETCH_MAX_CONCURRENT: '1',
      NODE_FETCH_MAX_QUEUED: '8',
    });
    expect(config.nodeFetch).toEqual({
      allowedOrigins: ['https://audio.example', 'https://backup.example:8443'],
      mediaAllowedOrigins: ['https://media.example'],
      remoteSearchPathTemplate: '/v2/search/{query}',
      remoteResolvePathTemplate: '/v1/resolve/{trackId}',
      metadataTimeoutMs: 12_000,
      maxBytes: 350 * 1024 * 1024,
      timeoutMs: 900_000,
      maxConcurrentJobs: 1,
      maxQueuedJobs: 8,
    });
  });

  it('refuse une origine fetch-node non HTTPS ou contenant un chemin', () => {
    expect(() => loadConfig({
      NODE_FETCH_ALLOWED_ORIGINS: 'http://audio.example',
    })).toThrow(/origines HTTPS/);
    expect(() => loadConfig({
      NODE_FETCH_ALLOWED_ORIGINS: 'https://audio.example/files',
    })).toThrow(/origines HTTPS/);
    expect(() => loadConfig({
      NODE_FETCH_MEDIA_ALLOWED_ORIGINS: 'https://cdn.example/files',
    })).toThrow(/origines HTTPS/);
  });

  it('refuse un template de résolution distant absolu ou sans trackId', () => {
    expect(() => loadConfig({
      NODE_FETCH_REMOTE_RESOLVE_PATH_TEMPLATE: 'https://other.example/api/{trackId}',
    })).toThrow(/chemin relatif/);
    expect(() => loadConfig({
      NODE_FETCH_REMOTE_RESOLVE_PATH_TEMPLATE: '/api/download',
    })).toThrow(/trackId/);
    expect(() => loadConfig({
      NODE_FETCH_SEARCH_PATH_TEMPLATE: 'https://other.example/search?q={query}',
    })).toThrow(/chemin relatif/);
    expect(() => loadConfig({
      NODE_FETCH_SEARCH_PATH_TEMPLATE: '/search',
    })).toThrow(/query/);
  });
});
