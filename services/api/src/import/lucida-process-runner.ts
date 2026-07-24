import { spawn, type ChildProcess, type SpawnOptions } from 'node:child_process';
import { StringDecoder } from 'node:string_decoder';
import {
  dirname,
  isAbsolute,
  relative,
  resolve,
} from 'node:path';

const MAX_QUERY_LENGTH = 200;
const MAX_RESULT_INDEX = 100;
const MAX_DOWNLOAD_TIMEOUT_SECONDS = 300;
const MAX_DOWNLOAD_RETRIES = 9;
const MAX_NDJSON_LINE_BYTES = 64 * 1024;
const DEFAULT_STDERR_LIMIT_BYTES = 32 * 1024;
const DEFAULT_PROCESS_TIMEOUT_MS = 5 * 60 * 1000;
const FORCE_KILL_DELAY_MS = 5_000;

export type LucidaRunMode = 'search' | 'download';

export interface LucidaStageEvent {
  type: 'stage';
  stage: string;
  message: string;
}

export interface LucidaSearchResultEvent {
  type: 'search_result';
  index: number;
  title: string;
  artist: string;
  album: string;
  duration: number;
}

export interface LucidaCompleteEvent {
  type: 'complete';
  mode: 'list';
  count: number;
}

export interface LucidaSelectedEvent {
  type: 'selected';
  index: number;
  title: string;
  artist: string;
  album: string;
  duration: number;
  service: 'Qobuz';
}

export interface LucidaProgressEvent {
  type: 'progress';
  stage: string;
  percent: number;
  attempt: number;
  maxAttempts: number;
}

export interface LucidaRetryEvent {
  type: 'retry';
  attempt: number;
  maxAttempts: number;
  reason: string;
  delaySeconds: number;
}

export interface LucidaSuccessEvent {
  type: 'success';
  filepath: string;
  title: string;
  artist: string;
  album: string;
  duration: number;
}

export interface LucidaErrorEvent {
  type: 'error';
  code: string;
  message: string;
}

export type LucidaEvent =
  | LucidaStageEvent
  | LucidaSearchResultEvent
  | LucidaCompleteEvent
  | LucidaSelectedEvent
  | LucidaProgressEvent
  | LucidaRetryEvent
  | LucidaSuccessEvent
  | LucidaErrorEvent;

export interface LucidaSearchRunRequest {
  mode: 'search';
  query: string;
  signal?: AbortSignal;
  onEvent?: (event: LucidaEvent) => void;
}

export interface LucidaDownloadRunRequest {
  mode: 'download';
  query: string;
  resultIndex: number;
  outputDir: string;
  downloadTimeoutSeconds?: number;
  downloadRetries?: number;
  signal?: AbortSignal;
  onEvent?: (event: LucidaEvent) => void;
}

export type LucidaRunRequest =
  | LucidaSearchRunRequest
  | LucidaDownloadRunRequest;

export interface LucidaSearchRunResult {
  mode: 'search';
  results: LucidaSearchResultEvent[];
  count: number;
}

export interface LucidaDownloadRunResult {
  mode: 'download';
  success: LucidaSuccessEvent;
  /** Chemin absolu interne, jamais destiné à être exposé directement par une API. */
  absoluteFilePath: string;
  /** Chemin relatif au dossier de sortie imposé par le backend. */
  relativeFilePath: string;
}

export type LucidaRunResult =
  | LucidaSearchRunResult
  | LucidaDownloadRunResult;

export type LucidaProcessErrorCode =
  | 'INVALID_REQUEST'
  | 'CANCELLED'
  | 'TIMEOUT'
  | 'SPAWN_ERROR'
  | 'PROTOCOL_ERROR'
  | 'PROCESS_FAILED'
  | 'MISSING_TERMINAL_EVENT'
  | 'OUTPUT_PATH_VIOLATION'
  | string;

export class LucidaProcessError extends Error {
  constructor(
    readonly code: LucidaProcessErrorCode,
    message: string,
    readonly details: {
      exitCode?: number | null;
      signal?: NodeJS.Signals | null;
      stderr?: string;
    } = {},
  ) {
    super(message);
    this.name = 'LucidaProcessError';
  }
}

export type LucidaSpawn = (
  command: string,
  args: readonly string[],
  options: SpawnOptions,
) => ChildProcess;

export interface LucidaProcessRunnerOptions {
  scriptPath: string;
  importRoot: string;
  pythonPath?: string;
  processTimeoutMs?: number;
  stderrLimitBytes?: number;
  spawnImpl?: LucidaSpawn;
}

function nonEmptyString(
  value: unknown,
  field: string,
  maxLength = 500,
): string {
  if (typeof value !== 'string') {
    throw new LucidaProcessError(
      'PROTOCOL_ERROR',
      `Champ NDJSON invalide : ${field} doit être une chaîne.`,
    );
  }
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > maxLength) {
    throw new LucidaProcessError(
      'PROTOCOL_ERROR',
      `Champ NDJSON invalide : ${field}.`,
    );
  }
  return value;
}

function integerInRange(
  value: unknown,
  field: string,
  min: number,
  max: number,
): number {
  if (!Number.isInteger(value) || (value as number) < min || (value as number) > max) {
    throw new LucidaProcessError(
      'PROTOCOL_ERROR',
      `Champ NDJSON invalide : ${field}.`,
    );
  }
  return value as number;
}

function isConfined(root: string, candidate: string): boolean {
  const absoluteRoot = resolve(root);
  const absoluteCandidate = resolve(candidate);
  const rel = relative(absoluteRoot, absoluteCandidate);
  return rel === '' || (!rel.startsWith('..') && !isAbsolute(rel));
}

function confinedFileRelativePath(root: string, candidate: string): string {
  const absoluteRoot = resolve(root);
  const absoluteCandidate = resolve(candidate);
  const rel = relative(absoluteRoot, absoluteCandidate);
  if (!rel || rel.startsWith('..') || isAbsolute(rel)) {
    throw new LucidaProcessError(
      'OUTPUT_PATH_VIOLATION',
      'Le script a retourné un fichier hors du dossier autorisé.',
    );
  }
  return rel;
}

function validateEvent(value: unknown): LucidaEvent {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new LucidaProcessError(
      'PROTOCOL_ERROR',
      'Événement NDJSON non objet.',
    );
  }

  const event = value as Record<string, unknown>;
  const type = nonEmptyString(event.type, 'type', 50);

  switch (type) {
    case 'stage':
      return {
        type,
        stage: nonEmptyString(event.stage, 'stage', 80),
        message: nonEmptyString(event.message, 'message'),
      };

    case 'search_result':
      return {
        type,
        index: integerInRange(event.index, 'index', 0, MAX_RESULT_INDEX),
        title: nonEmptyString(event.title, 'title'),
        artist: nonEmptyString(event.artist, 'artist'),
        album: nonEmptyString(event.album, 'album'),
        duration: integerInRange(event.duration, 'duration', 0, 24 * 60 * 60),
      };

    case 'complete':
      if (event.mode !== 'list') {
        throw new LucidaProcessError(
          'PROTOCOL_ERROR',
          'Champ NDJSON invalide : complete.mode.',
        );
      }
      return {
        type,
        mode: 'list',
        count: integerInRange(event.count, 'count', 0, 1_000),
      };

    case 'selected': {
      const service = nonEmptyString(event.service, 'service', 50);
      if (service.toLocaleLowerCase('fr-FR') !== 'qobuz') {
        throw new LucidaProcessError(
          'PROTOCOL_ERROR',
          'Le script a sélectionné un service non autorisé.',
        );
      }
      return {
        type,
        index: integerInRange(event.index, 'index', 0, MAX_RESULT_INDEX),
        title: nonEmptyString(event.title, 'title'),
        artist: typeof event.artist === 'string' ? event.artist : '',
        album: typeof event.album === 'string' ? event.album : '',
        duration: integerInRange(event.duration, 'duration', 0, 24 * 60 * 60),
        service: 'Qobuz',
      };
    }

    case 'progress':
      return {
        type,
        stage: nonEmptyString(event.stage, 'stage', 80),
        percent: integerInRange(event.percent, 'percent', 0, 100),
        attempt: integerInRange(event.attempt, 'attempt', 1, 10),
        maxAttempts: integerInRange(event.maxAttempts, 'maxAttempts', 1, 10),
      };

    case 'retry':
      return {
        type,
        attempt: integerInRange(event.attempt, 'attempt', 1, 10),
        maxAttempts: integerInRange(event.maxAttempts, 'maxAttempts', 1, 10),
        reason: nonEmptyString(event.reason, 'reason'),
        delaySeconds: integerInRange(event.delaySeconds, 'delaySeconds', 0, 60),
      };

    case 'success':
      return {
        type,
        filepath: nonEmptyString(event.filepath, 'filepath', 2_000),
        title: nonEmptyString(event.title, 'title'),
        artist: typeof event.artist === 'string' ? event.artist : '',
        album: typeof event.album === 'string' ? event.album : '',
        duration: integerInRange(event.duration, 'duration', 0, 24 * 60 * 60),
      };

    case 'error':
      return {
        type,
        code: nonEmptyString(event.code, 'code', 100),
        message: nonEmptyString(event.message, 'message'),
      };

    default:
      throw new LucidaProcessError(
        'PROTOCOL_ERROR',
        `Type d’événement NDJSON inconnu : ${type}.`,
      );
  }
}

function normalizeQuery(query: string): string {
  const normalized = query.trim().replace(/\s+/g, ' ');
  if (!normalized || normalized.length > MAX_QUERY_LENGTH) {
    throw new LucidaProcessError(
      'INVALID_REQUEST',
      `La requête doit contenir entre 1 et ${MAX_QUERY_LENGTH} caractères.`,
    );
  }
  return normalized;
}

function validateRunnerOptions(options: LucidaProcessRunnerOptions): {
  scriptPath: string;
  importRoot: string;
  pythonPath: string;
  processTimeoutMs: number;
  stderrLimitBytes: number;
  spawnImpl: LucidaSpawn;
} {
  const scriptPath = resolve(options.scriptPath);
  const importRoot = resolve(options.importRoot);
  const processTimeoutMs =
    options.processTimeoutMs ?? DEFAULT_PROCESS_TIMEOUT_MS;
  const stderrLimitBytes =
    options.stderrLimitBytes ?? DEFAULT_STDERR_LIMIT_BYTES;

  if (!scriptPath.toLocaleLowerCase('en-US').endsWith('.py')) {
    throw new LucidaProcessError(
      'INVALID_REQUEST',
      'Le chemin du script Lucida doit pointer vers un fichier Python.',
    );
  }
  if (
    !Number.isInteger(processTimeoutMs) ||
    processTimeoutMs < 100 ||
    processTimeoutMs > 30 * 60 * 1000
  ) {
    throw new LucidaProcessError(
      'INVALID_REQUEST',
      'processTimeoutMs est hors limites.',
    );
  }
  if (
    !Number.isInteger(stderrLimitBytes) ||
    stderrLimitBytes < 1_024 ||
    stderrLimitBytes > 1024 * 1024
  ) {
    throw new LucidaProcessError(
      'INVALID_REQUEST',
      'stderrLimitBytes est hors limites.',
    );
  }

  return {
    scriptPath,
    importRoot,
    pythonPath: options.pythonPath ?? 'python',
    processTimeoutMs,
    stderrLimitBytes,
    spawnImpl: options.spawnImpl ?? spawn,
  };
}

export class LucidaProcessRunner {
  private readonly options: ReturnType<typeof validateRunnerOptions>;
  private readonly activeChildren = new Set<ChildProcess>();

  constructor(options: LucidaProcessRunnerOptions) {
    this.options = validateRunnerOptions(options);
  }

  activeProcessCount(): number {
    return this.activeChildren.size;
  }

  stopAll(): void {
    for (const child of this.activeChildren) {
      if (child.exitCode === null) {
        child.kill('SIGTERM');
        const forceTimer = setTimeout(() => {
          if (child.exitCode === null) child.kill('SIGKILL');
        }, FORCE_KILL_DELAY_MS);
        forceTimer.unref();
      }
    }
  }

  run(request: LucidaRunRequest): Promise<LucidaRunResult> {
    const query = normalizeQuery(request.query);

    if (request.signal?.aborted) {
      return Promise.reject(
        new LucidaProcessError(
          'CANCELLED',
          'Import annulé avant le lancement du processus.',
        ),
      );
    }

    const args = [
      this.options.scriptPath,
      query,
      '--service',
      'Qobuz',
      '--json',
    ];

    let outputDir: string | null = null;

    if (request.mode === 'search') {
      args.push('--list');
    } else {
      if (
        !Number.isInteger(request.resultIndex) ||
        request.resultIndex < 0 ||
        request.resultIndex > MAX_RESULT_INDEX
      ) {
        return Promise.reject(
          new LucidaProcessError(
            'INVALID_REQUEST',
            `resultIndex doit être compris entre 0 et ${MAX_RESULT_INDEX}.`,
          ),
        );
      }

      const downloadTimeoutSeconds =
        request.downloadTimeoutSeconds ?? 75;
      const downloadRetries = request.downloadRetries ?? 2;

      if (
        !Number.isInteger(downloadTimeoutSeconds) ||
        downloadTimeoutSeconds < 10 ||
        downloadTimeoutSeconds > MAX_DOWNLOAD_TIMEOUT_SECONDS
      ) {
        return Promise.reject(
          new LucidaProcessError(
            'INVALID_REQUEST',
            `downloadTimeoutSeconds doit être compris entre 10 et ${MAX_DOWNLOAD_TIMEOUT_SECONDS}.`,
          ),
        );
      }
      if (
        !Number.isInteger(downloadRetries) ||
        downloadRetries < 0 ||
        downloadRetries > MAX_DOWNLOAD_RETRIES
      ) {
        return Promise.reject(
          new LucidaProcessError(
            'INVALID_REQUEST',
            `downloadRetries doit être compris entre 0 et ${MAX_DOWNLOAD_RETRIES}.`,
          ),
        );
      }

      outputDir = resolve(request.outputDir);
      if (!isConfined(this.options.importRoot, outputDir)) {
        return Promise.reject(
          new LucidaProcessError(
            'INVALID_REQUEST',
            'Le dossier de sortie est hors de la racine d’import.',
          ),
        );
      }

      args.push(
        '--index',
        String(request.resultIndex),
        '--output',
        outputDir,
        '--download-timeout',
        String(downloadTimeoutSeconds),
        '--download-retries',
        String(downloadRetries),
      );
    }

    let child: ChildProcess;
    try {
      child = this.options.spawnImpl(
        this.options.pythonPath,
        args,
        {
          cwd: dirname(this.options.scriptPath),
          shell: false,
          windowsHide: true,
          stdio: ['ignore', 'pipe', 'pipe'],
          env: {
            ...process.env,
            PYTHONIOENCODING: 'utf-8',
            PYTHONUTF8: '1',
          },
        },
      );
    } catch (error) {
      return Promise.reject(
        new LucidaProcessError(
          'SPAWN_ERROR',
          `Impossible de lancer Python : ${
            error instanceof Error ? error.message : 'erreur inconnue'
          }`,
        ),
      );
    }

    this.activeChildren.add(child);

    return new Promise<LucidaRunResult>((resolvePromise, rejectPromise) => {
      let settled = false;
      let stdoutBuffer = '';
      let stderrBuffer = '';
      let lastErrorEvent: LucidaErrorEvent | null = null;
      let completeEvent: LucidaCompleteEvent | null = null;
      let successEvent: LucidaSuccessEvent | null = null;
      const searchResults: LucidaSearchResultEvent[] = [];
      const stdoutDecoder = new StringDecoder('utf8');
      const stderrDecoder = new StringDecoder('utf8');
      let forceKillTimer: NodeJS.Timeout | null = null;

      const removeAbortListener = (): void => {
        request.signal?.removeEventListener('abort', handleAbort);
      };

      const clearProcessTimeout = (): void => {
        clearTimeout(processTimer);
      };

      const finish = (
        callback: () => void,
      ): void => {
        if (settled) return;
        settled = true;
        clearProcessTimeout();
        removeAbortListener();
        callback();
      };

      const terminate = (): void => {
        if (child.exitCode !== null) return;
        child.kill('SIGTERM');
        if (forceKillTimer === null) {
          forceKillTimer = setTimeout(() => {
            if (child.exitCode === null) child.kill('SIGKILL');
          }, FORCE_KILL_DELAY_MS);
          forceKillTimer.unref();
        }
      };

      const fail = (error: LucidaProcessError): void => {
        terminate();
        finish(() => rejectPromise(error));
      };

      const emit = (event: LucidaEvent): void => {
        try {
          request.onEvent?.(event);
        } catch (error) {
          throw new LucidaProcessError(
            'PROTOCOL_ERROR',
            `Le consommateur d’événements a échoué : ${
              error instanceof Error ? error.message : 'erreur inconnue'
            }`,
          );
        }
      };

      const processLine = (rawLine: string): void => {
        const line = rawLine.trim();
        if (!line) return;
        if (Buffer.byteLength(line, 'utf8') > MAX_NDJSON_LINE_BYTES) {
          throw new LucidaProcessError(
            'PROTOCOL_ERROR',
            'Une ligne NDJSON dépasse la taille maximale autorisée.',
          );
        }

        let decoded: unknown;
        try {
          decoded = JSON.parse(line);
        } catch {
          throw new LucidaProcessError(
            'PROTOCOL_ERROR',
            'Le processus Python a émis une ligne NDJSON invalide.',
          );
        }

        const event = validateEvent(decoded);

        if (event.type === 'search_result') {
          searchResults.push(event);
        } else if (event.type === 'complete') {
          if (completeEvent !== null) {
            throw new LucidaProcessError(
              'PROTOCOL_ERROR',
              'Le processus Python a émis plusieurs événements complete.',
            );
          }
          completeEvent = event;
        } else if (event.type === 'success') {
          if (successEvent !== null) {
            throw new LucidaProcessError(
              'PROTOCOL_ERROR',
              'Le processus Python a émis plusieurs événements success.',
            );
          }
          successEvent = event;
        } else if (event.type === 'error') {
          lastErrorEvent = event;
        }

        emit(event);
      };

      const consumeStdout = (text: string): void => {
        stdoutBuffer += text;
        if (Buffer.byteLength(stdoutBuffer, 'utf8') > MAX_NDJSON_LINE_BYTES * 2) {
          throw new LucidaProcessError(
            'PROTOCOL_ERROR',
            'Le buffer NDJSON dépasse la taille maximale autorisée.',
          );
        }

        while (true) {
          const newlineIndex = stdoutBuffer.indexOf('\n');
          if (newlineIndex < 0) return;
          const line = stdoutBuffer.slice(0, newlineIndex);
          stdoutBuffer = stdoutBuffer.slice(newlineIndex + 1);
          processLine(line);
        }
      };

      const appendStderr = (text: string): void => {
        stderrBuffer += text;
        while (
          Buffer.byteLength(stderrBuffer, 'utf8') >
          this.options.stderrLimitBytes
        ) {
          stderrBuffer = stderrBuffer.slice(
            Math.max(1, Math.floor(stderrBuffer.length / 4)),
          );
        }
      };

      const handleAbort = (): void => {
        fail(
          new LucidaProcessError(
            'CANCELLED',
            'Import annulé par l’utilisateur.',
          ),
        );
      };

      const processTimer = setTimeout(() => {
        fail(
          new LucidaProcessError(
            'TIMEOUT',
            'Le processus Lucida a dépassé le délai global autorisé.',
            { stderr: stderrBuffer },
          ),
        );
      }, this.options.processTimeoutMs);
      processTimer.unref();

      request.signal?.addEventListener('abort', handleAbort, { once: true });

      child.stdout?.on('data', (chunk: Buffer | string) => {
        if (settled) return;
        try {
          consumeStdout(
            typeof chunk === 'string'
              ? chunk
              : stdoutDecoder.write(chunk),
          );
        } catch (error) {
          fail(
            error instanceof LucidaProcessError
              ? error
              : new LucidaProcessError(
                  'PROTOCOL_ERROR',
                  'Erreur pendant la lecture du protocole NDJSON.',
                ),
          );
        }
      });

      child.stdout?.on('end', () => {
        if (settled) return;
        try {
          consumeStdout(stdoutDecoder.end());
          processLine(stdoutBuffer);
          stdoutBuffer = '';
        } catch (error) {
          fail(
            error instanceof LucidaProcessError
              ? error
              : new LucidaProcessError(
                  'PROTOCOL_ERROR',
                  'Erreur pendant la finalisation du protocole NDJSON.',
                ),
          );
        }
      });

      child.stderr?.on('data', (chunk: Buffer | string) => {
        appendStderr(
          typeof chunk === 'string'
            ? chunk
            : stderrDecoder.write(chunk),
        );
      });

      child.stderr?.on('end', () => {
        appendStderr(stderrDecoder.end());
      });

      child.once('error', (error) => {
        this.activeChildren.delete(child);
        fail(
          new LucidaProcessError(
            'SPAWN_ERROR',
            `Erreur du processus Python : ${error.message}`,
            { stderr: stderrBuffer },
          ),
        );
      });

      child.once('close', (code, signal) => {
        this.activeChildren.delete(child);
        if (forceKillTimer !== null) clearTimeout(forceKillTimer);
        if (settled) return;

        if (code !== 0) {
          const error = lastErrorEvent;
          finish(() =>
            rejectPromise(
              new LucidaProcessError(
                error?.code ?? 'PROCESS_FAILED',
                error?.message ?? 'Le processus Lucida a échoué.',
                {
                  exitCode: code,
                  signal,
                  stderr: stderrBuffer,
                },
              ),
            ),
          );
          return;
        }

        if (request.mode === 'search') {
          if (completeEvent === null) {
            finish(() =>
              rejectPromise(
                new LucidaProcessError(
                  'MISSING_TERMINAL_EVENT',
                  'Le processus de recherche a terminé sans événement complete.',
                  { exitCode: code, signal, stderr: stderrBuffer },
                ),
              ),
            );
            return;
          }
          if (completeEvent.count !== searchResults.length) {
            finish(() =>
              rejectPromise(
                new LucidaProcessError(
                  'PROTOCOL_ERROR',
                  'Le nombre de résultats annoncé ne correspond pas aux événements reçus.',
                  { exitCode: code, signal, stderr: stderrBuffer },
                ),
              ),
            );
            return;
          }

          finish(() =>
            resolvePromise({
              mode: 'search',
              results: searchResults,
              count: completeEvent!.count,
            }),
          );
          return;
        }

        if (successEvent === null || outputDir === null) {
          finish(() =>
            rejectPromise(
              new LucidaProcessError(
                'MISSING_TERMINAL_EVENT',
                'Le processus de téléchargement a terminé sans événement success.',
                { exitCode: code, signal, stderr: stderrBuffer },
              ),
            ),
          );
          return;
        }

        let relativeFilePath: string;
        try {
          relativeFilePath = confinedFileRelativePath(
            outputDir,
            successEvent.filepath,
          );
        } catch (error) {
          finish(() =>
            rejectPromise(
              error instanceof LucidaProcessError
                ? error
                : new LucidaProcessError(
                    'OUTPUT_PATH_VIOLATION',
                    'Chemin de fichier téléchargé invalide.',
                  ),
            ),
          );
          return;
        }

        finish(() =>
          resolvePromise({
            mode: 'download',
            success: successEvent!,
            absoluteFilePath: resolve(successEvent!.filepath),
            relativeFilePath,
          }),
        );
      });
    });
  }
}
