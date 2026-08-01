import { randomUUID } from 'node:crypto';
import {
  mkdtempSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import type { FastifyInstance } from 'fastify';
import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from 'vitest';
import { eq } from 'drizzle-orm';
import { buildApp } from '../app.js';
import type { AppConfig } from '../config.js';
import {
  acquisitionJobs,
  users,
} from '../db/schema.js';
import { hashPassword } from '../auth/passwords.js';
import type {
  AcquisitionRunner,
} from '../import/acquisition-import-service.js';
import {
  LucidaProcessError,
  type LucidaDownloadRunRequest,
  type LucidaRunResult,
  type LucidaSearchRunRequest,
} from '../import/lucida-process-runner.js';
import type {
  LucidaSearchRunner,
} from './acquisition-imports.js';
import { ProviderHealthRepository } from '../import/provider-health-repository.js';

class BlockingDownloadRunner implements AcquisitionRunner {
  readonly calls: LucidaDownloadRunRequest[] = [];
  readonly stopAll = vi.fn();

  run(request: LucidaDownloadRunRequest): Promise<LucidaRunResult> {
    this.calls.push(request);
    return new Promise<LucidaRunResult>((_resolve, reject) => {
      const cancel = () => {
        reject(
          new LucidaProcessError(
            'CANCELLED',
            'Import annulé par l’utilisateur.',
          ),
        );
      };
      if (request.signal?.aborted) {
        cancel();
        return;
      }
      request.signal?.addEventListener('abort', cancel, { once: true });
    });
  }
}

class FakeSearchRunner implements LucidaSearchRunner {
  readonly calls: LucidaSearchRunRequest[] = [];
  handler: (
    request: LucidaSearchRunRequest,
  ) => Promise<LucidaRunResult> = async () => ({
    mode: 'search',
    count: 1,
    results: [
      {
        type: 'search_result',
        index: 0,
        title: 'creeper',
        artist: 'Luther',
        album: 'creeper + seed',
        duration: 160,
      },
    ],
  });

  run(request: LucidaSearchRunRequest): Promise<LucidaRunResult> {
    this.calls.push(request);
    return this.handler(request);
  }
}

let root: string;
let app: FastifyInstance;
let ownerToken: string;
let listenerToken: string;
let listenerId: number;
let downloadRunner: BlockingDownloadRunner;
let searchRunner: FakeSearchRunner;

async function login(
  username: string,
  password: string,
): Promise<string> {
  const response = await app.inject({
    method: 'POST',
    url: '/api/auth/login',
    payload: { username, password },
  });
  expect(response.statusCode).toBe(200);
  return response.json().accessToken as string;
}

function auth(token: string) {
  return {
    authorization: `Bearer ${token}`,
  };
}

beforeEach(async () => {
  root = mkdtempSync(
    join(tmpdir(), 'homespotify-acquisition-routes-'),
  );
  const scriptPath = join(root, 'lucida_dl_final.py');
  writeFileSync(scriptPath, '# test-only\n', 'utf-8');

  const config: AppConfig = {
    nodeEnv: 'test',
    host: '127.0.0.1',
    port: 0,
    dbPath: ':memory:',
    logLevel: 'fatal',
    musicDir: join(root, 'music'),
    incomingDir: join(root, 'incoming'),
    importRoot: join(root, 'imports'),
    coversDir: join(root, 'covers'),
    maxUploadBytes: 200 * 1024 * 1024,
    authTokenSecret:
      'test-secret-at-least-thirty-two-characters',
    accessTokenTtlSeconds: 900,
    refreshTokenTtlSeconds: 86_400,
    lucida: {
      scriptPath,
      pythonPath: 'python-test',
      processTimeoutMs: 300_000,
      maxConcurrentDownloads: 3,
      challengeCooldownSeconds: 1_800,
      rateLimitDefaultCooldownSeconds: 900,
      unavailableCooldownSeconds: 600,
      maxCooldownSeconds: 21_600,
      providerFailureWindowSeconds: 600,
      providerFailureThreshold: 2,
      interactiveVerificationEnabled: true,
      interactiveVerificationTimeoutSeconds: 120,
    },
  };

  downloadRunner = new BlockingDownloadRunner();
  searchRunner = new FakeSearchRunner();

  app = buildApp(config, {
    importWatcher: false,
    lucidaRunner: downloadRunner,
    lucidaSearchRunner: searchRunner,
    lucidaSearchTimeoutMs: 25,
  });
  await app.ready();

  const ownerPassword = 'owner-password-123';
  const bootstrap = await app.inject({
    method: 'POST',
    url: '/api/auth/bootstrap',
    payload: {
      username: 'owner',
      displayName: 'Owner',
      password: ownerPassword,
      passwordConfirmation: ownerPassword,
    },
  });
  expect(bootstrap.statusCode).toBe(201);
  ownerToken = bootstrap.json().accessToken as string;

  const listenerPassword = 'listener-password-123';
  const now = new Date().toISOString();
  listenerId = app.dbHandle.db
    .insert(users)
    .values({
      username: 'listener',
      displayName: 'Listener',
      passwordHash: await hashPassword(listenerPassword),
      role: 'USER',
      isActive: true,
      mustChangePassword: false,
      createdAt: now,
      updatedAt: now,
    })
    .returning({ id: users.id })
    .get().id;
  listenerToken = await login('listener', listenerPassword);
});

afterEach(async () => {
  await app.close();
  rmSync(root, { recursive: true, force: true });
});

describe('routes d’acquisition authentifiées', () => {
  it('exige une authentification', async () => {
    const search = await app.inject({
      method: 'POST',
      url: '/api/imports/search',
      payload: { query: 'Luther Creeper' },
    });
    const jobs = await app.inject({
      method: 'GET',
      url: '/api/imports/jobs',
    });

    expect(search.statusCode).toBe(401);
    expect(jobs.statusCode).toBe(401);
  });

  it('retourne les résultats sans chemin interne et sans créer de job', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/api/imports/search',
      headers: auth(ownerToken),
      payload: { query: '  Luther   Creeper  ' },
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({
      results: [
        {
          index: 0,
          title: 'creeper',
          artist: 'Luther',
          album: 'creeper + seed',
          duration: 160,
        },
      ],
    });
    expect(searchRunner.calls[0]?.query).toBe('Luther Creeper');
    expect(JSON.stringify(response.json())).not.toMatch(
      /filepath|absolute|stderr|dedupe/i,
    );
    expect(
      app.dbHandle.db.select().from(acquisitionJobs).all(),
    ).toHaveLength(0);
  });

  it('valide strictement query avant le runner', async () => {
    for (const query of ['', '   ', 'x'.repeat(201), 'ligne\ninterdite']) {
      const response = await app.inject({
        method: 'POST',
        url: '/api/imports/search',
        headers: auth(ownerToken),
        payload: { query },
      });
      expect(response.statusCode).toBe(400);
    }

    expect(searchRunner.calls).toHaveLength(0);
  });

  it('convertit NO_RESULTS en liste vide', async () => {
    searchRunner.handler = async () => {
      throw new LucidaProcessError(
        'NO_RESULTS',
        'Aucun résultat.',
      );
    };

    const response = await app.inject({
      method: 'POST',
      url: '/api/imports/search',
      headers: auth(ownerToken),
      payload: { query: 'Introuvable' },
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ results: [] });
  });

  it('convertit le timeout de recherche en 504', async () => {
    searchRunner.handler = async (request) =>
      new Promise<LucidaRunResult>((_resolve, reject) => {
        request.signal?.addEventListener(
          'abort',
          () => {
            reject(
              new LucidaProcessError(
                'CANCELLED',
                'Recherche annulée.',
              ),
            );
          },
          { once: true },
        );
      });

    const response = await app.inject({
      method: 'POST',
      url: '/api/imports/search',
      headers: auth(ownerToken),
      payload: { query: 'Timeout' },
    });

    expect(response.statusCode).toBe(504);
    expect(response.json()).toMatchObject({
      error: 'search_timeout',
    });
  });

  it('masque les diagnostics internes d’un échec externe', async () => {
    searchRunner.handler = async () => {
      throw new LucidaProcessError(
        'PROTOCOL_ERROR',
        'JSON invalide avec C:\\secret\\fichier',
        {
          stderr: 'token privé et chemin serveur',
        },
      );
    };

    const response = await app.inject({
      method: 'POST',
      url: '/api/imports/search',
      headers: auth(ownerToken),
      payload: { query: 'Erreur' },
    });

    expect(response.statusCode).toBe(502);
    expect(response.json()).toEqual({
      statusCode: 502,
      error: 'external_tool_error',
      message: 'La recherche distante a échoué.',
    });
    expect(response.body).not.toMatch(/secret|stderr|token privé/i);
  });

  it('crée un job borné, bloque le doublon et ne divulgue aucun chemin', async () => {
    const payload = {
      query: 'Luther Creeper',
      resultIndex: 0,
      service: 'Qobuz',
      downloadTimeoutSeconds: 75,
      downloadRetries: 2,
    };

    const created = await app.inject({
      method: 'POST',
      url: '/api/imports/jobs',
      headers: auth(ownerToken),
      payload,
    });

    expect(created.statusCode).toBe(202);
    const body = created.json();
    expect(body.accepted).toBe(true);
    expect(body.item).toMatchObject({
      query: 'Luther Creeper',
      provider: 'Qobuz',
      resultIndex: 0,
      status: 'QUEUED',
      maxAttempts: 3,
    });
    expect(JSON.stringify(body)).not.toMatch(
      /downloadedRelativePath|localImportJobId|dedupeKey|absoluteFilePath|userId/i,
    );

    const duplicate = await app.inject({
      method: 'POST',
      url: '/api/imports/jobs',
      headers: auth(ownerToken),
      payload,
    });
    expect(duplicate.statusCode).toBe(409);
    expect(duplicate.json().error).toBe('active_duplicate');
  });

  it('valide les options de création avant de persister', async () => {
    const invalidPayloads = [
      {
        query: 'Test',
        resultIndex: -1,
      },
      {
        query: 'Test',
        resultIndex: 0,
        service: 'Tidal',
      },
      {
        query: 'Test',
        resultIndex: 0,
        downloadTimeoutSeconds: 9,
      },
      {
        query: 'Test',
        resultIndex: 0,
        downloadRetries: 10,
      },
    ];

    for (const payload of invalidPayloads) {
      const response = await app.inject({
        method: 'POST',
        url: '/api/imports/jobs',
        headers: auth(ownerToken),
        payload,
      });
      expect(response.statusCode).toBe(400);
    }

    expect(
      app.dbHandle.db.select().from(acquisitionJobs).all(),
    ).toHaveLength(0);
    expect(downloadRunner.calls).toHaveLength(0);
  });

  it('isole GET, liste et DELETE par utilisateur', async () => {
    const created = await app.inject({
      method: 'POST',
      url: '/api/imports/jobs',
      headers: auth(ownerToken),
      payload: {
        query: 'Privé',
        resultIndex: 0,
      },
    });
    const jobId = created.json().item.id as string;

    const ownerGet = await app.inject({
      method: 'GET',
      url: `/api/imports/jobs/${jobId}`,
      headers: auth(ownerToken),
    });
    expect(ownerGet.statusCode).toBe(200);

    const listenerGet = await app.inject({
      method: 'GET',
      url: `/api/imports/jobs/${jobId}`,
      headers: auth(listenerToken),
    });
    expect(listenerGet.statusCode).toBe(404);

    const listenerList = await app.inject({
      method: 'GET',
      url: '/api/imports/jobs',
      headers: auth(listenerToken),
    });
    expect(listenerList.statusCode).toBe(200);
    expect(listenerList.json().items).toEqual([]);

    const listenerDelete = await app.inject({
      method: 'DELETE',
      url: `/api/imports/jobs/${jobId}`,
      headers: auth(listenerToken),
    });
    expect(listenerDelete.statusCode).toBe(404);

    const ownerDelete = await app.inject({
      method: 'DELETE',
      url: `/api/imports/jobs/${jobId}`,
      headers: auth(ownerToken),
    });
    expect(ownerDelete.statusCode).toBe(202);
    expect(ownerDelete.json()).toMatchObject({
      accepted: true,
      jobId,
    });
  });

  it('filtre la liste en SQL et refuse limit/status/id invalides', async () => {
    const now = new Date().toISOString();
    app.dbHandle.db
      .insert(acquisitionJobs)
      .values({
        id: randomUUID(),
        userId: listenerId,
        provider: 'QOBUZ',
        query: 'Terminé',
        dedupeKey: `QOBUZ:0:termine-${randomUUID()}`,
        resultIndex: 0,
        status: 'COMPLETED',
        progress: 100,
        maxAttempts: 3,
        createdAt: now,
        updatedAt: now,
        completedAt: now,
      })
      .run();

    const filtered = await app.inject({
      method: 'GET',
      url: '/api/imports/jobs?status=COMPLETED&limit=1',
      headers: auth(listenerToken),
    });
    expect(filtered.statusCode).toBe(200);
    expect(filtered.json().items).toHaveLength(1);
    expect(filtered.json().items[0].status).toBe('COMPLETED');

    for (const url of [
      '/api/imports/jobs?limit=0',
      '/api/imports/jobs?limit=abc',
      '/api/imports/jobs?status=UNKNOWN',
    ]) {
      const response = await app.inject({
        method: 'GET',
        url,
        headers: auth(listenerToken),
      });
      expect(response.statusCode).toBe(400);
    }

    const invalidId = await app.inject({
      method: 'GET',
      url: '/api/imports/jobs/not-a-uuid',
      headers: auth(listenerToken),
    });
    expect(invalidId.statusCode).toBe(400);
  });

  it('rend DELETE idempotent pour un job déjà terminal sans exposer son erreur brute', async () => {
    const now = new Date().toISOString();
    const id = randomUUID();
    app.dbHandle.db
      .insert(acquisitionJobs)
      .values({
        id,
        userId: listenerId,
        provider: 'QOBUZ',
        query: 'Déjà fini',
        dedupeKey: `QOBUZ:0:fini-${randomUUID()}`,
        resultIndex: 0,
        status: 'FAILED',
        progress: 10,
        maxAttempts: 3,
        errorCode: 'INTERNAL_ERROR',
        errorMessage: 'C:\\serveur\\secret\\track.flac',
        createdAt: now,
        updatedAt: now,
        completedAt: now,
      })
      .run();

    const getResponse = await app.inject({
      method: 'GET',
      url: `/api/imports/jobs/${id}`,
      headers: auth(listenerToken),
    });
    expect(getResponse.statusCode).toBe(200);
    expect(getResponse.body).not.toMatch(/serveur|secret|track\.flac/i);
    expect(getResponse.json().item.errorMessage).toBe(
      'L’acquisition a échoué.',
    );

    const response = await app.inject({
      method: 'DELETE',
      url: `/api/imports/jobs/${id}`,
      headers: auth(listenerToken),
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({
      accepted: false,
      jobId: id,
      status: 'FAILED',
    });

    const persisted = app.dbHandle.db
      .select()
      .from(acquisitionJobs)
      .where(eq(acquisitionJobs.id, id))
      .get();
    expect(persisted?.status).toBe('FAILED');
  });

  it('protège provider-status par authentification et expose un contrat sûr', async () => {
    const anonymous = await app.inject({
      method: 'GET',
      url: '/api/imports/provider-status',
    });
    expect(anonymous.statusCode).toBe(401);

    new ProviderHealthRepository(app.dbHandle, {
      challengeCooldownSeconds: 1_800,
      rateLimitDefaultCooldownSeconds: 900,
      unavailableCooldownSeconds: 600,
      maxCooldownSeconds: 21_600,
      providerFailureWindowSeconds: 600,
      providerFailureThreshold: 2,
    }).recordFailure('PROVIDER_CHALLENGE');
    const response = await app.inject({
      method: 'GET',
      url: '/api/imports/provider-status',
      headers: auth(listenerToken),
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toMatchObject({
      provider: 'Lucida',
      state: 'OPEN',
      available: false,
      reasonCode: 'PROVIDER_CHALLENGE',
      message: 'Le service est temporairement en pause.',
      manualRetryAllowed: false,
    });
    expect(response.body).not.toMatch(
      /stderr|cookie|cf-mitigated|https?:\/\/|[A-Z]:\\/i,
    );

    app.dbHandle.sqlite.pragma('ignore_check_constraints = ON');
    app.dbHandle.sqlite
      .prepare(
        `UPDATE provider_health
         SET state = 'MANUAL_VERIFICATION_REQUIRED',
             reason_code = 'PROVIDER_CHALLENGE',
             retry_at = NULL,
             manual_verification_job_id = NULL,
             manual_verification_holder_job_id = NULL
         WHERE provider = 'LUCIDA'`,
      )
      .run();
    app.dbHandle.sqlite.pragma('ignore_check_constraints = OFF');
    const repaired = await app.inject({
      method: 'GET',
      url: '/api/imports/provider-status',
      headers: auth(listenerToken),
    });
    expect(repaired.json()).toMatchObject({
      state: 'CLOSED',
      available: true,
      reasonCode: null,
      manualVerificationRequired: false,
      manualVerificationJobId: null,
    });
  });

  it('crée un job PAUSED_PROVIDER sans spawn quand le circuit est OPEN', async () => {
    new ProviderHealthRepository(app.dbHandle, {
      challengeCooldownSeconds: 1_800,
      rateLimitDefaultCooldownSeconds: 900,
      unavailableCooldownSeconds: 600,
      maxCooldownSeconds: 21_600,
      providerFailureWindowSeconds: 600,
      providerFailureThreshold: 2,
    }).recordFailure('PROVIDER_CHALLENGE');

    const response = await app.inject({
      method: 'POST',
      url: '/api/imports/jobs',
      headers: auth(listenerToken),
      payload: {
        query: 'Luther Creeper',
        resultIndex: 0,
        service: 'Qobuz',
      },
    });
    expect(response.statusCode).toBe(202);
    expect(response.json().item.status).toBe('PAUSED_PROVIDER');
    expect(downloadRunner.calls).toHaveLength(0);
  });

  it('contrôle le contexte et le résultat du helper sans donnée sensible', async () => {
    const now = new Date().toISOString();
    const jobId = randomUUID();
    app.dbHandle.db
      .insert(acquisitionJobs)
      .values({
        id: jobId,
        userId: listenerId,
        provider: 'QOBUZ',
        query: 'Vérification helper',
        dedupeKey: `QOBUZ:0:helper-${randomUUID()}`,
        resultIndex: 0,
        status: 'MANUAL_VERIFICATION_REQUIRED',
        stage: 'waiting_user_verification',
        progress: 25,
        maxAttempts: 3,
        createdAt: now,
        updatedAt: now,
      })
      .run();
    new ProviderHealthRepository(app.dbHandle, {
      challengeCooldownSeconds: 1_800,
      rateLimitDefaultCooldownSeconds: 900,
      unavailableCooldownSeconds: 600,
      maxCooldownSeconds: 21_600,
      providerFailureWindowSeconds: 600,
      providerFailureThreshold: 2,
    }).requireManualVerification(jobId);

    const manualStatus = await app.inject({
      method: 'GET',
      url: '/api/imports/provider-status',
      headers: auth(listenerToken),
    });
    expect(manualStatus.json()).toMatchObject({
      state: 'MANUAL_VERIFICATION_REQUIRED',
      available: false,
      reasonCode: 'PROVIDER_CHALLENGE',
      retryAt: null,
      manualRetryAllowed: true,
      manualVerificationRequired: true,
      manualVerificationJobId: jobId,
      message: 'Une vérification manuelle est nécessaire sur le serveur.',
    });

    const denied = await app.inject({
      method: 'GET',
      url: `/api/imports/jobs/${jobId}/manual-verification`,
      headers: auth(ownerToken),
    });
    expect(denied.statusCode).toBe(404);

    const context = await app.inject({
      method: 'GET',
      url: `/api/imports/jobs/${jobId}/manual-verification`,
      headers: auth(listenerToken),
    });
    expect(context.statusCode).toBe(200);
    expect(context.json()).toEqual({
      jobId,
      query: 'Vérification helper',
      resultIndex: 0,
      verificationTimeoutSeconds: 120,
    });
    expect(context.body).not.toMatch(
      /stderr|cookie|token|cf_clearance|[A-Z]:\\/i,
    );

    const invalid = await app.inject({
      method: 'POST',
      url: `/api/imports/jobs/${jobId}/manual-verification-result`,
      headers: auth(listenerToken),
      payload: { result: 'unknown', cookie: 'forbidden' },
    });
    expect(invalid.statusCode).toBe(400);

    const cancelled = await app.inject({
      method: 'POST',
      url: `/api/imports/jobs/${jobId}/manual-verification-result`,
      headers: auth(listenerToken),
      payload: { result: 'cancelled' },
    });
    expect(cancelled.statusCode).toBe(202);
    expect(cancelled.json().item.status).toBe('CANCELLED');

    const replay = await app.inject({
      method: 'POST',
      url: `/api/imports/jobs/${jobId}/manual-verification-result`,
      headers: auth(listenerToken),
      payload: { result: 'cancelled' },
    });
    expect(replay.statusCode).toBe(409);

    const failedJobId = randomUUID();
    app.dbHandle.db
      .insert(acquisitionJobs)
      .values({
        id: failedJobId,
        userId: listenerId,
        provider: 'QOBUZ',
        query: 'Ancien échec',
        dedupeKey: `QOBUZ:0:failed-${randomUUID()}`,
        resultIndex: 0,
        status: 'FAILED',
        stage: 'failed',
        errorCode: 'SEARCH_FAILED',
        maxAttempts: 3,
        createdAt: now,
        updatedAt: now,
      })
      .run();
    const failedContext = await app.inject({
      method: 'GET',
      url: `/api/imports/jobs/${failedJobId}/manual-verification`,
      headers: auth(listenerToken),
    });
    expect(failedContext.statusCode).toBe(409);
  });
});
