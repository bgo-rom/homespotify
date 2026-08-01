import { randomUUID } from 'node:crypto';
import { eq } from 'drizzle-orm';
import { afterEach, describe, expect, it } from 'vitest';
import { createDb, type DbHandle } from './client.js';
import {
  acquisitionJobs,
  providerHealth,
  users,
} from './schema.js';
import {
  ensureAcquisitionJobsSchema,
  ensureProviderHealthSchema,
  runMigrations,
} from './migrate.js';

let handle: DbHandle | null = null;

function setup(): { handle: DbHandle; userId: number } {
  handle = createDb(':memory:');
  runMigrations(handle, {
    info: () => undefined,
    error: () => undefined,
  });

  const now = new Date().toISOString();
  const userId = handle.db
    .insert(users)
    .values({
      username: `user_${randomUUID().slice(0, 8)}`,
      displayName: 'Test acquisition',
      passwordHash: 'test-only',
      role: 'USER',
      isActive: true,
      mustChangePassword: false,
      createdAt: now,
      updatedAt: now,
    })
    .returning({ id: users.id })
    .get().id;

  return { handle, userId };
}

function insertJob(
  db: DbHandle,
  userId: number,
  overrides: Partial<typeof acquisitionJobs.$inferInsert> = {},
): string {
  const now = new Date().toISOString();
  const id = overrides.id ?? randomUUID();

  db.db
    .insert(acquisitionJobs)
    .values({
      id,
      userId,
      query: 'Luther Creeper',
      dedupeKey: 'qobuz:luther:creeper:0',
      createdAt: now,
      updatedAt: now,
      ...overrides,
    })
    .run();

  return id;
}

afterEach(() => {
  handle?.sqlite.close();
  handle = null;
});

describe('schéma acquisition_jobs', () => {
  it('est créé par runMigrations avec ses valeurs par défaut', () => {
    const { handle: db, userId } = setup();
    const id = insertJob(db, userId);

    const row = db.db
      .select()
      .from(acquisitionJobs)
      .where(eq(acquisitionJobs.id, id))
      .get();

    expect(row).toMatchObject({
      id,
      userId,
      provider: 'QOBUZ',
      query: 'Luther Creeper',
      dedupeKey: 'qobuz:luther:creeper:0',
      status: 'QUEUED',
      progress: 0,
      attempt: 0,
      maxAttempts: 3,
      cancelRequested: false,
    });
    expect(row?.localImportJobId).toBeNull();
    expect(row?.trackId).toBeNull();
  });

  it('est idempotent après une migration complète', () => {
    const { handle: db } = setup();

    expect(
      ensureAcquisitionJobsSchema(db, {
        info: () => undefined,
        error: () => undefined,
      }),
    ).toEqual([]);
  });

  it('crée provider_health sur base vierge et reste idempotent', () => {
    const { handle: db } = setup();
    const now = new Date().toISOString();
    db.db
      .insert(providerHealth)
      .values({
        provider: 'LUCIDA',
        createdAt: now,
        updatedAt: now,
      })
      .run();
    expect(db.db.select().from(providerHealth).get()).toMatchObject({
      provider: 'LUCIDA',
      state: 'CLOSED',
      failureCount: 0,
    });
    expect(
      ensureProviderHealthSchema(db, {
        info: () => undefined,
        error: () => undefined,
      }),
    ).toEqual([]);
  });

  it('accepte PAUSED_PROVIDER et conserve la déduplication active', () => {
    const { handle: db, userId } = setup();
    insertJob(db, userId, {
      status: 'PAUSED_PROVIDER',
      dedupeKey: 'pause-active',
    });
    expect(() =>
      insertJob(db, userId, {
        dedupeKey: 'pause-active',
      }),
    ).toThrow(/UNIQUE constraint failed/);
  });

  it('refuse une progression hors de 0..100', () => {
    const { handle: db, userId } = setup();

    expect(() =>
      insertJob(db, userId, {
        progress: 101,
      }),
    ).toThrow();
  });

  it('refuse un provider autre que QOBUZ', () => {
    const { handle: db, userId } = setup();

    expect(() =>
      insertJob(db, userId, {
        provider: 'TIDAL',
      }),
    ).toThrow();
  });

  it('refuse maxAttempts hors de 1..10', () => {
    const { handle: db, userId } = setup();

    expect(() =>
      insertJob(db, userId, {
        maxAttempts: 0,
      }),
    ).toThrow();

    expect(() =>
      insertJob(db, userId, {
        id: randomUUID(),
        dedupeKey: 'qobuz:luther:creeper:max11',
        maxAttempts: 11,
      }),
    ).toThrow();
  });

  it('bloque un doublon actif puis autorise un nouveau job après COMPLETED', () => {
    const { handle: db, userId } = setup();
    const firstId = insertJob(db, userId);

    expect(() =>
      insertJob(db, userId, {
        id: randomUUID(),
      }),
    ).toThrow();

    db.db
      .update(acquisitionJobs)
      .set({
        status: 'COMPLETED',
        completedAt: new Date().toISOString(),
        updatedAt: new Date().toISOString(),
      })
      .where(eq(acquisitionJobs.id, firstId))
      .run();

    expect(() =>
      insertJob(db, userId, {
        id: randomUUID(),
      }),
    ).not.toThrow();
  });

  it('autorise la même clé active pour deux utilisateurs différents', () => {
    const { handle: db, userId } = setup();
    insertJob(db, userId);

    const now = new Date().toISOString();
    const otherUserId = db.db
      .insert(users)
      .values({
        username: `other_${randomUUID().slice(0, 8)}`,
        displayName: 'Autre utilisateur',
        passwordHash: 'test-only',
        role: 'USER',
        isActive: true,
        mustChangePassword: false,
        createdAt: now,
        updatedAt: now,
      })
      .returning({ id: users.id })
      .get().id;

    expect(() =>
      insertJob(db, otherUserId, {
        id: randomUUID(),
      }),
    ).not.toThrow();
  });
});
