import { randomUUID } from 'node:crypto';
import { and, desc, eq, inArray } from 'drizzle-orm';
import type { DbHandle } from '../db/client.js';
import { downloadJobs, type DownloadJobStatus } from '../db/schema.js';

/** États où le job occupe encore une place dans la file ou un processus. */
export const ACTIVE_DOWNLOAD_JOB_STATUSES = [
  'queued',
  'resolving',
  'downloading',
  'processing',
  'importing',
] as const satisfies readonly DownloadJobStatus[];

export const TERMINAL_DOWNLOAD_JOB_STATUSES = [
  'completed',
  'failed',
  'cancelled',
  'interrupted',
] as const satisfies readonly DownloadJobStatus[];

/** Seuls états relançables : un job réussi ou annulé ne redevient jamais actif. */
export const RETRYABLE_DOWNLOAD_JOB_STATUSES = [
  'failed',
  'interrupted',
] as const satisfies readonly DownloadJobStatus[];

export type DownloadJobRow = typeof downloadJobs.$inferSelect;

export type DownloadJobRepositoryErrorCode =
  | 'invalid_input'
  | 'job_not_found'
  | 'active_duplicate'
  | 'not_retryable';

export class DownloadJobRepositoryError extends Error {
  constructor(
    readonly code: DownloadJobRepositoryErrorCode,
    message: string,
  ) {
    super(message);
    this.name = 'DownloadJobRepositoryError';
  }
}

/** `url` = lien collé par l'utilisateur ; `search` = recherche texte résolue. */
export const DOWNLOAD_REQUEST_KINDS = ['url', 'search'] as const;
export type DownloadRequestKind = (typeof DOWNLOAD_REQUEST_KINDS)[number];

export interface CreateDownloadJobInput {
  userId: number;
  requestedUrl: string;
  normalizedUrl: string;
  maxAttempts?: number;
  requestKind?: DownloadRequestKind;
  /** Texte saisi ; conservé pour l'historique et la relance. */
  query?: string | null;
  /** Candidats retenus, sérialisés — jamais de credential ni de token. */
  candidatesJson?: string | null;
}

export interface UpdateDownloadJobInput {
  status?: DownloadJobStatus;
  stage?: string | null;
  progress?: number;
  message?: string | null;
  title?: string | null;
  artist?: string | null;
  album?: string | null;
  source?: string | null;
  quality?: string | null;
  outputPath?: string | null;
  localImportJobId?: number | null;
  trackId?: number | null;
  errorCode?: string | null;
  errorMessage?: string | null;
  processId?: number | null;
  attempt?: number;
  /** Historique ordonné des tentatives (JSON assaini). */
  attemptsJson?: string | null;
  candidatesJson?: string | null;
  selectedProvider?: string | null;
  selectedUrl?: string | null;
}

const MAX_URL_LENGTH = 2_000;
const MAX_TEXT_LENGTH = 500;
/** Borne des colonnes JSON : un historique de tentatives, pas un journal. */
const MAX_JSON_LENGTH = 20_000;
const MAX_PATH_LENGTH = 1_000;
const MAX_ATTEMPTS = 10;
const DEFAULT_LIST_LIMIT = 20;
const MAX_LIST_LIMIT = 100;

function isPositiveInteger(value: number): boolean {
  return Number.isInteger(value) && value > 0;
}

function isTerminal(status: DownloadJobStatus): boolean {
  return (TERMINAL_DOWNLOAD_JOB_STATUSES as readonly string[]).includes(status);
}

function isActive(status: string): boolean {
  return (ACTIVE_DOWNLOAD_JOB_STATUSES as readonly string[]).includes(status);
}

function isUniqueConstraintError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  const code = (error as Error & { code?: string }).code ?? '';
  return (
    code === 'SQLITE_CONSTRAINT_UNIQUE' ||
    /UNIQUE constraint failed:\s*download_jobs\./i.test(error.message)
  );
}

function validateText(
  field: string,
  value: string | null | undefined,
  maxLength = MAX_TEXT_LENGTH,
): void {
  if (value === undefined || value === null) return;
  if (value.length > maxLength) {
    throw new DownloadJobRepositoryError(
      'invalid_input',
      `${field} dépasse ${maxLength} caractères.`,
    );
  }
}

/**
 * Persistance des téléchargements Antra.
 *
 * Toute transition critique passe par une transaction SQLite : un job ne peut
 * pas être pris deux fois par la file, ni redevenir actif après un état
 * terminal.
 */
export class DownloadJobRepository {
  constructor(private readonly handle: DbHandle) {}

  createJob(input: CreateDownloadJobInput): DownloadJobRow {
    if (!isPositiveInteger(input.userId)) {
      throw new DownloadJobRepositoryError(
        'invalid_input',
        'userId doit être un entier positif.',
      );
    }
    validateText('requestedUrl', input.requestedUrl, MAX_URL_LENGTH);
    validateText('normalizedUrl', input.normalizedUrl, MAX_URL_LENGTH);
    if (input.requestedUrl.trim().length === 0) {
      throw new DownloadJobRepositoryError('invalid_input', 'url vide.');
    }

    const maxAttempts = input.maxAttempts ?? 3;
    if (!Number.isInteger(maxAttempts) || maxAttempts < 1 || maxAttempts > MAX_ATTEMPTS) {
      throw new DownloadJobRepositoryError(
        'invalid_input',
        `maxAttempts doit être compris entre 1 et ${MAX_ATTEMPTS}.`,
      );
    }

    const requestKind = input.requestKind ?? 'url';
    if (!(DOWNLOAD_REQUEST_KINDS as readonly string[]).includes(requestKind)) {
      throw new DownloadJobRepositoryError(
        'invalid_input',
        'requestKind doit valoir "url" ou "search".',
      );
    }
    validateText('query', input.query, MAX_TEXT_LENGTH);
    validateText('candidatesJson', input.candidatesJson, MAX_JSON_LENGTH);

    const now = new Date().toISOString();
    try {
      const row = this.handle.db
        .insert(downloadJobs)
        .values({
          id: randomUUID(),
          userId: input.userId,
          provider: 'antra',
          requestedUrl: input.requestedUrl,
          normalizedUrl: input.normalizedUrl,
          requestKind,
          query: input.query ?? null,
          candidatesJson: input.candidatesJson ?? null,
          maxAttempts,
          createdAt: now,
          updatedAt: now,
        })
        .returning()
        .get();
      if (!row) {
        throw new DownloadJobRepositoryError(
          'invalid_input',
          'La création du téléchargement a échoué.',
        );
      }
      return row;
    } catch (error) {
      if (error instanceof DownloadJobRepositoryError) throw error;
      if (isUniqueConstraintError(error)) {
        throw new DownloadJobRepositoryError(
          'active_duplicate',
          'Ce lien est déjà en cours de téléchargement.',
        );
      }
      throw error;
    }
  }

  getJobForUser(id: string, userId: number): DownloadJobRow | null {
    this.validateIdentity(id, userId);
    return (
      this.handle.db
        .select()
        .from(downloadJobs)
        .where(and(eq(downloadJobs.id, id), eq(downloadJobs.userId, userId)))
        .get() ?? null
    );
  }

  requireJobForUser(id: string, userId: number): DownloadJobRow {
    const row = this.getJobForUser(id, userId);
    if (!row) {
      throw new DownloadJobRepositoryError(
        'job_not_found',
        'Téléchargement introuvable.',
      );
    }
    return row;
  }

  /** Lecture ADMINISTRATEUR : ne doit jamais servir une route utilisateur. */
  getJobById(id: string): DownloadJobRow | null {
    return (
      this.handle.db.select().from(downloadJobs).where(eq(downloadJobs.id, id)).get() ??
      null
    );
  }

  listRecentForUser(
    userId: number,
    limit = DEFAULT_LIST_LIMIT,
    status?: DownloadJobStatus,
  ): DownloadJobRow[] {
    if (!isPositiveInteger(userId)) {
      throw new DownloadJobRepositoryError(
        'invalid_input',
        'userId doit être un entier positif.',
      );
    }
    if (!Number.isInteger(limit) || limit < 1 || limit > MAX_LIST_LIMIT) {
      throw new DownloadJobRepositoryError(
        'invalid_input',
        `limit doit être compris entre 1 et ${MAX_LIST_LIMIT}.`,
      );
    }

    return this.handle.db
      .select()
      .from(downloadJobs)
      .where(
        status === undefined
          ? eq(downloadJobs.userId, userId)
          : and(eq(downloadJobs.userId, userId), eq(downloadJobs.status, status)),
      )
      .orderBy(desc(downloadJobs.createdAt), desc(downloadJobs.id))
      .limit(limit)
      .all();
  }

  updateJob(id: string, input: UpdateDownloadJobInput): DownloadJobRow {
    this.validateUpdate(input);

    return this.handle.sqlite.transaction(() => {
      const current = this.handle.db
        .select()
        .from(downloadJobs)
        .where(eq(downloadJobs.id, id))
        .get();
      if (!current) {
        throw new DownloadJobRepositoryError(
          'job_not_found',
          'Téléchargement introuvable.',
        );
      }

      const now = new Date().toISOString();
      const values: Partial<typeof downloadJobs.$inferInsert> = {
        ...input,
        updatedAt: now,
      };

      // Un job terminal ne redevient JAMAIS actif par une simple mise à jour :
      // seule `requeueForRetry` peut le faire, et uniquement depuis
      // `failed`/`interrupted`.
      if (
        input.status !== undefined &&
        isTerminal(current.status as DownloadJobStatus) &&
        !isTerminal(input.status)
      ) {
        throw new DownloadJobRepositoryError(
          'invalid_input',
          'Un téléchargement terminé ne peut pas redevenir actif.',
        );
      }

      if (input.status !== undefined && input.status !== 'queued' && current.startedAt === null) {
        values.startedAt = now;
      }
      if (input.status !== undefined && isTerminal(input.status)) {
        values.completedAt = current.completedAt ?? now;
        // Aucun processus ne survit à un état terminal.
        values.processId = null;
      }
      if (input.status === 'completed') {
        values.progress = 100;
        values.errorCode = null;
        values.errorMessage = null;
      }

      const row = this.handle.db
        .update(downloadJobs)
        .set(values)
        .where(eq(downloadJobs.id, id))
        .returning()
        .get();
      if (!row) {
        throw new DownloadJobRepositoryError(
          'job_not_found',
          'Téléchargement introuvable.',
        );
      }
      return row;
    })();
  }

  /**
   * Marque la demande d'annulation. Idempotent : rappeler la méthode sur un job
   * déjà en cours d'annulation ne change rien et retourne `true`.
   */
  requestCancellation(id: string, userId: number): boolean {
    return this.handle.sqlite.transaction(() => {
      const current = this.requireJobForUser(id, userId);
      if (!isActive(current.status)) return false;
      if (current.cancelRequested) return true;

      this.handle.db
        .update(downloadJobs)
        .set({ cancelRequested: true, updatedAt: new Date().toISOString() })
        .where(and(eq(downloadJobs.id, id), eq(downloadJobs.userId, userId)))
        .run();
      return true;
    })();
  }

  /**
   * Remet un job `failed`/`interrupted` en file, sur la MÊME ligne : aucun
   * doublon n'est créé et l'historique de l'URL reste unique.
   */
  requeueForRetry(id: string, userId: number): DownloadJobRow {
    return this.handle.sqlite.transaction(() => {
      const current = this.requireJobForUser(id, userId);
      if (
        !(RETRYABLE_DOWNLOAD_JOB_STATUSES as readonly string[]).includes(current.status)
      ) {
        throw new DownloadJobRepositoryError(
          'not_retryable',
          'Seul un téléchargement en échec ou interrompu peut être relancé.',
        );
      }
      if (current.attempt >= current.maxAttempts) {
        throw new DownloadJobRepositoryError(
          'not_retryable',
          'Nombre maximal de tentatives atteint pour ce téléchargement.',
        );
      }

      const now = new Date().toISOString();
      try {
        const row = this.handle.db
          .update(downloadJobs)
          .set({
            status: 'queued',
            stage: 'queued',
            progress: 0,
            message: 'Nouvelle tentative en attente.',
            errorCode: null,
            errorMessage: null,
            processId: null,
            cancelRequested: false,
            completedAt: null,
            startedAt: null,
            // Nouvelle séquence de tentatives : l'historique précédent ne doit
            // pas être confondu avec celui de la relance. Les CANDIDATS sont
            // en revanche conservés — c'est eux qu'on rejoue.
            attemptsJson: null,
            selectedProvider: null,
            selectedUrl: null,
            updatedAt: now,
          })
          .where(
            and(
              eq(downloadJobs.id, id),
              eq(downloadJobs.userId, userId),
              inArray(downloadJobs.status, [...RETRYABLE_DOWNLOAD_JOB_STATUSES]),
            ),
          )
          .returning()
          .get();
        if (!row) {
          throw new DownloadJobRepositoryError(
            'not_retryable',
            'Le téléchargement a changé d’état entre-temps.',
          );
        }
        return row;
      } catch (error) {
        if (error instanceof DownloadJobRepositoryError) throw error;
        if (isUniqueConstraintError(error)) {
          throw new DownloadJobRepositoryError(
            'active_duplicate',
            'Ce lien est déjà en cours de téléchargement.',
          );
        }
        throw error;
      }
    })();
  }

  findActiveByUrl(userId: number, normalizedUrl: string): DownloadJobRow | null {
    return (
      this.handle.db
        .select()
        .from(downloadJobs)
        .where(
          and(
            eq(downloadJobs.userId, userId),
            eq(downloadJobs.normalizedUrl, normalizedUrl),
            inArray(downloadJobs.status, [...ACTIVE_DOWNLOAD_JOB_STATUSES]),
          ),
        )
        .get() ?? null
    );
  }

  /**
   * Marque interrompus les jobs laissés actifs par un processus serveur
   * disparu. À appeler UNE FOIS au démarrage, avant d'accepter du travail.
   */
  markActiveJobsInterruptedOnStartup(): number {
    const now = new Date().toISOString();
    const result = this.handle.db
      .update(downloadJobs)
      .set({
        status: 'interrupted',
        stage: 'interrupted',
        message: 'Téléchargement interrompu par un redémarrage du serveur.',
        errorCode: 'SERVER_RESTART',
        errorMessage: 'Le serveur a redémarré avant la fin du téléchargement.',
        processId: null,
        completedAt: now,
        updatedAt: now,
      })
      .where(inArray(downloadJobs.status, [...ACTIVE_DOWNLOAD_JOB_STATUSES]))
      .run();
    return result.changes;
  }

  private validateIdentity(id: string, userId: number): void {
    if (!id.trim() || id.length > 100) {
      throw new DownloadJobRepositoryError(
        'invalid_input',
        'Identifiant de téléchargement invalide.',
      );
    }
    if (!isPositiveInteger(userId)) {
      throw new DownloadJobRepositoryError(
        'invalid_input',
        'userId doit être un entier positif.',
      );
    }
  }

  private validateUpdate(input: UpdateDownloadJobInput): void {
    if (Object.keys(input).length === 0) {
      throw new DownloadJobRepositoryError(
        'invalid_input',
        'Aucune modification fournie.',
      );
    }
    if (
      input.progress !== undefined &&
      (!Number.isInteger(input.progress) || input.progress < 0 || input.progress > 100)
    ) {
      throw new DownloadJobRepositoryError(
        'invalid_input',
        'progress doit être un entier compris entre 0 et 100.',
      );
    }
    if (
      input.processId !== undefined &&
      input.processId !== null &&
      !isPositiveInteger(input.processId)
    ) {
      throw new DownloadJobRepositoryError(
        'invalid_input',
        'processId doit être un entier positif ou null.',
      );
    }
    if (
      input.attempt !== undefined &&
      (!Number.isInteger(input.attempt) || input.attempt < 0 || input.attempt > MAX_ATTEMPTS)
    ) {
      throw new DownloadJobRepositoryError(
        'invalid_input',
        `attempt doit être compris entre 0 et ${MAX_ATTEMPTS}.`,
      );
    }

    for (const [field, value] of [
      ['stage', input.stage],
      ['message', input.message],
      ['title', input.title],
      ['artist', input.artist],
      ['album', input.album],
      ['source', input.source],
      ['quality', input.quality],
      ['errorCode', input.errorCode],
      ['errorMessage', input.errorMessage],
      ['selectedProvider', input.selectedProvider],
    ] as const) {
      validateText(field, value);
    }
    validateText('outputPath', input.outputPath, MAX_PATH_LENGTH);
    validateText('selectedUrl', input.selectedUrl, MAX_URL_LENGTH);
    validateText('attemptsJson', input.attemptsJson, MAX_JSON_LENGTH);
    validateText('candidatesJson', input.candidatesJson, MAX_JSON_LENGTH);

    for (const [field, value] of [
      ['localImportJobId', input.localImportJobId],
      ['trackId', input.trackId],
    ] as const) {
      if (value !== undefined && value !== null && !isPositiveInteger(value)) {
        throw new DownloadJobRepositoryError(
          'invalid_input',
          `${field} doit être un entier positif ou null.`,
        );
      }
    }
  }
}
