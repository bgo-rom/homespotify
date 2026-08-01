import { randomUUID } from 'node:crypto';
import { and, desc, eq, inArray } from 'drizzle-orm';
import type { DbHandle } from '../db/client.js';
import {
  acquisitionJobs,
  type AcquisitionJobStatus,
  type AcquisitionProvider,
} from '../db/schema.js';

export const ACTIVE_ACQUISITION_JOB_STATUSES = [
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
] as const satisfies readonly AcquisitionJobStatus[];

const INTERRUPTIBLE_ACQUISITION_JOB_STATUSES = [
  'QUEUED',
  'SEARCHING',
  'SELECTING',
  'OPENING_RESULT',
  'VERIFYING',
  'DOWNLOADING',
  'RETRYING',
  'DOWNLOADED',
  'IMPORTING',
] as const satisfies readonly AcquisitionJobStatus[];

export const TERMINAL_ACQUISITION_JOB_STATUSES = [
  'COMPLETED',
  'FAILED',
  'CANCELLED',
  'INTERRUPTED',
] as const satisfies readonly AcquisitionJobStatus[];

export type AcquisitionJobRow = typeof acquisitionJobs.$inferSelect;

export type AcquisitionJobRepositoryErrorCode =
  | 'invalid_input'
  | 'job_not_found'
  | 'active_duplicate';

export class AcquisitionJobRepositoryError extends Error {
  constructor(
    readonly code: AcquisitionJobRepositoryErrorCode,
    message: string,
  ) {
    super(message);
    this.name = 'AcquisitionJobRepositoryError';
  }
}

export interface CreateAcquisitionJobInput {
  userId: number;
  query: string;
  provider?: AcquisitionProvider;
  resultIndex?: number | null;
  maxAttempts?: number;
  selectedTitle?: string | null;
  selectedArtist?: string | null;
  selectedAlbum?: string | null;
  selectedDurationSeconds?: number | null;
}

export interface UpdateAcquisitionJobInput {
  status?: AcquisitionJobStatus;
  stage?: string | null;
  progress?: number;
  message?: string | null;
  selectedTitle?: string | null;
  selectedArtist?: string | null;
  selectedAlbum?: string | null;
  selectedDurationSeconds?: number | null;
  attempt?: number;
  downloadedRelativePath?: string | null;
  localImportJobId?: number | null;
  trackId?: number | null;
  errorCode?: string | null;
  errorMessage?: string | null;
  providerUsed?: 'LUCIDA' | 'MONOCHROME_MANUAL';
  fallbackFrom?: string | null;
  fallbackReasonCode?: string | null;
}

const MAX_QUERY_LENGTH = 200;
const MAX_TEXT_LENGTH = 500;
const MAX_RELATIVE_PATH_LENGTH = 1000;
const MAX_RESULT_INDEX = 100;
const MAX_ATTEMPTS = 10;
const DEFAULT_LIST_LIMIT = 20;
const MAX_LIST_LIMIT = 100;

function isPositiveInteger(value: number): boolean {
  return Number.isInteger(value) && value > 0;
}

function normalizeWhitespace(value: string): string {
  return value.trim().replace(/\s+/g, ' ');
}

function normalizeForDedupe(value: string): string {
  return normalizeWhitespace(value)
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLocaleLowerCase('fr-FR')
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim()
    .replace(/\s+/g, ' ');
}

function validateOptionalText(
  field: string,
  value: string | null | undefined,
  maxLength = MAX_TEXT_LENGTH,
): void {
  if (value === undefined || value === null) return;
  if (value.length > maxLength) {
    throw new AcquisitionJobRepositoryError(
      'invalid_input',
      `${field} dépasse ${maxLength} caractères.`,
    );
  }
}

function isUniqueConstraintError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  const code = (error as Error & { code?: string }).code ?? '';
  return (
    code === 'SQLITE_CONSTRAINT_UNIQUE' ||
    /UNIQUE constraint failed:\s*acquisition_jobs\.user_id,\s*acquisition_jobs\.dedupe_key/i.test(
      error.message,
    )
  );
}

function isTerminalStatus(status: AcquisitionJobStatus): boolean {
  return (TERMINAL_ACQUISITION_JOB_STATUSES as readonly string[]).includes(status);
}

function isActiveStatus(status: string): boolean {
  return (ACTIVE_ACQUISITION_JOB_STATUSES as readonly string[]).includes(status);
}

export function buildAcquisitionDedupeKey(input: {
  provider: AcquisitionProvider;
  query: string;
  resultIndex: number | null;
}): string {
  const normalizedQuery = normalizeForDedupe(input.query);
  if (!normalizedQuery) {
    throw new AcquisitionJobRepositoryError(
      'invalid_input',
      'La requête ne contient aucun caractère exploitable.',
    );
  }

  const resultPart = input.resultIndex === null ? 'AUTO' : String(input.resultIndex);
  return `${input.provider}:${resultPart}:${normalizedQuery}`;
}

export class AcquisitionJobRepository {
  constructor(private readonly handle: DbHandle) {}

  createJob(input: CreateAcquisitionJobInput): AcquisitionJobRow {
    if (!isPositiveInteger(input.userId)) {
      throw new AcquisitionJobRepositoryError(
        'invalid_input',
        'userId doit être un entier positif.',
      );
    }

    const query = normalizeWhitespace(input.query);
    if (!query) {
      throw new AcquisitionJobRepositoryError(
        'invalid_input',
        'La requête ne peut pas être vide.',
      );
    }
    if (query.length > MAX_QUERY_LENGTH) {
      throw new AcquisitionJobRepositoryError(
        'invalid_input',
        `La requête dépasse ${MAX_QUERY_LENGTH} caractères.`,
      );
    }

    const provider = input.provider ?? 'QOBUZ';
    if (provider !== 'QOBUZ') {
      throw new AcquisitionJobRepositoryError(
        'invalid_input',
        'Seul le provider QOBUZ est autorisé.',
      );
    }

    const resultIndex = input.resultIndex ?? null;
    if (
      resultIndex !== null &&
      (!Number.isInteger(resultIndex) || resultIndex < 0 || resultIndex > MAX_RESULT_INDEX)
    ) {
      throw new AcquisitionJobRepositoryError(
        'invalid_input',
        `resultIndex doit être compris entre 0 et ${MAX_RESULT_INDEX}.`,
      );
    }

    const maxAttempts = input.maxAttempts ?? 3;
    if (
      !Number.isInteger(maxAttempts) ||
      maxAttempts < 1 ||
      maxAttempts > MAX_ATTEMPTS
    ) {
      throw new AcquisitionJobRepositoryError(
        'invalid_input',
        `maxAttempts doit être compris entre 1 et ${MAX_ATTEMPTS}.`,
      );
    }
    for (const [field, value] of [
      ['selectedTitle', input.selectedTitle],
      ['selectedArtist', input.selectedArtist],
      ['selectedAlbum', input.selectedAlbum],
    ] as const) {
      validateOptionalText(field, value);
    }
    if (
      input.selectedDurationSeconds !== undefined &&
      input.selectedDurationSeconds !== null &&
      (!Number.isInteger(input.selectedDurationSeconds) ||
        input.selectedDurationSeconds < 1 ||
        input.selectedDurationSeconds > 86_400)
    ) {
      throw new AcquisitionJobRepositoryError(
        'invalid_input',
        'selectedDurationSeconds invalide.',
      );
    }

    const now = new Date().toISOString();
    const dedupeKey = buildAcquisitionDedupeKey({
      provider,
      query,
      resultIndex,
    });

    try {
      const row = this.handle.db
        .insert(acquisitionJobs)
        .values({
          id: randomUUID(),
          userId: input.userId,
          provider,
          query,
          dedupeKey,
          resultIndex,
          maxAttempts,
          selectedTitle: input.selectedTitle,
          selectedArtist: input.selectedArtist,
          selectedAlbum: input.selectedAlbum,
          selectedDurationSeconds: input.selectedDurationSeconds,
          createdAt: now,
          updatedAt: now,
        })
        .returning()
        .get();

      if (!row) {
        throw new AcquisitionJobRepositoryError(
          'invalid_input',
          'La création du job a échoué.',
        );
      }

      return row;
    } catch (error) {
      if (error instanceof AcquisitionJobRepositoryError) throw error;
      if (isUniqueConstraintError(error)) {
        throw new AcquisitionJobRepositoryError(
          'active_duplicate',
          'Un import identique est déjà actif pour cet utilisateur.',
        );
      }
      throw error;
    }
  }

  getJobForUser(id: string, userId: number): AcquisitionJobRow | null {
    this.validateIdentity(id, userId);
    return (
      this.handle.db
        .select()
        .from(acquisitionJobs)
        .where(
          and(
            eq(acquisitionJobs.id, id),
            eq(acquisitionJobs.userId, userId),
          ),
        )
        .get() ?? null
    );
  }

  requireJobForUser(id: string, userId: number): AcquisitionJobRow {
    const row = this.getJobForUser(id, userId);
    if (!row) {
      throw new AcquisitionJobRepositoryError(
        'job_not_found',
        'Job d’acquisition introuvable.',
      );
    }
    return row;
  }

  listRecentForUser(
    userId: number,
    limit = DEFAULT_LIST_LIMIT,
    status?: AcquisitionJobStatus,
  ): AcquisitionJobRow[] {
    if (!isPositiveInteger(userId)) {
      throw new AcquisitionJobRepositoryError(
        'invalid_input',
        'userId doit être un entier positif.',
      );
    }
    if (!Number.isInteger(limit) || limit < 1 || limit > MAX_LIST_LIMIT) {
      throw new AcquisitionJobRepositoryError(
        'invalid_input',
        `limit doit être compris entre 1 et ${MAX_LIST_LIMIT}.`,
      );
    }
    if (
      status !== undefined &&
      !(
        [
          ...ACTIVE_ACQUISITION_JOB_STATUSES,
          ...TERMINAL_ACQUISITION_JOB_STATUSES,
        ] as readonly string[]
      ).includes(status)
    ) {
      throw new AcquisitionJobRepositoryError(
        'invalid_input',
        'Statut d’acquisition invalide.',
      );
    }

    return this.handle.db
      .select()
      .from(acquisitionJobs)
      .where(
        status === undefined
          ? eq(acquisitionJobs.userId, userId)
          : and(
              eq(acquisitionJobs.userId, userId),
              eq(acquisitionJobs.status, status),
            ),
      )
      .orderBy(desc(acquisitionJobs.createdAt), desc(acquisitionJobs.id))
      .limit(limit)
      .all();
  }

  findActiveDuplicate(
    userId: number,
    dedupeKey: string,
  ): AcquisitionJobRow | null {
    if (!isPositiveInteger(userId) || !dedupeKey.trim()) {
      throw new AcquisitionJobRepositoryError(
        'invalid_input',
        'Paramètres de recherche de doublon invalides.',
      );
    }

    return (
      this.handle.db
        .select()
        .from(acquisitionJobs)
        .where(
          and(
            eq(acquisitionJobs.userId, userId),
            eq(acquisitionJobs.dedupeKey, dedupeKey),
            inArray(
              acquisitionJobs.status,
              [...ACTIVE_ACQUISITION_JOB_STATUSES],
            ),
          ),
        )
        .get() ?? null
    );
  }

  updateJob(
    id: string,
    userId: number,
    input: UpdateAcquisitionJobInput,
  ): AcquisitionJobRow {
    const current = this.requireJobForUser(id, userId);
    this.validateUpdate(input);

    const now = new Date().toISOString();
    const values: Partial<typeof acquisitionJobs.$inferInsert> = {
      ...input,
      updatedAt: now,
    };

    if (
      input.status !== undefined &&
      input.status !== 'QUEUED' &&
      current.startedAt === null
    ) {
      values.startedAt = now;
    }

    if (input.status !== undefined && isTerminalStatus(input.status)) {
      values.completedAt = current.completedAt ?? now;
    }

    if (input.status === 'COMPLETED') {
      values.progress = 100;
      values.errorCode = null;
      values.errorMessage = null;
    }

    const row = this.handle.db
      .update(acquisitionJobs)
      .set(values)
      .where(
        and(
          eq(acquisitionJobs.id, id),
          eq(acquisitionJobs.userId, userId),
        ),
      )
      .returning()
      .get();

    if (!row) {
      throw new AcquisitionJobRepositoryError(
        'job_not_found',
        'Job d’acquisition introuvable.',
      );
    }

    return row;
  }

  requestCancellation(id: string, userId: number): boolean {
    const current = this.requireJobForUser(id, userId);
    if (!isActiveStatus(current.status)) return false;
    if (current.cancelRequested) return true;

    this.handle.db
      .update(acquisitionJobs)
      .set({
        cancelRequested: true,
        updatedAt: new Date().toISOString(),
      })
      .where(
        and(
          eq(acquisitionJobs.id, id),
          eq(acquisitionJobs.userId, userId),
        ),
      )
      .run();

    return true;
  }

  markActiveJobsInterruptedOnStartup(): number {
    const now = new Date().toISOString();
    const result = this.handle.db
      .update(acquisitionJobs)
      .set({
        status: 'INTERRUPTED',
        stage: 'interrupted',
        message: 'Import interrompu par un redémarrage du serveur.',
        errorCode: 'SERVER_RESTART',
        errorMessage: 'Le serveur a redémarré avant la fin de l’import.',
        completedAt: now,
        updatedAt: now,
      })
      .where(
        inArray(
          acquisitionJobs.status,
          [...INTERRUPTIBLE_ACQUISITION_JOB_STATUSES],
        ),
      )
      .run();

    return result.changes;
  }

  pauseQueuedJobs(
    reasonCode: string,
    publicMessage: string,
  ): number {
    const now = new Date().toISOString();
    const result = this.handle.db
      .update(acquisitionJobs)
      .set({
        status: 'PAUSED_PROVIDER',
        stage: 'provider_paused',
        message: publicMessage.slice(0, MAX_TEXT_LENGTH),
        errorCode: reasonCode.slice(0, 100),
        errorMessage: publicMessage.slice(0, MAX_TEXT_LENGTH),
        updatedAt: now,
      })
      .where(
        and(
          eq(acquisitionJobs.provider, 'QOBUZ'),
          eq(acquisitionJobs.status, 'QUEUED'),
        ),
      )
      .run();
    return result.changes;
  }

  resumePausedJob(id: string, userId: number): AcquisitionJobRow {
    const current = this.requireJobForUser(id, userId);
    if (current.status !== 'PAUSED_PROVIDER') {
      throw new AcquisitionJobRepositoryError(
        'invalid_input',
        'Seul un job suspendu par le fournisseur peut être repris.',
      );
    }
    const row = this.handle.db
      .update(acquisitionJobs)
      .set({
        status: 'QUEUED',
        stage: 'queued',
        message: 'Tentative manuelle en attente.',
        errorCode: null,
        errorMessage: null,
        cancelRequested: false,
        completedAt: null,
        updatedAt: new Date().toISOString(),
      })
      .where(
        and(
          eq(acquisitionJobs.id, id),
          eq(acquisitionJobs.userId, userId),
          eq(acquisitionJobs.status, 'PAUSED_PROVIDER'),
        ),
      )
      .returning()
      .get();
    if (!row) {
      throw new AcquisitionJobRepositoryError(
        'job_not_found',
        'Job d’acquisition introuvable.',
      );
    }
    return row;
  }

  private validateIdentity(id: string, userId: number): void {
    if (!id.trim() || id.length > 100) {
      throw new AcquisitionJobRepositoryError(
        'invalid_input',
        'Identifiant de job invalide.',
      );
    }
    if (!isPositiveInteger(userId)) {
      throw new AcquisitionJobRepositoryError(
        'invalid_input',
        'userId doit être un entier positif.',
      );
    }
  }

  private validateUpdate(input: UpdateAcquisitionJobInput): void {
    if (Object.keys(input).length === 0) {
      throw new AcquisitionJobRepositoryError(
        'invalid_input',
        'Aucune modification fournie.',
      );
    }

    if (
      input.status !== undefined &&
      !(
        [
          ...ACTIVE_ACQUISITION_JOB_STATUSES,
          ...TERMINAL_ACQUISITION_JOB_STATUSES,
        ] as readonly string[]
      ).includes(input.status)
    ) {
      throw new AcquisitionJobRepositoryError(
        'invalid_input',
        'Statut d’acquisition invalide.',
      );
    }

    if (
      input.progress !== undefined &&
      (!Number.isInteger(input.progress) ||
        input.progress < 0 ||
        input.progress > 100)
    ) {
      throw new AcquisitionJobRepositoryError(
        'invalid_input',
        'progress doit être un entier compris entre 0 et 100.',
      );
    }

    if (
      input.attempt !== undefined &&
      (!Number.isInteger(input.attempt) ||
        input.attempt < 0 ||
        input.attempt > MAX_ATTEMPTS)
    ) {
      throw new AcquisitionJobRepositoryError(
        'invalid_input',
        `attempt doit être compris entre 0 et ${MAX_ATTEMPTS}.`,
      );
    }

    if (
      input.selectedDurationSeconds !== undefined &&
      input.selectedDurationSeconds !== null &&
      (!Number.isInteger(input.selectedDurationSeconds) ||
        input.selectedDurationSeconds < 0)
    ) {
      throw new AcquisitionJobRepositoryError(
        'invalid_input',
        'selectedDurationSeconds doit être un entier positif ou nul.',
      );
    }

    for (const [field, value] of [
      ['stage', input.stage],
      ['message', input.message],
      ['selectedTitle', input.selectedTitle],
      ['selectedArtist', input.selectedArtist],
      ['selectedAlbum', input.selectedAlbum],
      ['errorCode', input.errorCode],
      ['errorMessage', input.errorMessage],
      ['fallbackFrom', input.fallbackFrom],
      ['fallbackReasonCode', input.fallbackReasonCode],
    ] as const) {
      validateOptionalText(field, value);
    }

    if (
      input.providerUsed !== undefined &&
      input.providerUsed !== 'LUCIDA' &&
      input.providerUsed !== 'MONOCHROME_MANUAL'
    ) {
      throw new AcquisitionJobRepositoryError(
        'invalid_input',
        'providerUsed invalide.',
      );
    }

    validateOptionalText(
      'downloadedRelativePath',
      input.downloadedRelativePath,
      MAX_RELATIVE_PATH_LENGTH,
    );

    for (const [field, value] of [
      ['localImportJobId', input.localImportJobId],
      ['trackId', input.trackId],
    ] as const) {
      if (value !== undefined && value !== null && !isPositiveInteger(value)) {
        throw new AcquisitionJobRepositoryError(
          'invalid_input',
          `${field} doit être un entier positif ou null.`,
        );
      }
    }
  }
}
