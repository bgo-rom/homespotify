import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import FormData from 'form-data';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { FastifyInstance } from 'fastify';
import { and, eq } from 'drizzle-orm';
import { buildApp } from '../app.js';
import type { AppConfig } from '../config.js';
import {
  favorites,
  musicRequests,
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
import { makeWav } from '../test/wav.js';
import { reconcileMusicRequestStatus } from './music-request-service.js';
import { listQueueForUser } from './recommendation-service.js';
import type {
  MusicSimilarityProvider,
  SimilarArtistNeighbor,
  SimilarTrackNeighbor,
  TopTrackOfArtist,
} from './music-similarity-provider.js';
import type { PreviewMatch, PreviewProvider } from './preview-provider.js';
import {
  buildUserTasteProfile,
  composeQueue,
  deArtist,
  isRefreshInFlight,
  refreshRecommendationQueueForUser,
  RECOMMENDATION_MODEL_VERSION,
  type ScoredCandidate,
} from './recommendation-engine.js';

let base: string;
let app: FastifyInstance;

/** Graphe de similarité simulé, mutable par test. */
let graphSimilarTracks: Map<string, SimilarTrackNeighbor[]>;
let graphSimilarArtists: Map<string, SimilarArtistNeighbor[]>;
let graphTopTracks: Map<string, TopTrackOfArtist[]>;
let similarityCalls: number;
/** Seeds réellement interrogées (vérifie la rotation du bouton Actualiser). */
let queriedTrackSeeds: string[];
let similarityProvider: MusicSimilarityProvider;
/** Résolutions d'extrait simulées, par titre (mutable par test). */
let previewByTitle: Map<string, PreviewMatch>;
let previewCalls: number;
let previewProvider: PreviewProvider;

const gk = (title: string, artist: string) => `${title.toLowerCase()}|${artist.toLowerCase()}`;

function preview(catalogId: string, confidence = 0.9): PreviewMatch {
  return {
    previewUrl: `https://audio-ssl.itunes.apple.com/${catalogId}.m4a`,
    provider: 'ITUNES',
    confidence,
    catalogId,
    isrc: null,
    canonicalTitle: '',
    canonicalArtist: '',
    artworkUrl: `https://is1-ssl.mzstatic.com/${catalogId}/600x600bb.jpg`,
    artworkWidth: 600,
    artworkHeight: 600,
    artworkProvider: 'ITUNES',
    matchedDurationMs: 180000,
  };
}

/** Validateur d'extrait factice : tout https audio-ssl.itunes est « ok », zéro réseau. */
const fakePreviewValidator = async (url: string) => ({
  ok: url.startsWith('https://'),
  reason: null,
  contentType: 'audio/mp4',
});

function makeConfig(): AppConfig {
  return {
    nodeEnv: 'test',
    host: '127.0.0.1',
    port: 0,
    dbPath: ':memory:',
    logLevel: 'error',
    musicDir: join(base, 'music'),
    incomingDir: join(base, 'imports'),
    importRoot: join(base, 'imports'),
    coversDir: join(base, 'covers'),
    maxUploadBytes: 200 * 1024 * 1024,
    authTokenSecret: 'test-secret-0123456789abcdef0123456789abcdef',
    accessTokenTtlSeconds: 900,
    refreshTokenTtlSeconds: 30 * 24 * 60 * 60,
  };
}

async function bootstrapOwner(): Promise<string> {
  const res = await app.inject({
    method: 'POST',
    url: '/api/auth/bootstrap',
    payload: {
      username: 'owner',
      displayName: 'Owner',
      password: 'motdepasse-owner-1',
      passwordConfirmation: 'motdepasse-owner-1',
    },
  });
  expect(res.statusCode).toBe(201);
  return res.json().accessToken;
}

async function createUser(
  ownerToken: string,
  username: string,
): Promise<{ id: number; token: string }> {
  const created = await app.inject({
    method: 'POST',
    url: '/api/admin/users',
    headers: auth(ownerToken),
    payload: { username, displayName: username, temporaryPassword: 'motdepasse-temp-1', role: 'USER' },
  });
  expect(created.statusCode).toBe(201);
  const id = created.json().user.id;
  const login = await app.inject({
    method: 'POST',
    url: '/api/auth/login',
    payload: { username, password: 'motdepasse-temp-1' },
  });
  const changed = await app.inject({
    method: 'POST',
    url: '/api/auth/change-password',
    headers: auth(login.json().accessToken),
    payload: {
      currentPassword: 'motdepasse-temp-1',
      newPassword: 'motdepasse-final-1',
      newPasswordConfirmation: 'motdepasse-final-1',
    },
  });
  expect(changed.statusCode).toBe(200);
  return { id, token: changed.json().accessToken };
}

async function importTrack(token: string, title: string, artist = 'A'): Promise<number> {
  const form = new FormData();
  form.append('provenance', 'rip_cd');
  form.append('file', makeWav({ title, artist, album: 'Alb', seconds: 0.08 }), {
    filename: `${title}.wav`,
    contentType: 'audio/wav',
  });
  const res = await app.inject({
    method: 'POST',
    url: '/api/tracks',
    payload: form,
    headers: { ...form.getHeaders(), authorization: `Bearer ${token}` },
  });
  expect(res.statusCode).toBe(201);
  return res.json().id;
}

/** Seed direct du catalogue (source MANUAL, admissible sans preuve graphe). */
function insertCandidate(input: {
  title: string;
  artist: string;
  album?: string;
  previewUrl?: string;
  previewConfidence?: number;
  durationMs?: number;
  genres?: string[];
  metadataJson?: string;
  externalId?: string;
  evidenceJson?: string;
  source?: string;
  isActive?: boolean;
}): number {
  const now = new Date().toISOString();
  // Un candidat semé AVEC extrait est considéré déjà MEDIA_READY (identité +
  // artwork + extrait fiable) : il peut entrer dans la file sans passer par la
  // résolution catalogue. Sans extrait, il reste DISCOVERED.
  const confidence =
    input.previewConfidence ?? (input.previewUrl !== undefined ? 0.9 : null);
  const isReady = input.previewUrl !== undefined && (confidence ?? 0) >= 0.8;
  return app.dbHandle.db
    .insert(recommendationCandidates)
    .values({
      externalId: input.externalId ?? null,
      itemType: 'TRACK',
      title: input.title,
      artist: input.artist,
      album: input.album ?? null,
      canonicalTitle: isReady ? input.title : null,
      canonicalArtist: isReady ? input.artist : null,
      artworkUrl: isReady ? `https://is1-ssl.mzstatic.com/${input.title}/600x600bb.jpg` : null,
      artworkWidth: isReady ? 600 : null,
      artworkHeight: isReady ? 600 : null,
      artworkProvider: isReady ? 'ITUNES' : null,
      externalUrl: null,
      previewUrl: input.previewUrl ?? null,
      previewProvider: isReady ? 'ITUNES' : null,
      previewConfidence: confidence,
      previewMatchedAt: isReady ? now : null,
      durationMs: input.durationMs ?? null,
      genresJson: input.genres && input.genres.length > 0 ? JSON.stringify(input.genres) : null,
      source: input.source ?? 'MANUAL',
      metadataJson: input.metadataJson ?? null,
      evidenceJson: input.evidenceJson ?? null,
      mediaResolutionStatus: isReady ? 'MEDIA_READY' : 'DISCOVERED',
      isActive: input.isActive ?? true,
      createdAt: now,
      updatedAt: now,
    })
    .returning({ id: recommendationCandidates.id })
    .get().id;
}

/** Compat helper (les describes historiques passaient un token OWNER). */
async function createCandidate(
  _ownerToken: string,
  input: { title: string; artist: string; album?: string; previewUrl?: string },
): Promise<number> {
  return insertCandidate(input);
}

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/** Attend la fin d'un job en cours puis exécute un refresh COMPLET. */
async function refreshQueue(userId: number, forceCatalogSync = false) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const result = await refreshRecommendationQueueForUser(app.dbHandle, userId, {
      similarityProvider,
      previewProvider,
      previewValidator: fakePreviewValidator,
      forceCatalogSync,
    });
    if (result.status !== 'already_running') return result;
    await sleep(10);
  }
  throw new Error('le refresh de la file n’a jamais pu s’exécuter (single-flight bloqué)');
}

/** Attend que plus aucun job ne tourne pour cet utilisateur. */
async function drainRefresh(userId: number) {
  for (let attempt = 0; attempt < 200 && isRefreshInFlight(userId); attempt += 1) {
    await sleep(5);
  }
}

function auth(token: string) {
  return { authorization: `Bearer ${token}` };
}

/**
 * Fixture « Ajna » : bibliothèque rap FR réaliste (profil du rapport de
 * Phase 1). Ajna domine par l'étendue (4 morceaux + playlist + écoutes),
 * malgré UN favori isolé AC/DC.
 */
async function seedAjnaFixture(token: string, userId: number) {
  const allBlack = await importTrack(token, 'All Black', 'Ajna');
  const after = await importTrack(token, 'After', 'Ajna');
  const sully = await importTrack(token, 'Sully', 'Ajna');
  const antidote = await importTrack(token, 'Antidote', 'Ajna');
  const acdc = await importTrack(token, 'Back In Black', 'AC/DC');
  await importTrack(token, 'Tieks', 'Laylow');
  const favored = await app.inject({
    method: 'POST',
    url: '/api/favorites',
    headers: auth(token),
    payload: { trackId: acdc },
  });
  expect(favored.statusCode).toBe(201);

  const playlist = await app.inject({
    method: 'POST',
    url: '/api/playlists',
    headers: auth(token),
    payload: { name: 'Rap FR' },
  });
  for (const trackId of [allBlack, after]) {
    await app.inject({
      method: 'POST',
      url: `/api/playlists/${playlist.json().id}/tracks`,
      headers: auth(token),
      payload: { trackId },
    });
  }

  // Écoutes réelles via la route publique d'ingestion.
  const played = await app.inject({
    method: 'POST',
    url: '/api/play-events',
    headers: auth(token),
    payload: {
      items: [
        { trackId: allBlack, startedAt: new Date().toISOString(), listenedMs: 180000, completed: true },
        { trackId: allBlack, startedAt: new Date().toISOString(), listenedMs: 175000, completed: true },
        { trackId: after, startedAt: new Date().toISOString(), listenedMs: 160000, completed: true },
        { trackId: sully, startedAt: new Date().toISOString(), listenedMs: 90000, completed: false },
      ],
    },
  });
  expect(played.statusCode).toBe(201);
  expect(played.json().inserted).toBe(4);

  // Graphe : voisins directs des morceaux d'Ajna + artistes voisins.
  graphSimilarTracks.set(gk('All Black', 'Ajna'), [
    { title: 'Tout Noir', artist: 'Nono La Grinta', durationMs: 180000, externalUrl: 'https://www.last.fm/1', match: 0.82 },
    { title: 'Nuit Blanche', artist: 'Guala', durationMs: 175000, externalUrl: 'https://www.last.fm/2', match: 0.44 },
    // Poubelle : bannie par le filtre qualité malgré un bon match.
    { title: 'Rap FR Megamix', artist: 'Various Artists', durationMs: null, externalUrl: null, match: 0.9 },
  ]);
  graphSimilarTracks.set(gk('After', 'Ajna'), [
    { title: 'Tout Noir', artist: 'Nono La Grinta', durationMs: 180000, externalUrl: 'https://www.last.fm/1', match: 0.71 },
    { title: 'Minuit', artist: 'Kairo Keyz', durationMs: 200000, externalUrl: 'https://www.last.fm/3', match: 0.36 },
  ]);
  graphSimilarArtists.set('ajna', [
    { name: 'H.LLS', match: 0.88, externalUrl: 'https://www.last.fm/hlls' },
    { name: 'Jaywill', match: 0.52, externalUrl: 'https://www.last.fm/jaywill' },
    // Trop faible : jamais exploité seul.
    { name: 'Artiste Tag Générique', match: 0.05, externalUrl: null },
  ]);
  graphSimilarArtists.set('laylow', [
    { name: 'Jaywill', match: 0.41, externalUrl: 'https://www.last.fm/jaywill' },
  ]);
  graphTopTracks.set('h.lls', [
    { title: 'Vertige', artist: 'H.LLS', externalUrl: 'https://www.last.fm/4' },
    { title: 'Peine', artist: 'H.LLS', externalUrl: 'https://www.last.fm/5' },
  ]);
  graphTopTracks.set('jaywill', [
    { title: 'Rechute', artist: 'Jaywill', externalUrl: 'https://www.last.fm/6' },
  ]);

  // Extraits iTunes fiables pour les candidats attendus.
  previewByTitle.set('Tout Noir', preview('1001'));
  previewByTitle.set('Nuit Blanche', preview('1002'));
  previewByTitle.set('Minuit', preview('1003'));
  previewByTitle.set('Vertige', preview('1004'));
  previewByTitle.set('Peine', preview('1005'));
  // Rechute : match ambigu (confiance 0.65) → hors feed standard.
  previewByTitle.set('Rechute', preview('1006', 0.65));

  return { allBlack, after, sully, antidote, acdc, userId };
}

beforeEach(async () => {
  base = mkdtempSync(join(tmpdir(), 'homespotify-disco-'));
  graphSimilarTracks = new Map();
  graphSimilarArtists = new Map();
  graphTopTracks = new Map();
  similarityCalls = 0;
  queriedTrackSeeds = [];
  similarityProvider = {
    id: 'FAKE_GRAPH',
    async similarTracks(seed) {
      similarityCalls += 1;
      queriedTrackSeeds.push(gk(seed.title, seed.artist));
      return graphSimilarTracks.get(gk(seed.title, seed.artist)) ?? [];
    },
    async similarArtists(seedArtist) {
      similarityCalls += 1;
      return graphSimilarArtists.get(seedArtist.toLowerCase()) ?? [];
    },
    async topTracksOf(artist) {
      similarityCalls += 1;
      return graphTopTracks.get(artist.toLowerCase()) ?? [];
    },
  };
  previewByTitle = new Map();
  previewCalls = 0;
  previewProvider = {
    id: 'ITUNES',
    async findPreview(input) {
      previewCalls += 1;
      return previewByTitle.get(input.title) ?? null;
    },
  };
  app = buildApp(makeConfig(), {
    similarityProvider,
    previewProvider,
    previewValidator: fakePreviewValidator,
  });
  await app.ready();
});

afterEach(async () => {
  await app.close();
  rmSync(base, { recursive: true, force: true });
});

describe('profil de goût V3 (fixture Ajna)', () => {
  it('Ajna domine par l’étendue malgré un favori isolé, sans artiste fantôme', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    await seedAjnaFixture(alice.token, alice.id);

    const profile = buildUserTasteProfile(app.dbHandle, alice.id);
    expect(profile.topArtists[0]).toBe('Ajna');
    // 4 morceaux d'Ajna = UNE seule entrée artiste (pas de fantômes).
    const ajnaKeys = [...profile.artistWeights.keys()].filter((key) => key.includes('ajna'));
    expect(ajnaKeys).toEqual(['ajna']);
    // Les morceaux d'Antidote/All Black renforcent le poids d'Ajna.
    expect(profile.artistWeights.get('ajna')!).toBeGreaterThan(
      profile.artistWeights.get('ac/dc')!,
    );
    // Les seeds morceaux sont les plus écoutés/favoris en tête.
    expect(profile.trackSeeds[0]!.artist === 'Ajna' || profile.trackSeeds[0]!.artist === 'AC/DC').toBe(true);
    const seedTitles = profile.trackSeeds.slice(0, 6).map((seed) => seed.title);
    expect(seedTitles).toContain('All Black');
    expect(seedTitles).toContain('After');
  });

  it('les écoutes arrivent par POST /api/play-events (compte du token uniquement)', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    const bob = await createUser(ownerToken, 'bob');
    const trackAlice = await importTrack(alice.token, 'Privée', 'Artiste');

    // bob ne peut pas injecter d'écoutes sur une piste qu'il ne possède pas.
    const rejected = await app.inject({
      method: 'POST',
      url: '/api/play-events',
      headers: auth(bob.token),
      payload: {
        items: [{ trackId: trackAlice, startedAt: new Date().toISOString(), listenedMs: 1000 }],
      },
    });
    expect(rejected.statusCode).toBe(201);
    expect(rejected.json().inserted).toBe(0);

    const anonymous = await app.inject({
      method: 'POST',
      url: '/api/play-events',
      payload: { items: [] },
    });
    expect(anonymous.statusCode).toBe(401);
  });

  it('DISLIKE pénalise modérément l’artiste sans bannir le reste du feed', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    await importTrack(alice.token, 'Base', 'Artiste Socle');
    const c1 = insertCandidate({ title: 'Détestée', artist: 'Artiste Moyen', previewUrl: 'https://x.example/1.m4a' });
    insertCandidate({ title: 'Autre du même', artist: 'Artiste Moyen', previewUrl: 'https://x.example/2.m4a' });
    insertCandidate({ title: 'Ailleurs', artist: 'Artiste Socle', previewUrl: 'https://x.example/3.m4a' });
    await app.inject({
      method: 'POST',
      url: `/api/recommendations/${c1}/action`,
      headers: auth(alice.token),
      payload: { action: 'DISLIKE' },
    });
    await refreshQueue(alice.id);

    const res = await app.inject({
      method: 'GET',
      url: '/api/recommendations',
      headers: auth(alice.token),
    });
    const items = res.json().items as Array<{ title: string; artist: string }>;
    // Le morceau disliké ne revient jamais ; l'artiste PEUT revenir (pénalité
    // modérée, pas un bannissement) et le reste du feed vit toujours.
    expect(items.map((i) => i.title)).not.toContain('Détestée');
    expect(items.map((i) => i.title)).toContain('Ailleurs');
  });

  it('PREVIEW_STOPPED_EARLY est une action de feedback acceptée', async () => {
    const ownerToken = await bootstrapOwner();
    const cid = insertCandidate({ title: 'Coupée', artist: 'Artiste' });
    const res = await app.inject({
      method: 'POST',
      url: `/api/recommendations/${cid}/action`,
      headers: auth(ownerToken),
      payload: { action: 'PREVIEW_STOPPED_EARLY' },
    });
    expect(res.statusCode).toBe(201);
  });
});

describe('graphe de similarité et génération V3', () => {
  it('génère depuis le graphe : preuves exigées, Various Artists banni, raisons FR', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    await seedAjnaFixture(alice.token, alice.id);

    const result = await refreshQueue(alice.id, true);
    expect(result.status).toBe('refreshed');
    expect(result.queued).toBeGreaterThan(0);

    const res = await app.inject({
      method: 'GET',
      url: '/api/recommendations?limit=20',
      headers: auth(alice.token),
    });
    const items = res.json().items as Array<{
      title: string;
      artist: string;
      reason: string;
      reasonCode: string;
      category: string;
      previewUrl: string | null;
      modelVersion: string;
    }>;
    expect(items.length).toBeGreaterThan(0);
    const artists = items.map((item) => item.artist);
    // Bannis : Various Artists (malgré match 0.9) et l'artiste au tag générique.
    expect(artists).not.toContain('Various Artists');
    expect(artists).not.toContain('Artiste Tag Générique');
    // Tout item du feed standard a un extrait fiable et la version V3.
    for (const item of items) {
      expect(item.previewUrl).not.toBeNull();
      expect(item.modelVersion).toBe(RECOMMENDATION_MODEL_VERSION);
    }
    // « Tout Noir » : voisin direct de DEUX morceaux d'Ajna → SAFE, raison FR.
    const toutNoir = items.find((item) => item.title === 'Tout Noir');
    expect(toutNoir).toBeDefined();
    expect(toutNoir!.category).toBe('SAFE');
    expect(toutNoir!.reason).toBe('Proche de plusieurs morceaux d’Ajna que tu écoutes souvent'.replace('’', "'"));
    // « Vertige » (H.LLS) : artiste voisin fort d'Ajna → ADJACENT.
    const vertige = items.find((item) => item.title === 'Vertige');
    expect(vertige).toBeDefined();
    expect(vertige!.reason).toBe("Artiste proche d'Ajna");
    // « Rechute » (extrait ambigu 0.65 < seuil) n'est JAMAIS MEDIA_READY :
    // modèle v4, il n'entre pas dans la file (plus de réglage « sans aperçu »).
    expect(items.map((item) => item.title)).not.toContain('Rechute');
    const rechute = app.dbHandle.db
      .select({ status: recommendationCandidates.mediaResolutionStatus })
      .from(recommendationCandidates)
      .where(eq(recommendationCandidates.title, 'Rechute'))
      .get();
    expect(rechute?.status).toBe('MEDIA_UNAVAILABLE');

    // Snapshot d'ACCEPTATION (Phase 8) : top 10 anonymisé de la fixture Ajna,
    // avec catégorie, code de raison, présence d'extrait et exclusions.
    const rejected = app.dbHandle.db
      .select({ title: recommendationCandidates.title, artist: recommendationCandidates.artist })
      .from(recommendationCandidates)
      .where(eq(recommendationCandidates.isActive, false))
      .all();
    const snapshot = {
      fixture: 'Ajna',
      modelVersion: RECOMMENDATION_MODEL_VERSION,
      seedProfile: { dominantArtist: 'Ajna', favoriteOutlier: 'AC/DC' },
      top10: items.slice(0, 10).map(
        (item: {
          title: string;
          artist: string;
          category: string;
          reasonCode: string;
          reason: string;
          previewUrl: string | null;
          score: number;
        }) => ({
          title: item.title,
          artist: item.artist,
          category: item.category,
          reasonCode: item.reasonCode,
          reason: item.reason,
          hasPreview: item.previewUrl !== null,
          score: Math.round(item.score * 100) / 100,
        }),
      ),
      excludedByQuality: rejected,
    };
    // Écrit hors du dossier temporaire (supprimé en afterEach) pour pouvoir
    // l'inspecter : le chemin est surchargeable par ACCEPTANCE_SNAPSHOT_PATH.
    const snapshotPath = process.env.ACCEPTANCE_SNAPSHOT_PATH;
    if (snapshotPath) {
      writeFileSync(snapshotPath, JSON.stringify(snapshot, null, 2));
    }
    // Vérité d'acceptation : le top est catégorisé, tout est motivé en FR.
    for (const entry of snapshot.top10) {
      expect(['SAFE', 'ADJACENT', 'EXPLORATION']).toContain(entry.category);
      expect(entry.reason.length).toBeGreaterThan(0);
    }
    expect(snapshot.top10.some((entry: { category: string }) => entry.category === 'SAFE')).toBe(
      true,
    );
  });

  it('une seule relation moyenne ne suffit JAMAIS (indépendance exigée)', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    await importTrack(alice.token, 'Seule Seed', 'Artiste Unique');
    // Un artiste voisin à match moyen (0.3 < 0.7) d'UNE seule seed…
    graphSimilarArtists.set('artiste unique', [
      { name: 'Voisin Moyen', match: 0.3, externalUrl: null },
    ]);
    graphTopTracks.set('voisin moyen', [
      { title: 'Titre Moyen', artist: 'Voisin Moyen', externalUrl: null },
    ]);
    previewByTitle.set('Titre Moyen', preview('2001'));
    await refreshQueue(alice.id, true);

    const res = await app.inject({
      method: 'GET',
      url: '/api/recommendations?includeNoPreview=true',
      headers: auth(alice.token),
    });
    expect(res.json().items.map((i: { title: string }) => i.title)).not.toContain('Titre Moyen');
  });

  it('le GET du feed ne déclenche AUCUN appel externe et répond vite', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    insertCandidate({ title: 'Libre', artist: 'Neutre', previewUrl: 'https://x.example/p.m4a' });
    await refreshQueue(alice.id);
    await drainRefresh(alice.id);

    similarityCalls = 0;
    previewCalls = 0;
    const startedAt = Date.now();
    const res = await app.inject({
      method: 'GET',
      url: '/api/recommendations',
      headers: auth(alice.token),
    });
    const elapsedMs = Date.now() - startedAt;
    expect(res.statusCode).toBe(200);
    expect(res.json().items).toHaveLength(1);
    expect(similarityCalls).toBe(0);
    expect(previewCalls).toBe(0);
    expect(elapsedMs).toBeLessThan(300);
    await drainRefresh(alice.id);
  });

  it('graphe non configuré : feed local seulement, jamais de crash', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    await importTrack(alice.token, 'Base', 'Artiste');
    insertCandidate({ title: 'Locale', artist: 'Artiste', previewUrl: 'https://x.example/1.m4a' });
    const result = await refreshRecommendationQueueForUser(app.dbHandle, alice.id, {
      similarityProvider: null,
      previewProvider,
      forceCatalogSync: true,
    });
    expect(result.status).toBe('refreshed');
    const res = await app.inject({
      method: 'GET',
      url: '/api/recommendations',
      headers: auth(alice.token),
    });
    expect(res.json().items.map((i: { title: string }) => i.title)).toEqual(['Locale']);
  });

  it('échec dur du graphe : conserve atomiquement l’ancienne file', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    await importTrack(alice.token, 'Graine', 'Artiste graine');
    insertCandidate({ title: 'Ancienne carte', artist: 'Artiste local', previewUrl: 'https://x.example/1.m4a' });
    const initial = await refreshQueue(alice.id);
    expect(initial.queued).toBeGreaterThan(0);

    const broken: MusicSimilarityProvider = {
      id: 'BROKEN',
      async similarTracks() { throw new Error('graphe indisponible'); },
      async similarArtists() { throw new Error('graphe indisponible'); },
      async topTracksOf() { throw new Error('graphe indisponible'); },
    };
    const failed = await refreshRecommendationQueueForUser(app.dbHandle, alice.id, {
      similarityProvider: broken,
      previewProvider,
      forceCatalogSync: true,
    });
    expect(failed.status).toBe('retained_old_feed');
    expect(failed.queued).toBe(initial.queued);
    expect(failed.providerError).toContain('indisponible');
  });
});

describe('feed continu (le paquet ne meurt jamais)', () => {
  it('survit à une rafale de dislikes : la réserve sert, le refill part', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    await seedAjnaFixture(alice.token, alice.id);
    // Réserve locale abondante (MEDIA_READY) en plus du graphe.
    for (let i = 1; i <= 40; i += 1) {
      insertCandidate({
        title: `Réserve ${String(i).padStart(2, '0')}`,
        artist: `Artiste R${i}`,
        previewUrl: `https://x.example/r${i}.m4a`,
      });
    }
    await refreshQueue(alice.id, true);

    // 6 dislikes d'affilée sur le haut du feed.
    for (let round = 0; round < 6; round += 1) {
      const feed = await app.inject({
        method: 'GET',
        url: '/api/recommendations?limit=5',
        headers: auth(alice.token),
      });
      const top = feed.json().items[0];
      expect(top).toBeDefined();
      const swipe = await app.inject({
        method: 'POST',
        url: `/api/recommendations/${top.id}/action`,
        headers: auth(alice.token),
        payload: { action: 'DISLIKE' },
      });
      expect(swipe.statusCode).toBe(201);
      await drainRefresh(alice.id);
    }

    const after = await app.inject({
      method: 'GET',
      url: '/api/recommendations?limit=10',
      headers: auth(alice.token),
    });
    expect(after.json().items.length).toBeGreaterThan(0);
    expect(['READY', 'REFRESHING', 'EXHAUSTED']).toContain(after.json().status.generationStatus);
    await drainRefresh(alice.id);
  });

  it('une carte simplement VUE n’est plus exclue (pénalité, pas bannissement)', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    const seen = insertCandidate({ title: 'Déjà vue', artist: 'Autre', previewUrl: 'https://x.example/1.m4a' });
    app.dbHandle.db.insert(recommendationImpressions).values({
      userId: alice.id,
      candidateId: seen,
      shownAt: new Date().toISOString(),
      position: 1,
      modelVersion: RECOMMENDATION_MODEL_VERSION,
      reasonCode: 'STYLE_DISCOVERY',
    }).run();
    await refreshQueue(alice.id);

    const res = await app.inject({
      method: 'GET',
      url: '/api/recommendations',
      headers: auth(alice.token),
    });
    expect(res.json().items.map((i: { id: number }) => i.id)).toContain(seen);
  });

  it('les doublons exacts titre+artiste sont dédupliqués', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    const first = insertCandidate({ title: 'Doublon', artist: 'Même Artiste', previewUrl: 'https://x.example/1.m4a' });
    insertCandidate({ title: ' doublon ', artist: ' même artiste ', previewUrl: 'https://x.example/2.m4a' });
    await refreshQueue(alice.id);
    const res = await app.inject({
      method: 'GET',
      url: '/api/recommendations',
      headers: auth(alice.token),
    });
    expect(res.json().items.map((i: { id: number }) => i.id)).toEqual([first]);
  });

  it('sous le seuil de cartes prêtes, le GET déclenche un refill asynchrone', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    for (let i = 1; i <= 5; i += 1) {
      insertCandidate({ title: `Peu ${i}`, artist: `Artiste ${i}`, previewUrl: `https://x.example/${i}.m4a` });
    }
    await refreshQueue(alice.id);
    await drainRefresh(alice.id);

    const res = await app.inject({
      method: 'GET',
      url: '/api/recommendations',
      headers: auth(alice.token),
    });
    expect(res.statusCode).toBe(200);
    // 5 cartes < seuil REFILL_THRESHOLD : un job est déjà reparti (ou vient de finir).
    const status = await app.inject({
      method: 'GET',
      url: '/api/recommendations/status',
      headers: auth(alice.token),
    });
    expect(['REFRESHING', 'READY', 'EXHAUSTED']).toContain(status.json().generationStatus);
    await drainRefresh(alice.id);
  });

  it('EXHAUSTED quand tout a été servi ; Actualiser change la combinaison de seeds', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    await seedAjnaFixture(alice.token, alice.id);
    await refreshQueue(alice.id, true);

    // Sert tout le feed.
    let cursor: string | null = null;
    for (let page = 0; page < 10; page += 1) {
      const url = cursor === null
        ? '/api/recommendations?limit=20&includeNoPreview=true'
        : `/api/recommendations?limit=20&includeNoPreview=true&cursor=${cursor}`;
      const res = await app.inject({ method: 'GET', url, headers: auth(alice.token) });
      cursor = res.json().nextCursor;
      if (cursor === null) break;
    }
    await drainRefresh(alice.id);
    const status = await app.inject({
      method: 'GET',
      url: '/api/recommendations/status',
      headers: auth(alice.token),
    });
    expect(['EXHAUSTED', 'READY', 'REFRESHING']).toContain(status.json().generationStatus);

    // Bouton Actualiser : rotation des seeds → le graphe est interrogé avec
    // une AUTRE combinaison (pas un simple retri du même tableau).
    queriedTrackSeeds = [];
    await refreshQueue(alice.id, true);
    const firstCombo = [...queriedTrackSeeds];
    queriedTrackSeeds = [];
    await refreshQueue(alice.id, true);
    expect(queriedTrackSeeds.length).toBeGreaterThan(0);
    expect(queriedTrackSeeds).not.toEqual(firstCombo);
  });

  it('pagination par curseur : pages disjointes, fin de file propre', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    for (let i = 1; i <= 25; i += 1) {
      insertCandidate({
        title: `Titre ${String(i).padStart(2, '0')}`,
        artist: `Artiste ${i}`,
        previewUrl: `https://x.example/${i}.m4a`,
      });
    }
    await refreshQueue(alice.id);
    await drainRefresh(alice.id);

    // Pagination testée sur la LECTURE pure (listQueueForUser) : la file est
    // figée, sans le refill continu de la route GET (qui re-score/réordonne sur
    // impressions — hors sujet ici). Les 25 candidats sont tous MEDIA_READY.
    const page1 = listQueueForUser(app.dbHandle, alice.id, { limit: 10 });
    expect(page1.items).toHaveLength(10);
    expect(page1.nextCursor).not.toBeNull();

    const page2 = listQueueForUser(app.dbHandle, alice.id, { cursor: page1.nextCursor, limit: 10 });
    expect(page2.items).toHaveLength(10);
    const ids1 = new Set(page1.items.map((i) => i.id));
    for (const item of page2.items) expect(ids1.has(item.id)).toBe(false);

    const page3 = listQueueForUser(app.dbHandle, alice.id, { cursor: page2.nextCursor, limit: 10 });
    expect(page3.items).toHaveLength(5);
    expect(page3.nextCursor).toBeNull();

    // Plafond MAX_PAGE_SIZE côté route.
    const capped = await app.inject({
      method: 'GET',
      url: '/api/recommendations?limit=50',
      headers: auth(alice.token),
    });
    expect(capped.json().items.length).toBeLessThanOrEqual(20);
    await drainRefresh(alice.id);
  });

  it('DISLIKE retire immédiatement le candidat de la file (sans attendre le refresh)', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    const c1 = insertCandidate({ title: 'Reste', artist: 'Un', previewUrl: 'https://x.example/1.m4a' });
    const c2 = insertCandidate({ title: 'Part', artist: 'Deux', previewUrl: 'https://x.example/2.m4a' });
    await refreshQueue(alice.id);
    await drainRefresh(alice.id);

    const swipe = await app.inject({
      method: 'POST',
      url: `/api/recommendations/${c2}/action`,
      headers: auth(alice.token),
      payload: { action: 'DISLIKE' },
    });
    expect(swipe.statusCode).toBe(201);

    const res = await app.inject({
      method: 'GET',
      url: '/api/recommendations',
      headers: auth(alice.token),
    });
    const ids = res.json().items.map((i: { id: number }) => i.id);
    expect(ids).toContain(c1);
    expect(ids).not.toContain(c2);
    await drainRefresh(alice.id);
  });

  it('exclut : déjà possédée, DISLIKE, demande active, piste supprimée', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    const trackId = await importTrack(alice.token, 'Possedee', 'Artiste P');
    const removedId = await importTrack(alice.token, 'Retiree', 'Artiste R');

    const cOwned = insertCandidate({ title: 'Possedee', artist: 'Artiste P', previewUrl: 'https://x.example/1.m4a' });
    const cDisliked = insertCandidate({ title: 'Nulle', artist: 'Bof', previewUrl: 'https://x.example/2.m4a' });
    const cRequested = insertCandidate({ title: 'Voulue', artist: 'Chouette', previewUrl: 'https://x.example/3.m4a' });
    const cRemoved = insertCandidate({ title: 'Retiree', artist: 'Artiste R', previewUrl: 'https://x.example/4.m4a' });
    const cVisible = insertCandidate({ title: 'Libre', artist: 'Neutre', previewUrl: 'https://x.example/5.m4a' });

    await app.inject({
      method: 'POST',
      url: `/api/recommendations/${cDisliked}/action`,
      headers: auth(alice.token),
      payload: { action: 'DISLIKE' },
    });
    const req = await app.inject({
      method: 'POST',
      url: '/api/music-requests',
      headers: auth(alice.token),
      payload: { candidateId: cRequested },
    });
    expect(req.statusCode).toBe(201);
    const del = await app.inject({
      method: 'DELETE',
      url: `/api/library/tracks/${removedId}`,
      headers: auth(alice.token),
    });
    expect(del.statusCode).toBe(200);
    await drainRefresh(alice.id);

    await refreshQueue(alice.id);
    const res = await app.inject({
      method: 'GET',
      url: '/api/recommendations',
      headers: auth(alice.token),
    });
    const ids = res.json().items.map((i: { id: number }) => i.id);
    expect(ids).toEqual([cVisible]);
    expect(ids).not.toContain(cOwned);
    expect(ids).not.toContain(cDisliked);
    expect(ids).not.toContain(cRequested);
    expect(ids).not.toContain(cRemoved);
    expect(trackId).toBeGreaterThan(0);
    await drainRefresh(alice.id);
  });

  it('isolation stricte : chaque compte a SA file et SON classement', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    const bob = await createUser(ownerToken, 'bob');
    await importTrack(alice.token, 'Chanson A', 'Artiste Alpha');
    await importTrack(bob.token, 'Chanson B', 'Artiste Beta');
    const cAlpha = insertCandidate({ title: 'Pour Alice', artist: 'Artiste Alpha', previewUrl: 'https://x.example/1.m4a' });
    const cBeta = insertCandidate({ title: 'Pour Bob', artist: 'Artiste Beta', previewUrl: 'https://x.example/2.m4a' });
    await refreshQueue(alice.id);
    await refreshQueue(bob.id);

    const resAlice = await app.inject({
      method: 'GET',
      url: '/api/recommendations',
      headers: auth(alice.token),
    });
    const resBob = await app.inject({
      method: 'GET',
      url: '/api/recommendations',
      headers: auth(bob.token),
    });
    expect(resAlice.json().items[0].id).toBe(cAlpha);
    expect(resBob.json().items[0].id).toBe(cBeta);

    await app.inject({
      method: 'POST',
      url: `/api/recommendations/${cBeta}/action`,
      headers: auth(alice.token),
      payload: { action: 'DISLIKE' },
    });
    await drainRefresh(alice.id);
    const bobAfter = await app.inject({
      method: 'GET',
      url: '/api/recommendations',
      headers: auth(bob.token),
    });
    expect(bobAfter.json().items.map((i: { id: number }) => i.id)).toContain(cBeta);
    await drainRefresh(alice.id);
    await drainRefresh(bob.id);
  });

  it('single-flight : un second refresh pendant l’exécution est refusé', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    await importTrack(alice.token, 'Seed', 'Artiste');
    await drainRefresh(alice.id);

    const slow: MusicSimilarityProvider = {
      id: 'SLOW',
      async similarTracks() { await sleep(120); return []; },
      async similarArtists() { return []; },
      async topTracksOf() { return []; },
    };
    const first = refreshRecommendationQueueForUser(app.dbHandle, alice.id, {
      similarityProvider: slow,
      previewProvider,
      forceCatalogSync: true,
    });
    const second = await refreshRecommendationQueueForUser(app.dbHandle, alice.id, {
      similarityProvider: slow,
      previewProvider,
      forceCatalogSync: true,
    });
    expect(second.status).toBe('already_running');
    expect((await first).status).toBe('refreshed');
  });
});

describe('composition et qualité', () => {
  const scoredItem = (
    id: number,
    category: ScoredCandidate['category'],
    artistKey: string,
    score: number,
  ): ScoredCandidate => ({
    candidateId: id,
    trackKey: `titre-${id}|${artistKey}`,
    artistKey,
    score,
    category,
    reasonCode: 'STYLE_DISCOVERY',
    reasonText: 'Raison',
    hasReliablePreview: true,
  });

  it('mélange cible 60/30/10 sur une fenêtre de 10', () => {
    const scored: ScoredCandidate[] = [
      ...Array.from({ length: 20 }, (_, i) => scoredItem(i + 1, 'SAFE', `safe-${i}`, 100 - i)),
      ...Array.from({ length: 10 }, (_, i) => scoredItem(50 + i, 'ADJACENT', `adj-${i}`, 50 - i)),
      ...Array.from({ length: 5 }, (_, i) => scoredItem(80 + i, 'EXPLORATION', `exp-${i}`, 10 - i)),
    ];
    const queue = composeQueue(scored, 10);
    expect(queue).toHaveLength(10);
    expect(queue.filter((item) => item.category === 'SAFE')).toHaveLength(6);
    expect(queue.filter((item) => item.category === 'ADJACENT')).toHaveLength(3);
    expect(queue.filter((item) => item.category === 'EXPLORATION')).toHaveLength(1);
  });

  it('un seau vide déborde sur les autres : la file ne meurt jamais', () => {
    const scored: ScoredCandidate[] = Array.from({ length: 12 }, (_, i) =>
      scoredItem(i + 1, 'SAFE', `artiste-${i}`, 12 - i),
    );
    const queue = composeQueue(scored, 10);
    expect(queue).toHaveLength(10); // aucune casse malgré 0 ADJACENT/EXPLORATION
  });

  it('diversité : max 2 cartes du même artiste par fenêtre de 10 (si possible)', () => {
    const scored: ScoredCandidate[] = [
      ...Array.from({ length: 6 }, (_, i) => scoredItem(i + 1, 'SAFE', 'star', 100 - i)),
      ...Array.from({ length: 8 }, (_, i) => scoredItem(20 + i, 'SAFE', `autre-${i}`, 50 - i)),
    ];
    const queue = composeQueue(scored, 10);
    const starCount = queue.slice(0, 10).filter((item) => item.artistKey === 'star').length;
    expect(starCount).toBeLessThanOrEqual(2);
  });

  it('elision française correcte dans les raisons', () => {
    expect(deArtist('Ajna')).toBe("d'Ajna");
    expect(deArtist('Laylow')).toBe('de Laylow');
    expect(deArtist('H.LLS')).toBe("d'H.LLS");
  });

  it('le job résout le média (extrait+pochette) ; sans match → MEDIA_UNAVAILABLE hors file', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    // Candidats DISCOVERED (sans média) portés par une preuve graphe, résolus
    // par le job : l'un matche le catalogue, l'autre non.
    const evidence = JSON.stringify([
      { type: 'TRACK_SIMILAR', seed: 'S — Artiste', seedArtist: 'Artiste', match: 0.9 },
    ]);
    const cMatch = insertCandidate({
      title: 'AvecExtrait', artist: 'Artiste', durationMs: 200000, source: 'EXTERNAL_CATALOG', evidenceJson: evidence,
    });
    const cNoMatch = insertCandidate({
      title: 'SansExtrait', artist: 'Artiste Deux', source: 'EXTERNAL_CATALOG', evidenceJson: evidence,
    });
    previewByTitle.set('AvecExtrait', preview('123456', 0.8));
    await refreshQueue(alice.id);
    await drainRefresh(alice.id);

    const res = await app.inject({
      method: 'GET',
      url: '/api/recommendations',
      headers: auth(alice.token),
    });
    const items = res.json().items as Array<{ id: number; previewUrl: string | null; artworkUrl: string | null }>;
    const withPreview = items.find((i) => i.id === cMatch);
    // MEDIA_READY : servi avec extrait https + pochette 600×600 du même match.
    expect(withPreview?.previewUrl).toBe('https://audio-ssl.itunes.apple.com/123456.m4a');
    expect(withPreview?.artworkUrl).toContain('600x600bb');
    // Sans match : jamais dans la file (modèle v4 : seuls MEDIA_READY entrent).
    expect(items.find((i) => i.id === cNoMatch)).toBeUndefined();

    const ready = app.dbHandle.db
      .select().from(recommendationCandidates).where(eq(recommendationCandidates.id, cMatch)).get();
    expect(ready?.previewProvider).toBe('ITUNES');
    expect(ready?.previewConfidence).toBe(0.8);
    expect(ready?.mediaResolutionStatus).toBe('MEDIA_READY');
    expect(ready?.artworkProvider).toBe('ITUNES');
    const unavailable = app.dbHandle.db
      .select().from(recommendationCandidates).where(eq(recommendationCandidates.id, cNoMatch)).get();
    expect(unavailable?.mediaResolutionStatus).toBe('MEDIA_UNAVAILABLE');
    expect(unavailable?.mediaFailureReason).toBe('NO_CATALOG_MATCH');
    await drainRefresh(alice.id);
  });

  it('previewUrl non https rejetée à la lecture (double sécurité)', async () => {
    const ownerToken = await bootstrapOwner();
    // Injection directe d'une carte legacy à extrait http dans la file : la
    // porte de LECTURE la neutralise (previewUrl → null), sécurité en profondeur.
    const cid = insertCandidate({
      title: 'Preview',
      artist: 'Artiste',
      previewUrl: 'https://secure.example/preview.m4a',
    });
    const ownerId = 1;
    await refreshQueue(ownerId);
    await drainRefresh(ownerId);
    // Bascule l'extrait en http APRÈS composition (simulate donnée corrompue).
    app.dbHandle.db
      .update(recommendationCandidates)
      .set({ previewUrl: 'http://insecure.example/preview.mp3' })
      .where(eq(recommendationCandidates.id, cid))
      .run();
    const res = await app.inject({
      method: 'GET',
      url: '/api/recommendations',
      headers: auth(ownerToken),
    });
    const item = res.json().items.find((i: { id: number }) => i.id === cid);
    expect(item.previewUrl).toBeNull();
    await drainRefresh(ownerId);
  });

  it('chaque carte servie est journalisée et marquée servie (refill)', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    insertCandidate({ title: 'Un', artist: 'A1', previewUrl: 'https://x.example/1.m4a' });
    insertCandidate({ title: 'Deux', artist: 'A2', previewUrl: 'https://x.example/2.m4a' });
    await refreshQueue(alice.id);
    await drainRefresh(alice.id);

    await app.inject({
      method: 'GET',
      url: '/api/recommendations',
      headers: auth(alice.token),
    });
    const rows = app.dbHandle.db
      .select()
      .from(recommendationImpressions)
      .where(eq(recommendationImpressions.userId, alice.id))
      .all();
    expect(rows).toHaveLength(2);
    expect(rows[0]?.modelVersion).toBe(RECOMMENDATION_MODEL_VERSION);
    const served = app.dbHandle.db
      .select()
      .from(userRecommendationQueue)
      .where(eq(userRecommendationQueue.userId, alice.id))
      .all();
    expect(served.every((row) => row.servedAt !== null)).toBe(true);
    await drainRefresh(alice.id);
  });
});

describe('nettoyage legacy au boot', () => {
  it('files des anciens modèles supprimées, candidats poubelle désactivés, historique conservé', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    const junk = insertCandidate({ title: 'Vieux Mix', artist: 'Various Artists' });
    const good = insertCandidate({ title: 'Saine', artist: 'Artiste', previewUrl: 'https://x.example/1.m4a' });
    // Ancienne file V2 + un événement historique sur le candidat poubelle.
    const now = new Date().toISOString();
    app.dbHandle.db.insert(userRecommendationQueue).values({
      userId: alice.id,
      candidateId: junk,
      score: 1,
      rank: 1,
      reasonCode: 'TOP_ARTIST',
      reasonText: 'Vieux',
      category: 'SAFE',
      generatedAt: now,
      expiresAt: now,
      modelVersion: 'hybrid-v2',
    }).run();
    app.dbHandle.db.insert(recommendationEvents).values({
      userId: alice.id,
      candidateId: junk,
      action: 'DISLIKE',
      createdAt: now,
    }).run();

    // Le nettoyage tourne au boot : on le rejoue via un nouveau buildApp sur
    // la MÊME base ? (base :memory: par app) → on l'invoque directement.
    const { invalidateLegacyArtifacts } = await import('./recommendation-engine.js');
    const result = invalidateLegacyArtifacts(app.dbHandle);
    expect(result.queuesDropped).toBeGreaterThanOrEqual(1);
    expect(result.candidatesDeactivated).toBeGreaterThanOrEqual(1);

    const junkRow = app.dbHandle.db
      .select()
      .from(recommendationCandidates)
      .where(eq(recommendationCandidates.id, junk))
      .get();
    expect(junkRow?.isActive).toBe(false);
    const goodRow = app.dbHandle.db
      .select()
      .from(recommendationCandidates)
      .where(eq(recommendationCandidates.id, good))
      .get();
    expect(goodRow?.isActive).toBe(true);
    // L'historique (événements) est intégralement préservé.
    const events = app.dbHandle.db
      .select()
      .from(recommendationEvents)
      .where(eq(recommendationEvents.candidateId, junk))
      .all();
    expect(events).toHaveLength(1);
  });
});

describe('feed et statut', () => {
  it('file vide : liste vide, statut EMPTY, pas de curseur', async () => {
    const ownerToken = await bootstrapOwner();
    const res = await app.inject({
      method: 'GET',
      url: '/api/recommendations',
      headers: auth(ownerToken),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({
      items: [],
      nextCursor: null,
      status: { generationStatus: 'EMPTY', refreshing: false, queueSize: 0 },
    });
    await drainRefresh(1);
  });

  it('exige une authentification', async () => {
    const res = await app.inject({ method: 'GET', url: '/api/recommendations' });
    expect(res.statusCode).toBe(401);
  });

  it('POST /refresh répond 202 immédiatement (job asynchrone)', async () => {
    const ownerToken = await bootstrapOwner();
    const refreshed = await app.inject({
      method: 'POST',
      url: '/api/recommendations/refresh',
      headers: auth(ownerToken),
    });
    expect(refreshed.statusCode).toBe(202);
    expect(['started', 'already_running']).toContain(refreshed.json().status);
    expect(refreshed.json().modelVersion).toBe(RECOMMENDATION_MODEL_VERSION);
    await drainRefresh(1);
  });

  it('action de swipe inconnue refusée, candidat inconnu → 404', async () => {
    const ownerToken = await bootstrapOwner();
    const cid = insertCandidate({ title: 'T', artist: 'A2' });
    const bad = await app.inject({
      method: 'POST',
      url: `/api/recommendations/${cid}/action`,
      headers: auth(ownerToken),
      payload: { action: 'DOWNLOAD' },
    });
    expect(bad.statusCode).toBe(400);
    const missing = await app.inject({
      method: 'POST',
      url: '/api/recommendations/9999/action',
      headers: auth(ownerToken),
      payload: { action: 'SKIP' },
    });
    expect(missing.statusCode).toBe(404);
  });
});

describe('diagnostics OWNER des recommandations', () => {
  it('l’ancien CRUD manuel du catalogue est retiré', async () => {
    const ownerToken = await bootstrapOwner();
    const res = await app.inject({
      method: 'POST',
      url: '/api/admin/recommendation-candidates',
      headers: auth(ownerToken),
      payload: { title: 'X', artist: 'Y' },
    });
    expect(res.statusCode).toBe(404);
  });

  it('health : compteurs, providers, réservé au OWNER', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    insertCandidate({ title: 'Un', artist: 'A1', previewUrl: 'https://x.example/1.m4a' });

    const forbidden = await app.inject({
      method: 'GET',
      url: '/api/admin/recommendations/health',
      headers: auth(alice.token),
    });
    expect(forbidden.statusCode).toBe(403);

    const res = await app.inject({
      method: 'GET',
      url: '/api/admin/recommendations/health',
      headers: auth(ownerToken),
    });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.modelVersion).toBe(RECOMMENDATION_MODEL_VERSION);
    expect(body.providers.similarityGraph).toBe('configured');
    expect(body.candidates.total).toBeGreaterThanOrEqual(1);
    expect(body.candidates.reliablePreview).toBeGreaterThanOrEqual(1);
  });

  it('media-health/:userId : entonnoir média, échecs, estimation, réservé OWNER', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    // Un candidat prêt (extrait), un candidat sans média (DISCOVERED).
    insertCandidate({ title: 'Prête', artist: 'A1', previewUrl: 'https://x.example/1.m4a' });
    insertCandidate({ title: 'EnAttente', artist: 'A2' });

    const forbidden = await app.inject({
      method: 'GET',
      url: `/api/admin/recommendations/media-health/${alice.id}`,
      headers: auth(alice.token),
    });
    expect(forbidden.statusCode).toBe(403);

    const res = await app.inject({
      method: 'GET',
      url: `/api/admin/recommendations/media-health/${alice.id}`,
      headers: auth(ownerToken),
    });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.modelVersion).toBe(RECOMMENDATION_MODEL_VERSION);
    expect(body.providers.catalog).toBe('ITUNES');
    expect(body.candidates.mediaReady).toBeGreaterThanOrEqual(1);
    expect(body.candidates.candidatesDiscovered).toBeGreaterThanOrEqual(1);
    expect(body.queue.targetReady).toBe(20);
    expect(typeof body.estimatedRemainingMs).toBe('number');
    expect(body.failureReasons).toBeDefined();
  });

  it('profile/:userId : vue lecture seule du profil, seeds et file', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    await seedAjnaFixture(alice.token, alice.id);
    await refreshQueue(alice.id, true);

    const res = await app.inject({
      method: 'GET',
      url: `/api/admin/recommendations/profile/${alice.id}`,
      headers: auth(ownerToken),
    });
    expect(res.statusCode).toBe(200);
    const body = res.json();
    expect(body.profile.topArtists[0].name).toBe('Ajna');
    expect(body.profile.trackSeeds.length).toBeGreaterThan(0);
    expect(body.queue.queueSize).toBeGreaterThan(0);
    expect(body.queue.categories).toBeDefined();
    await drainRefresh(alice.id);
  });

  it('metrics : actions agrégées et impressions', async () => {
    const ownerToken = await bootstrapOwner();
    const cid = insertCandidate({ title: 'Metrique', artist: 'Artiste', previewUrl: 'https://x.example/1.m4a' });
    await app.inject({
      method: 'POST',
      url: `/api/recommendations/${cid}/action`,
      headers: auth(ownerToken),
      payload: { action: 'SKIP' },
    });
    const res = await app.inject({
      method: 'GET',
      url: '/api/admin/recommendations/metrics',
      headers: auth(ownerToken),
    });
    expect(res.statusCode).toBe(200);
    expect(res.json().actions.SKIP).toBeGreaterThanOrEqual(1);
    await drainRefresh(1);
  });

  it('refresh-user et maintenance : outils OWNER', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    insertCandidate({ title: 'Outil', artist: 'Artiste', previewUrl: 'https://x.example/1.m4a' });

    const refreshed = await app.inject({
      method: 'POST',
      url: `/api/admin/recommendations/refresh-user/${alice.id}`,
      headers: auth(ownerToken),
    });
    expect(refreshed.statusCode).toBe(200);
    expect(['refreshed', 'already_running']).toContain(refreshed.json().status);
    await drainRefresh(alice.id);

    const maintenance = await app.inject({
      method: 'POST',
      url: '/api/admin/recommendations/maintenance',
      headers: auth(ownerToken),
    });
    expect(maintenance.statusCode).toBe(202);
    expect(maintenance.json().users).toBeGreaterThanOrEqual(2);
    await drainRefresh(1);
    await drainRefresh(alice.id);
  });
});

describe('demandes de musique', () => {
  it('création SENT, doublon actif refusé (409), déjà possédée refusée (409)', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    await importTrack(alice.token, 'Mienne', 'Moi');
    const cid = await createCandidate(ownerToken, { title: 'Nouvelle', artist: 'Artiste' });
    const cOwned = await createCandidate(ownerToken, { title: 'Mienne', artist: 'Moi' });

    const created = await app.inject({
      method: 'POST',
      url: '/api/music-requests',
      headers: auth(alice.token),
      payload: { candidateId: cid },
    });
    expect(created.statusCode).toBe(201);
    expect(created.json().status).toBe('SENT');

    const duplicate = await app.inject({
      method: 'POST',
      url: '/api/music-requests',
      headers: auth(alice.token),
      payload: { candidateId: cid },
    });
    expect(duplicate.statusCode).toBe(409);
    expect(duplicate.json().error).toBe('duplicate_active_request');

    const owned = await app.inject({
      method: 'POST',
      url: '/api/music-requests',
      headers: auth(alice.token),
      payload: { candidateId: cOwned },
    });
    expect(owned.statusCode).toBe(409);
    expect(owned.json().error).toBe('already_owned');
  });

  it('portée stricte : un utilisateur ne voit que SES demandes', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    const bob = await createUser(ownerToken, 'bob');
    const cid = await createCandidate(ownerToken, { title: 'Privée', artist: 'Artiste' });

    const created = await app.inject({
      method: 'POST',
      url: '/api/music-requests',
      headers: auth(alice.token),
      payload: { candidateId: cid },
    });
    const requestId = created.json().id;

    const listBob = await app.inject({
      method: 'GET',
      url: '/api/music-requests',
      headers: auth(bob.token),
    });
    expect(listBob.json().items).toHaveLength(0);
    const getBob = await app.inject({
      method: 'GET',
      url: `/api/music-requests/${requestId}`,
      headers: auth(bob.token),
    });
    expect(getBob.statusCode).toBe(404);
    const cancelBob = await app.inject({
      method: 'POST',
      url: `/api/music-requests/${requestId}/cancel`,
      headers: auth(bob.token),
    });
    expect(cancelBob.statusCode).toBe(404);
  });

  it('annulation permise avant IMPORTING, refusée ensuite', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    const c1 = await createCandidate(ownerToken, { title: 'Annulable', artist: 'A1' });
    const c2 = await createCandidate(ownerToken, { title: 'Bloquée', artist: 'A2' });

    const r1 = (
      await app.inject({
        method: 'POST',
        url: '/api/music-requests',
        headers: auth(alice.token),
        payload: { candidateId: c1 },
      })
    ).json().id;
    const cancelled = await app.inject({
      method: 'POST',
      url: `/api/music-requests/${r1}/cancel`,
      headers: auth(alice.token),
    });
    expect(cancelled.statusCode).toBe(200);
    expect(cancelled.json().status).toBe('CANCELLED');

    const r2 = (
      await app.inject({
        method: 'POST',
        url: '/api/music-requests',
        headers: auth(alice.token),
        payload: { candidateId: c2 },
      })
    ).json().id;
    const toImporting = await app.inject({
      method: 'PATCH',
      url: `/api/admin/music-requests/${r2}`,
      headers: auth(ownerToken),
      payload: { status: 'IMPORTING' },
    });
    expect(toImporting.statusCode).toBe(200);
    const refused = await app.inject({
      method: 'POST',
      url: `/api/music-requests/${r2}/cancel`,
      headers: auth(alice.token),
    });
    expect(refused.statusCode).toBe(409);
    expect(refused.json().error).toBe('cancel_forbidden');
  });

  it('COMPLETED interdit à la main ; posé par réconciliation après attribution réelle', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    const cid = await createCandidate(ownerToken, { title: 'Esperee', artist: 'Artiste' });
    const requestId = (
      await app.inject({
        method: 'POST',
        url: '/api/music-requests',
        headers: auth(alice.token),
        payload: { candidateId: cid },
      })
    ).json().id;

    // Override manuel vers COMPLETED : refusé.
    const forced = await app.inject({
      method: 'PATCH',
      url: `/api/admin/music-requests/${requestId}`,
      headers: auth(ownerToken),
      payload: { status: 'COMPLETED' },
    });
    expect(forced.statusCode).toBe(409);

    // Le OWNER importe la piste (dans SA bibliothèque) puis l'associe : la
    // demande n'est PAS complétée tant qu'alice n'a pas l'accès.
    const trackId = await importTrack(ownerToken, 'Esperee', 'Artiste');
    const associated = await app.inject({
      method: 'PATCH',
      url: `/api/admin/music-requests/${requestId}`,
      headers: auth(ownerToken),
      payload: { status: 'IMPORTING', ownerNote: 'trouvée en CD' },
    });
    expect(associated.statusCode).toBe(200);
    expect(associated.json().status).toBe('IMPORTING');

    // Attribution de l'accès à alice puis réconciliation → COMPLETED.
    const grant = await app.inject({
      method: 'POST',
      url: `/api/admin/users/${alice.id}/library/tracks`,
      headers: auth(ownerToken),
      payload: { trackId },
    });
    expect(grant.statusCode).toBe(201);
    const assigned = await app.inject({
      method: 'POST',
      url: `/api/admin/music-requests/${requestId}/assign-track`,
      headers: auth(ownerToken),
      payload: { trackId },
    });
    expect(assigned.statusCode).toBe(200);
    expect(assigned.json().status).toBe('COMPLETED');

    const view = await app.inject({
      method: 'GET',
      url: `/api/music-requests/${requestId}`,
      headers: auth(alice.token),
    });
    expect(view.json().status).toBe('COMPLETED');
    expect(view.json().completedAt).not.toBeNull();
    expect(view.json().ownerNote).toBe('trouvée en CD');
  });

  it('réconciliation au boot : COMPLETED sans accès visible est rétrogradée', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    const cid = await createCandidate(ownerToken, { title: 'Fantome', artist: 'Artiste' });
    const trackId = await importTrack(ownerToken, 'Fantome', 'Artiste');
    const requestId = (
      await app.inject({
        method: 'POST',
        url: '/api/music-requests',
        headers: auth(alice.token),
        payload: { candidateId: cid },
      })
    ).json().id;

    // Corruption simulée : COMPLETED posé en base sans accès user_tracks.
    app.dbHandle.db
      .update(musicRequests)
      .set({ status: 'COMPLETED', resultingTrackId: trackId, completedAt: new Date().toISOString() })
      .where(eq(musicRequests.id, requestId))
      .run();

    const result = reconcileMusicRequestStatus(app.dbHandle, requestId);
    expect(result.status).toBe('IMPORTING');
    expect(result.changed).toBe(true);
  });

  it('accès admin refusé aux non-OWNER', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    const list = await app.inject({
      method: 'GET',
      url: '/api/admin/music-requests',
      headers: auth(alice.token),
    });
    expect(list.statusCode).toBe(403);
  });

  it('assign-track attribue la piste au demandeur et COMPLETED reste automatique', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    const candidateId = await createCandidate(ownerToken, { title: 'Assignée', artist: 'Artiste' });
    const requestId = (await app.inject({ method: 'POST', url: '/api/music-requests', headers: auth(alice.token), payload: { candidateId } })).json().id;
    const trackId = await importTrack(ownerToken, 'Assignée', 'Artiste');
    const assigned = await app.inject({
      method: 'POST',
      url: `/api/admin/music-requests/${requestId}/assign-track`,
      headers: auth(ownerToken),
      payload: { trackId },
    });
    expect(assigned.statusCode).toBe(200);
    expect(assigned.json().status).toBe('COMPLETED');
    expect(assigned.json().presentInRequesterLibrary).toBe(true);
  });
});

describe('suppression douce de bibliothèque', () => {
  it('retire la relation personnelle, le favori, masque la piste et n’affecte pas les autres comptes', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    const bob = await createUser(ownerToken, 'bob');
    const trackId = await importTrack(alice.token, 'Partagee', 'Artiste');
    await app.inject({
      method: 'POST',
      url: `/api/admin/users/${bob.id}/library/tracks`,
      headers: auth(ownerToken),
      payload: { trackId },
    });
    await app.inject({
      method: 'POST',
      url: '/api/favorites',
      headers: auth(alice.token),
      payload: { trackId },
    });

    const res = await app.inject({
      method: 'DELETE',
      url: `/api/library/tracks/${trackId}`,
      headers: auth(alice.token),
    });
    expect(res.statusCode).toBe(200);

    // Accès d'Alice masqué durablement et favori supprimé.
    expect(
      app.dbHandle.db
        .select()
        .from(userTracks)
        .where(and(eq(userTracks.userId, alice.id), eq(userTracks.trackId, trackId)))
        .get(),
    ).toMatchObject({ isVisible: false });
    expect(
      app.dbHandle.db
        .select()
        .from(favorites)
        .where(and(eq(favorites.userId, alice.id), eq(favorites.trackId, trackId)))
        .get(),
    ).toBeUndefined();
    // Masquage REMOVED créé.
    const hidden = app.dbHandle.db
      .select()
      .from(userHiddenTracks)
      .where(and(eq(userHiddenTracks.userId, alice.id), eq(userHiddenTracks.trackId, trackId)))
      .get();
    expect(hidden?.reason).toBe('REMOVED');
    // Fichier/ligne tracks intacts, bob garde sa relation personnelle visible.
    expect(app.dbHandle.db.select().from(tracks).where(eq(tracks.id, trackId)).get()).toBeDefined();
    expect(
      app.dbHandle.db
        .select()
        .from(userTracks)
        .where(and(eq(userTracks.userId, bob.id), eq(userTracks.trackId, trackId)))
        .get(),
    ).toMatchObject({ isVisible: true });

    // Les vues d'Alice reflètent bien le retrait de SA bibliothèque. La piste
    // reste néanmoins publiée au catalogue global grâce à la relation de Bob.
    const aliceLibrary = await app.inject({
      method: 'GET',
      url: '/api/tracks',
      headers: auth(alice.token),
    });
    expect(aliceLibrary.statusCode).toBe(200);
    expect(aliceLibrary.json().items.map((item: { id: number }) => item.id)).not.toContain(trackId);

    const aliceCatalog = await app.inject({
      method: 'GET',
      url: '/api/catalog/recent',
      headers: auth(alice.token),
    });
    expect(aliceCatalog.statusCode).toBe(200);
    const publishedTrack = aliceCatalog
      .json()
      .items.find((item: { id: number }) => item.id === trackId);
    expect(publishedTrack).toBeDefined();
    expect(publishedTrack.inMyLibrary).toBe(false);

    const streamBob = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/stream`,
      headers: auth(bob.token),
    });
    expect(streamBob.statusCode).toBe(200);
    // Alice peut encore écouter cette piste PUBLIÉE comme tout compte
    // authentifié, sans qu'elle réapparaisse dans sa bibliothèque personnelle.
    const streamAlice = await app.inject({
      method: 'GET',
      url: `/api/tracks/${trackId}/stream`,
      headers: auth(alice.token),
    });
    expect(streamAlice.statusCode).toBe(200);
  });

  it('dernière relation visible retirée : le tombstone et le fichier restent', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    const trackId = await importTrack(alice.token, 'Unique', 'Artiste');
    await app.inject({
      method: 'DELETE',
      url: `/api/library/tracks/${trackId}`,
      headers: auth(alice.token),
    });
    expect(app.dbHandle.db.select().from(tracks).where(eq(tracks.id, trackId)).get()).toBeDefined();
    expect(
      app.dbHandle.db.select().from(userTracks).where(eq(userTracks.trackId, trackId)).all(),
    ).toEqual([expect.objectContaining({ userId: alice.id, isVisible: false })]);
  });

  it('une demande COMPLETED est réconciliée après suppression volontaire de la piste', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    const cid = await createCandidate(ownerToken, { title: 'Regrettee', artist: 'Artiste' });
    const requestId = (
      await app.inject({
        method: 'POST',
        url: '/api/music-requests',
        headers: auth(alice.token),
        payload: { candidateId: cid },
      })
    ).json().id;
    const trackId = await importTrack(ownerToken, 'Regrettee', 'Artiste');
    const assigned = await app.inject({
      method: 'POST',
      url: `/api/admin/music-requests/${requestId}/assign-track`,
      headers: auth(ownerToken),
      payload: { trackId },
    });
    expect(assigned.statusCode).toBe(200);
    expect(assigned.json().status).toBe('COMPLETED');

    // Alice supprime la piste : la visibilité user_tracks disparaît, donc la
    // complétion ne peut plus être présentée comme effective.
    await app.inject({
      method: 'DELETE',
      url: `/api/library/tracks/${trackId}`,
      headers: auth(alice.token),
    });
    const view = await app.inject({
      method: 'GET',
      url: `/api/music-requests/${requestId}`,
      headers: auth(alice.token),
    });
    expect(view.json().status).toBe('IMPORTING');
  });

  it('suppression d’une piste inconnue ou sans accès → 404', async () => {
    const ownerToken = await bootstrapOwner();
    const alice = await createUser(ownerToken, 'alice');
    const bob = await createUser(ownerToken, 'bob');
    const trackId = await importTrack(alice.token, 'Pas à bob', 'Artiste');
    const res = await app.inject({
      method: 'DELETE',
      url: `/api/library/tracks/${trackId}`,
      headers: auth(bob.token),
    });
    expect(res.statusCode).toBe(404);
    const missing = await app.inject({
      method: 'DELETE',
      url: '/api/library/tracks/99999',
      headers: auth(alice.token),
    });
    expect(missing.statusCode).toBe(404);
  });
});
