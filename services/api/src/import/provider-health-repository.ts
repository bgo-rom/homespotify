import { and, eq, or } from 'drizzle-orm';
import type { LucidaConfig } from '../config.js';
import type { DbHandle } from '../db/client.js';
import {
  acquisitionJobs,
  providerHealth,
  type ProviderHealthState,
} from '../db/schema.js';

export const LUCIDA_PROVIDER_KEY = 'LUCIDA';

export type ProviderFailureCode =
  | 'PROVIDER_CHALLENGE'
  | 'PROVIDER_RATE_LIMITED'
  | 'PROVIDER_UNAVAILABLE';

export type ProviderReasonCode =
  | ProviderFailureCode
  | 'MANUAL_VERIFICATION_REQUIRED';

export type ProviderHealthRow = typeof providerHealth.$inferSelect;

export interface ProviderPublicStatus {
  provider: 'Lucida';
  state: ProviderHealthState;
  available: boolean;
  reasonCode: ProviderReasonCode | null;
  message: string | null;
  retryAt: string | null;
  manualRetryAllowed: boolean;
  manualVerificationRequired: boolean;
  manualVerificationJobId: string | null;
}

export class ProviderHealthError extends Error {
  constructor(
    readonly code: 'provider_cooldown' | 'probe_in_progress',
    message: string,
    readonly retryAt: string | null,
  ) {
    super(message);
    this.name = 'ProviderHealthError';
  }
}

export interface ProviderHealthOptions {
  clock?: () => Date;
  random?: () => number;
}

const PAUSED_MESSAGE = 'Le service est temporairement en pause.';
const CHALLENGE_MESSAGE =
  'Le service externe demande une vérification de sécurité.';
const RATE_LIMIT_MESSAGE =
  'Le service externe limite temporairement les requêtes.';
const UNAVAILABLE_MESSAGE =
  'Le fournisseur est temporairement indisponible.';
const MANUAL_VERIFICATION_MESSAGE =
  'Une vérification manuelle est nécessaire sur le serveur.';

export interface InteractiveChallengeRecoveryResult {
  providerStatesConverted: number;
  jobsConverted: number;
}

export interface ManualChallengeTransitionResult {
  handled: true;
  terminal: false;
  state: 'MANUAL_VERIFICATION_REQUIRED';
}

function asReasonCode(value: string | null): ProviderReasonCode | null {
  if (
    value === 'PROVIDER_CHALLENGE' ||
    value === 'PROVIDER_RATE_LIMITED' ||
    value === 'PROVIDER_UNAVAILABLE' ||
    value === 'MANUAL_VERIFICATION_REQUIRED'
  ) {
    return value;
  }
  return null;
}

export class ProviderHealthRepository {
  private readonly clock: () => Date;
  private readonly random: () => number;

  constructor(
    private readonly handle: DbHandle,
    private readonly config: Pick<
      LucidaConfig,
      | 'challengeCooldownSeconds'
      | 'rateLimitDefaultCooldownSeconds'
      | 'unavailableCooldownSeconds'
      | 'maxCooldownSeconds'
      | 'providerFailureWindowSeconds'
      | 'providerFailureThreshold'
    >,
    options: ProviderHealthOptions = {},
  ) {
    this.clock = options.clock ?? (() => new Date());
    this.random = options.random ?? Math.random;
  }

  get(): ProviderHealthRow {
    return this.handle.sqlite.transaction(() => this.getOrCreate())();
  }

  publicStatus(): ProviderPublicStatus {
    this.repairOrphanedManualVerification();
    const row = this.get();
    const nowMs = this.clock().getTime();
    const retryMs = row.retryAt ? Date.parse(row.retryAt) : Number.NaN;
    return {
      provider: 'Lucida',
      state: row.state as ProviderHealthState,
      available: row.state === 'CLOSED',
      reasonCode: asReasonCode(row.reasonCode),
      message:
        row.state === 'CLOSED'
          ? null
          : row.state === 'MANUAL_VERIFICATION_REQUIRED'
            ? row.publicMessage
            : PAUSED_MESSAGE,
      retryAt: row.retryAt,
      manualRetryAllowed:
        row.state === 'MANUAL_VERIFICATION_REQUIRED'
          ? row.manualVerificationJobId !== null &&
            row.manualVerificationHolderJobId === null
          : row.state === 'OPEN' &&
            Number.isFinite(retryMs) &&
            nowMs >= retryMs &&
            row.halfOpenProbeJobId === null,
      manualVerificationRequired:
        row.state === 'MANUAL_VERIFICATION_REQUIRED',
      manualVerificationJobId: row.manualVerificationJobId,
    };
  }

  recordFailure(
    code: ProviderFailureCode,
    retryAfterSeconds?: number,
  ): ProviderHealthRow {
    return this.handle.sqlite.transaction(() => {
      const row = this.getOrCreate();
      const now = this.clock();
      const nowIso = now.toISOString();
      const previousFailureMs = row.lastFailureAt
        ? Date.parse(row.lastFailureAt)
        : Number.NaN;
      const inWindow =
        Number.isFinite(previousFailureMs) &&
        now.getTime() - previousFailureMs <=
          this.config.providerFailureWindowSeconds * 1_000;
      const failureCount = inWindow ? row.failureCount + 1 : 1;

      if (
        code === 'PROVIDER_UNAVAILABLE' &&
        row.state === 'CLOSED' &&
        failureCount < this.config.providerFailureThreshold
      ) {
        return this.update({
          ...row,
          failureCount,
          lastFailureAt: nowIso,
          updatedAt: nowIso,
        });
      }

      const baseSeconds = this.baseCooldownSeconds(
        code,
        retryAfterSeconds,
      );
      const wasProbe = row.state === 'HALF_OPEN';
      const previousSeconds = this.previousCooldownSeconds(row);
      const jitterSeconds = wasProbe
        ? Math.floor(Math.max(0, Math.min(1, this.random())) * 61)
        : 0;
      const cooldownSeconds = wasProbe
        ? Math.min(
            this.config.maxCooldownSeconds,
            Math.max(baseSeconds, previousSeconds * 2) + jitterSeconds,
          )
        : baseSeconds;
      const retryAt = new Date(
        now.getTime() + cooldownSeconds * 1_000,
      ).toISOString();

      return this.update({
        ...row,
        state: 'OPEN',
        reasonCode: code,
        publicMessage: this.messageFor(code),
        failureCount,
        openedAt: nowIso,
        retryAt,
        lastFailureAt: nowIso,
        halfOpenProbeJobId: null,
        manualVerificationJobId: null,
        manualVerificationHolderJobId: null,
        updatedAt: nowIso,
      });
    })();
  }

  requireManualVerification(jobId: string): ProviderHealthRow {
    return this.handle.sqlite.transaction(() => {
      const row = this.getOrCreate();
      const job = this.handle.db
        .select({
          status: acquisitionJobs.status,
          stage: acquisitionJobs.stage,
        })
        .from(acquisitionJobs)
        .where(eq(acquisitionJobs.id, jobId))
        .get();
      if (
        job?.status !== 'MANUAL_VERIFICATION_REQUIRED' ||
        job.stage !== 'waiting_user_verification'
      ) {
        throw new ProviderHealthError(
          'probe_in_progress',
          'Le job de vérification manuelle est invalide.',
          null,
        );
      }
      if (
        row.state === 'MANUAL_VERIFICATION_REQUIRED' &&
        row.manualVerificationJobId !== null &&
        row.manualVerificationJobId !== jobId
      ) {
        throw new ProviderHealthError(
          'probe_in_progress',
          'Une vérification manuelle est déjà en attente.',
          null,
        );
      }
      const nowIso = this.clock().toISOString();
      return this.update({
        ...row,
        state: 'MANUAL_VERIFICATION_REQUIRED',
        reasonCode: 'PROVIDER_CHALLENGE',
        publicMessage: MANUAL_VERIFICATION_MESSAGE,
        openedAt: null,
        retryAt: null,
        halfOpenProbeJobId: null,
        manualVerificationJobId: jobId,
        manualVerificationHolderJobId: null,
        updatedAt: nowIso,
      });
    })();
  }

  transitionChallengeToManual(
    jobId: string,
    userId: number,
  ): ManualChallengeTransitionResult {
    return this.handle.sqlite.transaction(
      (): ManualChallengeTransitionResult => {
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
          job.status === 'FAILED' ||
          job.status === 'COMPLETED' ||
          job.status === 'CANCELLED'
        ) {
          throw new ProviderHealthError(
            'probe_in_progress',
            'Le job ne peut pas attendre une vérification manuelle.',
            null,
          );
        }

        const nowIso = this.clock().toISOString();
        const message = MANUAL_VERIFICATION_MESSAGE;
        this.handle.db
          .update(acquisitionJobs)
          .set({
            status: 'MANUAL_VERIFICATION_REQUIRED',
            stage: 'waiting_user_verification',
            message,
            errorCode: 'PROVIDER_CHALLENGE',
            errorMessage: message,
            completedAt: null,
            trackId: null,
            updatedAt: nowIso,
          })
          .where(
            and(
              eq(acquisitionJobs.id, jobId),
              eq(acquisitionJobs.userId, userId),
            ),
          )
          .run();

        const row = this.getOrCreate();
        this.update({
          ...row,
          state: 'MANUAL_VERIFICATION_REQUIRED',
          reasonCode: 'PROVIDER_CHALLENGE',
          publicMessage: message,
          openedAt: null,
          retryAt: null,
          halfOpenProbeJobId: null,
          manualVerificationJobId: jobId,
          manualVerificationHolderJobId: null,
          updatedAt: nowIso,
        });

        return {
          handled: true,
          terminal: false,
          state: 'MANUAL_VERIFICATION_REQUIRED',
        };
      },
    )();
  }

  repairOrphanedManualVerification(): boolean {
    return this.handle.sqlite.transaction(() => {
      const row = this.getOrCreate();
      if (row.state !== 'MANUAL_VERIFICATION_REQUIRED') return false;

      const job = row.manualVerificationJobId
        ? this.handle.db
            .select({
              status: acquisitionJobs.status,
              stage: acquisitionJobs.stage,
            })
            .from(acquisitionJobs)
            .where(eq(acquisitionJobs.id, row.manualVerificationJobId))
            .get()
        : undefined;
      if (
        job?.status === 'MANUAL_VERIFICATION_REQUIRED' &&
        job.stage === 'waiting_user_verification'
      ) {
        return false;
      }

      const nowIso = this.clock().toISOString();
      this.update({
        ...row,
        state: 'CLOSED',
        reasonCode: null,
        publicMessage: null,
        failureCount: 0,
        openedAt: null,
        retryAt: null,
        halfOpenProbeJobId: null,
        manualVerificationJobId: null,
        manualVerificationHolderJobId: null,
        updatedAt: nowIso,
      });
      return true;
    })();
  }

  reserveManualVerification(jobId: string): ProviderHealthRow {
    return this.handle.sqlite.transaction(() => {
      const row = this.getOrCreate();
      if (
        row.state !== 'MANUAL_VERIFICATION_REQUIRED' ||
        row.manualVerificationJobId !== jobId
      ) {
        throw new ProviderHealthError(
          'probe_in_progress',
          'Ce job n’attend pas de vérification manuelle.',
          null,
        );
      }
      if (row.manualVerificationHolderJobId !== null) {
        throw new ProviderHealthError(
          'probe_in_progress',
          'Une vérification manuelle est déjà en cours.',
          null,
        );
      }
      return this.update({
        ...row,
        manualVerificationHolderJobId: jobId,
        updatedAt: this.clock().toISOString(),
      });
    })();
  }

  releaseManualVerification(jobId: string): ProviderHealthRow {
    return this.handle.sqlite.transaction(() => {
      const row = this.getOrCreate();
      if (
        row.state !== 'MANUAL_VERIFICATION_REQUIRED' ||
        row.manualVerificationJobId !== jobId
      ) {
        return row;
      }
      return this.update({
        ...row,
        manualVerificationHolderJobId: null,
        updatedAt: this.clock().toISOString(),
      });
    })();
  }

  abandonManualVerification(jobId: string): ProviderHealthRow {
    return this.handle.sqlite.transaction(() => {
      const row = this.getOrCreate();
      if (
        row.state !== 'MANUAL_VERIFICATION_REQUIRED' ||
        row.manualVerificationJobId !== jobId
      ) {
        return row;
      }
      return this.update({
        ...row,
        manualVerificationJobId: null,
        manualVerificationHolderJobId: null,
        updatedAt: this.clock().toISOString(),
      });
    })();
  }

  recordManualVerificationSuccess(jobId: string): ProviderHealthRow {
    return this.handle.sqlite.transaction(() => {
      const row = this.getOrCreate();
      if (
        row.state !== 'MANUAL_VERIFICATION_REQUIRED' ||
        row.manualVerificationJobId !== jobId ||
        row.manualVerificationHolderJobId !== jobId
      ) {
        return row;
      }
      const nowIso = this.clock().toISOString();
      return this.update({
        ...row,
        state: 'CLOSED',
        reasonCode: null,
        publicMessage: null,
        failureCount: 0,
        openedAt: null,
        retryAt: null,
        lastSuccessAt: nowIso,
        halfOpenProbeJobId: null,
        manualVerificationJobId: null,
        manualVerificationHolderJobId: null,
        updatedAt: nowIso,
      });
    })();
  }

  beginManualProbe(jobId: string): ProviderHealthRow {
    return this.handle.sqlite.transaction(() => {
      const row = this.getOrCreate();
      const now = this.clock();
      if (row.state === 'HALF_OPEN') {
        throw new ProviderHealthError(
          'probe_in_progress',
          'Une tentative de vérification est déjà en cours.',
          row.retryAt,
        );
      }
      if (row.state !== 'OPEN') return row;

      const retryMs = row.retryAt ? Date.parse(row.retryAt) : Number.NaN;
      if (!Number.isFinite(retryMs) || now.getTime() < retryMs) {
        throw new ProviderHealthError(
          'provider_cooldown',
          PAUSED_MESSAGE,
          row.retryAt,
        );
      }
      return this.update({
        ...row,
        state: 'HALF_OPEN',
        halfOpenProbeJobId: jobId,
        manualVerificationJobId: null,
        manualVerificationHolderJobId: null,
        updatedAt: now.toISOString(),
      });
    })();
  }

  recordProbeSuccess(jobId: string): ProviderHealthRow {
    return this.handle.sqlite.transaction(() => {
      const row = this.getOrCreate();
      if (
        row.state !== 'HALF_OPEN' ||
        row.halfOpenProbeJobId !== jobId
      ) {
        return row;
      }
      const nowIso = this.clock().toISOString();
      return this.update({
        ...row,
        state: 'CLOSED',
        reasonCode: null,
        publicMessage: null,
        failureCount: 0,
        openedAt: null,
        retryAt: null,
        lastSuccessAt: nowIso,
        halfOpenProbeJobId: null,
        manualVerificationJobId: null,
        manualVerificationHolderJobId: null,
        updatedAt: nowIso,
      });
    })();
  }

  releaseProbe(jobId: string): ProviderHealthRow {
    return this.handle.sqlite.transaction(() => {
      const row = this.getOrCreate();
      if (
        row.state !== 'HALF_OPEN' ||
        row.halfOpenProbeJobId !== jobId
      ) {
        return row;
      }
      return this.update({
        ...row,
        state: 'OPEN',
        halfOpenProbeJobId: null,
        updatedAt: this.clock().toISOString(),
      });
    })();
  }

  recoverInterruptedProbe(): boolean {
    return this.handle.sqlite.transaction(() => {
      const row = this.getOrCreate();
      if (
        row.state === 'MANUAL_VERIFICATION_REQUIRED' &&
        row.manualVerificationHolderJobId !== null
      ) {
        this.update({
          ...row,
          manualVerificationHolderJobId: null,
          updatedAt: this.clock().toISOString(),
        });
        return true;
      }
      if (row.state !== 'HALF_OPEN') return false;
      this.update({
        ...row,
        state: 'OPEN',
        halfOpenProbeJobId: null,
        updatedAt: this.clock().toISOString(),
      });
      return true;
    })();
  }

  recoverLegacyInteractiveChallenge(): InteractiveChallengeRecoveryResult {
    return this.handle.sqlite.transaction(() => {
      const row = this.getOrCreate();
      if (
        row.state !== 'OPEN' ||
        row.reasonCode !== 'PROVIDER_CHALLENGE'
      ) {
        return { providerStatesConverted: 0, jobsConverted: 0 };
      }

      const matchingJob = this.handle.db
        .select({
          id: acquisitionJobs.id,
          userId: acquisitionJobs.userId,
        })
        .from(acquisitionJobs)
        .where(
          and(
            eq(acquisitionJobs.provider, 'QOBUZ'),
            eq(acquisitionJobs.status, 'PAUSED_PROVIDER'),
            or(
              eq(acquisitionJobs.errorCode, 'PROVIDER_CHALLENGE'),
              eq(acquisitionJobs.stage, 'provider_challenge'),
            ),
          ),
        )
        .get();

      if (!matchingJob) {
        const nowIso = this.clock().toISOString();
        this.update({
          ...row,
          state: 'CLOSED',
          reasonCode: null,
          publicMessage: null,
          failureCount: 0,
          openedAt: null,
          retryAt: null,
          halfOpenProbeJobId: null,
          manualVerificationJobId: null,
          manualVerificationHolderJobId: null,
          updatedAt: nowIso,
        });
        return { providerStatesConverted: 1, jobsConverted: 0 };
      }

      this.transitionChallengeToManual(
        matchingJob.id,
        matchingJob.userId,
      );

      return {
        providerStatesConverted: 1,
        jobsConverted: 1,
      };
    })();
  }

  private getOrCreate(): ProviderHealthRow {
    const existing = this.handle.db
      .select()
      .from(providerHealth)
      .where(eq(providerHealth.provider, LUCIDA_PROVIDER_KEY))
      .get();
    if (existing) return existing;
    const now = this.clock().toISOString();
    return this.handle.db
      .insert(providerHealth)
      .values({
        provider: LUCIDA_PROVIDER_KEY,
        createdAt: now,
        updatedAt: now,
      })
      .returning()
      .get()!;
  }

  private update(row: ProviderHealthRow): ProviderHealthRow {
    return this.handle.db
      .update(providerHealth)
      .set(row)
      .where(eq(providerHealth.provider, LUCIDA_PROVIDER_KEY))
      .returning()
      .get()!;
  }

  private baseCooldownSeconds(
    code: ProviderFailureCode,
    retryAfterSeconds?: number,
  ): number {
    switch (code) {
      case 'PROVIDER_CHALLENGE':
        return this.config.challengeCooldownSeconds;
      case 'PROVIDER_RATE_LIMITED':
        return retryAfterSeconds !== undefined &&
          Number.isInteger(retryAfterSeconds)
          ? Math.max(60, Math.min(86_400, retryAfterSeconds))
          : this.config.rateLimitDefaultCooldownSeconds;
      case 'PROVIDER_UNAVAILABLE':
        return this.config.unavailableCooldownSeconds;
    }
  }

  private previousCooldownSeconds(row: ProviderHealthRow): number {
    if (!row.openedAt || !row.retryAt) return 0;
    const seconds =
      (Date.parse(row.retryAt) - Date.parse(row.openedAt)) / 1_000;
    return Number.isFinite(seconds) && seconds > 0 ? seconds : 0;
  }

  private messageFor(code: ProviderFailureCode): string {
    switch (code) {
      case 'PROVIDER_CHALLENGE':
        return CHALLENGE_MESSAGE;
      case 'PROVIDER_RATE_LIMITED':
        return RATE_LIMIT_MESSAGE;
      case 'PROVIDER_UNAVAILABLE':
        return UNAVAILABLE_MESSAGE;
    }
  }
}
