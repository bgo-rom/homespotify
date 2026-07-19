import type { FastifyInstance, FastifyReply, FastifyRequest, preHandlerHookHandler } from 'fastify';
import { findUserById, toPublicUser, type PublicUser, type UserRow } from './auth-service.js';
import { decide, type AdminAction, type Principal } from './permissions.js';
import type { Role } from './roles.js';

export interface AccessTokenPayload {
  sub: string; // id utilisateur
  username: string;
  role: Role;
  type: 'access';
}

declare module 'fastify' {
  interface FastifyRequest {
    /** Renseigné par requireAuth ; jamais de passwordHash ici. */
    authUser: PublicUser;
  }
}

export function signAccessToken(app: FastifyInstance, user: UserRow): string {
  const payload: AccessTokenPayload = {
    sub: String(user.id),
    username: user.username,
    role: user.role as Role,
    type: 'access',
  };
  return app.jwt.sign(payload, { expiresIn: app.config.accessTokenTtlSeconds });
}

function unauthorized(reply: FastifyReply): FastifyReply {
  // Message générique : ne révèle ni l'existence du compte ni la cause exacte.
  return reply.code(401).send({ statusCode: 401, error: 'unauthorized', message: 'Authentification requise.' });
}

export interface AuthGuards {
  /**
   * Vérifie l'access token, charge l'utilisateur et refuse les comptes
   * inactifs. Par défaut, un compte en `mustChangePassword` est bloqué (403
   * `password_change_required`) sauf sur les routes qui permettent justement
   * d'en sortir (me, change-password, logout).
   */
  requireAuth(options?: { allowPendingPasswordChange?: boolean }): preHandlerHookHandler;
  /** requireAuth + autorisation centralisée (permissions.ts) pour une action admin. */
  requireAdmin(action: AdminAction): preHandlerHookHandler[];
}

export function createAuthGuards(app: FastifyInstance): AuthGuards {
  const requireAuth = (
    options: { allowPendingPasswordChange?: boolean } = {},
  ): preHandlerHookHandler => {
    return async (request: FastifyRequest, reply: FastifyReply) => {
      const header = request.headers.authorization;
      if (typeof header !== 'string' || !header.startsWith('Bearer ')) {
        return unauthorized(reply);
      }
      let payload: AccessTokenPayload;
      try {
        payload = app.jwt.verify<AccessTokenPayload>(header.slice('Bearer '.length));
      } catch {
        return unauthorized(reply);
      }
      if (payload.type !== 'access') return unauthorized(reply);

      const user = findUserById(app.dbHandle, Number(payload.sub));
      if (!user || !user.isActive) return unauthorized(reply);

      if (user.mustChangePassword && options.allowPendingPasswordChange !== true) {
        return reply.code(403).send({
          statusCode: 403,
          error: 'password_change_required',
          message: 'Le mot de passe doit être changé avant de continuer.',
        });
      }

      request.authUser = toPublicUser(user);
    };
  };

  const requireAdmin = (action: AdminAction): preHandlerHookHandler[] => [
    requireAuth(),
    async (request: FastifyRequest, reply: FastifyReply) => {
      const actor: Principal = { id: request.authUser.id, role: request.authUser.role };
      const decision = decide(actor, action);
      if (!decision.allowed) {
        return reply.code(403).send({
          statusCode: 403,
          error: decision.reason ?? 'forbidden',
          message: 'Accès refusé.',
        });
      }
    },
  ];

  return { requireAuth, requireAdmin };
}
