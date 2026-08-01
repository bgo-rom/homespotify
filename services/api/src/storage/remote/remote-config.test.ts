import { describe, expect, it } from 'vitest';
import { loadConfig } from '../../config.js';
import { loadRemoteStorageConfig } from './remote-config.js';

const SECRET = '0123456789abcdef0123456789abcdef';

describe('configuration du stockage distant', () => {
  it('loadConfig conserve local par défaut sans exiger de secret distant', () => {
    const config = loadConfig({
      AUDIO_REMOTE_BASE_URL: 'invalide',
      AUDIO_REMOTE_SHARED_SECRET: 'court',
    });
    expect(config.audioStorageMode).toBe('local');
    expect(config.audioRemote).toBeUndefined();
  });

  it('loadConfig exige puis expose la configuration uniquement en remote', () => {
    expect(() => loadConfig({ AUDIO_STORAGE_MODE: 'remote' })).toThrow(
      /AUDIO_REMOTE_SHARED_SECRET/,
    );
    const config = loadConfig({
      AUDIO_STORAGE_MODE: 'remote',
      AUDIO_REMOTE_BASE_URL: 'http://10.8.0.2:3100',
      AUDIO_REMOTE_SHARED_SECRET: SECRET,
    });
    expect(config.audioStorageMode).toBe('remote');
    expect(config.audioRemote?.baseUrl).toBe('http://10.8.0.2:3100');
  });

  it('ne lit aucune variable distante en mode local', () => {
    expect(
      loadRemoteStorageConfig(
        {
          AUDIO_REMOTE_BASE_URL: 'invalide',
          AUDIO_REMOTE_SHARED_SECRET: 'court',
        },
        'local',
      ),
    ).toBeUndefined();
  });

  it('accepte la configuration WireGuard et applique les défauts bornés', () => {
    expect(
      loadRemoteStorageConfig(
        {
          AUDIO_REMOTE_BASE_URL: 'http://10.8.0.2:3100',
          AUDIO_REMOTE_SHARED_SECRET: SECRET,
        },
        'remote',
      ),
    ).toEqual({
      baseUrl: 'http://10.8.0.2:3100',
      sharedSecret: SECRET,
      connectTimeoutMs: 2_000,
      headersTimeoutMs: 5_000,
      bodyIdleTimeoutMs: 15_000,
      maxConnections: 8,
    });
  });

  it.each([
    [{ AUDIO_REMOTE_SHARED_SECRET: SECRET }, 'AUDIO_REMOTE_BASE_URL'],
    [
      { AUDIO_REMOTE_BASE_URL: 'http://10.8.0.2:3100' },
      'AUDIO_REMOTE_SHARED_SECRET',
    ],
    [
      {
        AUDIO_REMOTE_BASE_URL: 'http://10.8.0.2:3100',
        AUDIO_REMOTE_SHARED_SECRET: 'trop-court',
      },
      'AUDIO_REMOTE_SHARED_SECRET',
    ],
    [
      {
        AUDIO_REMOTE_BASE_URL: 'pas-une-url',
        AUDIO_REMOTE_SHARED_SECRET: SECRET,
      },
      'AUDIO_REMOTE_BASE_URL',
    ],
    [
      {
        AUDIO_REMOTE_BASE_URL: 'https://10.8.0.2:3100',
        AUDIO_REMOTE_SHARED_SECRET: SECRET,
      },
      'HTTP',
    ],
    [
      {
        AUDIO_REMOTE_BASE_URL: 'http://example.com:3100',
        AUDIO_REMOTE_SHARED_SECRET: SECRET,
      },
      'IP privée',
    ],
    [
      {
        AUDIO_REMOTE_BASE_URL: 'http://10.8.0.2:3100/internal',
        AUDIO_REMOTE_SHARED_SECRET: SECRET,
      },
      'sans credentials',
    ],
    [
      {
        AUDIO_REMOTE_BASE_URL: 'http://10.8.0.2:3100',
        AUDIO_REMOTE_SHARED_SECRET: SECRET,
        AUDIO_REMOTE_CONNECT_TIMEOUT_MS: '0',
      },
      'AUDIO_REMOTE_CONNECT_TIMEOUT_MS',
    ],
    [
      {
        AUDIO_REMOTE_BASE_URL: 'http://10.8.0.2:3100',
        AUDIO_REMOTE_SHARED_SECRET: SECRET,
        AUDIO_REMOTE_MAX_CONNECTIONS: '65',
      },
      'AUDIO_REMOTE_MAX_CONNECTIONS',
    ],
  ])('refuse une configuration invalide sans reproduire sa valeur', (env, marker) => {
    expect(() => loadRemoteStorageConfig(env, 'remote')).toThrow(marker);
    try {
      loadRemoteStorageConfig(env, 'remote');
    } catch (error) {
      expect(String(error)).not.toContain(SECRET);
    }
  });
});
