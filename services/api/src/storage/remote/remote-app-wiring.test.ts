import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterAll, describe, expect, it } from 'vitest';
import { buildApp } from '../../app.js';
import type { AppConfig } from '../../config.js';
import { LocalFileStorageProvider } from '../local-file-storage.js';
import { RemoteWindowsStorageProvider } from './remote-windows-storage.js';
import { CachedAudioStorageProvider } from '../cache/cached-audio-storage.js';

const base = mkdtempSync(join(tmpdir(), 'homespotify-remote-wiring-'));

afterAll(() => {
  rmSync(base, { recursive: true, force: true });
});

describe('câblage du stockage distant', () => {
  it('remote ne change jamais le provider local des dérivées offline', async () => {
    const config: AppConfig = {
      nodeEnv: 'test',
      host: '127.0.0.1',
      port: 0,
      dbPath: ':memory:',
      logLevel: 'error',
      musicDir: join(base, 'music'),
      incomingDir: join(base, 'imports'),
      importRoot: join(base, 'imports'),
      coversDir: join(base, 'covers'),
      audioStorageMode: 'remote',
      audioRemote: {
        baseUrl: 'http://127.0.0.1:3100',
        sharedSecret: 'x'.repeat(32),
        connectTimeoutMs: 2_000,
        headersTimeoutMs: 5_000,
        bodyIdleTimeoutMs: 15_000,
        maxConnections: 8,
      },
      offline: {
        derivedCacheDir: join(base, 'offline'),
        encodeConcurrency: 1,
      },
      maxUploadBytes: 200 * 1024 * 1024,
      authTokenSecret: 'test-secret-0123456789abcdef0123456789abcdef',
      accessTokenTtlSeconds: 900,
      refreshTokenTtlSeconds: 30 * 24 * 60 * 60,
    };
    const app = buildApp(config, { importWatcher: false });
    await app.ready();
    expect(app.audioStorage).toBeInstanceOf(RemoteWindowsStorageProvider);
    expect(app.offlineVariantStorage).toBeInstanceOf(LocalFileStorageProvider);
    await app.close();
  });

  it('cached décore le distant sans changer les dérivées offline', async () => {
    const config: AppConfig = {
      nodeEnv: 'test',
      host: '127.0.0.1',
      port: 0,
      dbPath: ':memory:',
      logLevel: 'error',
      musicDir: join(base, 'music-cached'),
      incomingDir: join(base, 'imports-cached'),
      importRoot: join(base, 'imports-cached'),
      coversDir: join(base, 'covers-cached'),
      audioStorageMode: 'cached',
      audioRemote: {
        baseUrl: 'http://127.0.0.1:3100',
        sharedSecret: 'x'.repeat(32),
        connectTimeoutMs: 2_000,
        headersTimeoutMs: 5_000,
        bodyIdleTimeoutMs: 15_000,
        maxConnections: 8,
      },
      audioCache: {
        root: join(base, 'audio-cache'),
        maxBytes: 1024 * 1024,
        minFreeBytes: 1,
        tempMaxAgeMs: 1000,
        fillOnFullGet: true,
        verifyOnHit: 'size',
        evictionTargetRatio: 0.9,
      },
      offline: {
        derivedCacheDir: join(base, 'offline-cached'),
        encodeConcurrency: 1,
      },
      maxUploadBytes: 200 * 1024 * 1024,
      authTokenSecret: 'test-secret-0123456789abcdef0123456789abcdef',
      accessTokenTtlSeconds: 900,
      refreshTokenTtlSeconds: 30 * 24 * 60 * 60,
    };
    const app = buildApp(config, { importWatcher: false });
    await app.ready();
    expect(app.audioStorage).toBeInstanceOf(CachedAudioStorageProvider);
    expect(app.offlineVariantStorage).toBeInstanceOf(LocalFileStorageProvider);
    await app.close();
  });
});
