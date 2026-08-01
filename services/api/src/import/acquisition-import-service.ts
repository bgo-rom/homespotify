import { and, eq } from 'drizzle-orm';
import {
  lstat,
  readdir,
  realpath,
  rename,
  rm,
} from 'node:fs/promises';
import {
  basename,
  extname,
  isAbsolute,
  relative,
  resolve,
} from 'node:path';
import type { DbHandle } from '../db/client.js';
import {
  importJobs,
  type AcquisitionJobStatus,
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
import {
  ProviderHealthError,
  ProviderHealthRepository,
  type ProviderFailureCode,
  type ProviderPublicStatus,
} from './provider-health-repository.js';
import {
  MonochromeManualSessionError,
  MonochromeManualSessionRepository,
} from './monochrome-manual-session-repository.js';

const MAX_RESULT_INDEX = 100;
const MAX_DOWNLOAD_TIMEOUT_SECONDS = 300;
const MAX_DOWNLOAD_RETRIES = 9;

/**
 * Borne dure du parallélisme. Chaque job actif = un processus Python + un
 * Chromium : au-delà, la machine devient le goulot et le service distant voit
 * une rafale qui ressemble à un abus.
 */
export const MAX_CONCURRENT_ACQUISITIONS = 4;

/**
 * Délai minimal entre deux DÉMARRAGES de jobs.
 *
 * Ce n'est pas un détail de confort : lancer N processus dans la même
 * milliseconde produit une rafale simultanée vers le service distant, ce qui
 * est exactement le motif qui déclenche les blocages. Les démarrages sont donc
 * échelonnés, avec une part aléatoire pour ne pas créer un rythme régulier.
 */
const START_STAGGER_MS = 1_500;
const START_STAGGER_JITTER_MS = 1_000;

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
  targetTitle?: string;
  targetArtist?: string;
  targetAlbum?: string;
  targetDurationSeconds?: number;
}

export type ManualVerificationResult =
  | 'verification_completed'
  | 'cancelled'
  | 'timeout'
  | 'provider_error';

export type MonochromeManualResult =
  | 'download_ready'
  | 'cancelled'
  | 'timeout'
  | 'no_exact_match'
  | 'ambiguous_match'
  | 'file_rejected'
  | 'dry_run_completed'
  | 'provider_error';

const MONOCHROME_FALLBACK_CODES = new Set([
  'LUCIDA_ERROR',
  'PROVIDER_INVALID_RESPONSE',
  'PROVIDER_UNAVAILABLE',
  'PROVIDER_HTTP_ERROR',
  'SEARCH_FAILED',
]);

export function isMonochromeFallbackEligible(
  code: string,
  job: Pick<
    AcquisitionJobRow,
    'status' | 'cancelRequested' | 'selectedTitle' | 'selectedArtist'
  >,
): boolean {
  return (
    MONOCHROME_FALLBACK_CODES.has(code) &&
    !job.cancelRequested &&
    job.status !== 'COMPLETED' &&
    job.status !== 'IMPORTING' &&
    job.status !== 'MANUAL_VERIFICATION_REQUIRED' &&
    typeof job.selectedTitle === 'string' &&
    job.selectedTitle.trim().length > 0 &&
    typeof job.selectedArtist === 'string' &&
    job.selectedArtist.trim().length > 0
  );
}

interface AcquisitionHandlingResult {
  handled: true;
  terminal: boolean;
  state: AcquisitionJobStatus;
}

interface QueuedAcquisition {
  jobId: string;
  userId: number;
  username: string;
  query: string;
  resultIndex: number;
  downloadTimeoutSeconds: number;
  downloadRetries: number;
  targetTitle?: string;
  targetArtist?: string;
  targetAlbum?: string;
  targetDurationSeconds?: number;
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
      | 'job_not_found'
      | 'provider_cooldown'
      | 'probe_in_progress'
      | 'manual_verification_invalid'
      | 'manual_result_invalid',
    message: string,
    readonly retryAt: string | null = null,
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
  /** Jobs en cours d'exécution, indexés par identifiant. */
  private readonly active = new Map<string, ActiveAcquisition>();
  /** Un worker par créneau de parallélisme occupé. */
  private readonly workers = new Set<Promise<void>>();
  private stopped = false;
  private lastStartAt = 0;
  private readonly maxConcurrent: number;
  private readonly staggerMs: number;
  private readonly providerHealth: ProviderHealthRepository;
  private readonly interactiveVerificationEnabled: boolean;
  private readonly interactiveVerificationTimeoutSeconds: number;
  private readonly interactiveStagingRoot: string;
  private readonly monochromeStagingRoot: string;
  private readonly monochromeFallbackEnabled: boolean;
  private readonly monochromeManualTimeoutSeconds: number;
  private readonly monochromeSessions: MonochromeManualSessionRepository;
  private orphanedManualVerificationRepaired = false;

  constructor(
    private readonly handle: DbHandle,
    private readonly repository: AcquisitionJobRepository,
    private readonly runner: AcquisitionRunner,
    private readonly localImportService: AcquisitionLocalImportService,
    options: {
      /** 1 (défaut, sérialisé) à [MAX_CONCURRENT_ACQUISITIONS]. */
      maxConcurrent?: number;
      /** Injectable pour les tests : 0 désactive l'échelonnement. */
      startStaggerMs?: number;
      /** État fournisseur persistant injectable avec clock factice en tests. */
      providerHealth?: ProviderHealthRepository;
      interactiveVerificationEnabled?: boolean;
      interactiveVerificationTimeoutSeconds?: number;
      interactiveStagingRoot?: string;
      monochromeStagingRoot?: string;
      monochromeFallbackEnabled?: boolean;
      monochromeManualTimeoutSeconds?: number;
      monochromeSessions?: MonochromeManualSessionRepository;
    } = {},
  ) {
    const requested = options.maxConcurrent ?? 1;
    if (
      !Number.isInteger(requested) ||
      requested < 1 ||
      requested > MAX_CONCURRENT_ACQUISITIONS
    ) {
      throw new AcquisitionImportServiceError(
        'invalid_input',
        `maxConcurrent doit être un entier entre 1 et ${MAX_CONCURRENT_ACQUISITIONS}.`,
      );
    }
    this.maxConcurrent = requested;
    this.staggerMs = options.startStaggerMs ?? START_STAGGER_MS;
    this.providerHealth =
      options.providerHealth ??
      new ProviderHealthRepository(handle, {
        challengeCooldownSeconds: 1_800,
        rateLimitDefaultCooldownSeconds: 900,
        unavailableCooldownSeconds: 600,
        maxCooldownSeconds: 21_600,
        providerFailureWindowSeconds: 600,
        providerFailureThreshold: 2,
      });
    this.interactiveVerificationEnabled =
      options.interactiveVerificationEnabled ?? false;
    this.interactiveVerificationTimeoutSeconds =
      options.interactiveVerificationTimeoutSeconds ?? 120;
    this.interactiveStagingRoot = resolve(
      options.interactiveStagingRoot ?? '.interactive',
    );
    this.monochromeStagingRoot = resolve(
      options.monochromeStagingRoot ?? '.monochrome',
    );
    this.monochromeFallbackEnabled =
      options.monochromeFallbackEnabled ?? false;
    this.monochromeManualTimeoutSeconds =
      options.monochromeManualTimeoutSeconds ?? 600;
    this.monochromeSessions =
      options.monochromeSessions ??
      new MonochromeManualSessionRepository(handle);
    if (
      !Number.isInteger(this.interactiveVerificationTimeoutSeconds) ||
      this.interactiveVerificationTimeoutSeconds < 30 ||
      this.interactiveVerificationTimeoutSeconds > 600
    ) {
      throw new AcquisitionImportServiceError(
        'invalid_input',
        'interactiveVerificationTimeoutSeconds doit être compris entre 30 et 600.',
      );
    }
    if (
      !Number.isInteger(this.monochromeManualTimeoutSeconds) ||
      this.monochromeManualTimeoutSeconds < 30 ||
      this.monochromeManualTimeoutSeconds > 1_800
    ) {
      throw new AcquisitionImportServiceError(
        'invalid_input',
        'monochromeManualTimeoutSeconds doit être compris entre 30 et 1800.',
      );
    }
  }

  /**
   * Marque les jobs laissés actifs par un ancien processus serveur.
   * À appeler une fois au démarrage, avant d'accepter de nouveaux jobs.
   */
  recoverInterruptedJobs(): number {
    this.monochromeSessions.recoverInterruptedHolder();
    this.providerHealth.recoverInterruptedProbe();
    if (this.interactiveVerificationEnabled) {
      const orphanRepairedBeforeLegacyRecovery =
        this.providerHealth.repairOrphanedManualVerification();
      const legacyRecovery =
        this.providerHealth.recoverLegacyInteractiveChallenge();
      this.orphanedManualVerificationRepaired =
        orphanRepairedBeforeLegacyRecovery ||
        (legacyRecovery.providerStatesConverted > 0 &&
          legacyRecovery.jobsConverted === 0) ||
        this.providerHealth.repairOrphanedManualVerification();
    }
    const interrupted =
      this.repository.markActiveJobsInterruptedOnStartup();
    return interrupted;
  }

  repairedOrphanedManualVerificationOnStartup(): boolean {
    return this.orphanedManualVerificationRepaired;
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
      selectedTitle: normalized.targetTitle ?? null,
      selectedArtist: normalized.targetArtist ?? null,
      selectedAlbum: normalized.targetAlbum ?? null,
      selectedDurationSeconds: normalized.targetDurationSeconds ?? null,
    });

    if (this.interactiveVerificationEnabled) {
      this.providerHealth.repairOrphanedManualVerification();
    }
    const provider = this.providerHealth.get();
    if (provider.state === 'MANUAL_VERIFICATION_REQUIRED') {
      this.queue.push({
        jobId: job.id,
        ...normalized,
      });
      return job;
    }

    if (provider.state !== 'CLOSED') {
      return this.repository.updateJob(job.id, job.userId, {
        status: 'PAUSED_PROVIDER',
        stage: 'provider_paused',
        message: 'Le service est temporairement en pause.',
        errorCode: provider.reasonCode,
        errorMessage: 'Le service est temporairement en pause.',
      });
    }

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
    status?: AcquisitionJobStatus,
  ): AcquisitionJobRow[] {
    return this.repository.listRecentForUser(userId, limit, status);
  }

  providerStatus(): ProviderPublicStatus {
    return this.providerHealth.publicStatus();
  }

  manualVerificationContext(
    jobId: string,
    userId: number,
    reserveHolder = true,
  ): {
    job: AcquisitionJobRow;
    timeoutSeconds: number;
  } {
    if (!this.interactiveVerificationEnabled) {
      throw new AcquisitionImportServiceError(
        'manual_verification_invalid',
        'La vérification interactive n’est pas activée.',
      );
    }
    const job = this.repository.requireJobForUser(jobId, userId);
    const health = this.providerHealth.get();
    if (
      job.status !== 'MANUAL_VERIFICATION_REQUIRED' ||
      health.state !== 'MANUAL_VERIFICATION_REQUIRED' ||
      health.manualVerificationJobId !== jobId ||
      (!reserveHolder &&
        health.manualVerificationHolderJobId !== jobId)
    ) {
      throw new AcquisitionImportServiceError(
        'manual_verification_invalid',
        'Ce job n’attend pas de vérification manuelle.',
      );
    }
    if (reserveHolder) {
      try {
        this.providerHealth.reserveManualVerification(jobId);
      } catch (error) {
        if (error instanceof ProviderHealthError) {
          throw new AcquisitionImportServiceError(
            'manual_verification_invalid',
            error.message,
          );
        }
        throw error;
      }
    }
    return {
      job,
      timeoutSeconds: this.interactiveVerificationTimeoutSeconds,
    };
  }

  monochromeManualContext(
    jobId: string,
    userId: number,
  ): {
    job: AcquisitionJobRow;
    timeoutSeconds: number;
  } {
    if (!this.monochromeFallbackEnabled) {
      throw new AcquisitionImportServiceError(
        'manual_verification_invalid',
        'Le fallback Monochrome n’est pas activé.',
      );
    }
    const job = this.repository.requireJobForUser(jobId, userId);
    if (
      job.status !== 'WAITING_MANUAL_DOWNLOAD' ||
      !job.selectedTitle ||
      !job.selectedArtist ||
      job.cancelRequested
    ) {
      throw new AcquisitionImportServiceError(
        'manual_verification_invalid',
        'Ce job n’attend pas de téléchargement Monochrome.',
      );
    }
    try {
      this.monochromeSessions.reserve(jobId, userId);
    } catch (error) {
      if (error instanceof MonochromeManualSessionError) {
        throw new AcquisitionImportServiceError(
          'manual_verification_invalid',
          error.message,
        );
      }
      throw error;
    }
    return {
      job,
      timeoutSeconds: this.monochromeManualTimeoutSeconds,
    };
  }

  retryPaused(
    jobId: string,
    userId: number,
    username: string,
  ): AcquisitionJobRow {
    const current = this.repository.requireJobForUser(jobId, userId);
    if (current.status !== 'PAUSED_PROVIDER') {
      throw new AcquisitionImportServiceError(
        'invalid_input',
        'Ce job n’est pas suspendu par le fournisseur.',
      );
    }

    try {
      this.providerHealth.beginManualProbe(jobId);
    } catch (error) {
      if (error instanceof ProviderHealthError) {
        throw new AcquisitionImportServiceError(
          error.code,
          error.message,
          error.retryAt,
        );
      }
      throw error;
    }

    try {
      const resumed = this.repository.resumePausedJob(jobId, userId);
      this.queue.push({
        jobId,
        userId,
        username,
        query: resumed.query,
        resultIndex: resumed.resultIndex ?? 0,
        downloadTimeoutSeconds: 75,
        downloadRetries: Math.max(0, resumed.maxAttempts - 1),
      });
      this.kickDrain();
      return resumed;
    } catch (error) {
      this.providerHealth.releaseProbe(jobId);
      throw error;
    }
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

    if (current.status === 'MANUAL_VERIFICATION_REQUIRED') {
      this.repository.updateJob(jobId, userId, {
        status: 'CANCELLED',
        stage: 'cancelled',
        message: 'Import annulé.',
        errorCode: 'CANCELLED',
        errorMessage: 'Annulé par l’utilisateur.',
      });
      this.providerHealth.abandonManualVerification(jobId);
      return true;
    }

    if (current.status === 'WAITING_MANUAL_DOWNLOAD') {
      this.repository.updateJob(jobId, userId, {
        status: 'CANCELLED',
        stage: 'cancelled',
        message: 'Import annulé.',
        errorCode: 'CANCELLED',
        errorMessage: 'Annulé par l’utilisateur.',
      });
      this.monochromeSessions.release(jobId, userId);
      return true;
    }

    if (current.status === 'PAUSED_PROVIDER') {
      this.repository.updateJob(jobId, userId, {
        status: 'CANCELLED',
        stage: 'cancelled',
        message: 'Import annulé.',
        errorCode: 'CANCELLED',
        errorMessage: 'Annulé par l’utilisateur.',
      });
      this.providerHealth.releaseProbe(jobId);
      return true;
    }

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

    const running = this.active.get(jobId);
    if (running && running.item.userId === userId) {
      running.controller.abort();
      return true;
    }

    // Le job peut avoir changé d'état entre la lecture et la demande.
    return current.status === 'QUEUED';
  }

  async applyManualVerificationResult(
    jobId: string,
    userId: number,
    username: string,
    result: ManualVerificationResult,
  ): Promise<AcquisitionJobRow> {
    const { job } = this.manualVerificationContext(jobId, userId, false);

    switch (result) {
      case 'cancelled':
        this.cancel(jobId, userId);
        return this.repository.requireJobForUser(jobId, userId);

      case 'timeout':
        this.providerHealth.releaseManualVerification(jobId);
        return this.repository.updateJob(jobId, userId, {
          status: 'MANUAL_VERIFICATION_REQUIRED',
          stage: 'waiting_user_verification',
          message: 'Une vérification manuelle est nécessaire sur le serveur.',
          errorCode: 'PROVIDER_CHALLENGE',
          errorMessage:
            'Une vérification manuelle est nécessaire sur le serveur.',
        });

      case 'provider_error':
        this.providerHealth.releaseManualVerification(jobId);
        return this.repository.updateJob(jobId, userId, {
          status: 'MANUAL_VERIFICATION_REQUIRED',
          stage: 'waiting_user_verification',
          message: 'Une vérification manuelle est nécessaire sur le serveur.',
          errorCode: 'PROVIDER_CHALLENGE',
          errorMessage:
            'Une vérification manuelle est nécessaire sur le serveur.',
        });

      case 'verification_completed':
        break;
    }

    const stagingDirectory = this.interactiveJobDirectory(jobId);
    try {
      this.repository.updateJob(jobId, userId, {
        status: 'VERIFYING',
        stage: 'validating_manual_result',
        message: 'Validation du fichier acquis manuellement.',
        errorCode: null,
        errorMessage: null,
      });
      const source = await this.requireInteractiveAudioFile(
        stagingDirectory,
      );
      const paths = await this.localImportService.ensureUserDirectory(
        userId,
        username,
      );
      const destination = resolve(
        paths.inbox,
        `${jobId}-${basename(source)}`,
      );
      if (!this.isConfined(paths.inbox, destination)) {
        throw new AcquisitionImportServiceError(
          'manual_result_invalid',
          'Destination d’import manuel invalide.',
        );
      }
      await rename(source, destination);

      this.repository.updateJob(jobId, userId, {
        status: 'DOWNLOADED',
        stage: 'downloaded',
        progress: 100,
        message: 'Fichier téléchargé et validé par le helper.',
        downloadedRelativePath: basename(destination),
      });
      this.repository.updateJob(jobId, userId, {
        status: 'IMPORTING',
        stage: 'local_import',
        progress: 100,
        message: 'Analyse et ajout dans la bibliothèque.',
      });

      const localImportJobId =
        await this.localImportService.processInboxFile(
          userId,
          destination,
        );
      const localJob = this.handle.db
        .select()
        .from(importJobs)
        .where(
          and(
            eq(importJobs.id, localImportJobId),
            eq(importJobs.userId, userId),
          ),
        )
        .get();
      if (!localJob) {
        throw new AcquisitionImportServiceError(
          'manual_result_invalid',
          'Le pipeline local n’a pas retourné de job valide.',
        );
      }
      const completed = this.finalizeFromLocalImport(
        {
          jobId,
          userId,
          username,
          query: job.query,
          resultIndex: job.resultIndex ?? 0,
          downloadTimeoutSeconds: 75,
          downloadRetries: Math.max(0, job.maxAttempts - 1),
        },
        localImportJobId,
        localJob.status as ImportJobStatus,
        localJob.trackId,
        localJob.errorMessage,
      );
      if (completed) {
        this.providerHealth.recordManualVerificationSuccess(jobId);
        this.kickDrain();
      } else {
        this.providerHealth.abandonManualVerification(jobId);
      }
      return this.repository.requireJobForUser(jobId, userId);
    } catch (error) {
      this.providerHealth.abandonManualVerification(jobId);
      this.repository.updateJob(jobId, userId, {
        status: 'FAILED',
        stage: 'manual_result_invalid',
        message: 'Le résultat du helper n’a pas pu être importé.',
        errorCode: 'MANUAL_VERIFICATION_RESULT_INVALID',
        errorMessage: 'Le fichier du helper est absent ou invalide.',
      });
      if (error instanceof AcquisitionImportServiceError) throw error;
      throw new AcquisitionImportServiceError(
        'manual_result_invalid',
        'Le résultat du helper est absent ou invalide.',
      );
    } finally {
      if (this.isConfined(this.interactiveStagingRoot, stagingDirectory)) {
        await rm(stagingDirectory, {
          recursive: true,
          force: true,
        }).catch(() => undefined);
      }
    }
  }

  async applyMonochromeManualResult(
    jobId: string,
    userId: number,
    username: string,
    result: MonochromeManualResult,
  ): Promise<AcquisitionJobRow> {
    const job = this.repository.requireJobForUser(jobId, userId);
    if (job.status !== 'WAITING_MANUAL_DOWNLOAD') {
      throw new AcquisitionImportServiceError(
        'manual_result_invalid',
        'Ce job n’attend pas de résultat Monochrome.',
      );
    }
    try {
      this.monochromeSessions.requireReserved(jobId, userId);
    } catch (error) {
      if (error instanceof MonochromeManualSessionError) {
        throw new AcquisitionImportServiceError(
          'manual_result_invalid',
          error.message,
        );
      }
      throw error;
    }

    if (result === 'cancelled') {
      this.cancel(jobId, userId);
      return this.repository.requireJobForUser(jobId, userId);
    }
    if (result === 'dry_run_completed') {
      this.monochromeSessions.markResultReceived(jobId, userId);
      const updated = this.repository.updateJob(jobId, userId, {
        status: 'CANCELLED',
        stage: 'monochrome_diagnostic_completed',
        message: 'Diagnostic Monochrome terminé sans import.',
        errorCode: 'DRY_RUN_COMPLETED',
        errorMessage: 'Aucune écriture dans la bibliothèque.',
      });
      this.monochromeSessions.release(jobId, userId);
      return updated;
    }
    if (result === 'provider_error') {
      this.monochromeSessions.resetReservation(jobId, userId);
      return this.repository.updateJob(jobId, userId, {
        status: 'WAITING_MANUAL_DOWNLOAD',
        stage: 'waiting_manual_download',
        message:
          'Le helper Monochrome s’est arrêté. Tu peux relancer les instructions.',
        errorCode: null,
        errorMessage: null,
      });
    }
    if (result !== 'download_ready') {
      this.monochromeSessions.markResultReceived(jobId, userId);
      const code = {
        timeout: 'MONOCHROME_MANUAL_TIMEOUT',
        no_exact_match: 'MONOCHROME_NO_EXACT_MATCH',
        ambiguous_match: 'MONOCHROME_AMBIGUOUS_MATCH',
        file_rejected: 'MONOCHROME_FILE_REJECTED',
      }[result];
      const updated = this.repository.updateJob(jobId, userId, {
        status: result === 'timeout' ? 'FAILED' : 'FAILED',
        stage: 'monochrome_failed',
        message: 'Le fallback Monochrome n’a pas produit de fichier valide.',
        errorCode: code,
        errorMessage:
          'Le fallback manuel est terminé sans fichier importable.',
      });
      this.monochromeSessions.release(jobId, userId);
      return updated;
    }

    this.monochromeSessions.markResultReceived(jobId, userId);
    const stagingDirectory = this.monochromeJobDirectory(jobId);
    try {
      this.repository.updateJob(jobId, userId, {
        status: 'VERIFYING',
        stage: 'verifying_manual_file',
        message: 'Vérification du fichier.',
        errorCode: null,
        errorMessage: null,
      });
      const source = await this.requireInteractiveAudioFile(
        stagingDirectory,
        this.monochromeStagingRoot,
      );
      const paths = await this.localImportService.ensureUserDirectory(
        userId,
        username,
      );
      const destination = resolve(paths.inbox, `${jobId}-${basename(source)}`);
      if (!this.isConfined(paths.inbox, destination)) {
        throw new AcquisitionImportServiceError(
          'manual_result_invalid',
          'Destination Monochrome invalide.',
        );
      }
      await rename(source, destination);
      this.repository.updateJob(jobId, userId, {
        status: 'IMPORTING',
        stage: 'local_import',
        progress: 100,
        message: 'Importation.',
        downloadedRelativePath: basename(destination),
      });
      const localImportJobId =
        await this.localImportService.processInboxFile(userId, destination);
      const localJob = this.handle.db
        .select()
        .from(importJobs)
        .where(
          and(
            eq(importJobs.id, localImportJobId),
            eq(importJobs.userId, userId),
          ),
        )
        .get();
      if (!localJob) {
        throw new AcquisitionImportServiceError(
          'manual_result_invalid',
          'Le pipeline local n’a pas retourné de job.',
        );
      }
      this.finalizeFromLocalImport(
        {
          jobId,
          userId,
          username,
          query: job.query,
          resultIndex: job.resultIndex ?? 0,
          downloadTimeoutSeconds: 75,
          downloadRetries: Math.max(0, job.maxAttempts - 1),
        },
        localImportJobId,
        localJob.status as ImportJobStatus,
        localJob.trackId,
        localJob.errorMessage,
      );
      const completed = this.repository.requireJobForUser(jobId, userId);
      if (completed.status !== 'COMPLETED' || completed.trackId === null) {
        throw new AcquisitionImportServiceError(
          'manual_result_invalid',
          'Un trackId réel est requis avant la fin du fallback.',
        );
      }
      this.monochromeSessions.release(jobId, userId);
      return completed;
    } catch (error) {
      this.monochromeSessions.release(jobId, userId);
      const current = this.repository.requireJobForUser(jobId, userId);
      if (current.status !== 'FAILED') {
        this.repository.updateJob(jobId, userId, {
          status: 'FAILED',
          stage: 'monochrome_file_rejected',
          message: 'Le fichier Monochrome a été rejeté.',
          errorCode: 'MONOCHROME_FILE_REJECTED',
          errorMessage: 'Le pipeline local a rejeté le fichier.',
        });
      }
      if (error instanceof AcquisitionImportServiceError) throw error;
      throw new AcquisitionImportServiceError(
        'manual_result_invalid',
        'Le fichier Monochrome est absent ou invalide.',
      );
    } finally {
      if (this.isConfined(this.monochromeStagingRoot, stagingDirectory)) {
        await rm(stagingDirectory, { recursive: true, force: true }).catch(
          () => undefined,
        );
      }
    }
  }

  queuedCount(): number {
    return this.queue.length;
  }

  /** Premier job actif — conservé pour les appels historiques. */
  activeJobId(): string | null {
    for (const running of this.active.values()) {
      return running.item.jobId;
    }
    return null;
  }

  activeJobIds(): string[] {
    return [...this.active.keys()];
  }

  activeCount(): number {
    return this.active.size;
  }

  /** Nombre de téléchargements simultanés autorisés. */
  concurrencyLimit(): number {
    return this.maxConcurrent;
  }

  async waitForIdle(): Promise<void> {
    while (this.workers.size > 0) {
      await Promise.all([...this.workers]);
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

    for (const running of this.active.values()) {
      running.controller.abort();
    }
    this.runner.stopAll();
    await this.waitForIdle();
  }

  /**
   * Occupe autant de créneaux libres que la file le permet.
   *
   * Appelée à chaque `enqueue` et à la fin de chaque job : c'est le seul point
   * qui décide de démarrer du travail.
   */
  private kickDrain(): void {
    if (this.stopped) return;
    const provider = this.providerHealth.get();
    if (
      provider.state !== 'CLOSED' &&
      provider.state !== 'HALF_OPEN'
    ) {
      return;
    }

    while (
      this.workers.size < this.maxConcurrent &&
      this.queue.length > 0
    ) {
      const worker = this.runWorker()
        .catch((error: unknown) => {
          // Chaque job est normalement isolé dans processItem. Cette branche
          // protège la file contre une erreur de programmation inattendue.
          console.error('échec inattendu de la file acquisition', {
            error:
              error instanceof Error ? error.message : 'Erreur inconnue.',
          });
        })
        .finally(() => {
          this.workers.delete(worker);
          if (!this.stopped && this.queue.length > 0) {
            this.kickDrain();
          }
        });

      this.workers.add(worker);
    }
  }

  /**
   * Un créneau de parallélisme : consomme la file jusqu'à épuisement.
   *
   * Plusieurs workers tournent en parallèle mais partagent la même file, donc
   * l'ordre de PRISE reste FIFO.
   */
  private async runWorker(): Promise<void> {
    while (!this.stopped && this.queue.length > 0) {
      const provider = this.providerHealth.get();
      if (
        provider.state !== 'CLOSED' &&
        provider.state !== 'HALF_OPEN'
      ) {
        return;
      }
      const item = this.queue.shift();
      if (!item) return;
      if (
        provider.state === 'HALF_OPEN' &&
        provider.halfOpenProbeJobId !== item.jobId
      ) {
        continue;
      }

      const current = this.repository.getJobForUser(item.jobId, item.userId);
      if (
        !current ||
        current.cancelRequested ||
        current.status !== 'QUEUED'
      ) {
        continue;
      }

      const controller = new AbortController();
      this.active.set(item.jobId, { item, controller });

      try {
        await this.waitForStartSlot(controller.signal);
        if (this.stopped || controller.signal.aborted) {
          this.failItem(
            item,
            new LucidaProcessError('CANCELLED', 'Import annulé.'),
          );
          continue;
        }
        const result = await this.processItem(item, controller.signal);
        if (result.state === 'MANUAL_VERIFICATION_REQUIRED') return;
      } catch (error) {
        const result = this.failItem(item, error);
        if (result.state === 'MANUAL_VERIFICATION_REQUIRED') return;
      } finally {
        this.active.delete(item.jobId);
      }
    }
  }

  /**
   * Échelonne les démarrages pour ne jamais émettre une rafale simultanée
   * vers le service distant.
   */
  private async waitForStartSlot(signal: AbortSignal): Promise<void> {
    if (this.staggerMs <= 0) return;

    const jitter = Math.floor(Math.random() * START_STAGGER_JITTER_MS);
    const earliest = this.lastStartAt + this.staggerMs + jitter;
    const wait = earliest - Date.now();
    this.lastStartAt = Math.max(Date.now(), earliest);
    if (wait <= 0) return;

    await new Promise<void>((resolvePromise) => {
      const timer = setTimeout(finish, wait);
      function finish(): void {
        clearTimeout(timer);
        signal.removeEventListener('abort', finish);
        resolvePromise();
      }
      signal.addEventListener('abort', finish, { once: true });
    });
  }

  private async processItem(
    item: QueuedAcquisition,
    signal: AbortSignal,
  ): Promise<AcquisitionHandlingResult> {
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
    this.providerHealth.recordProbeSuccess(item.jobId);

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
    const completed = this.repository.requireJobForUser(
      item.jobId,
      item.userId,
    );
    return {
      handled: true,
      terminal: completed.status === 'COMPLETED',
      state: completed.status as AcquisitionJobStatus,
    };
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
          message: 'Résultat Qobuz sélectionné.',
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
        if (this.isProviderFailureCode(event.code)) break;
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
  ): boolean {
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
        return true;

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
        return false;

      case 'REJECTED':
        this.repository.updateJob(item.jobId, item.userId, {
          status: 'FAILED',
          stage: 'local_import_rejected',
          message: 'Le fichier a été rejeté par le pipeline local.',
          localImportJobId,
          errorCode: 'LOCAL_IMPORT_REJECTED',
          errorMessage: localError ?? 'Import local rejeté.',
        });
        return false;

      case 'FAILED':
        this.repository.updateJob(item.jobId, item.userId, {
          status: 'FAILED',
          stage: 'local_import_failed',
          message: 'L’import local a échoué.',
          localImportJobId,
          errorCode: 'LOCAL_IMPORT_FAILED',
          errorMessage: localError ?? 'Échec du pipeline local.',
        });
        return false;

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
        return false;
    }
  }

  private failItem(
    item: QueuedAcquisition,
    error: unknown,
  ): AcquisitionHandlingResult {
    const row = this.repository.getJobForUser(
      item.jobId,
      item.userId,
    );
    if (!row) {
      return { handled: true, terminal: true, state: 'FAILED' };
    }
    if (row.status === 'MANUAL_VERIFICATION_REQUIRED') {
      return {
        handled: true,
        terminal: false,
        state: 'MANUAL_VERIFICATION_REQUIRED',
      };
    }
    if (row.status === 'WAITING_MANUAL_DOWNLOAD') {
      return {
        handled: true,
        terminal: false,
        state: 'WAITING_MANUAL_DOWNLOAD',
      };
    }

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
      return { handled: true, terminal: true, state: 'INTERRUPTED' };
    }

    if (cancelled || row.cancelRequested) {
      this.repository.updateJob(item.jobId, item.userId, {
        status: 'CANCELLED',
        stage: 'cancelled',
        message: 'Import annulé.',
        errorCode: 'CANCELLED',
        errorMessage: 'Annulé par l’utilisateur.',
      });
      this.providerHealth.releaseProbe(item.jobId);
      return { handled: true, terminal: true, state: 'CANCELLED' };
    }

    const code =
      error instanceof LucidaProcessError
        ? error.code
        : 'INTERNAL_ERROR';
    const message =
      error instanceof Error
        ? error.message
        : 'Erreur d’acquisition inconnue.';

    if (
      this.monochromeFallbackEnabled &&
      isMonochromeFallbackEligible(String(code), row)
    ) {
      try {
        this.monochromeSessions.offer(
          item.jobId,
          item.userId,
          String(code),
        );
        return {
          handled: true,
          terminal: false,
          state: 'WAITING_MANUAL_DOWNLOAD',
        };
      } catch (fallbackError) {
        if (
          fallbackError instanceof MonochromeManualSessionError &&
          fallbackError.code === 'holder_busy'
        ) {
          this.repository.updateJob(item.jobId, item.userId, {
            status: 'PAUSED_PROVIDER',
            stage: 'monochrome_holder_busy',
            message:
              'Une autre session Monochrome est déjà en attente sur le serveur.',
            errorCode: String(code),
            errorMessage:
              'Le fallback Monochrome global est déjà réservé.',
          });
          return {
            handled: true,
            terminal: false,
            state: 'PAUSED_PROVIDER',
          };
        }
        throw fallbackError;
      }
    }

    if (this.isProviderFailureCode(String(code))) {
      if (
        code === 'PROVIDER_CHALLENGE' &&
        this.interactiveVerificationEnabled
      ) {
        return this.providerHealth.transitionChallengeToManual(
          item.jobId,
          item.userId,
        );
      }
      const health = this.providerHealth.recordFailure(
        code as ProviderFailureCode,
        error instanceof LucidaProcessError
          ? error.details.retryAfterSeconds
          : undefined,
      );
      if (
        code === 'PROVIDER_UNAVAILABLE' &&
        health.state === 'CLOSED'
      ) {
        this.repository.updateJob(item.jobId, item.userId, {
          status: 'FAILED',
          stage: 'failed',
          message: 'Le fournisseur est temporairement indisponible.',
          errorCode: String(code),
          errorMessage: 'Le fournisseur est temporairement indisponible.',
        });
        return { handled: true, terminal: true, state: 'FAILED' };
      }
      const publicMessage =
        health.publicMessage ?? 'Le service est temporairement en pause.';
      this.repository.updateJob(item.jobId, item.userId, {
        status: 'PAUSED_PROVIDER',
        stage: 'provider_paused',
        message: publicMessage,
        errorCode: String(code),
        errorMessage: publicMessage,
      });
      if (health.state === 'OPEN') {
        this.repository.pauseQueuedJobs(String(code), publicMessage);
      }
      return {
        handled: true,
        terminal: false,
        state: 'PAUSED_PROVIDER',
      };
    }

    this.repository.updateJob(item.jobId, item.userId, {
      status: 'FAILED',
      stage: 'failed',
      message: 'L’acquisition a échoué.',
      errorCode: String(code).slice(0, 100),
      errorMessage: message.slice(0, 500),
    });
    return { handled: true, terminal: true, state: 'FAILED' };
  }

  private isProviderFailureCode(code: string): code is ProviderFailureCode {
    return (
      code === 'PROVIDER_CHALLENGE' ||
      code === 'PROVIDER_RATE_LIMITED' ||
      code === 'PROVIDER_UNAVAILABLE'
    );
  }

  private interactiveJobDirectory(jobId: string): string {
    const directory = resolve(this.interactiveStagingRoot, jobId);
    if (!this.isConfined(this.interactiveStagingRoot, directory)) {
      throw new AcquisitionImportServiceError(
        'manual_result_invalid',
        'Dossier de résultat interactif invalide.',
      );
    }
    return directory;
  }

  private monochromeJobDirectory(jobId: string): string {
    const directory = resolve(this.monochromeStagingRoot, jobId);
    if (!this.isConfined(this.monochromeStagingRoot, directory)) {
      throw new AcquisitionImportServiceError(
        'manual_result_invalid',
        'Dossier Monochrome invalide.',
      );
    }
    return directory;
  }

  private async requireInteractiveAudioFile(
    directory: string,
    allowedRoot = this.interactiveStagingRoot,
  ): Promise<string> {
    const directoryStat = await lstat(directory).catch(() => null);
    if (
      !directoryStat ||
      !directoryStat.isDirectory() ||
      directoryStat.isSymbolicLink()
    ) {
      throw new AcquisitionImportServiceError(
        'manual_result_invalid',
        'Dossier de résultat interactif absent ou invalide.',
      );
    }
    const entries = await readdir(directory, { withFileTypes: true });
    const candidates = entries.filter((entry) => {
      if (!entry.isFile()) return false;
      const extension = extname(entry.name).toLocaleLowerCase('en-US');
      return extension === '.wav' || extension === '.flac';
    });
    if (candidates.length !== 1) {
      throw new AcquisitionImportServiceError(
        'manual_result_invalid',
        'Le helper doit produire exactement un fichier WAV ou FLAC.',
      );
    }
    const candidate = resolve(directory, candidates[0]!.name);
    const [realRoot, realCandidate] = await Promise.all([
      realpath(allowedRoot),
      realpath(candidate),
    ]);
    if (!this.isConfined(realRoot, realCandidate)) {
      throw new AcquisitionImportServiceError(
        'manual_result_invalid',
        'Le fichier du helper sort du dossier autorisé.',
      );
    }
    const fileStat = await lstat(realCandidate);
    if (
      !fileStat.isFile() ||
      fileStat.isSymbolicLink() ||
      fileStat.size < 1
    ) {
      throw new AcquisitionImportServiceError(
        'manual_result_invalid',
        'Le fichier du helper est vide ou invalide.',
      );
    }
    return realCandidate;
  }

  private isConfined(root: string, candidate: string): boolean {
    const rel = relative(resolve(root), resolve(candidate));
    return (
      rel === '' ||
      (!rel.startsWith('..') && !isAbsolute(rel))
    );
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

    const targetTitle = input.targetTitle?.trim();
    const targetArtist = input.targetArtist?.trim();
    const targetAlbum = input.targetAlbum?.trim();
    if (
      (targetTitle === undefined) !== (targetArtist === undefined) ||
      (targetTitle !== undefined &&
        (targetTitle.length < 1 ||
          targetTitle.length > 500 ||
          targetArtist!.length < 1 ||
          targetArtist!.length > 500))
    ) {
      throw new AcquisitionImportServiceError(
        'invalid_input',
        'La cible doit fournir un titre et un artiste valides.',
      );
    }
    if (targetAlbum !== undefined && targetAlbum.length > 500) {
      throw new AcquisitionImportServiceError(
        'invalid_input',
        'Album cible invalide.',
      );
    }
    if (
      input.targetDurationSeconds !== undefined &&
      (!Number.isInteger(input.targetDurationSeconds) ||
        input.targetDurationSeconds < 1 ||
        input.targetDurationSeconds > 86_400)
    ) {
      throw new AcquisitionImportServiceError(
        'invalid_input',
        'Durée cible invalide.',
      );
    }

    return {
      userId: input.userId,
      username,
      query,
      resultIndex: input.resultIndex,
      downloadTimeoutSeconds,
      downloadRetries,
      ...(targetTitle === undefined ? {} : { targetTitle }),
      ...(targetArtist === undefined ? {} : { targetArtist }),
      ...(targetAlbum ? { targetAlbum } : {}),
      ...(input.targetDurationSeconds === undefined
        ? {}
        : { targetDurationSeconds: input.targetDurationSeconds }),
    };
  }
}
