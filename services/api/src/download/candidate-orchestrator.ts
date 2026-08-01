/**
 * Politique de repli entre candidats.
 *
 * Isolée du service pour être vérifiable seule : décider « faut-il essayer le
 * candidat suivant ? » est une règle métier, pas un détail d'exécution. Une
 * erreur de jugement ici produit soit un abandon prématuré, soit un
 * acharnement inutile sur des sources condamnées.
 */
import type { DownloadCandidate } from './candidate-resolver.js';

/**
 * Codes d'échec TECHNIQUES d'une source : le candidat suivant a une chance
 * réelle d'aboutir.
 *
 * Regroupe les cas imposés : délai de métadonnées, miroir indisponible, source
 * non disponible, authentification du fournisseur absente, aucun fichier
 * produit, extrait incomplet.
 */
const FALLBACK_ELIGIBLE_CODES = new Set([
  // Le moteur s'est arrêté sans produire de piste exploitable.
  'NO_TRACK_DOWNLOADED',
  'ENGINE_EXIT_ERROR',
  'ENGINE_FAILED',
  // Diagnostic structuré remonté par Antra (miroir, source, authentification).
  'ANTRA_SUMMARY_ERROR',
  'ANTRA_TRACK_FAILED',
  'ANTRA_ERROR',
  // Le délai de CETTE tentative a été atteint (métadonnées bloquées, miroir muet).
  'ATTEMPT_TIMEOUT',
  // Le fichier produit est inexploitable pour cette source.
  'NO_FILE_DETECTED',
  'EXCERPT_TOO_SHORT',
  'UNREADABLE',
  // Fichier lisible mais hors specs d'ingestion (ex. FLAC 32 bits) : une autre
  // source fournit souvent la même piste dans un format accepté.
  'FORMAT_REJECTED',
  'NO_AUDIO_STREAM',
  'EMPTY',
  'UNSTABLE',
]);

/**
 * Codes qui interdisent le repli.
 *
 * - `CANCELLED` : une annulation utilisateur ne doit JAMAIS enchaîner sur un
 *   autre candidat — c'est l'inverse de ce qui a été demandé.
 * - `SPAWN_FAILED` : le serveur ne sait pas lancer Python ; tous les candidats
 *   échoueraient identiquement.
 * - `TIMEOUT` : c'est le délai GLOBAL du job, pas celui d'une tentative.
 * - `LOCAL_IMPORT_*` : le fichier a bien été produit ; le problème est local et
 *   réessayer une autre source risquerait un doublon.
 */
const FALLBACK_BLOCKING_CODES = new Set([
  'CANCELLED',
  'SPAWN_FAILED',
  'TIMEOUT',
  'INTERNAL_ERROR',
  'LOCAL_IMPORT_JOB_MISSING',
  'LOCAL_IMPORT_TRACK_MISSING',
  'LOCAL_IMPORT_REVIEW_REQUIRED',
  'LOCAL_IMPORT_FAILED',
]);

export function isFallbackEligible(errorCode: string | null): boolean {
  if (errorCode === null) return false;
  if (FALLBACK_BLOCKING_CODES.has(errorCode)) return false;
  return FALLBACK_ELIGIBLE_CODES.has(errorCode);
}

/** Trace d'une tentative, persistée et exposée sans URL brute ni secret. */
export interface CandidateAttempt {
  order: number;
  provider: string;
  /** URL normalisée du candidat — jamais un token, jamais un chemin serveur. */
  url: string;
  startedAt: string;
  endedAt: string | null;
  outcome: 'succeeded' | 'failed' | 'cancelled' | 'skipped';
  errorCode: string | null;
}

export interface OrchestratorDecision {
  /** Candidat à essayer, ou `null` si la chaîne est terminée. */
  candidate: DownloadCandidate | null;
  /** Raison de l'arrêt, quand `candidate` est `null`. */
  stopReason:
    | null
    | 'exhausted'
    | 'cancelled'
    | 'global_timeout'
    | 'not_eligible';
}

/**
 * Parcourt une liste ordonnée de candidats, sans jamais rejouer le même.
 *
 * L'orchestrateur ne lance rien : il décide. L'exécution reste dans
 * `DownloadService`, ce qui permet de tester la politique sans processus.
 */
export class DownloadCandidateOrchestrator {
  private index = 0;
  private readonly attempts: CandidateAttempt[] = [];
  private readonly triedUrls = new Set<string>();

  constructor(
    private readonly candidates: readonly DownloadCandidate[],
    private readonly options: {
      /** Instant limite, tous candidats confondus. */
      deadlineAt: number;
      now?: () => number;
    },
  ) {}

  private now(): number {
    return this.options.now?.() ?? Date.now();
  }

  /** Candidat suivant, ou raison d'arrêt. */
  next(context: { cancelled: boolean; lastErrorCode: string | null }): OrchestratorDecision {
    if (context.cancelled) return { candidate: null, stopReason: 'cancelled' };
    if (this.now() >= this.options.deadlineAt) {
      return { candidate: null, stopReason: 'global_timeout' };
    }
    // Une première tentative n'a pas de code précédent : la règle d'éligibilité
    // ne s'applique qu'aux SUIVANTES.
    if (this.attempts.length > 0 && !isFallbackEligible(context.lastErrorCode)) {
      return { candidate: null, stopReason: 'not_eligible' };
    }

    while (this.index < this.candidates.length) {
      const candidate = this.candidates[this.index]!;
      this.index += 1;
      // Deux catalogues peuvent publier la même URL : ne jamais la rejouer.
      if (this.triedUrls.has(candidate.url)) continue;
      return { candidate, stopReason: null };
    }
    return { candidate: null, stopReason: 'exhausted' };
  }

  /** Enregistre le début d'une tentative et retourne son numéro d'ordre. */
  beginAttempt(candidate: DownloadCandidate, startedAt: string): number {
    this.triedUrls.add(candidate.url);
    const order = this.attempts.length + 1;
    this.attempts.push({
      order,
      provider: candidate.provider,
      url: candidate.url,
      startedAt,
      endedAt: null,
      outcome: 'failed',
      errorCode: null,
    });
    return order;
  }

  endAttempt(
    order: number,
    outcome: CandidateAttempt['outcome'],
    errorCode: string | null,
    endedAt: string,
  ): void {
    const attempt = this.attempts.find((entry) => entry.order === order);
    if (attempt === undefined) return;
    attempt.outcome = outcome;
    attempt.errorCode = errorCode;
    attempt.endedAt = endedAt;
  }

  history(): readonly CandidateAttempt[] {
    return this.attempts;
  }

  attemptCount(): number {
    return this.attempts.length;
  }

  remainingCount(): number {
    return Math.max(0, this.candidates.length - this.index);
  }
}
