import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import { createDb, type DbHandle } from '../db/client.js';
import { runMigrations } from '../db/migrate.js';
import {
  acquisitionJobs,
  users,
} from '../db/schema.js';
import {
  ProviderHealthError,
  ProviderHealthRepository,
} from './provider-health-repository.js';

const handles: DbHandle[] = [];
const directories: string[] = [];
const policy = {
  challengeCooldownSeconds: 1_800,
  rateLimitDefaultCooldownSeconds: 900,
  unavailableCooldownSeconds: 600,
  maxCooldownSeconds: 21_600,
  providerFailureWindowSeconds: 600,
  providerFailureThreshold: 2,
};

function memoryRepository(clock: () => Date, random = () => 0) {
  const handle = createDb(':memory:');
  handles.push(handle);
  runMigrations(handle, { info: () => undefined, error: () => undefined });
  return new ProviderHealthRepository(handle, policy, { clock, random });
}

function manualRepository(clock: () => Date) {
  const handle = createDb(':memory:');
  handles.push(handle);
  runMigrations(handle, { info: () => undefined, error: () => undefined });
  const now = clock().toISOString();
  const userId = handle.db
    .insert(users)
    .values({
      username: `manual_${Math.random().toString(16).slice(2)}`,
      displayName: 'Manual',
      passwordHash: 'test-only',
      role: 'USER',
      isActive: true,
      mustChangePassword: false,
      createdAt: now,
      updatedAt: now,
    })
    .returning({ id: users.id })
    .get().id;
  const jobId = '11111111-1111-4111-8111-111111111111';
  handle.db
    .insert(acquisitionJobs)
    .values({
      id: jobId,
      userId,
      provider: 'QOBUZ',
      query: 'manual',
      dedupeKey: `QOBUZ:0:${jobId}`,
      resultIndex: 0,
      status: 'SEARCHING',
      stage: 'searching',
      maxAttempts: 3,
      createdAt: now,
      updatedAt: now,
    })
    .run();
  return {
    repository: new ProviderHealthRepository(handle, policy, { clock }),
    jobId,
    userId,
  };
}

afterEach(() => {
  for (const handle of handles.splice(0)) handle.sqlite.close();
  for (const directory of directories.splice(0)) {
    rmSync(directory, { recursive: true, force: true });
  }
});

describe('ProviderHealthRepository', () => {
  it('crée un circuit CLOSED par défaut', () => {
    const repository = memoryRepository(
      () => new Date('2026-07-29T20:00:00.000Z'),
    );
    expect(repository.get()).toMatchObject({
      provider: 'LUCIDA',
      state: 'CLOSED',
      failureCount: 0,
    });
    expect(repository.publicStatus()).toMatchObject({
      provider: 'Lucida',
      available: true,
      manualRetryAllowed: false,
    });
  });

  it('ouvre immédiatement sur un challenge', () => {
    const repository = memoryRepository(
      () => new Date('2026-07-29T20:00:00.000Z'),
    );
    expect(repository.recordFailure('PROVIDER_CHALLENGE')).toMatchObject({
      state: 'OPEN',
      reasonCode: 'PROVIDER_CHALLENGE',
      retryAt: '2026-07-29T20:30:00.000Z',
    });
  });

  it('respecte Retry-After pour une limitation', () => {
    const repository = memoryRepository(
      () => new Date('2026-07-29T20:00:00.000Z'),
    );
    expect(
      repository.recordFailure('PROVIDER_RATE_LIMITED', 1_200).retryAt,
    ).toBe('2026-07-29T20:20:00.000Z');
  });

  it('n’ouvre une panne externe qu’au seuil dans la fenêtre', () => {
    let now = new Date('2026-07-29T20:00:00.000Z');
    const repository = memoryRepository(() => now);
    expect(repository.recordFailure('PROVIDER_UNAVAILABLE').state).toBe(
      'CLOSED',
    );
    now = new Date('2026-07-29T20:05:00.000Z');
    expect(repository.recordFailure('PROVIDER_UNAVAILABLE')).toMatchObject({
      state: 'OPEN',
      failureCount: 2,
      retryAt: '2026-07-29T20:15:00.000Z',
    });
  });

  it('persiste son état après recréation du repository et de la base', () => {
    const directory = mkdtempSync(join(tmpdir(), 'hs-provider-health-'));
    directories.push(directory);
    const path = join(directory, 'test.db');
    const first = createDb(path);
    runMigrations(first, { info: () => undefined, error: () => undefined });
    new ProviderHealthRepository(first, policy, {
      clock: () => new Date('2026-07-29T20:00:00.000Z'),
    }).recordFailure('PROVIDER_CHALLENGE');
    first.sqlite.close();

    const second = createDb(path);
    handles.push(second);
    runMigrations(second, { info: () => undefined, error: () => undefined });
    expect(new ProviderHealthRepository(second, policy).get()).toMatchObject({
      state: 'OPEN',
      reasonCode: 'PROVIDER_CHALLENGE',
    });
  });

  it('interdit la probe avant retryAt puis n’en réserve qu’une', () => {
    let now = new Date('2026-07-29T20:00:00.000Z');
    const repository = memoryRepository(() => now);
    repository.recordFailure('PROVIDER_CHALLENGE');
    expect(() => repository.beginManualProbe('job-1')).toThrowError(
      ProviderHealthError,
    );
    now = new Date('2026-07-29T20:31:00.000Z');
    expect(repository.beginManualProbe('job-1')).toMatchObject({
      state: 'HALF_OPEN',
      halfOpenProbeJobId: 'job-1',
    });
    expect(() => repository.beginManualProbe('job-2')).toThrowError(
      ProviderHealthError,
    );
  });

  it('ferme uniquement après le succès réel de la probe', () => {
    let now = new Date('2026-07-29T20:00:00.000Z');
    const repository = memoryRepository(() => now);
    repository.recordFailure('PROVIDER_CHALLENGE');
    now = new Date('2026-07-29T20:31:00.000Z');
    repository.beginManualProbe('job-1');
    expect(repository.recordProbeSuccess('autre').state).toBe('HALF_OPEN');
    expect(repository.recordProbeSuccess('job-1')).toMatchObject({
      state: 'CLOSED',
      failureCount: 0,
      reasonCode: null,
      retryAt: null,
      halfOpenProbeJobId: null,
    });
  });

  it('double le délai après échec HALF_OPEN avec borne maximale', () => {
    let now = new Date('2026-07-29T20:00:00.000Z');
    const repository = memoryRepository(() => now, () => 0);
    repository.recordFailure('PROVIDER_CHALLENGE');
    now = new Date('2026-07-29T20:31:00.000Z');
    repository.beginManualProbe('job-1');
    expect(repository.recordFailure('PROVIDER_CHALLENGE').retryAt).toBe(
      '2026-07-29T21:31:00.000Z',
    );
  });

  it('libère une probe annulée sans déclarer le fournisseur sain', () => {
    let now = new Date('2026-07-29T20:00:00.000Z');
    const repository = memoryRepository(() => now);
    repository.recordFailure('PROVIDER_CHALLENGE');
    now = new Date('2026-07-29T20:31:00.000Z');
    repository.beginManualProbe('job-1');
    expect(repository.releaseProbe('job-1')).toMatchObject({
      state: 'OPEN',
      halfOpenProbeJobId: null,
      reasonCode: 'PROVIDER_CHALLENGE',
    });
  });

  it('récupère une probe interrompue au redémarrage sans fermer le circuit', () => {
    let now = new Date('2026-07-29T20:00:00.000Z');
    const repository = memoryRepository(() => now);
    repository.recordFailure('PROVIDER_CHALLENGE');
    now = new Date('2026-07-29T20:31:00.000Z');
    repository.beginManualProbe('job-1');
    expect(repository.recoverInterruptedProbe()).toBe(true);
    expect(repository.get()).toMatchObject({
      state: 'OPEN',
      halfOpenProbeJobId: null,
      reasonCode: 'PROVIDER_CHALLENGE',
    });
    expect(repository.publicStatus().manualRetryAllowed).toBe(true);
  });

  it('bloque Lucida sans cooldown pendant une vérification manuelle', () => {
    const { repository, jobId, userId } = manualRepository(
      () => new Date('2026-07-30T12:00:00.000Z'),
    );
    repository.transitionChallengeToManual(jobId, userId);
    expect(repository.get()).toMatchObject({
      state: 'MANUAL_VERIFICATION_REQUIRED',
      reasonCode: 'PROVIDER_CHALLENGE',
      retryAt: null,
      openedAt: null,
      halfOpenProbeJobId: null,
      failureCount: 0,
      manualVerificationJobId: jobId,
      manualVerificationHolderJobId: null,
    });
    expect(repository.publicStatus()).toMatchObject({
      available: false,
      manualRetryAllowed: true,
      manualVerificationRequired: true,
      manualVerificationJobId: jobId,
      retryAt: null,
    });
    expect(() =>
      repository.requireManualVerification('job-2'),
    ).toThrowError(ProviderHealthError);
  });

  it('ne ferme le circuit manuel qu’après le succès réel du job réservé', () => {
    const { repository, jobId, userId } = manualRepository(
      () => new Date('2026-07-30T12:00:00.000Z'),
    );
    repository.transitionChallengeToManual(jobId, userId);
    repository.reserveManualVerification(jobId);
    expect(
      repository.recordManualVerificationSuccess('autre').state,
    ).toBe('MANUAL_VERIFICATION_REQUIRED');
    expect(
      repository.recordManualVerificationSuccess(jobId),
    ).toMatchObject({
      state: 'CLOSED',
      reasonCode: null,
      failureCount: 0,
      halfOpenProbeJobId: null,
      manualVerificationJobId: null,
      manualVerificationHolderJobId: null,
    });
  });

  it('libère une vérification annulée sans déclarer Lucida sain', () => {
    const { repository, jobId, userId } = manualRepository(
      () => new Date('2026-07-30T12:00:00.000Z'),
    );
    repository.transitionChallengeToManual(jobId, userId);
    repository.reserveManualVerification(jobId);
    expect(repository.releaseManualVerification(jobId)).toMatchObject({
      state: 'MANUAL_VERIFICATION_REQUIRED',
      halfOpenProbeJobId: null,
      manualVerificationJobId: jobId,
      manualVerificationHolderJobId: null,
    });
  });
});
