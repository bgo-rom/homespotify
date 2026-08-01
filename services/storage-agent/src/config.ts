/**
 * Configuration du Storage Agent.
 *
 * Trois règles non négociables :
 * 1. aucune valeur par défaut ne peut exposer l'agent au réseau (`HOST` vaut
 *    `127.0.0.1`, `0.0.0.0` est refusé, y compris explicitement) ;
 * 2. le secret partagé est obligatoire hors tests, et jamais journalisé ;
 * 3. toute valeur absente, vide ou hors bornes provoque un échec clair au
 *    démarrage — jamais un repli silencieux.
 */
import { randomBytes } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

export interface StorageAgentConfig {
  nodeEnv: 'development' | 'production' | 'test';
  host: string;
  port: number;
  /** Racine absolue de la bibliothèque musicale. Jamais exposée en réponse. */
  musicRoot: string;
  /** Chemin absolu du fichier d'index JSON. Jamais exposé en réponse. */
  indexPath: string;
  /** Secret HMAC partagé avec le VPS. Ne doit apparaître dans aucun log. */
  sharedSecret: string;
  /** IP sources autorisées, déjà normalisées (IPv4-mapped réduit en IPv4). */
  allowedRemoteIps: readonly string[];
  maxConcurrentStreams: number;
  hmacMaxClockSkewSeconds: number;
  logLevel: 'fatal' | 'error' | 'warn' | 'info' | 'debug' | 'trace';
  /** Intervalle de scrutation mtime de l'index ; 0 = rechargement manuel seul. */
  indexPollIntervalMs: number;
}

export class StorageAgentConfigError extends Error {
  constructor(message: string) {
    super(`Config Storage Agent invalide : ${message}`);
    this.name = 'StorageAgentConfigError';
  }
}

const NODE_ENVS = ['development', 'production', 'test'] as const;
const LOG_LEVELS = ['fatal', 'error', 'warn', 'info', 'debug', 'trace'] as const;

/** Longueur minimale du secret : 32 octets aléatoires encodés en hexadécimal. */
export const MIN_SHARED_SECRET_LENGTH = 32;

/** Interfaces d'écoute interdites par défaut ET explicitement. */
const FORBIDDEN_HOSTS = new Set(['0.0.0.0', '::', '[::]', '*']);

const IPV4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;

/**
 * Normalise une adresse IP pour comparaison stricte.
 *
 * Traite le cas IPv4-mapped IPv6 (`::ffff:10.8.0.1`), que Node expose lorsque
 * la socket est en dual-stack, SANS élargir la comparaison : seule la forme
 * mappée exacte est réduite, aucun préfixe ni masque n'est interprété.
 * Retourne `null` si l'entrée n'est pas une IP littérale reconnue.
 */
export function normalizeIp(raw: string | undefined | null): string | null {
  if (typeof raw !== 'string') return null;
  let value = raw.trim().toLowerCase();
  if (value.length === 0) return null;

  // `[::1]` ou `[::ffff:127.0.0.1]` : forme entre crochets des URL.
  if (value.startsWith('[') && value.endsWith(']')) value = value.slice(1, -1);

  // Un port éventuel n'est jamais accepté : l'appelant fournit une IP seule.
  if (value.includes('%')) value = value.slice(0, value.indexOf('%')); // zone id

  if (value.startsWith('::ffff:')) {
    const tail = value.slice('::ffff:'.length);
    if (IPV4.test(tail)) value = tail;
  }

  if (IPV4.test(value)) {
    const parts = value.split('.').map(Number);
    if (parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) return null;
    // Forme canonique : refuse `010.008.000.001` qui pourrait tromper une
    // comparaison textuelle.
    return parts.join('.');
  }

  // IPv6 littéral : accepté tel quel, comparé textuellement en minuscules.
  if (/^[0-9a-f:]+$/.test(value) && value.includes(':')) return value;

  return null;
}

function boundedInt(name: string, raw: string | undefined, fallback: number, min: number, max: number): number {
  if (raw === undefined || raw.trim().length === 0) return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new StorageAgentConfigError(`${name}="${raw}" (entier ${min}-${max} attendu)`);
  }
  return value;
}

function oneOf<T extends string>(name: string, value: string, allowed: readonly T[]): T {
  if ((allowed as readonly string[]).includes(value)) return value as T;
  throw new StorageAgentConfigError(`${name}="${value}" (attendu : ${allowed.join(', ')})`);
}

/**
 * Charge un `.env` sans écraser les variables déjà définies.
 * Appelé par `main.ts` seulement — jamais par les tests.
 */
export function loadDotEnv(path = '.env', env: NodeJS.ProcessEnv = process.env): void {
  if (!existsSync(path)) return;
  for (const line of readFileSync(path, 'utf-8').split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed.length === 0 || trimmed.startsWith('#')) continue;
    const separator = trimmed.indexOf('=');
    if (separator <= 0) continue;
    const key = trimmed.slice(0, separator).trim();
    if (key.length === 0 || env[key] !== undefined) continue;
    let value = trimmed.slice(separator + 1).trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    env[key] = value;
  }
}

function loadSharedSecret(env: NodeJS.ProcessEnv, nodeEnv: string): string {
  const secret = env.STORAGE_AGENT_SHARED_SECRET ?? '';
  if (secret.length >= MIN_SHARED_SECRET_LENGTH) return secret;
  if (secret.length > 0) {
    // Message volontairement sans la valeur ni sa longueur exacte.
    throw new StorageAgentConfigError(
      `STORAGE_AGENT_SHARED_SECRET trop court (${MIN_SHARED_SECRET_LENGTH} caractères minimum)`,
    );
  }
  if (nodeEnv !== 'test') {
    throw new StorageAgentConfigError(
      'STORAGE_AGENT_SHARED_SECRET est obligatoire (32+ caractères aléatoires)',
    );
  }
  // Tests uniquement : secret éphémère par processus, jamais écrit sur disque.
  return randomBytes(32).toString('hex');
}

function loadHost(env: NodeJS.ProcessEnv): string {
  const host = (env.STORAGE_AGENT_HOST ?? '127.0.0.1').trim();
  if (host.length === 0) {
    throw new StorageAgentConfigError('STORAGE_AGENT_HOST vide');
  }
  if (FORBIDDEN_HOSTS.has(host)) {
    throw new StorageAgentConfigError(
      `STORAGE_AGENT_HOST="${host}" interdit (écoute sur toutes les interfaces)`,
    );
  }
  return host;
}

function loadAllowedRemoteIps(env: NodeJS.ProcessEnv): readonly string[] {
  const raw = (env.STORAGE_AGENT_ALLOWED_REMOTE_IP ?? '10.8.0.1').trim();
  if (raw.length === 0) {
    throw new StorageAgentConfigError('STORAGE_AGENT_ALLOWED_REMOTE_IP vide');
  }
  const entries = raw
    .split(',')
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
  if (entries.length === 0) {
    throw new StorageAgentConfigError('STORAGE_AGENT_ALLOWED_REMOTE_IP vide');
  }
  const normalized: string[] = [];
  for (const entry of entries) {
    // Aucun CIDR : une plage se déclare IP par IP, jamais par masque.
    if (entry.includes('/')) {
      throw new StorageAgentConfigError(
        `STORAGE_AGENT_ALLOWED_REMOTE_IP="${entry}" (CIDR refusé, IP littérale attendue)`,
      );
    }
    const ip = normalizeIp(entry);
    if (ip === null) {
      throw new StorageAgentConfigError(
        `STORAGE_AGENT_ALLOWED_REMOTE_IP="${entry}" (IP littérale attendue)`,
      );
    }
    if (!normalized.includes(ip)) normalized.push(ip);
  }
  return Object.freeze(normalized);
}

function requiredPath(env: NodeJS.ProcessEnv, name: string): string {
  const raw = (env[name] ?? '').trim();
  if (raw.length === 0) {
    throw new StorageAgentConfigError(`${name} est obligatoire`);
  }
  return resolve(raw);
}

export function loadStorageAgentConfig(
  env: NodeJS.ProcessEnv = process.env,
): StorageAgentConfig {
  const nodeEnv = oneOf('NODE_ENV', env.NODE_ENV ?? 'development', NODE_ENVS);

  return {
    nodeEnv,
    host: loadHost(env),
    port: boundedInt('STORAGE_AGENT_PORT', env.STORAGE_AGENT_PORT, 3100, 1, 65535),
    musicRoot: requiredPath(env, 'STORAGE_AGENT_MUSIC_ROOT'),
    indexPath: requiredPath(env, 'STORAGE_AGENT_INDEX_PATH'),
    sharedSecret: loadSharedSecret(env, nodeEnv),
    allowedRemoteIps: loadAllowedRemoteIps(env),
    maxConcurrentStreams: boundedInt(
      'STORAGE_AGENT_MAX_CONCURRENT_STREAMS',
      env.STORAGE_AGENT_MAX_CONCURRENT_STREAMS,
      8,
      1,
      64,
    ),
    hmacMaxClockSkewSeconds: boundedInt(
      'STORAGE_AGENT_HMAC_MAX_CLOCK_SKEW_SECONDS',
      env.STORAGE_AGENT_HMAC_MAX_CLOCK_SKEW_SECONDS,
      60,
      5,
      300,
    ),
    logLevel: oneOf('STORAGE_AGENT_LOG_LEVEL', env.STORAGE_AGENT_LOG_LEVEL ?? 'info', LOG_LEVELS),
    indexPollIntervalMs: boundedInt(
      'STORAGE_AGENT_INDEX_POLL_INTERVAL_MS',
      env.STORAGE_AGENT_INDEX_POLL_INTERVAL_MS,
      5_000,
      0,
      3_600_000,
    ),
  };
}
