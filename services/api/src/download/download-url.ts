/**
 * Validation et normalisation des URL soumises au moteur Antra.
 *
 * Règle du projet (cf. CLAUDE.md / TECH_DECISIONS) : le backend ne relaie
 * jamais une origine distante arbitraire. Seuls les hôtes de cette allowlist —
 * ceux qu'Antra sait réellement résoudre — sont acceptés, en HTTPS uniquement.
 * La valeur utilisateur ne traverse jamais un shell : elle est passée telle
 * quelle comme argument `spawn`, ce qui rend l'injection impossible, mais ne
 * dispense pas de cette validation.
 */

/**
 * Hôtes réellement dispatchés par `AntraService.fetch_playlist_tracks`
 * (`tools/antra/antra/core/service.py`) et ses prédicats
 * `is_tidal_url` / `is_qobuz_url` / `is_deezer_url` / `is_youtube_music_url`.
 *
 * `youtube.com` sans le sous-domaine `music` n'est PAS géré par Antra : il est
 * volontairement absent, plutôt qu'accepté puis rejeté après un spawn inutile.
 */
const ALLOWED_HOST_SUFFIXES = [
  'open.spotify.com',
  'music.apple.com',
  'music.youtube.com',
  'soundcloud.com',
  'tidal.com',
  'qobuz.com',
  'deezer.com',
] as const;

/** Hôtes acceptés à l'identique (jamais comme suffixe). */
const ALLOWED_EXACT_HOSTS = [
  'open.qobuz.com',
  'listen.tidal.com',
  'deezer.page.link',
  'link.deezer.com',
] as const;

/**
 * Amazon Music est régional. La liste est EXPLICITE et non un motif générique :
 * `^music\.amazon\.[a-z]+(\.[a-z]+)?$` accepterait `music.amazon.evil.com`,
 * qu'un tiers peut créer en quelques minutes sur son propre domaine.
 */
const AMAZON_MUSIC_HOSTS = new Set(
  [
    'com',
    'fr',
    'de',
    'es',
    'it',
    'nl',
    'se',
    'pl',
    'ca',
    'com.mx',
    'com.br',
    'com.au',
    'co.uk',
    'co.jp',
    'in',
    'sg',
    'ae',
    'sa',
    'eg',
    'com.tr',
    'com.be',
  ].map((tld) => `music.amazon.${tld}`),
);

/** Longueur maximale acceptée : au-delà, c'est un abus, pas une URL de piste. */
export const MAX_DOWNLOAD_URL_LENGTH = 2_000;

const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/;

export type DownloadUrlRejectionCode =
  | 'empty'
  | 'too_long'
  | 'control_character'
  | 'looks_like_option'
  | 'malformed'
  | 'scheme_not_https'
  | 'credentials_in_url'
  | 'host_not_allowed';

export interface DownloadUrlRejection {
  ok: false;
  code: DownloadUrlRejectionCode;
  message: string;
}

export interface DownloadUrlAcceptance {
  ok: true;
  /** URL nettoyée telle que soumise (espaces retirés). */
  requestedUrl: string;
  /** Forme canonique stable, utilisée comme clé anti-doublon actif. */
  normalizedUrl: string;
  host: string;
}

export type DownloadUrlResult = DownloadUrlAcceptance | DownloadUrlRejection;

/**
 * Paramètres de suivi publicitaire retirés à la normalisation. Aucun
 * identifiant fonctionnel n'est touché : `si`, `utm_*` et compagnie ne servent
 * qu'au traçage et rendraient la déduplication inopérante.
 */
const TRACKING_PARAMETERS = new Set([
  'si',
  'nd',
  'utm_source',
  'utm_medium',
  'utm_campaign',
  'utm_term',
  'utm_content',
  'fbclid',
  'gclid',
  '_branch_match_id',
  'referrer',
  'context',
]);

function reject(
  code: DownloadUrlRejectionCode,
  message: string,
): DownloadUrlRejection {
  return { ok: false, code, message };
}

function isAllowedHost(host: string): boolean {
  if ((ALLOWED_EXACT_HOSTS as readonly string[]).includes(host)) return true;
  if (AMAZON_MUSIC_HOSTS.has(host)) return true;
  return ALLOWED_HOST_SUFFIXES.some(
    (suffix) => host === suffix || host.endsWith(`.${suffix}`),
  );
}

/**
 * Valide puis normalise une URL de téléchargement.
 *
 * Retourne un résultat explicite plutôt qu'une exception : l'appelant HTTP doit
 * pouvoir répondre 400 avec un message précis sans capturer d'erreur générique.
 */
export function parseDownloadUrl(raw: unknown): DownloadUrlResult {
  if (typeof raw !== 'string') {
    return reject('empty', 'url est obligatoire et doit être une chaîne.');
  }

  const trimmed = raw.trim();
  if (trimmed.length === 0) {
    return reject('empty', 'url ne peut pas être vide.');
  }
  if (trimmed.length > MAX_DOWNLOAD_URL_LENGTH) {
    return reject(
      'too_long',
      `url ne peut pas dépasser ${MAX_DOWNLOAD_URL_LENGTH} caractères.`,
    );
  }
  if (CONTROL_CHARACTERS.test(trimmed)) {
    return reject(
      'control_character',
      'url contient un caractère de contrôle interdit.',
    );
  }
  // Une valeur commençant par `-` serait interprétée comme une option par
  // n'importe quelle CLI : refus AVANT toute construction d'argument.
  if (trimmed.startsWith('-')) {
    return reject(
      'looks_like_option',
      'url doit être une adresse https://, pas une option de ligne de commande.',
    );
  }

  let parsed: URL;
  try {
    parsed = new URL(trimmed);
  } catch {
    return reject('malformed', 'url n’est pas une adresse valide.');
  }

  // Couvre file:, javascript:, data:, http: et tout chemin local : seul HTTPS
  // passe, sans exception de développement.
  if (parsed.protocol !== 'https:') {
    return reject(
      'scheme_not_https',
      'Seules les adresses https:// sont acceptées.',
    );
  }
  if (parsed.username.length > 0 || parsed.password.length > 0) {
    return reject(
      'credentials_in_url',
      'url ne doit pas contenir d’identifiants.',
    );
  }

  const host = parsed.hostname.toLowerCase();
  if (!isAllowedHost(host)) {
    return reject(
      'host_not_allowed',
      'Ce service n’est pas pris en charge par le moteur de téléchargement.',
    );
  }

  return {
    ok: true,
    requestedUrl: trimmed,
    normalizedUrl: normalizeDownloadUrl(parsed),
    host,
  };
}

/**
 * Forme canonique : hôte en minuscules, port par défaut retiré, fragment
 * supprimé, paramètres de traçage retirés et paramètres restants triés.
 *
 * Les identifiants NÉCESSAIRES sont préservés : le chemin n'est jamais
 * réécrit, et seuls les paramètres explicitement listés comme publicitaires
 * disparaissent.
 */
export function normalizeDownloadUrl(input: URL | string): string {
  const url = typeof input === 'string' ? new URL(input) : new URL(input.href);
  url.hash = '';
  url.hostname = url.hostname.toLowerCase();
  if (url.port === '443') url.port = '';

  const kept = [...url.searchParams.entries()]
    .filter(([key]) => !TRACKING_PARAMETERS.has(key.toLowerCase()))
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  url.search = '';
  for (const [key, value] of kept) url.searchParams.append(key, value);

  // Un `/` final n'est significatif nulle part sur ces services : le retirer
  // évite deux jobs actifs pour la même ressource.
  if (url.pathname.length > 1 && url.pathname.endsWith('/')) {
    url.pathname = url.pathname.slice(0, -1);
  }

  return url.toString();
}

/** Liste publique des services acceptés — affichable dans l'UI, sans secret. */
export const SUPPORTED_DOWNLOAD_SERVICES: readonly string[] = [
  'open.spotify.com',
  'music.apple.com',
  'music.amazon.*',
  'music.youtube.com',
  'soundcloud.com',
  'tidal.com',
  'listen.tidal.com',
  'qobuz.com',
  'open.qobuz.com',
  'deezer.com',
  'deezer.page.link',
];
