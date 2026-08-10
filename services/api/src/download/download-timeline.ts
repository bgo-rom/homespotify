/**
 * Chronologie d'un job de téléchargement — observabilité PURE.
 *
 * Aucune décision ne dépend de ce module : il n'écrit que des journaux. Il
 * existe parce que le pipeline Antra n'émettait qu'un seul événement structuré
 * (`DOWNLOAD_SEARCH_QUEUED`), ce qui rendait impossible de dire où passait le
 * temps entre la demande du téléphone et la piste en bibliothèque.
 *
 * Chaque marque est une ligne `DL_PHASE` autonome : un `jobId`, une phase, la
 * durée depuis la marque précédente et depuis le début. Le tri se fait ensuite
 * hors ligne, sans état partagé côté serveur.
 *
 * Aucun secret, aucune URL complète, aucun chemin absolu n'y transite : seules
 * des valeurs numériques et des noms de phase constants.
 */

export type DownloadPhase =
  | 'job_created'
  | 'processing_start'
  | 'candidates_resolved'
  | 'staging_ready'
  | 'antra_spawn_start'
  | 'antra_spawn_end'
  | 'antra_stage'
  | 'antra_exit'
  | 'detect_start'
  | 'detect_end'
  | 'remote_import_start'
  | 'analysis_start'
  | 'analysis_end'
  | 'hash_start'
  | 'hash_end'
  | 'dedup_end'
  | 'storage_put_start'
  | 'storage_put_end'
  | 'cover_end'
  | 'db_finalize'
  | 'index_publish_start'
  | 'index_publish_end'
  | 'remote_import_end'
  | 'job_completed';

export interface TimelineLogger {
  info(context: Record<string, unknown>, message: string): void;
}

/**
 * Horloge monotone en millisecondes fractionnaires. `performance.now()` ne
 * recule pas si l'horloge système est ajustée pendant un téléchargement long.
 */
function monotonicMs(): number {
  return performance.now();
}

export class DownloadTimeline {
  private readonly startedAt = monotonicMs();
  private previousAt = this.startedAt;

  constructor(
    private readonly logger: TimelineLogger | undefined,
    private readonly jobId: string,
  ) {}

  mark(phase: DownloadPhase, extra: Record<string, unknown> = {}): void {
    if (this.logger === undefined) return;
    const now = monotonicMs();
    this.logger.info(
      {
        event: 'DL_PHASE',
        jobId: this.jobId,
        phase,
        sinceStartMs: Math.round((now - this.startedAt) * 1000) / 1000,
        sincePreviousMs: Math.round((now - this.previousAt) * 1000) / 1000,
        ...extra,
      },
      'DL_PHASE',
    );
    this.previousAt = now;
  }
}

/**
 * Chronologie autonome pour un composant qui ne reçoit pas l'objet ci-dessus
 * (l'import distant est appelé avec un `requestId`, pas avec un job).
 * Le `requestId` a la forme `download-<jobId>`.
 */
export function timelineFromRequestId(
  logger: TimelineLogger | undefined,
  requestId: string | undefined,
): DownloadTimeline | null {
  if (logger === undefined || requestId === undefined) return null;
  const jobId = requestId.startsWith('download-')
    ? requestId.slice('download-'.length)
    : requestId;
  return new DownloadTimeline(logger, jobId);
}
