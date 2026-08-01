import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { createDb, type DbHandle } from '../db/client.js';
import type {
  CatalogSearchResult,
  DiscoveryProviderId,
} from '../discovery/catalog/types.js';
import type { TrackSearchProvider } from './track-search.js';
import { runMigrations } from '../db/migrate.js';
import { users } from '../db/schema.js';
import { makeFlac } from '../test/flac.js';
import { DownloadJobRepository } from './download-job-repository.js';
import {
  DownloadService,
  DownloadServiceError,
  type DownloadLocalImportService,
} from './download-service.js';
import type {
  DownloadHandle,
  DownloadProvider,
  DownloadProviderEvent,
  DownloadRequest,
  DownloadResult,
  ProviderHealth,
} from './download-provider.js';

let root: string;
let handle: DbHandle;
let userId: number;

const silentLog = { info: () => {}, error: () => {} };

/**
 * Moteur factice pilotable : aucun processus Python n'est lancé, et le test
 * décide quand et comment chaque job se termine.
 */
class FakeProvider implements DownloadProvider {
  readonly name = 'fake';
  readonly started: DownloadRequest[] = [];
  readonly cancelled: string[] = [];
  stopAllCalls = 0;

  private readonly pending = new Map<
    string,
    {
      resolve: (result: DownloadResult) => void;
      emit: (event: DownloadProviderEvent) => void;
      request: DownloadRequest;
    }
  >();

  /** Fichiers écrits dans le staging au moment où le job se termine. */
  filesToCreate: (request: DownloadRequest) => Array<{ name: string; data: Buffer }> =
    () => [];

  async start(request: DownloadRequest): Promise<DownloadHandle> {
    this.started.push(request);
    const listeners = new Set<(event: DownloadProviderEvent) => void>();
    let resolveCompletion: (result: DownloadResult) => void;
    const completion = new Promise<DownloadResult>((resolvePromise) => {
      resolveCompletion = resolvePromise;
    });
    this.pending.set(request.jobId, {
      resolve: (result) => resolveCompletion(result),
      emit: (event) => {
        for (const listener of listeners) listener(event);
      },
      request,
    });
    return {
      processId: 1234,
      completion,
      onEvent: (callback) => {
        listeners.add(callback);
        return () => listeners.delete(callback);
      },
    };
  }

  emit(jobId: string, event: DownloadProviderEvent): void {
    this.pending.get(jobId)?.emit(event);
  }

  isRunning(jobId: string): boolean {
    return this.pending.has(jobId);
  }

  succeed(jobId: string, overrides: Partial<DownloadResult> = {}): void {
    const entry = this.pending.get(jobId);
    if (!entry) throw new Error(`job inconnu : ${jobId}`);
    for (const file of this.filesToCreate(entry.request)) {
      mkdirSync(entry.request.outputDir, { recursive: true });
      writeFileSync(join(entry.request.outputDir, file.name), file.data);
    }
    this.pending.delete(jobId);
    entry.resolve({
      ok: true,
      downloaded: 1,
      skipped: 0,
      failed: 0,
      track: {},
      reportedFiles: [],
      errorCode: null,
      errorMessage: null,
      ...overrides,
    });
  }

  /**
   * Échec de la tentative en cours. Sans effet si plus rien n'est en cours :
   * une fois la chaîne terminée, un appel de nettoyage ne doit pas faire
   * échouer le test pour une mauvaise raison.
   */
  fail(jobId: string, errorMessage = 'Moteur en échec.'): void {
    const entry = this.pending.get(jobId);
    if (!entry) return;
    this.pending.delete(jobId);
    entry.resolve({
      ok: false,
      downloaded: 0,
      skipped: 0,
      failed: 1,
      track: {},
      reportedFiles: [],
      errorCode: 'ENGINE_FAILED',
      errorMessage,
    });
  }

  async cancel(jobId: string): Promise<void> {
    this.cancelled.push(jobId);
    const entry = this.pending.get(jobId);
    if (!entry) return;
    this.pending.delete(jobId);
    entry.resolve({
      ok: false,
      downloaded: 0,
      skipped: 0,
      failed: 0,
      track: {},
      reportedFiles: [],
      errorCode: 'CANCELLED',
      errorMessage: 'Téléchargement annulé.',
    });
  }

  async healthCheck(): Promise<ProviderHealth> {
    return {
      available: true,
      pythonFound: true,
      antraImportable: true,
      outputWritable: true,
      premiumKeyConfigured: true,
      soulseekDisabled: true,
      detail: null,
      checkedAt: new Date().toISOString(),
    };
  }

  stopAll(): void {
    this.stopAllCalls += 1;
  }
}

/** Pipeline local factice : enregistre les fichiers qui lui sont remis. */
class FakeLocalImport implements DownloadLocalImportService {
  readonly imported: string[] = [];
  nextJobId = 1;

  constructor(private readonly inbox: string) {}

  async ensureUserDirectory(userIdArg: number) {
    mkdirSync(this.inbox, { recursive: true });
    return {
      userId: userIdArg,
      directoryName: 'inbox',
      root: this.inbox,
      inbox: this.inbox,
      rejected: join(this.inbox, 'rejected'),
      processed: join(this.inbox, 'processed'),
    };
  }

  async processInboxFile(_userId: number, path: string): Promise<number> {
    this.imported.push(path);
    return this.nextJobId;
  }
}

/** Résultat catalogue minimal pour les tests de recherche. */
function catalogTrack(options: {
  title: string;
  artist: string;
  isrc?: string | null;
  durationSeconds?: number;
  urls?: Array<{ provider: DiscoveryProviderId; url: string }>;
}): CatalogSearchResult {
  const urls = options.urls ?? [
    { provider: 'deezer' as DiscoveryProviderId, url: 'https://www.deezer.com/track/9' },
  ];
  return {
    canonicalKey: options.isrc ? `isrc:${options.isrc}` : `id:${options.title}`,
    entityType: 'track',
    title: options.title,
    artists: [{ name: options.artist, reference: null }],
    album: options.title,
    durationMs: (options.durationSeconds ?? 180) * 1000,
    releaseDate: null,
    explicit: null,
    images: [],
    isrc: options.isrc ?? null,
    upc: null,
    mbid: null,
    trackCount: null,
    providerReferences: urls.map((entry) => ({
      provider: entry.provider,
      entityType: 'track' as const,
      externalId: 'x',
      externalUrl: entry.url,
      market: 'FR',
    })),
    externalLinks: [],
    preview: null,
    matchConfidence: 'STRONG',
  };
}

/** Recherche factice : aucun appel réseau, aucun credential. */
class FakeSearchProvider implements TrackSearchProvider {
  readonly name = 'fake_search';
  readonly queries: string[] = [];

  constructor(private readonly results: CatalogSearchResult[]) {}

  async searchTracks(input: { query: string }): Promise<CatalogSearchResult[]> {
    this.queries.push(input.query);
    return this.results;
  }
}

function makeService(
  provider: DownloadProvider,
  localImport: DownloadLocalImportService,
  overrides: Partial<ConstructorParameters<typeof DownloadService>[4]> = {},
): DownloadService {
  return new DownloadService(
    handle,
    new DownloadJobRepository(handle),
    provider,
    localImport,
    {
      importRoot: join(root, 'imports'),
      maxConcurrent: 2,
      jobTimeoutMs: 5_000,
      allowedExtensions: ['.flac'],
      stabilityIntervalMs: 1,
      stabilityChecks: 1,
      maxStabilityChecks: 5,
      ...overrides,
    },
  );
}

function enqueue(service: DownloadService, url: string) {
  return service.enqueue({
    userId,
    username: 'owner',
    requestedUrl: url,
    normalizedUrl: url,
  });
}

/**
 * Fait échouer chaque tentative de la chaîne, en attendant à chaque fois que le
 * moteur ait réellement démarré. Sans cette attente, un `fail()` anticipé
 * n'aurait aucun effet et le job resterait en suspens.
 */
async function failWholeChain(
  provider: FakeProvider,
  jobId: string,
  attempts: number,
  from = provider.started.length,
): Promise<void> {
  for (let index = from; index < attempts; index += 1) {
    await waitFor(() => provider.started.length === index + 1);
    provider.fail(jobId);
  }
}

async function waitFor(
  predicate: () => boolean,
  timeoutMs = 3_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error('condition jamais atteinte');
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 5));
  }
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'homespotify-download-'));
  handle = createDb(join(root, 'db.sqlite'));
  runMigrations(handle, silentLog);
  const now = new Date().toISOString();
  userId = handle.db
    .insert(users)
    .values({
      username: 'owner',
      displayName: 'Owner',
      passwordHash: 'x',
      role: 'OWNER',
      createdAt: now,
      updatedAt: now,
    })
    .returning()
    .get()!.id;
});

afterEach(() => {
  handle.sqlite.close();
  rmSync(root, { recursive: true, force: true });
});

describe('DownloadService — file d’exécution', () => {
  it('respecte la limite de concurrence et laisse les autres en attente', async () => {
    const provider = new FakeProvider();
    const service = makeService(provider, new FakeLocalImport(join(root, 'inbox')), {
      maxConcurrent: 2,
    });

    const jobs = [
      enqueue(service, 'https://open.spotify.com/track/1'),
      enqueue(service, 'https://open.spotify.com/track/2'),
      enqueue(service, 'https://open.spotify.com/track/3'),
    ];

    await waitFor(() => provider.started.length === 2);
    // Le troisième reste en file tant qu'un créneau n'est pas libéré.
    expect(provider.started).toHaveLength(2);
    expect(service.getJobForUser(jobs[2]!.id, userId)?.status).toBe('queued');

    provider.fail(jobs[0]!.id);
    await waitFor(() => provider.started.length === 3);
    provider.fail(jobs[1]!.id);
    provider.fail(jobs[2]!.id);
    await service.waitForIdle();
  });

  it('refuse un second job actif pour la même URL', () => {
    const provider = new FakeProvider();
    const service = makeService(provider, new FakeLocalImport(join(root, 'inbox')));

    enqueue(service, 'https://open.spotify.com/track/1');
    expect(() => enqueue(service, 'https://open.spotify.com/track/1')).toThrow(
      DownloadServiceError,
    );
  });

  it('ne lance jamais deux fois le même job', async () => {
    const provider = new FakeProvider();
    const service = makeService(provider, new FakeLocalImport(join(root, 'inbox')));
    const job = enqueue(service, 'https://open.spotify.com/track/1');

    await waitFor(() => provider.started.length === 1);
    expect(provider.started.filter((item) => item.jobId === job.id)).toHaveLength(1);
    provider.fail(job.id);
    await service.waitForIdle();
  });
});

describe('DownloadService — annulation', () => {
  it('annule un job en attente sans jamais lancer le moteur', async () => {
    const provider = new FakeProvider();
    const service = makeService(provider, new FakeLocalImport(join(root, 'inbox')), {
      maxConcurrent: 1,
    });

    const running = enqueue(service, 'https://open.spotify.com/track/1');
    const waiting = enqueue(service, 'https://open.spotify.com/track/2');
    await waitFor(() => provider.started.length === 1);

    expect(await service.cancel(waiting.id, userId)).toBe(true);
    expect(service.getJobForUser(waiting.id, userId)?.status).toBe('cancelled');
    expect(provider.started.some((item) => item.jobId === waiting.id)).toBe(false);

    provider.fail(running.id);
    await service.waitForIdle();
  });

  it('annule un job en cours et reste idempotent', async () => {
    const provider = new FakeProvider();
    const service = makeService(provider, new FakeLocalImport(join(root, 'inbox')));
    const job = enqueue(service, 'https://open.spotify.com/track/1');
    await waitFor(() => provider.started.length === 1);

    expect(await service.cancel(job.id, userId)).toBe(true);
    // Deuxième appel : accepté sans effet supplémentaire.
    expect(await service.cancel(job.id, userId)).toBe(true);
    await service.waitForIdle();

    expect(service.getJobForUser(job.id, userId)?.status).toBe('cancelled');
    expect(provider.cancelled).toContain(job.id);
  });

  it('une annulation pendant la préparation ne lance JAMAIS le moteur', async () => {
    const provider = new FakeProvider();
    const localImport = new FakeLocalImport(join(root, 'inbox'));

    // Bloque la préparation (création des dossiers) : c'est exactement la
    // fenêtre où une annulation arrivait trop tôt et laissait le job bloqué
    // jusqu'au délai global.
    let releasePreparation: () => void = () => {};
    const preparation = new Promise<void>((resolvePromise) => {
      releasePreparation = resolvePromise;
    });
    const original = localImport.ensureUserDirectory.bind(localImport);
    localImport.ensureUserDirectory = async (id: number) => {
      await preparation;
      return original(id);
    };

    const service = makeService(provider, localImport);
    const job = enqueue(service, 'https://open.spotify.com/track/1');

    await service.cancel(job.id, userId);
    releasePreparation();
    await service.waitForIdle();

    expect(provider.started).toHaveLength(0);
    expect(service.getJobForUser(job.id, userId)?.status).toBe('cancelled');
  });

  it('annuler un job déjà terminal ne réécrit rien', async () => {
    const provider = new FakeProvider();
    const service = makeService(provider, new FakeLocalImport(join(root, 'inbox')));
    const job = enqueue(service, 'https://open.spotify.com/track/1');
    await waitFor(() => provider.started.length === 1);
    provider.fail(job.id);
    await service.waitForIdle();

    expect(await service.cancel(job.id, userId)).toBe(false);
    expect(service.getJobForUser(job.id, userId)?.status).toBe('failed');
  });
});

describe('DownloadService — délai global', () => {
  it('tue le moteur et échoue proprement au-delà du délai', async () => {
    const provider = new FakeProvider();
    const service = makeService(provider, new FakeLocalImport(join(root, 'inbox')), {
      jobTimeoutMs: 20,
    });
    const job = enqueue(service, 'https://open.spotify.com/track/1');

    await waitFor(() => provider.cancelled.includes(job.id));
    await service.waitForIdle();

    const row = service.getJobForUser(job.id, userId);
    expect(row?.status).toBe('failed');
    expect(row?.errorCode).toBe('TIMEOUT');
  });
});

describe('DownloadService — détection et import du fichier', () => {
  it('détecte le nouveau FLAC, le remet au pipeline local et complète le job', async () => {
    const provider = new FakeProvider();
    provider.filesToCreate = () => [
      { name: '01 - Lifestyles.flac', data: makeFlac({ seconds: 180 }) },
    ];
    const localImport = new FakeLocalImport(join(root, 'inbox'));
    const service = makeService(provider, localImport);

    const job = enqueue(service, 'https://open.spotify.com/track/1');
    await waitFor(() => provider.started.length === 1);
    provider.succeed(job.id);
    await service.waitForIdle();

    expect(localImport.imported).toHaveLength(1);
    expect(localImport.imported[0]).toContain('Lifestyles.flac');
    // L'état final dépend du pipeline local : ici, aucun import_jobs réel n'est
    // créé, le service le signale au lieu d'inventer un succès.
    const row = service.getJobForUser(job.id, userId);
    expect(row?.status).toBe('failed');
    expect(row?.errorCode).toBe('LOCAL_IMPORT_JOB_MISSING');
  });

  it('ignore les fichiers temporaires et les extensions non autorisées', async () => {
    const provider = new FakeProvider();
    provider.filesToCreate = () => [
      { name: 'partiel.flac.part', data: Buffer.from('inachevé') },
      { name: 'chiffre.enc.m4a', data: Buffer.from('chiffré') },
      { name: 'notes.txt', data: Buffer.from('texte') },
      { name: 'cover.jpg', data: Buffer.from('image') },
    ];
    const localImport = new FakeLocalImport(join(root, 'inbox'));
    const service = makeService(provider, localImport);

    const job = enqueue(service, 'https://open.spotify.com/track/1');
    await waitFor(() => provider.started.length === 1);
    provider.succeed(job.id);
    await service.waitForIdle();

    expect(localImport.imported).toHaveLength(0);
    const row = service.getJobForUser(job.id, userId);
    expect(row?.status).toBe('failed');
    expect(row?.errorCode).toBe('NO_FILE_DETECTED');
  });

  it('rejette un fichier illisible sans le confondre avec un succès', async () => {
    const provider = new FakeProvider();
    provider.filesToCreate = () => [
      { name: 'faux.flac', data: Buffer.from('ceci n’est pas du FLAC') },
    ];
    const localImport = new FakeLocalImport(join(root, 'inbox'));
    const service = makeService(provider, localImport);

    const job = enqueue(service, 'https://open.spotify.com/track/1');
    await waitFor(() => provider.started.length === 1);
    provider.succeed(job.id);
    await service.waitForIdle();

    expect(localImport.imported).toHaveLength(0);
    expect(service.getJobForUser(job.id, userId)?.status).toBe('failed');
  });

  it('n’importe que depuis le staging DÉDIÉ au job', async () => {
    const provider = new FakeProvider();
    provider.filesToCreate = () => [
      { name: '01 - Lifestyles.flac', data: makeFlac({ seconds: 180 }) },
    ];
    const localImport = new FakeLocalImport(join(root, 'inbox'));
    const service = makeService(provider, localImport);

    // Fichier d'un AUTRE job, présent dans la racine de staging partagée : il
    // ne doit jamais être ramassé, même s'il est plus récent.
    const foreign = join(root, 'imports', '.antra', 'autre-job');
    mkdirSync(foreign, { recursive: true });
    writeFileSync(join(foreign, 'intrus.flac'), makeFlac({ seconds: 200 }));

    const job = enqueue(service, 'https://open.spotify.com/track/1');
    await waitFor(() => provider.started.length === 1);
    provider.succeed(job.id);
    await service.waitForIdle();

    expect(localImport.imported).toHaveLength(1);
    expect(localImport.imported[0]).toContain('Lifestyles.flac');
    expect(localImport.imported.join('|')).not.toContain('intrus');
  });
});

describe('DownloadService — reprise et relance', () => {
  it('marque interrompus les jobs actifs au redémarrage', () => {
    const provider = new FakeProvider();
    const service = makeService(provider, new FakeLocalImport(join(root, 'inbox')));
    const job = enqueue(service, 'https://open.spotify.com/track/1');

    // Simule un nouveau processus serveur sur la même base.
    const rebooted = makeService(
      new FakeProvider(),
      new FakeLocalImport(join(root, 'inbox')),
    );
    expect(rebooted.recoverInterruptedJobs()).toBeGreaterThanOrEqual(1);
    expect(rebooted.getJobForUser(job.id, userId)?.status).toBe('interrupted');
    void service;
  });

  it('relance un job interrompu sur la même ligne, sans doublon', async () => {
    const provider = new FakeProvider();
    const service = makeService(provider, new FakeLocalImport(join(root, 'inbox')));
    const job = enqueue(service, 'https://open.spotify.com/track/1');
    await waitFor(() => provider.started.length === 1);
    provider.fail(job.id);
    await service.waitForIdle();

    const retried = service.retry(job.id, userId, 'owner');
    expect(retried.id).toBe(job.id);
    expect(retried.status).toBe('queued');
    expect(service.listRecentForUser(userId)).toHaveLength(1);

    await waitFor(() => provider.started.length === 2);
    provider.fail(job.id);
    await service.waitForIdle();
  });

  it('refuse de relancer un job réussi ou annulé', async () => {
    const provider = new FakeProvider();
    const service = makeService(provider, new FakeLocalImport(join(root, 'inbox')));
    const job = enqueue(service, 'https://open.spotify.com/track/1');
    await waitFor(() => provider.started.length === 1);
    await service.cancel(job.id, userId);
    await service.waitForIdle();

    expect(() => service.retry(job.id, userId, 'owner')).toThrow(DownloadServiceError);
  });
});

describe('DownloadService — chaîne de repli entre sources', () => {
  const chain = [
    {
      provider: 'spotify' as const,
      url: 'https://open.spotify.com/track/1',
      title: 'Lifestyles',
      artist: 'Guala',
      album: 'Lifestyles',
      durationSeconds: 180,
      isrc: 'AAAAA0000001',
      confidence: 88,
      sourceRank: 100,
      artworkUrl: null,
    },
    {
      provider: 'itunes' as const,
      url: 'https://music.apple.com/fr/album/x/1?i=2',
      title: 'Lifestyles',
      artist: 'Guala',
      album: 'Lifestyles',
      durationSeconds: 180,
      isrc: 'AAAAA0000001',
      confidence: 88,
      sourceRank: 70,
      artworkUrl: null,
    },
    {
      provider: 'deezer' as const,
      url: 'https://www.deezer.com/track/3',
      title: 'Lifestyles',
      artist: 'Guala',
      album: 'Lifestyles',
      durationSeconds: 180,
      isrc: 'AAAAA0000001',
      confidence: 88,
      sourceRank: 40,
      artworkUrl: null,
    },
  ];

  function enqueueChain(service: DownloadService) {
    return service.enqueue({
      userId,
      username: 'owner',
      requestedUrl: chain[0]!.url,
      normalizedUrl: chain[0]!.url,
      requestKind: 'search',
      query: 'Guala Lifestyles',
      candidates: chain,
    });
  }

  it('essaie le candidat suivant après un délai de la première source', async () => {
    const provider = new FakeProvider();
    const service = makeService(provider, new FakeLocalImport(join(root, 'inbox')));
    const job = enqueueChain(service);

    await waitFor(() => provider.started.length === 1);
    expect(provider.started[0]?.url).toBe(chain[0]!.url);
    provider.fail(job.id, 'Metadata timeout');

    await waitFor(() => provider.started.length === 2);
    expect(provider.started[1]?.url).toBe(chain[1]!.url);
    // Chaque tentative reçoit un dossier de staging ISOLÉ.
    expect(provider.started[0]?.outputDir).not.toBe(provider.started[1]?.outputDir);

    await failWholeChain(provider, job.id, chain.length, 1);
    await service.waitForIdle();
  });

  it('s’arrête au premier succès sans essayer les suivants', async () => {
    const provider = new FakeProvider();
    provider.filesToCreate = () => [
      { name: '01 - Lifestyles.flac', data: makeFlac({ seconds: 180 }) },
    ];
    const localImport = new FakeLocalImport(join(root, 'inbox'));
    const service = makeService(provider, localImport);
    const job = enqueueChain(service);

    await waitFor(() => provider.started.length === 1);
    provider.fail(job.id);
    await waitFor(() => provider.started.length === 2);
    provider.succeed(job.id);
    await service.waitForIdle();

    // Le troisième candidat n'est jamais tenté.
    expect(provider.started).toHaveLength(2);
    expect(localImport.imported).toHaveLength(1);
  });

  it('épuise la chaîne quand tous les candidats échouent', async () => {
    const provider = new FakeProvider();
    const service = makeService(provider, new FakeLocalImport(join(root, 'inbox')));
    const job = enqueueChain(service);

    for (let attempt = 1; attempt <= chain.length; attempt += 1) {
      await waitFor(() => provider.started.length === attempt);
      provider.fail(job.id);
    }
    await service.waitForIdle();

    expect(provider.started).toHaveLength(3);
    const row = service.getJobForUser(job.id, userId);
    expect(row?.status).toBe('failed');
    const attempts = JSON.parse(row?.attemptsJson ?? '[]') as Array<{
      order: number;
      provider: string;
      errorCode: string | null;
    }>;
    expect(attempts.map((entry) => entry.provider)).toEqual([
      'spotify',
      'itunes',
      'deezer',
    ]);
    expect(attempts.every((entry) => entry.errorCode !== null)).toBe(true);
  });

  it('une annulation entre deux candidats n’enchaîne jamais', async () => {
    const provider = new FakeProvider();
    const service = makeService(provider, new FakeLocalImport(join(root, 'inbox')));
    const job = enqueueChain(service);

    await waitFor(() => provider.started.length === 1);
    await service.cancel(job.id, userId);
    await service.waitForIdle();

    // Le premier processus est arrêté, aucun second candidat n'est lancé.
    expect(provider.started).toHaveLength(1);
    expect(service.getJobForUser(job.id, userId)?.status).toBe('cancelled');
  });

  it('n’importe jamais deux fois lorsqu’une source a déjà réussi', async () => {
    const provider = new FakeProvider();
    provider.filesToCreate = () => [
      { name: '01 - Lifestyles.flac', data: makeFlac({ seconds: 180 }) },
    ];
    const localImport = new FakeLocalImport(join(root, 'inbox'));
    const service = makeService(provider, localImport);
    const job = enqueueChain(service);

    await waitFor(() => provider.started.length === 1);
    provider.succeed(job.id);
    await service.waitForIdle();

    expect(provider.started).toHaveLength(1);
    expect(localImport.imported).toHaveLength(1);
  });

  it('conserve la requête, les candidats et la source retenue', async () => {
    const provider = new FakeProvider();
    const service = makeService(provider, new FakeLocalImport(join(root, 'inbox')));
    const job = enqueueChain(service);

    await failWholeChain(provider, job.id, chain.length);
    await service.waitForIdle();

    const row = service.getJobForUser(job.id, userId)!;
    expect(row.requestKind).toBe('search');
    expect(row.query).toBe('Guala Lifestyles');
    expect(JSON.parse(row.candidatesJson ?? '[]')).toHaveLength(3);
    expect(row.selectedUrl).toBe(chain[2]!.url);
    // Aucun credential ni token n'est stocké.
    const serialized = JSON.stringify(row);
    expect(serialized).not.toMatch(/token|secret|api[_-]?key|password/i);
    expect(serialized).not.toMatch(/[A-Za-z]:\\/);
  });
});

describe('DownloadService — recherche texte', () => {
  const results = [
    catalogTrack({ title: 'Lifestyle', artist: 'Rich Gang' }),
    catalogTrack({
      title: 'Lifestyles',
      artist: 'Guala',
      isrc: 'AAAAA0000001',
      urls: [
        { provider: 'spotify', url: 'https://open.spotify.com/track/abc' },
        { provider: 'deezer', url: 'https://www.deezer.com/track/1' },
      ],
    }),
  ];

  it('résout « Guala Lifestyles » en job avec chaîne de candidats', async () => {
    const provider = new FakeProvider();
    const service = makeService(provider, new FakeLocalImport(join(root, 'inbox')), {
      searchProvider: new FakeSearchProvider(results),
    });

    const outcome = await service.enqueueFromSearch({
      userId,
      username: 'owner',
      query: 'Guala Lifestyles',
    });
    expect(outcome.kind).toBe('queued');
    if (outcome.kind !== 'queued') return;

    expect(outcome.track.title).toBe('Lifestyles');
    expect(outcome.track.artist).toBe('Guala');
    // Spotify d'abord : URL la moins contrainte pour le moteur.
    expect(outcome.track.candidates[0]?.provider).toBe('spotify');
    expect(outcome.job.requestKind).toBe('search');
    expect(outcome.job.query).toBe('Guala Lifestyles');

    await waitFor(() => provider.started.length === 1);
    expect(provider.started[0]?.url).toBe('https://open.spotify.com/track/abc');
    await failWholeChain(provider, outcome.job.id, outcome.track.candidates.length, 0);
    await service.waitForIdle();
  });

  it('ne crée aucun job quand le choix est ambigu', async () => {
    const provider = new FakeProvider();
    const service = makeService(provider, new FakeLocalImport(join(root, 'inbox')), {
      searchProvider: new FakeSearchProvider([
        catalogTrack({ title: 'Lifestyles', artist: 'Guala', isrc: 'AAAAA0000001' }),
        catalogTrack({ title: 'Lifestyles', artist: 'Guala', isrc: 'BBBBB0000002' }),
      ]),
    });

    const outcome = await service.enqueueFromSearch({
      userId,
      username: 'owner',
      query: 'Guala Lifestyles',
    });
    expect(outcome.kind).toBe('ambiguous');
    expect(service.listRecentForUser(userId)).toHaveLength(0);
    expect(provider.started).toHaveLength(0);
  });

  it('signale l’absence de correspondance sans créer de job', async () => {
    const service = makeService(
      new FakeProvider(),
      new FakeLocalImport(join(root, 'inbox')),
      { searchProvider: new FakeSearchProvider([]) },
    );
    const outcome = await service.enqueueFromSearch({
      userId,
      username: 'owner',
      query: 'Guala Lifestyles',
    });
    expect(outcome.kind).toBe('no_match');
    expect(service.listRecentForUser(userId)).toHaveLength(0);
  });

  it('refuse la recherche quand aucun catalogue n’est configuré', async () => {
    const service = makeService(new FakeProvider(), new FakeLocalImport(join(root, 'inbox')));
    await expect(
      service.enqueueFromSearch({ userId, username: 'owner', query: 'Guala Lifestyles' }),
    ).rejects.toBeInstanceOf(DownloadServiceError);
  });
});

describe('DownloadService — événements et cloisonnement', () => {
  it('diffuse la progression aux abonnés et se désabonne proprement', async () => {
    const provider = new FakeProvider();
    const service = makeService(provider, new FakeLocalImport(join(root, 'inbox')));
    const job = enqueue(service, 'https://open.spotify.com/track/1');
    await waitFor(() => provider.started.length === 1);

    const seen: string[] = [];
    const unsubscribe = service.subscribe(job.id, (event) => seen.push(event.type));
    provider.emit(job.id, {
      type: 'stage',
      stage: 'downloading',
      message: null,
      track: { title: 'Lifestyles', artist: 'Guala' },
    });
    expect(seen).toContain('progress');

    unsubscribe();
    const before = seen.length;
    provider.emit(job.id, { type: 'stage', stage: 'processing', message: null });
    expect(seen).toHaveLength(before);

    provider.fail(job.id);
    await service.waitForIdle();
  });

  it('un autre compte ne voit jamais le job', async () => {
    const provider = new FakeProvider();
    const service = makeService(provider, new FakeLocalImport(join(root, 'inbox')));
    const job = enqueue(service, 'https://open.spotify.com/track/1');

    const now = new Date().toISOString();
    const otherId = handle.db
      .insert(users)
      .values({
        username: 'autre',
        displayName: 'Autre',
        passwordHash: 'x',
        role: 'USER',
        createdAt: now,
        updatedAt: now,
      })
      .returning()
      .get()!.id;

    expect(service.getJobForUser(job.id, otherId)).toBeNull();
    expect(service.listRecentForUser(otherId)).toHaveLength(0);

    await waitFor(() => provider.started.length === 1);
    provider.fail(job.id);
    await service.waitForIdle();
  });
});
