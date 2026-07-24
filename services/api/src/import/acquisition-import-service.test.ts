import { randomUUID } from 'node:crypto';
import { join, resolve } from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { createDb, type DbHandle } from '../db/client.js';
import { runMigrations } from '../db/migrate.js';
import {
  acquisitionJobs,
  importJobs,
  tracks,
  users,
  type ImportJobStatus,
} from '../db/schema.js';
import {
  AcquisitionJobRepository,
} from './acquisition-job-repository.js';
import {
  AcquisitionImportService,
  AcquisitionImportServiceError,
  type AcquisitionLocalImportService,
  type AcquisitionRunner,
} from './acquisition-import-service.js';
import {
  LucidaProcessError,
  type LucidaDownloadRunRequest,
  type LucidaDownloadRunResult,
  type LucidaEvent,
} from './lucida-process-runner.js';

interface Deferred<T> {
  promise: Promise<T>;
  resolve(value: T): void;
  reject(error: unknown): void;
}

function deferred<T>(): Deferred<T> {
  let resolvePromise!: (value: T) => void;
  let rejectPromise!: (error: unknown) => void;
  const promise = new Promise<T>((resolveValue, rejectValue) => {
    resolvePromise = resolveValue;
    rejectPromise = rejectValue;
  });
  return {
    promise,
    resolve: resolvePromise,
    reject: rejectPromise,
  };
}

class FakeRunner implements AcquisitionRunner {
  readonly calls: LucidaDownloadRunRequest[] = [];
  readonly stopAll = vi.fn();
  handler: (
    request: LucidaDownloadRunRequest,
  ) => Promise<LucidaDownloadRunResult> = async (request) => ({
    mode: 'download',
    success: {
      type: 'success',
      filepath: join(request.outputDir, 'track.flac'),
      title: 'Track',
      artist: 'Artist',
      album: 'Album',
      duration: 120,
    },
    absoluteFilePath: join(request.outputDir, 'track.flac'),
    relativeFilePath: 'track.flac',
  });

  async run(
    request: LucidaDownloadRunRequest,
  ): Promise<LucidaDownloadRunResult> {
    this.calls.push(request);
    return this.handler(request);
  }
}

interface SetupOptions {
  localStatus?: ImportJobStatus;
  localError?: string | null;
  withTrack?: boolean;
}

interface SetupResult {
  handle: DbHandle;
  repository: AcquisitionJobRepository;
  runner: FakeRunner;
  localImport: AcquisitionLocalImportService;
  service: AcquisitionImportService;
  firstUserId: number;
  secondUserId: number;
  firstUsername: string;
  importRoot: string;
}

const handles: DbHandle[] = [];

function setup(options: SetupOptions = {}): SetupResult {
  const handle = createDb(':memory:');
  handles.push(handle);
  runMigrations(handle, {
    info: () => undefined,
    error: () => undefined,
  });

  const now = new Date().toISOString();
  const firstUsername = `alice_${randomUUID().slice(0, 8)}`;
  const secondUsername = `bob_${randomUUID().slice(0, 8)}`;

  const insertUser = (username: string): number =>
    handle.db
      .insert(users)
      .values({
        username,
        displayName: username,
        passwordHash: 'test-only',
        role: 'USER',
        isActive: true,
        mustChangePassword: false,
        createdAt: now,
        updatedAt: now,
      })
      .returning({ id: users.id })
      .get().id;

  const firstUserId = insertUser(firstUsername);
  const secondUserId = insertUser(secondUsername);
  const importRoot = resolve('test-data', 'imports');
  const runner = new FakeRunner();

  const localImport: AcquisitionLocalImportService = {
    ensureUserDirectory: vi.fn(async (userId: number, username: string) => {
      const root = join(importRoot, `${userId}_${username}`);
      return {
        userId,
        directoryName: `${userId}_${username}`,
        root,
        inbox: join(root, 'inbox'),
        rejected: join(root, 'rejected'),
        processed: join(root, 'processed'),
      };
    }),
    processInboxFile: vi.fn(async (userId: number, path: string) => {
      let trackId: number | null = null;
      if (options.withTrack ?? true) {
        trackId = handle.db
          .insert(tracks)
          .values({
            hash: randomUUID().replaceAll('-', '').padEnd(64, '0').slice(0, 64),
            path: `track-${randomUUID()}.flac`,
            originalExtension: '.flac',
            mimeType: 'audio/flac',
            sizeBytes: 100,
            durationSeconds: 120,
            title: 'Track',
            artist: 'Artist',
            album: 'Album',
            createdAt: new Date().toISOString(),
          })
          .returning({ id: tracks.id })
          .get().id;
      }

      return handle.db
        .insert(importJobs)
        .values({
          userId,
          filename: path.split(/[\\/]/).at(-1) ?? 'track.flac',
          relativePath: `processed/${randomUUID()}.flac`,
          status: options.localStatus ?? 'IMPORTED',
          trackId,
          errorMessage: options.localError ?? null,
          createdAt: new Date().toISOString(),
          updatedAt: new Date().toISOString(),
          processedAt: new Date().toISOString(),
        })
        .returning({ id: importJobs.id })
        .get().id;
    }),
  };

  const repository = new AcquisitionJobRepository(handle);
  const service = new AcquisitionImportService(
    handle,
    repository,
    runner,
    localImport,
  );

  return {
    handle,
    repository,
    runner,
    localImport,
    service,
    firstUserId,
    secondUserId,
    firstUsername,
    importRoot,
  };
}

function emit(
  request: LucidaDownloadRunRequest,
  event: LucidaEvent,
): void {
  request.onEvent?.(event);
}

async function waitUntil(
  predicate: () => boolean,
  timeoutMs = 2_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) {
      throw new Error('condition non atteinte avant timeout');
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 1));
  }
}

afterEach(() => {
  for (const handle of handles.splice(0)) {
    handle.sqlite.close();
  }
});

describe('AcquisitionImportService', () => {
  it('enchaîne téléchargement, vrai import local et COMPLETED', async () => {
    const {
      service,
      runner,
      firstUserId,
      firstUsername,
      localImport,
    } = setup();

    runner.handler = async (request) => {
      emit(request, {
        type: 'selected',
        index: 0,
        title: 'creeper',
        artist: 'Luther',
        album: 'creeper + seed',
        duration: 160,
        service: 'Qobuz',
      });
      emit(request, {
        type: 'stage',
        stage: 'opening_result',
        message: 'Ouverture du résultat',
      });
      emit(request, {
        type: 'progress',
        stage: 'downloading',
        percent: 45,
        attempt: 1,
        maxAttempts: 3,
      });
      emit(request, {
        type: 'success',
        filepath: join(request.outputDir, 'creeper.flac'),
        title: 'creeper',
        artist: 'Luther',
        album: 'creeper + seed',
        duration: 160,
      });

      return {
        mode: 'download',
        success: {
          type: 'success',
          filepath: join(request.outputDir, 'creeper.flac'),
          title: 'creeper',
          artist: 'Luther',
          album: 'creeper + seed',
          duration: 160,
        },
        absoluteFilePath: join(request.outputDir, 'creeper.flac'),
        relativeFilePath: 'creeper.flac',
      };
    };

    const created = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Luther Creeper',
      resultIndex: 0,
    });

    expect(created.status).toBe('QUEUED');
    await service.waitForIdle();

    const completed = service.getJobForUser(created.id, firstUserId);
    expect(completed).toMatchObject({
      status: 'COMPLETED',
      stage: 'completed',
      progress: 100,
      selectedTitle: 'creeper',
      selectedArtist: 'Luther',
      selectedAlbum: 'creeper + seed',
      downloadedRelativePath: 'creeper.flac',
    });
    expect(completed?.localImportJobId).not.toBeNull();
    expect(completed?.trackId).not.toBeNull();
    expect(localImport.processInboxFile).toHaveBeenCalledOnce();
  });

  it('ne traite qu’un seul téléchargement à la fois', async () => {
    const {
      service,
      runner,
      firstUserId,
      firstUsername,
    } = setup();

    const firstDeferred = deferred<LucidaDownloadRunResult>();
    let call = 0;
    runner.handler = async (request) => {
      call += 1;
      if (call === 1) return firstDeferred.promise;
      return {
        mode: 'download',
        success: {
          type: 'success',
          filepath: join(request.outputDir, 'second.flac'),
          title: 'Second',
          artist: 'Artist',
          album: 'Album',
          duration: 100,
        },
        absoluteFilePath: join(request.outputDir, 'second.flac'),
        relativeFilePath: 'second.flac',
      };
    };

    service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Premier',
      resultIndex: 0,
    });
    service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Deuxième',
      resultIndex: 0,
    });

    await waitUntil(() => runner.calls.length === 1);
    expect(service.queuedCount()).toBe(1);

    const firstRequest = runner.calls[0]!;
    firstDeferred.resolve({
      mode: 'download',
      success: {
        type: 'success',
        filepath: join(firstRequest.outputDir, 'first.flac'),
        title: 'First',
        artist: 'Artist',
        album: 'Album',
        duration: 100,
      },
      absoluteFilePath: join(firstRequest.outputDir, 'first.flac'),
      relativeFilePath: 'first.flac',
    });

    await service.waitForIdle();
    expect(runner.calls).toHaveLength(2);
  });

  it('reste IMPORTING tant que UserImportService n’a pas fini', async () => {
    const {
      handle,
      service,
      runner,
      firstUserId,
      firstUsername,
      localImport,
    } = setup();

    const localDeferred = deferred<number>();
    vi.mocked(localImport.processInboxFile).mockImplementation(
      async () => localDeferred.promise,
    );

    const created = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Test',
      resultIndex: 0,
    });

    await waitUntil(
      () => vi.mocked(localImport.processInboxFile).mock.calls.length === 1,
    );

    expect(
      service.getJobForUser(created.id, firstUserId)?.status,
    ).toBe('IMPORTING');

    const trackId = handle.db
      .insert(tracks)
      .values({
        hash: 'a'.repeat(64),
        path: 'deferred.flac',
        originalExtension: '.flac',
        mimeType: 'audio/flac',
        sizeBytes: 100,
        durationSeconds: 100,
        title: 'Deferred',
        artist: 'Artist',
        album: 'Album',
        createdAt: new Date().toISOString(),
      })
      .returning({ id: tracks.id })
      .get().id;

    const localJobId = handle.db
      .insert(importJobs)
      .values({
        userId: firstUserId,
        filename: 'deferred.flac',
        relativePath: 'processed/deferred.flac',
        status: 'IMPORTED',
        trackId,
        createdAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      })
      .returning({ id: importJobs.id })
      .get().id;

    localDeferred.resolve(localJobId);
    await service.waitForIdle();

    expect(
      service.getJobForUser(created.id, firstUserId)?.status,
    ).toBe('COMPLETED');
    expect(runner.calls).toHaveLength(1);
  });

  it('annule immédiatement un job encore en file', async () => {
    const {
      service,
      runner,
      firstUserId,
      firstUsername,
    } = setup();

    const firstDeferred = deferred<LucidaDownloadRunResult>();
    runner.handler = async () => firstDeferred.promise;

    const first = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Premier',
      resultIndex: 0,
    });
    const second = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Deuxième',
      resultIndex: 0,
    });

    await waitUntil(() => service.activeJobId() === first.id);
    expect(service.cancel(second.id, firstUserId)).toBe(true);
    expect(
      service.getJobForUser(second.id, firstUserId),
    ).toMatchObject({
      status: 'CANCELLED',
      cancelRequested: true,
    });

    const firstRequest = runner.calls[0]!;
    firstDeferred.resolve({
      mode: 'download',
      success: {
        type: 'success',
        filepath: join(firstRequest.outputDir, 'first.flac'),
        title: 'First',
        artist: 'Artist',
        album: 'Album',
        duration: 100,
      },
      absoluteFilePath: join(firstRequest.outputDir, 'first.flac'),
      relativeFilePath: 'first.flac',
    });

    await service.waitForIdle();
    expect(runner.calls).toHaveLength(1);
  });

  it('annule le processus actif via AbortSignal', async () => {
    const {
      service,
      runner,
      firstUserId,
      firstUsername,
    } = setup();

    runner.handler = async (request) =>
      new Promise<LucidaDownloadRunResult>((_resolve, reject) => {
        request.signal?.addEventListener(
          'abort',
          () => {
            reject(
              new LucidaProcessError(
                'CANCELLED',
                'Import annulé par l’utilisateur.',
              ),
            );
          },
          { once: true },
        );
      });

    const created = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Actif',
      resultIndex: 0,
    });

    await waitUntil(() => service.activeJobId() === created.id);
    expect(service.cancel(created.id, firstUserId)).toBe(true);
    await service.waitForIdle();

    expect(
      service.getJobForUser(created.id, firstUserId),
    ).toMatchObject({
      status: 'CANCELLED',
      errorCode: 'CANCELLED',
    });
  });

  it('convertit une erreur runner structurée en FAILED', async () => {
    const {
      service,
      runner,
      firstUserId,
      firstUsername,
    } = setup();

    runner.handler = async () => {
      throw new LucidaProcessError(
        'NO_EXACT_MATCH',
        'Aucune correspondance exacte.',
      );
    };

    const created = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Introuvable',
      resultIndex: 0,
    });
    await service.waitForIdle();

    expect(
      service.getJobForUser(created.id, firstUserId),
    ).toMatchObject({
      status: 'FAILED',
      errorCode: 'NO_EXACT_MATCH',
      errorMessage: 'Aucune correspondance exacte.',
    });
  });

  it('termine aussi correctement quand le pipeline local réutilise une piste', async () => {
    const {
      service,
      firstUserId,
      firstUsername,
    } = setup({ localStatus: 'REUSED' });

    const created = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Déjà présente',
      resultIndex: 0,
    });
    await service.waitForIdle();

    expect(
      service.getJobForUser(created.id, firstUserId),
    ).toMatchObject({
      status: 'COMPLETED',
    });
    expect(
      service.getJobForUser(created.id, firstUserId)?.message,
    ).toMatch(/déjà présente/i);
  });

  it('reporte un échec du vrai import local', async () => {
    const {
      service,
      firstUserId,
      firstUsername,
    } = setup({
      localStatus: 'FAILED',
      localError: 'FLAC invalide',
      withTrack: false,
    });

    const created = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Fichier invalide',
      resultIndex: 0,
    });
    await service.waitForIdle();

    expect(
      service.getJobForUser(created.id, firstUserId),
    ).toMatchObject({
      status: 'FAILED',
      errorCode: 'LOCAL_IMPORT_FAILED',
      errorMessage: 'FLAC invalide',
    });
  });

  it('signale explicitement un rapprochement nécessitant le propriétaire', async () => {
    const {
      service,
      firstUserId,
      firstUsername,
    } = setup({
      localStatus: 'WAITING_FOR_OWNER_MATCH',
      withTrack: false,
    });

    const created = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Ambigu',
      resultIndex: 0,
    });
    await service.waitForIdle();

    expect(
      service.getJobForUser(created.id, firstUserId),
    ).toMatchObject({
      status: 'FAILED',
      stage: 'owner_review_required',
      errorCode: 'LOCAL_IMPORT_REVIEW_REQUIRED',
    });
  });

  it('isole lecture, liste et annulation entre utilisateurs', async () => {
    const {
      service,
      runner,
      firstUserId,
      secondUserId,
      firstUsername,
    } = setup();

    runner.handler = async (request) =>
      new Promise<LucidaDownloadRunResult>((_resolve, reject) => {
        request.signal?.addEventListener(
          'abort',
          () => {
            reject(
              new LucidaProcessError(
                'CANCELLED',
                'Import annulé par l’utilisateur.',
              ),
            );
          },
          { once: true },
        );
      });

    const created = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Privé',
      resultIndex: 0,
    });

    await waitUntil(() => service.activeJobId() === created.id);

    expect(service.getJobForUser(created.id, secondUserId)).toBeNull();
    expect(service.listRecentForUser(secondUserId)).toEqual([]);
    expect(() =>
      service.cancel(created.id, secondUserId),
    ).toThrowError(
      expect.objectContaining({
        code: 'job_not_found',
      }),
    );

    expect(service.cancel(created.id, firstUserId)).toBe(true);
    await service.waitForIdle();

    expect(
      service.getJobForUser(created.id, firstUserId),
    ).toMatchObject({
      status: 'CANCELLED',
      errorCode: 'CANCELLED',
    });
  });

  it('récupère les anciens jobs actifs en INTERRUPTED', () => {
    const {
      service,
      repository,
      firstUserId,
    } = setup();

    const oldJob = repository.createJob({
      userId: firstUserId,
      query: 'Ancien',
      resultIndex: 0,
    });

    expect(service.recoverInterruptedJobs()).toBe(1);
    expect(
      service.getJobForUser(oldJob.id, firstUserId),
    ).toMatchObject({
      status: 'INTERRUPTED',
      errorCode: 'SERVER_RESTART',
    });
  });

  it('interrompt file et job actif pendant stop()', async () => {
    const {
      service,
      runner,
      firstUserId,
      firstUsername,
    } = setup();

    runner.handler = async (request) =>
      new Promise<LucidaDownloadRunResult>((_resolve, reject) => {
        request.signal?.addEventListener(
          'abort',
          () => {
            reject(
              new LucidaProcessError(
                'CANCELLED',
                'Arrêt serveur',
              ),
            );
          },
          { once: true },
        );
      });

    const active = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Actif',
      resultIndex: 0,
    });
    const queued = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'En attente',
      resultIndex: 0,
    });

    await waitUntil(() => service.activeJobId() === active.id);
    await service.stop();

    expect(runner.stopAll).toHaveBeenCalledOnce();
    expect(
      service.getJobForUser(active.id, firstUserId)?.status,
    ).toBe('INTERRUPTED');
    expect(
      service.getJobForUser(queued.id, firstUserId)?.status,
    ).toBe('INTERRUPTED');

    expect(() =>
      service.enqueue({
        userId: firstUserId,
        username: firstUsername,
        query: 'Refusé',
        resultIndex: 0,
      }),
    ).toThrowError(
      expect.objectContaining({
        code: 'service_stopped',
      }),
    );
  });

  it('valide les options avant de créer un job', () => {
    const {
      handle,
      service,
      firstUserId,
      firstUsername,
    } = setup();

    expect(() =>
      service.enqueue({
        userId: firstUserId,
        username: firstUsername,
        query: 'Test',
        resultIndex: -1,
      }),
    ).toThrowError(AcquisitionImportServiceError);

    expect(() =>
      service.enqueue({
        userId: firstUserId,
        username: firstUsername,
        query: 'Test',
        resultIndex: 0,
        downloadRetries: 10,
      }),
    ).toThrowError(AcquisitionImportServiceError);

    expect(
      handle.db.select().from(acquisitionJobs).all(),
    ).toHaveLength(0);
  });
});
