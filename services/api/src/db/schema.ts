import { sql } from 'drizzle-orm';
import {
  check,
  index,
  integer,
  primaryKey,
  real,
  sqliteTable,
  text,
  uniqueIndex,
} from 'drizzle-orm/sqlite-core';

export const appMeta = sqliteTable('app_meta', {
  key: text('key').primaryKey(),
  value: text('value').notNull(),
  updatedAt: text('updated_at').notNull(),
});

export const tracks = sqliteTable('tracks', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  hash: text('hash').notNull().unique(), // SHA-256 du fichier, calculé en flux
  path: text('path').notNull(), // relatif à musicDir
  originalExtension: text('original_extension'), // .wav | .flac
  mimeType: text('mime_type'), // audio/wav | audio/flac (pour le Content-Type de stream)
  sizeBytes: integer('size_bytes').notNull(),
  durationSeconds: real('duration_seconds'),
  title: text('title').notNull(),
  artist: text('artist').notNull(),
  album: text('album').notNull(),
  year: integer('year'),
  genre: text('genre'),
  isrc: text('isrc'),
  coverPath: text('cover_path'), // relatif à coversDir
  createdAt: text('created_at').notNull(),
});

// Comptes utilisateurs — rôles OWNER | ADMIN | USER.
// Le hash de mot de passe (Argon2id) ne doit JAMAIS sortir de la couche auth.
export const users = sqliteTable(
  'users',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    username: text('username').notNull().unique(), // normalisé minuscules
    displayName: text('display_name').notNull(),
    passwordHash: text('password_hash').notNull(),
    role: text('role').notNull(), // OWNER | ADMIN | USER
    isActive: integer('is_active', { mode: 'boolean' }).notNull().default(true),
    mustChangePassword: integer('must_change_password', { mode: 'boolean' }).notNull().default(false),
    createdAt: text('created_at').notNull(),
    updatedAt: text('updated_at').notNull(),
    lastLoginAt: text('last_login_at'),
    disabledAt: text('disabled_at'),
    disabledReason: text('disabled_reason'),
  },
  (table) => [
    // Garantie STRUCTURELLE d'unicité du OWNER : même deux insertions
    // concurrentes ne peuvent pas créer deux propriétaires.
    uniqueIndex('users_single_owner_idx')
      .on(table.role)
      .where(sql`role = 'OWNER'`),
  ],
);

// Sessions à refresh token. Seul le hash SHA-256 du token est stocké :
// un dump de la base ne permet pas de rejouer une session.
export const sessions = sqliteTable(
  'sessions',
  {
    id: text('id').primaryKey(), // UUID v4
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    refreshTokenHash: text('refresh_token_hash').notNull().unique(),
    deviceName: text('device_name'),
    createdAt: text('created_at').notNull(),
    lastUsedAt: text('last_used_at').notNull(),
    expiresAt: text('expires_at').notNull(),
    revokedAt: text('revoked_at'),
  },
  (table) => [index('sessions_user_idx').on(table.userId)],
);

// Journal d'audit des actions sensibles. metadata_json est nettoyé en amont
// (jamais de token, hash ou mot de passe — cf. audit.ts).
export const auditLogs = sqliteTable(
  'audit_logs',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    actorUserId: integer('actor_user_id'), // null : tentative anonyme (login échoué)
    targetUserId: integer('target_user_id'),
    action: text('action').notNull(),
    metadataJson: text('metadata_json'),
    createdAt: text('created_at').notNull(),
  },
  (table) => [index('audit_logs_created_idx').on(table.createdAt)],
);

// Candidats de recommandation : métadonnées descriptives UNIQUEMENT (aucun
// fichier, aucun lien de téléchargement). previewUrl n'est renseignée que si
// elle provient d'une source légale documentée.
export const RECOMMENDATION_SOURCES = ['LIBRARY_SIMILARITY', 'EXTERNAL_CATALOG', 'MANUAL'] as const;
export type RecommendationSource = (typeof RECOMMENDATION_SOURCES)[number];
export const RECOMMENDATION_ITEM_TYPES = ['TRACK', 'ALBUM', 'PLAYLIST'] as const;
export type RecommendationItemType = (typeof RECOMMENDATION_ITEM_TYPES)[number];

// Cycle de vie média d'un candidat (modèle v4 « media-ready »). Un candidat
// n'entre dans user_recommendation_queue QUE s'il atteint MEDIA_READY :
// identité fiable, artwork HTTPS ≥ 500×500, extrait HTTPS validé, zéro
// ambiguïté de version. Voir discovery/media-state.ts.
export const MEDIA_RESOLUTION_STATUSES = [
  'DISCOVERED',
  'IDENTITY_RESOLVING',
  'IDENTITY_RESOLVED',
  'MEDIA_RESOLVING',
  'MEDIA_READY',
  'MEDIA_UNAVAILABLE',
  'RETRYABLE_ERROR',
  'PERMANENTLY_REJECTED',
] as const;
export type MediaResolutionStatus = (typeof MEDIA_RESOLUTION_STATUSES)[number];

export const recommendationCandidates = sqliteTable(
  'recommendation_candidates',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    externalId: text('external_id'), // id du catalogue source (MusicBrainz…)
    itemType: text('item_type').notNull().default('TRACK'),
    title: text('title').notNull(),
    artist: text('artist').notNull(),
    album: text('album'),
    // Identité CANONIQUE résolue par le catalogue (jamais la casse Last.fm
    // brute) : sert le matching, l'affichage et la déduplication.
    canonicalArtist: text('canonical_artist'),
    canonicalTitle: text('canonical_title'),
    // ISRC (identité forte) et id de piste du catalogue primaire.
    isrc: text('isrc'),
    appleMusicSongId: text('apple_music_song_id'),
    artworkUrl: text('artwork_url'),
    artworkWidth: integer('artwork_width'),
    artworkHeight: integer('artwork_height'),
    artworkProvider: text('artwork_provider'), // ITUNES | APPLE_MUSIC | COVER_ART_ARCHIVE
    externalUrl: text('external_url'),
    // Extrait 30 s résolu par un CatalogProvider (iTunes durci | Apple Music) :
    // URL HTTPS uniquement, jamais de token HomeSpotify transmis au tiers.
    previewUrl: text('preview_url'),
    previewProvider: text('preview_provider'), // ITUNES | APPLE_MUSIC | null
    previewMatchedAt: text('preview_matched_at'),
    previewConfidence: real('preview_confidence'), // 0..1 selon la cascade de matching
    previewExpiresAt: text('preview_expires_at'), // re-résolution après expiration
    durationMs: integer('duration_ms'),
    genresJson: text('genres_json'),
    source: text('source').notNull(), // LIBRARY_SIMILARITY | EXTERNAL_CATALOG | MANUAL
    metadataJson: text('metadata_json'),
    // Preuves de similarité (JSON) : liste de relations DIRECTES issues des
    // providers (track-similar, artist-similar) avec seed et force. Un
    // candidat sans preuve exploitable n'est JAMAIS servi (jamais de tag seul).
    evidenceJson: text('evidence_json'),
    // Machine à états média : cf. MEDIA_RESOLUTION_STATUSES. Seul MEDIA_READY
    // est éligible à la file. mediaFailureReason garde la raison stable d'un
    // échec (diagnostics OWNER). mediaResolvedAt : dernier passage média.
    mediaResolutionStatus: text('media_resolution_status').notNull().default('DISCOVERED'),
    mediaFailureReason: text('media_failure_reason'),
    mediaResolvedAt: text('media_resolved_at'),
    isActive: integer('is_active', { mode: 'boolean' }).notNull().default(true),
    createdAt: text('created_at').notNull(),
    updatedAt: text('updated_at').notNull(),
  },
  (table) => [
    // Un même candidat externe n'existe qu'une fois par source.
    uniqueIndex('recommendation_candidates_source_external_idx')
      .on(table.source, table.externalId)
      .where(sql`external_id IS NOT NULL`),
    index('recommendation_candidates_artist_idx').on(table.artist),
    // Sélection rapide des candidats à (re)résoudre / prêts.
    index('recommendation_candidates_media_status_idx').on(table.mediaResolutionStatus),
  ],
);

// Interactions swipe d'un utilisateur avec un candidat. Journal append-only :
// la dernière action LIKE/DISLIKE fait foi pour les exclusions.
export const RECOMMENDATION_ACTIONS = [
  'LIKE',
  'DISLIKE',
  'SKIP',
  'OPEN',
  'REQUEST',
  'PREVIEW_STOPPED_EARLY',
] as const;
export type RecommendationAction = (typeof RECOMMENDATION_ACTIONS)[number];

export const recommendationEvents = sqliteTable(
  'recommendation_events',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    candidateId: integer('candidate_id')
      .notNull()
      .references(() => recommendationCandidates.id, { onDelete: 'cascade' }),
    action: text('action').notNull(), // LIKE | DISLIKE | SKIP | OPEN | REQUEST
    createdAt: text('created_at').notNull(),
  },
  (table) => [
    index('recommendation_events_user_idx').on(table.userId),
    index('recommendation_events_candidate_idx').on(table.candidateId),
  ],
);

// File de recommandations PRÉ-CALCULÉE par utilisateur (moteur hybride V2).
// GET /api/recommendations ne lit QUE cette table : aucun appel externe au
// moment du feed. Regénérée par refreshRecommendationQueueForUser (job async).
export const userRecommendationQueue = sqliteTable(
  'user_recommendation_queue',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    candidateId: integer('candidate_id')
      .notNull()
      .references(() => recommendationCandidates.id, { onDelete: 'cascade' }),
    score: real('score').notNull(),
    rank: integer('rank').notNull(), // ordre de service (1 = première carte)
    reasonCode: text('reason_code').notNull(), // cf. RECOMMENDATION_REASON_CODES
    reasonText: text('reason_text').notNull(), // littéral français affiché sur la carte
    // SAFE | ADJACENT | EXPLORATION — composition cible 60/30/10.
    category: text('category').notNull().default('SAFE'),
    // Renseigné quand la carte a été réellement servie par le GET du feed
    // (l'exclusion ne repose plus dessus : sert au comptage « non vues »).
    servedAt: text('served_at'),
    generatedAt: text('generated_at').notNull(),
    expiresAt: text('expires_at').notNull(),
    modelVersion: text('model_version').notNull(),
  },
  (table) => [
    uniqueIndex('user_recommendation_queue_user_candidate_idx').on(
      table.userId,
      table.candidateId,
    ),
    index('user_recommendation_queue_user_rank_idx').on(table.userId, table.rank),
    // Comptage « prêtes/réserve non servies » du refill continu (servedAt IS NULL).
    index('user_recommendation_queue_served_idx').on(table.userId, table.servedAt),
  ],
);

// Journal des cartes réellement SERVIES (mesure d'exposition, jamais exposé
// aux autres comptes). Alimenté par le GET du feed.
export const recommendationImpressions = sqliteTable(
  'recommendation_impressions',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    candidateId: integer('candidate_id')
      .notNull()
      .references(() => recommendationCandidates.id, { onDelete: 'cascade' }),
    shownAt: text('shown_at').notNull(),
    position: integer('position').notNull(),
    modelVersion: text('model_version').notNull(),
    reasonCode: text('reason_code'),
  },
  (table) => [index('recommendation_impressions_user_idx').on(table.userId, table.shownAt)],
);

// Demandes de musique : l'utilisateur demande, le OWNER traite MANUELLEMENT.
// Aucune recherche n'entraîne jamais de téléchargement automatique.
export const MUSIC_REQUEST_STATUSES = [
  'SENT',
  'REVIEWING',
  'APPROVED',
  'SEARCHING_MANUALLY',
  'IMPORTING',
  'PARTIALLY_COMPLETED',
  'COMPLETED',
  'REJECTED',
  'CANCELLED',
  'FAILED',
] as const;
export type MusicRequestStatus = (typeof MUSIC_REQUEST_STATUSES)[number];

/** Statuts où la demande est encore vivante (bloque un doublon). */
export const ACTIVE_MUSIC_REQUEST_STATUSES = [
  'SENT',
  'REVIEWING',
  'APPROVED',
  'SEARCHING_MANUALLY',
  'IMPORTING',
] as const;

export const musicRequests = sqliteTable(
  'music_requests',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    requestedByUserId: integer('requested_by_user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    candidateId: integer('candidate_id')
      .notNull()
      .references(() => recommendationCandidates.id, { onDelete: 'restrict' }),
    requestType: text('request_type').notNull().default('TRACK'),
    title: text('title'),
    artist: text('artist'),
    album: text('album'),
    externalUrl: text('external_url'),
    externalSource: text('external_source'),
    coverUrl: text('cover_url'),
    status: text('status').notNull(), // cf. MUSIC_REQUEST_STATUSES
    userNote: text('user_note'),
    ownerNote: text('owner_note'),
    reviewedByOwnerId: integer('reviewed_by_owner_id').references(() => users.id, {
      onDelete: 'set null',
    }),
    resultingTrackId: integer('resulting_track_id').references(() => tracks.id, {
      onDelete: 'set null',
    }),
    requestedItemCount: integer('requested_item_count').notNull().default(1),
    completedItemCount: integer('completed_item_count').notNull().default(0),
    unavailableItemCount: integer('unavailable_item_count').notNull().default(0),
    createdAt: text('created_at').notNull(),
    updatedAt: text('updated_at').notNull(),
    completedAt: text('completed_at'),
  },
  (table) => [
    index('music_requests_requester_idx').on(table.requestedByUserId),
    index('music_requests_status_idx').on(table.status),
    // Une seule demande ACTIVE par (utilisateur, candidat).
    uniqueIndex('music_requests_active_unique')
      .on(table.requestedByUserId, table.candidateId)
      .where(
        sql`status IN ('SENT', 'REVIEWING', 'APPROVED', 'SEARCHING_MANUALLY', 'IMPORTING')`,
      ),
  ],
);

export const MUSIC_REQUEST_ITEM_STATUSES = [
  'PENDING',
  'SEARCHING',
  'FOUND',
  'IMPORTING',
  'COMPLETED',
  'UNAVAILABLE',
  'REJECTED',
  'FAILED',
] as const;
export type MusicRequestItemStatus = (typeof MUSIC_REQUEST_ITEM_STATUSES)[number];

/** Snapshot ordonné des pistes demandées pour TRACK, ALBUM ou PLAYLIST. */
export const musicRequestItems = sqliteTable(
  'music_request_items',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    musicRequestId: integer('music_request_id')
      .notNull()
      .references(() => musicRequests.id, { onDelete: 'cascade' }),
    position: integer('position').notNull(),
    title: text('title').notNull(),
    artist: text('artist'),
    album: text('album'),
    durationMs: integer('duration_ms'),
    isrc: text('isrc'),
    resultingTrackId: integer('resulting_track_id').references(() => tracks.id, {
      onDelete: 'set null',
    }),
    status: text('status').notNull().default('PENDING'),
    ownerNote: text('owner_note'),
    createdAt: text('created_at').notNull(),
    updatedAt: text('updated_at').notNull(),
  },
  (table) => [
    uniqueIndex('music_request_items_request_position_unique').on(
      table.musicRequestId,
      table.position,
    ),
    index('music_request_items_request_idx').on(table.musicRequestId),
    index('music_request_items_track_idx').on(table.resultingTrackId),
  ],
);

/** Nom de dossier immuable créé à l'ouverture du compte. */
export const userImportDirectories = sqliteTable(
  'user_import_directories',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    directoryName: text('directory_name').notNull(),
    createdAt: text('created_at').notNull(),
  },
  (table) => [
    uniqueIndex('user_import_directories_user_unique').on(table.userId),
    uniqueIndex('user_import_directories_name_unique').on(table.directoryName),
  ],
);

export const IMPORT_JOB_STATUSES = [
  'DISCOVERED',
  'WAITING_FOR_STABLE_FILE',
  'ANALYZING',
  'WAITING_FOR_OWNER_MATCH',
  'IMPORTED',
  'REUSED',
  'REJECTED',
  'FAILED',
] as const;
export type ImportJobStatus = (typeof IMPORT_JOB_STATUSES)[number];

/** Suivi d'un fichier déposé dans l'inbox propre à un utilisateur. */
export const importJobs = sqliteTable(
  'import_jobs',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    filename: text('filename').notNull(),
    relativePath: text('relative_path').notNull(),
    sizeBytes: integer('size_bytes'),
    status: text('status').notNull().default('DISCOVERED'),
    sha256: text('sha256'),
    metadataJson: text('metadata_json'),
    trackId: integer('track_id').references(() => tracks.id, { onDelete: 'set null' }),
    musicRequestId: integer('music_request_id').references(() => musicRequests.id, {
      onDelete: 'set null',
    }),
    musicRequestItemId: integer('music_request_item_id').references(
      () => musicRequestItems.id,
      { onDelete: 'set null' },
    ),
    matchCandidatesJson: text('match_candidates_json'),
    errorMessage: text('error_message'),
    attempts: integer('attempts').notNull().default(0),
    createdAt: text('created_at').notNull(),
    updatedAt: text('updated_at').notNull(),
    processedAt: text('processed_at'),
  },
  (table) => [
    index('import_jobs_user_created_idx').on(table.userId, table.createdAt),
    index('import_jobs_status_idx').on(table.status),
    uniqueIndex('import_jobs_active_path_unique')
      .on(table.userId, table.relativePath)
      .where(sql`status IN ('DISCOVERED', 'WAITING_FOR_STABLE_FILE', 'ANALYZING')`),
  ],
);

export const ACQUISITION_JOB_STATUSES = [
  'QUEUED',
  'SEARCHING',
  'SELECTING',
  'OPENING_RESULT',
  'VERIFYING',
  'DOWNLOADING',
  'RETRYING',
  'PAUSED_PROVIDER',
  'MANUAL_VERIFICATION_REQUIRED',
  'WAITING_MANUAL_DOWNLOAD',
  'DOWNLOADED',
  'IMPORTING',
  'COMPLETED',
  'FAILED',
  'CANCELLED',
  'INTERRUPTED',
] as const;
export type AcquisitionJobStatus = (typeof ACQUISITION_JOB_STATUSES)[number];

export const ACQUISITION_PROVIDERS = ['QOBUZ'] as const;
export type AcquisitionProvider = (typeof ACQUISITION_PROVIDERS)[number];

/**
 * Suit l'acquisition distante AVANT que le vrai fichier soit pris en charge
 * par UserImportService. Cette table ne remplace jamais `import_jobs`.
 */
export const acquisitionJobs = sqliteTable(
  'acquisition_jobs',
  {
    id: text('id').primaryKey(), // UUID généré côté service
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    provider: text('provider').notNull().default('QOBUZ'),
    query: text('query').notNull(),
    /** Clé normalisée stable utilisée uniquement pour bloquer les doublons actifs. */
    dedupeKey: text('dedupe_key').notNull(),
    resultIndex: integer('result_index'),
    status: text('status').notNull().default('QUEUED'),
    stage: text('stage'),
    progress: integer('progress').notNull().default(0),
    message: text('message'),
    selectedTitle: text('selected_title'),
    selectedArtist: text('selected_artist'),
    selectedAlbum: text('selected_album'),
    selectedDurationSeconds: integer('selected_duration_seconds'),
    attempt: integer('attempt').notNull().default(0),
    maxAttempts: integer('max_attempts').notNull().default(3),
    /** Chemin relatif à l'inbox utilisateur, jamais un chemin absolu exposé. */
    downloadedRelativePath: text('downloaded_relative_path'),
    localImportJobId: integer('local_import_job_id').references(() => importJobs.id, {
      onDelete: 'set null',
    }),
    trackId: integer('track_id').references(() => tracks.id, { onDelete: 'set null' }),
    errorCode: text('error_code'),
    errorMessage: text('error_message'),
    providerUsed: text('provider_used').notNull().default('LUCIDA'),
    fallbackFrom: text('fallback_from'),
    fallbackReasonCode: text('fallback_reason_code'),
    cancelRequested: integer('cancel_requested', { mode: 'boolean' })
      .notNull()
      .default(false),
    createdAt: text('created_at').notNull(),
    updatedAt: text('updated_at').notNull(),
    startedAt: text('started_at'),
    completedAt: text('completed_at'),
  },
  (table) => [
    index('acquisition_jobs_user_created_idx').on(table.userId, table.createdAt),
    index('acquisition_jobs_status_idx').on(table.status),
    index('acquisition_jobs_local_import_idx').on(table.localImportJobId),
    uniqueIndex('acquisition_jobs_active_dedupe_unique')
      .on(table.userId, table.dedupeKey)
      .where(
        sql`status IN (
          'QUEUED',
          'SEARCHING',
          'SELECTING',
          'OPENING_RESULT',
          'VERIFYING',
          'DOWNLOADING',
          'RETRYING',
          'PAUSED_PROVIDER',
          'MANUAL_VERIFICATION_REQUIRED',
          'WAITING_MANUAL_DOWNLOAD',
          'DOWNLOADED',
          'IMPORTING'
        )`,
      ),
    check(
      'acquisition_jobs_provider_check',
      sql`${table.provider} IN ('QOBUZ')`,
    ),
    check(
      'acquisition_jobs_status_check',
      sql`${table.status} IN (
        'QUEUED',
        'SEARCHING',
        'SELECTING',
        'OPENING_RESULT',
        'VERIFYING',
        'DOWNLOADING',
        'RETRYING',
        'PAUSED_PROVIDER',
        'MANUAL_VERIFICATION_REQUIRED',
        'WAITING_MANUAL_DOWNLOAD',
        'DOWNLOADED',
        'IMPORTING',
        'COMPLETED',
        'FAILED',
        'CANCELLED',
        'INTERRUPTED'
      )`,
    ),
    check(
      'acquisition_jobs_progress_check',
      sql`${table.progress} >= 0 AND ${table.progress} <= 100`,
    ),
    check(
      'acquisition_jobs_result_index_check',
      sql`${table.resultIndex} IS NULL OR ${table.resultIndex} >= 0`,
    ),
    check(
      'acquisition_jobs_duration_check',
      sql`${table.selectedDurationSeconds} IS NULL OR ${table.selectedDurationSeconds} >= 0`,
    ),
    check(
      'acquisition_jobs_attempt_check',
      sql`${table.attempt} >= 0`,
    ),
    check(
      'acquisition_jobs_max_attempts_check',
      sql`${table.maxAttempts} >= 1 AND ${table.maxAttempts} <= 10`,
    ),
  ],
);

/**
 * États d'un téléchargement Antra. `interrupted` est réservé aux jobs laissés
 * actifs par un processus serveur disparu : c'est le seul état terminal
 * relançable avec `failed`.
 */
export const DOWNLOAD_JOB_STATUSES = [
  'queued',
  'resolving',
  'downloading',
  'processing',
  'importing',
  'completed',
  'failed',
  'cancelled',
  'interrupted',
] as const;
export type DownloadJobStatus = (typeof DOWNLOAD_JOB_STATUSES)[number];

export const DOWNLOAD_PROVIDERS = ['antra'] as const;
export type DownloadProviderName = (typeof DOWNLOAD_PROVIDERS)[number];

/**
 * Téléchargements par URL pilotés par le moteur Antra.
 *
 * Même règle que `acquisition_jobs` : cette table suit le processus Python,
 * puis pointe vers le vrai `import_jobs` créé par UserImportService. Elle ne
 * duplique jamais l'indexation de la bibliothèque.
 */
export const downloadJobs = sqliteTable(
  'download_jobs',
  {
    id: text('id').primaryKey(), // UUID généré côté service
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    provider: text('provider').notNull().default('antra'),
    /** URL telle que soumise, déjà validée contre l'allowlist. */
    requestedUrl: text('requested_url').notNull(),
    /** Forme canonique servant aussi de clé anti-doublon actif. */
    normalizedUrl: text('normalized_url').notNull(),
    /** `url` = lien collé ; `search` = recherche texte résolue en candidats. */
    requestKind: text('request_kind').notNull().default('url'),
    /** Texte saisi par l'utilisateur ; NULL pour une URL directe. */
    query: text('query'),
    /** Candidats retenus (JSON assaini : ni credential, ni token, ni chemin). */
    candidatesJson: text('candidates_json'),
    /** Historique ordonné des tentatives et de leur code d'échec. */
    attemptsJson: text('attempts_json'),
    /** Catalogue d'origine de l'URL finalement utilisée. */
    selectedProvider: text('selected_provider'),
    /** URL du candidat finalement utilisé (normalisée, jamais un secret). */
    selectedUrl: text('selected_url'),
    status: text('status').notNull().default('queued'),
    /** Étape technique libre (`resolving`, `downloading`, `local_import`, …). */
    stage: text('stage'),
    progress: integer('progress').notNull().default(0),
    message: text('message'),
    title: text('title'),
    artist: text('artist'),
    album: text('album'),
    /** Source réellement retenue par Antra (`qobuz`, `tidal`, …). */
    source: text('source'),
    /** Libellé de qualité rapporté par Antra (`FLAC 24-bit/96kHz`, …). */
    quality: text('quality'),
    /** Chemin relatif à la racine d'import — jamais un chemin absolu exposé. */
    outputPath: text('output_path'),
    localImportJobId: integer('local_import_job_id').references(() => importJobs.id, {
      onDelete: 'set null',
    }),
    trackId: integer('track_id').references(() => tracks.id, { onDelete: 'set null' }),
    errorCode: text('error_code'),
    errorMessage: text('error_message'),
    /** PID du processus Python en cours ; remis à NULL dès la fin. */
    processId: integer('process_id'),
    attempt: integer('attempt').notNull().default(0),
    maxAttempts: integer('max_attempts').notNull().default(3),
    cancelRequested: integer('cancel_requested', { mode: 'boolean' })
      .notNull()
      .default(false),
    createdAt: text('created_at').notNull(),
    updatedAt: text('updated_at').notNull(),
    startedAt: text('started_at'),
    completedAt: text('completed_at'),
  },
  (table) => [
    index('download_jobs_user_created_idx').on(table.userId, table.createdAt),
    index('download_jobs_status_idx').on(table.status),
    index('download_jobs_local_import_idx').on(table.localImportJobId),
    // Deux téléchargements actifs de la même URL par le même compte n'ont
    // aucun sens : la contrainte est STRUCTURELLE, pas seulement applicative.
    uniqueIndex('download_jobs_active_url_unique')
      .on(table.userId, table.normalizedUrl)
      .where(
        sql`status IN (
          'queued',
          'resolving',
          'downloading',
          'processing',
          'importing'
        )`,
      ),
    check('download_jobs_provider_check', sql`${table.provider} IN ('antra')`),
    check(
      'download_jobs_status_check',
      sql`${table.status} IN (
        'queued',
        'resolving',
        'downloading',
        'processing',
        'importing',
        'completed',
        'failed',
        'cancelled',
        'interrupted'
      )`,
    ),
    check(
      'download_jobs_progress_check',
      sql`${table.progress} >= 0 AND ${table.progress} <= 100`,
    ),
    check('download_jobs_attempt_check', sql`${table.attempt} >= 0`),
    check(
      'download_jobs_max_attempts_check',
      sql`${table.maxAttempts} >= 1 AND ${table.maxAttempts} <= 10`,
    ),
    check(
      'download_jobs_process_id_check',
      sql`${table.processId} IS NULL OR ${table.processId} > 0`,
    ),
    check(
      'download_jobs_request_kind_check',
      sql`${table.requestKind} IN ('url', 'search')`,
    ),
  ],
);

export const MONOCHROME_MANUAL_SESSION_STATUSES = [
  'WAITING',
  'RESERVED',
  'RESULT_RECEIVED',
] as const;
export type MonochromeManualSessionStatus =
  (typeof MONOCHROME_MANUAL_SESSION_STATUSES)[number];

/**
 * Holder global du helper visible. Une seule ligne non terminale peut exister ;
 * le helper ne modifie jamais SQLite et passe exclusivement par les routes.
 */
export const monochromeManualSessions = sqliteTable(
  'monochrome_manual_sessions',
  {
    jobId: text('job_id')
      .primaryKey()
      .references(() => acquisitionJobs.id, { onDelete: 'cascade' }),
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    status: text('status').notNull().default('WAITING'),
    reservedAt: text('reserved_at'),
    startedAt: text('started_at'),
    resultReceivedAt: text('result_received_at'),
    createdAt: text('created_at').notNull(),
    updatedAt: text('updated_at').notNull(),
  },
  (table) => [
    uniqueIndex('monochrome_manual_single_active_unique')
      .on(sql`1`)
      .where(sql`status IN ('WAITING','RESERVED')`),
    index('monochrome_manual_user_idx').on(table.userId),
    check(
      'monochrome_manual_status_check',
      sql`${table.status} IN ('WAITING','RESERVED','RESULT_RECEIVED')`,
    ),
  ],
);

export const PROVIDER_HEALTH_STATES = [
  'CLOSED',
  'OPEN',
  'HALF_OPEN',
  'MANUAL_VERIFICATION_REQUIRED',
] as const;
export type ProviderHealthState = (typeof PROVIDER_HEALTH_STATES)[number];

/**
 * État global et persistant d'un fournisseur d'acquisition. Aucun diagnostic
 * brut, secret, URL ou chemin local n'est stocké dans cette table.
 */
export const providerHealth = sqliteTable(
  'provider_health',
  {
    provider: text('provider').primaryKey(),
    state: text('state').notNull().default('CLOSED'),
    reasonCode: text('reason_code'),
    publicMessage: text('public_message'),
    failureCount: integer('failure_count').notNull().default(0),
    openedAt: text('opened_at'),
    retryAt: text('retry_at'),
    lastFailureAt: text('last_failure_at'),
    lastSuccessAt: text('last_success_at'),
    halfOpenProbeJobId: text('half_open_probe_job_id'),
    manualVerificationJobId: text('manual_verification_job_id'),
    manualVerificationHolderJobId: text('manual_verification_holder_job_id'),
    createdAt: text('created_at').notNull(),
    updatedAt: text('updated_at').notNull(),
  },
  (table) => [
    index('provider_health_state_retry_idx').on(table.state, table.retryAt),
    check(
      'provider_health_state_check',
      sql`${table.state} IN (
        'CLOSED',
        'OPEN',
        'HALF_OPEN',
        'MANUAL_VERIFICATION_REQUIRED'
      )`,
    ),
    check(
      'provider_health_failure_count_check',
      sql`${table.failureCount} >= 0`,
    ),
    check(
      'provider_health_half_open_probe_check',
      sql`${table.state} IN (
        'HALF_OPEN'
      ) OR ${table.halfOpenProbeJobId} IS NULL`,
    ),
    check(
      'provider_health_manual_verification_job_required_check',
      sql`(
          ${table.state} = 'MANUAL_VERIFICATION_REQUIRED'
          AND ${table.manualVerificationJobId} IS NOT NULL
        ) OR (
          ${table.manualVerificationJobId} IS NULL
          AND ${table.manualVerificationHolderJobId} IS NULL
        )`,
    ),
  ],
);

// Pistes/candidats masqués par utilisateur : suppression douce (REMOVED) ou
// rejet de swipe (DISLIKED). Bloque les futures recommandations. Exactement
// une des deux cibles (trackId XOR candidateId) est renseignée.
export const HIDDEN_TRACK_REASONS = ['REMOVED', 'DISLIKED'] as const;
export type HiddenTrackReason = (typeof HIDDEN_TRACK_REASONS)[number];

export const userHiddenTracks = sqliteTable(
  'user_hidden_tracks',
  {
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    trackId: integer('track_id').references(() => tracks.id, { onDelete: 'cascade' }),
    candidateId: integer('candidate_id').references(() => recommendationCandidates.id, {
      onDelete: 'cascade',
    }),
    reason: text('reason').notNull(), // REMOVED | DISLIKED
    createdAt: text('created_at').notNull(),
  },
  (table) => [
    // Index uniques PARTIELS : un masquage par (user, piste) et par
    // (user, candidat) — les deux colonnes étant nullables, une PK composite
    // ne suffirait pas.
    uniqueIndex('user_hidden_tracks_track_unique')
      .on(table.userId, table.trackId)
      .where(sql`track_id IS NOT NULL`),
    uniqueIndex('user_hidden_tracks_candidate_unique')
      .on(table.userId, table.candidateId)
      .where(sql`candidate_id IS NOT NULL`),
    index('user_hidden_tracks_user_idx').on(table.userId),
  ],
);

// Événements d'écoute minimalistes (signal optionnel pour la reco V1+).
export const playEvents = sqliteTable(
  'play_events',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    trackId: integer('track_id')
      .notNull()
      .references(() => tracks.id, { onDelete: 'cascade' }),
    startedAt: text('started_at').notNull(),
    listenedMs: integer('listened_ms').notNull().default(0),
    completed: integer('completed', { mode: 'boolean' }).notNull().default(false),
  },
  (table) => [index('play_events_user_idx').on(table.userId, table.trackId)],
);

export const LISTENING_EVENT_TYPES = [
  'PLAY_STARTED',
  'PLAY_RESUMED',
  'PLAY_PROGRESS',
  'PLAY_PAUSED',
  'PLAY_SEEKED',
  'PLAY_COMPLETED',
  'PLAY_SKIPPED',
  'PLAY_STOPPED',
  'PLAY_ERROR',
  'TRACK_CHANGED',
] as const;
export type ListeningEventType = (typeof LISTENING_EVENT_TYPES)[number];

export const LISTENING_SESSION_STATUSES = ['ACTIVE', 'PAUSED', 'ENDED'] as const;
export type ListeningSessionStatus = (typeof LISTENING_SESSION_STATUSES)[number];

/**
 * Agrégat fiable d'une lecture. `listened_ms` est cumulatif et monotone : les
 * retries et événements désordonnés ne peuvent donc jamais doubler une écoute.
 */
export const listeningSessions = sqliteTable(
  'listening_sessions',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    trackId: integer('track_id')
      .notNull()
      .references(() => tracks.id, { onDelete: 'cascade' }),
    clientSessionId: text('client_session_id').notNull(),
    installationId: text('installation_id').notNull(),
    startedAt: text('started_at').notNull(),
    lastActivityAt: text('last_activity_at').notNull(),
    latestClientEventAt: text('latest_client_event_at').notNull(),
    endedAt: text('ended_at'),
    initialPositionMs: integer('initial_position_ms').notNull().default(0),
    lastPositionMs: integer('last_position_ms').notNull().default(0),
    durationMs: integer('duration_ms'),
    listenedMs: integer('listened_ms').notNull().default(0),
    playbackSpeed: real('playback_speed').notNull().default(1),
    status: text('status').notNull().default('ACTIVE'),
    endReason: text('end_reason'),
    pauseCount: integer('pause_count').notNull().default(0),
    seekCount: integer('seek_count').notNull().default(0),
    qualifiedPlay: integer('qualified_play', { mode: 'boolean' }).notNull().default(false),
    completed: integer('completed', { mode: 'boolean' }).notNull().default(false),
    createdAt: text('created_at').notNull(),
    updatedAt: text('updated_at').notNull(),
  },
  (table) => [
    uniqueIndex('listening_sessions_user_client_unique').on(
      table.userId,
      table.clientSessionId,
    ),
    index('listening_sessions_user_started_idx').on(table.userId, table.startedAt),
    index('listening_sessions_user_track_idx').on(table.userId, table.trackId),
    check('listening_sessions_listened_nonnegative', sql`${table.listenedMs} >= 0`),
    check('listening_sessions_position_nonnegative', sql`${table.lastPositionMs} >= 0`),
    check(
      'listening_sessions_speed_range',
      sql`${table.playbackSpeed} >= 0.7 AND ${table.playbackSpeed} <= 1.3`,
    ),
  ],
);

/** Journal détaillé, borné et dédupliqué par identifiant client. */
export const listeningEvents = sqliteTable(
  'listening_events',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    sessionId: integer('session_id')
      .notNull()
      .references(() => listeningSessions.id, { onDelete: 'cascade' }),
    clientEventId: text('client_event_id').notNull(),
    eventType: text('event_type').notNull(),
    positionMs: integer('position_ms').notNull(),
    listenedMs: integer('listened_ms').notNull(),
    durationMs: integer('duration_ms'),
    playbackSpeed: real('playback_speed').notNull(),
    clientCreatedAt: text('client_created_at').notNull(),
    serverReceivedAt: text('server_received_at').notNull(),
    metadataJson: text('metadata_json'),
  },
  (table) => [
    uniqueIndex('listening_events_user_client_unique').on(table.userId, table.clientEventId),
    index('listening_events_session_idx').on(table.sessionId),
    index('listening_events_user_received_idx').on(table.userId, table.serverReceivedAt),
    check('listening_events_listened_nonnegative', sql`${table.listenedMs} >= 0`),
    check('listening_events_position_nonnegative', sql`${table.positionMs} >= 0`),
  ],
);

// Accès d'un utilisateur à une piste physique. Le fichier existe UNE fois
// (table tracks) ; user_tracks est la relation logique qui rend la
// bibliothèque distincte par compte. Un retrait conserve la relation avec
// is_visible=false afin de ne pas être annulé par le backfill du démarrage ; il
// ne touche jamais le fichier — cf. MULTI_USER_DATA_MODEL.md.
export const USER_TRACK_SOURCES = ['EXISTING', 'MANUAL_IMPORT', 'ADMIN'] as const;
export type UserTrackSource = (typeof USER_TRACK_SOURCES)[number];

export const userTracks = sqliteTable(
  'user_tracks',
  {
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    trackId: integer('track_id')
      .notNull()
      .references(() => tracks.id, { onDelete: 'cascade' }),
    addedAt: text('added_at').notNull(),
    // Qui a attribué l'accès (OWNER lors d'une attribution admin, null pour le backfill).
    addedByUserId: integer('added_by_user_id').references(() => users.id, {
      onDelete: 'set null',
    }),
    source: text('source').notNull(), // EXISTING | MANUAL_IMPORT | ADMIN
    isVisible: integer('is_visible', { mode: 'boolean' }).notNull().default(true),
  },
  (table) => [
    // unique(userId, trackId) : un utilisateur n'a qu'un accès par piste.
    primaryKey({ columns: [table.userId, table.trackId] }),
    // Recherche inverse « qui a accès à cette piste » (tailles partagées).
    index('user_tracks_track_idx').on(table.trackId),
  ],
);

// Réglage de vitesse propre à un utilisateur et une piste. Il ne modifie
// jamais le fichier audio ; preserve_pitch reste structurellement vrai.
export const userTrackPlaybackSettings = sqliteTable(
  'user_track_playback_settings',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    trackId: integer('track_id')
      .notNull()
      .references(() => tracks.id, { onDelete: 'cascade' }),
    speedRatio: real('speed_ratio').notNull().default(1),
    preservePitch: integer('preserve_pitch', { mode: 'boolean' }).notNull().default(true),
    createdAt: text('created_at').notNull(),
    updatedAt: text('updated_at').notNull(),
  },
  (table) => [
    uniqueIndex('user_track_playback_settings_user_track_unique').on(
      table.userId,
      table.trackId,
    ),
    check(
      'user_track_playback_settings_speed_check',
      sql`${table.speedRatio} >= 0.70 AND ${table.speedRatio} <= 1.30`,
    ),
    check(
      'user_track_playback_settings_pitch_check',
      sql`${table.preservePitch} = 1`,
    ),
  ],
);

// Analyse descriptive partagée par tous les comptes. Seul le signal décodé
// en flux est lu ; aucun fichier intermédiaire ou audio modifié n'est produit.
export const trackAudioAnalysis = sqliteTable(
  'track_audio_analysis',
  {
    trackId: integer('track_id')
      .primaryKey()
      .references(() => tracks.id, { onDelete: 'cascade' }),
    rawBpm: real('raw_bpm'),
    bpm: real('bpm'),
    bpmConfidence: real('bpm_confidence'),
    bpmSource: text('bpm_source'), // METADATA | FFMPEG_TEMPO
    status: text('status').notNull().default('PENDING'), // PENDING | ANALYZING | READY | LOW_CONFIDENCE | FAILED
    errorMessage: text('error_message'),
    analyzedAt: text('analyzed_at'),
    updatedAt: text('updated_at').notNull(),
  },
  (table) => [
    check(
      'track_audio_analysis_bpm_check',
      sql`${table.bpm} IS NULL OR (${table.bpm} >= 40 AND ${table.bpm} <= 240)`,
    ),
    check(
      'track_audio_analysis_confidence_check',
      sql`${table.bpmConfidence} IS NULL OR (${table.bpmConfidence} >= 0 AND ${table.bpmConfidence} <= 1)`,
    ),
  ],
);

// Mesure de sonie EBU R128 partagée par tous les comptes. L'analyse décode le
// fichier en flux, ne crée aucun intermédiaire et ne modifie jamais l'original.
export const trackLoudnessAnalysis = sqliteTable(
  'track_loudness_analysis',
  {
    trackId: integer('track_id')
      .primaryKey()
      .references(() => tracks.id, { onDelete: 'cascade' }),
    status: text('status').notNull().default('PENDING'), // PENDING | ANALYZING | READY | FAILED
    integratedLufs: real('integrated_lufs'),
    truePeakDbfs: real('true_peak_dbfs'),
    replayGainDb: real('replay_gain_db'),
    targetLufs: real('target_lufs').notNull().default(-18),
    peakCeilingDbfs: real('peak_ceiling_dbfs').notNull().default(-1),
    errorMessage: text('error_message'),
    analyzedAt: text('analyzed_at'),
    updatedAt: text('updated_at').notNull(),
  },
  (table) => [
    check(
      'track_loudness_analysis_lufs_check',
      sql`${table.integratedLufs} IS NULL OR (${table.integratedLufs} >= -70 AND ${table.integratedLufs} <= 5)`,
    ),
    check(
      'track_loudness_analysis_peak_check',
      sql`${table.truePeakDbfs} IS NULL OR (${table.truePeakDbfs} >= -120 AND ${table.truePeakDbfs} <= 20)`,
    ),
    check(
      'track_loudness_analysis_gain_check',
      sql`${table.replayGainDb} IS NULL OR (${table.replayGainDb} >= -24 AND ${table.replayGainDb} <= 12)`,
    ),
  ],
);

// Favoris par utilisateur (remplace le favorites.json local du mobile).
export const favorites = sqliteTable(
  'favorites',
  {
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    trackId: integer('track_id')
      .notNull()
      .references(() => tracks.id, { onDelete: 'cascade' }),
    createdAt: text('created_at').notNull(),
  },
  (table) => [primaryKey({ columns: [table.userId, table.trackId] })],
);

// Playlists : chaque playlist appartient à un utilisateur.
export const playlists = sqliteTable(
  'playlists',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    userId: integer('user_id')
      .notNull()
      .references(() => users.id, { onDelete: 'cascade' }),
    name: text('name').notNull(),
    createdAt: text('created_at').notNull(),
    updatedAt: text('updated_at').notNull(),
  },
  (table) => [index('playlists_user_idx').on(table.userId)],
);

// Contenu ordonné d'une playlist. Une piste au plus une fois par playlist.
export const playlistTracks = sqliteTable(
  'playlist_tracks',
  {
    playlistId: integer('playlist_id')
      .notNull()
      .references(() => playlists.id, { onDelete: 'cascade' }),
    trackId: integer('track_id')
      .notNull()
      .references(() => tracks.id, { onDelete: 'cascade' }),
    position: integer('position').notNull(),
    addedAt: text('added_at').notNull(),
  },
  (table) => [
    primaryKey({ columns: [table.playlistId, table.trackId] }),
    index('playlist_tracks_playlist_idx').on(table.playlistId),
  ],
);

// Cache NORMALISÉ des réponses de découverte catalogue (jamais les réponses
// brutes complètes des fournisseurs, jamais de secret/token, jamais d'audio).
// TTL différenciés par opération — cf. discovery/catalog/discovery-cache.ts.
export const discoveryCache = sqliteTable(
  'discovery_cache',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    provider: text('provider').notNull(),
    operation: text('operation').notNull(), // search | artist | artist_albums | album | playlist | isrc
    queryHash: text('query_hash').notNull(), // SHA-256 des paramètres normalisés
    entityType: text('entity_type'),
    market: text('market').notNull().default(''),
    locale: text('locale'),
    normalizedJson: text('normalized_json').notNull(),
    fetchedAt: text('fetched_at').notNull(),
    expiresAt: text('expires_at').notNull(),
    schemaVersion: integer('schema_version').notNull().default(1),
    statusCode: integer('status_code'),
    negativeResult: integer('negative_result', { mode: 'boolean' }).notNull().default(false),
  },
  (table) => [
    uniqueIndex('discovery_cache_key_unique').on(
      table.provider,
      table.operation,
      table.queryHash,
      table.market,
    ),
    index('discovery_cache_expires_idx').on(table.expiresAt),
  ],
);

// Qualité MESURÉE (music-metadata), jamais déduite de l'extension — cf. AUDIO_SOURCING.md
export const trackQuality = sqliteTable('track_quality', {
  trackId: integer('track_id')
    .primaryKey()
    .references(() => tracks.id, { onDelete: 'cascade' }),
  container: text('container').notNull(),
  codec: text('codec').notNull(),
  sampleRate: integer('sample_rate').notNull(),
  bitDepth: integer('bit_depth').notNull(),
  channels: integer('channels').notNull(),
  status: text('status').notNull(), // lossless_verifie | lossless_probable | lossy | inconnue
  provenance: text('provenance').notNull(), // rip_cd | achat | libre | upscale_ia | inconnue
  analyzedAt: text('analyzed_at').notNull(),
});

// Enrichissement descriptif externe (MusicBrainz/Cover Art), séparé de la vérité audio mesurée.
export const trackEnrichment = sqliteTable('track_enrichment', {
  trackId: integer('track_id')
    .primaryKey()
    .references(() => tracks.id, { onDelete: 'cascade' }),
  status: text('status').notNull(), // pending | matched | ambiguous | not_found | failed
  musicbrainzRecordingId: text('musicbrainz_recording_id'),
  musicbrainzReleaseId: text('musicbrainz_release_id'),
  musicbrainzReleaseGroupId: text('musicbrainz_release_group_id'),
  musicbrainzArtistId: text('musicbrainz_artist_id'),
  canonicalTitle: text('canonical_title'),
  canonicalArtist: text('canonical_artist'),
  canonicalAlbum: text('canonical_album'),
  albumArtist: text('album_artist'),
  releaseDate: text('release_date'),
  trackNumber: integer('track_number'),
  discNumber: integer('disc_number'),
  genre: text('genre'),
  matchScore: real('match_score'),
  candidatesJson: text('candidates_json'),
  errorMessage: text('error_message'),
  checkedAt: text('checked_at').notNull(),
  enrichedAt: text('enriched_at'),
}, (table) => [
  index('track_enrichment_status_idx').on(table.status),
  index('track_enrichment_recording_idx').on(table.musicbrainzRecordingId),
]);

// --- Variantes hors ligne (Phase 1A) ---------------------------------------
// Dérivées Ogg/Opus produites côté serveur. Le fichier canonique WAV/FLAC
// n'est JAMAIS modifié : une variante est identifiée par
// (source_sha256, profile_version, encoder_version) — single-flight distinct
// pour 128 et 256. `path` est relatif au cache de dérivées, jamais absolu.
export const OFFLINE_VARIANT_STATUSES = ['PENDING', 'ENCODING', 'READY', 'FAILED', 'STALE'] as const;
export type OfflineVariantStatus = (typeof OFFLINE_VARIANT_STATUSES)[number];

export const trackOfflineVariants = sqliteTable(
  'track_offline_variants',
  {
    id: integer('id').primaryKey({ autoIncrement: true }),
    trackId: integer('track_id')
      .notNull()
      .references(() => tracks.id, { onDelete: 'cascade' }),
    sourceSha256: text('source_sha256').notNull(), // hash de la source au moment de la demande
    profile: text('profile').notNull(), // opus_128 | opus_256
    profileVersion: text('profile_version').notNull(), // opus-128-v1 | opus-256-v1
    encoderVersion: text('encoder_version').notNull(),
    status: text('status').notNull().default('PENDING'),
    targetBitrateKbps: integer('target_bitrate_kbps').notNull(),
    measuredBitrateKbps: integer('measured_bitrate_kbps'), // ffprobe, jamais l'argument demandé
    durationSeconds: real('duration_seconds'),
    sizeBytes: integer('size_bytes'),
    sha256: text('sha256'), // hash de la dérivée publiée
    path: text('path'), // relatif au cache de dérivées
    errorMessage: text('error_message'),
    attempts: integer('attempts').notNull().default(0),
    createdAt: text('created_at').notNull(),
    updatedAt: text('updated_at').notNull(),
    readyAt: text('ready_at'),
  },
  (table) => [
    uniqueIndex('track_offline_variants_identity_unique').on(
      table.sourceSha256,
      table.profileVersion,
      table.encoderVersion,
    ),
    index('track_offline_variants_track_idx').on(table.trackId),
    index('track_offline_variants_status_idx').on(table.status),
  ],
);
