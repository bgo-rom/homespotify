/**
 * Rapprochement et déduplication multi-fournisseurs (Phases 6 et 22).
 * Stratégie DÉTERMINISTE :
 *   1. ISRC exact ;
 *   2. MBID exact ;
 *   3. identité visible normalisée (titre + artiste principal + version) ;
 *   4. aucun regroupement si ambigu (versions alternatives séparées).
 *
 * Jamais de fusion original/remix, studio/live, explicite/censuré : la
 * détection de version réutilise ALT_VERSION_RE du pipeline média validé.
 * Chaque résultat fusionné conserve les références de TOUS les providers.
 */

import { normalizeForMatch } from '../preview-provider.js';
import type { CatalogSearchResult, MatchConfidenceLevel } from './types.js';

const ALT_VERSION_RE =
  /\b(live|en\s+concert|unplugged|remix|rmx|mashup|bootleg|cover|tribute|karaoke|karaoké|instrumental|acoustic|acoustique|re-?recorded|demo|clean|censored)\b/iu;

/** Empreinte de VERSION : distingue remix/live/instrumental du studio. */
function versionFingerprint(result: CatalogSearchResult): string {
  const raw = `${result.title} ${result.album ?? ''}`;
  const markers: string[] = [];
  const re = new RegExp(ALT_VERSION_RE.source, 'giu');
  let match: RegExpExecArray | null;
  while ((match = re.exec(raw)) !== null) markers.push(match[0].toLowerCase());
  return markers.sort().join('+');
}

function identityKey(result: CatalogSearchResult): string {
  const primaryArtist = result.artists[0]?.name ?? '';
  return `${normalizeForMatch(result.title)}|${normalizeForMatch(primaryArtist)}`;
}

/** Ordre de priorité des providers pour le classement (Phase 22). */
const PROVIDER_PRIORITY: Record<string, number> = {
  deezer: 5,
  itunes: 4,
  spotify: 3,
  apple_music: 2,
  musicbrainz: 1,
};

function mergePair(base: CatalogSearchResult, extra: CatalogSearchResult): CatalogSearchResult {
  const references = [...base.providerReferences];
  for (const reference of extra.providerReferences) {
    if (!references.some((r) => r.provider === reference.provider && r.externalId === reference.externalId)) {
      references.push(reference);
    }
  }
  const links = [...base.externalLinks];
  for (const link of extra.externalLinks) {
    if (!links.some((l) => l.url === link.url)) links.push(link);
  }
  const images = [...base.images];
  for (const candidate of extra.images) {
    if (!images.some((entry) => entry.url === candidate.url)) images.push(candidate);
  }
  return {
    ...base,
    isrc: base.isrc ?? extra.isrc,
    upc: base.upc ?? extra.upc,
    mbid: base.mbid ?? extra.mbid,
    album: base.album ?? extra.album,
    durationMs: base.durationMs ?? extra.durationMs,
    releaseDate: base.releaseDate ?? extra.releaseDate,
    explicit: base.explicit ?? extra.explicit,
    trackCount: base.trackCount ?? extra.trackCount,
    images,
    preview: base.preview ?? extra.preview,
    providerReferences: references,
    externalLinks: links,
    // Présence dans plusieurs catalogues = correspondance renforcée.
    matchConfidence: upgradeConfidence(base.matchConfidence),
  };
}

function upgradeConfidence(level: MatchConfidenceLevel): MatchConfidenceLevel {
  return level === 'POSSIBLE' ? 'STRONG' : level;
}

/**
 * Fusionne les résultats de plusieurs providers en préservant l'ordre du
 * premier provider (priorité) et sans jamais fusionner deux versions
 * distinctes (fingerprint de version différent → résultats séparés).
 */
export function mergeSearchResults(lists: CatalogSearchResult[][]): CatalogSearchResult[] {
  const merged: CatalogSearchResult[] = [];
  const byStrongKey = new Map<string, number>(); // isrc:… / upc:… / mbid:…
  const byIdentity = new Map<string, number[]>();

  const tryStrongKeys = (result: CatalogSearchResult): string[] => {
    const keys: string[] = [];
    if (result.isrc) keys.push(`isrc:${result.isrc}`);
    if (result.mbid) keys.push(`mbid:${result.mbid}`);
    if (result.upc) keys.push(`upc:${result.upc}`);
    return keys;
  };

  for (const list of lists) {
    for (const result of list) {
      if (result.title.trim().length === 0) continue;
      // 1-2. Clés fortes (ISRC / MBID / UPC).
      let targetIndex: number | null = null;
      for (const key of tryStrongKeys(result)) {
        const index = byStrongKey.get(key);
        if (index !== undefined) {
          targetIndex = index;
          break;
        }
      }
      // 3. Identité visible + version identique. La durée et le statut
      // explicit divergent trop souvent entre catalogues pour créer une carte
      // supplémentaire : ils restent des métadonnées, jamais une clé d'écran.
      if (targetIndex === null && result.entityType === 'track') {
        const identity = identityKey(result);
        for (const index of byIdentity.get(identity) ?? []) {
          const candidate = merged[index]!;
          if (
            candidate.entityType === 'track' &&
            versionFingerprint(candidate) === versionFingerprint(result)
          ) {
            targetIndex = index;
            break;
          }
        }
      }
      // Les recherches artiste de MusicBrainz contiennent fréquemment plusieurs
      // MBID homonymes sans image. Pour l'affichage de découverte, une seule
      // carte par nom exact est plus utile et permet d'y agréger la photo Deezer.
      if (targetIndex === null && result.entityType === 'artist') {
        const identity = identityKey(result);
        targetIndex = byIdentity.get(identity)?.find(
          (index) => merged[index]?.entityType === 'artist',
        ) ?? null;
      }
      // Un album est fusionné seulement si titre ET artiste principal coïncident.
      // Les albums homonymes d'artistes différents restent donc distincts.
      if (targetIndex === null && result.entityType === 'album') {
        const identity = identityKey(result);
        targetIndex = byIdentity.get(identity)?.find(
          (index) => merged[index]?.entityType === 'album',
        ) ?? null;
      }
      if (targetIndex !== null) {
        merged[targetIndex] = mergePair(merged[targetIndex]!, result);
      } else {
        targetIndex = merged.length;
        merged.push(result);
        const identity = identityKey(result);
        const bucket = byIdentity.get(identity) ?? [];
        bucket.push(targetIndex);
        byIdentity.set(identity, bucket);
      }
      for (const key of tryStrongKeys(merged[targetIndex]!)) {
        if (!byStrongKey.has(key)) byStrongKey.set(key, targetIndex);
      }
    }
  }
  return merged;
}

/**
 * Classement reproductible (Phase 22) : signaux structurels uniquement, jamais
 * une popularité propriétaire seule. Tri STABLE (index d'origine en dernier).
 */
export function rankSearchResults(
  results: CatalogSearchResult[],
  query: string,
): CatalogSearchResult[] {
  const normalizedQuery = normalizeForMatch(query);
  const score = (result: CatalogSearchResult): number => {
    let value = 0;
    if (normalizeForMatch(result.title) === normalizedQuery) value += 40;
    else if (normalizeForMatch(result.title).includes(normalizedQuery)) value += 15;
    if (result.artists.some((a) => normalizeForMatch(a.name) === normalizedQuery)) value += 30;
    if (result.isrc !== null) value += 12;
    if (result.mbid !== null) value += 8;
    if (result.providerReferences.length >= 2) value += 14; // multi-catalogue
    if (result.images.length > 0) value += 10;
    if (result.externalLinks.length > 0) value += 3;
    if (result.preview !== null) value += 12;
    value += Math.max(
      0,
      ...result.providerReferences.map((r) => PROVIDER_PRIORITY[r.provider] ?? 0),
    );
    return value;
  };
  return results
    .map((result, index) => ({ result, index, value: score(result) }))
    .sort((a, b) => b.value - a.value || a.index - b.index)
    .map((entry) => entry.result);
}

/**
 * Une recherche d'artiste exacte ne doit jamais être noyée dans des variantes
 * lexicales. Les homonymes exacts ont déjà été fusionnés par identité ; si au
 * moins un nom exact existe, tout le fuzzy est donc du bruit pour cet écran.
 */
export function keepExactArtistMatchesWhenAvailable(
  results: CatalogSearchResult[],
  query: string,
): CatalogSearchResult[] {
  const normalizedQuery = normalizeForMatch(query);
  if (normalizedQuery.length === 0) return results;
  const exact = results.filter(
    (result) =>
      result.entityType === 'artist' &&
      normalizeForMatch(result.title) === normalizedQuery,
  );
  return exact.length > 0 ? exact : results;
}
