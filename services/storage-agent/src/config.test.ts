import { describe, expect, it } from 'vitest';
import {
  loadStorageAgentConfig,
  normalizeIp,
  StorageAgentConfigError,
} from './config.js';

/** Env minimale valide, hors variables testées. */
function baseEnv(overrides: NodeJS.ProcessEnv = {}): NodeJS.ProcessEnv {
  return {
    NODE_ENV: 'test',
    STORAGE_AGENT_MUSIC_ROOT: 'C:\\music',
    STORAGE_AGENT_INDEX_PATH: 'C:\\music\\index.json',
    STORAGE_AGENT_SHARED_SECRET: 'b'.repeat(64),
    ...overrides,
  };
}

describe('loadStorageAgentConfig — défauts sûrs', () => {
  it('écoute sur 127.0.0.1:3100 par défaut', () => {
    const config = loadStorageAgentConfig(baseEnv());
    expect(config.host).toBe('127.0.0.1');
    expect(config.port).toBe(3100);
  });

  it('applique les défauts de concurrence et de fenêtre horaire', () => {
    const config = loadStorageAgentConfig(baseEnv());
    expect(config.maxConcurrentStreams).toBe(8);
    expect(config.maxConcurrentImports).toBe(2);
    expect(config.maxImportBytes).toBe(1024 * 1024 * 1024);
    expect(config.maxIndexBytes).toBe(16 * 1024 * 1024);
    expect(config.hmacMaxClockSkewSeconds).toBe(60);
    expect(config.allowedRemoteIps).toEqual(['10.8.0.1']);
  });

  it('refuse une écoute sur toutes les interfaces, même explicite', () => {
    for (const host of ['0.0.0.0', '::', '*']) {
      expect(() => loadStorageAgentConfig(baseEnv({ STORAGE_AGENT_HOST: host }))).toThrowError(
        StorageAgentConfigError,
      );
    }
  });
});

describe('loadStorageAgentConfig — secret', () => {
  it('est obligatoire hors test', () => {
    expect(() =>
      loadStorageAgentConfig(
        baseEnv({ NODE_ENV: 'production', STORAGE_AGENT_SHARED_SECRET: '' }),
      ),
    ).toThrowError(/obligatoire/);
  });

  it('refuse un secret trop court', () => {
    expect(() =>
      loadStorageAgentConfig(baseEnv({ STORAGE_AGENT_SHARED_SECRET: 'court' })),
    ).toThrowError(/trop court/);
  });

  it('ne recopie jamais la valeur du secret dans le message d’erreur', () => {
    const secret = 'super-secret-mais-trop-court';
    try {
      loadStorageAgentConfig(baseEnv({ STORAGE_AGENT_SHARED_SECRET: secret }));
      expect.unreachable('doit lever');
    } catch (error) {
      expect((error as Error).message).not.toContain(secret);
    }
  });

  it('génère un secret éphémère en test si absent', () => {
    const config = loadStorageAgentConfig(baseEnv({ STORAGE_AGENT_SHARED_SECRET: '' }));
    expect(config.sharedSecret.length).toBeGreaterThanOrEqual(32);
  });
});

describe('loadStorageAgentConfig — chemins et bornes', () => {
  it('exige MUSIC_ROOT et INDEX_PATH', () => {
    expect(() =>
      loadStorageAgentConfig(baseEnv({ STORAGE_AGENT_MUSIC_ROOT: '' })),
    ).toThrowError(/MUSIC_ROOT/);
    expect(() =>
      loadStorageAgentConfig(baseEnv({ STORAGE_AGENT_INDEX_PATH: '  ' })),
    ).toThrowError(/INDEX_PATH/);
  });

  it('refuse une concurrence hors bornes', () => {
    expect(() =>
      loadStorageAgentConfig(baseEnv({ STORAGE_AGENT_MAX_CONCURRENT_STREAMS: '0' })),
    ).toThrowError(StorageAgentConfigError);
    expect(() =>
      loadStorageAgentConfig(baseEnv({ STORAGE_AGENT_MAX_CONCURRENT_STREAMS: '9999' })),
    ).toThrowError(StorageAgentConfigError);
  });

  it('refuse des bornes d’import invalides', () => {
    expect(() =>
      loadStorageAgentConfig(baseEnv({ STORAGE_AGENT_MAX_CONCURRENT_IMPORTS: '0' })),
    ).toThrowError(StorageAgentConfigError);
    expect(() =>
      loadStorageAgentConfig(baseEnv({ STORAGE_AGENT_MAX_IMPORT_BYTES: '1024' })),
    ).toThrowError(StorageAgentConfigError);
    expect(() =>
      loadStorageAgentConfig(baseEnv({ STORAGE_AGENT_MAX_INDEX_BYTES: '512' })),
    ).toThrowError(StorageAgentConfigError);
  });

  it('refuse une fenêtre horaire hors bornes', () => {
    expect(() =>
      loadStorageAgentConfig(baseEnv({ STORAGE_AGENT_HMAC_MAX_CLOCK_SKEW_SECONDS: '1' })),
    ).toThrowError(StorageAgentConfigError);
  });
});

describe('loadStorageAgentConfig — IP autorisées', () => {
  it('accepte une liste explicite', () => {
    const config = loadStorageAgentConfig(
      baseEnv({ STORAGE_AGENT_ALLOWED_REMOTE_IP: '10.8.0.1, 127.0.0.1' }),
    );
    expect(config.allowedRemoteIps).toEqual(['10.8.0.1', '127.0.0.1']);
  });

  it('refuse un CIDR (aucune plage implicite)', () => {
    expect(() =>
      loadStorageAgentConfig(baseEnv({ STORAGE_AGENT_ALLOWED_REMOTE_IP: '10.8.0.0/24' })),
    ).toThrowError(/CIDR/);
  });

  it('refuse une valeur non IP', () => {
    expect(() =>
      loadStorageAgentConfig(baseEnv({ STORAGE_AGENT_ALLOWED_REMOTE_IP: 'vps.example.com' })),
    ).toThrowError(/IP littérale/);
  });
});

describe('normalizeIp', () => {
  it('réduit la forme IPv4-mapped IPv6', () => {
    expect(normalizeIp('::ffff:10.8.0.1')).toBe('10.8.0.1');
    expect(normalizeIp('::FFFF:127.0.0.1')).toBe('127.0.0.1');
    expect(normalizeIp('[::ffff:127.0.0.1]')).toBe('127.0.0.1');
  });

  it('n’élargit aucune plage', () => {
    // `::1` n'est PAS `127.0.0.1` : une autorisation IPv4 ne couvre pas IPv6.
    expect(normalizeIp('::1')).toBe('::1');
    expect(normalizeIp('10.8.0.10')).not.toBe('10.8.0.1');
  });

  it('canonicalise les octets à zéros initiaux', () => {
    // `010.008.000.001` ne doit pas contourner une comparaison textuelle.
    expect(normalizeIp('010.008.000.001')).toBe('10.8.0.1');
  });

  it('rejette ce qui n’est pas une IP littérale', () => {
    expect(normalizeIp('localhost')).toBeNull();
    expect(normalizeIp('')).toBeNull();
    expect(normalizeIp(undefined)).toBeNull();
    expect(normalizeIp('10.8.0.256')).toBeNull();
  });
});
