import { describe, expect, it } from 'vitest';
import { resolve } from 'node:path';
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
    expect(config.acquisitionProviders).toMatchObject({
      order: ['LUCIDA', 'MONOCHROME_MANUAL'],
      monochromeManualFallbackEnabled: true,
      monochromeBaseUrl: 'https://monochrome.tf/',
      monochromeManualTimeoutSeconds: 600,
      monochromeFileStabilitySeconds: 3,
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

  it('valide les cooldowns Lucida avec leurs valeurs par défaut', () => {
    const config = loadConfig({
      LUCIDA_SCRIPT_PATH: resolve(
        '../../tools/spotify-auth-spoof/lucida_dl_final.py',
      ),
    });
    expect(config.lucida).toMatchObject({
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

  it('échoue explicitement sur une politique Lucida invalide', () => {
    const script = resolve(
      '../../tools/spotify-auth-spoof/lucida_dl_final.py',
    );
    expect(() =>
      loadConfig({
        LUCIDA_SCRIPT_PATH: script,
        LUCIDA_PROVIDER_FAILURE_THRESHOLD: '1.5',
      }),
    ).toThrow(/LUCIDA_PROVIDER_FAILURE_THRESHOLD/);
    expect(() =>
      loadConfig({
        LUCIDA_SCRIPT_PATH: script,
        LUCIDA_CHALLENGE_COOLDOWN_SECONDS: '4000',
        LUCIDA_MAX_COOLDOWN_SECONDS: '3000',
      }),
    ).toThrow(/LUCIDA_MAX_COOLDOWN_SECONDS/);
    expect(() =>
      loadConfig({
        LUCIDA_SCRIPT_PATH: script,
        LUCIDA_INTERACTIVE_VERIFICATION_ENABLED: 'peut-être',
      }),
    ).toThrow(/LUCIDA_INTERACTIVE_VERIFICATION_ENABLED/);
    expect(() =>
      loadConfig({
        LUCIDA_SCRIPT_PATH: script,
        LUCIDA_INTERACTIVE_VERIFICATION_TIMEOUT_SECONDS: '10',
      }),
    ).toThrow(/LUCIDA_INTERACTIVE_VERIFICATION_TIMEOUT_SECONDS/);
  });

  it('valide et borne la configuration Monochrome', () => {
    expect(() =>
      loadConfig({
        ACQUISITION_PROVIDER_ORDER: 'MONOCHROME_MANUAL,LUCIDA',
      }),
    ).toThrow(/ACQUISITION_PROVIDER_ORDER/);
    expect(() =>
      loadConfig({ MONOCHROME_BASE_URL: 'http://monochrome.tf/' }),
    ).toThrow(/MONOCHROME_BASE_URL/);
    expect(() =>
      loadConfig({ MONOCHROME_MANUAL_TIMEOUT_SECONDS: '29' }),
    ).toThrow(/MONOCHROME_MANUAL_TIMEOUT_SECONDS/);
    expect(() =>
      loadConfig({ MONOCHROME_FILE_STABILITY_SECONDS: '31' }),
    ).toThrow(/MONOCHROME_FILE_STABILITY_SECONDS/);
    expect(() =>
      loadConfig({ MONOCHROME_MANUAL_FALLBACK_ENABLED: 'peut-être' }),
    ).toThrow(/MONOCHROME_MANUAL_FALLBACK_ENABLED/);
  });

  it('désactive l’acquisition historique par défaut', () => {
    expect(loadConfig({}).acquisitionProviders.legacyEnabled).toBe(false);
    expect(
      loadConfig({ ACQUISITION_LEGACY_ENABLED: 'true' }).acquisitionProviders
        .legacyEnabled,
    ).toBe(true);
  });

  describe('moteur Antra', () => {
    // Le dépôt Antra et son venv existent réellement sur la machine cible :
    // la configuration doit être validée contre des chemins réels, pas
    // contre des chaînes arbitraires.
    const antraDir = resolve('../../tools/antra');
    const antraPython = resolve(
      '../../tools/antra/.venv/Scripts/python.exe',
    );

    it('reste absente tant que ANTRA_DIR n’est pas fourni', () => {
      expect(loadConfig({}).antra).toBeUndefined();
    });

    it('applique les valeurs par défaut attendues', () => {
      const config = loadConfig({
        ANTRA_DIR: antraDir,
        ANTRA_PYTHON: antraPython,
      });
      expect(config.antra).toMatchObject({
        source: 'auto',
        format: 'flac',
        allowedExtensions: ['.flac', '.wav'],
        maxConcurrent: 2,
        jobTimeoutMs: 900_000,
        slskdAutoBootstrap: false,
        verbose: false,
      });
    });

    it('exige un interpréteur Python explicite et existant', () => {
      expect(() => loadConfig({ ANTRA_DIR: antraDir })).toThrow(/ANTRA_PYTHON/);
      expect(() =>
        loadConfig({ ANTRA_DIR: antraDir, ANTRA_PYTHON: 'C:/absent/python.exe' }),
      ).toThrow(/ANTRA_PYTHON/);
      expect(() =>
        loadConfig({ ANTRA_DIR: 'C:/dossier/absent', ANTRA_PYTHON: antraPython }),
      ).toThrow(/ANTRA_DIR/);
    });

    it('refuse d’activer Soulseek, qui exigerait une configuration interactive', () => {
      expect(() =>
        loadConfig({
          ANTRA_DIR: antraDir,
          ANTRA_PYTHON: antraPython,
          ANTRA_SLSKD_AUTO_BOOTSTRAP: 'true',
        }),
      ).toThrow(/ANTRA_SLSKD_AUTO_BOOTSTRAP/);
    });

    it('borne la concurrence, le délai et valide source/format/extensions', () => {
      const base = { ANTRA_DIR: antraDir, ANTRA_PYTHON: antraPython };
      expect(() =>
        loadConfig({ ...base, ANTRA_MAX_CONCURRENT: '5' }),
      ).toThrow(/ANTRA_MAX_CONCURRENT/);
      expect(() =>
        loadConfig({ ...base, ANTRA_JOB_TIMEOUT_MS: '1000' }),
      ).toThrow(/ANTRA_JOB_TIMEOUT_MS/);
      expect(() => loadConfig({ ...base, ANTRA_SOURCE: 'napster' })).toThrow(
        /ANTRA_SOURCE/,
      );
      expect(() => loadConfig({ ...base, ANTRA_FORMAT: 'wma' })).toThrow(
        /ANTRA_FORMAT/,
      );
      // `.ogg` n'est pas importable par le pipeline local bit-perfect.
      expect(() =>
        loadConfig({ ...base, ANTRA_ALLOWED_EXTENSIONS: '.ogg' }),
      ).toThrow(/ANTRA_ALLOWED_EXTENSIONS/);
    });
  });
});
