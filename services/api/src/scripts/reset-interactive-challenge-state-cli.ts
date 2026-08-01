import Database from 'better-sqlite3';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const MANUAL_MESSAGE =
  'Une vérification manuelle est nécessaire sur le serveur.';

function readDatabasePath(argv: string[]): string {
  const index = argv.indexOf('--db-path');
  const value = index >= 0 ? argv[index + 1] : undefined;
  if (!value?.trim()) {
    throw new Error('Argument --db-path obligatoire.');
  }
  return resolve(value);
}

export function resetInteractiveChallengeState(
  database: Database.Database,
): { providerStatesConverted: number; jobsConverted: number } {
  database.pragma('foreign_keys = ON');
  return database.transaction(() => {
    const provider = database
      .prepare(
        `SELECT state, reason_code
         FROM provider_health
         WHERE provider = 'LUCIDA'`,
      )
      .get() as { state: string; reason_code: string | null } | undefined;
    if (
      provider?.state !== 'OPEN' ||
      provider.reason_code !== 'PROVIDER_CHALLENGE'
    ) {
      return { providerStatesConverted: 0, jobsConverted: 0 };
    }

    const candidate = database
      .prepare(
        `SELECT id
         FROM acquisition_jobs
         WHERE provider = 'QOBUZ'
           AND status = 'PAUSED_PROVIDER'
           AND error_code = 'PROVIDER_CHALLENGE'
         ORDER BY created_at ASC, id ASC
         LIMIT 1`,
      )
      .get() as { id: string } | undefined;

    if (!candidate) {
      const closed = database
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
             AND state = 'OPEN'
             AND reason_code = 'PROVIDER_CHALLENGE'`,
        )
        .run(new Date().toISOString());
      return {
        providerStatesConverted: closed.changes,
        jobsConverted: 0,
      };
    }

    const providerUpdate = database
      .prepare(
        `UPDATE provider_health
         SET state = 'MANUAL_VERIFICATION_REQUIRED',
             reason_code = 'PROVIDER_CHALLENGE',
             public_message = ?,
             opened_at = NULL,
             retry_at = NULL,
             half_open_probe_job_id = NULL,
             manual_verification_job_id = ?,
             manual_verification_holder_job_id = NULL,
             updated_at = ?
         WHERE provider = 'LUCIDA'
           AND state = 'OPEN'
           AND reason_code = 'PROVIDER_CHALLENGE'`,
      )
      .run(MANUAL_MESSAGE, candidate.id, new Date().toISOString());

    const jobUpdate = database
      .prepare(
        `UPDATE acquisition_jobs
         SET status = 'MANUAL_VERIFICATION_REQUIRED',
             stage = 'waiting_user_verification',
             message = ?,
             error_code = 'PROVIDER_CHALLENGE',
             error_message = ?,
             completed_at = NULL,
             track_id = NULL,
             updated_at = ?
         WHERE id = ?
           AND provider = 'QOBUZ'
           AND status = 'PAUSED_PROVIDER'
           AND error_code = 'PROVIDER_CHALLENGE'`,
      )
      .run(
        MANUAL_MESSAGE,
        MANUAL_MESSAGE,
        new Date().toISOString(),
        candidate.id,
      );

    return {
      providerStatesConverted: providerUpdate.changes,
      jobsConverted: jobUpdate.changes,
    };
  })();
}

function main(): void {
  const database = new Database(readDatabasePath(process.argv.slice(2)));
  try {
    const result = resetInteractiveChallengeState(database);
    process.stdout.write(`${JSON.stringify(result)}\n`);
  } finally {
    database.close();
  }
}

const entryPoint = process.argv[1]
  ? pathToFileURL(resolve(process.argv[1])).href
  : null;
if (entryPoint === import.meta.url) {
  main();
}
