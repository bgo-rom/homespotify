/**
 * Assainissement des messages issus du processus Antra AVANT stockage en base,
 * journalisation pino ou diffusion SSE.
 *
 * Antra journalise abondamment et peut recracher une clé, un cookie, un jeton
 * ou un chemin Windows absolu dans un message d'erreur. Rien de tout cela ne
 * doit atteindre la base, les logs serveur ni l'application mobile.
 */

/** Longueur maximale conservée : un message d'UI, pas une trace de pile. */
export const MAX_SANITIZED_MESSAGE_LENGTH = 300;

const REDACTED = '[masqué]';

/**
 * Motifs de secrets. L'ordre compte : les formes `clé=valeur` sont traitées
 * avant les jetons nus, sinon la valeur serait masquée sans son étiquette.
 */
const SECRET_PATTERNS: ReadonlyArray<{ pattern: RegExp; replacement: string }> = [
  // clé=valeur / "clé": "valeur" pour tout nom de champ sensible connu.
  {
    pattern:
      // Le guillemet fermant optionnel couvre la forme JSON `"api_key": "…"`,
      // que le moteur produit dans certains messages d'erreur.
      /\b(antra[_-]?api[_-]?key|api[_-]?key|apikey|access[_-]?token|refresh[_-]?token|user[_-]?auth[_-]?token|session[_-]?json|authorization|auth|bearer|password|passwd|secret|client[_-]?secret|arl|sp[_-]?dc|cookie|csrf[-_]?token|token)\b["']?\s*[:=]\s*("[^"]*"|'[^']*'|[^\s,;&)"']{1,})/gi,
    replacement: `$1=${REDACTED}`,
  },
  // En-tête HTTP complet, y compris quand il n'est pas sous forme clé=valeur.
  { pattern: /\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/gi, replacement: `Bearer ${REDACTED}` },
  // Jeton Amazon reconnaissable, présent en clair dans certains logs Antra.
  { pattern: /\bAtna\|[A-Za-z0-9._~+/=-]{8,}/g, replacement: REDACTED },
  // JWT nu (trois segments base64url).
  {
    pattern: /\beyJ[A-Za-z0-9._-]{10,}\.[A-Za-z0-9._-]{10,}\.[A-Za-z0-9._-]{5,}/g,
    replacement: REDACTED,
  },
  // Identifiants dans une URL : https://user:pass@host
  { pattern: /(https?:\/\/)[^/\s:@]+:[^/\s@]+@/gi, replacement: '$1' },
];

/**
 * Chemins locaux. Le backend ne doit jamais révéler l'arborescence du serveur :
 * ni à l'application, ni dans un message d'erreur stocké.
 */
const PATH_PATTERNS: ReadonlyArray<{ pattern: RegExp; replacement: string }> = [
  // Chemin Windows absolu, avec ou sans guillemets.
  { pattern: /[A-Za-z]:\\[^\s"'<>|]*/g, replacement: '[chemin local]' },
  // Chemin UNC.
  { pattern: /\\\\[^\s"'<>|]+/g, replacement: '[chemin local]' },
  // Chemin POSIX absolu vraisemblable (au moins deux segments).
  { pattern: /(?:^|\s)\/(?:[\w.-]+\/){1,}[\w.-]*/g, replacement: ' [chemin local]' },
];

const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/g;

/**
 * Nettoie un message : secrets masqués, chemins locaux retirés, caractères de
 * contrôle supprimés, espaces normalisés, longueur bornée.
 *
 * Retourne `null` pour une entrée vide ou devenue vide : un message vide n'a
 * pas à être persisté ni diffusé.
 */
export function sanitizeMessage(
  raw: unknown,
  maxLength = MAX_SANITIZED_MESSAGE_LENGTH,
): string | null {
  if (typeof raw !== 'string') return null;

  let value = raw;
  for (const { pattern, replacement } of SECRET_PATTERNS) {
    value = value.replace(pattern, replacement);
  }
  for (const { pattern, replacement } of PATH_PATTERNS) {
    value = value.replace(pattern, replacement);
  }

  value = value
    .replace(CONTROL_CHARACTERS, ' ')
    .replace(/\s+/g, ' ')
    .trim();

  if (value.length === 0) return null;
  return value.length > maxLength ? `${value.slice(0, maxLength - 1)}…` : value;
}

/**
 * Version courte pour un champ contraint (titre, artiste, source, qualité).
 * Applique le même masquage, avec une borne plus stricte.
 */
export function sanitizeShortField(
  raw: unknown,
  maxLength = 200,
): string | null {
  return sanitizeMessage(raw, maxLength);
}
