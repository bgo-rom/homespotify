/**
 * Identité de VERSION d'une piste — source unique du projet.
 *
 * Le catalogue distingue mal `addiction` de `addiction (Slowed)` : la
 * normalisation d'identité (`normalizeForMatch`) supprime les parenthèses, donc
 * les deux titres deviennent le même texte. Seule l'empreinte de version
 * ci-dessous les sépare. Elle DOIT donc être unique dans le projet : quatre
 * copies divergentes du même motif ont déjà produit un import faux en
 * production (LESSONS L-081).
 *
 * Règle : deux textes ne désignent la même version que si leurs marqueurs sont
 * identiques. Aucune tolérance, aucun rapprochement « proche » : une version
 * ralentie n'est pas la version normale.
 */

/**
 * Marqueurs de version alternative.
 *
 * Ordre significatif : les variantes longues précèdent les courtes pour que
 * « ultra slowed » ne soit pas réduit à « slowed ».
 */
const ALT_VERSION_SOURCE = [
  'ultra\\s*slowed',
  'super\\s*slowed',
  'slowed(?:\\s*(?:down|\\+|and|&)?\\s*reverb)?',
  'sped\\s*up',
  'speed\\s*up',
  'nightcore',
  'live',
  'en\\s+concert',
  'unplugged',
  'remix',
  'rmx',
  'mashup',
  'bootleg',
  'cover',
  'tribute',
  'karaoke',
  'karaoké',
  'made\\s+famous',
  'as\\s+made\\s+popular',
  'instrumental',
  'acoustic',
  'acoustique',
  're-?recorded',
  're-?record',
  'demo',
  'rehearsal',
  'clean',
  'censored',
].join('|');

/** Motif partagé. Un nouvel appel produit une instance neuve : pas d'état `lastIndex`. */
export function altVersionRegExp(flags = 'iu'): RegExp {
  return new RegExp(`\\b(?:${ALT_VERSION_SOURCE})\\b`, flags);
}

/** true si le texte porte au moins un marqueur de version alternative. */
export function hasAltVersionMarker(value: string): boolean {
  return altVersionRegExp().test(value);
}

/**
 * Empreinte de version d'un ou plusieurs textes (titre, album, requête…).
 *
 * Chaîne vide = version studio ordinaire. Les marqueurs sont dédupliqués,
 * normalisés (espaces compactés, minuscules) et triés : l'empreinte ne dépend
 * ni de l'ordre des mots, ni de la casse, ni de la ponctuation d'espacement.
 */
export function versionFingerprint(...texts: ReadonlyArray<string | null | undefined>): string {
  const haystack = texts.filter((text): text is string => typeof text === 'string').join(' ');
  if (haystack.trim().length === 0) return '';
  const markers = new Set<string>();
  const regExp = altVersionRegExp('giu');
  let match: RegExpExecArray | null;
  while ((match = regExp.exec(haystack)) !== null) {
    markers.add(match[0].toLowerCase().replace(/\s+/gu, ' ').trim());
  }
  return [...markers].sort().join('+');
}

/**
 * Deux empreintes désignent-elles la même version ?
 *
 * Comparaison stricte et symétrique : `''` (studio) ne correspond jamais à
 * `'slowed'`, et réciproquement.
 */
export function sameVersion(left: string, right: string): boolean {
  return left === right;
}
