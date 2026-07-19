import { statfsSync } from 'node:fs';
import { readFileSync } from 'node:fs';
import type { FastifyInstance, FastifyReply, FastifyRequest } from 'fastify';
import { desc, eq, sql } from 'drizzle-orm';
import { auditLogs, sessions, tracks, users } from '../db/schema.js';
import {
  countActiveSessions,
  findUserById,
  normalizeDisplayName,
  normalizeUsername,
  revokeAllSessions,
  toPublicUser,
  type UserRow,
} from '../auth/auth-service.js';
import { recordAudit } from '../auth/audit.js';
import type { AuthGuards } from '../auth/guards.js';
import { decide, type AdminAction } from '../auth/permissions.js';
import { isAssignableRole, type Role } from '../auth/roles.js';
import { hashPassword, validatePassword, PASSWORD_MIN_LENGTH } from '../auth/passwords.js';

const pkg = JSON.parse(
  readFileSync(new URL('../../package.json', import.meta.url), 'utf-8'),
) as { version: string };

function badRequest(reply: FastifyReply, message: string): FastifyReply {
  return reply.code(400).send({ statusCode: 400, error: 'bad_request', message });
}

function userNotFound(reply: FastifyReply): FastifyReply {
  return reply
    .code(404)
    .send({ statusCode: 404, error: 'user_not_found', message: 'Utilisateur inconnu.' });
}

export function registerAdminRoutes(
  app: FastifyInstance,
  guards: AuthGuards,
  hooks: { onUserCreated?: (userId: number, username: string) => Promise<void> } = {},
): void {
  const handle = app.dbHandle;
  const { db } = handle;

  /**
   * Charge la cible et applique la décision centralisée (permissions.ts).
   * Retourne la ligne utilisateur, ou null si la réponse a déjà été envoyée.
   */
  function authorizeTarget(
    request: FastifyRequest<{ Params: { id: string } }>,
    reply: FastifyReply,
    action: AdminAction,
  ): UserRow | null {
    const targetId = Number(request.params.id);
    if (!Number.isInteger(targetId) || targetId < 1) {
      badRequest(reply, 'Identifiant utilisateur invalide.');
      return null;
    }
    const target = findUserById(handle, targetId);
    if (!target) {
      userNotFound(reply);
      return null;
    }
    const decision = decide(
      { id: request.authUser.id, role: request.authUser.role },
      action,
      { id: target.id, role: target.role as Role },
    );
    if (!decision.allowed) {
      reply.code(403).send({
        statusCode: 403,
        error: decision.reason ?? 'forbidden',
        message:
          decision.reason === 'owner_protected'
            ? 'Le compte OWNER ne peut pas être ciblé par cette action.'
            : decision.reason === 'self_target_forbidden'
              ? 'Impossible d’appliquer cette action à son propre compte.'
              : 'Accès refusé.',
      });
      return null;
    }
    return target;
  }

  app.get('/api/admin/overview', { preHandler: guards.requireAdmin('admin.view') }, async () => {
    // Espace disque du volume qui héberge la bibliothèque audio.
    let disk: { totalBytes: number; freeBytes: number; usedBytes: number } | null = null;
    try {
      const stat = statfsSync(app.config.musicDir);
      const totalBytes = stat.blocks * stat.bsize;
      const freeBytes = stat.bavail * stat.bsize;
      disk = { totalBytes, freeBytes, usedBytes: totalBytes - freeBytes };
    } catch {
      // Volume indisponible : null plutôt qu'un chiffre inventé.
    }

    const library = db
      .select({ trackCount: sql<number>`count(*)`, sizeBytes: sql<number>`coalesce(sum(size_bytes), 0)` })
      .from(tracks)
      .get() ?? { trackCount: 0, sizeBytes: 0 };

    const userCounts = db
      .select({
        total: sql<number>`count(*)`,
        active: sql<number>`sum(case when is_active = 1 then 1 else 0 end)`,
        blocked: sql<number>`sum(case when is_active = 0 then 1 else 0 end)`,
      })
      .from(users)
      .get() ?? { total: 0, active: 0, blocked: 0 };

    return {
      backend: {
        status: 'ok',
        uptimeSeconds: Math.round(process.uptime()),
        version: pkg.version,
        environment: app.config.nodeEnv,
        serverTime: new Date().toISOString(),
      },
      disk,
      library: { trackCount: library.trackCount, sizeBytes: library.sizeBytes },
      users: {
        total: userCounts.total,
        active: userCounts.active ?? 0,
        blocked: userCounts.blocked ?? 0,
      },
      sessions: { active: countActiveSessions(handle) },
    };
  });

  app.get('/api/admin/users', { preHandler: guards.requireAdmin('admin.view') }, async () => {
    const rows = db.select().from(users).orderBy(users.id).all();
    return {
      items: rows.map((row) => ({
        ...toPublicUser(row),
        activeSessionCount: countActiveSessions(handle, row.id),
        // Pas encore de relations user↔tracks : aucune valeur inventée
        // (cf. MULTI_USER_DATA_MODEL.md).
        storageUsage: null,
      })),
    };
  });

  app.get<{ Params: { id: string } }>(
    '/api/admin/users/:id',
    { preHandler: guards.requireAdmin('admin.view') },
    async (request, reply) => {
      const targetId = Number(request.params.id);
      if (!Number.isInteger(targetId) || targetId < 1) {
        return badRequest(reply, 'Identifiant utilisateur invalide.');
      }
      const target = findUserById(handle, targetId);
      if (!target) return userNotFound(reply);
      return {
        user: toPublicUser(target),
        activeSessionCount: countActiveSessions(handle, target.id),
        storageUsage: null,
      };
    },
  );

  // Création de compte par le OWNER (aucune inscription publique dans cette
  // phase) : mot de passe temporaire + changement obligatoire à la première
  // connexion. Jamais de rôle OWNER ici.
  app.post<{ Body: Record<string, unknown> }>(
    '/api/admin/users',
    { preHandler: guards.requireAdmin('user.create') },
    async (request, reply) => {
      const body = request.body ?? {};
      const username = normalizeUsername(body.username);
      if (!username) {
        return badRequest(
          reply,
          'username invalide : 3 à 32 caractères, minuscules/chiffres/._-, début et fin alphanumériques.',
        );
      }
      const displayName = normalizeDisplayName(body.displayName);
      if (!displayName) return badRequest(reply, 'displayName invalide : 1 à 64 caractères.');
      const temporaryPassword = validatePassword(body.temporaryPassword);
      if (!temporaryPassword) {
        return badRequest(
          reply,
          `Mot de passe temporaire invalide : ${PASSWORD_MIN_LENGTH} caractères minimum.`,
        );
      }
      const role = body.role ?? 'USER';
      if (!isAssignableRole(role)) {
        return badRequest(reply, 'Rôle invalide : USER ou ADMIN uniquement.');
      }

      const passwordHash = await hashPassword(temporaryPassword);
      const now = new Date().toISOString();
      let created: UserRow;
      try {
        created = db
          .insert(users)
          .values({
            username,
            displayName,
            passwordHash,
            role,
            isActive: true,
            mustChangePassword: true,
            createdAt: now,
            updatedAt: now,
          })
          .returning()
          .get();
      } catch (error) {
        if (error instanceof Error && error.message.includes('UNIQUE')) {
          return reply.code(409).send({
            statusCode: 409,
            error: 'username_taken',
            message: 'Ce nom d’utilisateur existe déjà.',
          });
        }
        throw error;
      }

      recordAudit(handle, {
        action: 'admin.user_created',
        actorUserId: request.authUser.id,
        targetUserId: created.id,
        metadata: { username: created.username, role: created.role },
      });
      await hooks.onUserCreated?.(created.id, created.username);
      return reply.code(201).send({ user: toPublicUser(created) });
    },
  );

  app.patch<{ Params: { id: string }; Body: Record<string, unknown> }>(
    '/api/admin/users/:id/status',
    { preHandler: guards.requireAdmin('admin.view') },
    async (request, reply) => {
      const body = request.body ?? {};
      if (typeof body.isActive !== 'boolean') {
        return badRequest(reply, 'isActive (booléen) est obligatoire.');
      }
      const action = body.isActive ? 'user.unblock' : 'user.block';
      const target = authorizeTarget(request, reply, action);
      if (!target) return reply;

      const reason =
        typeof body.reason === 'string' && body.reason.trim().length > 0
          ? body.reason.trim().slice(0, 200)
          : null;
      const now = new Date().toISOString();
      db.update(users)
        .set(
          body.isActive
            ? { isActive: true, disabledAt: null, disabledReason: null, updatedAt: now }
            : { isActive: false, disabledAt: now, disabledReason: reason, updatedAt: now },
        )
        .where(eq(users.id, target.id))
        .run();

      // Un compte bloqué perd immédiatement toutes ses sessions.
      if (!body.isActive) revokeAllSessions(handle, target.id);

      recordAudit(handle, {
        action: body.isActive ? 'admin.user_unblocked' : 'admin.user_blocked',
        actorUserId: request.authUser.id,
        targetUserId: target.id,
        metadata: reason ? { reason } : {},
      });
      const updated = findUserById(handle, target.id);
      return { user: toPublicUser(updated ?? target) };
    },
  );

  app.post<{ Params: { id: string }; Body: Record<string, unknown> }>(
    '/api/admin/users/:id/reset-password',
    { preHandler: guards.requireAdmin('admin.view') },
    async (request, reply) => {
      const target = authorizeTarget(request, reply, 'user.reset_password');
      if (!target) return reply;
      const temporaryPassword = validatePassword(request.body?.temporaryPassword);
      if (!temporaryPassword) {
        return badRequest(
          reply,
          `Mot de passe temporaire invalide : ${PASSWORD_MIN_LENGTH} caractères minimum.`,
        );
      }

      const passwordHash = await hashPassword(temporaryPassword);
      const now = new Date().toISOString();
      db.update(users)
        .set({ passwordHash, mustChangePassword: true, updatedAt: now })
        .where(eq(users.id, target.id))
        .run();
      const revokedCount = revokeAllSessions(handle, target.id);

      // Le mot de passe temporaire n'est ni journalisé ni renvoyé : le OWNER
      // le connaît déjà, il le transmet lui-même à l'utilisateur.
      recordAudit(handle, {
        action: 'admin.password_reset',
        actorUserId: request.authUser.id,
        targetUserId: target.id,
        metadata: { sessionCount: revokedCount },
      });
      return { user: toPublicUser(findUserById(handle, target.id) ?? target), revokedSessions: revokedCount };
    },
  );

  app.post<{ Params: { id: string } }>(
    '/api/admin/users/:id/revoke-sessions',
    { preHandler: guards.requireAdmin('admin.view') },
    async (request, reply) => {
      const target = authorizeTarget(request, reply, 'user.revoke_sessions');
      if (!target) return reply;
      const revokedCount = revokeAllSessions(handle, target.id);
      recordAudit(handle, {
        action: 'admin.sessions_revoked',
        actorUserId: request.authUser.id,
        targetUserId: target.id,
        metadata: { sessionCount: revokedCount },
      });
      return { revokedSessions: revokedCount };
    },
  );

  app.patch<{ Params: { id: string }; Body: Record<string, unknown> }>(
    '/api/admin/users/:id/role',
    { preHandler: guards.requireAdmin('admin.view') },
    async (request, reply) => {
      const target = authorizeTarget(request, reply, 'user.set_role');
      if (!target) return reply;
      const role = request.body?.role;
      if (!isAssignableRole(role)) {
        return badRequest(reply, 'Rôle invalide : USER ou ADMIN uniquement.');
      }
      if (role === target.role) {
        return { user: toPublicUser(target), changed: false };
      }
      const now = new Date().toISOString();
      db.update(users).set({ role, updatedAt: now }).where(eq(users.id, target.id)).run();
      recordAudit(handle, {
        action: 'admin.role_changed',
        actorUserId: request.authUser.id,
        targetUserId: target.id,
        metadata: { fromRole: target.role, toRole: role },
      });
      return { user: toPublicUser(findUserById(handle, target.id) ?? target), changed: true };
    },
  );

  app.delete<{ Params: { id: string } }>(
    '/api/admin/users/:id',
    { preHandler: guards.requireAdmin('admin.view') },
    async (request, reply) => {
      const target = authorizeTarget(request, reply, 'user.delete');
      if (!target) return reply;

      // Suppression transactionnelle : sessions par cascade FK. Les fichiers
      // audio physiques ne sont JAMAIS touchés (bibliothèque partagée —
      // comportement futur documenté dans MULTI_USER_DATA_MODEL.md).
      db.transaction((tx) => {
        tx.delete(sessions).where(eq(sessions.userId, target.id)).run();
        tx.delete(users).where(eq(users.id, target.id)).run();
      });

      recordAudit(handle, {
        action: 'admin.user_deleted',
        actorUserId: request.authUser.id,
        targetUserId: target.id,
        metadata: { username: target.username, role: target.role },
      });
      return reply.code(204).send();
    },
  );

  app.get<{ Querystring: { limit?: string; offset?: string } }>(
    '/api/admin/audit-logs',
    { preHandler: guards.requireAdmin('admin.view') },
    async (request, reply) => {
      const limit = Math.min(Math.max(Number(request.query.limit ?? 50) || 50, 1), 200);
      const offset = Math.max(Number(request.query.offset ?? 0) || 0, 0);
      const items = db
        .select()
        .from(auditLogs)
        .orderBy(desc(auditLogs.id))
        .limit(limit)
        .offset(offset)
        .all();
      const total = db.select({ n: sql<number>`count(*)` }).from(auditLogs).get()?.n ?? 0;
      return reply.send({ items, total, limit, offset });
    },
  );
}
