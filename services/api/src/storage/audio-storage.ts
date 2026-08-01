import type { Readable } from 'node:stream';

/**
 * Abstraction du stockage audio.
 *
 * Objectif : le backend ne connaît plus la localisation physique des fichiers.
 * Aujourd'hui un seul provider existe (local), demain le même contrat servira
 * un agent distant sur le PC Windows et une couche de cache sur le VPS.
 *
 * Règle de séparation des responsabilités : le provider fournit des
 * INFORMATIONS et des FLUX. Il ne connaît ni HTTP, ni les codes de statut, ni
 * les en-têtes. Le parsing du Range et les statuts 200/206/416 restent
 * intégralement dans la couche HTTP.
 */

/**
 * Référence portable vers un fichier audio.
 *
 * `relativePath` est TOUJOURS relatif à la racine du provider et TOUJOURS
 * exprimé avec `/`, quel que soit le système d'exploitation. La base de
 * données, elle, n'est pas modifiée : elle continue de stocker des chemins
 * Windows avec `\` (157/157 au 2026-07-25). La conversion se fait ici, à la
 * construction de la référence.
 */
export interface TrackStorageReference {
  /** Identifiant de la piste, utilisé pour les diagnostics `STREAM_*`. */
  trackId: number;
  /** Chemin portable, relatif à la racine du provider, séparateur `/`. */
  relativePath: string;
  /** SHA-256 du contenu : sert d'ETag et, plus tard, de clé de cache. */
  contentHash: string;
  /** Taille SQLite attendue, utilisée seulement comme contrôle de divergence. */
  expectedSizeBytes?: number;
}

/** Plage d'octets inclusive, alignée sur la sémantique HTTP Range. */
export interface ByteRange {
  start: number;
  end: number;
}

export interface AudioFileInfo {
  sizeBytes: number;
  /** Date de dernière modification, pour l'en-tête `Last-Modified`. */
  modifiedAt: Date;
  /** Type observé à la source, conservé par le cache. */
  contentType?: string;
  /** Origine effective des octets — informatif, utile dès la Phase 5. */
  source: 'local' | 'cache' | 'remote';
}

export type StorageHealth =
  | { status: 'online'; source: 'local' | 'cache' | 'remote'; latencyMs: number }
  | { status: 'offline'; reason: string }
  | { status: 'degraded'; reason: string };

/**
 * Codes d'erreur du stockage.
 *
 * Volontairement distincts des codes HTTP : c'est la route qui décide qu'un
 * `NOT_FOUND` devient un 404 et — à partir de la Phase 4 — qu'un
 * `STORAGE_OFFLINE` devient un 503 plutôt qu'un 404.
 */
export type AudioStorageErrorCode =
  | 'INVALID_REFERENCE'
  | 'PATH_TRAVERSAL'
  | 'NOT_FOUND'
  | 'NOT_A_FILE'
  | 'READ_FAILED'
  | 'STORAGE_OFFLINE'
  | 'AGENT_UNAVAILABLE'
  | 'CONNECT_TIMEOUT'
  | 'HEADERS_TIMEOUT'
  | 'BODY_TIMEOUT'
  | 'REMOTE_AUTH_FAILED'
  | 'INDEX_STALE'
  | 'INDEX_NOT_LOADED'
  | 'MUSIC_ROOT_UNAVAILABLE'
  | 'STORAGE_BUSY'
  | 'REMOTE_INVALID_RESPONSE'
  | 'REMOTE_RANGE_INVALID'
  | 'REMOTE_STREAM_INTERRUPTED'
  | 'REMOTE_INTERNAL'
  | 'CACHE_MISS'
  | 'CACHE_CORRUPT'
  | 'CACHE_DISK_FULL'
  | 'CACHE_WRITE_FAILED'
  | 'CACHE_INDEX_FAILED'
  | 'CACHE_FILL_ABORTED'
  | 'CACHE_FILL_TRUNCATED'
  | 'CACHE_EVICTION_FAILED'
  | 'CACHE_DISABLED_FOR_REQUEST';

export class AudioStorageError extends Error {
  constructor(
    readonly code: AudioStorageErrorCode,
    message: string,
    override readonly cause?: unknown,
  ) {
    super(message);
    this.name = 'AudioStorageError';
  }
}

export interface AudioStorageProvider {
  /** Métadonnées du fichier. Lève `AudioStorageError` si indisponible. */
  stat(
    reference: TrackStorageReference,
    context?: StorageRequestContext,
  ): Promise<AudioFileInfo>;

  /**
   * Flux de lecture. `range` est inclusif des deux bornes, comme HTTP.
   * Absent = fichier entier.
   */
  createReadStream(
    reference: TrackStorageReference,
    range?: ByteRange,
    context?: StorageRequestContext,
  ): Promise<Readable>;

  healthCheck(): Promise<StorageHealth>;

  /** Libère les connexions persistantes éventuelles. */
  close?(): void | Promise<void>;
}

export interface StorageRequestContext {
  /** Identifiant public sûr propagé jusqu'au Storage Agent. */
  requestId?: string;
}

// ---------------------------------------------------------------------------
// Normalisation des chemins
// ---------------------------------------------------------------------------

/** Lettre de lecteur Windows : `C:`, `F:\`, `c:/`. */
const WINDOWS_DRIVE = /^[A-Za-z]:/;

/**
 * Convertit un chemin stocké en base en chemin portable.
 *
 * Ne fait AUCUN accès disque et ne modifie AUCUNE donnée : c'est une fonction
 * pure, appelée à chaque construction de référence.
 *
 * Transformations appliquées :
 * - `\` → `/` (les 157 chemins en base sont au format Windows) ;
 * - séparateurs consécutifs réduits à un seul ;
 * - segments `.` supprimés.
 *
 * Rejets (aucune tentative de « réparation » silencieuse) :
 * - chemin vide ou uniquement des séparateurs ;
 * - chemin absolu Unix (`/x`) ou Windows (`C:\x`) ;
 * - chemin UNC (`\\serveur\partage`) ;
 * - tout segment `..`.
 *
 * Le rejet de `..` est fait ICI, avant toute résolution : la vérification de
 * confinement après `resolve()` est une seconde barrière, pas la première.
 */
export function toPortableRelativePath(storedPath: string): string {
  if (typeof storedPath !== 'string') {
    throw new AudioStorageError(
      'INVALID_REFERENCE',
      'Le chemin stocké doit être une chaîne.',
    );
  }

  const unified = storedPath.replace(/\\/g, '/');

  if (unified.trim().length === 0) {
    throw new AudioStorageError(
      'INVALID_REFERENCE',
      'Le chemin stocké est vide.',
    );
  }

  // `//serveur/partage` (UNC converti) et `/absolu` sont refusés ensemble.
  if (unified.startsWith('/')) {
    throw new AudioStorageError(
      'INVALID_REFERENCE',
      'Un chemin absolu ou UNC ne peut pas servir de référence relative.',
    );
  }

  if (WINDOWS_DRIVE.test(unified)) {
    throw new AudioStorageError(
      'INVALID_REFERENCE',
      'Un chemin absolu Windows ne peut pas servir de référence relative.',
    );
  }

  const segments: string[] = [];
  for (const segment of unified.split('/')) {
    // Séparateurs consécutifs → segments vides, simplement ignorés.
    if (segment === '' || segment === '.') continue;
    if (segment === '..') {
      throw new AudioStorageError(
        'PATH_TRAVERSAL',
        'Le chemin contient une remontée de répertoire interdite.',
      );
    }
    segments.push(segment);
  }

  if (segments.length === 0) {
    throw new AudioStorageError(
      'INVALID_REFERENCE',
      'Le chemin stocké ne contient aucun segment exploitable.',
    );
  }

  return segments.join('/');
}

/**
 * Construit une référence à partir d'une ligne de la table `tracks`.
 *
 * Point de passage unique : toute référence du backend naît ici, donc aucune
 * route ne peut contourner la normalisation ni la validation.
 */
export function trackStorageReference(row: {
  id: number;
  path: string;
  hash: string;
  sizeBytes?: number;
}): TrackStorageReference {
  return {
    trackId: row.id,
    relativePath: toPortableRelativePath(row.path),
    contentHash: row.hash,
    ...(row.sizeBytes === undefined
      ? {}
      : { expectedSizeBytes: row.sizeBytes }),
  };
}
