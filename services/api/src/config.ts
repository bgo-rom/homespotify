import { randomBytes } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import {
  parseAudioStorageMode,
  type AudioStorageMode,
} from './storage/provider-factory.js';
import {
  loadRemoteStorageConfig,
  type RemoteStorageConfig,
} from './storage/remote/remote-config.js';
import {
  loadAudioCacheConfig,
  type AudioCacheConfig,
} from './storage/cache/cache-config.js';

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
  /**
   * Origine des fichiers audio (plan de migration VPS, Phase 1).
   * `local` seul est implémenté ; `remote`/`cached` échouent explicitement.
   * Optionnel : absent = `local`, soit le comportement historique.
   */
  audioStorageMode?: AudioStorageMode;
  /** Obligatoire uniquement lorsque `audioStorageMode === "remote"`. */
  audioRemote?: RemoteStorageConfig;
  /** Obligatoire uniquement lorsque `audioStorageMode === "cached"`. */
  audioCache?: AudioCacheConfig;
  maxUploadBytes: number;
  /** Secret HMAC des access tokens — env AUTH_TOKEN_SECRET, obligatoire en production. */
  authTokenSecret: string;
  accessTokenTtlSeconds: number;
  refreshTokenTtlSeconds: number;
  backup?: BackupConfig;
  /**
   * Acquisition distante optionnelle. Absente tant que LUCIDA_SCRIPT_PATH
   * n'est pas configuré : aucun processus Python n'est alors créé.
   */
  lucida?: LucidaConfig;
  acquisitionProviders: AcquisitionProviderConfig;
  /**
   * Moteur de téléchargement Antra — fournisseur PRINCIPAL par défaut.
   * Absent tant que `ANTRA_DIR` n'est pas configuré : aucun processus Python
   * n'est alors créé et les routes `/api/downloads` répondent 503.
   */
  antra?: AntraConfig;
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
  /**
   * Mise à jour automatique de l'application Android. Absente tant que
   * `APP_UPDATE_ANDROID_DIR` n'est pas configuré : les routes
   * `/api/app-update/android/*` répondent alors 503, et rien d'autre ne change.
   */
  appUpdate?: AppUpdateConfig;
}

export interface AppUpdateConfig {
  /** Racine du catalogue de releases Android (releases/, metadata/, latest.json). */
  androidDir: string;
}

export interface OfflineConfig {
  /** Racine confinée du cache de dérivées (fichiers .ogg publiés + .part). */
  derivedCacheDir: string;
  /** Encodages simultanés — borné 1..4, jamais illimité (serveur H24). */
  encodeConcurrency: number;
}

export interface LucidaConfig {
  /** Chemin absolu du script Python validé au chargement de la configuration. */
  scriptPath: string;
  /** Exécutable Python ou chemin complet ; résolu par spawn, jamais par un shell. */
  pythonPath: string;
  /** Délai global du processus complet, distinct du timeout HTTP du script. */
  processTimeoutMs: number;
  /**
   * Téléchargements simultanés autorisés (1 à 4).
   *
   * Chaque unité = un processus Python + un Chromium. Au-delà de 4, la machine
   * devient le goulot et la rafale vers le service distant ressemble à un abus.
   */
  maxConcurrentDownloads: number;
  challengeCooldownSeconds: number;
  rateLimitDefaultCooldownSeconds: number;
  unavailableCooldownSeconds: number;
  maxCooldownSeconds: number;
  providerFailureWindowSeconds: number;
  providerFailureThreshold: number;
  /**
   * Autorise uniquement le workflow manuel externe. Le service ne lance
   * jamais Chromium visible, même lorsque cette option vaut true.
   */
  interactiveVerificationEnabled: boolean;
  interactiveVerificationTimeoutSeconds: number;
}

/**
 * Configuration du moteur Antra.
 *
 * La clé Premium n'apparaît JAMAIS ici : elle vit dans le `.env` du dépôt Antra
 * et n'est lue que par le processus Python, grâce au `cwd` positionné sur
 * [dir]. Le backend ne la lit pas, ne la journalise pas et ne l'expose pas.
 */
export interface AntraConfig {
  /** Racine du dépôt Antra ; devient le `cwd` du processus Python. */
  dir: string;
  /** Interpréteur Python du venv Antra ; résolu par spawn, jamais par un shell. */
  pythonPath: string;
  /** Racine de staging des téléchargements (un sous-dossier par job). */
  outputDir: string;
  /** Préférence de source Antra (`auto` par défaut). */
  source: string;
  /** Format de sortie demandé à Antra (`flac` par défaut). */
  format: string;
  /** Extensions acceptées à l'issue du téléchargement (minuscules, avec point). */
  allowedExtensions: readonly string[];
  /** Téléchargements simultanés (1 à 4). */
  maxConcurrent: number;
  /** Délai global d'un job, arbre de processus tué au-delà. */
  jobTimeoutMs: number;
  /**
   * Toujours `false` en pratique : Soulseek ne doit jamais être amorcé par le
   * backend, sinon le processus attend une configuration interactive.
   */
  slskdAutoBootstrap: boolean;
  /** Logs Antra détaillés relayés en debug. Jamais activé en production. */
  verbose: boolean;
}

export interface AcquisitionProviderConfig {
  /**
   * Chaîne d'acquisition HISTORIQUE (Lucida / Monochrome / DoubleDouble).
   *
   * `false` par défaut depuis l'intégration d'Antra : les anciens fournisseurs
   * ne sont plus jamais lancés automatiquement. Les fichiers restent en place
   * et le service redevient identique à l'ancien comportement en repassant
   * `ACQUISITION_LEGACY_ENABLED=true`.
   */
  legacyEnabled: boolean;
  order: readonly ('LUCIDA' | 'MONOCHROME_MANUAL')[];
  monochromeManualFallbackEnabled: boolean;
  monochromeBaseUrl: string;
  monochromeManualTimeoutSeconds: number;
  monochromeDownloadDirectory: string;
  monochromeFileStabilitySeconds: number;
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

function loadLucidaConfig(env: NodeJS.ProcessEnv): LucidaConfig | undefined {
  const rawScriptPath = env.LUCIDA_SCRIPT_PATH?.trim() ?? '';
  if (rawScriptPath.length === 0) return undefined;

  const scriptPath = resolve(rawScriptPath);
  if (!scriptPath.toLowerCase().endsWith('.py')) {
    throw new Error(
      `Config invalide : LUCIDA_SCRIPT_PATH="${rawScriptPath}" (fichier .py attendu)`,
    );
  }
  if (!existsSync(scriptPath)) {
    throw new Error(
      `Config invalide : LUCIDA_SCRIPT_PATH="${rawScriptPath}" introuvable`,
    );
  }

  const pythonPath = env.LUCIDA_PYTHON_PATH?.trim() || 'python';
  const processTimeoutSeconds = boundedInt(
    'LUCIDA_PROCESS_TIMEOUT_SECONDS',
    env.LUCIDA_PROCESS_TIMEOUT_SECONDS,
    300,
    10,
    1_800,
  );

  const maxConcurrentDownloads = boundedInt(
    'LUCIDA_MAX_CONCURRENT_DOWNLOADS',
    env.LUCIDA_MAX_CONCURRENT_DOWNLOADS,
    3,
    1,
    4,
  );
  const challengeCooldownSeconds = boundedInt(
    'LUCIDA_CHALLENGE_COOLDOWN_SECONDS',
    env.LUCIDA_CHALLENGE_COOLDOWN_SECONDS,
    1_800,
    60,
    21_600,
  );
  const rateLimitDefaultCooldownSeconds = boundedInt(
    'LUCIDA_RATE_LIMIT_DEFAULT_COOLDOWN_SECONDS',
    env.LUCIDA_RATE_LIMIT_DEFAULT_COOLDOWN_SECONDS,
    900,
    60,
    86_400,
  );
  const unavailableCooldownSeconds = boundedInt(
    'LUCIDA_UNAVAILABLE_COOLDOWN_SECONDS',
    env.LUCIDA_UNAVAILABLE_COOLDOWN_SECONDS,
    600,
    60,
    21_600,
  );
  const maxCooldownSeconds = boundedInt(
    'LUCIDA_MAX_COOLDOWN_SECONDS',
    env.LUCIDA_MAX_COOLDOWN_SECONDS,
    21_600,
    60,
    86_400,
  );
  const providerFailureWindowSeconds = boundedInt(
    'LUCIDA_PROVIDER_FAILURE_WINDOW_SECONDS',
    env.LUCIDA_PROVIDER_FAILURE_WINDOW_SECONDS,
    600,
    60,
    3_600,
  );
  const providerFailureThreshold = boundedInt(
    'LUCIDA_PROVIDER_FAILURE_THRESHOLD',
    env.LUCIDA_PROVIDER_FAILURE_THRESHOLD,
    2,
    1,
    10,
  );
  const interactiveVerificationEnabled = strictBool(
    'LUCIDA_INTERACTIVE_VERIFICATION_ENABLED',
    env.LUCIDA_INTERACTIVE_VERIFICATION_ENABLED,
    false,
  );
  const interactiveVerificationTimeoutSeconds = boundedInt(
    'LUCIDA_INTERACTIVE_VERIFICATION_TIMEOUT_SECONDS',
    env.LUCIDA_INTERACTIVE_VERIFICATION_TIMEOUT_SECONDS,
    120,
    30,
    600,
  );
  if (
    maxCooldownSeconds < challengeCooldownSeconds ||
    maxCooldownSeconds < unavailableCooldownSeconds ||
    maxCooldownSeconds < rateLimitDefaultCooldownSeconds
  ) {
    throw new Error(
      'Config invalide : LUCIDA_MAX_COOLDOWN_SECONDS doit être supérieur ou égal aux cooldowns configurés',
    );
  }

  return {
    scriptPath,
    pythonPath,
    processTimeoutMs: processTimeoutSeconds * 1_000,
    maxConcurrentDownloads,
    challengeCooldownSeconds,
    rateLimitDefaultCooldownSeconds,
    unavailableCooldownSeconds,
    maxCooldownSeconds,
    providerFailureWindowSeconds,
    providerFailureThreshold,
    interactiveVerificationEnabled,
    interactiveVerificationTimeoutSeconds,
  };
}

const ANTRA_SOURCES = [
  'auto',
  'hifi',
  'amazon',
  'apple',
  'tidal',
  'qobuz',
  'deezer',
  'jiosaavn',
  'soulseek',
] as const;

const ANTRA_FORMATS = ['flac', 'source', 'alac', 'm4a', 'aac', 'mp3'] as const;

/**
 * Extensions réellement importables par le pipeline local
 * (`UserImportService`, bit-perfect WAV/FLAC). Autoriser autre chose ferait
 * échouer l'import APRÈS un téléchargement réussi : c'est un choix explicite,
 * pas un défaut.
 */
const ANTRA_ACCEPTED_EXTENSIONS = ['.flac', '.wav', '.m4a', '.mp3', '.aac'] as const;

const DEFAULT_ANTRA_EXTENSIONS = ['.flac', '.wav'] as const;

/**
 * Charge la configuration Antra. Absente si `ANTRA_DIR` n'est pas fourni : le
 * backend démarre normalement, seul le fournisseur devient indisponible.
 *
 * Les chemins sont validés ici pour échouer tôt et lisiblement, jamais au
 * milieu d'un téléchargement.
 */
function loadAntraConfig(env: NodeJS.ProcessEnv): AntraConfig | undefined {
  const rawDir = env.ANTRA_DIR?.trim() ?? '';
  if (rawDir.length === 0) return undefined;

  const dir = resolve(rawDir);
  if (!existsSync(dir)) {
    throw new Error(`Config invalide : ANTRA_DIR="${rawDir}" introuvable`);
  }

  const rawPython = env.ANTRA_PYTHON?.trim() ?? '';
  const pythonPath = rawPython.length > 0 ? resolve(rawPython) : '';
  if (pythonPath.length === 0) {
    throw new Error(
      'Config invalide : ANTRA_PYTHON est obligatoire dès que ANTRA_DIR est défini',
    );
  }
  if (!existsSync(pythonPath)) {
    throw new Error(`Config invalide : ANTRA_PYTHON="${rawPython}" introuvable`);
  }

  const outputDir = resolve(
    env.ANTRA_OUTPUT_DIR?.trim() ||
      env.HOMESPOTIFY_IMPORT_ROOT?.trim() ||
      env.INCOMING_DIR?.trim() ||
      '../../storage/imports',
  );

  const source = (env.ANTRA_SOURCE?.trim() || 'auto').toLowerCase();
  if (!(ANTRA_SOURCES as readonly string[]).includes(source)) {
    throw new Error(
      `Config invalide : ANTRA_SOURCE="${env.ANTRA_SOURCE}" (attendu : ${ANTRA_SOURCES.join(', ')})`,
    );
  }

  const format = (env.ANTRA_FORMAT?.trim() || 'flac').toLowerCase();
  if (!(ANTRA_FORMATS as readonly string[]).includes(format)) {
    throw new Error(
      `Config invalide : ANTRA_FORMAT="${env.ANTRA_FORMAT}" (attendu : ${ANTRA_FORMATS.join(', ')})`,
    );
  }

  const rawExtensions = env.ANTRA_ALLOWED_EXTENSIONS?.trim() ?? '';
  const allowedExtensions =
    rawExtensions.length === 0
      ? [...DEFAULT_ANTRA_EXTENSIONS]
      : rawExtensions
          .split(',')
          .map((value) => value.trim().toLowerCase())
          .filter(Boolean)
          .map((value) => (value.startsWith('.') ? value : `.${value}`));
  if (
    allowedExtensions.length === 0 ||
    allowedExtensions.some(
      (value) => !(ANTRA_ACCEPTED_EXTENSIONS as readonly string[]).includes(value),
    )
  ) {
    throw new Error(
      `Config invalide : ANTRA_ALLOWED_EXTENSIONS="${rawExtensions}" (attendu : ${ANTRA_ACCEPTED_EXTENSIONS.join(', ')})`,
    );
  }

  const maxConcurrent = boundedInt(
    'ANTRA_MAX_CONCURRENT',
    env.ANTRA_MAX_CONCURRENT,
    2,
    1,
    4,
  );
  const jobTimeoutMs = boundedInt(
    'ANTRA_JOB_TIMEOUT_MS',
    env.ANTRA_JOB_TIMEOUT_MS,
    900_000,
    30_000,
    3_600_000,
  );
  const slskdAutoBootstrap = strictBool(
    'ANTRA_SLSKD_AUTO_BOOTSTRAP',
    env.ANTRA_SLSKD_AUTO_BOOTSTRAP,
    false,
  );
  if (slskdAutoBootstrap) {
    throw new Error(
      'Config invalide : ANTRA_SLSKD_AUTO_BOOTSTRAP doit rester false — Soulseek exigerait une configuration interactive impossible côté serveur',
    );
  }

  return {
    dir,
    pythonPath,
    outputDir,
    source,
    format,
    allowedExtensions,
    maxConcurrent,
    jobTimeoutMs,
    slskdAutoBootstrap: false,
    verbose: strictBool('ANTRA_VERBOSE', env.ANTRA_VERBOSE, false),
  };
}

function loadAcquisitionProviderConfig(
  env: NodeJS.ProcessEnv,
): AcquisitionProviderConfig {
  const rawOrder =
    env.ACQUISITION_PROVIDER_ORDER ?? 'LUCIDA,MONOCHROME_MANUAL';
  const order = rawOrder
    .split(',')
    .map((value) => value.trim().toLocaleUpperCase('en-US'))
    .filter(Boolean);
  if (
    order.length < 1 ||
    order.length > 2 ||
    new Set(order).size !== order.length ||
    order.some(
      (value) => value !== 'LUCIDA' && value !== 'MONOCHROME_MANUAL',
    ) ||
    order[0] !== 'LUCIDA'
  ) {
    throw new Error(
      'Config invalide : ACQUISITION_PROVIDER_ORDER doit commencer par LUCIDA et ne contenir que LUCIDA,MONOCHROME_MANUAL',
    );
  }

  const monochromeBaseUrl =
    env.MONOCHROME_BASE_URL ?? 'https://monochrome.tf/';
  let parsedBaseUrl: URL;
  try {
    parsedBaseUrl = new URL(monochromeBaseUrl);
  } catch {
    throw new Error(
      'Config invalide : MONOCHROME_BASE_URL doit être une URL HTTPS valide',
    );
  }
  if (
    parsedBaseUrl.protocol !== 'https:' ||
    parsedBaseUrl.username ||
    parsedBaseUrl.password ||
    parsedBaseUrl.search ||
    parsedBaseUrl.hash
  ) {
    throw new Error(
      'Config invalide : MONOCHROME_BASE_URL doit être une URL HTTPS publique sans credentials, query ni fragment',
    );
  }
  const monochromeDownloadDirectory =
    env.MONOCHROME_DOWNLOAD_DIRECTORY ?? '';
  if (
    monochromeDownloadDirectory &&
    !resolve(monochromeDownloadDirectory).match(/^[A-Za-z]:\\/u)
  ) {
    throw new Error(
      'Config invalide : MONOCHROME_DOWNLOAD_DIRECTORY doit être un chemin Windows absolu',
    );
  }

  return {
    legacyEnabled: strictBool(
      'ACQUISITION_LEGACY_ENABLED',
      env.ACQUISITION_LEGACY_ENABLED,
      false,
    ),
    order: order as ('LUCIDA' | 'MONOCHROME_MANUAL')[],
    monochromeManualFallbackEnabled: strictBool(
      'MONOCHROME_MANUAL_FALLBACK_ENABLED',
      env.MONOCHROME_MANUAL_FALLBACK_ENABLED,
      true,
    ),
    monochromeBaseUrl: parsedBaseUrl.toString(),
    monochromeManualTimeoutSeconds: boundedInt(
      'MONOCHROME_MANUAL_TIMEOUT_SECONDS',
      env.MONOCHROME_MANUAL_TIMEOUT_SECONDS,
      600,
      30,
      1_800,
    ),
    monochromeDownloadDirectory,
    monochromeFileStabilitySeconds: boundedInt(
      'MONOCHROME_FILE_STABILITY_SECONDS',
      env.MONOCHROME_FILE_STABILITY_SECONDS,
      3,
      1,
      30,
    ),
  };
}

/**
 * Catalogue des mises à jour Android. Absent si `APP_UPDATE_ANDROID_DIR` n'est
 * pas fourni : la fonctionnalité est indisponible, jamais une panne. Le chemin
 * est résolu ici pour échouer tôt sur une valeur relative ambiguë ; son
 * existence n'est PAS exigée au démarrage (le premier `publish` le crée).
 */
function loadAppUpdateConfig(env: NodeJS.ProcessEnv): AppUpdateConfig | undefined {
  const raw = env.APP_UPDATE_ANDROID_DIR?.trim() ?? '';
  if (raw.length === 0) return undefined;
  return { androidDir: resolve(raw) };
}

function parseBool(value: string | undefined, fallback: boolean): boolean {
  if (value === undefined || value.length === 0) return fallback;
  return ['1', 'true', 'yes', 'on'].includes(value.toLowerCase());
}

function strictBool(
  name: string,
  raw: string | undefined,
  fallback: boolean,
): boolean {
  if (raw === undefined || raw.length === 0) return fallback;
  const normalized = raw.trim().toLowerCase();
  if (['1', 'true', 'yes', 'on'].includes(normalized)) return true;
  if (['0', 'false', 'no', 'off'].includes(normalized)) return false;
  throw new Error(
    `Config invalide : ${name}="${raw}" (booléen attendu)`,
  );
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
  const audioStorageMode = parseAudioStorageMode(env.AUDIO_STORAGE_MODE);
  const audioRemote = loadRemoteStorageConfig(env, audioStorageMode);
  const audioCache = loadAudioCacheConfig(env, audioStorageMode);

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
  const lucida = loadLucidaConfig(env);
  const acquisitionProviders = loadAcquisitionProviderConfig(env);
  const antra = loadAntraConfig(env);
  const appUpdate = loadAppUpdateConfig(env);
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
    // Valeur inconnue -> exception au démarrage, jamais de repli sur 'local'.
    audioStorageMode,
    ...(audioRemote === undefined ? {} : { audioRemote }),
    ...(audioCache === undefined ? {} : { audioCache }),
    maxUploadBytes: Math.floor(maxUploadMb * 1024 * 1024),
    offline: {
      derivedCacheDir: env.OFFLINE_CACHE_DIR ?? '../../storage/cache/offline-opus',
      encodeConcurrency: boundedInt('OFFLINE_ENCODE_CONCURRENCY', env.OFFLINE_ENCODE_CONCURRENCY, 1, 1, 4),
    },
    authTokenSecret: loadAuthTokenSecret(env, nodeEnv),
    accessTokenTtlSeconds,
    refreshTokenTtlSeconds: refreshTokenTtlDays * 24 * 60 * 60,
    backup,
    ...(lucida ? { lucida } : {}),
    acquisitionProviders,
    ...(antra ? { antra } : {}),
    ...(lastfm ? { lastfm } : {}),
    ...(appleMusic ? { appleMusic } : {}),
    ...(appUpdate ? { appUpdate } : {}),
    discovery: loadDiscoveryConfig(env),
  };
}
