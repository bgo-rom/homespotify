import { randomUUID } from 'node:crypto';
import { eq } from 'drizzle-orm';
import { afterEach, describe, expect, it } from 'vitest';
import { createDb, type DbHandle } from '../db/client.js';
import { runMigrations } from '../db/migrate.js';
import { acquisitionJobs, providerHealth, users } from '../db/schema.js';
import { repairOrphanedManualVerification } from './repair-orphaned-manual-verification-cli.js';

let handle: DbHandle | null = null;

afterEach(() => {
  handle?.sqlite.close();
  handle = null;
});

function setupJob(status: 'FAILED' | 'CANCELLED' | 'COMPLETED' | 'MANUAL_VERIFICATION_REQUIRED') {
  handle = createDb(':memory:');
  runMigrations(handle, { info: () => undefined, error: () => undefined });
  const now = new Date().toISOString();
  const userId = handle.db
    .insert(users)
    .values({
      username: `repair_${randomUUID().slice(0, 8)}`,
      displayName: 'Repair',
      passwordHash: 'test-only',
      role: 'USER',
      isActive: true,
      mustChangePassword: false,
      createdAt: now,
      updatedAt: now,
    })
    .returning({ id: users.id })
    .get().id;
  const jobId = randomUUID();
  handle.db
    .insert(acquisitionJobs)
    .values({
      id: jobId,
      userId,
      provider: 'QOBUZ',
      query: 'repair',
      dedupeKey: `QOBUZ:0:${jobId}`,
      resultIndex: 0,
      status,
      stage:
        status === 'MANUAL_VERIFICATION_REQUIRED'
          ? 'waiting_user_verification'
          : 'failed',
      maxAttempts: 3,
      createdAt: now,
      updatedAt: now,
    })
    .run();
  handle.db
    .insert(providerHealth)
    .values({
      provider: 'LUCIDA',
      state: 'MANUAL_VERIFICATION_REQUIRED',
      reasonCode: 'PROVIDER_CHALLENGE',
      manualVerificationJobId: jobId,
      createdAt: now,
      updatedAt: now,
    })
    .run();
  return { jobId };
}

describe('repairOrphanedManualVerification', () => {
  it('ferme un état manuel sans JobId', () => {
    setupJob('MANUAL_VERIFICATION_REQUIRED');
    handle!.sqlite.pragma('ignore_check_constraints = ON');
    handle!.sqlite
      .prepare(
        `UPDATE provider_health
         SET manual_verification_job_id = NULL
         WHERE provider = 'LUCIDA'`,
      )
      .run();
    handle!.sqlite.pragma('ignore_check_constraints = OFF');
    expect(repairOrphanedManualVerification(handle!.sqlite)).toMatchObject({
      rowsModified: 1,
      after: { state: 'CLOSED', manualVerificationJobId: null },
    });
  });

  it('ferme un état manuel dont le JobId est introuvable', () => {
    const { jobId } = setupJob('MANUAL_VERIFICATION_REQUIRED');
    handle!.db
      .delete(acquisitionJobs)
      .where(eq(acquisitionJobs.id, jobId))
      .run();
    expect(repairOrphanedManualVerification(handle!.sqlite)).toMatchObject({
      rowsModified: 1,
      associatedJob: null,
      after: { state: 'CLOSED' },
    });
  });

  for (const status of ['FAILED', 'CANCELLED', 'COMPLETED'] as const) {
    it(`ferme le fournisseur si le job est ${status}`, () => {
      setupJob(status);
      expect(repairOrphanedManualVerification(handle!.sqlite))
        .toMatchObject({
          rowsModified: 1,
          after: {
            state: 'CLOSED',
            reasonCode: null,
            manualVerificationJobId: null,
          },
        });
      expect(repairOrphanedManualVerification(handle!.sqlite).rowsModified)
        .toBe(0);
    });
  }

  it('conserve un job manuel actif valide', () => {
    const { jobId } = setupJob('MANUAL_VERIFICATION_REQUIRED');
    expect(repairOrphanedManualVerification(handle!.sqlite)).toMatchObject({
      rowsModified: 0,
      after: {
        state: 'MANUAL_VERIFICATION_REQUIRED',
        manualVerificationJobId: jobId,
      },
    });
  });
});
