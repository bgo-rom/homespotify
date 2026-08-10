import { createHash, randomBytes } from 'node:crypto';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import type { FastifyInstance } from 'fastify';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../app.js';
import type { AppConfig } from '../config.js';

const PACKAGE_NAME = 'com.homespotify.homespotify_mobile';
const CERT_SHA256 = '9d461189865d0d1f3774ae06a4bbf84f13c890c471b3e8d2082887006a5a78d6';

let root: string;
let catalogRoot: string;
let app: FastifyInstance | null = null;

function baseConfig(overrides: Partial<AppConfig> = {}): AppConfig {
  return {
    nodeEnv: 'test',
    host: '127.0.0.1',
    port: 0,
    dbPath: ':memory:',
    logLevel: 'fatal',
    musicDir: join(root, 'music'),
    incomingDir: join(root, 'incoming'),
    importRoot: join(root, 'imports'),
    coversDir: join(root, 'covers'),
    maxUploadBytes: 200 * 1024 * 1024,
    authTokenSecret: 'test-secret-at-least-thirty-two-characters',
    accessTokenTtlSeconds: 900,
    refreshTokenTtlSeconds: 86_400,
    acquisitionProviders: {
      legacyEnabled: false,
      order: ['LUCIDA'],
      monochromeManualFallbackEnabled: false,
      monochromeBaseUrl: 'https://monochrome.tf/',
      monochromeManualTimeoutSeconds: 600,
      monochromeDownloadDirectory: '',
      monochromeFileStabilitySeconds: 3,
    },
    ...overrides,
  };
}

async function startApp(config: AppConfig): Promise<FastifyInstance> {
  const instance = buildApp(config, { importWatcher: false });
  await instance.ready();
  app = instance;
  return instance;
}

interface PublishOptions {
  versionCode: number;
  versionName?: string;
  required?: boolean;
  minSupportedVersionCode?: number;
  releaseNotes?: string[];
  /** Écrit un APK dont la taille diffère du manifeste (corruption simulée). */
  actualBytes?: number;
  /** N'écrit pas le fichier APK, uniquement les métadonnées. */
  skipApk?: boolean;
  /** Ne recopie pas les métadonnées dans latest.json. */
  skipLatest?: boolean;
}

/** Publie une release COMPLÈTE dans le catalogue de test. */
function publish(options: PublishOptions): { sha256: string; bytes: Buffer } {
  const {
    versionCode,
    versionName = '1.0.0',
    required = false,
    minSupportedVersionCode = 1,
    releaseNotes = ['Note de version'],
    actualBytes,
    skipApk = false,
    skipLatest = false,
  } = options;

  const declaredSize = 4096;
  const bytes = randomBytes(declaredSize);
  const sha256 = createHash('sha256').update(bytes).digest('hex');

  if (!skipApk) {
    const written = actualBytes === undefined ? bytes : bytes.subarray(0, actualBytes);
    writeFileSync(join(catalogRoot, 'releases', `homespotify-${versionCode}.apk`), written);
  }

  const manifest = {
    platform: 'android',
    packageName: PACKAGE_NAME,
    versionCode,
    versionName,
    required,
    minSupportedVersionCode,
    sizeBytes: declaredSize,
    sha256,
    signingCertSha256: CERT_SHA256,
    releaseNotes,
    publishedAt: new Date().toISOString(),
  };
  const serialized = JSON.stringify(manifest, null, 2);
  writeFileSync(join(catalogRoot, 'metadata', `${versionCode}.json`), serialized);
  if (!skipLatest) writeFileSync(join(catalogRoot, 'latest.json'), serialized);
  return { sha256, bytes };
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'homespotify-app-update-'));
  catalogRoot = join(root, 'mobile-updates', 'android');
  mkdirSync(join(catalogRoot, 'releases'), { recursive: true });
  mkdirSync(join(catalogRoot, 'metadata'), { recursive: true });
});

afterEach(async () => {
  if (app !== null) {
    await app.close();
    app = null;
  }
  rmSync(root, { recursive: true, force: true });
});

describe('GET /api/app-update/android/latest', () => {
  it('1. sert le manifeste publié et calcule updateAvailable', async () => {
    const instance = await startApp(
      baseConfig({ appUpdate: { androidDir: catalogRoot } }),
    );
    const { sha256 } = publish({ versionCode: 11, releaseNotes: ['Test du système'] });

    const response = await instance.inject({
      method: 'GET',
      url: '/api/app-update/android/latest?currentVersionCode=10',
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({
      updateAvailable: true,
      latest: {
        platform: 'android',
        packageName: PACKAGE_NAME,
        versionCode: 11,
        versionName: '1.0.0',
        required: false,
        minSupportedVersionCode: 1,
        sizeBytes: 4096,
        sha256,
        signingCertSha256: CERT_SHA256,
        releaseNotes: ['Test du système'],
        downloadPath: '/api/app-update/android/download/11',
      },
    });
    // Aucun chemin serveur ne fuit vers le client.
    expect(JSON.stringify(response.json())).not.toContain(catalogRoot);
  });

  it('2. répond proprement quand aucune version n’est publiée', async () => {
    const instance = await startApp(
      baseConfig({ appUpdate: { androidDir: catalogRoot } }),
    );
    const response = await instance.inject({
      method: 'GET',
      url: '/api/app-update/android/latest?currentVersionCode=10',
    });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ updateAvailable: false, latest: null });
  });

  it('3. versionCode identique ou plus récent → aucune mise à jour', async () => {
    const instance = await startApp(
      baseConfig({ appUpdate: { androidDir: catalogRoot } }),
    );
    publish({ versionCode: 11 });

    for (const current of [11, 12]) {
      const response = await instance.inject({
        method: 'GET',
        url: `/api/app-update/android/latest?currentVersionCode=${current}`,
      });
      expect(response.statusCode).toBe(200);
      expect(response.json().updateAvailable).toBe(false);
      expect(response.json().latest.versionCode).toBe(11);
    }
  });

  it('4. refuse un currentVersionCode non entier', async () => {
    const instance = await startApp(
      baseConfig({ appUpdate: { androidDir: catalogRoot } }),
    );
    publish({ versionCode: 11 });
    for (const value of ['abc', '-3', '1.5', '0x0b', ' 11']) {
      const response = await instance.inject({
        method: 'GET',
        url: `/api/app-update/android/latest?currentVersionCode=${encodeURIComponent(value)}`,
      });
      expect(response.statusCode, value).toBe(400);
    }
  });

  it('5. manifeste corrompu → 500 explicite, jamais de manifeste partiel', async () => {
    const instance = await startApp(
      baseConfig({ appUpdate: { androidDir: catalogRoot } }),
    );
    writeFileSync(join(catalogRoot, 'latest.json'), '{ "platform": "android"');

    const response = await instance.inject({
      method: 'GET',
      url: '/api/app-update/android/latest',
    });
    expect(response.statusCode).toBe(500);
    expect(response.json().error).toBe('manifest_invalid');
  });

  it('6. manifeste incohérent (minSupported > versionCode) → refusé', async () => {
    const instance = await startApp(
      baseConfig({ appUpdate: { androidDir: catalogRoot } }),
    );
    writeFileSync(
      join(catalogRoot, 'latest.json'),
      JSON.stringify({
        platform: 'android',
        packageName: PACKAGE_NAME,
        versionCode: 5,
        versionName: '1.0.0',
        required: false,
        minSupportedVersionCode: 9,
        sizeBytes: 10,
        sha256: 'a'.repeat(64),
        signingCertSha256: CERT_SHA256,
        releaseNotes: [],
        publishedAt: new Date().toISOString(),
      }),
    );
    const response = await instance.inject({
      method: 'GET',
      url: '/api/app-update/android/latest',
    });
    expect(response.statusCode).toBe(500);
  });

  it('7. service non configuré → 503, sans casser le reste du backend', async () => {
    const instance = await startApp(baseConfig());
    const response = await instance.inject({
      method: 'GET',
      url: '/api/app-update/android/latest',
    });
    expect(response.statusCode).toBe(503);
    expect(response.json().error).toBe('update_service_unconfigured');

    const health = await instance.inject({ method: 'GET', url: '/health' });
    expect(health.statusCode).toBe(200);
  });

  it('8. ignore un latest.json.tmp : latest ne pointe jamais vers un temporaire', async () => {
    const instance = await startApp(
      baseConfig({ appUpdate: { androidDir: catalogRoot } }),
    );
    publish({ versionCode: 11 });
    // Publication interrompue : le temporaire d'une version 12 traîne encore.
    writeFileSync(
      join(catalogRoot, 'latest.json.tmp'),
      JSON.stringify({ platform: 'android', versionCode: 12 }),
    );
    writeFileSync(join(catalogRoot, 'releases', 'homespotify-12.apk.tmp'), 'partiel');

    const response = await instance.inject({
      method: 'GET',
      url: '/api/app-update/android/latest?currentVersionCode=11',
    });
    expect(response.statusCode).toBe(200);
    expect(response.json().latest.versionCode).toBe(11);
    expect(response.json().updateAvailable).toBe(false);

    // Et la version 12 n'est pas téléchargeable tant qu'elle n'est pas publiée.
    const download = await instance.inject({
      method: 'GET',
      url: '/api/app-update/android/download/12',
    });
    expect(download.statusCode).toBe(404);
  });
});

describe('GET /api/app-update/android/download/:versionCode', () => {
  it('9. sert l’APK complète avec le bon type et la bonne taille', async () => {
    const instance = await startApp(
      baseConfig({ appUpdate: { androidDir: catalogRoot } }),
    );
    const { sha256, bytes } = publish({ versionCode: 11 });

    const response = await instance.inject({
      method: 'GET',
      url: '/api/app-update/android/download/11',
    });

    expect(response.statusCode).toBe(200);
    expect(response.headers['content-type']).toBe('application/vnd.android.package-archive');
    expect(response.headers['content-length']).toBe('4096');
    expect(response.headers['accept-ranges']).toBe('bytes');
    expect(response.headers['x-homespotify-sha256']).toBe(sha256);
    expect(createHash('sha256').update(response.rawPayload).digest('hex')).toBe(sha256);
    expect(response.rawPayload.equals(bytes)).toBe(true);
  });

  it('10. sert une plage Range pour la reprise', async () => {
    const instance = await startApp(
      baseConfig({ appUpdate: { androidDir: catalogRoot } }),
    );
    const { bytes } = publish({ versionCode: 11 });

    const response = await instance.inject({
      method: 'GET',
      url: '/api/app-update/android/download/11',
      headers: { range: 'bytes=1000-1099' },
    });
    expect(response.statusCode).toBe(206);
    expect(response.headers['content-range']).toBe('bytes 1000-1099/4096');
    expect(response.headers['content-length']).toBe('100');
    expect(response.rawPayload.equals(bytes.subarray(1000, 1100))).toBe(true);

    const unsatisfiable = await instance.inject({
      method: 'GET',
      url: '/api/app-update/android/download/11',
      headers: { range: 'bytes=99999-' },
    });
    expect(unsatisfiable.statusCode).toBe(416);
  });

  it('11. version inconnue → 404 propre', async () => {
    const instance = await startApp(
      baseConfig({ appUpdate: { androidDir: catalogRoot } }),
    );
    publish({ versionCode: 11 });
    const response = await instance.inject({
      method: 'GET',
      url: '/api/app-update/android/download/999',
    });
    expect(response.statusCode).toBe(404);
    expect(response.json().error).toBe('not_found');
  });

  it('12. refuse toute traversée de chemin ou nom de fichier', async () => {
    const instance = await startApp(
      baseConfig({ appUpdate: { androidDir: catalogRoot } }),
    );
    publish({ versionCode: 11 });
    writeFileSync(join(root, 'secret.txt'), 'contenu privé');

    const hostile = [
      '..%2F..%2Fsecret.txt',
      '%2e%2e%2f%2e%2e%2fsecret.txt',
      '11.apk',
      'homespotify-11.apk',
      '..',
      '0',
      '011',
    ];
    for (const value of hostile) {
      const response = await instance.inject({
        method: 'GET',
        url: `/api/app-update/android/download/${value}`,
      });
      expect([400, 404], value).toContain(response.statusCode);
      expect(response.rawPayload.toString()).not.toContain('contenu privé');
    }
  });

  it('13. métadonnées publiées mais APK absente → 404, jamais de flux vide', async () => {
    const instance = await startApp(
      baseConfig({ appUpdate: { androidDir: catalogRoot } }),
    );
    publish({ versionCode: 11, skipApk: true });
    const response = await instance.inject({
      method: 'GET',
      url: '/api/app-update/android/download/11',
    });
    expect(response.statusCode).toBe(404);
  });

  it('14. taille sur disque ≠ manifeste → 500, aucun octet servi', async () => {
    const instance = await startApp(
      baseConfig({ appUpdate: { androidDir: catalogRoot } }),
    );
    publish({ versionCode: 11, actualBytes: 2048 });
    const response = await instance.inject({
      method: 'GET',
      url: '/api/app-update/android/download/11',
    });
    expect(response.statusCode).toBe(500);
    expect(response.json().error).toBe('release_corrupted');
  });

  it('15. une ancienne version reste téléchargeable pour diagnostic', async () => {
    const instance = await startApp(
      baseConfig({ appUpdate: { androidDir: catalogRoot } }),
    );
    const older = publish({ versionCode: 10, skipLatest: true });
    publish({ versionCode: 11 });

    const response = await instance.inject({
      method: 'GET',
      url: '/api/app-update/android/download/10',
    });
    expect(response.statusCode).toBe(200);
    expect(createHash('sha256').update(response.rawPayload).digest('hex')).toBe(older.sha256);
  });

  it('16. reste accessible sans Bearer, et n’ouvre rien d’autre', async () => {
    const instance = await startApp(
      baseConfig({ appUpdate: { androidDir: catalogRoot } }),
    );
    publish({ versionCode: 11 });

    const anonymous = await instance.inject({
      method: 'GET',
      url: '/api/app-update/android/latest?currentVersionCode=1',
    });
    expect(anonymous.statusCode).toBe(200);
    expect(anonymous.json().updateAvailable).toBe(true);

    // La règle « public » ne déborde pas : le reste de l'API exige un Bearer.
    const tracks = await instance.inject({ method: 'GET', url: '/api/tracks' });
    expect(tracks.statusCode).toBe(401);
  });
});
