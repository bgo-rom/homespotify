import { randomUUID } from 'node:crypto';
import { afterEach, expect, it } from 'vitest';
import { createDb, type DbHandle } from '../db/client.js';
import { runMigrations } from '../db/migrate.js';
import {
  acquisitionJobs,
  providerHealth,
  users,
} from '../db/schema.js';
import { resetInteractiveChallengeState } from './reset-interactive-challenge-state-cli.js';

let handle: DbHandle | null = null;

afterEach(() => {
  handle?.sqlite.close();
  handle = null;
});

it('convertit uniquement le challenge legacy et reste idempotent', () => {
  handle = createDb(':memory:');
  runMigrations(handle, { info: () => undefined, error: () => undefined });
  const now = new Date().toISOString();
  const userId = handle.db
    .insert(users)
    .values({
      username: `maintenance_${randomUUID().slice(0, 8)}`,
      displayName: 'Maintenance',
      passwordHash: 'test-only',
      role: 'USER',
      isActive: true,
      mustChangePassword: false,
      createdAt: now,
      updatedAt: now,
    })
    .returning({ id: users.id })
    .get().id;
  const challengeId = randomUUID();
  const rateLimitId = randomUUID();
  handle.db.insert(acquisitionJobs).values([
    {
      id: challengeId,
      userId,
      provider: 'QOBUZ',
      query: 'challenge',
      dedupeKey: `QOBUZ:0:${challengeId}`,
      resultIndex: 0,
      status: 'PAUSED_PROVIDER',
      stage: 'provider_paused',
      errorCode: 'PROVIDER_CHALLENGE',
      maxAttempts: 3,
      createdAt: now,
      updatedAt: now,
    },
    {
      id: rateLimitId,
      userId,
      provider: 'QOBUZ',
      query: 'rate limit',
      dedupeKey: `QOBUZ:0:${rateLimitId}`,
      resultIndex: 0,
      status: 'PAUSED_PROVIDER',
      stage: 'provider_paused',
      errorCode: 'PROVIDER_RATE_LIMITED',
      maxAttempts: 3,
      createdAt: now,
      updatedAt: now,
    },
  ]).run();
  handle.db.insert(providerHealth).values({
    provider: 'LUCIDA',
    state: 'OPEN',
    reasonCode: 'PROVIDER_CHALLENGE',
    openedAt: now,
    retryAt: new Date(Date.now() + 1_800_000).toISOString(),
    createdAt: now,
    updatedAt: now,
  }).run();

  expect(resetInteractiveChallengeState(handle.sqlite)).toEqual({
    providerStatesConverted: 1,
    jobsConverted: 1,
  });
  expect(resetInteractiveChallengeState(handle.sqlite)).toEqual({
    providerStatesConverted: 0,
    jobsConverted: 0,
  });
  expect(
    handle.db.select().from(providerHealth).get(),
  ).toMatchObject({
    state: 'MANUAL_VERIFICATION_REQUIRED',
    reasonCode: 'PROVIDER_CHALLENGE',
    retryAt: null,
    openedAt: null,
    halfOpenProbeJobId: null,
    manualVerificationJobId: challengeId,
  });
  const jobs = handle.db.select().from(acquisitionJobs).all();
  expect(jobs.find((job) => job.id === challengeId)).toMatchObject({
    status: 'MANUAL_VERIFICATION_REQUIRED',
    stage: 'waiting_user_verification',
  });
  expect(jobs.find((job) => job.id === rateLimitId)?.status)
    .toBe('PAUSED_PROVIDER');
});
