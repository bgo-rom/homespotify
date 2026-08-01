import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { FastifyInstance } from 'fastify';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../app.js';
import type { AppConfig } from '../config.js';
import { defaultDiscoveryConfig } from '../config.js';
import type { RegisteredProvider } from '../discovery/catalog/discovery-catalog-service.js';
import {
  CatalogProviderError,
  type CatalogCapability,
  type CatalogSearchInput,
  type CatalogSearchPage,
  type CatalogSearchResult,
  type DiscoveryCatalogProvider,
} from '../discovery/catalog/types.js';
import { tracks, userTracks } from '../db/schema.js';

let root: string;
let app: FastifyInstance;
let ownerToken: string;

function fakeResult(overrides: Partial<CatalogSearchResult>): CatalogSearchResult {
  return {
    canonicalKey: 'k',
    entityType: 'track',
    title: 'Titre',
    artists: [{ name: 'Artiste', reference: null }],
    album: 'Album',
    durationMs: 200_000,
    releaseDate: '2001',
    explicit: false,
    images: [],
    isrc: null,
    upc: null,
    mbid: null,
    trackCount: null,
    providerReferences: [
      { provider: 'spotify', entityType: 'track', externalId: 't1', externalUrl: 'https://open.spotify.com/track/t1', market: 'FR' },
    ],
    externalLinks: [],
    preview: null,
    matchConfidence: 'STRONG',
    ...overrides,
  };
}

class FakeProvider implements DiscoveryCatalogProvider {
  readonly capabilities: ReadonlySet<CatalogCapability>;
  searchCalls = 0;
  failWith: CatalogProviderError | null = null;

  constructor(
    readonly id: 'itunes' | 'spotify' | 'musicbrainz' | 'apple_music',
    readonly results: CatalogSearchResult[],
    capabilities?: CatalogCapability[],
  ) {
    this.capabilities = new Set(
      capabilities ?? ['SEARCH_TRACKS', 'SEARCH_ARTISTS', 'SEARCH_ALBUMS', 'LOOKUP_ISRC', 'ALBUM_TRACKLIST'],
    );
  }

  readonly attribution = 'Test provider';

  async search(_input: CatalogSearchInput): Promise<CatalogSearchPage> {
    this.searchCalls += 1;
    if (this.failWith) throw this.failWith;
    return { items: this.results, nextCursor: null };
  }

  async resolveByIsrc(isrc: string): Promise<CatalogSearchResult[]> {
    if (this.failWith) throw this.failWith;
    return this.results.filter((result) => result.isrc === isrc.toUpperCase());
  }

  async getAlbum(id: string) {
    if (id !== 'al1') throw new CatalogProviderError('NOT_FOUND', 'album inconnu');
    return {
      reference: { provider: this.id, entityType: 'album' as const, externalId: id, externalUrl: null, market: 'FR' },
      title: 'Album complet',
      artists: [{ name: 'Artiste', reference: null }],
      releaseDate: '2001-03-01',
      albumType: 'album',
      label: 'Label',
      copyright: null,
      upc: null,
      mbid: null,
      images: [],
      discCount: 1,
      trackCount: 2,
      tracks: [
        { discNumber: 1, trackNumber: 1, position: 1, title: 'Un', artists: [], durationMs: 1000, explicit: false, isrc: null, reference: null, preview: null },
        { discNumber: 1, trackNumber: 2, position: 2, title: 'Deux', artists: [], durationMs: 2000, explicit: false, isrc: null, reference: null, preview: null },
      ],
      externalLinks: [],
    };
  }
}

function providersWith(entries: Partial<Record<string, RegisteredProvider>>): RegisteredProvider[] {
  const defaults: RegisteredProvider[] = [
    { id: 'itunes', enabled: false, disabledReason: 'test_disabled', provider: null },
    { id: 'spotify', enabled: false, disabledReason: 'credentials_missing', provider: null },
    { id: 'musicbrainz', enabled: false, disabledReason: 'user_agent_missing', provider: null },
    { id: 'apple_music', enabled: false, disabledReason: 'credentials_missing', provider: null },
    { id: 'deezer', enabled: false, disabledReason: 'tos_unverified', provider: null },
    { id: 'tidal', enabled: false, disabledReason: 'credentials_missing', provider: null },
  ];
  return defaults.map((entry) => entries[entry.id] ?? entry);
}

async function startApp(discoveryProviders: RegisteredProvider[]): Promise<void> {
  const config: AppConfig = {
    nodeEnv: 'test',
    host: '127.0.0.1',
    port: 0,
    dbPath: ':memory:',
    logLevel: 'fatal',
    musicDir: join(root, 'music'),
    incomingDir: join(root, 'incoming'),
    importRoot: join(root, 'imports'),
    coversDir: join(root, 'covers'),
    maxUploadBytes: 200 * 1024 * 1024,
    authTokenSecret: 'test-secret-at-least-thirty-two-characters',
    accessTokenTtlSeconds: 900,
    refreshTokenTtlSeconds: 86400,
    discovery: defaultDiscoveryConfig(),
  };
  app = buildApp(config, { importWatcher: false, discoveryProviders });
  await app.ready();
  const bootstrap = await app.inject({
    method: 'POST',
    url: '/api/auth/bootstrap',
    payload: {
      username: 'owner',
      displayName: 'Owner',
      password: 'owner-password-123',
      passwordConfirmation: 'owner-password-123',
    },
  });
  ownerToken = bootstrap.json().accessToken as string;
}

async function createUser(username: string): Promise<string> {
  const password = `${username}-password-123`;
  await app.inject({
    method: 'POST',
    url: '/api/admin/users',
    headers: { authorization: `Bearer ${ownerToken}` },
    payload: { username, displayName: username, temporaryPassword: password, role: 'USER' },
  });
  const login = await app.inject({
    method: 'POST',
    url: '/api/auth/login',
    payload: { username, password },
  });
  const changed = await app.inject({
    method: 'POST',
    url: '/api/auth/change-password',
    headers: { authorization: `Bearer ${login.json().accessToken as string}` },
    payload: {
      currentPassword: password,
      newPassword: `${username}-changed-password-123`,
      newPasswordConfirmation: `${username}-changed-password-123`,
    },
  });
  return changed.json().accessToken as string;
}

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'homespotify-discovery-catalog-'));
});

afterEach(async () => {
  await app.close();
  rmSync(root, { recursive: true, force: true });
});

describe('GET /api/discovery/search', () => {
  it('exige une authentification', async () => {
    await startApp(providersWith({}));
    const response = await app.inject({ method: 'GET', url: '/api/discovery/search?q=test' });
    expect(response.statusCode).toBe(401);
  });

  it('valide q, type et limit', async () => {
    await startApp(providersWith({}));
    const headers = { authorization: `Bearer ${ownerToken}` };
    expect((await app.inject({ method: 'GET', url: '/api/discovery/search?q=a', headers })).statusCode).toBe(400);
    expect(
      (await app.inject({ method: 'GET', url: '/api/discovery/search?q=ok&type=chanson', headers })).statusCode,
    ).toBe(400);
    expect(
      (await app.inject({ method: 'GET', url: '/api/discovery/search?q=ok&limit=999', headers })).statusCode,
    ).toBe(400);
    expect(
      (await app.inject({ method: 'GET', url: '/api/discovery/search?q=ok&market=France', headers })).statusCode,
    ).toBe(400);
  });

  it('retourne les résultats fusionnés + statuts des providers (désactivés inclus)', async () => {
    const spotify = new FakeProvider('spotify', [
      fakeResult({ canonicalKey: 'isrc:FRZ030100001', isrc: 'FRZ030100001' }),
    ]);
    const musicbrainz = new FakeProvider('musicbrainz', [
      fakeResult({
        canonicalKey: 'mbid:m1',
        isrc: 'FRZ030100001',
        mbid: 'm1',
        providerReferences: [
          { provider: 'musicbrainz', entityType: 'track', externalId: 'm1', externalUrl: null, market: null },
        ],
      }),
    ]);
    await startApp(
      providersWith({
        spotify: { id: 'spotify', enabled: true, disabledReason: null, provider: spotify },
        musicbrainz: { id: 'musicbrainz', enabled: true, disabledReason: null, provider: musicbrainz },
      }),
    );
    const response = await app.inject({
      method: 'GET',
      url: '/api/discovery/search?q=titre&type=track',
      headers: { authorization: `Bearer ${ownerToken}` },
    });
    expect(response.statusCode).toBe(200);
    const body = response.json();
    // Même ISRC des deux côtés : un seul résultat fusionné avec les deux refs.
    expect(body.items).toHaveLength(1);
    expect(body.items[0].providerReferences).toHaveLength(2);
    const statuses = Object.fromEntries(body.providers.map((p: { id: string; status: string }) => [p.id, p.status]));
    expect(statuses).toMatchObject({ spotify: 'OK', musicbrainz: 'OK', deezer: 'DISABLED', tidal: 'DISABLED' });
    // Plateformes sans preuve : UNKNOWN, providers coupés : PROVIDER_DISABLED.
    const links = body.items[0].externalLinks as Array<{ platform: string; status: string }>;
    expect(links.find((l) => l.platform === 'deezer')?.status).toBe('PROVIDER_DISABLED');
    expect(links.find((l) => l.platform === 'bandcamp')?.status).toBe('UNKNOWN');
  });

  it('résultats PARTIELS quand un provider échoue (l’autre répond)', async () => {
    const failing = new FakeProvider('spotify', []);
    failing.failWith = new CatalogProviderError('TIMEOUT', 'timeout simulé');
    const healthy = new FakeProvider('musicbrainz', [fakeResult({ canonicalKey: 'mbid:x', mbid: 'x' })]);
    await startApp(
      providersWith({
        spotify: { id: 'spotify', enabled: true, disabledReason: null, provider: failing },
        musicbrainz: { id: 'musicbrainz', enabled: true, disabledReason: null, provider: healthy },
      }),
    );
    const response = await app.inject({
      method: 'GET',
      url: '/api/discovery/search?q=titre',
      headers: { authorization: `Bearer ${ownerToken}` },
    });
    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body.items).toHaveLength(1);
    const spotifyStatus = body.providers.find((p: { id: string }) => p.id === 'spotify');
    expect(spotifyStatus.status).toBe('DEGRADED');
  });

  it('cache : le second appel identique ne rappelle pas le provider', async () => {
    const spotify = new FakeProvider('spotify', [fakeResult({})]);
    await startApp(
      providersWith({ spotify: { id: 'spotify', enabled: true, disabledReason: null, provider: spotify } }),
    );
    const headers = { authorization: `Bearer ${ownerToken}` };
    await app.inject({ method: 'GET', url: '/api/discovery/search?q=titre', headers });
    await app.inject({ method: 'GET', url: '/api/discovery/search?q=titre', headers });
    expect(spotify.searchCalls).toBe(1);
  });

  it('une recherche artiste exacte retire les variantes sans rapport', async () => {
    const itunes = new FakeProvider('itunes', [fakeResult({
      canonicalKey: 'itunes:artist:ajna',
      entityType: 'artist',
      title: 'Ajna',
      artists: [{ name: 'Ajna', reference: null }],
      providerReferences: [{
        provider: 'itunes', entityType: 'artist', externalId: 'ajna', externalUrl: null, market: 'FR',
      }],
    })], ['SEARCH_ARTISTS']);
    const musicbrainz = new FakeProvider('musicbrainz', [fakeResult({
      canonicalKey: 'mbid:random',
      entityType: 'artist',
      title: 'Ajna Masters',
      artists: [{ name: 'Ajna Masters', reference: null }],
      providerReferences: [{
        provider: 'musicbrainz', entityType: 'artist', externalId: 'random', externalUrl: null, market: null,
      }],
    })], ['SEARCH_ARTISTS']);
    await startApp(providersWith({
      itunes: { id: 'itunes', enabled: true, disabledReason: null, provider: itunes },
      musicbrainz: { id: 'musicbrainz', enabled: true, disabledReason: null, provider: musicbrainz },
    }));

    const response = await app.inject({
      method: 'GET',
      url: '/api/discovery/search?q=Ajna&type=artist',
      headers: { authorization: `Bearer ${ownerToken}` },
    });

    expect(response.statusCode).toBe(200);
    expect(response.json().items.map((item: { title: string }) => item.title)).toEqual(['Ajna']);
  });

  it('rate limit par utilisateur : 429 après la fenêtre autorisée', async () => {
    await startApp(providersWith({}));
    const headers = { authorization: `Bearer ${ownerToken}` };
    let lastCode = 200;
    for (let index = 0; index < 45; index += 1) {
      const response = await app.inject({ method: 'GET', url: `/api/discovery/search?q=req${index}`, headers });
      lastCode = response.statusCode;
    }
    expect(lastCode).toBe(429);
  });
});

describe('GET /api/discovery/providers et santé OWNER', () => {
  it('expose capacités et raisons de désactivation, jamais de secret', async () => {
    await startApp(providersWith({}));
    const response = await app.inject({
      method: 'GET',
      url: '/api/discovery/providers',
      headers: { authorization: `Bearer ${ownerToken}` },
    });
    expect(response.statusCode).toBe(200);
    const raw = response.body.toLowerCase();
    expect(raw).not.toContain('secret');
    expect(raw).not.toContain('client_id');
    expect(raw).not.toContain('token');
    const body = response.json();
    const deezer = body.providers.find((p: { id: string }) => p.id === 'deezer');
    expect(deezer).toMatchObject({ enabled: false, disabledReason: 'tos_unverified' });
  });

  it('la santé est réservée aux administrateurs', async () => {
    await startApp(providersWith({}));
    const userToken = await createUser('alice');
    const forbidden = await app.inject({
      method: 'GET',
      url: '/api/admin/discovery/health',
      headers: { authorization: `Bearer ${userToken}` },
    });
    expect(forbidden.statusCode).toBe(403);
    const allowed = await app.inject({
      method: 'GET',
      url: '/api/admin/discovery/health',
      headers: { authorization: `Bearer ${ownerToken}` },
    });
    expect(allowed.statusCode).toBe(200);
    expect(allowed.json().providers).toHaveLength(6);
    expect(allowed.json().cache).toHaveProperty('entries');
  });
});

describe('fiches et résolution', () => {
  it('fiche album : tracklist ordonnée du provider', async () => {
    const spotify = new FakeProvider('spotify', []);
    await startApp(
      providersWith({ spotify: { id: 'spotify', enabled: true, disabledReason: null, provider: spotify } }),
    );
    const response = await app.inject({
      method: 'GET',
      url: '/api/discovery/albums/spotify/al1',
      headers: { authorization: `Bearer ${ownerToken}` },
    });
    expect(response.statusCode).toBe(200);
    expect(response.json().tracks.map((t: { title: string }) => t.title)).toEqual(['Un', 'Deux']);
  });

  it('album inconnu → 404 ; provider désactivé → 503 ; id invalide → 400', async () => {
    const spotify = new FakeProvider('spotify', []);
    await startApp(
      providersWith({ spotify: { id: 'spotify', enabled: true, disabledReason: null, provider: spotify } }),
    );
    const headers = { authorization: `Bearer ${ownerToken}` };
    expect((await app.inject({ method: 'GET', url: '/api/discovery/albums/spotify/inconnu', headers })).statusCode).toBe(404);
    expect((await app.inject({ method: 'GET', url: '/api/discovery/albums/deezer/al1', headers })).statusCode).toBe(503);
    expect(
      (await app.inject({ method: 'GET', url: '/api/discovery/albums/spotify/..%2F..%2Fetc', headers })).statusCode,
    ).toBe(400);
  });

  it('résolution par ISRC retourne l’entité fusionnée EXACT', async () => {
    const spotify = new FakeProvider('spotify', [
      fakeResult({ canonicalKey: 'isrc:FRZ030100001', isrc: 'FRZ030100001', matchConfidence: 'EXACT' }),
    ]);
    await startApp(
      providersWith({ spotify: { id: 'spotify', enabled: true, disabledReason: null, provider: spotify } }),
    );
    const response = await app.inject({
      method: 'POST',
      url: '/api/discovery/resolve',
      headers: { authorization: `Bearer ${ownerToken}` },
      payload: { isrc: 'FRZ030100001' },
    });
    expect(response.statusCode).toBe(200);
    expect(response.json().isrc).toBe('FRZ030100001');
    const invalid = await app.inject({
      method: 'POST',
      url: '/api/discovery/resolve',
      headers: { authorization: `Bearer ${ownerToken}` },
      payload: { isrc: 'pas-un-isrc' },
    });
    expect(invalid.statusCode).toBe(400);
  });
});

describe('système de demandes musicales supprimé', () => {
  it('ne sert plus aucune route de demande, ni utilisateur ni OWNER', async () => {
    await startApp(providersWith({}));
    const userToken = await createUser('alice');
    const routes: Array<{ method: 'GET' | 'POST'; url: string; token: string }> = [
      { method: 'POST', url: '/api/music-requests', token: userToken },
      { method: 'GET', url: '/api/music-requests', token: userToken },
      { method: 'GET', url: '/api/admin/music-requests', token: ownerToken },
      { method: 'GET', url: '/api/admin/music-requests/1/spotify-link', token: ownerToken },
    ];
    for (const route of routes) {
      const response = await app.inject({
        method: route.method,
        url: route.url,
        headers: { authorization: `Bearer ${route.token}` },
        ...(route.method === 'POST' ? { payload: { candidateId: 1 } } : {}),
      });
      expect(response.statusCode).toBe(404);
    }
  });
});
