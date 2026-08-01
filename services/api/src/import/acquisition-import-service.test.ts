import { randomUUID } from 'node:crypto';
import { eq } from 'drizzle-orm';
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { createDb, type DbHandle } from '../db/client.js';
import { runMigrations } from '../db/migrate.js';
import {
  acquisitionJobs,
  importJobs,
  providerHealth,
  tracks,
  users,
  type ImportJobStatus,
} from '../db/schema.js';
import {
  AcquisitionJobRepository,
  AcquisitionJobRepositoryError,
} from './acquisition-job-repository.js';
import {
  AcquisitionImportService,
  AcquisitionImportServiceError,
  isMonochromeFallbackEligible,
  type AcquisitionLocalImportService,
  type AcquisitionRunner,
} from './acquisition-import-service.js';
import {
  LucidaProcessError,
  type LucidaDownloadRunRequest,
  type LucidaDownloadRunResult,
  type LucidaEvent,
} from './lucida-process-runner.js';
import { ProviderHealthRepository } from './provider-health-repository.js';

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
  /** Défaut 1 : comportement sérialisé historique. */
  maxConcurrent?: number;
  /** Défaut 0 : pas d'échelonnement dans les tests. */
  startStaggerMs?: number;
  providerHealth?: ProviderHealthRepository;
  interactiveVerificationEnabled?: boolean;
  importRoot?: string;
  monochromeFallbackEnabled?: boolean;
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
const directories: string[] = [];

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
  const importRoot =
    options.importRoot ?? resolve('test-data', 'imports');
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
    {
      maxConcurrent: options.maxConcurrent ?? 1,
      // L'échelonnement des démarrages a son propre test dédié : ailleurs il
      // ne ferait qu'allonger la durée des tests sans rien vérifier.
      startStaggerMs: options.startStaggerMs ?? 0,
      ...(options.providerHealth
        ? { providerHealth: options.providerHealth }
        : {}),
      interactiveVerificationEnabled:
        options.interactiveVerificationEnabled ?? false,
      interactiveVerificationTimeoutSeconds: 120,
      interactiveStagingRoot: join(importRoot, '.interactive'),
      monochromeStagingRoot: join(importRoot, '.monochrome'),
      monochromeFallbackEnabled:
        options.monochromeFallbackEnabled ?? false,
      monochromeManualTimeoutSeconds: 600,
    },
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
  for (const directory of directories.splice(0)) {
    rmSync(directory, { recursive: true, force: true });
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

  it('rejoue le scénario complet : échec réseau, retry, puis COMPLETED', async () => {
    const {
      service,
      runner,
      firstUserId,
      firstUsername,
      localImport,
    } = setup();

    const seenStatuses: string[] = [];

    runner.handler = async (request) => {
      emit(request, {
        type: 'stage',
        stage: 'searching',
        message: 'Recherche du morceau',
      });
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
        type: 'progress',
        stage: 'downloading',
        percent: 20,
        attempt: 1,
        maxAttempts: 3,
      });

      // Première tentative : échec réseau côté script Python.
      emit(request, {
        type: 'retry',
        attempt: 2,
        maxAttempts: 3,
        reason: 'Failed to fetch',
      });
      seenStatuses.push(
        service.getJobForUser(created.id, firstUserId)?.status ?? '?',
      );

      // Seconde tentative : succès.
      emit(request, {
        type: 'progress',
        stage: 'downloading',
        percent: 100,
        attempt: 2,
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

    await service.waitForIdle();

    // L'échec intermédiaire a bien été exposé comme RETRYING, pas comme FAILED.
    expect(seenStatuses).toEqual(['RETRYING']);

    const completed = service.getJobForUser(created.id, firstUserId);
    expect(completed).toMatchObject({
      status: 'COMPLETED',
      stage: 'completed',
      progress: 100,
      attempt: 2,
      selectedTitle: 'creeper',
      downloadedRelativePath: 'creeper.flac',
    });
    expect(completed?.trackId).not.toBeNull();
    expect(completed?.errorCode).toBeNull();
    // Un seul processus : le retry est interne au script, pas une relance.
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

  it('exécute plusieurs téléchargements en parallèle jusqu’à la limite', async () => {
    const {
      service,
      runner,
      firstUserId,
      firstUsername,
    } = setup({ maxConcurrent: 3 });

    expect(service.concurrencyLimit()).toBe(3);

    const gates = [
      deferred<LucidaDownloadRunResult>(),
      deferred<LucidaDownloadRunResult>(),
      deferred<LucidaDownloadRunResult>(),
      deferred<LucidaDownloadRunResult>(),
    ];
    let call = 0;
    runner.handler = async () => {
      const gate = gates[call]!;
      call += 1;
      return gate.promise;
    };

    for (const query of ['Un', 'Deux', 'Trois', 'Quatre']) {
      service.enqueue({
        userId: firstUserId,
        username: firstUsername,
        query,
        resultIndex: 0,
      });
    }

    // Trois démarrent ensemble ; le quatrième attend un créneau libre.
    await waitUntil(() => runner.calls.length === 3);
    expect(service.activeCount()).toBe(3);
    expect(service.queuedCount()).toBe(1);
    expect(service.activeJobIds()).toHaveLength(3);

    // Le 4e ne démarre qu'après la libération d'un créneau.
    for (const [index, gate] of gates.entries()) {
      const request = runner.calls[index];
      gate.resolve({
        mode: 'download',
        success: {
          type: 'success',
          filepath: join(request?.outputDir ?? '', `track${index}.flac`),
          title: `Track ${index}`,
          artist: 'Artist',
          album: 'Album',
          duration: 100,
        },
        absoluteFilePath: join(request?.outputDir ?? '', `track${index}.flac`),
        relativeFilePath: `track${index}.flac`,
      });
      // Laisse le worker libéré prendre le job suivant avant de continuer.
      await waitUntil(() => runner.calls.length >= Math.min(index + 4, 4));
    }

    await service.waitForIdle();
    expect(runner.calls).toHaveLength(4);
    expect(service.activeCount()).toBe(0);
    expect(service.queuedCount()).toBe(0);
  });

  it('refuse une concurrence hors bornes', () => {
    expect(() => setup({ maxConcurrent: 0 })).toThrowError(
      /maxConcurrent/,
    );
    expect(() => setup({ maxConcurrent: 5 })).toThrowError(
      /maxConcurrent/,
    );
  });

  it('échelonne les démarrages pour éviter une rafale simultanée', async () => {
    const {
      service,
      runner,
      firstUserId,
      firstUsername,
    } = setup({ maxConcurrent: 3, startStaggerMs: 120 });

    const startedAt: number[] = [];
    runner.handler = async (request) => {
      startedAt.push(Date.now());
      return {
        mode: 'download',
        success: {
          type: 'success',
          filepath: join(request.outputDir, 'x.flac'),
          title: 'X',
          artist: 'Artist',
          album: 'Album',
          duration: 100,
        },
        absoluteFilePath: join(request.outputDir, 'x.flac'),
        relativeFilePath: 'x.flac',
      };
    };

    for (const query of ['Un', 'Deux', 'Trois']) {
      service.enqueue({
        userId: firstUserId,
        username: firstUsername,
        query,
        resultIndex: 0,
      });
    }

    await service.waitForIdle();

    expect(startedAt).toHaveLength(3);
    // Les démarrages 2 et 3 sont espacés : aucune rafale simultanée.
    expect(startedAt[1]! - startedAt[0]!).toBeGreaterThanOrEqual(100);
    expect(startedAt[2]! - startedAt[1]!).toBeGreaterThanOrEqual(100);
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

    // Attendre le VRAI signal de démarrage (le runner a été invoqué) et non
    // seulement l'inscription du job comme actif : celle-ci précède l'appel.
    await waitUntil(
      () => service.activeJobId() === first.id && runner.calls.length === 1,
    );
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

    await waitUntil(
      () => service.activeJobId() === created.id && runner.calls.length >= 1,
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

    await waitUntil(
      () => service.activeJobId() === created.id && runner.calls.length >= 1,
    );

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

    await waitUntil(
      () => service.activeJobId() === active.id && runner.calls.length >= 1,
    );
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

  it('ne lance aucun runner et crée un job visible en pause quand le circuit est OPEN', async () => {
    const {
      handle,
      service,
      runner,
      firstUserId,
      firstUsername,
    } = setup();
    new ProviderHealthRepository(handle, {
      challengeCooldownSeconds: 1_800,
      rateLimitDefaultCooldownSeconds: 900,
      unavailableCooldownSeconds: 600,
      maxCooldownSeconds: 21_600,
      providerFailureWindowSeconds: 600,
      providerFailureThreshold: 2,
    }).recordFailure('PROVIDER_CHALLENGE');

    const job = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Pause provider',
      resultIndex: 0,
    });
    await service.waitForIdle();

    expect(job.status).toBe('PAUSED_PROVIDER');
    expect(job.stage).toBe('provider_paused');
    expect(runner.calls).toHaveLength(0);
  });

  it('suspend le job fautif et les jobs QUEUED sans retry automatique', async () => {
    const {
      service,
      repository,
      runner,
      firstUserId,
      firstUsername,
    } = setup();
    runner.handler = async () => {
      throw new LucidaProcessError(
        'PROVIDER_CHALLENGE',
        'Le fournisseur demande une vérification de sécurité.',
        { retryable: false },
      );
    };

    const first = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Premier',
      resultIndex: 0,
    });
    const second = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Second',
      resultIndex: 0,
    });
    await service.waitForIdle();

    expect(repository.requireJobForUser(first.id, firstUserId).status).toBe(
      'PAUSED_PROVIDER',
    );
    expect(repository.requireJobForUser(second.id, firstUserId).status).toBe(
      'PAUSED_PROVIDER',
    );
    expect(runner.calls).toHaveLength(1);
  });

  it('interdit la reprise avant retryAt et respecte ownership', () => {
    const {
      handle,
      service,
      firstUserId,
      secondUserId,
      firstUsername,
    } = setup();
    new ProviderHealthRepository(handle, {
      challengeCooldownSeconds: 1_800,
      rateLimitDefaultCooldownSeconds: 900,
      unavailableCooldownSeconds: 600,
      maxCooldownSeconds: 21_600,
      providerFailureWindowSeconds: 600,
      providerFailureThreshold: 2,
    }).recordFailure('PROVIDER_CHALLENGE');
    const job = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Ownership',
      resultIndex: 0,
    });

    try {
      service.retryPaused(job.id, firstUserId, firstUsername);
      throw new Error('reprise acceptée trop tôt');
    } catch (error) {
      expect(error).toMatchObject({ code: 'provider_cooldown' });
    }
    try {
      service.retryPaused(job.id, secondUserId, 'other');
      throw new Error('ownership non respecté');
    } catch (error) {
      expect(error).toMatchObject({ code: 'job_not_found' });
    }
  });

  it('autorise une seule probe après retryAt et ferme au DOWNLOADED', async () => {
    const {
      handle,
      service,
      repository,
      firstUserId,
      firstUsername,
    } = setup();
    const health = new ProviderHealthRepository(handle, {
      challengeCooldownSeconds: 1_800,
      rateLimitDefaultCooldownSeconds: 900,
      unavailableCooldownSeconds: 600,
      maxCooldownSeconds: 21_600,
      providerFailureWindowSeconds: 600,
      providerFailureThreshold: 2,
    });
    health.recordFailure('PROVIDER_CHALLENGE');
    const first = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Probe',
      resultIndex: 0,
    });
    const second = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Attente',
      resultIndex: 0,
    });
    handle.db
      .update(providerHealth)
      .set({ retryAt: '2000-01-01T00:00:00.000Z' })
      .run();

    service.retryPaused(first.id, firstUserId, firstUsername);
    try {
      service.retryPaused(second.id, firstUserId, firstUsername);
      throw new Error('seconde probe acceptée');
    } catch (error) {
      expect(error).toMatchObject({ code: 'probe_in_progress' });
    }
    await service.waitForIdle();

    expect(health.get()).toMatchObject({
      state: 'CLOSED',
      halfOpenProbeJobId: null,
    });
    expect(repository.requireJobForUser(first.id, firstUserId).status).toBe(
      'COMPLETED',
    );
    expect(repository.requireJobForUser(second.id, firstUserId).status).toBe(
      'PAUSED_PROVIDER',
    );
  });

  it('demande une vérification manuelle sans cooldown ni second spawn', async () => {
    const {
      service,
      runner,
      firstUserId,
      firstUsername,
    } = setup({ interactiveVerificationEnabled: true });
    runner.handler = async () => {
      throw new LucidaProcessError(
        'PROVIDER_CHALLENGE',
        'challenge test',
      );
    };

    const first = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'challenge interactif',
      resultIndex: 0,
    });
    await service.waitForIdle();

    expect(service.getJobForUser(first.id, firstUserId)).toMatchObject({
      status: 'MANUAL_VERIFICATION_REQUIRED',
      stage: 'waiting_user_verification',
      message: 'Une vérification manuelle est nécessaire sur le serveur.',
      errorCode: 'PROVIDER_CHALLENGE',
      attempt: 0,
      completedAt: null,
      trackId: null,
    });
    expect(service.providerStatus()).toMatchObject({
      state: 'MANUAL_VERIFICATION_REQUIRED',
      retryAt: null,
      manualRetryAllowed: true,
      reasonCode: 'PROVIDER_CHALLENGE',
      manualVerificationJobId: first.id,
    });

    const second = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'autre titre',
      resultIndex: 0,
    });
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 20));
    expect(service.getJobForUser(second.id, firstUserId)?.status).toBe(
      'QUEUED',
    );
    expect(runner.calls).toHaveLength(1);
  });

  it('valide ownership et anti-rejeu du résultat helper', async () => {
    const root = mkdtempSync(join(tmpdir(), 'hs-interactive-service-'));
    directories.push(root);
    const {
      service,
      runner,
      firstUserId,
      secondUserId,
      firstUsername,
      importRoot,
    } = setup({
      interactiveVerificationEnabled: true,
      importRoot: root,
    });
    runner.handler = async () => {
      throw new LucidaProcessError(
        'PROVIDER_CHALLENGE',
        'challenge test',
      );
    };
    const job = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'validation humaine',
      resultIndex: 1,
    });
    await service.waitForIdle();

    expect(() =>
      service.manualVerificationContext(job.id, secondUserId),
    ).toThrowError(AcquisitionJobRepositoryError);
    service.manualVerificationContext(job.id, firstUserId);

    const staging = join(importRoot, '.interactive', job.id);
    const inbox = join(
      importRoot,
      `${firstUserId}_${firstUsername}`,
      'inbox',
    );
    mkdirSync(staging, { recursive: true });
    mkdirSync(inbox, { recursive: true });
    writeFileSync(join(staging, 'track.flac'), Buffer.from([1, 2, 3]));

    const completed = await service.applyManualVerificationResult(
      job.id,
      firstUserId,
      firstUsername,
      'verification_completed',
    );
    expect(completed.status).toBe('COMPLETED');
    expect(service.providerStatus().state).toBe('CLOSED');
    await expect(
      service.applyManualVerificationResult(
        job.id,
        firstUserId,
        firstUsername,
        'verification_completed',
      ),
    ).rejects.toBeInstanceOf(AcquisitionImportServiceError);
  });

  it('annule et libère le holder sans déclarer le fournisseur sain', async () => {
    const {
      service,
      runner,
      firstUserId,
      firstUsername,
    } = setup({ interactiveVerificationEnabled: true });
    runner.handler = async () => {
      throw new LucidaProcessError(
        'PROVIDER_CHALLENGE',
        'challenge test',
      );
    };
    const job = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'annulation humaine',
      resultIndex: 0,
    });
    await service.waitForIdle();
    expect(service.cancel(job.id, firstUserId)).toBe(true);
    expect(service.getJobForUser(job.id, firstUserId)?.status).toBe(
      'CANCELLED',
    );
    expect(service.providerStatus().state).toBe('CLOSED');
  });

  it('récupère transactionnellement et idempotemment les challenges persistés', () => {
    const {
      service,
      repository,
      handle,
      firstUserId,
    } = setup({ interactiveVerificationEnabled: true });
    const challengeJob = repository.createJob({
      userId: firstUserId,
      query: 'ancien challenge',
      provider: 'QOBUZ',
      resultIndex: 0,
    });
    repository.updateJob(challengeJob.id, firstUserId, {
      status: 'PAUSED_PROVIDER',
      stage: 'provider_paused',
      errorCode: 'PROVIDER_CHALLENGE',
      errorMessage: 'ancien cooldown',
    });
    const rateLimitJob = repository.createJob({
      userId: firstUserId,
      query: 'ancienne limitation',
      provider: 'QOBUZ',
      resultIndex: 0,
    });
    repository.updateJob(rateLimitJob.id, firstUserId, {
      status: 'PAUSED_PROVIDER',
      stage: 'provider_paused',
      errorCode: 'PROVIDER_RATE_LIMITED',
      errorMessage: 'limitation',
    });
    new ProviderHealthRepository(handle, {
      challengeCooldownSeconds: 1_800,
      rateLimitDefaultCooldownSeconds: 900,
      unavailableCooldownSeconds: 600,
      maxCooldownSeconds: 21_600,
      providerFailureWindowSeconds: 600,
      providerFailureThreshold: 2,
    }).recordFailure('PROVIDER_CHALLENGE');
    handle.db
      .update(providerHealth)
      .set({
        state: 'HALF_OPEN',
        halfOpenProbeJobId: challengeJob.id,
      })
      .run();

    service.recoverInterruptedJobs();
    expect(service.providerStatus()).toMatchObject({
      state: 'MANUAL_VERIFICATION_REQUIRED',
      reasonCode: 'PROVIDER_CHALLENGE',
      retryAt: null,
      manualVerificationJobId: challengeJob.id,
    });
    expect(repository.requireJobForUser(challengeJob.id, firstUserId))
      .toMatchObject({
        status: 'MANUAL_VERIFICATION_REQUIRED',
        stage: 'waiting_user_verification',
        errorCode: 'PROVIDER_CHALLENGE',
      });
    expect(repository.requireJobForUser(rateLimitJob.id, firstUserId).status)
      .toBe('PAUSED_PROVIDER');

    service.recoverInterruptedJobs();
    expect(
      handle.db
        .select()
        .from(acquisitionJobs)
        .where(eq(acquisitionJobs.id, challengeJob.id))
        .get()?.status,
    ).toBe('MANUAL_VERIFICATION_REQUIRED');
  });

  it('répare au démarrage un état manuel référençant un job terminal', () => {
    const {
      service,
      repository,
      handle,
      firstUserId,
    } = setup({ interactiveVerificationEnabled: true });
    const failedJob = repository.createJob({
      userId: firstUserId,
      query: 'challenge orphelin',
      provider: 'QOBUZ',
      resultIndex: 0,
    });
    repository.updateJob(failedJob.id, firstUserId, {
      status: 'FAILED',
      stage: 'failed',
      errorCode: 'SEARCH_FAILED',
      errorMessage: 'historique conservé',
    });
    expect(service.providerStatus().state).toBe('CLOSED');
    handle.db
      .update(providerHealth)
      .set({
        state: 'MANUAL_VERIFICATION_REQUIRED',
        reasonCode: 'PROVIDER_CHALLENGE',
        manualVerificationJobId: failedJob.id,
      })
      .run();

    expect(service.recoverInterruptedJobs()).toBe(0);
    expect(service.repairedOrphanedManualVerificationOnStartup()).toBe(true);
    expect(service.providerStatus()).toMatchObject({
      state: 'CLOSED',
      reasonCode: null,
      manualVerificationJobId: null,
    });
    expect(repository.requireJobForUser(failedJob.id, firstUserId))
      .toMatchObject({
        status: 'FAILED',
        stage: 'failed',
        errorCode: 'SEARCH_FAILED',
      });
  });
});

describe('fallback Monochrome manuel', () => {
  const eligibleJob = {
    status: 'SEARCHING' as const,
    cancelRequested: false,
    selectedTitle: 'Lifestyles',
    selectedArtist: 'Guala',
  };

  it.each([
    'LUCIDA_ERROR',
    'PROVIDER_INVALID_RESPONSE',
    'PROVIDER_UNAVAILABLE',
    'PROVIDER_HTTP_ERROR',
    'SEARCH_FAILED',
  ])('autorise le code Lucida %s', (code) => {
    expect(isMonochromeFallbackEligible(code, eligibleJob)).toBe(true);
  });

  it.each([
    'INVALID_ARGUMENT',
    'CANCELLED',
    'PROVIDER_CHALLENGE',
    'PROVIDER_RATE_LIMITED',
    'LOCAL_IMPORT_REJECTED',
  ])('refuse le code non éligible %s', (code) => {
    expect(isMonochromeFallbackEligible(code, eligibleJob)).toBe(false);
  });

  it('refuse une cible sans métadonnées strictes', () => {
    expect(
      isMonochromeFallbackEligible('LUCIDA_ERROR', {
        ...eligibleJob,
        selectedArtist: null,
      }),
    ).toBe(false);
  });

  it('Lucida success ne déclenche aucun fallback', async () => {
    const { service, firstUserId, firstUsername, handle } = setup({
      monochromeFallbackEnabled: true,
    });
    const job = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Lifestyles Guala',
      resultIndex: 0,
      targetTitle: 'Lifestyles',
      targetArtist: 'Guala',
    });
    await service.waitForIdle();
    expect(service.getJobForUser(job.id, firstUserId)?.status).toBe(
      'COMPLETED',
    );
    expect(
      handle.sqlite
        .prepare('SELECT count(*) AS count FROM monochrome_manual_sessions')
        .get(),
    ).toEqual({ count: 0 });
  });

  it('LUCIDA_ERROR transitionne vers WAITING_MANUAL_DOWNLOAD', async () => {
    const { service, runner, firstUserId, firstUsername } = setup({
      monochromeFallbackEnabled: true,
    });
    runner.handler = async () => {
      throw new LucidaProcessError('LUCIDA_ERROR', 'Erreur fournisseur.');
    };
    const job = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Lifestyles Guala',
      resultIndex: 0,
      targetTitle: 'Lifestyles',
      targetArtist: 'Guala',
      targetAlbum: 'Lifestyles',
      targetDurationSeconds: 127,
    });
    await service.waitForIdle();
    const current = service.getJobForUser(job.id, firstUserId);
    expect(current).toMatchObject({
      status: 'WAITING_MANUAL_DOWNLOAD',
      stage: 'waiting_manual_download',
      providerUsed: 'MONOCHROME_MANUAL',
      fallbackFrom: 'LUCIDA',
      fallbackReasonCode: 'LUCIDA_ERROR',
      completedAt: null,
      trackId: null,
    });
  });

  it('réserve un holder unique et applique ownership', async () => {
    const {
      service,
      runner,
      firstUserId,
      secondUserId,
      firstUsername,
    } = setup({ monochromeFallbackEnabled: true });
    runner.handler = async () => {
      throw new LucidaProcessError(
        'PROVIDER_UNAVAILABLE',
        'Indisponible.',
      );
    };
    const job = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Lifestyles Guala',
      resultIndex: 0,
      targetTitle: 'Lifestyles',
      targetArtist: 'Guala',
    });
    await service.waitForIdle();
    expect(() =>
      service.monochromeManualContext(job.id, secondUserId),
    ).toThrow(AcquisitionJobRepositoryError);
    expect(service.monochromeManualContext(job.id, firstUserId).job.id).toBe(
      job.id,
    );
    expect(() =>
      service.monochromeManualContext(job.id, firstUserId),
    ).toThrow(AcquisitionImportServiceError);
  });

  it('exige un vrai import et un trackId avant COMPLETED', async () => {
    const importRoot = mkdtempSync(join(tmpdir(), 'monochrome-import-'));
    directories.push(importRoot);
    const {
      service,
      runner,
      firstUserId,
      firstUsername,
    } = setup({
      monochromeFallbackEnabled: true,
      importRoot,
      withTrack: true,
    });
    runner.handler = async () => {
      throw new LucidaProcessError('LUCIDA_ERROR', 'Erreur fournisseur.');
    };
    const job = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Lifestyles Guala',
      resultIndex: 0,
      targetTitle: 'Lifestyles',
      targetArtist: 'Guala',
    });
    await service.waitForIdle();
    service.monochromeManualContext(job.id, firstUserId);
    const staging = join(importRoot, '.monochrome', job.id);
    const inbox = join(importRoot, `${firstUserId}_${firstUsername}`, 'inbox');
    mkdirSync(staging, { recursive: true });
    mkdirSync(inbox, { recursive: true });
    writeFileSync(join(staging, 'Lifestyles.flac'), 'test-audio');

    const completed = await service.applyMonochromeManualResult(
      job.id,
      firstUserId,
      firstUsername,
      'download_ready',
    );

    expect(completed.status).toBe('COMPLETED');
    expect(completed.trackId).toBeTypeOf('number');
    expect(completed.providerUsed).toBe('MONOCHROME_MANUAL');
    expect(completed.completedAt).not.toBeNull();
  });

  it('refuse le résultat helper sans fichier validé', async () => {
    const importRoot = mkdtempSync(join(tmpdir(), 'monochrome-reject-'));
    directories.push(importRoot);
    const {
      service,
      runner,
      firstUserId,
      firstUsername,
    } = setup({ monochromeFallbackEnabled: true, importRoot });
    runner.handler = async () => {
      throw new LucidaProcessError('SEARCH_FAILED', 'Aucun résultat.');
    };
    const job = service.enqueue({
      userId: firstUserId,
      username: firstUsername,
      query: 'Lifestyles Guala',
      resultIndex: 0,
      targetTitle: 'Lifestyles',
      targetArtist: 'Guala',
    });
    await service.waitForIdle();
    service.monochromeManualContext(job.id, firstUserId);
    mkdirSync(join(importRoot, '.monochrome', job.id), { recursive: true });

    await expect(
      service.applyMonochromeManualResult(
        job.id,
        firstUserId,
        firstUsername,
        'download_ready',
      ),
    ).rejects.toBeInstanceOf(AcquisitionImportServiceError);
    expect(service.getJobForUser(job.id, firstUserId)?.status).toBe('FAILED');
  });
});
