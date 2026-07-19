import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { and, eq, gt, isNull, sql } from 'drizzle-orm';
import type { DbHandle } from '../db/client.js';
import { sessions, users } from '../db/schema.js';
import type { Role } from './roles.js';

export type UserRow = typeof users.$inferSelect;
export type SessionRow = typeof sessions.$inferSelect;

/** Représentation d'un utilisateur SANS champ sensible — la seule qui sorte de l'API. */
export interface PublicUser {
  id: number;
  username: string;
  displayName: string;
  role: Role;
  isActive: boolean;
  mustChangePassword: boolean;
  createdAt: string;
  updatedAt: string;
  lastLoginAt: string | null;
  disabledAt: string | null;
  disabledReason: string | null;
}

export function toPublicUser(user: UserRow): PublicUser {
  return {
    id: user.id,
    username: user.username,
    displayName: user.displayName,
    role: user.role as Role,
    isActive: user.isActive,
    mustChangePassword: user.mustChangePassword,
    createdAt: user.createdAt,
    updatedAt: user.updatedAt,
    lastLoginAt: user.lastLoginAt,
    disabledAt: user.disabledAt,
    disabledReason: user.disabledReason,
  };
}

export const USERNAME_PATTERN = /^[a-z0-9](?:[a-z0-9._-]{1,30})[a-z0-9]$/;

/** Normalise puis valide un username ; null si invalide. */
export function normalizeUsername(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const username = raw.trim().toLowerCase();
  return USERNAME_PATTERN.test(username) ? username : null;
}

export function normalizeDisplayName(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const displayName = raw.trim().replace(/\s+/g, ' ');
  if (displayName.length < 1 || displayName.length > 64) return null;
  return displayName;
}

export function findUserById(handle: DbHandle, id: number): UserRow | undefined {
  return handle.db.select().from(users).where(eq(users.id, id)).get();
}

export function findUserByUsername(handle: DbHandle, username: string): UserRow | undefined {
  return handle.db.select().from(users).where(eq(users.username, username)).get();
}

export function countUsers(handle: DbHandle): number {
  return handle.db.select({ n: sql<number>`count(*)` }).from(users).get()?.n ?? 0;
}

// --- Sessions à refresh token -----------------------------------------------
// Token brut : 48 octets aléatoires en base64url, transmis une seule fois au
// client. En base : uniquement son SHA-256 (une fuite de la base ne permet
// pas de forger une session).

function hashRefreshToken(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

export interface IssuedSession {
  session: SessionRow;
  refreshToken: string;
}

export function createSession(
  handle: DbHandle,
  input: { userId: number; deviceName?: string | null; ttlSeconds: number },
): IssuedSession {
  const refreshToken = randomBytes(48).toString('base64url');
  const now = new Date();
  const session: SessionRow = {
    id: randomUUID(),
    userId: input.userId,
    refreshTokenHash: hashRefreshToken(refreshToken),
    deviceName: input.deviceName ?? null,
    createdAt: now.toISOString(),
    lastUsedAt: now.toISOString(),
    expiresAt: new Date(now.getTime() + input.ttlSeconds * 1000).toISOString(),
    revokedAt: null,
  };
  handle.db.insert(sessions).values(session).run();
  return { session, refreshToken };
}

/**
 * Rotation : le token présenté est consommé et remplacé atomiquement par un
 * nouveau. L'ancien token devient immédiatement invalide (son hash n'existe
 * plus en base). Retourne null si le token est inconnu, révoqué ou expiré.
 */
export function rotateSession(
  handle: DbHandle,
  refreshToken: string,
  ttlSeconds: number,
): (IssuedSession & { userId: number }) | null {
  const now = new Date();
  const nextToken = randomBytes(48).toString('base64url');

  const rotated = handle.db.transaction((tx) => {
    const current = tx
      .select()
      .from(sessions)
      .where(
        and(
          eq(sessions.refreshTokenHash, hashRefreshToken(refreshToken)),
          isNull(sessions.revokedAt),
          gt(sessions.expiresAt, now.toISOString()),
        ),
      )
      .get();
    if (!current) return null;

    tx.update(sessions)
      .set({
        refreshTokenHash: hashRefreshToken(nextToken),
        lastUsedAt: now.toISOString(),
        expiresAt: new Date(now.getTime() + ttlSeconds * 1000).toISOString(),
      })
      .where(eq(sessions.id, current.id))
      .run();

    return tx.select().from(sessions).where(eq(sessions.id, current.id)).get() ?? null;
  });

  if (!rotated) return null;
  return { session: rotated, refreshToken: nextToken, userId: rotated.userId };
}

/** Révoque la session correspondant au refresh token présenté. */
export function revokeSessionByToken(handle: DbHandle, refreshToken: string): SessionRow | null {
  const row = handle.db
    .select()
    .from(sessions)
    .where(and(eq(sessions.refreshTokenHash, hashRefreshToken(refreshToken)), isNull(sessions.revokedAt)))
    .get();
  if (!row) return null;
  handle.db
    .update(sessions)
    .set({ revokedAt: new Date().toISOString() })
    .where(eq(sessions.id, row.id))
    .run();
  return row;
}

/** Révoque toutes les sessions actives d'un utilisateur ; retourne le nombre révoqué. */
export function revokeAllSessions(handle: DbHandle, userId: number): number {
  const result = handle.db
    .update(sessions)
    .set({ revokedAt: new Date().toISOString() })
    .where(and(eq(sessions.userId, userId), isNull(sessions.revokedAt)))
    .run();
  return result.changes;
}

export function countActiveSessions(handle: DbHandle, userId?: number): number {
  const conditions = [isNull(sessions.revokedAt), gt(sessions.expiresAt, new Date().toISOString())];
  if (userId !== undefined) conditions.push(eq(sessions.userId, userId));
  return (
    handle.db
      .select({ n: sql<number>`count(*)` })
      .from(sessions)
      .where(and(...conditions))
      .get()?.n ?? 0
  );
}
