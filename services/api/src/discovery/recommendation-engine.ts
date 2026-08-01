import { and, eq, gte, inArray, sql } from 'drizzle-orm';
import type { DbHandle } from '../db/client.js';
import {
  appMeta,
  favorites,
  listeningSessions,
  playEvents,
  playlists,
  playlistTracks,
  recommendationCandidates,
  recommendationEvents,
  recommendationImpressions,
  tracks,
  userHiddenTracks,
  userRecommendationQueue,
  userTracks,
} from '../db/schema.js';
import type { CatalogProvider } from './preview-provider.js';
import { MIN_ARTWORK_PX } from './preview-provider.js';
import {
  isArtworkSufficient,
  validatePreviewUrl,
  type PreviewValidationResult,
} from './media-validation.js';
import { isMediaReady, shouldResolveMedia } from './media-state.js';
import type { MediaResolutionStatus } from '../db/schema.js';
import {
  hasSufficientEvidence,
  isStrongEvidence,
  MEDIUM_MATCH,
  STRONG_ARTIST_MATCH,
  type MusicSimilarityProvider,
  type SimilarityEvidence,
} from './music-similarity-provider.js';
import { rejectCandidateQuality } from './candidate-quality.js';
import {
  buildExcludedCandidateIds,
  buildExcludedTrackKeys,
  buildOwnedTrackKeys,
  normalizeKey,
} from './recommendation-service.js';

/**
 * Moteur de recommandation V3 « Swipefy » — graphe de similarité RÉEL.
 *
 * Principes :
 *  - le GET du feed lit une file locale pré-calculée (aucun appel externe) ;
 *  - la génération (asynchrone, single-flight par compte) interroge le graphe
 *    de similarité (Last.fm) à partir de seeds issues du profil de goût,
 *    vérifie chaque candidat (qualité + preuve + extrait iTunes) puis
 *    compose une réserve avec un mélange 60 % SAFE / 30 % ADJACENT /
 *    10 % EXPLORATION ;
 *  - une carte VUE n'est plus jamais exclue définitivement : l'exposition
 *    récente est une pénalité de score, pas un bannissement (leçon V2 : le
 *    feed mourait après une session).
 */

export const RECOMMENDATION_MODEL_VERSION = 'recommendation-v4-media-ready';

/** Cartes MEDIA_READY prêtes visées, immédiatement visibles. */
export const READY_TARGET = 20;
/** Réserve MEDIA_READY visée en plus des prêtes (task : 40). */
export const RESERVE_TARGET = 40;
/** Taille totale composée (que des MEDIA_READY) : prêtes + réserve. */
const QUEUE_COMPOSE_SIZE = READY_TARGET + RESERVE_TARGET;
/** Sous ce nombre de cartes prêtes NON servies, un refill asynchrone part. */
export const REFILL_THRESHOLD = 20;
/** Pool cible de candidats en attente d'enrichissement (task : 100-200). */
export const PENDING_ENRICHMENT_TARGET = 150;

/** TTL du cache de synchronisation graphe externe par utilisateur. */
const GRAPH_SYNC_TTL_MS = 6 * 60 * 60 * 1000;
/** Budget de RÉSOLUTIONS MÉDIA par run (identité + catalogue + validation). */
const MEDIA_RESOLUTION_BUDGET = 40;
/** Concurrence des résolutions média (respect du provider externe). */
const MEDIA_RESOLUTION_CONCURRENCY = 5;
/** TTL avant nouvelle tentative d'un candidat MEDIA_UNAVAILABLE / RETRYABLE. */
const MEDIA_RETRY_TTL_MS = 12 * 60 * 60 * 1000;
/** Durée de vie d'une file générée. */
const QUEUE_TTL_MS = 24 * 60 * 60 * 1000;
/** Fraîcheur d'un extrait résolu avant re-validation. */
const PREVIEW_FRESHNESS_MS = 7 * 24 * 60 * 60 * 1000;
/** Confiance minimale d'un extrait pour être MEDIA_READY. */
export const PREVIEW_CONFIDENCE_FLOOR = 0.8;

// --- Poids du profil de goût ------------------------------------------------
const WEIGHT_FAVORITE = 5;
const WEIGHT_LIKE = 3;
const WEIGHT_PLAYLIST_FIRST = 2;
const WEIGHT_PLAYLIST_EXTRA = 1;
const WEIGHT_LIBRARY = 1;
const WEIGHT_RECENT_LISTEN = 1;
const PLAY_WEIGHT_CAP = 4;
const WEIGHT_SKIP = -0.4;
const SKIP_CAP = -1.2;
const WEIGHT_PREVIEW_STOPPED = -0.3;
const PREVIEW_STOPPED_CAP = -0.9;
/** DISLIKE : fort sur le morceau (exclu), modéré sur l'artiste — jamais un genre. */
const ARTIST_DISLIKE_PENALTY = -2;
const ARTIST_REMOVED_PENALTY = -1;
/** Pénalité par exposition récente (7 jours), plafonnée. */
const IMPRESSION_PENALTY = -1.5;
const IMPRESSION_PENALTY_FLOOR = -4.5;

export const RECOMMENDATION_REASON_CODES = [
  'TOP_ARTIST',
  'TRACK_NEIGHBOR',
  'ARTIST_NEIGHBOR',
  'NEAR_FAVORITES',
  'STYLE_DISCOVERY',
] as const;
export type RecommendationReasonCode = (typeof RECOMMENDATION_REASON_CODES)[number];

export type RecommendationCategory = 'SAFE' | 'ADJACENT' | 'EXPLORATION';

export interface TrackSeed {
  title: string;
  artist: string;
  key: string;
  weight: number;
}

export interface UserTasteProfile {
  /** Poids par artiste (clé normalisée) — peut être négatif (dislikes). */
  artistWeights: Map<string, number>;
  /** Nom affichable par clé normalisée. */
  artistDisplay: Map<string, string>;
  /** Morceaux seeds, du plus aimé au moins aimé (poids > 0 uniquement). */
  trackSeeds: TrackSeed[];
  /** Artistes dominants (poids > 0), noms affichables. */
  topArtists: string[];
  favoriteArtists: string[];
}

const trackKey = (title: string, artist: string): string =>
  `${normalizeKey(title)}|${normalizeKey(artist)}`;

/**
 * Profil de goût V3, STRICTEMENT par compte. Signaux positifs au niveau
 * MORCEAU (favori, écoutes, playlists multiples, demandes abouties, LIKE),
 * agrégés ensuite par artiste avec un multiplicateur d'étendue : quatre
 * pistes d'Ajna pèsent plus qu'un favori isolé d'AC/DC. Négatifs : DISLIKE
 * (morceau exclu, artiste modérément pénalisé), REMOVE (exclu), SKIP et
 * PREVIEW_STOPPED_EARLY (faibles). Jamais de bannissement de genre.
 */
export function buildUserTasteProfile(handle: DbHandle, userId: number): UserTasteProfile {
  const { db } = handle;
  const trackWeights = new Map<string, { title: string; artist: string; weight: number }>();
  const artistDirect = new Map<string, number>(); // pénalités/bonus directs artiste
  const artistDisplay = new Map<string, string>();
  const favoriteScore = new Map<string, number>();

  const remember = (artist: string) => {
    const key = normalizeKey(artist);
    if (key.length > 0 && !artistDisplay.has(key)) artistDisplay.set(key, artist.trim());
  };
  const bumpTrack = (title: string, artist: string, weight: number) => {
    const key = trackKey(title, artist);
    if (key === '|') return;
    const entry = trackWeights.get(key) ?? { title: title.trim(), artist: artist.trim(), weight: 0 };
    entry.weight += weight;
    trackWeights.set(key, entry);
    remember(artist);
  };

  // Bibliothèque visible : socle.
  const libraryRows = db
    .select({ title: tracks.title, artist: tracks.artist })
    .from(userTracks)
    .innerJoin(tracks, eq(tracks.id, userTracks.trackId))
    .where(and(eq(userTracks.userId, userId), eq(userTracks.isVisible, true)))
    .all();
  for (const row of libraryRows) bumpTrack(row.title, row.artist, WEIGHT_LIBRARY);

  // Favoris : très fort.
  const favoriteRows = db
    .select({ title: tracks.title, artist: tracks.artist })
    .from(favorites)
    .innerJoin(tracks, eq(tracks.id, favorites.trackId))
    .where(eq(favorites.userId, userId))
    .all();
  for (const row of favoriteRows) {
    bumpTrack(row.title, row.artist, WEIGHT_FAVORITE);
    favoriteScore.set(normalizeKey(row.artist), (favoriteScore.get(normalizeKey(row.artist)) ?? 0) + 1);
  }

  // Présence en playlists : +2 la première, +1 chaque playlist supplémentaire.
  const playlistRows = db
    .select({
      title: tracks.title,
      artist: tracks.artist,
      n: sql<number>`count(distinct ${playlistTracks.playlistId})`,
    })
    .from(playlistTracks)
    .innerJoin(playlists, eq(playlists.id, playlistTracks.playlistId))
    .innerJoin(tracks, eq(tracks.id, playlistTracks.trackId))
    .where(eq(playlists.userId, userId))
    .groupBy(playlistTracks.trackId)
    .all();
  for (const row of playlistRows) {
    bumpTrack(row.title, row.artist, WEIGHT_PLAYLIST_FIRST + Math.max(0, row.n - 1) * WEIGHT_PLAYLIST_EXTRA);
  }

  // Écoutes réelles (play_events) : fréquence + complétion, plafonné, avec
  // bonus de récence (14 jours).
  const recentCutoff = new Date(Date.now() - 14 * 24 * 60 * 60 * 1000).toISOString();
  const playRows = db
    .select({
      title: tracks.title,
      artist: tracks.artist,
      plays: sql<number>`count(*)`,
      completions: sql<number>`sum(case when ${playEvents.completed} then 1 else 0 end)`,
      lastPlayed: sql<string>`max(${playEvents.startedAt})`,
    })
    .from(playEvents)
    .innerJoin(tracks, eq(tracks.id, playEvents.trackId))
    .where(eq(playEvents.userId, userId))
    .groupBy(playEvents.trackId)
    .all();
  for (const row of playRows) {
    const listenWeight = Math.min(PLAY_WEIGHT_CAP, row.plays * 0.6 + row.completions * 1.2);
    const recentBonus = row.lastPlayed >= recentCutoff ? WEIGHT_RECENT_LISTEN : 0;
    bumpTrack(row.title, row.artist, listenWeight + recentBonus);
  }

  // Sessions fiables de la phase 3B. Seules les écoutes qualifiées comptent :
  // un skip rapide n'est ni un goût positif, ni un DISLIKE implicite.
  const sessionRows = db
    .select({
      title: tracks.title,
      artist: tracks.artist,
      plays: sql<number>`count(*)`,
      completions: sql<number>`sum(case when ${listeningSessions.completed} then 1 else 0 end)`,
      lastPlayed: sql<string>`max(${listeningSessions.startedAt})`,
    })
    .from(listeningSessions)
    .innerJoin(tracks, eq(tracks.id, listeningSessions.trackId))
    .where(
      and(
        eq(listeningSessions.userId, userId),
        eq(listeningSessions.qualifiedPlay, true),
      ),
    )
    .groupBy(listeningSessions.trackId)
    .all();
  for (const row of sessionRows) {
    const listenWeight = Math.min(PLAY_WEIGHT_CAP, row.plays * 0.6 + row.completions * 1.2);
    const recentBonus = row.lastPlayed >= recentCutoff ? WEIGHT_RECENT_LISTEN : 0;
    bumpTrack(row.title, row.artist, listenWeight + recentBonus);
  }

  // Feedback Découvrir, par candidat.
  const swipeRows = db
    .select({
      title: recommendationCandidates.title,
      artist: recommendationCandidates.artist,
      action: recommendationEvents.action,
      n: sql<number>`count(*)`,
    })
    .from(recommendationEvents)
    .innerJoin(
      recommendationCandidates,
      eq(recommendationCandidates.id, recommendationEvents.candidateId),
    )
    .where(eq(recommendationEvents.userId, userId))
    .groupBy(recommendationEvents.candidateId, recommendationEvents.action)
    .all();
  const dislikedArtists = new Set<string>();
  for (const row of swipeRows) {
    switch (row.action) {
      case 'LIKE':
        bumpTrack(row.title, row.artist, WEIGHT_LIKE);
        break;
      case 'SKIP':
        bumpTrack(row.title, row.artist, Math.max(SKIP_CAP, row.n * WEIGHT_SKIP));
        break;
      case 'PREVIEW_STOPPED_EARLY':
        bumpTrack(row.title, row.artist, Math.max(PREVIEW_STOPPED_CAP, row.n * WEIGHT_PREVIEW_STOPPED));
        break;
      case 'DISLIKE':
        // Le morceau est déjà exclu (user_hidden_tracks) ; l'artiste prend une
        // pénalité MODÉRÉE, une seule fois par morceau disliké distinct.
        dislikedArtists.add(`${normalizeKey(row.artist)}|${normalizeKey(row.title)}`);
        break;
      default:
        break;
    }
  }
  for (const entry of dislikedArtists) {
    const artistKey = entry.split('|')[0]!;
    artistDirect.set(artistKey, (artistDirect.get(artistKey) ?? 0) + ARTIST_DISLIKE_PENALTY);
  }

  // Retraits de bibliothèque : pénalité artiste légère (le morceau est exclu).
  const removedRows = db
    .select({ artist: tracks.artist })
    .from(userHiddenTracks)
    .innerJoin(tracks, eq(tracks.id, userHiddenTracks.trackId))
    .where(
      and(
        eq(userHiddenTracks.userId, userId),
        eq(userHiddenTracks.reason, 'REMOVED'),
        sql`${userHiddenTracks.trackId} IS NOT NULL`,
      ),
    )
    .all();
  for (const row of removedRows) {
    const key = normalizeKey(row.artist);
    artistDirect.set(key, (artistDirect.get(key) ?? 0) + ARTIST_REMOVED_PENALTY);
  }

  // Agrégat artiste : somme des poids POSITIFS de morceaux × multiplicateur
  // d'étendue (nombre de morceaux distincts aimés), plus les pénalités
  // directes. Quatre morceaux à +1 (Ajna) > un favori isolé à +6 (AC/DC).
  const artistWeights = new Map<string, number>();
  const artistTrackCount = new Map<string, number>();
  for (const entry of trackWeights.values()) {
    if (entry.weight <= 0) continue;
    const key = normalizeKey(entry.artist);
    artistWeights.set(key, (artistWeights.get(key) ?? 0) + entry.weight);
    artistTrackCount.set(key, (artistTrackCount.get(key) ?? 0) + 1);
  }
  for (const [key, count] of artistTrackCount) {
    const breadth = 1 + 0.25 * (count - 1);
    artistWeights.set(key, (artistWeights.get(key) ?? 0) * breadth);
  }
  for (const [key, penalty] of artistDirect) {
    artistWeights.set(key, (artistWeights.get(key) ?? 0) + penalty);
  }

  const trackSeeds: TrackSeed[] = [...trackWeights.entries()]
    .filter(([, entry]) => entry.weight > 0)
    .map(([key, entry]) => ({ key, title: entry.title, artist: entry.artist, weight: entry.weight }))
    .sort((a, b) => (b.weight !== a.weight ? b.weight - a.weight : a.key.localeCompare(b.key)));

  const byWeightDesc = (map: Map<string, number>): string[] =>
    [...map.entries()]
      .filter(([, weight]) => weight > 0)
      .sort((a, b) => (b[1] !== a[1] ? b[1] - a[1] : a[0].localeCompare(b[0])))
      .map(([key]) => artistDisplay.get(key) ?? key);

  return {
    artistWeights,
    artistDisplay,
    trackSeeds,
    topArtists: byWeightDesc(artistWeights),
    favoriteArtists: byWeightDesc(favoriteScore),
  };
}

// --- Sélection et rotation des seeds ---------------------------------------

const TRACK_SEED_POOL = 12;
const ARTIST_SEED_POOL = 8;
const TRACK_SEEDS_PER_RUN = 5;
const TRACK_SEED_ANCHORS = 3;
const ARTIST_SEEDS_PER_RUN = 3;

function rotationKey(userId: number): string {
  return `reco:v3:rotation:${userId}`;
}

function readRotation(handle: DbHandle, userId: number): number {
  const raw = handle.db
    .select()
    .from(appMeta)
    .where(eq(appMeta.key, rotationKey(userId)))
    .get()?.value;
  const value = Number(raw ?? 0);
  return Number.isInteger(value) && value >= 0 ? value : 0;
}

/** Incrémentée par le bouton « Actualiser » : change la combinaison de seeds. */
export function advanceSeedRotation(handle: DbHandle, userId: number): number {
  const next = readRotation(handle, userId) + 1;
  const now = new Date().toISOString();
  handle.db
    .insert(appMeta)
    .values({ key: rotationKey(userId), value: String(next), updatedAt: now })
    .onConflictDoUpdate({ target: appMeta.key, set: { value: String(next), updatedAt: now } })
    .run();
  return next;
}

function rotate<T>(items: T[], offset: number): T[] {
  if (items.length === 0) return items;
  const shift = offset % items.length;
  return [...items.slice(shift), ...items.slice(0, shift)];
}

export interface SeedSelection {
  trackSeeds: TrackSeed[];
  artistSeeds: string[];
  rotation: number;
}

export function selectSeeds(profile: UserTasteProfile, rotation: number): SeedSelection {
  const trackPool = profile.trackSeeds.slice(0, TRACK_SEED_POOL);
  const artistPool = profile.topArtists.slice(0, ARTIST_SEED_POOL);
  // Les seeds DOMINANTES restent toujours dans le run (elles définissent le
  // goût) ; la rotation ne fait tourner que la traîne — « Actualiser » change
  // donc réellement la combinaison sans perdre le cœur du profil.
  const anchorTracks = trackPool.slice(0, TRACK_SEED_ANCHORS);
  const rotatingTracks = rotate(trackPool.slice(TRACK_SEED_ANCHORS), rotation * 2).slice(
    0,
    Math.max(0, TRACK_SEEDS_PER_RUN - anchorTracks.length),
  );
  const anchorArtists = artistPool.slice(0, 1);
  const rotatingArtists = rotate(artistPool.slice(1), rotation).slice(
    0,
    Math.max(0, ARTIST_SEEDS_PER_RUN - anchorArtists.length),
  );
  return {
    trackSeeds: [...anchorTracks, ...rotatingTracks],
    artistSeeds: [...anchorArtists, ...rotatingArtists],
    rotation,
  };
}

// --- Synchronisation du graphe ----------------------------------------------

interface GraphCandidate {
  title: string;
  artist: string;
  durationMs: number | null;
  externalUrl: string | null;
  evidences: SimilarityEvidence[];
}

/**
 * Interroge le graphe (voisins de morceaux + artistes voisins matérialisés)
 * et retourne les candidats admissibles (qualité + preuve suffisante).
 * Chaque appel provider est fail-soft ; si TOUS échouent, l'erreur remonte.
 */
async function fetchGraphCandidates(
  provider: MusicSimilarityProvider,
  seeds: SeedSelection,
  excludedKeys: Set<string>,
): Promise<{ candidates: GraphCandidate[]; errors: string[] }> {
  const byKey = new Map<string, GraphCandidate>();
  const errors: string[] = [];
  let successfulCalls = 0;

  const addEvidence = (
    neighbor: { title: string; artist: string; durationMs?: number | null; externalUrl: string | null },
    evidence: SimilarityEvidence,
  ) => {
    if (rejectCandidateQuality({ title: neighbor.title, artist: neighbor.artist }) !== null) return;
    const key = trackKey(neighbor.title, neighbor.artist);
    if (excludedKeys.has(key)) return;
    const entry = byKey.get(key) ?? {
      title: neighbor.title.trim(),
      artist: neighbor.artist.trim(),
      durationMs: neighbor.durationMs ?? null,
      externalUrl: neighbor.externalUrl,
      evidences: [],
    };
    if (entry.durationMs === null && neighbor.durationMs) entry.durationMs = neighbor.durationMs;
    entry.evidences.push(evidence);
    byKey.set(key, entry);
  };

  // 1. Voisins DIRECTS des morceaux seeds (relation forte).
  for (const seed of seeds.trackSeeds) {
    try {
      const neighbors = await provider.similarTracks({ title: seed.title, artist: seed.artist });
      successfulCalls += 1;
      for (const neighbor of neighbors) {
        if (neighbor.match < MEDIUM_MATCH) continue;
        addEvidence(neighbor, {
          type: 'TRACK_SIMILAR',
          seed: `${seed.title} — ${seed.artist}`,
          seedArtist: seed.artist,
          match: neighbor.match,
        });
      }
    } catch (error) {
      errors.push(error instanceof Error ? error.message : String(error));
    }
  }

  // 2. Artistes voisins des artistes seeds, matérialisés par leurs morceaux.
  for (const seedArtist of seeds.artistSeeds) {
    try {
      const similar = await provider.similarArtists(seedArtist);
      successfulCalls += 1;
      for (const neighborArtist of similar.filter((a) => a.match >= MEDIUM_MATCH).slice(0, 4)) {
        try {
          const tops = await provider.topTracksOf(neighborArtist.name);
          successfulCalls += 1;
          for (const top of tops.slice(0, 4)) {
            addEvidence(
              { title: top.title, artist: top.artist, externalUrl: top.externalUrl },
              {
                type: 'ARTIST_SIMILAR',
                seed: seedArtist,
                seedArtist,
                match: neighborArtist.match,
              },
            );
          }
        } catch (error) {
          errors.push(error instanceof Error ? error.message : String(error));
        }
      }
    } catch (error) {
      errors.push(error instanceof Error ? error.message : String(error));
    }
  }

  if (successfulCalls === 0 && errors.length > 0) {
    throw new Error(`graphe de similarité indisponible : ${errors[0]}`);
  }

  // Règle d'acceptation : preuve forte OU preuves moyennes indépendantes.
  const candidates = [...byKey.values()].filter((candidate) =>
    hasSufficientEvidence(candidate.evidences),
  );
  return { candidates, errors };
}

function graphExternalId(title: string, artist: string): string {
  return `graph:${trackKey(title, artist)}`;
}

/**
 * Upsert des candidats admissibles (source EXTERNAL_CATALOG + preuves). Les
 * preuves des runs précédents sont FUSIONNÉES (dédupliquées par type+seed) :
 * un voisin confirmé par plusieurs combinaisons de seeds gagne en force.
 */
function upsertGraphCandidates(handle: DbHandle, candidates: GraphCandidate[]): number {
  const now = new Date().toISOString();
  let upserted = 0;
  for (const candidate of candidates) {
    const existing = handle.db
      .select({ evidenceJson: recommendationCandidates.evidenceJson })
      .from(recommendationCandidates)
      .where(
        and(
          eq(recommendationCandidates.source, 'EXTERNAL_CATALOG'),
          eq(
            recommendationCandidates.externalId,
            graphExternalId(candidate.title, candidate.artist),
          ),
        ),
      )
      .get();
    if (existing) {
      const seen = new Set(
        candidate.evidences.map((e) => `${e.type}|${normalizeKey(e.seed)}`),
      );
      for (const evidence of parseEvidences(existing.evidenceJson)) {
        const key = `${evidence.type}|${normalizeKey(evidence.seed)}`;
        if (!seen.has(key)) {
          seen.add(key);
          candidate.evidences.push(evidence);
        }
      }
    }
    handle.db
      .insert(recommendationCandidates)
      .values({
        externalId: graphExternalId(candidate.title, candidate.artist),
        itemType: 'TRACK',
        title: candidate.title,
        artist: candidate.artist,
        album: null,
        artworkUrl: null,
        externalUrl: candidate.externalUrl,
        previewUrl: null,
        durationMs: candidate.durationMs,
        genresJson: null,
        source: 'EXTERNAL_CATALOG',
        metadataJson: null,
        evidenceJson: JSON.stringify(candidate.evidences),
        isActive: true,
        createdAt: now,
        updatedAt: now,
      })
      .onConflictDoUpdate({
        target: [recommendationCandidates.source, recommendationCandidates.externalId],
        targetWhere: sql`${recommendationCandidates.externalId} IS NOT NULL`,
        set: {
          durationMs: candidate.durationMs,
          externalUrl: candidate.externalUrl,
          evidenceJson: JSON.stringify(candidate.evidences),
          isActive: true,
          updatedAt: now,
        },
      })
      .run();
    upserted += 1;
  }
  return upserted;
}

// --- Scoring et catégorisation ----------------------------------------------

export function parseEvidences(evidenceJson: string | null): SimilarityEvidence[] {
  if (evidenceJson === null) return [];
  try {
    const parsed: unknown = JSON.parse(evidenceJson);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(
      (item): item is SimilarityEvidence =>
        typeof item === 'object' &&
        item !== null &&
        ((item as SimilarityEvidence).type === 'TRACK_SIMILAR' ||
          (item as SimilarityEvidence).type === 'ARTIST_SIMILAR') &&
        typeof (item as SimilarityEvidence).match === 'number',
    );
  } catch {
    return [];
  }
}

/** Élision française : « d'Ajna » mais « de Laylow ». */
export function deArtist(name: string): string {
  const first = name.trim().charAt(0).toLowerCase();
  return 'aeiouyhàâéèêëîïôöùûü'.includes(first) ? `d'${name.trim()}` : `de ${name.trim()}`;
}

interface ReasonInput {
  artistKnown: string | null;
  evidences: SimilarityEvidence[];
}

function pickReason(input: ReasonInput): { code: RecommendationReasonCode; text: string } {
  const trackEvidences = input.evidences.filter((e) => e.type === 'TRACK_SIMILAR');
  const artistEvidences = input.evidences.filter((e) => e.type === 'ARTIST_SIMILAR');

  if (input.artistKnown !== null) {
    return { code: 'TOP_ARTIST', text: `Parce que tu écoutes souvent ${input.artistKnown}` };
  }
  if (trackEvidences.length > 0) {
    const seedArtists = [...new Set(trackEvidences.map((e) => e.seedArtist))];
    const seedTitles = [...new Set(trackEvidences.map((e) => e.seed.split(' — ')[0] ?? e.seed))];
    if (trackEvidences.length >= 2 && seedArtists.length === 1) {
      return {
        code: 'TRACK_NEIGHBOR',
        text: `Proche de plusieurs morceaux ${deArtist(seedArtists[0]!)} que tu écoutes souvent`,
      };
    }
    if (seedTitles.length >= 2) {
      return {
        code: 'TRACK_NEIGHBOR',
        text: `Recommandé à partir ${deArtist(seedTitles[0]!)} et ${seedTitles[1]}`,
      };
    }
    return {
      code: 'TRACK_NEIGHBOR',
      text: `Recommandé à partir ${deArtist(seedTitles[0]!)}`,
    };
  }
  if (artistEvidences.length > 0) {
    const seeds = [...new Set(artistEvidences.map((e) => e.seedArtist))];
    if (seeds.length >= 2) {
      return {
        code: 'ARTIST_NEIGHBOR',
        text: `Artiste proche ${deArtist(seeds[0]!)} et ${deArtist(seeds[1]!)}`,
      };
    }
    return { code: 'ARTIST_NEIGHBOR', text: `Artiste proche ${deArtist(seeds[0]!)}` };
  }
  return { code: 'STYLE_DISCOVERY', text: 'Découverte dans un style que tu aimes' };
}

export interface ScoredCandidate {
  candidateId: number;
  trackKey: string;
  artistKey: string;
  score: number;
  category: RecommendationCategory;
  reasonCode: RecommendationReasonCode;
  reasonText: string;
  hasReliablePreview: boolean;
  /** État média courant : seul MEDIA_READY est éligible à la file. */
  mediaStatus: MediaResolutionStatus;
}

/**
 * Note tous les candidats actifs, de qualité valide et non exclus. Le score
 * combine : voisinage direct de morceau (dominant), voisinage d'artiste,
 * affinité pour un artiste déjà connu, indépendance des preuves, pénalités
 * (skips, extraits coupés, expositions récentes, artistes dislikés).
 */
export function scoreCandidatesForUser(handle: DbHandle, userId: number): ScoredCandidate[] {
  const profile = buildUserTasteProfile(handle, userId);
  const excludedIds = buildExcludedCandidateIds(handle, userId);
  const excludedKeys = buildExcludedTrackKeys(handle, userId);
  const ownedKeys = buildOwnedTrackKeys(handle, userId);

  // Expositions récentes : PÉNALITÉ (jamais une exclusion).
  const impressionCutoff = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString();
  const impressionCounts = new Map<number, number>();
  for (const row of handle.db
    .select({ candidateId: recommendationImpressions.candidateId, n: sql<number>`count(*)` })
    .from(recommendationImpressions)
    .where(
      and(
        eq(recommendationImpressions.userId, userId),
        gte(recommendationImpressions.shownAt, impressionCutoff),
      ),
    )
    .groupBy(recommendationImpressions.candidateId)
    .all()) {
    impressionCounts.set(row.candidateId, row.n);
  }

  const skipCounts = new Map<number, number>();
  for (const row of handle.db
    .select({ candidateId: recommendationEvents.candidateId, n: sql<number>`count(*)` })
    .from(recommendationEvents)
    .where(and(eq(recommendationEvents.userId, userId), eq(recommendationEvents.action, 'SKIP')))
    .groupBy(recommendationEvents.candidateId)
    .all()) {
    skipCounts.set(row.candidateId, row.n);
  }

  const candidates = handle.db
    .select()
    .from(recommendationCandidates)
    .where(eq(recommendationCandidates.isActive, true))
    .all();

  const scored: ScoredCandidate[] = [];
  for (const candidate of candidates) {
    if (excludedIds.has(candidate.id)) continue;
    if (
      rejectCandidateQuality({
        title: candidate.title,
        artist: candidate.artist,
        itemType: candidate.itemType,
      }) !== null
    ) {
      continue;
    }
    const key = trackKey(candidate.title, candidate.artist);
    if (ownedKeys.has(key) || excludedKeys.has(key)) continue;

    const artistKey = normalizeKey(candidate.artist);
    const artistWeight = profile.artistWeights.get(artistKey) ?? 0;
    // Artiste globalement rejeté : on n'insiste pas.
    if (artistWeight <= ARTIST_DISLIKE_PENALTY) continue;

    const evidences = parseEvidences(candidate.evidenceJson);
    const strongTrack = Math.max(
      0,
      ...evidences.filter((e) => e.type === 'TRACK_SIMILAR').map((e) => e.match),
    );
    const artistSim = Math.max(
      0,
      ...evidences.filter((e) => e.type === 'ARTIST_SIMILAR').map((e) => e.match),
    );
    const distinctSeedArtists = new Set(evidences.map((e) => normalizeKey(e.seedArtist))).size;
    const hasStrong = evidences.some(isStrongEvidence);
    // Seeds distinctes (morceaux OU artistes) apportant une preuve FORTE.
    const distinctStrongSeeds = new Set(
      evidences.filter(isStrongEvidence).map((e) => normalizeKey(e.seed)),
    ).size;

    // Source MANUAL (owner/tests) sans preuve graphe : admissible, portée par
    // l'affinité locale uniquement.
    const isManual = candidate.source === 'MANUAL';
    if (!isManual && evidences.length === 0) continue;

    const impressionPenalty = Math.max(
      IMPRESSION_PENALTY_FLOOR,
      (impressionCounts.get(candidate.id) ?? 0) * IMPRESSION_PENALTY,
    );
    const skipPenalty = Math.max(SKIP_CAP * 2, (skipCounts.get(candidate.id) ?? 0) * WEIGHT_SKIP * 2);

    const score =
      12 * strongTrack +
      5 * artistSim +
      Math.min(6, Math.max(0, artistWeight)) +
      (distinctSeedArtists >= 2 ? (distinctSeedArtists - 1) * 2 : 0) +
      (artistWeight < 0 ? artistWeight : 0) +
      impressionPenalty +
      skipPenalty;

    const artistKnown = artistWeight > 0 ? (profile.artistDisplay.get(artistKey) ?? candidate.artist) : null;
    let category: RecommendationCategory;
    if (artistKnown !== null || distinctStrongSeeds >= 2 || (hasStrong && distinctSeedArtists >= 2)) {
      category = 'SAFE';
    } else if (hasStrong || artistSim >= STRONG_ARTIST_MATCH) {
      category = 'ADJACENT';
    } else {
      category = 'EXPLORATION';
    }

    const reason = pickReason({ artistKnown, evidences });
    scored.push({
      candidateId: candidate.id,
      trackKey: key,
      artistKey,
      score,
      category,
      reasonCode: reason.code,
      reasonText: reason.text,
      hasReliablePreview:
        candidate.previewUrl !== null &&
        (candidate.previewConfidence ?? 0) >= PREVIEW_CONFIDENCE_FLOOR,
      mediaStatus: candidate.mediaResolutionStatus as MediaResolutionStatus,
    });
  }

  // Tri déterministe : score décroissant puis id croissant.
  scored.sort((a, b) => (b.score !== a.score ? b.score - a.score : a.candidateId - b.candidateId));
  const seenTrackKeys = new Set<string>();
  return scored.filter((candidate) => {
    if (seenTrackKeys.has(candidate.trackKey)) return false;
    seenTrackKeys.add(candidate.trackKey);
    return true;
  });
}

/**
 * Composition : mélange cible 60 % SAFE / 30 % ADJACENT / 10 % EXPLORATION,
 * fenêtre glissante de 10 cartes avec max 2 morceaux du même artiste. Si un
 * seau se vide, les autres débordent — la file ne meurt JAMAIS pour une
 * contrainte de mélange.
 */
export function composeQueue(
  scored: ScoredCandidate[],
  size: number = QUEUE_COMPOSE_SIZE,
): ScoredCandidate[] {
  const buckets: Record<RecommendationCategory, ScoredCandidate[]> = {
    SAFE: scored.filter((item) => item.category === 'SAFE'),
    ADJACENT: scored.filter((item) => item.category === 'ADJACENT'),
    EXPLORATION: scored.filter((item) => item.category === 'EXPLORATION'),
  };
  const pattern: RecommendationCategory[] = [
    'SAFE', 'SAFE', 'SAFE', 'ADJACENT', 'SAFE', 'ADJACENT', 'SAFE', 'ADJACENT', 'SAFE', 'EXPLORATION',
  ];
  const target = Math.min(size, scored.length);
  const result: ScoredCandidate[] = [];
  const used = new Set<number>();

  const violatesDiversity = (item: ScoredCandidate): boolean => {
    const window = result.slice(-9);
    return window.filter((w) => w.artistKey === item.artistKey).length >= 2;
  };

  const takeFrom = (category: RecommendationCategory, relaxed: boolean): ScoredCandidate | null => {
    const order: RecommendationCategory[] =
      category === 'SAFE'
        ? ['SAFE', 'ADJACENT', 'EXPLORATION']
        : category === 'ADJACENT'
          ? ['ADJACENT', 'SAFE', 'EXPLORATION']
          : ['EXPLORATION', 'ADJACENT', 'SAFE'];
    for (const bucket of order) {
      const found = buckets[bucket].find(
        (item) => !used.has(item.candidateId) && (relaxed || !violatesDiversity(item)),
      );
      if (found) return found;
    }
    return null;
  };

  let position = 0;
  while (result.length < target) {
    const wanted = pattern[position % pattern.length]!;
    // Deux passes : d'abord en respectant la diversité, sinon en la relâchant
    // (une carte de plus du même artiste vaut mieux qu'un feed mort).
    const picked = takeFrom(wanted, false) ?? takeFrom(wanted, true);
    if (picked === null) break;
    used.add(picked.candidateId);
    result.push(picked);
    position += 1;
  }
  return result;
}

// --- Résolution média (identité → catalogue → validation → MEDIA_READY) -----

/** Verrou global par candidat : jamais deux résolutions média simultanées. */
const mediaInFlight = new Set<number>();

export interface MediaResolutionOutcome {
  resolvedReady: number;
  failed: number;
  attempted: number;
}

/** Exécute `worker` sur `items` avec une concurrence bornée. */
async function runPool<T>(
  items: T[],
  concurrency: number,
  worker: (item: T) => Promise<void>,
): Promise<void> {
  let cursor = 0;
  const runners = Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (cursor < items.length) {
      const index = cursor;
      cursor += 1;
      await worker(items[index]!);
    }
  });
  await Promise.all(runners);
}

function setMediaState(
  handle: DbHandle,
  candidateId: number,
  status: MediaResolutionStatus,
  fields: Partial<typeof recommendationCandidates.$inferInsert>,
  now: Date,
): void {
  handle.db
    .update(recommendationCandidates)
    .set({
      mediaResolutionStatus: status,
      mediaResolvedAt: now.toISOString(),
      updatedAt: now.toISOString(),
      ...fields,
    })
    .where(eq(recommendationCandidates.id, candidateId))
    .run();
}

/**
 * Résout le média des candidats donnés (priorité = ordre reçu), dans la limite
 * du budget. Enchaîne : verrou MEDIA_RESOLVING → identité ISRC optionnelle →
 * catalogue (extrait + pochette + identité canonique) → validation légère
 * (https + audio + artwork ≥ 500) → MEDIA_READY, sinon MEDIA_UNAVAILABLE /
 * RETRYABLE_ERROR avec raison stable. Ne télécharge JAMAIS l'extrait entier.
 */
export async function resolveMediaForCandidates(
  handle: DbHandle,
  candidateIds: number[],
  deps: QueueRefreshDeps,
  now: Date,
  budget: number = MEDIA_RESOLUTION_BUDGET,
): Promise<MediaResolutionOutcome> {
  const nowMs = now.getTime();
  // Filtre : candidats réellement à (re)traiter, non déjà verrouillés.
  const pending: Array<typeof recommendationCandidates.$inferSelect> = [];
  for (const id of candidateIds) {
    if (pending.length >= budget) break;
    if (mediaInFlight.has(id)) continue;
    const row = handle.db
      .select()
      .from(recommendationCandidates)
      .where(eq(recommendationCandidates.id, id))
      .get();
    if (!row) continue;
    const status = row.mediaResolutionStatus as MediaResolutionStatus;
    const expired =
      row.previewExpiresAt !== null && Date.parse(row.previewExpiresAt) <= nowMs;
    if (isMediaReady(status) && !expired) continue;
    if (!shouldResolveMedia(status, row.mediaResolvedAt, nowMs, MEDIA_RETRY_TTL_MS) && !expired) {
      continue;
    }
    pending.push(row);
    mediaInFlight.add(id);
  }

  const outcome: MediaResolutionOutcome = { resolvedReady: 0, failed: 0, attempted: pending.length };

  try {
    await runPool(pending, MEDIA_RESOLUTION_CONCURRENCY, async (candidate) => {
      // Verrou persistant (single-flight inter-processus / diagnostic).
      setMediaState(handle, candidate.id, 'MEDIA_RESOLVING', {}, now);

      // 1. Identité forte optionnelle (ISRC/MBID).
      let isrc = candidate.isrc;
      if ((isrc === null || isrc === undefined) && deps.identityResolver) {
        try {
          const id = await deps.identityResolver.resolve({
            title: candidate.title,
            artist: candidate.artist,
            durationMs: candidate.durationMs,
          });
          if (id?.isrc) isrc = id.isrc;
        } catch {
          /* identité best-effort : jamais bloquant */
        }
      }

      // 2. Catalogue média.
      const match = await deps.previewProvider.findPreview({
        title: candidate.title,
        artist: candidate.artist,
        durationMs: candidate.durationMs,
        isrc: isrc ?? null,
        catalogId: candidate.appleMusicSongId ?? null,
      });

      if (match === null) {
        setMediaState(
          handle,
          candidate.id,
          'MEDIA_UNAVAILABLE',
          { mediaFailureReason: 'NO_CATALOG_MATCH' },
          now,
        );
        outcome.failed += 1;
        return;
      }

      // 3. Garde-fous MEDIA_READY : confiance, artwork ≥ 500, extrait validé.
      if (match.confidence < PREVIEW_CONFIDENCE_FLOOR) {
        setMediaState(
          handle,
          candidate.id,
          'MEDIA_UNAVAILABLE',
          { mediaFailureReason: 'LOW_CONFIDENCE', isrc: match.isrc ?? isrc ?? null },
          now,
        );
        outcome.failed += 1;
        return;
      }
      if (!isArtworkSufficient(match.artworkUrl, match.artworkWidth, match.artworkHeight, MIN_ARTWORK_PX)) {
        setMediaState(
          handle,
          candidate.id,
          'MEDIA_UNAVAILABLE',
          { mediaFailureReason: 'ARTWORK_INSUFFICIENT' },
          now,
        );
        outcome.failed += 1;
        return;
      }
      const validate = deps.previewValidator ?? validatePreviewUrl;
      const validation = await validate(match.previewUrl);
      if (!validation.ok) {
        // Problème réseau/transitoire côté extrait : réessayable après TTL.
        setMediaState(
          handle,
          candidate.id,
          'RETRYABLE_ERROR',
          { mediaFailureReason: `PREVIEW_${validation.reason ?? 'INVALID'}` },
          now,
        );
        outcome.failed += 1;
        return;
      }

      // 4. MEDIA_READY : identité canonique + média complet persistés.
      setMediaState(
        handle,
        candidate.id,
        'MEDIA_READY',
        {
          canonicalTitle: match.canonicalTitle || candidate.title,
          canonicalArtist: match.canonicalArtist || candidate.artist,
          isrc: match.isrc ?? isrc ?? null,
          appleMusicSongId: match.provider === 'APPLE_MUSIC' ? match.catalogId : candidate.appleMusicSongId,
          previewUrl: match.previewUrl,
          previewProvider: match.provider,
          previewConfidence: match.confidence,
          previewMatchedAt: now.toISOString(),
          previewExpiresAt: new Date(nowMs + PREVIEW_FRESHNESS_MS).toISOString(),
          artworkUrl: match.artworkUrl,
          artworkWidth: match.artworkWidth,
          artworkHeight: match.artworkHeight,
          artworkProvider: match.artworkProvider,
          mediaFailureReason: null,
          ...(match.matchedDurationMs ? { durationMs: match.matchedDurationMs } : {}),
        },
        now,
      );
      outcome.resolvedReady += 1;
    });
  } finally {
    for (const candidate of pending) mediaInFlight.delete(candidate.id);
  }

  return outcome;
}

// --- Rafraîchissement / refill ----------------------------------------------

export interface QueueRefreshResult {
  status: 'refreshed' | 'already_running' | 'retained_old_feed';
  queued: number;
  catalogSynced: boolean;
  /** Nombre de candidats passés à MEDIA_READY pendant ce run. */
  previewsResolved: number;
  /** Candidats devenus MEDIA_UNAVAILABLE / RETRYABLE pendant ce run. */
  mediaFailed: number;
  providerError: string | null;
}

/**
 * Résolution d'identité forte optionnelle (MBID/ISRC via MusicBrainz). Absente
 * par défaut (rate-limit MB) : l'identité normalisée + désambiguïsation suffit.
 * Branchable plus tard sans changer le pipeline.
 */
export interface IdentityResolver {
  resolve(input: {
    title: string;
    artist: string;
    durationMs: number | null;
  }): Promise<{ isrc: string | null; mbid: string | null } | null>;
}

export interface QueueRefreshDeps {
  /** Graphe de similarité (null : non configuré — feed local uniquement). */
  similarityProvider: MusicSimilarityProvider | null;
  /** Catalogue média (iTunes durci primaire | Apple Music si secrets). */
  previewProvider: CatalogProvider;
  /** Résolution ISRC/MBID optionnelle (best-effort). */
  identityResolver?: IdentityResolver | null;
  /** Pré-validation légère de l'extrait (HEAD/MIME). Injectable pour les tests. */
  previewValidator?: (url: string) => Promise<PreviewValidationResult>;
  now?: () => Date;
  /** Force la resynchronisation graphe + invalide les cartes non vues. */
  forceCatalogSync?: boolean;
}

// Single-flight par utilisateur : une seule génération simultanée par compte.
const inFlight = new Map<number, Promise<QueueRefreshResult>>();

export function isRefreshInFlight(userId: number): boolean {
  return inFlight.has(userId);
}

function metaKey(userId: number): string {
  return `reco:catalog_synced:${userId}`;
}

const PROVIDER_ERROR_KEY = 'reco:provider_error';

function writeMeta(handle: DbHandle, key: string, value: string): void {
  const now = new Date().toISOString();
  handle.db
    .insert(appMeta)
    .values({ key, value, updatedAt: now })
    .onConflictDoUpdate({ target: appMeta.key, set: { value, updatedAt: now } })
    .run();
}

function readMeta(handle: DbHandle, key: string): string | null {
  return handle.db.select().from(appMeta).where(eq(appMeta.key, key)).get()?.value ?? null;
}

export function readProviderErrorStatus(handle: DbHandle): { message: string; at: string } | null {
  const raw = readMeta(handle, PROVIDER_ERROR_KEY);
  if (raw === null || raw === '') return null;
  try {
    return JSON.parse(raw) as { message: string; at: string };
  } catch {
    return null;
  }
}

// --- Erreur de rafraîchissement PAR UTILISATEUR -----------------------------
// Le refresh tourne en tâche de fond (fire-and-forget) : sans état persistant,
// un échec (schéma, provider, inattendu) serait invisible côté client. On le
// consigne donc dans app_meta et GET /status le remonte.

export type RefreshErrorKind = 'PROVIDER_ERROR' | 'SCHEMA_ERROR' | 'UNKNOWN_ERROR';

export interface RefreshErrorState {
  kind: RefreshErrorKind;
  message: string;
  at: string;
}

function userErrorKey(userId: number): string {
  return `reco:refresh_error:${userId}`;
}

/** Classe une erreur : un schéma SQLite incomplet (colonne/table absente) est SCHEMA_ERROR. */
export function classifyRefreshError(error: unknown): RefreshErrorKind {
  const message = (error instanceof Error ? error.message : String(error)).toLowerCase();
  if (
    /no such column|no column named|has no column|no such table|table .* has no|readonly|database disk image is malformed|no such index/.test(
      message,
    )
  ) {
    return 'SCHEMA_ERROR';
  }
  return 'UNKNOWN_ERROR';
}

export function recordUserRefreshError(
  handle: DbHandle,
  userId: number,
  kind: RefreshErrorKind,
  message: string,
  at: string = new Date().toISOString(),
): void {
  writeMeta(handle, userErrorKey(userId), JSON.stringify({ kind, message, at }));
}

export function clearUserRefreshError(handle: DbHandle, userId: number): void {
  writeMeta(handle, userErrorKey(userId), '');
}

export function readUserRefreshError(handle: DbHandle, userId: number): RefreshErrorState | null {
  const raw = readMeta(handle, userErrorKey(userId));
  if (raw === null || raw === '') return null;
  try {
    return JSON.parse(raw) as RefreshErrorState;
  } catch {
    return null;
  }
}

export function refreshRecommendationQueueForUser(
  handle: DbHandle,
  userId: number,
  deps: QueueRefreshDeps,
): Promise<QueueRefreshResult> {
  const existing = inFlight.get(userId);
  if (existing) {
    return Promise.resolve({
      status: 'already_running',
      queued: 0,
      catalogSynced: false,
      previewsResolved: 0,
      mediaFailed: 0,
      providerError: null,
    });
  }
  const run = executeRefresh(handle, userId, deps).finally(() => {
    inFlight.delete(userId);
  });
  inFlight.set(userId, run);
  return run;
}

/**
 * Enveloppe de sécurité : toute erreur du refresh (schéma, provider, inattendu)
 * est classée et consignée dans l'état par utilisateur AVANT d'être relancée,
 * pour que `GET /api/recommendations/status` la remonte fidèlement au lieu de
 * mentir (faux positif) ou de « pendre ».
 */
async function executeRefresh(
  handle: DbHandle,
  userId: number,
  deps: QueueRefreshDeps,
): Promise<QueueRefreshResult> {
  try {
    const result = await executeRefreshInner(handle, userId, deps);
    // Succès de génération complet : purge une éventuelle erreur passée.
    if (result.status === 'refreshed') {
      if (result.providerError === null) clearUserRefreshError(handle, userId);
      else
        recordUserRefreshError(handle, userId, 'PROVIDER_ERROR', result.providerError);
    } else if (result.status === 'retained_old_feed' && result.providerError !== null) {
      recordUserRefreshError(handle, userId, 'PROVIDER_ERROR', result.providerError);
    }
    return result;
  } catch (error) {
    const kind = classifyRefreshError(error);
    const message = error instanceof Error ? error.message : String(error);
    recordUserRefreshError(handle, userId, kind, message);
    throw error;
  }
}

async function executeRefreshInner(
  handle: DbHandle,
  userId: number,
  deps: QueueRefreshDeps,
): Promise<QueueRefreshResult> {
  const now = deps.now ? deps.now() : new Date();
  let catalogSynced = false;
  let providerError: string | null = null;

  const existingQueue = handle.db
    .select({
      candidateId: userRecommendationQueue.candidateId,
      servedAt: userRecommendationQueue.servedAt,
    })
    .from(userRecommendationQueue)
    .where(eq(userRecommendationQueue.userId, userId))
    .all();
  const servedAtByCandidate = new Map(existingQueue.map((row) => [row.candidateId, row.servedAt]));

  // 1. Synchronisation graphe externe (jamais pendant un GET) : sous TTL, ou
  //    forcée (bouton Actualiser), ou réserve trop basse.
  const lastSyncRaw = readMeta(handle, metaKey(userId));
  const lastSync = lastSyncRaw ? Date.parse(lastSyncRaw) : Number.NaN;
  const reserveLow = existingQueue.filter((row) => row.servedAt === null).length < RESERVE_TARGET / 2;
  const syncDue =
    deps.forceCatalogSync === true ||
    Number.isNaN(lastSync) ||
    now.getTime() - lastSync >= GRAPH_SYNC_TTL_MS ||
    reserveLow;

  if (syncDue && deps.similarityProvider !== null) {
    try {
      const profile = buildUserTasteProfile(handle, userId);
      const rotation = deps.forceCatalogSync === true
        ? advanceSeedRotation(handle, userId)
        : readRotation(handle, userId);
      const seeds = selectSeeds(profile, rotation);
      if (seeds.trackSeeds.length > 0 || seeds.artistSeeds.length > 0) {
        const excludedKeys = buildExcludedTrackKeys(handle, userId);
        const { candidates } = await fetchGraphCandidates(
          deps.similarityProvider,
          seeds,
          excludedKeys,
        );
        upsertGraphCandidates(handle, candidates);
        writeMeta(handle, metaKey(userId), now.toISOString());
        writeMeta(handle, PROVIDER_ERROR_KEY, '');
        catalogSynced = true;
      }
    } catch (error) {
      providerError = error instanceof Error ? error.message : String(error);
      writeMeta(
        handle,
        PROVIDER_ERROR_KEY,
        JSON.stringify({ message: providerError, at: now.toISOString() }),
      );
    }
  }

  if (providerError !== null && existingQueue.length > 0) {
    return {
      status: 'retained_old_feed',
      queued: existingQueue.length,
      catalogSynced: false,
      previewsResolved: 0,
      mediaFailed: 0,
      providerError,
    };
  }

  // 2. Scoring PROVISOIRE de tous les candidats éligibles (goût + preuve +
  //    qualité), quel que soit leur état média. Sert à PRIORISER la résolution.
  const scored = scoreCandidatesForUser(handle, userId);

  // 3. Résolution média PRIORISÉE par le score : on ne résout que ce qu'il faut
  //    pour atteindre la cible (prêtes + réserve), les non-prêts d'abord. Seuls
  //    les MEDIA_READY pourront ensuite entrer dans la file.
  const alreadyReady = scored.filter((item) => isMediaReady(item.mediaStatus)).length;
  const deficit = Math.max(0, QUEUE_COMPOSE_SIZE - alreadyReady);
  const budget = Math.min(MEDIA_RESOLUTION_BUDGET, deficit);
  let previewsResolved = 0;
  let mediaFailed = 0;
  if (budget > 0) {
    const toResolve = scored
      .filter((item) => item.mediaStatus !== 'MEDIA_READY' && item.mediaStatus !== 'PERMANENTLY_REJECTED')
      .map((item) => item.candidateId);
    const outcome = await resolveMediaForCandidates(handle, toResolve, deps, now, budget);
    previewsResolved = outcome.resolvedReady;
    mediaFailed = outcome.failed;
  }

  // 4. Composition STRICTEMENT sur les MEDIA_READY frais (relecture des états
  //    après résolution). Aucune carte muette ne peut entrer dans la file.
  const scoredIds = scored.map((item) => item.candidateId);
  const readyIds = new Set<number>();
  if (scoredIds.length > 0) {
    for (const row of handle.db
      .select({ id: recommendationCandidates.id })
      .from(recommendationCandidates)
      .where(
        and(
          inArray(recommendationCandidates.id, scoredIds),
          eq(recommendationCandidates.mediaResolutionStatus, 'MEDIA_READY'),
        ),
      )
      .all()) {
      readyIds.add(row.id);
    }
  }
  const eligible = scored
    .filter((item) => readyIds.has(item.candidateId))
    .map((item) => ({ ...item, mediaStatus: 'MEDIA_READY' as MediaResolutionStatus, hasReliablePreview: true }));
  const composed = composeQueue(eligible);

  // 5. Écriture transactionnelle : remplacement complet, en préservant le
  //    marqueur « déjà servie » des cartes conservées.
  const generatedAt = now.toISOString();
  const expiresAt = new Date(now.getTime() + QUEUE_TTL_MS).toISOString();
  handle.db.transaction((tx) => {
    tx.delete(userRecommendationQueue).where(eq(userRecommendationQueue.userId, userId)).run();
    composed.forEach((item, index) => {
      tx.insert(userRecommendationQueue)
        .values({
          userId,
          candidateId: item.candidateId,
          score: item.score,
          rank: index + 1,
          reasonCode: item.reasonCode,
          reasonText: item.reasonText,
          category: item.category,
          // Bouton Actualiser : les cartes non vues sont invalidées (nouvelle
          // combinaison de seeds) — on ne réétiquette jamais une carte servie.
          servedAt: servedAtByCandidate.get(item.candidateId) ?? null,
          generatedAt,
          expiresAt,
          modelVersion: RECOMMENDATION_MODEL_VERSION,
        })
        .run();
    });
  });

  return {
    status: 'refreshed',
    queued: composed.length,
    catalogSynced,
    previewsResolved,
    mediaFailed,
    providerError,
  };
}

// --- Nettoyage legacy (boot) --------------------------------------------------

/**
 * Invalide les artefacts des anciens modèles : files d'une autre
 * modelVersion supprimées, candidats de mauvaise qualité désactivés
 * (l'HISTORIQUE — événements, impressions — est intégralement préservé).
 */
export function invalidateLegacyArtifacts(handle: DbHandle): {
  queuesDropped: number;
  candidatesDeactivated: number;
} {
  const dropped = handle.db
    .delete(userRecommendationQueue)
    .where(sql`${userRecommendationQueue.modelVersion} != ${RECOMMENDATION_MODEL_VERSION}`)
    .run();

  let deactivated = 0;
  const active = handle.db
    .select({
      id: recommendationCandidates.id,
      title: recommendationCandidates.title,
      artist: recommendationCandidates.artist,
      itemType: recommendationCandidates.itemType,
    })
    .from(recommendationCandidates)
    .where(eq(recommendationCandidates.isActive, true))
    .all();
  const now = new Date().toISOString();
  for (const row of active) {
    if (rejectCandidateQuality(row) === null) continue;
    // Poubelle : désactivé ET marqué PERMANENTLY_REJECTED (jamais re-résolu).
    handle.db
      .update(recommendationCandidates)
      .set({
        isActive: false,
        mediaResolutionStatus: 'PERMANENTLY_REJECTED',
        mediaFailureReason: 'QUALITY_REJECTED',
        updatedAt: now,
      })
      .where(eq(recommendationCandidates.id, row.id))
      .run();
    deactivated += 1;
  }
  return { queuesDropped: dropped.changes, candidatesDeactivated: deactivated };
}
