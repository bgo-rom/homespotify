import type { DbHandle } from '../db/client.js';
import { auditLogs } from '../db/schema.js';

export type AuditAction =
  | 'auth.bootstrap'
  | 'auth.login_success'
  | 'auth.login_failed'
  | 'auth.logout'
  | 'auth.logout_all'
  | 'auth.password_changed'
  | 'admin.user_created'
  | 'admin.user_blocked'
  | 'admin.user_unblocked'
  | 'admin.user_deleted'
  | 'admin.role_changed'
  | 'admin.password_reset'
  | 'admin.sessions_revoked'
  | 'admin.library_track_granted'
  | 'admin.library_track_revoked'
  | 'admin.candidate_created'
  | 'admin.recommendations_maintenance'
  | 'library.track_removed'
  | 'import.track_created'
  | 'import.track_reused'
  | 'import.failed'
  | 'import.retried'
  | 'import.rejected'
  | 'storage.scan_requested'
  | 'backup.manual_requested';

// Défense en profondeur : même si un appelant passe une valeur sensible par
// erreur, elle n'atteint jamais la table d'audit.
const FORBIDDEN_KEY_PATTERN = /password|token|hash|secret|authorization/i;

export function sanitizeAuditMetadata(
  metadata: Record<string, unknown>,
): Record<string, string | number | boolean> {
  const clean: Record<string, string | number | boolean> = {};
  for (const [key, value] of Object.entries(metadata)) {
    if (FORBIDDEN_KEY_PATTERN.test(key)) continue;
    if (typeof value === 'string') {
      if (FORBIDDEN_KEY_PATTERN.test(value)) continue;
      clean[key] = value.slice(0, 200);
    } else if (typeof value === 'number' || typeof value === 'boolean') {
      clean[key] = value;
    }
    // Objets/tableaux ignorés : le journal ne stocke que des faits plats.
  }
  return clean;
}

export function recordAudit(
  handle: DbHandle,
  entry: {
    action: AuditAction;
    actorUserId?: number | null;
    targetUserId?: number | null;
    metadata?: Record<string, unknown>;
  },
): void {
  const metadata = entry.metadata ? sanitizeAuditMetadata(entry.metadata) : undefined;
  handle.db
    .insert(auditLogs)
    .values({
      actorUserId: entry.actorUserId ?? null,
      targetUserId: entry.targetUserId ?? null,
      action: entry.action,
      metadataJson: metadata && Object.keys(metadata).length > 0 ? JSON.stringify(metadata) : null,
      createdAt: new Date().toISOString(),
    })
    .run();
}
