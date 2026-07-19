/**
 * Machine à états du cycle de vie MÉDIA d'un candidat de recommandation
 * (modèle v4 « media-ready »). Règle absolue : seul un candidat `MEDIA_READY`
 * peut entrer dans `user_recommendation_queue` (cf. recommendation-engine.ts).
 *
 * Transitions légitimes :
 *
 *   DISCOVERED ─────────────► IDENTITY_RESOLVING ─► IDENTITY_RESOLVED
 *       ▲                                                   │
 *       │ (retry après TTL)                                 ▼
 *   RETRYABLE_ERROR ◄──────────────────────────── MEDIA_RESOLVING ─► MEDIA_READY
 *                                                        │  │
 *                                                        │  └─► MEDIA_UNAVAILABLE (négatif, TTL)
 *                                                        └────► PERMANENTLY_REJECTED (jamais réessayé)
 *
 * En pratique la résolution enchaîne identité + média dans un même passage ;
 * les états intermédiaires (`*_RESOLVING`) servent de VERROU persistant
 * (single-flight inter-processus) et de diagnostic.
 */

import type { MediaResolutionStatus } from '../db/schema.js';

export const MEDIA_READY: MediaResolutionStatus = 'MEDIA_READY';

/** États terminaux positifs : rien à refaire. */
export const TERMINAL_READY: readonly MediaResolutionStatus[] = ['MEDIA_READY'];

/** États terminaux négatifs DÉFINITIFS : jamais réessayés. */
export const TERMINAL_REJECTED: readonly MediaResolutionStatus[] = ['PERMANENTLY_REJECTED'];

/** États négatifs RÉESSAYABLES après expiration du TTL. */
export const RETRYABLE_NEGATIVE: readonly MediaResolutionStatus[] = [
  'MEDIA_UNAVAILABLE',
  'RETRYABLE_ERROR',
];

/** États « en cours » — verrou de résolution. */
export const IN_PROGRESS: readonly MediaResolutionStatus[] = [
  'IDENTITY_RESOLVING',
  'MEDIA_RESOLVING',
];

const ALLOWED: Record<MediaResolutionStatus, readonly MediaResolutionStatus[]> = {
  DISCOVERED: ['IDENTITY_RESOLVING', 'MEDIA_RESOLVING', 'PERMANENTLY_REJECTED'],
  IDENTITY_RESOLVING: ['IDENTITY_RESOLVED', 'RETRYABLE_ERROR', 'PERMANENTLY_REJECTED'],
  IDENTITY_RESOLVED: ['MEDIA_RESOLVING', 'PERMANENTLY_REJECTED'],
  MEDIA_RESOLVING: [
    'MEDIA_READY',
    'MEDIA_UNAVAILABLE',
    'RETRYABLE_ERROR',
    'PERMANENTLY_REJECTED',
  ],
  // Depuis un état stable on peut relancer un cycle (retry après TTL, ou
  // ré-résolution d'un extrait expiré).
  MEDIA_READY: ['MEDIA_RESOLVING'],
  MEDIA_UNAVAILABLE: ['MEDIA_RESOLVING', 'IDENTITY_RESOLVING'],
  RETRYABLE_ERROR: ['MEDIA_RESOLVING', 'IDENTITY_RESOLVING'],
  PERMANENTLY_REJECTED: [],
};

/** true si la transition `from → to` est autorisée par la machine à états. */
export function canTransition(
  from: MediaResolutionStatus,
  to: MediaResolutionStatus,
): boolean {
  if (from === to) return true;
  return ALLOWED[from]?.includes(to) ?? false;
}

/**
 * Un candidat doit-il être (re)soumis à la résolution média ? Oui s'il est
 * neuf, en identité résolue, ou négatif dont le TTL a expiré. Non s'il est
 * prêt (et non expiré), en cours, ou définitivement rejeté.
 */
export function shouldResolveMedia(
  status: MediaResolutionStatus,
  resolvedAt: string | null,
  now: number,
  retryTtlMs: number,
): boolean {
  if (status === 'PERMANENTLY_REJECTED') return false;
  if (IN_PROGRESS.includes(status)) return false;
  if (status === 'MEDIA_READY') return false; // fraîcheur gérée par previewExpiresAt
  if (RETRYABLE_NEGATIVE.includes(status)) {
    if (resolvedAt === null) return true;
    return now - Date.parse(resolvedAt) >= retryTtlMs;
  }
  // DISCOVERED | IDENTITY_RESOLVED : toujours à traiter.
  return true;
}

export function isMediaReady(status: MediaResolutionStatus): boolean {
  return status === 'MEDIA_READY';
}
