import { and, eq } from 'drizzle-orm';
import type { DbHandle } from '../db/client.js';
import {
  importJobs,
  type ImportJobStatus,
} from '../db/schema.js';
import type {
  UserImportPaths,
} from './user-import-service.js';
import {
  AcquisitionJobRepository,
  AcquisitionJobRepositoryError,
  type AcquisitionJobRow,
} from './acquisition-job-repository.js';
import {
  LucidaProcessError,
  type LucidaDownloadRunRequest,
  type LucidaEvent,
  type LucidaRunResult,
} from './lucida-process-runner.js';

const MAX_RESULT_INDEX = 100;
const MAX_DOWNLOAD_TIMEOUT_SECONDS = 300;
const MAX_DOWNLOAD_RETRIES = 9;

export interface AcquisitionLocalImportService {
  ensureUserDirectory(
    userId: number,
    username: string,
  ): Promise<UserImportPaths>;

  processInboxFile(
    userId: number,
    path: string,
  ): Promise<number>;
}

export interface AcquisitionRunner {
  run(request: LucidaDownloadRunRequest): Promise<LucidaRunResult>;
  stopAll(): void;
}

export interface StartAcquisitionInput {
  userId: number;
  username: string;
  query: string;
  resultIndex: number;
  downloadTimeoutSeconds?: number;
  downloadRetries?: number;
}

interface QueuedAcquisition {
  jobId: string;
  userId: number;
  username: string;
  query: string;
  resultIndex: number;
  downloadTimeoutSeconds: number;
  downloadRetries: number;
}

interface ActiveAcquisition {
  item: QueuedAcquisition;
  controller: AbortController;
}

export class AcquisitionImportServiceError extends Error {
  constructor(
    readonly code:
      | 'invalid_input'
      | 'service_stopped'
      | 'job_not_found',
    message: string,
  ) {
    super(message);
    this.name = 'AcquisitionImportServiceError';
  }
}

/**
 * Orchestre la partie distante puis remet le fichier au pipeline local.
 *
 * Règle fondamentale :
 * - acquisition_jobs suit Python/Lucida ;
 * - import_jobs reste créé et finalisé uniquement par UserImportService.
 */
export class AcquisitionImportService {
  private readonly queue: QueuedAcquisition[] = [];
  private active: ActiveAcquisition | null = null;
  private drainPromise: Promise<void> | null = null;
  private stopped = false;

  constructor(
    private readonly handle: DbHandle,
    private readonly repository: AcquisitionJobRepository,
    private readonly runner: AcquisitionRunner,
    private readonly localImportService: AcquisitionLocalImportService,
  ) {}

  /**
   * Marque les jobs laissés actifs par un ancien processus serveur.
   * À appeler une fois au démarrage, avant d'accepter de nouveaux jobs.
   */
  recoverInterruptedJobs(): number {
    return this.repository.markActiveJobsInterruptedOnStartup();
  }

  enqueue(input: StartAcquisitionInput): AcquisitionJobRow {
    if (this.stopped) {
      throw new AcquisitionImportServiceError(
        'service_stopped',
        'Le service d’acquisition est arrêté.',
      );
    }

    const normalized = this.validateStartInput(input);
    const job = this.repository.createJob({
      userId: normalized.userId,
      query: normalized.query,
      provider: 'QOBUZ',
      resultIndex: normalized.resultIndex,
      maxAttempts: normalized.downloadRetries + 1,
    });

    this.queue.push({
      jobId: job.id,
      ...normalized,
    });
    this.kickDrain();

    return job;
  }

  getJobForUser(
    jobId: string,
    userId: number,
  ): AcquisitionJobRow | null {
    return this.repository.getJobForUser(jobId, userId);
  }

  listRecentForUser(
    userId: number,
    limit = 20,
  ): AcquisitionJobRow[] {
    return this.repository.listRecentForUser(userId, limit);
  }

  /**
   * Demande l'annulation du job du compte donné.
   *
   * - job encore en file : suppression immédiate et statut CANCELLED ;
   * - job actif : AbortController, puis le worker pose le statut final ;
   * - job terminal : retourne false.
   */
  cancel(jobId: string, userId: number): boolean {
    let current: AcquisitionJobRow;
    try {
      current = this.repository.requireJobForUser(jobId, userId);
    } catch (error) {
      if (
        error instanceof AcquisitionJobRepositoryError &&
        error.code === 'job_not_found'
      ) {
        throw new AcquisitionImportServiceError(
          'job_not_found',
          'Job d’acquisition introuvable.',
        );
      }
      throw error;
    }

    const accepted = this.repository.requestCancellation(jobId, userId);
    if (!accepted) return false;

    const queuedIndex = this.queue.findIndex(
      (item) => item.jobId === jobId && item.userId === userId,
    );
    if (queuedIndex >= 0) {
      this.queue.splice(queuedIndex, 1);
      this.repository.updateJob(jobId, userId, {
        status: 'CANCELLED',
        stage: 'cancelled',
        message: 'Import annulé avant son démarrage.',
        errorCode: 'CANCELLED',
        errorMessage: 'Annulé par l’utilisateur.',
      });
      return true;
    }

    if (
      this.active?.item.jobId === jobId &&
      this.active.item.userId === userId
    ) {
      this.active.controller.abort();
      return true;
    }

    // Le job peut avoir changé d'état entre la lecture et la demande.
    return current.status === 'QUEUED';
  }

  queuedCount(): number {
    return this.queue.length;
  }

  activeJobId(): string | null {
    return this.active?.item.jobId ?? null;
  }

  async waitForIdle(): Promise<void> {
    while (this.drainPromise !== null) {
      await this.drainPromise;
    }
  }

  /**
   * Arrêt du serveur :
   * - les jobs non démarrés deviennent INTERRUPTED ;
   * - le processus actif est interrompu ;
   * - aucun nouveau job n'est accepté.
   */
  async stop(): Promise<void> {
    if (this.stopped) {
      await this.waitForIdle();
      return;
    }

    this.stopped = true;

    const queued = this.queue.splice(0);
    for (const item of queued) {
      this.repository.updateJob(item.jobId, item.userId, {
        status: 'INTERRUPTED',
        stage: 'interrupted',
        message: 'Import interrompu par l’arrêt du serveur.',
        errorCode: 'SERVER_SHUTDOWN',
        errorMessage: 'Le serveur s’est arrêté avant le démarrage du job.',
      });
    }

    this.active?.controller.abort();
    this.runner.stopAll();
    await this.waitForIdle();
  }

  private kickDrain(): void {
    if (this.drainPromise !== null || this.stopped) return;

    this.drainPromise = this.drainQueue()
      .catch((error: unknown) => {
        // Chaque job est normalement isolé dans processItem. Cette branche
        // protège la file contre une erreur de programmation inattendue.
        console.error('échec inattendu de la file acquisition', {
          error:
            error instanceof Error
              ? error.message
              : 'Erreur inconnue.',
        });
      })
      .finally(() => {
        this.drainPromise = null;
        if (!this.stopped && this.queue.length > 0) {
          this.kickDrain();
        }
      });
  }

  private async drainQueue(): Promise<void> {
    while (!this.stopped && this.queue.length > 0) {
      const item = this.queue.shift();
      if (!item) return;

      const current = this.repository.getJobForUser(
        item.jobId,
        item.userId,
      );
      if (
        !current ||
        current.cancelRequested ||
        current.status !== 'QUEUED'
      ) {
        continue;
      }

      const controller = new AbortController();
      this.active = { item, controller };

      try {
        await this.processItem(item, controller.signal);
      } catch (error) {
        this.failItem(item, error);
      } finally {
        this.active = null;
      }
    }
  }

  private async processItem(
    item: QueuedAcquisition,
    signal: AbortSignal,
  ): Promise<void> {
    const paths = await this.localImportService.ensureUserDirectory(
      item.userId,
      item.username,
    );

    this.repository.updateJob(item.jobId, item.userId, {
      status: 'SEARCHING',
      stage: 'searching',
      progress: 0,
      message: 'Recherche du morceau.',
      errorCode: null,
      errorMessage: null,
    });

    const result = await this.runner.run({
      mode: 'download',
      query: item.query,
      resultIndex: item.resultIndex,
      outputDir: paths.inbox,
      downloadTimeoutSeconds: item.downloadTimeoutSeconds,
      downloadRetries: item.downloadRetries,
      signal,
      onEvent: (event) => {
        this.applyRunnerEvent(item, event);
      },
    });

    if (result.mode !== 'download') {
      throw new LucidaProcessError(
        'PROTOCOL_ERROR',
        'Le runner a retourné un résultat de recherche pour un téléchargement.',
      );
    }

    this.repository.updateJob(item.jobId, item.userId, {
      status: 'DOWNLOADED',
      stage: 'downloaded',
      progress: 100,
      message: 'Fichier téléchargé et validé par le script.',
      downloadedRelativePath: result.relativeFilePath,
    });

    this.repository.updateJob(item.jobId, item.userId, {
      status: 'IMPORTING',
      stage: 'local_import',
      progress: 100,
      message: 'Analyse et ajout dans la bibliothèque.',
    });

    const localImportJobId =
      await this.localImportService.processInboxFile(
        item.userId,
        result.absoluteFilePath,
      );

    const localJob = this.handle.db
      .select()
      .from(importJobs)
      .where(
        and(
          eq(importJobs.id, localImportJobId),
          eq(importJobs.userId, item.userId),
        ),
      )
      .get();

    if (!localJob) {
      throw new LucidaProcessError(
        'LOCAL_IMPORT_JOB_MISSING',
        'Le pipeline local n’a pas retourné de job valide.',
      );
    }

    this.finalizeFromLocalImport(
      item,
      localImportJobId,
      localJob.status as ImportJobStatus,
      localJob.trackId,
      localJob.errorMessage,
    );
  }

  private applyRunnerEvent(
    item: QueuedAcquisition,
    event: LucidaEvent,
  ): void {
    switch (event.type) {
      case 'stage':
        this.repository.updateJob(item.jobId, item.userId, {
          status: this.statusForStage(event.stage),
          stage: event.stage,
          message: event.message,
        });
        break;

      case 'selected':
        this.repository.updateJob(item.jobId, item.userId, {
          status: 'SELECTING',
          stage: 'selected',
          message: 'Résultat Deezer sélectionné.',
          selectedTitle: event.title,
          selectedArtist: event.artist,
          selectedAlbum: event.album,
          selectedDurationSeconds: event.duration,
        });
        break;

      case 'progress':
        this.repository.updateJob(item.jobId, item.userId, {
          status: 'DOWNLOADING',
          stage: event.stage,
          progress: event.percent,
          attempt: event.attempt,
          message: `Téléchargement ${event.attempt}/${event.maxAttempts}.`,
        });
        break;

      case 'retry':
        this.repository.updateJob(item.jobId, item.userId, {
          status: 'RETRYING',
          stage: 'retrying',
          attempt: event.attempt,
          message: event.reason,
        });
        break;

      case 'success':
        this.repository.updateJob(item.jobId, item.userId, {
          status: 'DOWNLOADED',
          stage: 'downloaded',
          progress: 100,
          message: 'Téléchargement terminé.',
          selectedTitle: event.title,
          selectedArtist: event.artist,
          selectedAlbum: event.album,
          selectedDurationSeconds: event.duration,
        });
        break;

      case 'error':
        // Le code de sortie du runner décide du statut terminal. On conserve
        // néanmoins le diagnostic structuré immédiatement.
        this.repository.updateJob(item.jobId, item.userId, {
          stage: 'error',
          message: event.message,
          errorCode: event.code,
          errorMessage: event.message,
        });
        break;

      case 'search_result':
      case 'complete':
        // Événements informatifs non persistés pour un job de téléchargement.
        break;
    }
  }

  private statusForStage(
    stage: string,
  ):
    | 'SEARCHING'
    | 'OPENING_RESULT'
    | 'VERIFYING'
    | 'DOWNLOADING' {
    switch (stage) {
      case 'opening_result':
        return 'OPENING_RESULT';

      case 'verifying':
      case 'validating':
        return 'VERIFYING';

      case 'downloading':
        return 'DOWNLOADING';

      case 'searching':
      case 'opening_site':
      case 'lucida_search':
      case 'selecting_service':
      case 'waiting_results':
      default:
        return 'SEARCHING';
    }
  }

  private finalizeFromLocalImport(
    item: QueuedAcquisition,
    localImportJobId: number,
    status: ImportJobStatus,
    trackId: number | null,
    localError: string | null,
  ): void {
    switch (status) {
      case 'IMPORTED':
      case 'REUSED':
        if (trackId === null) {
          throw new LucidaProcessError(
            'LOCAL_IMPORT_TRACK_MISSING',
            'Le pipeline local a terminé sans trackId.',
          );
        }
        this.repository.updateJob(item.jobId, item.userId, {
          status: 'COMPLETED',
          stage: 'completed',
          progress: 100,
          message:
            status === 'REUSED'
              ? 'Piste déjà présente et ajoutée à votre bibliothèque.'
              : 'Piste ajoutée à votre bibliothèque.',
          localImportJobId,
          trackId,
        });
        return;

      case 'WAITING_FOR_OWNER_MATCH':
        this.repository.updateJob(item.jobId, item.userId, {
          status: 'FAILED',
          stage: 'owner_review_required',
          message: 'Une validation manuelle du propriétaire est nécessaire.',
          localImportJobId,
          errorCode: 'LOCAL_IMPORT_REVIEW_REQUIRED',
          errorMessage:
            'Le fichier a été téléchargé mais le rapprochement local est ambigu.',
        });
        return;

      case 'REJECTED':
        this.repository.updateJob(item.jobId, item.userId, {
          status: 'FAILED',
          stage: 'local_import_rejected',
          message: 'Le fichier a été rejeté par le pipeline local.',
          localImportJobId,
          errorCode: 'LOCAL_IMPORT_REJECTED',
          errorMessage: localError ?? 'Import local rejeté.',
        });
        return;

      case 'FAILED':
        this.repository.updateJob(item.jobId, item.userId, {
          status: 'FAILED',
          stage: 'local_import_failed',
          message: 'L’import local a échoué.',
          localImportJobId,
          errorCode: 'LOCAL_IMPORT_FAILED',
          errorMessage: localError ?? 'Échec du pipeline local.',
        });
        return;

      case 'DISCOVERED':
      case 'WAITING_FOR_STABLE_FILE':
      case 'ANALYZING':
      default:
        this.repository.updateJob(item.jobId, item.userId, {
          status: 'FAILED',
          stage: 'local_import_incomplete',
          message: 'Le pipeline local s’est terminé dans un état inattendu.',
          localImportJobId,
          errorCode: 'LOCAL_IMPORT_INCOMPLETE',
          errorMessage: `Statut local inattendu : ${status}.`,
        });
    }
  }

  private failItem(
    item: QueuedAcquisition,
    error: unknown,
  ): void {
    const row = this.repository.getJobForUser(
      item.jobId,
      item.userId,
    );
    if (!row) return;

    const cancelled =
      error instanceof LucidaProcessError &&
      error.code === 'CANCELLED';

    if (cancelled && this.stopped) {
      this.repository.updateJob(item.jobId, item.userId, {
        status: 'INTERRUPTED',
        stage: 'interrupted',
        message: 'Import interrompu par l’arrêt du serveur.',
        errorCode: 'SERVER_SHUTDOWN',
        errorMessage: 'Le serveur s’est arrêté pendant le traitement.',
      });
      return;
    }

    if (cancelled || row.cancelRequested) {
      this.repository.updateJob(item.jobId, item.userId, {
        status: 'CANCELLED',
        stage: 'cancelled',
        message: 'Import annulé.',
        errorCode: 'CANCELLED',
        errorMessage: 'Annulé par l’utilisateur.',
      });
      return;
    }

    const code =
      error instanceof LucidaProcessError
        ? error.code
        : 'INTERNAL_ERROR';
    const message =
      error instanceof Error
        ? error.message
        : 'Erreur d’acquisition inconnue.';

    this.repository.updateJob(item.jobId, item.userId, {
      status: 'FAILED',
      stage: 'failed',
      message: 'L’acquisition a échoué.',
      errorCode: String(code).slice(0, 100),
      errorMessage: message.slice(0, 500),
    });
  }

  private validateStartInput(
    input: StartAcquisitionInput,
  ): Omit<QueuedAcquisition, 'jobId'> {
    if (!Number.isInteger(input.userId) || input.userId < 1) {
      throw new AcquisitionImportServiceError(
        'invalid_input',
        'userId doit être un entier positif.',
      );
    }

    const username = input.username.trim();
    if (!username || username.length > 100) {
      throw new AcquisitionImportServiceError(
        'invalid_input',
        'username invalide.',
      );
    }

    const query = input.query.trim().replace(/\s+/g, ' ');
    if (!query || query.length > 200) {
      throw new AcquisitionImportServiceError(
        'invalid_input',
        'La requête doit contenir entre 1 et 200 caractères.',
      );
    }

    if (
      !Number.isInteger(input.resultIndex) ||
      input.resultIndex < 0 ||
      input.resultIndex > MAX_RESULT_INDEX
    ) {
      throw new AcquisitionImportServiceError(
        'invalid_input',
        `resultIndex doit être compris entre 0 et ${MAX_RESULT_INDEX}.`,
      );
    }

    const downloadTimeoutSeconds =
      input.downloadTimeoutSeconds ?? 75;
    if (
      !Number.isInteger(downloadTimeoutSeconds) ||
      downloadTimeoutSeconds < 10 ||
      downloadTimeoutSeconds > MAX_DOWNLOAD_TIMEOUT_SECONDS
    ) {
      throw new AcquisitionImportServiceError(
        'invalid_input',
        `downloadTimeoutSeconds doit être compris entre 10 et ${MAX_DOWNLOAD_TIMEOUT_SECONDS}.`,
      );
    }

    const downloadRetries = input.downloadRetries ?? 2;
    if (
      !Number.isInteger(downloadRetries) ||
      downloadRetries < 0 ||
      downloadRetries > MAX_DOWNLOAD_RETRIES
    ) {
      throw new AcquisitionImportServiceError(
        'invalid_input',
        `downloadRetries doit être compris entre 0 et ${MAX_DOWNLOAD_RETRIES}.`,
      );
    }

    return {
      userId: input.userId,
      username,
      query,
      resultIndex: input.resultIndex,
      downloadTimeoutSeconds,
      downloadRetries,
    };
  }
}
