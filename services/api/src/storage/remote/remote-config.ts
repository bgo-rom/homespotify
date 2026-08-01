import { isIP } from 'node:net';
import type { AudioStorageMode } from '../provider-factory.js';

export interface RemoteStorageConfig {
  baseUrl: string;
  sharedSecret: string;
  connectTimeoutMs: number;
  headersTimeoutMs: number;
  bodyIdleTimeoutMs: number;
  maxConnections: number;
}

export class RemoteStorageConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'RemoteStorageConfigError';
  }
}

function boundedInteger(
  name: string,
  raw: string | undefined,
  fallback: number,
  min: number,
  max: number,
): number {
  const value = Number(raw ?? fallback);
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new RemoteStorageConfigError(
      `Config distante invalide : ${name} doit être un entier ${min}-${max}.`,
    );
  }
  return value;
}

function isPrivateIpv4(host: string): boolean {
  const parts = host.split('.').map(Number);
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part))) {
    return false;
  }
  const [a, b] = parts as [number, number, number, number];
  return (
    a === 10 ||
    a === 127 ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) ||
    (a === 169 && b === 254)
  );
}

function isPrivateIp(host: string): boolean {
  const kind = isIP(host);
  if (kind === 4) return isPrivateIpv4(host);
  if (kind === 6) {
    const normalized = host.toLowerCase();
    return (
      normalized === '::1' ||
      normalized.startsWith('fc') ||
      normalized.startsWith('fd') ||
      normalized.startsWith('fe8') ||
      normalized.startsWith('fe9') ||
      normalized.startsWith('fea') ||
      normalized.startsWith('feb')
    );
  }
  return false;
}

function parseBaseUrl(raw: string | undefined): string {
  if (raw === undefined || raw.trim().length === 0) {
    throw new RemoteStorageConfigError(
      'Config distante invalide : AUDIO_REMOTE_BASE_URL est obligatoire en mode remote ou cached.',
    );
  }
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new RemoteStorageConfigError(
      'Config distante invalide : AUDIO_REMOTE_BASE_URL n’est pas une URL valide.',
    );
  }
  if (url.protocol !== 'http:') {
    throw new RemoteStorageConfigError(
      'Config distante invalide : AUDIO_REMOTE_BASE_URL doit utiliser HTTP dans le tunnel privé.',
    );
  }
  if (
    !isPrivateIp(url.hostname) ||
    url.username.length > 0 ||
    url.password.length > 0 ||
    url.search.length > 0 ||
    url.hash.length > 0 ||
    (url.pathname !== '' && url.pathname !== '/')
  ) {
    throw new RemoteStorageConfigError(
      'Config distante invalide : AUDIO_REMOTE_BASE_URL doit cibler une IP privée sans credentials, query ni chemin.',
    );
  }
  return url.origin;
}

export function loadRemoteStorageConfig(
  env: NodeJS.ProcessEnv,
  mode: AudioStorageMode,
): RemoteStorageConfig | undefined {
  if (mode === 'local') return undefined;

  const secret = env.AUDIO_REMOTE_SHARED_SECRET ?? '';
  if (secret.length < 32) {
    throw new RemoteStorageConfigError(
      'Config distante invalide : AUDIO_REMOTE_SHARED_SECRET est obligatoire et doit contenir au moins 32 caractères.',
    );
  }

  return {
    baseUrl: parseBaseUrl(env.AUDIO_REMOTE_BASE_URL),
    sharedSecret: secret,
    connectTimeoutMs: boundedInteger(
      'AUDIO_REMOTE_CONNECT_TIMEOUT_MS',
      env.AUDIO_REMOTE_CONNECT_TIMEOUT_MS,
      2_000,
      250,
      30_000,
    ),
    headersTimeoutMs: boundedInteger(
      'AUDIO_REMOTE_HEADERS_TIMEOUT_MS',
      env.AUDIO_REMOTE_HEADERS_TIMEOUT_MS,
      5_000,
      500,
      60_000,
    ),
    bodyIdleTimeoutMs: boundedInteger(
      'AUDIO_REMOTE_BODY_IDLE_TIMEOUT_MS',
      env.AUDIO_REMOTE_BODY_IDLE_TIMEOUT_MS,
      15_000,
      1_000,
      300_000,
    ),
    // L'agent accepte huit GET simultanés. Le défaut du pool reste aligné.
    maxConnections: boundedInteger(
      'AUDIO_REMOTE_MAX_CONNECTIONS',
      env.AUDIO_REMOTE_MAX_CONNECTIONS,
      8,
      1,
      64,
    ),
  };
}
