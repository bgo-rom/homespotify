/**
 * Parsing de l'en-tête HTTP Range (RFC 9110), aligné sur le comportement
 * PUBLIC actuel de l'API (`services/api/src/lib/range.ts`).
 *
 * Refus explicite du multi-range : `bytes=0-1,5-6` n'est jamais honoré. La RFC
 * autorise le serveur à ignorer un Range qu'il ne veut pas satisfaire et à
 * répondre 200 avec la représentation complète — c'est ce que fait l'API
 * publique aujourd'hui, et c'est ce que fait l'agent. Aucune réponse
 * `multipart/byteranges` n'est produite nulle part dans HomeSpotify.
 */
export type RangeResult =
  | { kind: 'full' }
  | { kind: 'partial'; start: number; end: number }
  | { kind: 'unsatisfiable' };

const SINGLE_RANGE = /^bytes=(\d*)-(\d*)$/;

export function parseRangeHeader(header: string | undefined, size: number): RangeResult {
  if (header === undefined) return { kind: 'full' };
  const trimmed = header.trim();

  // Multi-range et syntaxes non reconnues : Range ignoré → 200 complet.
  const match = SINGLE_RANGE.exec(trimmed);
  if (match === null) return { kind: 'full' };

  const startStr = match[1] ?? '';
  const endStr = match[2] ?? '';
  if (startStr === '' && endStr === '') return { kind: 'full' };
  // Fichier vide : aucune plage n'est satisfaisable.
  if (size === 0) return { kind: 'unsatisfiable' };

  if (startStr === '') {
    // Forme suffixe « bytes=-N » : les N derniers octets.
    const n = Number(endStr);
    if (n === 0) return { kind: 'unsatisfiable' };
    return { kind: 'partial', start: Math.max(0, size - n), end: size - 1 };
  }

  const start = Number(startStr);
  if (!Number.isSafeInteger(start) || start >= size) return { kind: 'unsatisfiable' };
  const end = endStr === '' ? size - 1 : Math.min(Number(endStr), size - 1);
  if (!Number.isSafeInteger(end) || end < start) return { kind: 'unsatisfiable' };
  return { kind: 'partial', start, end };
}

/** Détecte un multi-range, pour le journaliser explicitement. */
export function isMultiRange(header: string | undefined): boolean {
  return typeof header === 'string' && header.includes(',') && header.trim().startsWith('bytes=');
}
