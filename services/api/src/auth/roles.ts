export const ROLES = ['OWNER', 'ADMIN', 'USER'] as const;
export type Role = (typeof ROLES)[number];

/** Rôles assignables par l'administration — jamais OWNER (unique et immuable). */
export const ASSIGNABLE_ROLES = ['ADMIN', 'USER'] as const;
export type AssignableRole = (typeof ASSIGNABLE_ROLES)[number];

export function isRole(value: unknown): value is Role {
  return typeof value === 'string' && (ROLES as readonly string[]).includes(value);
}

export function isAssignableRole(value: unknown): value is AssignableRole {
  return typeof value === 'string' && (ASSIGNABLE_ROLES as readonly string[]).includes(value);
}
