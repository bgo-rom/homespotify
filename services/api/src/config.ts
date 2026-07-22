import { randomBytes } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';

export interface AppConfig {
  nodeEnv: 'development' | 'production' | 'test';
  host: string;
  port: number;
  dbPath: string;
  logLevel: 'fatal' | 'error' | 'warn' | 'info' | 'debug' | 'trace';
  musicDir: string;
  incomingDir: string;
  /** Racine confinée des inbox/rejected/processed par utilisateur. */
  importRoot: string;
  coversDir: string;
  maxUploadBytes: number;
  /** Secret HMAC des access tokens — env AUTH_TOKEN_SECRET, obligatoire en production. */
  authTokenSecret: string;
  accessTokenTtlSeconds: number;
  refreshTokenTtlSeconds: number;
  backup?: BackupConfig;
  /** Cache serveur des dérivées Opus hors ligne (Phase 1A). Optionnel pour la
   * rétro-compatibilité des configs de test : buildApp applique
   * defaultOfflineConfig() en absence. */
  offline?: OfflineConfig;
  /**
   * Provider de similarité Last.fm (graphe track/artist). Absent = graphe
   * indisponible : le feed Découvrir reste vide proprement et le diagnostic
   * OWNER l'affiche. La clé vit dans `.env`, jamais commitée ni journalisée.
   */
  lastfm?: LastfmConfig;
  /**
   * Apple Music (MusicKit) — provider catalogue SECONDAIRE. Présent uniquement
   * si TOUS les secrets sont fournis. La clé privée .p8 et le JWT dérivé ne
   * sortent JAMAIS vers Git ni vers le frontend (cf. AGENTS/TECH_DECISIONS).
   */
  appleMusic?: AppleMusicConfig;
  /** Recherche catalogue multi-fournisseurs (Phase Discovery). Optionnel pour
   * la rétro-compatibilité des configs de test : buildApp applique
   * defaultDiscoveryConfig() en absence. */
  discovery?: DiscoveryConfig;
}

export interface OfflineConfig {
  /** Racine confinée du cache de dérivées (fichiers .ogg publiés + .part). */
  derivedCacheDir: string;
  /** Encodages simultanés — borné 1..4, jamais illimité (serveur H24). */
  encodeConcurrency: number;
}

export interface BackupConfig {
  enabled: boolean;
  root: string;
  hourLocal: number;
  retentionCount: number;
}

export interface SpotifyDiscoveryConfig {
  clientId: string;
  clientSecret: string;
  apiBase: string;
  authBase: string;
}

export interface DiscoveryConfig {
  enabled: boolean;
  defaultMarket: string;
  defaultLocale: string;
  searchTimeoutMs: number;
  providerTimeoutMs: number;
  cacheMaxEntries: number;
  musicbrainzUserAgent: string | null;
  musicbrainzApiBase: string;
  /** Présent uniquement si le flag ET les credentials sont fournis. */
  spotify?: SpotifyDiscoveryConfig;
  /** Apple Music discovery : suit config.appleMusic sauf refus explicite. */
  appleMusicEnabled: boolean;
  /** API publique Deezer : catalogue, images et extraits officiels uniquement. */
  deezerEnabled: boolean;
  deezerApiBase: string;
  tidalEnabled: false;
}

export interface LastfmConfig {
  apiKey: string;
  baseUrl: string;
  timeoutMs: number;
}

export interface AppleMusicConfig {
  teamId: string;
  keyId: string;
  mediaId: string | null;
  privateKeyPath: string;
  storefront: string;
}

/**
 * Charge un fichier `.env` (clé=valeur, lignes # ignorées) dans process.env
 * SANS écraser les variables déjà définies. Appelé par server.ts uniquement —
 * jamais par les tests.
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

function loadLastfmConfig(env: NodeJS.ProcessEnv): LastfmConfig | undefined {
  const apiKey = env.LASTFM_API_KEY ?? '';
  if (apiKey.length === 0) return undefined;
  const baseUrl = env.LASTFM_BASE_URL ?? 'https://ws.audioscrobbler.com/2.0/';
  const timeoutMs = Number(env.LASTFM_TIMEOUT_MS ?? 8000);
  if (!Number.isInteger(timeoutMs) || timeoutMs < 500 || timeoutMs > 30_000) {
    throw new Error(
      `Config invalide : LASTFM_TIMEOUT_MS="${env.LASTFM_TIMEOUT_MS}" (entier 500-30000 attendu)`,
    );
  }
  return { apiKey, baseUrl, timeoutMs };
}

/**
 * Charge la config Apple Music seulement si les secrets OBLIGATOIRES sont tous
 * présents (team, key, chemin .p8). Sinon `undefined` : le provider n'est pas
 * branché et iTunes durci reste primaire. Aucun secret n'est journalisé.
 */
function loadAppleMusicConfig(env: NodeJS.ProcessEnv): AppleMusicConfig | undefined {
  const teamId = env.APPLE_MUSIC_TEAM_ID ?? '';
  const keyId = env.APPLE_MUSIC_KEY_ID ?? '';
  const privateKeyPath = env.APPLE_MUSIC_PRIVATE_KEY_PATH ?? '';
  if (teamId.length === 0 || keyId.length === 0 || privateKeyPath.length === 0) return undefined;
  if (!existsSync(privateKeyPath)) {
    throw new Error(
      `Config invalide : APPLE_MUSIC_PRIVATE_KEY_PATH="${privateKeyPath}" introuvable (.p8 attendu)`,
    );
  }
  return {
    teamId,
    keyId,
    mediaId: env.APPLE_MUSIC_MEDIA_ID && env.APPLE_MUSIC_MEDIA_ID.length > 0 ? env.APPLE_MUSIC_MEDIA_ID : null,
    privateKeyPath,
    storefront: (env.APPLE_MUSIC_STOREFRONT ?? 'fr').toLowerCase(),
  };
}

function parseBool(value: string | undefined, fallback: boolean): boolean {
  if (value === undefined || value.length === 0) return fallback;
  return ['1', 'true', 'yes', 'on'].includes(value.toLowerCase());
}

function boundedInt(name: string, raw: string | undefined, fallback: number, min: number, max: number): number {
  const value = Number(raw ?? fallback);
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new Error(`Config invalide : ${name}="${raw}" (entier ${min}-${max} attendu)`);
  }
  return value;
}

/**
 * Config de la découverte catalogue. Spotify n'est branché que si le flag ET
 * les deux credentials sont présents. Deezer est un enrichissement public
 * sans secret et reste désactivable indépendamment. Aucun secret n'est
 * journalisé ni exposé.
 */
function loadDiscoveryConfig(env: NodeJS.ProcessEnv): DiscoveryConfig {
  const spotifyEnabled = parseBool(env.SPOTIFY_DISCOVERY_ENABLED, false);
  const spotifyClientId = env.SPOTIFY_CLIENT_ID ?? '';
  const spotifyClientSecret = env.SPOTIFY_CLIENT_SECRET ?? '';
  const spotify: SpotifyDiscoveryConfig | undefined =
    spotifyEnabled && spotifyClientId.length > 0 && spotifyClientSecret.length > 0
      ? {
          clientId: spotifyClientId,
          clientSecret: spotifyClientSecret,
          apiBase: env.SPOTIFY_API_BASE ?? 'https://api.spotify.com/v1',
          authBase: env.SPOTIFY_AUTH_BASE ?? 'https://accounts.spotify.com',
        }
      : undefined;
  const userAgent = env.MUSICBRAINZ_USER_AGENT?.trim() ?? '';
  return {
    enabled: parseBool(env.DISCOVERY_ENABLED, true),
    defaultMarket: (env.DISCOVERY_DEFAULT_MARKET ?? 'FR').toUpperCase(),
    defaultLocale: env.DISCOVERY_DEFAULT_LOCALE ?? 'fr-FR',
    searchTimeoutMs: boundedInt('DISCOVERY_SEARCH_TIMEOUT_MS', env.DISCOVERY_SEARCH_TIMEOUT_MS, 10_000, 1_000, 60_000),
    providerTimeoutMs: boundedInt('DISCOVERY_PROVIDER_TIMEOUT_MS', env.DISCOVERY_PROVIDER_TIMEOUT_MS, 6_000, 500, 30_000),
    cacheMaxEntries: boundedInt('DISCOVERY_CACHE_MAX_ENTRIES', env.DISCOVERY_CACHE_MAX_ENTRIES, 5_000, 100, 100_000),
    musicbrainzUserAgent: userAgent.length >= 8 ? userAgent : null,
    musicbrainzApiBase: env.MUSICBRAINZ_API_BASE ?? 'https://musicbrainz.org',
    ...(spotify ? { spotify } : {}),
    appleMusicEnabled: parseBool(env.APPLE_MUSIC_DISCOVERY_ENABLED, true),
    deezerEnabled: parseBool(env.DEEZER_DISCOVERY_ENABLED, true),
    deezerApiBase: env.DEEZER_API_BASE ?? 'https://api.deezer.com',
    tidalEnabled: false,
  };
}

/** Config discovery par défaut (aucun credential : tout provider externe payant
 * est désactivé, MusicBrainz exige un User-Agent explicite). */
export function defaultDiscoveryConfig(): DiscoveryConfig {
  return loadDiscoveryConfig({});
}

/** Cache de dérivées par défaut : storage/cache/offline-opus (cf. ARCHITECTURE.md), un seul encodage à la fois. */
export function defaultOfflineConfig(): OfflineConfig {
  return { derivedCacheDir: '../../storage/cache/offline-opus', encodeConcurrency: 1 };
}

const NODE_ENVS = ['development', 'production', 'test'] as const;
const LOG_LEVELS = ['fatal', 'error', 'warn', 'info', 'debug', 'trace'] as const;

function oneOf<T extends string>(name: string, value: string, allowed: readonly T[]): T {
  if ((allowed as readonly string[]).includes(value)) return value as T;
  throw new Error(`Config invalide : ${name}="${value}" (attendu : ${allowed.join(', ')})`);
}

function loadAuthTokenSecret(env: NodeJS.ProcessEnv, nodeEnv: string): string {
  const secret = env.AUTH_TOKEN_SECRET ?? '';
  if (secret.length >= 32) return secret;
  if (secret.length > 0) {
    throw new Error('Config invalide : AUTH_TOKEN_SECRET trop court (32 caractères minimum)');
  }
  if (nodeEnv === 'production') {
    throw new Error(
      'Config invalide : AUTH_TOKEN_SECRET est obligatoire en production (32+ caractères aléatoires)',
    );
  }
  // Dev/test : secret éphémère par processus. Les access tokens meurent au
  // redémarrage, mais les refresh tokens (persistés hachés en base) suffisent
  // à rouvrir une session — aucun secret n'est écrit sur disque.
  return randomBytes(32).toString('hex');
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  const port = Number(env.PORT ?? 3000);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`Config invalide : PORT="${env.PORT}" (entier 1-65535 attendu)`);
  }

  const dbPath = env.DB_PATH ?? './data/homespotify.db';
  if (dbPath.length === 0) {
    throw new Error('Config invalide : DB_PATH vide');
  }

  const maxUploadMb = Number(env.MAX_UPLOAD_MB ?? 200);
  if (!Number.isFinite(maxUploadMb) || maxUploadMb < 150) {
    // Contrainte projet : minimum 150 Mo pour les WAV (~50 Mo/piste, marge x3)
    throw new Error(`Config invalide : MAX_UPLOAD_MB="${env.MAX_UPLOAD_MB}" (nombre >= 150 attendu)`);
  }

  const nodeEnv = oneOf('NODE_ENV', env.NODE_ENV ?? 'development', NODE_ENVS);

  const accessTokenTtlSeconds = Number(env.ACCESS_TOKEN_TTL_SECONDS ?? 900);
  if (!Number.isInteger(accessTokenTtlSeconds) || accessTokenTtlSeconds < 60) {
    throw new Error(
      `Config invalide : ACCESS_TOKEN_TTL_SECONDS="${env.ACCESS_TOKEN_TTL_SECONDS}" (entier >= 60 attendu)`,
    );
  }
  const refreshTokenTtlDays = Number(env.REFRESH_TOKEN_TTL_DAYS ?? 30);
  if (!Number.isInteger(refreshTokenTtlDays) || refreshTokenTtlDays < 1) {
    throw new Error(
      `Config invalide : REFRESH_TOKEN_TTL_DAYS="${env.REFRESH_TOKEN_TTL_DAYS}" (entier >= 1 attendu)`,
    );
  }

  const lastfm = loadLastfmConfig(env);
  const appleMusic = loadAppleMusicConfig(env);
  const backup: BackupConfig = {
    enabled: parseBool(env.BACKUP_ENABLED, nodeEnv !== 'test'),
    root: env.BACKUP_ROOT ?? '../../backups/server',
    hourLocal: boundedInt('BACKUP_HOUR_LOCAL', env.BACKUP_HOUR_LOCAL, 3, 0, 23),
    retentionCount: boundedInt(
      'BACKUP_RETENTION_COUNT',
      env.BACKUP_RETENTION_COUNT,
      14,
      2,
      365,
    ),
  };
  return {
    nodeEnv,
    host: env.HOST ?? '127.0.0.1',
    port,
    dbPath,
    logLevel: oneOf('LOG_LEVEL', env.LOG_LEVEL ?? 'info', LOG_LEVELS),
    // Défauts pensés pour un lancement depuis services/api (pnpm dev/start) ;
    // en Docker, surchargés vers /data/* (voir infra/compose.yaml)
    musicDir: env.MUSIC_DIR ?? '../../storage/music',
    incomingDir: env.INCOMING_DIR ?? '../../storage/imports',
    importRoot: env.HOMESPOTIFY_IMPORT_ROOT ?? env.INCOMING_DIR ?? '../../storage/imports',
    coversDir: env.COVERS_DIR ?? '../../storage/covers',
    maxUploadBytes: Math.floor(maxUploadMb * 1024 * 1024),
    offline: {
      derivedCacheDir: env.OFFLINE_CACHE_DIR ?? '../../storage/cache/offline-opus',
      encodeConcurrency: boundedInt('OFFLINE_ENCODE_CONCURRENCY', env.OFFLINE_ENCODE_CONCURRENCY, 1, 1, 4),
    },
    authTokenSecret: loadAuthTokenSecret(env, nodeEnv),
    accessTokenTtlSeconds,
    refreshTokenTtlSeconds: refreshTokenTtlDays * 24 * 60 * 60,
    backup,
    ...(lastfm ? { lastfm } : {}),
    ...(appleMusic ? { appleMusic } : {}),
    discovery: loadDiscoveryConfig(env),
  };
}
