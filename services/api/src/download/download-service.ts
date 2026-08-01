import { mkdir, rename, rm, stat } from 'node:fs/promises';
import { basename, extname, join, relative, resolve } from 'node:path';
import { and, eq } from 'drizzle-orm';
import type { DbHandle } from '../db/client.js';
import {
  importJobs,
  type DownloadJobStatus,
  type ImportJobStatus,
} from '../db/schema.js';
import type { UserImportPaths } from '../import/user-import-service.js';
import {
  DownloadCandidateOrchestrator,
  type CandidateAttempt,
  type OrchestratorDecision,
} from './candidate-orchestrator.js';
import {
  TrackCandidateResolver,
  type DownloadCandidate,
  type ResolvedTrack,
} from './candidate-resolver.js';
import type { TrackSearchProvider } from './track-search.js';
import {
  DownloadJobRepository,
  DownloadJobRepositoryError,
  type DownloadJobRow,
} from './download-job-repository.js';
import {
  detectDownloadedFiles,
  isConfined,
  listTemporaryArtifacts,
  snapshotDirectoryKeys,
} from './downloaded-file-detector.js';
import type {
  DownloadHandle,
  DownloadProvider,
  DownloadProviderEvent,
  DownloadResult,
  DownloadStage,
  DownloadTrackInfo,
  ProviderHealth,
} from './download-provider.js';
import { sanitizeMessage, sanitizeShortField } from './log-sanitizer.js';

/** Borne dure : chaque unité = un interpréteur Python complet. */
export const MAX_CONCURRENT_DOWNLOADS = 4;

/**
 * Cadence maximale d'écriture de la progression en base.
 *
 * Antra émet des dizaines d'événements par seconde ; écrire chacun d'eux
 * transformerait SQLite en goulot pour un gain d'affichage nul.
 */
const PROGRESS_PERSIST_INTERVAL_MS = 400;

/** Sous-dossier de staging, à l'intérieur de la racine d'import. */
const STAGING_DIRECTORY_NAME = '.antra';

export interface DownloadLocalImportService {
  ensureUserDirectory(userId: number, username: string): Promise<UserImportPaths>;
  processInboxFile(userId: number, path: string): Promise<number>;
}

export interface DownloadServiceLogger {
  info(context: Record<string, unknown>, message: string): void;
  warn(context: Record<string, unknown>, message: string): void;
  error(context: Record<string, unknown>, message: string): void;
  debug(context: Record<string, unknown>, message: string): void;
}

/** Événement diffusé aux abonnés SSE. Aucun chemin ni secret n'y figure. */
export type DownloadJobEvent =
  | { type: 'snapshot'; job: DownloadJobRow }
  | { type: 'progress'; job: DownloadJobRow }
  | { type: 'log'; jobId: string; level: string; message: string }
  | { type: 'completed'; job: DownloadJobRow }
  | { type: 'failed'; job: DownloadJobRow }
  | { type: 'cancelled'; job: DownloadJobRow };

export class DownloadServiceError extends Error {
  constructor(
    readonly code:
      | 'invalid_input'
      | 'service_stopped'
      | 'job_not_found'
      | 'active_duplicate'
      | 'not_retryable'
      | 'search_unavailable',
    message: string,
  ) {
    super(message);
    this.name = 'DownloadServiceError';
  }
}

interface QueuedDownload {
  jobId: string;
  userId: number;
  username: string;
  url: string;
}

interface ActiveDownload {
  item: QueuedDownload;
  handle: DownloadHandle | null;
  timeoutTimer: NodeJS.Timeout | null;
  cancelled: boolean;
}

/** Issue d'UNE tentative. `terminal` = le job est déjà finalisé. */
type AttemptOutcome =
  | { kind: 'terminal' }
  | { kind: 'cancelled' }
  | { kind: 'failed'; errorCode: string; errorMessage: string };

/**
 * Candidats d'un job. Un job « URL directe » en produit exactement un, ce qui
 * rend le parcours identique à l'ancien comportement.
 */
function candidatesForJob(
  job: DownloadJobRow | null,
  fallbackUrl: string,
): DownloadCandidate[] {
  const raw = job?.candidatesJson;
  if (typeof raw === 'string' && raw.length > 0) {
    try {
      const parsed: unknown = JSON.parse(raw);
      if (Array.isArray(parsed)) {
        const candidates = parsed.filter(isDownloadCandidate);
        if (candidates.length > 0) return candidates;
      }
    } catch {
      // JSON illisible (base modifiée à la main) : on retombe sur l'URL du job
      // plutôt que d'échouer, le comportement reste correct.
    }
  }
  return [
    {
      provider: 'manual',
      url: job?.normalizedUrl ?? fallbackUrl,
      title: job?.title ?? '',
      artist: job?.artist ?? '',
      album: job?.album ?? null,
      durationSeconds: null,
      isrc: null,
      confidence: 100,
      sourceRank: 100,
      artworkUrl: null,
    },
  ];
}

function isDownloadCandidate(value: unknown): value is DownloadCandidate {
  if (typeof value !== 'object' || value === null) return false;
  const record = value as Record<string, unknown>;
  return typeof record.url === 'string' && typeof record.provider === 'string';
}

/** Historique borné : les tentatives, jamais un journal complet. */
function serializeAttempts(attempts: readonly CandidateAttempt[]): string {
  return JSON.stringify(attempts.slice(-10));
}

const STATUS_BY_STAGE: Record<DownloadStage, DownloadJobStatus> = {
  queued: 'queued',
  resolving: 'resolving',
  selecting_source: 'resolving',
  downloading: 'downloading',
  processing: 'processing',
  importing: 'importing',
  completed: 'processing',
  failed: 'downloading',
  cancelled: 'cancelled',
};

/** Libellés français stables, indépendants de la langue des logs du moteur. */
const MESSAGE_BY_STAGE: Record<DownloadStage, string> = {
  queued: 'En attente.',
  resolving: 'Recherche de la musique.',
  selecting_source: 'Recherche de la meilleure source.',
  downloading: 'Téléchargement en cours.',
  processing: 'Traitement des métadonnées.',
  importing: 'Importation dans HomeSpotify.',
  completed: 'Traitement des métadonnées.',
  failed: 'Téléchargement en cours.',
  cancelled: 'Annulation.',
};

/**
 * Orchestre les téléchargements Antra puis remet le fichier au pipeline local.
 *
 * Règle fondamentale, identique à l'acquisition historique :
 * - `download_jobs` suit le processus du moteur ;
 * - `import_jobs` reste créé et finalisé UNIQUEMENT par `UserImportService`.
 *   Aucun second indexeur n'existe.
 */
export class DownloadService {
  private readonly queue: QueuedDownload[] = [];
  private readonly active = new Map<string, ActiveDownload>();
  private readonly workers = new Set<Promise<void>>();
  private readonly subscribers = new Map<
    string,
    Set<(event: DownloadJobEvent) => void>
  >();
  private readonly lastProgressPersistAt = new Map<string, number>();
  private readonly resolver = new TrackCandidateResolver();
  private stopped = false;

  constructor(
    private readonly handle: DbHandle,
    private readonly repository: DownloadJobRepository,
    private readonly provider: DownloadProvider,
    private readonly localImportService: DownloadLocalImportService,
    private readonly options: {
      /** Racine d'import : le staging vit dans `<importRoot>/.antra/<jobId>`. */
      importRoot: string;
      maxConcurrent: number;
      /** Budget TOTAL du job, toutes tentatives confondues. */
      jobTimeoutMs: number;
      /** Plafond d'UNE tentative ; sans lui, aucun repli n'aurait jamais lieu. */
      attemptTimeoutMs?: number;
      allowedExtensions: readonly string[];
      /**
       * Recherche texte. Absente = seules les URL directes sont acceptées ;
       * `/api/downloads/search` répond alors 503.
       */
      searchProvider?: TrackSearchProvider;
      logger?: DownloadServiceLogger;
      /** Injectable pour les tests : accélère l'attente de stabilité. */
      stabilityIntervalMs?: number;
      stabilityChecks?: number;
      maxStabilityChecks?: number;
    },
  ) {
    if (
      !Number.isInteger(options.maxConcurrent) ||
      options.maxConcurrent < 1 ||
      options.maxConcurrent > MAX_CONCURRENT_DOWNLOADS
    ) {
      throw new DownloadServiceError(
        'invalid_input',
        `maxConcurrent doit être un entier entre 1 et ${MAX_CONCURRENT_DOWNLOADS}.`,
      );
    }
  }

  /** Jobs laissés actifs par un ancien processus serveur → `interrupted`. */
  recoverInterruptedJobs(): number {
    return this.repository.markActiveJobsInterruptedOnStartup();
  }

  /** Crée un job et le met en file. Le doublon actif est refusé par la base. */
  enqueue(input: {
    userId: number;
    username: string;
    requestedUrl: string;
    normalizedUrl: string;
    /** `search` quand la demande vient d'une recherche texte résolue. */
    requestKind?: 'url' | 'search';
    /** Texte saisi, conservé pour l'historique et la relance. */
    query?: string | null;
    /** Chaîne de repli ordonnée. Absente = un seul candidat, l'URL du job. */
    candidates?: readonly DownloadCandidate[];
  }): DownloadJobRow {
    if (this.stopped) {
      throw new DownloadServiceError(
        'service_stopped',
        'Le service de téléchargement est arrêté.',
      );
    }

    let job: DownloadJobRow;
    try {
      job = this.repository.createJob({
        userId: input.userId,
        requestedUrl: input.requestedUrl,
        normalizedUrl: input.normalizedUrl,
        requestKind: input.requestKind ?? 'url',
        query: input.query ?? null,
        candidatesJson:
          input.candidates === undefined || input.candidates.length === 0
            ? null
            : JSON.stringify(input.candidates),
      });
    } catch (error) {
      throw toServiceError(error);
    }

    this.queue.push({
      jobId: job.id,
      userId: input.userId,
      username: input.username,
      url: job.requestedUrl,
    });
    this.kickDrain();
    return job;
  }

  /**
   * Identité de piste → candidats → job, en un seul appel.
   *
   * Deux régimes, décidés par la richesse de l'intention :
   *
   * - **Sélection épinglée** (`pinned`) : l'appelant a désigné une piste
   *   précise du catalogue et transmet son identité (titre, artiste, et selon
   *   les cas ISRC, durée, album). Il n'y a alors plus rien à trancher : la
   *   meilleure correspondance est téléchargée. Redemander un choix ici
   *   reviendrait à réintroduire une validation, ce que le produit exclut.
   * - **Texte libre seul** : le résolveur peut renvoyer `ambiguous`, et la
   *   décision revient à l'appelant — un import erroné pollue la bibliothèque
   *   durablement.
   */
  async enqueueFromSearch(input: {
    userId: number;
    username: string;
    query: string;
    title?: string | undefined;
    artist?: string | undefined;
    album?: string | undefined;
    isrc?: string | undefined;
    durationSeconds?: number | undefined;
  }): Promise<
    | { kind: 'queued'; job: DownloadJobRow; track: ResolvedTrack }
    | { kind: 'ambiguous'; options: ResolvedTrack[] }
    | { kind: 'no_match' }
  > {
    if (this.stopped) {
      throw new DownloadServiceError(
        'service_stopped',
        'Le service de téléchargement est arrêté.',
      );
    }
    const search = this.options.searchProvider;
    if (!search) {
      throw new DownloadServiceError(
        'search_unavailable',
        'La recherche musicale n’est pas configurée sur ce serveur.',
      );
    }

    // Une piste est « épinglée » dès que l'appelant fournit une preuve
    // d'identité : un ISRC, ou le couple titre + artiste.
    const pinned =
      (input.isrc !== undefined && input.isrc.length > 0) ||
      ((input.title?.trim().length ?? 0) > 0 && (input.artist?.trim().length ?? 0) > 0);

    const results = await search.searchTracks({ query: input.query });
    const resolution = this.resolver.resolve(
      results,
      {
        query: input.query,
        title: input.title,
        artist: input.artist,
        album: input.album,
      },
      {
        expectedIsrc: input.isrc ?? null,
        expectedDurationSeconds: input.durationSeconds ?? null,
      },
    );

    if (resolution.kind === 'no_match') return { kind: 'no_match' };
    if (resolution.kind === 'ambiguous') {
      if (!pinned) return { kind: 'ambiguous', options: resolution.options };
    }
    const track =
      resolution.kind === 'confident' ? resolution.track : resolution.options[0]!;

    const best = track.candidates[0]!;
    const job = this.enqueue({
      userId: input.userId,
      username: input.username,
      requestedUrl: best.url,
      normalizedUrl: best.url,
      requestKind: 'search',
      query: input.query,
      candidates: track.candidates,
    });
    return { kind: 'queued', job, track };
  }

  /** Recherche seule, sans effet de bord : aucun job n'est créé. */
  async searchTracks(query: string): Promise<ResolvedTrack[]> {
    const search = this.options.searchProvider;
    if (!search) {
      throw new DownloadServiceError(
        'search_unavailable',
        'La recherche musicale n’est pas configurée sur ce serveur.',
      );
    }
    const results = await search.searchTracks({ query });
    const resolution = this.resolver.resolve(results, { query });
    if (resolution.kind === 'no_match') return [];
    return resolution.kind === 'confident'
      ? [resolution.track, ...resolution.alternatives]
      : resolution.options;
  }

  /** Relance un job `failed`/`interrupted` sur la MÊME ligne, sans doublon. */
  retry(jobId: string, userId: number, username: string): DownloadJobRow {
    if (this.stopped) {
      throw new DownloadServiceError(
        'service_stopped',
        'Le service de téléchargement est arrêté.',
      );
    }
    let job: DownloadJobRow;
    try {
      job = this.repository.requeueForRetry(jobId, userId);
    } catch (error) {
      throw toServiceError(error);
    }

    this.queue.push({ jobId: job.id, userId, username, url: job.requestedUrl });
    this.kickDrain();
    return job;
  }

  getJobForUser(jobId: string, userId: number): DownloadJobRow | null {
    try {
      return this.repository.getJobForUser(jobId, userId);
    } catch (error) {
      throw toServiceError(error);
    }
  }

  listRecentForUser(
    userId: number,
    limit?: number,
    status?: DownloadJobStatus,
  ): DownloadJobRow[] {
    try {
      return this.repository.listRecentForUser(userId, limit, status);
    } catch (error) {
      throw toServiceError(error);
    }
  }

  /**
   * Annulation idempotente : marque la demande, retire de la file si le job n'a
   * pas démarré, et tue l'arbre de processus sinon.
   */
  async cancel(jobId: string, userId: number): Promise<boolean> {
    let accepted: boolean;
    try {
      accepted = this.repository.requestCancellation(jobId, userId);
    } catch (error) {
      throw toServiceError(error);
    }
    if (!accepted) return false;

    const queuedIndex = this.queue.findIndex((item) => item.jobId === jobId);
    if (queuedIndex >= 0) {
      this.queue.splice(queuedIndex, 1);
      this.finish(jobId, {
        status: 'cancelled',
        stage: 'cancelled',
        message: 'Téléchargement annulé.',
        errorCode: 'CANCELLED',
        errorMessage: 'Annulé avant le démarrage.',
      });
      return true;
    }

    const running = this.active.get(jobId);
    if (running && !running.cancelled) {
      running.cancelled = true;
      await this.provider.cancel(jobId);
    }
    return true;
  }

  health(): Promise<ProviderHealth> {
    return this.provider.healthCheck();
  }

  queuedCount(): number {
    return this.queue.length;
  }

  activeCount(): number {
    return this.active.size;
  }

  /** Abonnement SSE. Le retour désabonne — jamais de fuite d'écouteur. */
  subscribe(jobId: string, listener: (event: DownloadJobEvent) => void): () => void {
    const listeners = this.subscribers.get(jobId) ?? new Set();
    listeners.add(listener);
    this.subscribers.set(jobId, listeners);
    return () => {
      const current = this.subscribers.get(jobId);
      if (!current) return;
      current.delete(listener);
      if (current.size === 0) this.subscribers.delete(jobId);
    };
  }

  async stop(): Promise<void> {
    this.stopped = true;
    this.queue.length = 0;
    this.provider.stopAll();
    await Promise.allSettled([...this.workers]);
  }

  /** Attente utilisée par les tests : jamais appelée en production. */
  async waitForIdle(): Promise<void> {
    while (this.workers.size > 0) {
      await Promise.allSettled([...this.workers]);
    }
  }

  // --- file d'exécution ----------------------------------------------------

  private kickDrain(): void {
    if (this.stopped) return;
    while (this.workers.size < this.options.maxConcurrent && this.queue.length > 0) {
      const worker = this.runWorker()
        .catch((error: unknown) => {
          this.options.logger?.error(
            { err: error },
            'échec inattendu de la file de téléchargement',
          );
        })
        .finally(() => {
          this.workers.delete(worker);
          if (!this.stopped && this.queue.length > 0) this.kickDrain();
        });
      this.workers.add(worker);
    }
  }

  private async runWorker(): Promise<void> {
    while (!this.stopped && this.queue.length > 0) {
      const item = this.queue.shift();
      if (!item) return;

      // Relecture avant démarrage : le job a pu être annulé pendant l'attente.
      const current = this.repository.getJobForUser(item.jobId, item.userId);
      if (!current || current.cancelRequested || current.status !== 'queued') continue;
      if (this.active.has(item.jobId)) continue;

      const running: ActiveDownload = {
        item,
        handle: null,
        timeoutTimer: null,
        cancelled: false,
      };
      this.active.set(item.jobId, running);
      try {
        await this.processItem(running);
      } catch (error) {
        this.failFromError(item.jobId, error);
      } finally {
        if (running.timeoutTimer !== null) clearTimeout(running.timeoutTimer);
        this.active.delete(item.jobId);
        this.lastProgressPersistAt.delete(item.jobId);
      }
    }
  }

  /** Un dossier ISOLÉ par tentative : aucun mélange entre deux candidats. */
  private stagingDirFor(jobId: string, attemptOrder: number): string {
    return resolve(
      this.options.importRoot,
      STAGING_DIRECTORY_NAME,
      jobId,
      String(attemptOrder),
    );
  }

  /** Plafond d'une tentative, borné par le budget global restant. */
  private attemptTimeoutMs(): number {
    const configured = this.options.attemptTimeoutMs ?? this.options.jobTimeoutMs;
    return Math.max(1_000, Math.min(configured, this.options.jobTimeoutMs));
  }

  /**
   * Exécute le job en parcourant ses candidats jusqu'au premier succès.
   *
   * Un job « URL directe » n'a qu'un candidat : le parcours est alors
   * strictement équivalent à l'ancien comportement, ce qui préserve la
   * compatibilité de `POST /api/downloads { url }`.
   */
  private async processItem(running: ActiveDownload): Promise<void> {
    const { item } = running;
    const paths = await this.localImportService.ensureUserDirectory(
      item.userId,
      item.username,
    );

    const job = this.repository.getJobForUser(item.jobId, item.userId);
    const candidates = candidatesForJob(job, item.url);
    if (candidates.length === 0) {
      this.finish(item.jobId, {
        status: 'failed',
        stage: 'failed',
        message: 'Aucune source exploitable pour cette demande.',
        errorCode: 'NO_CANDIDATE',
        errorMessage: 'Aucun lien compatible n’a pu être retenu.',
      });
      return;
    }

    this.update(item.jobId, {
      status: 'resolving',
      stage: 'resolving',
      progress: 0,
      message: MESSAGE_BY_STAGE.resolving,
      errorCode: null,
      errorMessage: null,
      attempt: (job?.attempt ?? 0) + 1,
    });

    const orchestrator = new DownloadCandidateOrchestrator(candidates, {
      deadlineAt: Date.now() + this.options.jobTimeoutMs,
    });
    let lastErrorCode: string | null = null;
    let lastErrorMessage: string | null = null;

    for (;;) {
      const decision = orchestrator.next({
        cancelled: running.cancelled || this.wasCancellationRequested(item),
        lastErrorCode,
      });

      if (decision.candidate === null) {
        this.finalizeChain(item, decision.stopReason, lastErrorCode, lastErrorMessage);
        // Une annulation peut laisser un fichier complet non importé : la règle
        // « ne jamais détruire un enregistrement valide » prime, on ne purge
        // donc pas dans ce cas.
        if (decision.stopReason !== 'cancelled') {
          await this.purgeJobStaging(item.jobId);
        }
        return;
      }

      const candidate = decision.candidate;
      const order = orchestrator.beginAttempt(candidate, new Date().toISOString());
      // Le suivi doit dire QUELLE source est tentée : sans cela, un repli
      // ressemble à un blocage.
      this.update(item.jobId, {
        selectedProvider: candidate.provider,
        selectedUrl: candidate.url,
        attemptsJson: serializeAttempts(orchestrator.history()),
        ...(candidate.title ? { title: candidate.title } : {}),
        ...(candidate.artist ? { artist: candidate.artist } : {}),
        ...(candidate.album ? { album: candidate.album } : {}),
        message:
          order === 1
            ? MESSAGE_BY_STAGE.resolving
            : `Tentative d’une autre source (${candidate.provider}).`,
      });

      const outcome = await this.runAttempt(running, candidate, paths, order);
      orchestrator.endAttempt(
        order,
        outcome.kind === 'terminal'
          ? 'succeeded'
          : outcome.kind === 'cancelled'
            ? 'cancelled'
            : 'failed',
        outcome.kind === 'failed' ? outcome.errorCode : null,
        new Date().toISOString(),
      );
      this.update(item.jobId, {
        attemptsJson: serializeAttempts(orchestrator.history()),
      });

      // Le pipeline local a déjà tranché (succès ou refus local) : relancer une
      // autre source risquerait un doublon.
      if (outcome.kind === 'terminal') {
        await this.purgeJobStaging(item.jobId);
        return;
      }
      if (outcome.kind === 'cancelled') {
        this.finalizeChain(item, 'cancelled', 'CANCELLED', null);
        return;
      }
      lastErrorCode = outcome.errorCode;
      lastErrorMessage = outcome.errorMessage;
    }
  }

  /** Clôture le job quand plus aucun candidat ne peut être tenté. */
  private finalizeChain(
    item: QueuedDownload,
    stopReason: OrchestratorDecision['stopReason'],
    lastErrorCode: string | null,
    lastErrorMessage: string | null,
  ): void {
    if (stopReason === 'cancelled') {
      this.finish(item.jobId, {
        status: 'cancelled',
        stage: 'cancelled',
        message: 'Téléchargement annulé.',
        errorCode: 'CANCELLED',
        errorMessage: 'Annulé à votre demande.',
      });
      return;
    }
    if (stopReason === 'global_timeout') {
      this.finish(item.jobId, {
        status: 'failed',
        stage: 'failed',
        message: 'Le téléchargement a dépassé le délai autorisé.',
        errorCode: 'TIMEOUT',
        errorMessage: 'Le téléchargement a dépassé le délai autorisé.',
      });
      return;
    }
    this.finish(item.jobId, {
      status: 'failed',
      stage: 'failed',
      message:
        stopReason === 'exhausted'
          ? 'Aucune source n’a pu fournir cette piste.'
          : 'Le téléchargement a échoué.',
      errorCode: lastErrorCode ?? 'ENGINE_FAILED',
      errorMessage:
        lastErrorMessage ?? 'Le moteur de téléchargement a échoué.',
    });
  }

  /**
   * UNE tentative : un candidat, un dossier de staging isolé, un processus.
   *
   * Ne finalise le job QUE lorsque le pipeline local a tranché ; un échec
   * technique est remonté à l'appelant, qui décide du repli.
   */
  private async runAttempt(
    running: ActiveDownload,
    candidate: DownloadCandidate,
    paths: UserImportPaths,
    order: number,
  ): Promise<AttemptOutcome> {
    const { item } = running;
    const stagingDir = this.stagingDirFor(item.jobId, order);
    if (!isConfined(this.options.importRoot, stagingDir)) {
      throw new Error('Dossier de staging hors de la racine autorisée.');
    }
    await mkdir(stagingDir, { recursive: true });
    // Inventaire AVANT lancement : c'est lui qui rend la détection non ambiguë.
    const knownPaths = await snapshotDirectoryKeys(stagingDir);

    // La préparation ci-dessus est asynchrone : une annulation a pu arriver
    // entre la prise du job par le worker et cet instant. Sans ce contrôle, on
    // lancerait un processus que plus personne n'annulera, et le job resterait
    // bloqué jusqu'au délai global.
    if (running.cancelled || this.wasCancellationRequested(item)) {
      await this.cleanupTemporaryArtifacts(stagingDir);
      return { kind: 'cancelled' };
    }

    const track: DownloadTrackInfo = {
      ...(candidate.durationSeconds === null
        ? {}
        : { durationSeconds: candidate.durationSeconds }),
    };
    const handle = await this.provider.start({
      jobId: item.jobId,
      url: candidate.url,
      outputDir: stagingDir,
    });
    running.handle = handle;
    // Deuxième garde : `start` est lui aussi asynchrone. Un processus démarré
    // juste après une demande d'annulation doit être arrêté tout de suite.
    if (running.cancelled || this.wasCancellationRequested(item)) {
      running.cancelled = true;
      await this.provider.cancel(item.jobId);
    }
    if (handle.processId > 0) {
      this.update(item.jobId, { processId: handle.processId });
    }

    const unsubscribe = handle.onEvent((event) => {
      this.applyProviderEvent(item, event, track);
    });

    // Délai de CETTE tentative, borné par ce qu'il reste du budget global :
    // sans plafond par tentative, le premier candidat consommerait tout et
    // aucun repli n'aurait jamais lieu.
    let timedOut = false;
    running.timeoutTimer = setTimeout(() => {
      timedOut = true;
      this.options.logger?.warn(
        { jobId: item.jobId, attempt: order, provider: candidate.provider },
        'téléchargement : délai de la tentative dépassé, arrêt du processus',
      );
      void this.provider.cancel(item.jobId);
    }, this.attemptTimeoutMs());
    running.timeoutTimer.unref();

    let result: DownloadResult;
    try {
      result = await handle.completion;
    } finally {
      unsubscribe();
      if (running.timeoutTimer !== null) clearTimeout(running.timeoutTimer);
      running.timeoutTimer = null;
    }

    // L'annulation utilisateur est vérifiée AVANT le délai : un utilisateur qui
    // annule ne doit jamais voir « délai dépassé », ni déclencher un repli.
    if (running.cancelled || this.wasCancellationRequested(item)) {
      await this.cleanupTemporaryArtifacts(stagingDir);
      return { kind: 'cancelled' };
    }

    if (timedOut) {
      await this.cleanupTemporaryArtifacts(stagingDir);
      return {
        kind: 'failed',
        errorCode: 'ATTEMPT_TIMEOUT',
        errorMessage: 'Cette source n’a pas répondu dans le délai autorisé.',
      };
    }

    if (!result.ok) {
      await this.cleanupTemporaryArtifacts(stagingDir);
      return {
        kind: 'failed',
        errorCode: result.errorCode ?? 'ENGINE_FAILED',
        errorMessage:
          result.errorMessage ?? 'Le moteur de téléchargement a échoué.',
      };
    }

    this.update(item.jobId, {
      status: 'processing',
      stage: 'validating',
      progress: 95,
      message: 'Vérification du fichier téléchargé.',
    });

    const detection = await detectDownloadedFiles(stagingDir, {
      allowedExtensions: this.options.allowedExtensions,
      knownPaths,
      expectedDurationSeconds: track.durationSeconds ?? null,
      ...(this.options.stabilityIntervalMs === undefined
        ? {}
        : { stabilityIntervalMs: this.options.stabilityIntervalMs }),
      ...(this.options.stabilityChecks === undefined
        ? {}
        : { stabilityChecks: this.options.stabilityChecks }),
      ...(this.options.maxStabilityChecks === undefined
        ? {}
        : { maxStabilityChecks: this.options.maxStabilityChecks }),
    });

    if (detection.accepted.length === 0) {
      const firstRejection = detection.rejected[0];
      this.options.logger?.warn(
        {
          jobId: item.jobId,
          attempt: order,
          provider: candidate.provider,
          rejected: detection.rejected.map((entry) => entry.reasonCode),
        },
        'téléchargement : aucun fichier exploitable détecté',
      );
      await this.cleanupTemporaryArtifacts(stagingDir);
      // Un extrait ou un fichier illisible est un échec DE CETTE SOURCE : une
      // autre peut très bien fournir la piste complète.
      return {
        kind: 'failed',
        errorCode: firstRejection?.reasonCode.toUpperCase() ?? 'NO_FILE_DETECTED',
        errorMessage:
          firstRejection?.reason ??
          'Le moteur n’a produit aucun fichier audio valide.',
      };
    }

    this.update(item.jobId, {
      status: 'importing',
      stage: 'local_import',
      progress: 98,
      message: MESSAGE_BY_STAGE.importing,
    });

    await this.importDetectedFiles(item, paths, detection.accepted.map((f) => f.absolutePath));
    await this.cleanupStagingIfEmpty(stagingDir);
    // `importDetectedFiles` a finalisé le job (succès ou refus local) : la
    // chaîne de repli s'arrête là, sous peine de doublon.
    return { kind: 'terminal' };
  }

  /**
   * Déplace chaque fichier validé dans l'inbox du compte, puis délègue à
   * `UserImportService`. La déduplication (sha256, ISRC, titre+artiste+durée)
   * est celle du pipeline existant : rien n'est réimplémenté ici.
   */
  private async importDetectedFiles(
    item: QueuedDownload,
    paths: UserImportPaths,
    files: readonly string[],
  ): Promise<void> {
    let importedTrackId: number | null = null;
    let lastImportJobId: number | null = null;
    let lastStatus: ImportJobStatus | null = null;
    let lastError: string | null = null;
    let outputPath: string | null = null;

    for (const file of files) {
      const destination = await this.moveIntoInbox(paths.inbox, file);
      outputPath = relative(resolve(this.options.importRoot), destination);

      const localJobId = await this.localImportService.processInboxFile(
        item.userId,
        destination,
      );
      const localJob = this.handle.db
        .select()
        .from(importJobs)
        .where(and(eq(importJobs.id, localJobId), eq(importJobs.userId, item.userId)))
        .get();
      if (!localJob) continue;

      lastImportJobId = localJobId;
      lastStatus = localJob.status as ImportJobStatus;
      lastError = localJob.errorMessage;
      if (localJob.trackId !== null && importedTrackId === null) {
        importedTrackId = localJob.trackId;
      }
    }

    if (lastStatus === null) {
      this.finish(item.jobId, {
        status: 'failed',
        stage: 'failed',
        message: 'L’import local n’a pas abouti.',
        errorCode: 'LOCAL_IMPORT_JOB_MISSING',
        errorMessage: 'Le pipeline local n’a pas retourné de job valide.',
      });
      return;
    }

    switch (lastStatus) {
      case 'IMPORTED':
      case 'REUSED':
        if (importedTrackId === null) {
          this.finish(item.jobId, {
            status: 'failed',
            stage: 'failed',
            message: 'L’import local s’est terminé sans piste.',
            errorCode: 'LOCAL_IMPORT_TRACK_MISSING',
            errorMessage: 'Le pipeline local a terminé sans identifiant de piste.',
          });
          return;
        }
        this.finish(item.jobId, {
          status: 'completed',
          // `reused` est une ÉTAPE distincte, pas un échec : elle permet à
          // l'application de dire « déjà présent » sans deviner à partir d'un
          // libellé traduit.
          stage: lastStatus === 'REUSED' ? 'reused' : 'completed',
          progress: 100,
          message:
            lastStatus === 'REUSED'
              ? 'Ce titre est déjà présent dans votre bibliothèque.'
              : 'Piste ajoutée à votre bibliothèque.',
          localImportJobId: lastImportJobId,
          trackId: importedTrackId,
          outputPath,
        });
        return;

      case 'WAITING_FOR_OWNER_MATCH':
        this.finish(item.jobId, {
          status: 'failed',
          stage: 'owner_review_required',
          message: 'Une validation manuelle est nécessaire.',
          localImportJobId: lastImportJobId,
          errorCode: 'LOCAL_IMPORT_REVIEW_REQUIRED',
          errorMessage:
            'Le fichier a été téléchargé mais le rapprochement local est ambigu.',
          outputPath,
        });
        return;

      default:
        this.finish(item.jobId, {
          status: 'failed',
          stage: 'local_import_failed',
          message: 'L’import local a échoué.',
          localImportJobId: lastImportJobId,
          errorCode: 'LOCAL_IMPORT_FAILED',
          errorMessage: sanitizeMessage(lastError) ?? 'Échec du pipeline local.',
          outputPath,
        });
    }
  }

  private async moveIntoInbox(inbox: string, source: string): Promise<string> {
    await mkdir(inbox, { recursive: true });
    const extension = extname(source);
    const stem = basename(source, extension);
    let destination = join(inbox, basename(source));
    try {
      await stat(destination);
      destination = join(inbox, `${stem}-${Date.now()}${extension}`);
    } catch {
      // Destination libre.
    }
    if (!isConfined(inbox, destination)) {
      throw new Error('Destination d’import hors de l’inbox autorisée.');
    }
    await rename(source, destination);
    return destination;
  }

  /**
   * Supprime UNIQUEMENT les fichiers temporaires du staging du job. Un fichier
   * audio complet n'est jamais détruit : il reste consultable côté serveur.
   */
  private async cleanupTemporaryArtifacts(stagingDir: string): Promise<void> {
    if (!isConfined(this.options.importRoot, stagingDir)) return;
    for (const path of await listTemporaryArtifacts(stagingDir)) {
      await rm(path, { force: true }).catch(() => undefined);
    }
  }

  /**
   * Supprime l'arborescence de staging du job une fois celui-ci terminé.
   *
   * Les fichiers ACCEPTÉS ont déjà été DÉPLACÉS dans l'inbox du compte : il ne
   * reste ici que des rebuts (sources rejetées, formats hors specs). Sans cette
   * purge, chaque tentative écartée immobiliserait plusieurs dizaines de Mo
   * indéfiniment. Jamais appelée après une annulation.
   */
  private async purgeJobStaging(jobId: string): Promise<void> {
    const jobDir = resolve(this.options.importRoot, STAGING_DIRECTORY_NAME, jobId);
    if (!isConfined(this.options.importRoot, jobDir)) return;
    await rm(jobDir, { recursive: true, force: true }).catch(() => undefined);
  }

  /** Retire le dossier de staging s'il ne contient plus rien d'utile. */
  private async cleanupStagingIfEmpty(stagingDir: string): Promise<void> {
    if (!isConfined(this.options.importRoot, stagingDir)) return;
    const remaining = await snapshotDirectoryKeys(stagingDir);
    if (remaining.size > 0) return;
    await rm(stagingDir, { recursive: true, force: true }).catch(() => undefined);
  }

  private wasCancellationRequested(item: QueuedDownload): boolean {
    return (
      this.repository.getJobForUser(item.jobId, item.userId)?.cancelRequested === true
    );
  }

  // --- traduction des événements moteur ------------------------------------

  private applyProviderEvent(
    item: QueuedDownload,
    event: DownloadProviderEvent,
    track: DownloadTrackInfo,
  ): void {
    switch (event.type) {
      case 'log':
        // Les logs bruts ne sont JAMAIS persistés : ils sont diffusés tels
        // quels aux abonnés (déjà assainis) et journalisés en debug.
        this.emit(item.jobId, {
          type: 'log',
          jobId: item.jobId,
          level: event.level,
          message: event.message,
        });
        this.options.logger?.debug(
          { jobId: item.jobId, level: event.level },
          event.message,
        );
        return;

      case 'track':
        Object.assign(track, event.track);
        this.update(item.jobId, trackFields(event.track));
        return;

      case 'stage': {
        if (event.track) Object.assign(track, event.track);
        this.update(item.jobId, {
          status: STATUS_BY_STAGE[event.stage],
          stage: event.stage,
          message: MESSAGE_BY_STAGE[event.stage],
          ...(event.track ? trackFields(event.track) : {}),
        });
        return;
      }

      case 'progress': {
        if (event.track) Object.assign(track, event.track);
        // Écriture bornée : la progression est un confort d'affichage, pas une
        // donnée dont chaque incrément doit survivre à un crash.
        const now = Date.now();
        const last = this.lastProgressPersistAt.get(item.jobId) ?? 0;
        if (now - last < PROGRESS_PERSIST_INTERVAL_MS && event.percent < 100) return;
        this.lastProgressPersistAt.set(item.jobId, now);
        this.update(item.jobId, {
          progress: Math.max(0, Math.min(100, Math.round(event.percent))),
          ...(event.stage === undefined
            ? {}
            : { status: STATUS_BY_STAGE[event.stage], stage: event.stage }),
          ...(event.track ? trackFields(event.track) : {}),
        });
        return;
      }

      case 'error':
        // Le code de sortie du moteur décide de l'état terminal ; on conserve
        // néanmoins le diagnostic structuré immédiatement.
        this.update(item.jobId, {
          errorCode: event.code,
          errorMessage: event.message,
        });
        return;

      case 'file':
        // Le chemin absolu ne quitte jamais le serveur : il n'est pas persisté
        // tel quel et sert uniquement à la détection.
        return;
    }
  }

  // --- persistance + diffusion --------------------------------------------

  private update(
    jobId: string,
    values: Parameters<DownloadJobRepository['updateJob']>[1],
  ): DownloadJobRow | null {
    try {
      const row = this.repository.updateJob(jobId, values);
      this.emit(jobId, { type: 'progress', job: row });
      return row;
    } catch (error) {
      this.options.logger?.warn(
        { jobId, err: error },
        'mise à jour du téléchargement ignorée',
      );
      return null;
    }
  }

  private finish(
    jobId: string,
    values: Parameters<DownloadJobRepository['updateJob']>[1],
  ): void {
    const row = this.update(jobId, { ...values, processId: null });
    if (row === null) return;
    if (row.status === 'completed') this.emit(jobId, { type: 'completed', job: row });
    else if (row.status === 'cancelled') this.emit(jobId, { type: 'cancelled', job: row });
    else this.emit(jobId, { type: 'failed', job: row });
  }

  private failFromError(jobId: string, error: unknown): void {
    const message = sanitizeMessage(
      error instanceof Error ? error.message : String(error),
    );
    this.options.logger?.error({ jobId, err: error }, 'téléchargement en échec');
    this.finish(jobId, {
      status: 'failed',
      stage: 'failed',
      message: 'Le téléchargement a échoué.',
      errorCode: 'INTERNAL_ERROR',
      errorMessage: message ?? 'Erreur interne du service de téléchargement.',
    });
  }

  private emit(jobId: string, event: DownloadJobEvent): void {
    const listeners = this.subscribers.get(jobId);
    if (!listeners) return;
    for (const listener of listeners) {
      try {
        listener(event);
      } catch {
        // Un abonné SSE défaillant ne doit jamais interrompre un job.
      }
    }
  }
}

function trackFields(track: DownloadTrackInfo): Record<string, string | null> {
  const fields: Record<string, string | null> = {};
  const title = sanitizeShortField(track.title);
  const artist = sanitizeShortField(track.artist);
  const album = sanitizeShortField(track.album);
  const source = sanitizeShortField(track.source, 60);
  const quality = sanitizeShortField(track.quality, 60);
  if (title !== null) fields.title = title;
  if (artist !== null) fields.artist = artist;
  if (album !== null) fields.album = album;
  if (source !== null) fields.source = source;
  if (quality !== null) fields.quality = quality;
  return fields;
}

function toServiceError(error: unknown): unknown {
  if (error instanceof DownloadJobRepositoryError) {
    return new DownloadServiceError(error.code, error.message);
  }
  return error;
}
