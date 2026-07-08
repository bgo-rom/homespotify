export type RangeResult = { start: number; end: number } | 'full' | 'unsatisfiable';

/**
 * Parse un en-tête HTTP Range (RFC 9110) pour un fichier de `size` octets.
 * - absent/invalide/multi-range → 'full' (réponse 200 complète, permis par la RFC)
 * - hors bornes → 'unsatisfiable' (416)
 * - sinon → bornes inclusives prêtes pour createReadStream({ start, end })
 */
export function parseRangeHeader(header: string | undefined, size: number): RangeResult {
  if (!header) return 'full';
  const m = /^bytes=(\d*)-(\d*)$/.exec(header.trim());
  if (!m) return 'full';
  const startStr = m[1] ?? '';
  const endStr = m[2] ?? '';
  if (startStr === '' && endStr === '') return 'full';
  if (size === 0) return 'unsatisfiable';

  if (startStr === '') {
    // Forme suffixe "bytes=-N" : les N derniers octets
    const n = Number(endStr);
    if (n === 0) return 'unsatisfiable';
    return { start: Math.max(0, size - n), end: size - 1 };
  }

  const start = Number(startStr);
  if (start >= size) return 'unsatisfiable';
  const end = endStr === '' ? size - 1 : Math.min(Number(endStr), size - 1);
  if (end < start) return 'unsatisfiable';
  return { start, end };
}
