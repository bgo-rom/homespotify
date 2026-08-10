/**
 * Limiteur de débit en mémoire, sans dépendance externe.
 *
 * Pourquoi pas `@fastify/rate-limit` : ce backend sert un seul foyer derrière
 * Caddy. Un limiteur à fenêtre fixe de ~40 lignes couvre exactement le besoin —
 * freiner le bourrage d'identifiants sur l'authentification et l'abus des
 * routes de mise à jour publiques — sans ajouter de surface de dépendance.
 *
 * Modèle de confiance de l'adresse cliente : le processus Node n'écoute que sur
 * 127.0.0.1 ; Caddy est donc son unique pair direct. Caddy AJOUTE l'adresse du
 * client à `X-Forwarded-For` ; un client qui pré-remplit cet en-tête ne peut
 * qu'y insérer des valeurs AVANT celle que Caddy appose. La DERNIÈRE entrée est
 * donc la seule non falsifiable — c'est elle qu'on retient. En l'absence
 * d'en-tête (appel direct en test), on retombe sur l'adresse de la socket.
 */
import type { FastifyInstance, FastifyReply, FastifyRequest, preHandlerHookHandler } from 'fastify';

export interface RateLimitPolicy {
  /** Fenêtre glissante fixe, en millisecondes. */
  windowMs: number;
  /** Nombre maximal de requêtes acceptées par client et par fenêtre. */
  max: number;
}

interface Counter {
  count: number;
  resetAt: number;
}

/** Extrait l'adresse cliente non falsifiable (cf. en-tête de module). */
export function clientKey(request: FastifyRequest): string {
  const forwarded = request.headers['x-forwarded-for'];
  const raw = Array.isArray(forwarded) ? forwarded[forwarded.length - 1] : forwarded;
  if (typeof raw === 'string' && raw.length > 0) {
    const parts = raw.split(',');
    const last = parts[parts.length - 1]?.trim();
    if (last) return last;
  }
  return request.socket.remoteAddress ?? 'unknown';
}

/**
 * Crée un préhandler de limitation pour une politique donnée. Chaque appel
 * possède son propre espace de compteurs (`bucket`), pour que les tentatives de
 * connexion et les sondes de mise à jour ne se partagent pas le même quota.
 *
 * Bornes mémoire : purge amortie des fenêtres expirées à chaque accès, plus un
 * plafond dur d'entrées au-delà duquel les fenêtres expirées sont vidées en
 * masse. Un seul foyer n'atteint jamais ce plafond ; il n'existe que pour
 * qu'une rafale d'IP distinctes ne fasse pas croître la carte sans limite.
 */
export function createRateLimiter(
  policy: RateLimitPolicy,
  options: { maxEntries?: number; now?: () => number } = {},
): preHandlerHookHandler {
  const counters = new Map<string, Counter>();
  const maxEntries = options.maxEntries ?? 10_000;
  const now = options.now ?? (() => Date.now());

  function purgeExpired(currentMs: number): void {
    for (const [key, counter] of counters) {
      if (counter.resetAt <= currentMs) counters.delete(key);
    }
  }

  return async (request: FastifyRequest, reply: FastifyReply) => {
    const key = clientKey(request);
    const currentMs = now();

    let counter = counters.get(key);
    if (counter === undefined || counter.resetAt <= currentMs) {
      if (counters.size >= maxEntries) purgeExpired(currentMs);
      counter = { count: 0, resetAt: currentMs + policy.windowMs };
      counters.set(key, counter);
    }
    counter.count += 1;

    if (counter.count > policy.max) {
      const retryAfterSeconds = Math.max(1, Math.ceil((counter.resetAt - currentMs) / 1000));
      reply.header('retry-after', String(retryAfterSeconds));
      // Message générique : ne révèle ni la politique exacte ni l'état interne.
      return reply.code(429).send({
        statusCode: 429,
        error: 'too_many_requests',
        message: 'Trop de requêtes. Réessaie dans un instant.',
      });
    }
    return undefined;
  };
}

/**
 * Politiques par défaut. Volontairement généreuses pour un usage humain normal,
 * strictes seulement au regard d'une automatisation d'attaque.
 */
export const AUTH_RATE_LIMIT: RateLimitPolicy = { windowMs: 15 * 60 * 1000, max: 40 };
export const APP_UPDATE_RATE_LIMIT: RateLimitPolicy = { windowMs: 60 * 1000, max: 60 };

/** Décorateur pratique : enregistre un préhandler nommé réutilisable. */
export function buildAuthRateLimiter(_app: FastifyInstance): preHandlerHookHandler {
  return createRateLimiter(AUTH_RATE_LIMIT);
}
