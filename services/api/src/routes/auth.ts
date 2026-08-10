import type { FastifyInstance, FastifyReply } from 'fastify';
import { eq } from 'drizzle-orm';
import { users } from '../db/schema.js';
import {
  countUsers,
  createSession,
  findUserById,
  findUserByUsername,
  normalizeDisplayName,
  normalizeUsername,
  revokeAllSessions,
  revokeSessionByToken,
  rotateSession,
  toPublicUser,
  type IssuedSession,
  type UserRow,
} from '../auth/auth-service.js';
import { recordAudit } from '../auth/audit.js';
import { backfillOwnerLibrary } from '../library/user-library-service.js';
import { signAccessToken, type AuthGuards } from '../auth/guards.js';
import { createRateLimiter, AUTH_RATE_LIMIT } from '../lib/rate-limit.js';
import {
  hashPassword,
  validatePassword,
  verifyAgainstDummy,
  verifyPassword,
  PASSWORD_MIN_LENGTH,
} from '../auth/passwords.js';

function badRequest(reply: FastifyReply, message: string): FastifyReply {
  return reply.code(400).send({ statusCode: 400, error: 'bad_request', message });
}

/** Refus générique : ne révèle ni l'existence du compte ni la cause. */
function invalidCredentials(reply: FastifyReply): FastifyReply {
  return reply
    .code(401)
    .send({ statusCode: 401, error: 'invalid_credentials', message: 'Identifiants invalides.' });
}

function sanitizeDeviceName(raw: unknown): string | null {
  if (typeof raw !== 'string') return null;
  const deviceName = raw.trim().replace(/\s+/g, ' ').slice(0, 64);
  return deviceName.length > 0 ? deviceName : null;
}

interface CredentialsBody {
  username?: unknown;
  password?: unknown;
  deviceName?: unknown;
}

interface BootstrapBody extends CredentialsBody {
  displayName?: unknown;
  passwordConfirmation?: unknown;
}

interface RefreshBody {
  refreshToken?: unknown;
}

interface ChangePasswordBody {
  currentPassword?: unknown;
  newPassword?: unknown;
  newPasswordConfirmation?: unknown;
  deviceName?: unknown;
}

export interface AuthRouteHooks {
  /** Appelé (fire-and-forget) après un login réussi — ex. refresh des recos. */
  onLoginSuccess?: (userId: number) => void;
  onUserCreated?: (userId: number, username: string) => Promise<void>;
}

export function registerAuthRoutes(
  app: FastifyInstance,
  guards: AuthGuards,
  hooks: AuthRouteHooks = {},
): void {
  const handle = app.dbHandle;

  // Limiteur partagé par les routes d'authentification non authentifiées
  // (bourrage d'identifiants) et le changement de mot de passe. Clé = IP réelle
  // du client (cf. lib/rate-limit.ts). Fenêtre large, seuil hors d'atteinte
  // pour un humain, mais fatal à une automatisation.
  const authRateLimit = createRateLimiter(AUTH_RATE_LIMIT);

  function issueAuthPayload(user: UserRow, issued: IssuedSession) {
    return {
      user: toPublicUser(user),
      accessToken: signAccessToken(app, user),
      accessTokenExpiresInSeconds: app.config.accessTokenTtlSeconds,
      refreshToken: issued.refreshToken,
      refreshTokenExpiresAt: issued.session.expiresAt,
      sessionId: issued.session.id,
    };
  }

  app.get('/api/auth/bootstrap-status', async () => ({
    bootstrapRequired: countUsers(handle) === 0,
  }));

  app.post<{ Body: BootstrapBody }>(
    '/api/auth/bootstrap',
    { preHandler: authRateLimit },
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
    const password = validatePassword(body.password);
    if (!password) {
      return badRequest(reply, `Mot de passe invalide : ${PASSWORD_MIN_LENGTH} caractères minimum.`);
    }
    if (body.passwordConfirmation !== password) {
      return badRequest(reply, 'La confirmation ne correspond pas au mot de passe.');
    }

    // Hash AVANT la transaction : argon2 est asynchrone, la transaction
    // better-sqlite3 est synchrone et sérialisée dans l'event loop — deux
    // requêtes simultanées ne peuvent donc pas passer le garde-fou ensemble,
    // et l'index unique partiel sur role='OWNER' verrouille le tout en base.
    const passwordHash = await hashPassword(password);
    const now = new Date().toISOString();

    let created: UserRow;
    try {
      created = handle.db.transaction((tx) => {
        const existing = tx.select({ id: users.id }).from(users).limit(1).all();
        if (existing.length > 0) {
          throw new BootstrapUnavailableError();
        }
        return tx
          .insert(users)
          .values({
            username,
            displayName,
            passwordHash,
            role: 'OWNER',
            isActive: true,
            mustChangePassword: false,
            createdAt: now,
            updatedAt: now,
            lastLoginAt: now,
          })
          .returning()
          .get();
      });
    } catch (error) {
      if (error instanceof BootstrapUnavailableError || isUniqueConstraintError(error)) {
        return reply.code(409).send({
          statusCode: 409,
          error: 'bootstrap_unavailable',
          message: 'Le premier compte existe déjà.',
        });
      }
      throw error;
    }

    // Le OWNER vient d'être créé : lui attribuer tout le contenu préexistant
    // (pistes importées avant l'authentification). Idempotent.
    backfillOwnerLibrary(handle);
    await hooks.onUserCreated?.(created.id, created.username);

    const issued = createSession(handle, {
      userId: created.id,
      deviceName: sanitizeDeviceName(body.deviceName),
      ttlSeconds: app.config.refreshTokenTtlSeconds,
    });
    recordAudit(handle, {
      action: 'auth.bootstrap',
      actorUserId: created.id,
      targetUserId: created.id,
      metadata: { username: created.username, role: created.role },
    });
    return reply.code(201).send(issueAuthPayload(created, issued));
    },
  );

  app.post<{ Body: CredentialsBody }>(
    '/api/auth/login',
    { preHandler: authRateLimit },
    async (request, reply) => {
    const body = request.body ?? {};
    const username = normalizeUsername(body.username);
    const password = typeof body.password === 'string' ? body.password : '';

    if (!username || password.length === 0) {
      // Coût constant même sur entrée invalide : pas d'oracle de timing.
      await verifyAgainstDummy(password);
      recordAudit(handle, { action: 'auth.login_failed', metadata: { reason: 'invalid_input' } });
      return invalidCredentials(reply);
    }

    const user = findUserByUsername(handle, username);
    if (!user) {
      await verifyAgainstDummy(password);
      recordAudit(handle, {
        action: 'auth.login_failed',
        metadata: { username, reason: 'unknown_user' },
      });
      return invalidCredentials(reply);
    }

    const passwordOk = await verifyPassword(user.passwordHash, password);
    if (!passwordOk) {
      recordAudit(handle, {
        action: 'auth.login_failed',
        targetUserId: user.id,
        metadata: { username, reason: 'wrong_password' },
      });
      return invalidCredentials(reply);
    }

    if (!user.isActive) {
      recordAudit(handle, {
        action: 'auth.login_failed',
        targetUserId: user.id,
        metadata: { username, reason: 'account_disabled' },
      });
      return reply.code(403).send({
        statusCode: 403,
        error: 'account_disabled',
        message: 'Ce compte est désactivé.',
      });
    }

    const now = new Date().toISOString();
    handle.db.update(users).set({ lastLoginAt: now, updatedAt: now }).where(eq(users.id, user.id)).run();

    const issued = createSession(handle, {
      userId: user.id,
      deviceName: sanitizeDeviceName(body.deviceName),
      ttlSeconds: app.config.refreshTokenTtlSeconds,
    });
    recordAudit(handle, {
      action: 'auth.login_success',
      actorUserId: user.id,
      metadata: { username, deviceName: issued.session.deviceName ?? '' },
    });
    hooks.onLoginSuccess?.(user.id);
    return issueAuthPayload({ ...user, lastLoginAt: now }, issued);
    },
  );

  app.post<{ Body: RefreshBody }>(
    '/api/auth/refresh',
    { preHandler: authRateLimit },
    async (request, reply) => {
    const refreshToken = typeof request.body?.refreshToken === 'string' ? request.body.refreshToken : '';
    if (refreshToken.length === 0) return invalidCredentials(reply);

    const rotated = rotateSession(handle, refreshToken, app.config.refreshTokenTtlSeconds);
    if (!rotated) return invalidCredentials(reply);

    const user = findUserById(handle, rotated.userId);
    if (!user || !user.isActive) {
      // Compte supprimé ou bloqué entre-temps : la session rotée est révoquée.
      revokeAllSessions(handle, rotated.userId);
      return invalidCredentials(reply);
    }

    return issueAuthPayload(user, rotated);
    },
  );

  app.post<{ Body: RefreshBody }>('/api/auth/logout', async (request, reply) => {
    const refreshToken = typeof request.body?.refreshToken === 'string' ? request.body.refreshToken : '';
    if (refreshToken.length > 0) {
      const revoked = revokeSessionByToken(handle, refreshToken);
      if (revoked) {
        recordAudit(handle, { action: 'auth.logout', actorUserId: revoked.userId });
      }
    }
    // Idempotent : un token déjà invalide donne le même résultat côté client.
    return reply.code(204).send();
  });

  app.post(
    '/api/auth/logout-all',
    { preHandler: guards.requireAuth({ allowPendingPasswordChange: true }) },
    async (request, reply) => {
      const revokedCount = revokeAllSessions(handle, request.authUser.id);
      recordAudit(handle, {
        action: 'auth.logout_all',
        actorUserId: request.authUser.id,
        metadata: { sessionCount: revokedCount },
      });
      return reply.code(204).send();
    },
  );

  app.get(
    '/api/auth/me',
    { preHandler: guards.requireAuth({ allowPendingPasswordChange: true }) },
    async (request) => ({ user: request.authUser }),
  );

  app.post<{ Body: ChangePasswordBody }>(
    '/api/auth/change-password',
    { preHandler: [authRateLimit, guards.requireAuth({ allowPendingPasswordChange: true })] },
    async (request, reply) => {
      const body = request.body ?? {};
      const currentPassword = typeof body.currentPassword === 'string' ? body.currentPassword : '';
      const newPassword = validatePassword(body.newPassword);
      if (!newPassword) {
        return badRequest(
          reply,
          `Nouveau mot de passe invalide : ${PASSWORD_MIN_LENGTH} caractères minimum.`,
        );
      }
      if (body.newPasswordConfirmation !== newPassword) {
        return badRequest(reply, 'La confirmation ne correspond pas au nouveau mot de passe.');
      }
      if (newPassword === currentPassword) {
        return badRequest(reply, 'Le nouveau mot de passe doit être différent de l’actuel.');
      }

      const user = findUserById(handle, request.authUser.id);
      if (!user || !(await verifyPassword(user.passwordHash, currentPassword))) {
        return invalidCredentials(reply);
      }

      const passwordHash = await hashPassword(newPassword);
      const now = new Date().toISOString();
      handle.db
        .update(users)
        .set({ passwordHash, mustChangePassword: false, updatedAt: now })
        .where(eq(users.id, user.id))
        .run();

      // Toutes les anciennes sessions tombent (y compris celle-ci) ; une
      // nouvelle session est émise pour que l'appareil courant reste connecté.
      revokeAllSessions(handle, user.id);
      const issued = createSession(handle, {
        userId: user.id,
        deviceName: sanitizeDeviceName(body.deviceName),
        ttlSeconds: app.config.refreshTokenTtlSeconds,
      });
      recordAudit(handle, {
        action: 'auth.password_changed',
        actorUserId: user.id,
        targetUserId: user.id,
      });

      const updated = findUserById(handle, user.id);
      return issueAuthPayload(updated ?? user, issued);
    },
  );
}

class BootstrapUnavailableError extends Error {
  constructor() {
    super('bootstrap indisponible');
  }
}

function isUniqueConstraintError(error: unknown): boolean {
  return (
    error instanceof Error &&
    'code' in error &&
    typeof (error as { code?: unknown }).code === 'string' &&
    ((error as { code: string }).code === 'SQLITE_CONSTRAINT_UNIQUE' ||
      (error as { code: string }).code.startsWith('SQLITE_CONSTRAINT'))
  );
}
