import type { Role } from './roles.js';

// Autorisation CENTRALISÉE : toutes les routes admin passent par decide().
// Aucune condition de rôle dispersée dans les handlers.

export type AdminAction =
  | 'admin.view' // overview, listes, audit
  | 'admin.review' // examiner les imports, diagnostics et outils serveur
  | 'user.create'
  | 'user.block'
  | 'user.unblock'
  | 'user.delete'
  | 'user.set_role'
  | 'user.reset_password'
  | 'user.revoke_sessions'
  | 'library.view' // consulter la bibliothèque d'un utilisateur
  | 'library.grant_track' // attribuer une piste à un utilisateur
  | 'library.revoke_track'; // retirer l'accès d'un utilisateur à une piste

export interface Principal {
  id: number;
  role: Role;
}

export interface Decision {
  allowed: boolean;
  /** Code stable renvoyé au client en cas de refus. */
  reason?: 'forbidden' | 'owner_protected' | 'self_target_forbidden';
}

const MUTATING_ACTIONS: ReadonlySet<AdminAction> = new Set([
  'user.block',
  'user.unblock',
  'user.delete',
  'user.set_role',
  'user.reset_password',
  'user.revoke_sessions',
]);

/**
 * Décide si `actor` peut exécuter `action` (éventuellement sur `target`).
 *
 * Règles de cette phase :
 * - seul OWNER accède à l'administration (ADMIN recevra des droits explicites
 *   dans une phase ultérieure) ;
 * - le OWNER n'est JAMAIS une cible valide d'une mutation (suppression,
 *   blocage, rétrogradation, reset, révocation) ;
 * - on ne se supprime/bloque pas soi-même.
 */
export function decide(actor: Principal, action: AdminAction, target?: Principal): Decision {
  if (actor.role !== 'OWNER') {
    return { allowed: false, reason: 'forbidden' };
  }

  if (target !== undefined && MUTATING_ACTIONS.has(action)) {
    if (target.role === 'OWNER') {
      return { allowed: false, reason: 'owner_protected' };
    }
    if (target.id === actor.id && (action === 'user.delete' || action === 'user.block')) {
      return { allowed: false, reason: 'self_target_forbidden' };
    }
  }

  return { allowed: true };
}
