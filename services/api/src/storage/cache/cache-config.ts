import { isAbsolute, resolve } from 'node:path';
import type { AudioStorageMode } from '../provider-factory.js';

export interface AudioCacheConfig {
  root: string;
  maxBytes: number;
  minFreeBytes: number;
  tempMaxAgeMs: number;
  fillOnFullGet: boolean;
  verifyOnHit: 'size';
  evictionTargetRatio: number;
}

export class AudioCacheConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'AudioCacheConfigError';
  }
}

function integer(
  name: string,
  raw: string | undefined,
  fallback: number,
  min: number,
): number {
  const value = Number(raw ?? fallback);
  if (!Number.isSafeInteger(value) || value < min) {
    throw new AudioCacheConfigError(
      `Config cache invalide : ${name} doit être un entier >= ${min}.`,
    );
  }
  return value;
}

function boolean(name: string, raw: string | undefined, fallback: boolean): boolean {
  if (raw === undefined) return fallback;
  if (raw === 'true') return true;
  if (raw === 'false') return false;
  throw new AudioCacheConfigError(
    `Config cache invalide : ${name} doit valoir true ou false.`,
  );
}

export function loadAudioCacheConfig(
  env: NodeJS.ProcessEnv,
  mode: AudioStorageMode,
): AudioCacheConfig | undefined {
  if (mode !== 'cached') return undefined;
  const rawRoot = env.AUDIO_CACHE_ROOT?.trim() ?? '';
  if (rawRoot.length === 0 || !isAbsolute(rawRoot)) {
    throw new AudioCacheConfigError(
      'Config cache invalide : AUDIO_CACHE_ROOT absolue est obligatoire en mode cached.',
    );
  }
  const root = resolve(rawRoot);
  if (root === resolve(process.cwd())) {
    throw new AudioCacheConfigError(
      'Config cache invalide : AUDIO_CACHE_ROOT ne doit pas être le dossier de l’application.',
    );
  }
  const ratio = Number(env.AUDIO_CACHE_EVICTION_TARGET_RATIO ?? 0.9);
  if (!Number.isFinite(ratio) || ratio < 0.5 || ratio >= 1) {
    throw new AudioCacheConfigError(
      'Config cache invalide : AUDIO_CACHE_EVICTION_TARGET_RATIO doit être compris entre 0.5 inclus et 1 exclu.',
    );
  }
  const verify = env.AUDIO_CACHE_VERIFY_ON_HIT ?? 'size';
  if (verify !== 'size') {
    throw new AudioCacheConfigError(
      'Config cache invalide : AUDIO_CACHE_VERIFY_ON_HIT doit valoir size.',
    );
  }
  return {
    root,
    maxBytes: integer(
      'AUDIO_CACHE_MAX_BYTES',
      env.AUDIO_CACHE_MAX_BYTES,
      10_737_418_240,
      1,
    ),
    minFreeBytes: integer(
      'AUDIO_CACHE_MIN_FREE_BYTES',
      env.AUDIO_CACHE_MIN_FREE_BYTES,
      2_147_483_648,
      1,
    ),
    tempMaxAgeMs: integer(
      'AUDIO_CACHE_TEMP_MAX_AGE_MS',
      env.AUDIO_CACHE_TEMP_MAX_AGE_MS,
      3_600_000,
      1_000,
    ),
    fillOnFullGet: boolean(
      'AUDIO_CACHE_FILL_ON_FULL_GET',
      env.AUDIO_CACHE_FILL_ON_FULL_GET,
      true,
    ),
    verifyOnHit: verify,
    evictionTargetRatio: ratio,
  };
}
