/**
 * Transformation d'une intention utilisateur en candidats de téléchargement
 * ordonnés.
 *
 * Deux étapes distinctes, volontairement séparées :
 *   1. **choisir la bonne PISTE** parmi les résultats catalogue (scoring
 *      structurel : ISRC, titre, artiste, durée, album, version) ;
 *   2. **ordonner les URL** de cette piste selon la probabilité qu'Antra
 *      aboutisse réellement (`sourceRank`).
 *
 * Ces deux questions sont indépendantes : se tromper de piste produit un import
 * silencieusement faux, alors que se tromper d'URL ne coûte qu'une tentative.
 */
import { normalizeForMatch } from '../discovery/preview-provider.js';
import type {
  CatalogSearchResult,
  DiscoveryProviderId,
} from '../discovery/catalog/types.js';
import { parseDownloadUrl } from './download-url.js';
import { sanitizeShortField } from './log-sanitizer.js';

/** Marqueurs de version alternative — mêmes termes que le pipeline média. */
const ALT_VERSION_RE =
  /\b(live|en\s+concert|unplugged|remix|rmx|mashup|bootleg|cover|tribute|karaoke|karaoké|instrumental|acoustic|acoustique|re-?recorded|demo|sped\s*up|slowed|nightcore)\b/iu;

/**
 * Ordre de préférence des hôtes pour le TÉLÉCHARGEMENT — distinct de l'ordre
 * d'affichage du catalogue.
 *
 * Fondé sur `tools/antra/antra/core/service.py` : l'URL soumise détermine la
 * stratégie de sources d'Antra.
 *   - URL Spotify  → aucun `source_intent` : chaîne de résolution COMPLÈTE ;
 *   - URL Qobuz/Apple → `prefer_hires` : famille préférée, repli hi-res permis ;
 *   - URL Deezer/Tidal/Amazon → `exclusive` : verrouillé sur UN adaptateur, donc
 *     en échec dès que cet adaptateur est indisponible.
 *
 * Une URL Deezer reste un candidat utile, mais jamais en premier.
 */
const HOST_SOURCE_RANK: ReadonlyArray<{ test: (host: string) => boolean; rank: number }> = [
  { test: (host) => host === 'open.spotify.com', rank: 100 },
  { test: (host) => host.endsWith('qobuz.com'), rank: 80 },
  { test: (host) => host === 'music.apple.com' || host.endsWith('.music.apple.com'), rank: 70 },
  { test: (host) => host.endsWith('tidal.com'), rank: 45 },
  { test: (host) => host.endsWith('deezer.com') || host.endsWith('deezer.page.link'), rank: 40 },
  { test: (host) => host.startsWith('music.amazon.'), rank: 30 },
  { test: (host) => host === 'music.youtube.com', rank: 20 },
  { test: (host) => host.endsWith('soundcloud.com'), rank: 10 },
];

function sourceRankFor(host: string): number {
  return HOST_SOURCE_RANK.find((entry) => entry.test(host))?.rank ?? 5;
}

/** Un candidat de téléchargement : une URL précise pour une piste précise. */
export interface DownloadCandidate {
  /** Catalogue d'origine de l'URL (`deezer`, `itunes`, `spotify`…). */
  provider: DiscoveryProviderId | 'manual';
  /** URL normalisée, déjà validée contre l'allowlist. */
  url: string;
  title: string;
  artist: string;
  album: string | null;
  durationSeconds: number | null;
  isrc: string | null;
  /** Score de correspondance de la PISTE avec l'intention (0-100). */
  confidence: number;
  /** Probabilité qu'Antra aboutisse via cette URL (plus haut = essayé plus tôt). */
  sourceRank: number;
  /** Pochette pour l'affichage. Jamais téléchargée par le backend. */
  artworkUrl: string | null;
}

/** Piste retenue et l'ensemble de ses URL exploitables. */
export interface ResolvedTrack {
  canonicalKey: string;
  title: string;
  artist: string;
  album: string | null;
  durationSeconds: number | null;
  isrc: string | null;
  confidence: number;
  artworkUrl: string | null;
  /** Candidats ordonnés : premier essayé en premier. */
  candidates: DownloadCandidate[];
}

export type CandidateResolution =
  | {
      /** Une piste se détache nettement : le téléchargement peut démarrer. */
      kind: 'confident';
      track: ResolvedTrack;
      /** Autres pistes plausibles, pour information. */
      alternatives: ResolvedTrack[];
    }
  | {
      /** Plusieurs pistes crédibles : l'utilisateur doit trancher. */
      kind: 'ambiguous';
      options: ResolvedTrack[];
    }
  | {
      kind: 'no_match';
    };

export interface ResolverIntent {
  /** Texte brut saisi. */
  query: string;
  /** Titre explicite, quand l'appelant le connaît. */
  title?: string | undefined;
  /** Artiste explicite, quand l'appelant le connaît. */
  artist?: string | undefined;
  /** Album explicite, quand l'appelant le connaît. */
  album?: string | undefined;
}

/** Score minimal pour lancer un téléchargement sans demander confirmation. */
export const CONFIDENT_SCORE_THRESHOLD = 62;
/** En dessous, aucun candidat n'est proposé : mieux vaut ne rien faire. */
export const MINIMUM_PLAUSIBLE_SCORE = 30;
/** Écart minimal avec le second pour considérer le premier comme évident. */
export const CONFIDENT_SCORE_MARGIN = 12;

const MAX_OPTIONS = 8;
const MAX_CANDIDATES_PER_TRACK = 5;

function tokens(value: string): string[] {
  const normalized = normalizeForMatch(value);
  return normalized.length === 0 ? [] : normalized.split(' ').filter(Boolean);
}

function hasAltVersion(value: string): boolean {
  return ALT_VERSION_RE.test(value);
}

function primaryArtist(result: CatalogSearchResult): string {
  return result.artists[0]?.name ?? '';
}

/**
 * Couverture des tokens de l'intention par un texte donné, en proportion.
 * Un token de l'intention absent partout est le signal d'un homonyme.
 */
function coverage(intentTokens: string[], candidateTokens: Set<string>): number {
  if (intentTokens.length === 0) return 0;
  const matched = intentTokens.filter((token) => candidateTokens.has(token)).length;
  return matched / intentTokens.length;
}

/**
 * Score de correspondance PISTE ↔ intention.
 *
 * Priorités imposées : ISRC, puis titre normalisé, puis artiste normalisé,
 * puis durée, puis album, et enfin préférence pour la version studio quand
 * aucune version alternative n'est demandée.
 */
export function scoreTrackMatch(
  result: CatalogSearchResult,
  intent: ResolverIntent,
  options: { expectedIsrc?: string | null; expectedDurationSeconds?: number | null } = {},
): number {
  const titleNorm = normalizeForMatch(result.title);
  const artistNorm = normalizeForMatch(primaryArtist(result));
  const allArtistsNorm = result.artists.map((entry) => normalizeForMatch(entry.name));

  let score = 0;

  // 1. ISRC identique : preuve d'identité la plus forte disponible.
  const expectedIsrc = options.expectedIsrc?.toUpperCase() ?? null;
  if (expectedIsrc !== null && result.isrc !== null) {
    if (result.isrc.toUpperCase() === expectedIsrc) return 100;
    // Un ISRC connu ET différent disqualifie : ce n'est pas la même piste.
    return 0;
  }

  // 2-3. Titre et artiste explicites, quand l'appelant les a fournis.
  if (intent.title !== undefined && intent.title.trim().length > 0) {
    const wanted = normalizeForMatch(intent.title);
    if (titleNorm === wanted) score += 42;
    else if (titleNorm.startsWith(wanted) || wanted.startsWith(titleNorm)) score += 26;
    else if (titleNorm.includes(wanted)) score += 16;
  }
  if (intent.artist !== undefined && intent.artist.trim().length > 0) {
    const wanted = normalizeForMatch(intent.artist);
    if (allArtistsNorm.includes(wanted)) score += 34;
    else if (allArtistsNorm.some((entry) => entry.includes(wanted) || wanted.includes(entry))) {
      score += 18;
    }
  }

  // Texte libre : « Guala Lifestyles » ne dit pas lequel est l'artiste. On
  // mesure donc la couverture des tokens par le couple titre+artiste, ce qui
  // fonctionne dans les deux ordres de saisie.
  const hasExplicitFields =
    (intent.title?.trim().length ?? 0) > 0 || (intent.artist?.trim().length ?? 0) > 0;
  if (!hasExplicitFields) {
    const intentTokens = tokens(intent.query);
    const titleTokens = new Set(tokens(result.title));
    const artistTokens = new Set(allArtistsNorm.flatMap((entry) => entry.split(' ')));
    const albumTokens = new Set(tokens(result.album ?? ''));
    const combined = new Set([...titleTokens, ...artistTokens]);

    const combinedCoverage = coverage(intentTokens, combined);
    // Couverture totale du couple titre+artiste : signal principal.
    score += Math.round(combinedCoverage * 58);
    // Bonus de répartition : au moins un token dans le titre ET un dans
    // l'artiste écarte les résultats qui ne matchent que par un seul champ.
    const inTitle = intentTokens.some((token) => titleTokens.has(token));
    const inArtist = intentTokens.some((token) => artistTokens.has(token));
    if (inTitle && inArtist) score += 18;
    else if (inTitle || inArtist) score += 4;
    // Un token retrouvé uniquement dans l'album n'est pas une preuve d'identité.
    if (!inTitle && !inArtist && intentTokens.some((token) => albumTokens.has(token))) {
      score -= 6;
    }
  }

  // 4. Durée proche, lorsqu'une durée attendue est connue.
  const expectedDuration = options.expectedDurationSeconds ?? null;
  const actualDuration =
    result.durationMs === null ? null : Math.round(result.durationMs / 1000);
  if (expectedDuration !== null && actualDuration !== null) {
    const delta = Math.abs(actualDuration - expectedDuration);
    if (delta <= 2) score += 14;
    else if (delta <= 5) score += 9;
    else if (delta <= 15) score += 3;
    else score -= 12;
  }

  // 5. Album compatible avec l'intention. Un album explicite est un signal
  // d'appoint : il départage deux éditions d'un même titre, mais un album
  // différent ne disqualifie jamais (compilations, rééditions, single vs LP).
  if (result.album !== null) {
    const albumTokens = new Set(tokens(result.album));
    if (intent.album !== undefined && intent.album.trim().length > 0) {
      const wanted = normalizeForMatch(intent.album);
      const resultAlbum = normalizeForMatch(result.album);
      if (resultAlbum === wanted) score += 8;
      else if (resultAlbum.includes(wanted) || wanted.includes(resultAlbum)) score += 4;
    } else if (!hasExplicitFields) {
      if (tokens(intent.query).some((token) => albumTokens.has(token))) score += 4;
    }
  }

  // 6. Version studio préférée quand aucune variante n'est demandée.
  const intentWantsAltVersion = hasAltVersion(intent.query);
  const resultIsAltVersion =
    hasAltVersion(result.title) || hasAltVersion(result.album ?? '');
  if (!intentWantsAltVersion && resultIsAltVersion) score -= 22;
  if (intentWantsAltVersion && resultIsAltVersion) score += 8;

  // Signaux structurels secondaires : un résultat confirmé par plusieurs
  // catalogues est plus sûr qu'un résultat isolé.
  if (result.providerReferences.length >= 2) score += 6;
  if (result.isrc !== null) score += 4;

  return Math.max(0, Math.min(100, score));
}

/**
 * Extrait les URL téléchargeables d'un résultat catalogue, ordonnées par
 * probabilité de succès réel. Une URL non conforme à l'allowlist est ignorée
 * silencieusement : elle ne peut de toute façon pas être soumise au moteur.
 */
export function candidatesForResult(
  result: CatalogSearchResult,
  confidence: number,
): DownloadCandidate[] {
  const title = sanitizeShortField(result.title) ?? result.title;
  const artist = sanitizeShortField(primaryArtist(result)) ?? '';
  const album = sanitizeShortField(result.album);
  const durationSeconds =
    result.durationMs === null ? null : Math.round(result.durationMs / 1000);
  const artworkUrl = result.images[0]?.url ?? null;

  const seen = new Set<string>();
  const candidates: DownloadCandidate[] = [];

  const push = (rawUrl: string | null, provider: DiscoveryProviderId | 'manual'): void => {
    if (rawUrl === null) return;
    const parsed = parseDownloadUrl(rawUrl);
    if (!parsed.ok) return;
    if (seen.has(parsed.normalizedUrl)) return;
    seen.add(parsed.normalizedUrl);
    candidates.push({
      provider,
      url: parsed.normalizedUrl,
      title,
      artist,
      album,
      durationSeconds,
      isrc: result.isrc,
      confidence,
      sourceRank: sourceRankFor(parsed.host),
      artworkUrl,
    });
  };

  // Références directes des catalogues (pistes uniquement : un lien d'album
  // ferait télécharger l'album entier).
  for (const reference of result.providerReferences) {
    if (reference.entityType !== 'track') continue;
    push(reference.externalUrl, reference.provider);
  }
  // Liens externes rapportés par les catalogues (relations MusicBrainz,
  // `external_urls` Spotify…). Ils élargissent la chaîne de repli.
  for (const link of result.externalLinks) {
    push(link.url, providerIdForPlatform(link.platform));
  }

  return candidates
    .sort((a, b) => b.sourceRank - a.sourceRank || a.url.localeCompare(b.url))
    .slice(0, MAX_CANDIDATES_PER_TRACK);
}

function providerIdForPlatform(platform: string): DiscoveryProviderId | 'manual' {
  switch (platform) {
    case 'spotify':
    case 'deezer':
    case 'tidal':
    case 'itunes':
      return platform;
    case 'apple_music':
      return 'apple_music';
    default:
      return 'manual';
  }
}

function toResolvedTrack(
  result: CatalogSearchResult,
  confidence: number,
): ResolvedTrack | null {
  const candidates = candidatesForResult(result, confidence);
  // Une piste sans URL exploitable ne peut pas être téléchargée : la proposer
  // ne ferait que produire un échec garanti.
  if (candidates.length === 0) return null;
  return {
    canonicalKey: result.canonicalKey,
    title: candidates[0]!.title,
    artist: candidates[0]!.artist,
    album: candidates[0]!.album,
    durationSeconds: candidates[0]!.durationSeconds,
    isrc: result.isrc,
    confidence,
    artworkUrl: candidates[0]!.artworkUrl,
    candidates,
  };
}

/**
 * Sélectionne la piste à télécharger.
 *
 * Renvoie `ambiguous` — et donc rend la main à l'utilisateur — plutôt que de
 * télécharger arbitrairement une piste douteuse : un mauvais import pollue la
 * bibliothèque durablement, alors qu'un choix demandé ne coûte qu'un geste.
 */
export class TrackCandidateResolver {
  resolve(
    results: readonly CatalogSearchResult[],
    intent: ResolverIntent,
    options: {
      expectedIsrc?: string | null;
      expectedDurationSeconds?: number | null;
    } = {},
  ): CandidateResolution {
    const scored = results
      .map((result) => ({
        result,
        score: scoreTrackMatch(result, intent, options),
      }))
      .filter((entry) => entry.score >= MINIMUM_PLAUSIBLE_SCORE)
      .sort((a, b) => b.score - a.score);

    const tracks: ResolvedTrack[] = [];
    for (const entry of scored) {
      const track = toResolvedTrack(entry.result, entry.score);
      if (track !== null) tracks.push(track);
      if (tracks.length >= MAX_OPTIONS) break;
    }

    if (tracks.length === 0) return { kind: 'no_match' };

    const best = tracks[0]!;
    const second = tracks[1];
    const isConfident =
      best.confidence >= CONFIDENT_SCORE_THRESHOLD &&
      (second === undefined ||
        best.confidence - second.confidence >= CONFIDENT_SCORE_MARGIN ||
        // Deux entrées de la même piste (même ISRC) ne constituent pas une
        // ambiguïté : c'est la même musique vue par deux catalogues.
        (best.isrc !== null && best.isrc === second.isrc));

    if (isConfident) {
      return { kind: 'confident', track: best, alternatives: tracks.slice(1) };
    }
    return { kind: 'ambiguous', options: tracks };
  }
}
