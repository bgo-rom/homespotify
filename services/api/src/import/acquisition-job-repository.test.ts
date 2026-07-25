import { randomUUID } from 'node:crypto';
import { eq } from 'drizzle-orm';
import { afterEach, describe, expect, it } from 'vitest';
import { createDb, type DbHandle } from '../db/client.js';
import { runMigrations } from '../db/migrate.js';
import { acquisitionJobs, users } from '../db/schema.js';
import {
  AcquisitionJobRepository,
  AcquisitionJobRepositoryError,
  buildAcquisitionDedupeKey,
} from './acquisition-job-repository.js';

let handle: DbHandle | null = null;

function setup(): {
  handle: DbHandle;
  repository: AcquisitionJobRepository;
  firstUserId: number;
  secondUserId: number;
} {
  handle = createDb(':memory:');
  runMigrations(handle, {
    info: () => undefined,
    error: () => undefined,
  });

  const now = new Date().toISOString();

  const insertUser = (username: string): number =>
    handle!.db
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

  return {
    handle,
    repository: new AcquisitionJobRepository(handle),
    firstUserId: insertUser(`alice_${randomUUID().slice(0, 8)}`),
    secondUserId: insertUser(`bob_${randomUUID().slice(0, 8)}`),
  };
}

afterEach(() => {
  handle?.sqlite.close();
  handle = null;
});

describe('AcquisitionJobRepository', () => {
  it('normalise une clé de déduplication stable', () => {
    expect(
      buildAcquisitionDedupeKey({
        provider: 'QOBUZ',
        query: '  Luthér   Creeper! ',
        resultIndex: 0,
      }),
    ).toBe('QOBUZ:0:luther creeper');

    expect(
      buildAcquisitionDedupeKey({
        provider: 'QOBUZ',
        query: 'Luther Creeper',
        resultIndex: null,
      }),
    ).toBe('QOBUZ:AUTO:luther creeper');
  });

  it('crée un job avec ses valeurs par défaut', () => {
    const { repository, firstUserId } = setup();

    const row = repository.createJob({
      userId: firstUserId,
      query: '  Luther   Creeper  ',
      resultIndex: 0,
    });

    expect(row).toMatchObject({
      userId: firstUserId,
      provider: 'QOBUZ',
      query: 'Luther Creeper',
      resultIndex: 0,
      status: 'QUEUED',
      progress: 0,
      attempt: 0,
      maxAttempts: 3,
      cancelRequested: false,
    });
    expect(row.id).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
    );
  });

  it('rejette les entrées invalides', () => {
    const { repository, firstUserId } = setup();

    expect(() =>
      repository.createJob({
        userId: firstUserId,
        query: ' ',
      }),
    ).toThrowError(AcquisitionJobRepositoryError);

    expect(() =>
      repository.createJob({
        userId: firstUserId,
        query: 'Test',
        resultIndex: -1,
      }),
    ).toThrowError(AcquisitionJobRepositoryError);

    expect(() =>
      repository.createJob({
        userId: firstUserId,
        query: 'Test',
        maxAttempts: 11,
      }),
    ).toThrowError(AcquisitionJobRepositoryError);
  });

  it('bloque un doublon actif du même utilisateur', () => {
    const { repository, firstUserId } = setup();

    repository.createJob({
      userId: firstUserId,
      query: 'Luther Creeper',
      resultIndex: 0,
    });

    expect(() =>
      repository.createJob({
        userId: firstUserId,
        query: '  LUTHÉR creeper! ',
        resultIndex: 0,
      }),
    ).toThrowError(
      expect.objectContaining({
        code: 'active_duplicate',
      }),
    );
  });

  it('autorise la même recherche active pour deux utilisateurs', () => {
    const { repository, firstUserId, secondUserId } = setup();

    repository.createJob({
      userId: firstUserId,
      query: 'Luther Creeper',
      resultIndex: 0,
    });

    expect(() =>
      repository.createJob({
        userId: secondUserId,
        query: 'Luther Creeper',
        resultIndex: 0,
      }),
    ).not.toThrow();
  });

  it('isole strictement la lecture par userId', () => {
    const { repository, firstUserId, secondUserId } = setup();

    const row = repository.createJob({
      userId: firstUserId,
      query: 'Luther Creeper',
      resultIndex: 0,
    });

    expect(repository.getJobForUser(row.id, firstUserId)?.id).toBe(row.id);
    expect(repository.getJobForUser(row.id, secondUserId)).toBeNull();

    expect(() =>
      repository.requireJobForUser(row.id, secondUserId),
    ).toThrowError(
      expect.objectContaining({
        code: 'job_not_found',
      }),
    );
  });

  it('liste uniquement les jobs récents du bon utilisateur', () => {
    const { handle: db, repository, firstUserId, secondUserId } = setup();

    const first = repository.createJob({
      userId: firstUserId,
      query: 'Premier',
      resultIndex: 0,
    });
    repository.updateJob(first.id, firstUserId, {
      status: 'COMPLETED',
    });
    db.db
      .update(acquisitionJobs)
      .set({
        createdAt: '2020-01-01T00:00:00.000Z',
        updatedAt: '2020-01-01T00:00:00.000Z',
      })
      .where(eq(acquisitionJobs.id, first.id))
      .run();

    const second = repository.createJob({
      userId: firstUserId,
      query: 'Deuxième',
      resultIndex: 0,
    });

    repository.createJob({
      userId: secondUserId,
      query: 'Invisible',
      resultIndex: 0,
    });

    const rows = repository.listRecentForUser(firstUserId, 10);
    expect(rows.map((row) => row.id)).toEqual([second.id, first.id]);
    expect(rows.every((row) => row.userId === firstUserId)).toBe(true);
  });

  it('filtre réellement les jobs par statut avant la limite SQL', () => {
    const { repository, firstUserId } = setup();

    const completed = repository.createJob({
      userId: firstUserId,
      query: 'Terminé',
      resultIndex: 0,
    });
    repository.updateJob(completed.id, firstUserId, {
      status: 'COMPLETED',
    });

    repository.createJob({
      userId: firstUserId,
      query: 'Actif',
      resultIndex: 0,
    });

    expect(
      repository.listRecentForUser(
        firstUserId,
        1,
        'COMPLETED',
      ).map((row) => row.id),
    ).toEqual([completed.id]);
  });

  it('met à jour le job et gère automatiquement les dates terminales', () => {
    const { repository, firstUserId } = setup();

    const row = repository.createJob({
      userId: firstUserId,
      query: 'Luther Creeper',
      resultIndex: 0,
    });

    const downloading = repository.updateJob(row.id, firstUserId, {
      status: 'DOWNLOADING',
      stage: 'downloading',
      progress: 42,
      attempt: 1,
      selectedTitle: 'creeper',
      selectedArtist: 'Luther',
      selectedAlbum: 'creeper + seed',
      selectedDurationSeconds: 160,
    });

    expect(downloading.startedAt).not.toBeNull();
    expect(downloading.completedAt).toBeNull();
    expect(downloading.progress).toBe(42);

    const completed = repository.updateJob(row.id, firstUserId, {
      status: 'COMPLETED',
      errorCode: 'OLD_ERROR',
      errorMessage: 'Ancienne erreur',
    });

    expect(completed.progress).toBe(100);
    expect(completed.completedAt).not.toBeNull();
    expect(completed.errorCode).toBeNull();
    expect(completed.errorMessage).toBeNull();
  });

  it('rejette une progression ou une référence invalide', () => {
    const { repository, firstUserId } = setup();

    const row = repository.createJob({
      userId: firstUserId,
      query: 'Test',
      resultIndex: 0,
    });

    expect(() =>
      repository.updateJob(row.id, firstUserId, {
        progress: 101,
      }),
    ).toThrowError(AcquisitionJobRepositoryError);

    expect(() =>
      repository.updateJob(row.id, firstUserId, {
        localImportJobId: 0,
      }),
    ).toThrowError(AcquisitionJobRepositoryError);
  });

  it('demande l’annulation uniquement pour le propriétaire et un job actif', () => {
    const { repository, firstUserId, secondUserId } = setup();

    const row = repository.createJob({
      userId: firstUserId,
      query: 'Test',
      resultIndex: 0,
    });

    expect(() =>
      repository.requestCancellation(row.id, secondUserId),
    ).toThrowError(
      expect.objectContaining({
        code: 'job_not_found',
      }),
    );

    expect(repository.requestCancellation(row.id, firstUserId)).toBe(true);
    expect(
      repository.requireJobForUser(row.id, firstUserId).cancelRequested,
    ).toBe(true);

    repository.updateJob(row.id, firstUserId, {
      status: 'CANCELLED',
    });

    expect(repository.requestCancellation(row.id, firstUserId)).toBe(false);
  });

  it('marque uniquement les jobs actifs comme interrompus au redémarrage', () => {
    const { repository, firstUserId } = setup();

    const active = repository.createJob({
      userId: firstUserId,
      query: 'Actif',
      resultIndex: 0,
    });

    const completed = repository.createJob({
      userId: firstUserId,
      query: 'Terminé',
      resultIndex: 0,
    });
    repository.updateJob(completed.id, firstUserId, {
      status: 'COMPLETED',
    });

    expect(repository.markActiveJobsInterruptedOnStartup()).toBe(1);

    expect(repository.requireJobForUser(active.id, firstUserId)).toMatchObject({
      status: 'INTERRUPTED',
      stage: 'interrupted',
      errorCode: 'SERVER_RESTART',
    });
    expect(
      repository.requireJobForUser(completed.id, firstUserId).status,
    ).toBe('COMPLETED');
  });
});
