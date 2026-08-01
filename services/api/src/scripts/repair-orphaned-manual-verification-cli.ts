import Database from 'better-sqlite3';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

interface SafeProviderState {
  state: string;
  reasonCode: string | null;
  retryAt: string | null;
  manualVerificationJobId: string | null;
  manualVerificationHolderJobId: string | null;
}

export interface OrphanedManualVerificationRepairResult {
  before: SafeProviderState | null;
  after: SafeProviderState | null;
  associatedJob: {
    status: string;
    stage: string | null;
  } | null;
  rowsModified: number;
}

function readSafeProviderState(
  database: Database.Database,
): SafeProviderState | null {
  return (
    (database
      .prepare(
        `SELECT
           state,
           reason_code AS reasonCode,
           retry_at AS retryAt,
           manual_verification_job_id AS manualVerificationJobId,
           manual_verification_holder_job_id AS manualVerificationHolderJobId
         FROM provider_health
         WHERE provider = 'LUCIDA'`,
      )
      .get() as SafeProviderState | undefined) ?? null
  );
}

export function repairOrphanedManualVerification(
  database: Database.Database,
): OrphanedManualVerificationRepairResult {
  database.pragma('foreign_keys = ON');
  return database.transaction(() => {
    const before = readSafeProviderState(database);
    const associatedJob = before?.manualVerificationJobId
      ? ((database
          .prepare(
            `SELECT status, stage
             FROM acquisition_jobs
             WHERE id = ?`,
          )
          .get(before.manualVerificationJobId) as
          | { status: string; stage: string | null }
          | undefined) ?? null)
      : null;
    const valid =
      before?.state === 'MANUAL_VERIFICATION_REQUIRED' &&
      before.manualVerificationJobId !== null &&
      associatedJob?.status === 'MANUAL_VERIFICATION_REQUIRED' &&
      associatedJob.stage === 'waiting_user_verification';

    let rowsModified = 0;
    if (
      before?.state === 'MANUAL_VERIFICATION_REQUIRED' &&
      !valid
    ) {
      rowsModified = database
        .prepare(
          `UPDATE provider_health
           SET state = 'CLOSED',
               reason_code = NULL,
               public_message = NULL,
               failure_count = 0,
               opened_at = NULL,
               retry_at = NULL,
               half_open_probe_job_id = NULL,
               manual_verification_job_id = NULL,
               manual_verification_holder_job_id = NULL,
               updated_at = ?
           WHERE provider = 'LUCIDA'
             AND state = 'MANUAL_VERIFICATION_REQUIRED'`,
        )
        .run(new Date().toISOString()).changes;
    }

    return {
      before,
      after: readSafeProviderState(database),
      associatedJob,
      rowsModified,
    };
  })();
}

function readDatabasePath(argv: string[]): string {
  const index = argv.indexOf('--db-path');
  const value = index >= 0 ? argv[index + 1] : undefined;
  if (!value?.trim()) throw new Error('Argument --db-path obligatoire.');
  return resolve(value);
}

function main(): void {
  const database = new Database(readDatabasePath(process.argv.slice(2)));
  try {
    process.stdout.write(
      `${JSON.stringify(repairOrphanedManualVerification(database))}\n`,
    );
  } finally {
    database.close();
  }
}

const entryPoint = process.argv[1]
  ? pathToFileURL(resolve(process.argv[1])).href
  : null;
if (entryPoint === import.meta.url) main();
