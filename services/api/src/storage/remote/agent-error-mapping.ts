import {
  AudioStorageError,
  type AudioStorageErrorCode,
} from '../audio-storage.js';

const AGENT_ERROR_CODES = [
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

export type StorageAgentErrorCode = (typeof AGENT_ERROR_CODES)[number];

function isAgentErrorCode(value: string | undefined): value is StorageAgentErrorCode {
  return (
    value !== undefined &&
    (AGENT_ERROR_CODES as readonly string[]).includes(value)
  );
}

function publicCodeForAgentError(
  code: StorageAgentErrorCode,
): AudioStorageErrorCode {
  switch (code) {
    case 'FILE_NOT_FOUND':
      return 'NOT_FOUND';
    case 'TRACK_NOT_INDEXED':
      return 'INDEX_STALE';
    case 'INDEX_NOT_LOADED':
    case 'INDEX_INVALID':
      return 'INDEX_NOT_LOADED';
    case 'MUSIC_ROOT_UNAVAILABLE':
      return 'MUSIC_ROOT_UNAVAILABLE';
    case 'STREAM_LIMIT_REACHED':
      return 'STORAGE_BUSY';
    case 'AUTH_MISSING':
    case 'AUTH_INVALID':
    case 'AUTH_EXPIRED':
    case 'AUTH_REPLAY':
    case 'SOURCE_IP_DENIED':
      return 'REMOTE_AUTH_FAILED';
    case 'INVALID_RANGE':
      return 'REMOTE_RANGE_INVALID';
    case 'INVALID_TRACK_ID':
    case 'STREAM_READ_ERROR':
    case 'INTERNAL_ERROR':
      return 'REMOTE_INTERNAL';
  }
}

export function agentResponseError(
  statusCode: number,
  rawErrorCode: string | undefined,
): AudioStorageError {
  if (isAgentErrorCode(rawErrorCode)) {
    return new AudioStorageError(
      publicCodeForAgentError(rawErrorCode),
      'Le Storage Agent a refusé la requête.',
    );
  }

  // Un ancien agent ne fournit pas encore le code sur HEAD. Le 404 est traité
  // comme index potentiellement périmé, choix conservateur qui évite de faire
  // croire au mobile que la piste a été supprimée.
  if (statusCode === 404) {
    return new AudioStorageError(
      'INDEX_STALE',
      'La piste est absente de l’index distant ou du stockage.',
    );
  }
  if (statusCode === 401 || statusCode === 403) {
    return new AudioStorageError(
      'REMOTE_AUTH_FAILED',
      'Le Storage Agent a refusé l’authentification interne.',
    );
  }
  if (statusCode === 503) {
    return new AudioStorageError(
      'STORAGE_OFFLINE',
      'Le Storage Agent est temporairement indisponible.',
    );
  }
  return new AudioStorageError(
    'REMOTE_INVALID_RESPONSE',
    'Le Storage Agent a renvoyé une réponse inattendue.',
  );
}
