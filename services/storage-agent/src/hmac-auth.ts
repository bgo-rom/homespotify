/**
 * Authentification HMAC-SHA256 datée, avec anti-rejeu.
 *
 * C'est la deuxième des trois barrières du modèle de menace (WireGuard →
 * filtrage IP → HMAC). Elle suppose que le tunnel peut avoir été percé et que
 * l'attaquant voit passer les requêtes : d'où l'horodatage (fenêtre courte), le
 * nonce à usage unique (rejeu impossible) et l'empreinte du corps (aucune
 * substitution).
 *
 * Chaîne canonique signée, éléments séparés par `\n` :
 *
 *   METHOD \n PATH_WITH_QUERY \n TIMESTAMP \n NONCE \n CONTENT_SHA256
 *
 * La query string est INCLUSE : un paramètre ajouté ou retiré invalide la
 * signature.
 */
import { createHash, createHmac, randomBytes, timingSafeEqual } from 'node:crypto';

export const HEADER_TIMESTAMP = 'x-hs-timestamp';
export const HEADER_NONCE = 'x-hs-nonce';
export const HEADER_CONTENT_SHA256 = 'x-hs-content-sha256';
export const HEADER_SIGNATURE = 'x-hs-signature';
export const HEADER_REQUEST_ID = 'x-request-id';

/** SHA-256 du corps vide — valeur attendue pour tout GET/HEAD. */
export const EMPTY_BODY_SHA256 =
  'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

/** Signature hexadécimale d'un SHA-256 : 64 caractères, minuscules. */
const HEX_64 = /^[0-9a-f]{64}$/;

/** Nonce : au moins 128 bits, donc 22 caractères en base64url ou 32 en hexa. */
const NONCE_FORMAT = /^[A-Za-z0-9_+/=-]{22,128}$/;

export type HmacRejectionCode = 'AUTH_MISSING' | 'AUTH_INVALID' | 'AUTH_EXPIRED' | 'AUTH_REPLAY';

export interface CanonicalParts {
  method: string;
  /** Chemin AVEC query string, exactement tel que reçu sur le fil. */
  pathWithQuery: string;
  timestamp: number;
  nonce: string;
  contentSha256: string;
}

/** Construit la chaîne canonique. La méthode est normalisée en majuscules. */
export function canonicalString(parts: CanonicalParts): string {
  return [
    parts.method.toUpperCase(),
    parts.pathWithQuery,
    String(parts.timestamp),
    parts.nonce,
    parts.contentSha256.toLowerCase(),
  ].join('\n');
}

export function sha256Hex(body: Buffer | string): string {
  return createHash('sha256').update(body).digest('hex');
}

export function signCanonical(secret: string, parts: CanonicalParts): string {
  return createHmac('sha256', secret).update(canonicalString(parts), 'utf8').digest('hex');
}

/** Nonce aléatoire 256 bits (base64url), pour le client VPS et les tests. */
export function generateNonce(): string {
  return randomBytes(32).toString('base64url');
}

/**
 * Construit les en-têtes signés d'une requête.
 * Utilisé par les tests et, en Phase 4, par le `RemoteStorageProvider` du VPS.
 */
export function buildSignedHeaders(options: {
  secret: string;
  method: string;
  pathWithQuery: string;
  body?: Buffer | string;
  timestamp?: number;
  nonce?: string;
  requestId?: string;
}): Record<string, string> {
  const timestamp = options.timestamp ?? Math.floor(Date.now() / 1000);
  const nonce = options.nonce ?? generateNonce();
  const contentSha256 =
    options.body === undefined ? EMPTY_BODY_SHA256 : sha256Hex(options.body);
  const signature = signCanonical(options.secret, {
    method: options.method,
    pathWithQuery: options.pathWithQuery,
    timestamp,
    nonce,
    contentSha256,
  });
  return {
    [HEADER_TIMESTAMP]: String(timestamp),
    [HEADER_NONCE]: nonce,
    [HEADER_CONTENT_SHA256]: contentSha256,
    [HEADER_SIGNATURE]: signature,
    ...(options.requestId ? { [HEADER_REQUEST_ID]: options.requestId } : {}),
  };
}

/**
 * Cache anti-rejeu borné.
 *
 * Un nonce n'y entre qu'APRÈS validation de la signature : sans cela, un tiers
 * pourrait saturer le cache avec des nonces inventés sans connaître le secret.
 * La purge est amortie sur les insertions — aucun timer, donc rien à arrêter.
 */
export class NonceCache {
  private readonly seen = new Map<string, number>();

  constructor(
    private readonly ttlMs: number,
    private readonly maxEntries = 20_000,
  ) {}

  get size(): number {
    return this.seen.size;
  }

  /**
   * Consomme un nonce.
   * - `accepted` : première utilisation ;
   * - `replay` : déjà vu dans la fenêtre ;
   * - `saturated` : cache plein même après purge (jamais atteint en usage
   *   normal — un seul client, fenêtre de 60 s).
   */
  consume(nonce: string, nowMs: number = Date.now()): 'accepted' | 'replay' | 'saturated' {
    this.purge(nowMs);
    const expiresAt = this.seen.get(nonce);
    if (expiresAt !== undefined && expiresAt > nowMs) return 'replay';
    if (this.seen.size >= this.maxEntries) return 'saturated';
    this.seen.set(nonce, nowMs + this.ttlMs);
    return 'accepted';
  }

  private purge(nowMs: number): void {
    for (const [nonce, expiresAt] of this.seen) {
      // Map itère dans l'ordre d'insertion, donc dans l'ordre d'expiration :
      // dès qu'une entrée est encore valide, les suivantes le sont aussi.
      if (expiresAt > nowMs) break;
      this.seen.delete(nonce);
    }
  }
}

export interface HmacVerifierOptions {
  secret: string;
  maxClockSkewSeconds: number;
  nonceCache: NonceCache;
  now?: () => number;
}

export type HmacVerification =
  | { ok: true }
  | { ok: false; code: HmacRejectionCode; reason: string };

function headerValue(
  headers: Record<string, string | string[] | undefined>,
  name: string,
): string | null {
  const raw = headers[name];
  // Un en-tête répété est ambigu : refusé plutôt qu'arbitré.
  if (Array.isArray(raw)) return null;
  if (typeof raw !== 'string') return null;
  const trimmed = raw.trim();
  return trimmed.length === 0 ? null : trimmed;
}

export class HmacVerifier {
  private readonly now: () => number;

  constructor(private readonly options: HmacVerifierOptions) {
    this.now = options.now ?? (() => Date.now());
  }

  /**
   * Vérifie une requête. L'ordre des contrôles est délibéré :
   * présence → fraîcheur → format → signature → anti-rejeu.
   */
  verify(input: {
    method: string;
    pathWithQuery: string;
    headers: Record<string, string | string[] | undefined>;
    bodySha256: string;
  }): HmacVerification {
    const timestampRaw = headerValue(input.headers, HEADER_TIMESTAMP);
    const nonce = headerValue(input.headers, HEADER_NONCE);
    const contentSha256 = headerValue(input.headers, HEADER_CONTENT_SHA256);
    const signature = headerValue(input.headers, HEADER_SIGNATURE);

    if (timestampRaw === null || nonce === null || contentSha256 === null || signature === null) {
      return { ok: false, code: 'AUTH_MISSING', reason: 'en-tête d’authentification absent' };
    }

    if (!/^\d{1,15}$/.test(timestampRaw)) {
      return { ok: false, code: 'AUTH_INVALID', reason: 'horodatage non entier' };
    }
    const timestamp = Number(timestampRaw);
    const skewSeconds = Math.abs(Math.floor(this.now() / 1000) - timestamp);
    if (skewSeconds > this.options.maxClockSkewSeconds) {
      // Message distinct du 401 générique : une horloge désynchronisée est une
      // panne d'exploitation, pas une attaque.
      return { ok: false, code: 'AUTH_EXPIRED', reason: 'horodatage hors fenêtre' };
    }

    if (!NONCE_FORMAT.test(nonce)) {
      return { ok: false, code: 'AUTH_INVALID', reason: 'nonce de format invalide' };
    }

    const expectedBodyHash = input.bodySha256.toLowerCase();
    if (contentSha256.toLowerCase() !== expectedBodyHash) {
      return { ok: false, code: 'AUTH_INVALID', reason: 'empreinte de corps incorrecte' };
    }

    // Taille validée AVANT `timingSafeEqual`, qui lève sur longueurs inégales.
    if (!HEX_64.test(signature)) {
      return { ok: false, code: 'AUTH_INVALID', reason: 'signature de format invalide' };
    }

    const expected = signCanonical(this.options.secret, {
      method: input.method,
      pathWithQuery: input.pathWithQuery,
      timestamp,
      nonce,
      contentSha256: expectedBodyHash,
    });
    const provided = Buffer.from(signature, 'hex');
    const reference = Buffer.from(expected, 'hex');
    if (provided.length !== reference.length || !timingSafeEqual(provided, reference)) {
      return { ok: false, code: 'AUTH_INVALID', reason: 'signature invalide' };
    }

    const outcome = this.options.nonceCache.consume(nonce, this.now());
    if (outcome === 'replay') {
      return { ok: false, code: 'AUTH_REPLAY', reason: 'nonce déjà utilisé' };
    }
    if (outcome === 'saturated') {
      return { ok: false, code: 'AUTH_INVALID', reason: 'cache anti-rejeu saturé' };
    }

    return { ok: true };
  }
}
