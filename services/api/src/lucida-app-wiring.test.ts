import { randomUUID } from 'node:crypto';
import {
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { eq } from 'drizzle-orm';
import { buildApp } from './app.js';
import {
  loadConfig,
  type AppConfig,
} from './config.js';
import { createDb } from './db/client.js';
import { runMigrations } from './db/migrate.js';
import {
  acquisitionJobs,
  users,
} from './db/schema.js';
import type { AcquisitionRunner } from './import/acquisition-import-service.js';

const roots: string[] = [];

function temporaryRoot(prefix: string): string {
  const root = mkdtempSync(join(tmpdir(), prefix));
  roots.push(root);
  return root;
}

function baseConfig(root: string, dbPath: string): AppConfig {
  return {
    nodeEnv: 'test',
    host: '127.0.0.1',
    port: 0,
    dbPath,
    logLevel: 'fatal',
    musicDir: join(root, 'music'),
    incomingDir: join(root, 'imports'),
    importRoot: join(root, 'imports'),
    coversDir: join(root, 'covers'),
    maxUploadBytes: 200 * 1024 * 1024,
    authTokenSecret: 'test-secret-0123456789abcdef0123456789abcdef',
    accessTokenTtlSeconds: 900,
    refreshTokenTtlSeconds: 30 * 24 * 60 * 60,
  };
}

afterEach(() => {
  for (const root of roots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

describe('configuration Lucida', () => {
  it('reste désactivée quand LUCIDA_SCRIPT_PATH est absent', () => {
    const config = loadConfig({
      NODE_ENV: 'test',
    });

    expect(config.lucida).toBeUndefined();
  });

  it('résout le script, Python et le timeout global', () => {
    const root = temporaryRoot('homespotify-lucida-config-');
    const scriptPath = join(root, 'lucida_dl_final.py');
    writeFileSync(scriptPath, '# test-only\n', 'utf-8');

    const config = loadConfig({
      NODE_ENV: 'test',
      LUCIDA_SCRIPT_PATH: scriptPath,
      LUCIDA_PYTHON_PATH: 'python-test',
      LUCIDA_PROCESS_TIMEOUT_SECONDS: '420',
    });

    expect(config.lucida).toEqual({
      scriptPath: resolve(scriptPath),
      pythonPath: 'python-test',
      processTimeoutMs: 420_000,
      // Défaut : 3 téléchargements simultanés.
      maxConcurrentDownloads: 3,
      challengeCooldownSeconds: 1_800,
      rateLimitDefaultCooldownSeconds: 900,
      unavailableCooldownSeconds: 600,
      maxCooldownSeconds: 21_600,
      providerFailureWindowSeconds: 600,
      providerFailureThreshold: 2,
      interactiveVerificationEnabled: false,
      interactiveVerificationTimeoutSeconds: 120,
    });
  });

  it('borne la concurrence des téléchargements entre 1 et 4', () => {
    const root = temporaryRoot('homespotify-lucida-concurrency-');
    const scriptPath = join(root, 'lucida_dl_final.py');
    writeFileSync(scriptPath, '# test-only\n', 'utf-8');

    const withValue = (value: string): number | undefined =>
      loadConfig({
        NODE_ENV: 'test',
        LUCIDA_SCRIPT_PATH: scriptPath,
        LUCIDA_MAX_CONCURRENT_DOWNLOADS: value,
      }).lucida?.maxConcurrentDownloads;

    expect(withValue('1')).toBe(1);
    expect(withValue('4')).toBe(4);
    // Hors bornes : la configuration doit échouer, jamais dégrader en silence.
    expect(() => withValue('0')).toThrowError(
      /LUCIDA_MAX_CONCURRENT_DOWNLOADS/,
    );
    expect(() => withValue('5')).toThrowError(
      /LUCIDA_MAX_CONCURRENT_DOWNLOADS/,
    );
  });

  it('refuse un script absent, une extension invalide ou un timeout hors limites', () => {
    const root = temporaryRoot('homespotify-lucida-invalid-');
    const textPath = join(root, 'lucida.txt');
    const pythonPath = join(root, 'lucida.py');
    writeFileSync(textPath, 'test\n', 'utf-8');
    writeFileSync(pythonPath, '# test-only\n', 'utf-8');

    expect(() =>
      loadConfig({
        NODE_ENV: 'test',
        LUCIDA_SCRIPT_PATH: join(root, 'missing.py'),
      }),
    ).toThrow(/introuvable/i);

    expect(() =>
      loadConfig({
        NODE_ENV: 'test',
        LUCIDA_SCRIPT_PATH: textPath,
      }),
    ).toThrow(/fichier \.py attendu/i);

    expect(() =>
      loadConfig({
        NODE_ENV: 'test',
        LUCIDA_SCRIPT_PATH: pythonPath,
        LUCIDA_PROCESS_TIMEOUT_SECONDS: '9',
      }),
    ).toThrow(/entier 10-1800 attendu/i);
  });
});

describe('branchement Lucida dans buildApp', () => {
  it('récupère les jobs actifs au boot et arrête le runner avant la base', async () => {
    const root = temporaryRoot('homespotify-lucida-app-');
    const dbPath = join(root, 'homespotify.sqlite');
    const scriptPath = join(root, 'lucida_dl_final.py');
    writeFileSync(scriptPath, '# test-only\n', 'utf-8');

    const seeded = createDb(dbPath);
    runMigrations(seeded, {
      info: () => undefined,
      error: () => undefined,
    });

    const now = new Date().toISOString();
    const userId = seeded.db
      .insert(users)
      .values({
        username: `lucida_${randomUUID().slice(0, 8)}`,
        displayName: 'Lucida test',
        passwordHash: 'test-only',
        role: 'USER',
        isActive: true,
        mustChangePassword: false,
        createdAt: now,
        updatedAt: now,
      })
      .returning({ id: users.id })
      .get().id;

    const acquisitionId = randomUUID();
    seeded.db
      .insert(acquisitionJobs)
      .values({
        id: acquisitionId,
        userId,
        provider: 'QOBUZ',
        query: 'Luther Creeper',
        dedupeKey: 'QOBUZ:0:luther creeper',
        resultIndex: 0,
        status: 'DOWNLOADING',
        progress: 35,
        attempt: 1,
        maxAttempts: 3,
        createdAt: now,
        updatedAt: now,
        startedAt: now,
      })
      .run();
    seeded.sqlite.close();

    const stopAll = vi.fn();
    const lucidaRunner: AcquisitionRunner = {
      run: async () => {
        throw new Error('Le runner injecté ne doit pas être lancé par ce test.');
      },
      stopAll,
    };

    const config: AppConfig = {
      ...baseConfig(root, dbPath),
      lucida: {
        scriptPath,
      pythonPath: 'python-test',
      processTimeoutMs: 300_000,
      maxConcurrentDownloads: 3,
      challengeCooldownSeconds: 1_800,
      rateLimitDefaultCooldownSeconds: 900,
      unavailableCooldownSeconds: 600,
      maxCooldownSeconds: 21_600,
      providerFailureWindowSeconds: 600,
      providerFailureThreshold: 2,
      },
    };

    const app = buildApp(config, {
      importWatcher: false,
      lucidaRunner,
    });

    try {
      await app.ready();

      const recovered = app.dbHandle.db
        .select()
        .from(acquisitionJobs)
        .where(eq(acquisitionJobs.id, acquisitionId))
        .get();

      expect(recovered).toMatchObject({
        status: 'INTERRUPTED',
        stage: 'interrupted',
        errorCode: 'SERVER_RESTART',
      });
      expect(stopAll).not.toHaveBeenCalled();
    } finally {
      await app.close();
    }

    expect(stopAll).toHaveBeenCalledOnce();
  });
});
