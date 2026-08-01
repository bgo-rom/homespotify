import { and, eq } from 'drizzle-orm';
import type { DbHandle } from '../db/client.js';
import {
  acquisitionJobs,
  monochromeManualSessions,
} from '../db/schema.js';

export type MonochromeManualSessionRow =
  typeof monochromeManualSessions.$inferSelect;

export class MonochromeManualSessionError extends Error {
  constructor(
    readonly code:
      | 'invalid_state'
      | 'holder_busy'
      | 'not_found'
      | 'replayed',
    message: string,
  ) {
    super(message);
    this.name = 'MonochromeManualSessionError';
  }
}

export class MonochromeManualSessionRepository {
  constructor(private readonly handle: DbHandle) {}

  offer(jobId: string, userId: number, fallbackReasonCode: string): void {
    const now = new Date().toISOString();
    try {
      this.handle.sqlite.transaction(() => {
        const job = this.handle.db
          .select()
          .from(acquisitionJobs)
          .where(
            and(
              eq(acquisitionJobs.id, jobId),
              eq(acquisitionJobs.userId, userId),
            ),
          )
          .get();
        if (
          !job ||
          job.cancelRequested ||
          job.status === 'COMPLETED' ||
          job.status === 'IMPORTING'
        ) {
          throw new MonochromeManualSessionError(
            'invalid_state',
            'Ce job ne peut pas utiliser le fallback Monochrome.',
          );
        }
        this.handle.db
          .insert(monochromeManualSessions)
          .values({
            jobId,
            userId,
            status: 'WAITING',
            createdAt: now,
            updatedAt: now,
          })
          .run();
        this.handle.db
          .update(acquisitionJobs)
          .set({
            status: 'WAITING_MANUAL_DOWNLOAD',
            stage: 'waiting_manual_download',
            progress: 0,
            providerUsed: 'MONOCHROME_MANUAL',
            fallbackFrom: 'LUCIDA',
            fallbackReasonCode: fallbackReasonCode.slice(0, 100),
            errorCode: null,
            errorMessage: null,
            message:
              'Monochrome est ouvert sur le serveur. Vérifie le morceau puis clique manuellement sur Download dans Chromium.',
            completedAt: null,
            trackId: null,
            updatedAt: now,
          })
          .where(
            and(
              eq(acquisitionJobs.id, jobId),
              eq(acquisitionJobs.userId, userId),
            ),
          )
          .run();
      })();
    } catch (error) {
      if (error instanceof MonochromeManualSessionError) throw error;
      if (
        error instanceof Error &&
        /UNIQUE constraint failed/u.test(error.message)
      ) {
        throw new MonochromeManualSessionError(
          'holder_busy',
          'Une session Monochrome est déjà en attente.',
        );
      }
      throw error;
    }
  }

  reserve(jobId: string, userId: number): MonochromeManualSessionRow {
    const now = new Date().toISOString();
    const session = this.handle.db
      .update(monochromeManualSessions)
      .set({
        status: 'RESERVED',
        reservedAt: now,
        startedAt: now,
        updatedAt: now,
      })
      .where(
        and(
          eq(monochromeManualSessions.jobId, jobId),
          eq(monochromeManualSessions.userId, userId),
          eq(monochromeManualSessions.status, 'WAITING'),
        ),
      )
      .returning()
      .get();
    if (session) return session;
    const existing = this.get(jobId, userId);
    throw new MonochromeManualSessionError(
      existing?.status === 'RESULT_RECEIVED' ? 'replayed' : 'holder_busy',
      existing
        ? 'Le helper Monochrome est déjà réservé.'
        : 'Session Monochrome introuvable.',
    );
  }

  requireReserved(
    jobId: string,
    userId: number,
  ): MonochromeManualSessionRow {
    const session = this.get(jobId, userId);
    if (!session) {
      throw new MonochromeManualSessionError(
        'not_found',
        'Session Monochrome introuvable.',
      );
    }
    if (session.status === 'RESULT_RECEIVED') {
      throw new MonochromeManualSessionError(
        'replayed',
        'Le résultat du helper a déjà été transmis.',
      );
    }
    if (session.status !== 'RESERVED') {
      throw new MonochromeManualSessionError(
        'invalid_state',
        'Le helper Monochrome n’a pas réservé ce job.',
      );
    }
    return session;
  }

  markResultReceived(jobId: string, userId: number): void {
    this.requireReserved(jobId, userId);
    const now = new Date().toISOString();
    this.handle.db
      .update(monochromeManualSessions)
      .set({
        status: 'RESULT_RECEIVED',
        resultReceivedAt: now,
        updatedAt: now,
      })
      .where(
        and(
          eq(monochromeManualSessions.jobId, jobId),
          eq(monochromeManualSessions.userId, userId),
          eq(monochromeManualSessions.status, 'RESERVED'),
        ),
      )
      .run();
  }

  resetReservation(jobId: string, userId: number): void {
    this.requireReserved(jobId, userId);
    this.handle.db
      .update(monochromeManualSessions)
      .set({
        status: 'WAITING',
        reservedAt: null,
        startedAt: null,
        updatedAt: new Date().toISOString(),
      })
      .where(
        and(
          eq(monochromeManualSessions.jobId, jobId),
          eq(monochromeManualSessions.userId, userId),
          eq(monochromeManualSessions.status, 'RESERVED'),
        ),
      )
      .run();
  }

  release(jobId: string, userId: number): void {
    this.handle.db
      .delete(monochromeManualSessions)
      .where(
        and(
          eq(monochromeManualSessions.jobId, jobId),
          eq(monochromeManualSessions.userId, userId),
        ),
      )
      .run();
  }

  get(
    jobId: string,
    userId: number,
  ): MonochromeManualSessionRow | null {
    return (
      this.handle.db
        .select()
        .from(monochromeManualSessions)
        .where(
          and(
            eq(monochromeManualSessions.jobId, jobId),
            eq(monochromeManualSessions.userId, userId),
          ),
        )
        .get() ?? null
    );
  }

  recoverInterruptedHolder(): number {
    const result = this.handle.db
      .update(monochromeManualSessions)
      .set({
        status: 'WAITING',
        reservedAt: null,
        startedAt: null,
        updatedAt: new Date().toISOString(),
      })
      .where(eq(monochromeManualSessions.status, 'RESERVED'))
      .run();
    return result.changes;
  }
}
