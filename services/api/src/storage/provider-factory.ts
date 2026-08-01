import type { AudioStorageProvider } from './audio-storage.js';
import { LocalFileStorageProvider } from './local-file-storage.js';
import type { RemoteStorageConfig } from './remote/remote-config.js';
import { RemoteWindowsStorageProvider } from './remote/remote-windows-storage.js';
import type { RemoteLogger } from './remote/storage-agent-client.js';
import type { AudioCacheConfig } from './cache/cache-config.js';
import { CachedAudioStorageProvider } from './cache/cached-audio-storage.js';

/**
 * Modes de stockage prévus par le plan de migration VPS.
 *
 * - `local`  : système de fichiers local — seul mode implémenté (Phase 1).
 * - `remote` : Storage Agent sur le PC Windows — Phase 4.
 * - `cached` : cache VPS au-dessus du distant — Phase 5.
 */
export const AUDIO_STORAGE_MODES = ['local', 'remote', 'cached'] as const;
export type AudioStorageMode = (typeof AUDIO_STORAGE_MODES)[number];

export const DEFAULT_AUDIO_STORAGE_MODE: AudioStorageMode = 'local';

export class AudioStorageConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'AudioStorageConfigError';
  }
}

/**
 * Valide la valeur brute de `AUDIO_STORAGE_MODE`.
 *
 * Absente → `local`. Une valeur INCONNUE est refusée : jamais de repli
 * silencieux, qui masquerait une faute de frappe en production et ferait
 * croire à un mode distant actif alors qu'il ne l'est pas.
 */
export function parseAudioStorageMode(raw: string | undefined): AudioStorageMode {
  const value = raw?.trim();
  if (value === undefined || value.length === 0) {
    return DEFAULT_AUDIO_STORAGE_MODE;
  }
  if (!(AUDIO_STORAGE_MODES as readonly string[]).includes(value)) {
    throw new AudioStorageConfigError(
      `Config invalide : AUDIO_STORAGE_MODE="${value}" ` +
        `(valeurs acceptées : ${AUDIO_STORAGE_MODES.join(', ')})`,
    );
  }
  return value as AudioStorageMode;
}

/**
 * Construit le provider correspondant au mode.
 *
 * `remote` et `cached` échouent explicitement : ils sont déclarés dans le
 * contrat mais pas encore écrits. Les simuler en repliant sur `local`
 * donnerait l'illusion d'une migration fonctionnelle.
 */
export function createAudioStorageProvider(
  mode: AudioStorageMode,
  options: {
    musicDir: string;
    remote?: RemoteStorageConfig;
    cache?: AudioCacheConfig;
    logger?: RemoteLogger;
  },
): AudioStorageProvider {
  switch (mode) {
    case 'local':
      return new LocalFileStorageProvider(options.musicDir);

    case 'remote':
      if (options.remote === undefined) {
        throw new AudioStorageConfigError(
          'AUDIO_STORAGE_MODE="remote" exige une configuration distante valide.',
        );
      }
      return new RemoteWindowsStorageProvider(options.remote, options.logger);

    case 'cached':
      if (options.remote === undefined || options.cache === undefined) {
        throw new AudioStorageConfigError(
          'AUDIO_STORAGE_MODE="cached" exige des configurations distante et cache valides.',
        );
      }
      return new CachedAudioStorageProvider(
        new RemoteWindowsStorageProvider(options.remote, options.logger),
        options.cache,
        options.logger,
      );
  }
}
