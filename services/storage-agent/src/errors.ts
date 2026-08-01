/**
 * Codes d'erreur stables du Storage Agent.
 *
 * Ces codes constituent le CONTRAT interne PC ↔ VPS. Ils sont volontairement
 * distincts des codes HTTP publics de l'API : c'est le futur
 * `RemoteStorageProvider` (Phase 4) qui décidera qu'un `TRACK_NOT_INDEXED`
 * devient un 404 public et qu'un `STREAM_LIMIT_REACHED` devient un 503 public.
 *
 * Règle absolue : le corps de réponse ne contient JAMAIS de détail système
 * (chemin, nom de fichier, message d'exception, secret). Seuls le code stable
 * et un message générique en français sortent de l'agent.
 */
export const STORAGE_AGENT_ERROR_CODES = [
  'INVALID_TRACK_ID',
  'TRACK_NOT_INDEXED',
  'FILE_NOT_FOUND',
  'INVALID_RANGE',
  'AUTH_MISSING',
  'AUTH_INVALID',
  'AUTH_EXPIRED',
  'AUTH_REPLAY',
  'SOURCE_IP_DENIED',
  'INDEX_NOT_LOADED',
  'INDEX_INVALID',
  'MUSIC_ROOT_UNAVAILABLE',
  'STREAM_LIMIT_REACHED',
  'STREAM_READ_ERROR',
  'INTERNAL_ERROR',
] as const;

export type StorageAgentErrorCode = (typeof STORAGE_AGENT_ERROR_CODES)[number];

/**
 * Statut HTTP interne associé à chaque code.
 *
 * Décision documentée (cf. docs/VPS_PHASE2_STORAGE_AGENT.md) : la saturation de
 * concurrence renvoie **503** et non 429. Motif : la limite protège une
 * ressource serveur (disque + bande passante WireGuard), elle ne sanctionne pas
 * un client abusif — l'unique client légitime est le VPS. 503 + `Retry-After`
 * exprime « réessaie, ce n'est pas ta faute », ce qui est la sémantique exacte.
 */
const STATUS_BY_CODE: Record<StorageAgentErrorCode, number> = {
  INVALID_TRACK_ID: 400,
  TRACK_NOT_INDEXED: 404,
  FILE_NOT_FOUND: 404,
  INVALID_RANGE: 416,
  AUTH_MISSING: 401,
  AUTH_INVALID: 401,
  AUTH_EXPIRED: 401,
  AUTH_REPLAY: 401,
  SOURCE_IP_DENIED: 403,
  INDEX_NOT_LOADED: 503,
  INDEX_INVALID: 503,
  MUSIC_ROOT_UNAVAILABLE: 503,
  STREAM_LIMIT_REACHED: 503,
  STREAM_READ_ERROR: 500,
  INTERNAL_ERROR: 500,
};

/** Messages publics : génériques par construction, jamais dérivés d'une exception. */
const MESSAGE_BY_CODE: Record<StorageAgentErrorCode, string> = {
  INVALID_TRACK_ID: 'Identifiant de piste invalide.',
  TRACK_NOT_INDEXED: 'Piste absente de l’index local.',
  FILE_NOT_FOUND: 'Fichier audio introuvable.',
  INVALID_RANGE: 'Plage d’octets demandée invalide.',
  AUTH_MISSING: 'Authentification requise.',
  AUTH_INVALID: 'Authentification invalide.',
  AUTH_EXPIRED: 'Horodatage hors de la fenêtre autorisée.',
  AUTH_REPLAY: 'Nonce déjà utilisé.',
  SOURCE_IP_DENIED: 'Origine réseau non autorisée.',
  INDEX_NOT_LOADED: 'Index local non chargé.',
  INDEX_INVALID: 'Index local invalide.',
  MUSIC_ROOT_UNAVAILABLE: 'Racine musicale indisponible.',
  STREAM_LIMIT_REACHED: 'Limite de flux simultanés atteinte.',
  STREAM_READ_ERROR: 'Erreur de lecture du fichier.',
  INTERNAL_ERROR: 'Erreur interne.',
};

export function statusForErrorCode(code: StorageAgentErrorCode): number {
  return STATUS_BY_CODE[code];
}

export function messageForErrorCode(code: StorageAgentErrorCode): string {
  return MESSAGE_BY_CODE[code];
}

/** Corps de réponse d'erreur — forme unique, sans détail système. */
export interface StorageAgentErrorBody {
  error: StorageAgentErrorCode;
  message: string;
  requestId: string;
}

export function errorBody(
  code: StorageAgentErrorCode,
  requestId: string,
): StorageAgentErrorBody {
  return { error: code, message: messageForErrorCode(code), requestId };
}

/**
 * Erreur interne typée.
 *
 * `detail` sert exclusivement aux logs locaux et n'est jamais sérialisé dans une
 * réponse HTTP.
 */
export class StorageAgentError extends Error {
  constructor(
    readonly code: StorageAgentErrorCode,
    readonly detail?: string,
  ) {
    super(messageForErrorCode(code));
    this.name = 'StorageAgentError';
  }

  get status(): number {
    return statusForErrorCode(this.code);
  }
}
