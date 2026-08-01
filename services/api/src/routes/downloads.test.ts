import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { FastifyInstance } from 'fastify';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { buildApp } from '../app.js';
import type { AppConfig } from '../config.js';
import type {
  DownloadHandle,
  DownloadProvider,
  DownloadProviderEvent,
  DownloadRequest,
  DownloadResult,
  ProviderHealth,
} from '../download/download-provider.js';
import type {
  CatalogSearchResult,
  DiscoveryProviderId,
} from '../discovery/catalog/types.js';
import type { TrackSearchProvider } from '../download/track-search.js';
import type { DownloadJobRow } from '../download/download-job-repository.js';
import { publicDownloadJob } from './downloads.js';

/**
 * Moteur factice : aucun processus Python n'est lancé, aucun réseau n'est
 * touché. Chaque job reste en cours tant que le test ne le termine pas.
 */
class FakeProvider implements DownloadProvider {
  readonly name = 'fake';
  readonly started: DownloadRequest[] = [];
  readonly cancelled: string[] = [];
  private readonly pending = new Map<string, (result: DownloadResult) => void>();
  private readonly emitters = new Map<
    string,
    Set<(event: DownloadProviderEvent) => void>
  >();

  async start(request: DownloadRequest): Promise<DownloadHandle> {
    this.started.push(request);
    const listeners = new Set<(event: DownloadProviderEvent) => void>();
    this.emitters.set(request.jobId, listeners);
    const completion = new Promise<DownloadResult>((resolvePromise) => {
      this.pending.set(request.jobId, resolvePromise);
    });
    return {
      processId: 999,
      completion,
      onEvent: (callback) => {
        listeners.add(callback);
        return () => listeners.delete(callback);
      },
    };
  }

  emit(jobId: string, event: DownloadProviderEvent): void {
    for (const listener of this.emitters.get(jobId) ?? []) listener(event);
  }

  fail(jobId: string): void {
    const resolvePromise = this.pending.get(jobId);
    if (!resolvePromise) return;
    this.pending.delete(jobId);
    resolvePromise({
      ok: false,
      downloaded: 0,
      skipped: 0,
      failed: 1,
      track: {},
      reportedFiles: [],
      errorCode: 'ENGINE_FAILED',
      errorMessage: 'Moteur en échec.',
    });
  }

  async cancel(jobId: string): Promise<void> {
    this.cancelled.push(jobId);
    this.fail(jobId);
  }

  async healthCheck(): Promise<ProviderHealth> {
    return {
      available: true,
      pythonFound: true,
      antraImportable: true,
      outputWritable: true,
      premiumKeyConfigured: true,
      soulseekDisabled: true,
      detail: null,
      checkedAt: new Date().toISOString(),
    };
  }

  stopAll(): void {}
}

/** Résultats catalogue pilotés par chaque test — aucun appel réseau. */
let searchResults: CatalogSearchResult[] = [];

function catalogTrack(options: {
  title: string;
  artist: string;
  isrc?: string | null;
  album?: string | null;
  durationMs?: number | null;
  urls?: Array<{ provider: DiscoveryProviderId; url: string }>;
}): CatalogSearchResult {
  const urls = options.urls ?? [
    { provider: 'deezer' as DiscoveryProviderId, url: 'https://www.deezer.com/track/9' },
  ];
  return {
    canonicalKey: options.isrc ? `isrc:${options.isrc}` : `id:${options.title}`,
    entityType: 'track',
    title: options.title,
    artists: [{ name: options.artist, reference: null }],
    album: options.album ?? options.title,
    durationMs: options.durationMs === undefined ? 180_000 : options.durationMs,
    releaseDate: null,
    explicit: null,
    images: [],
    isrc: options.isrc ?? null,
    upc: null,
    mbid: null,
    trackCount: null,
    providerReferences: urls.map((entry) => ({
      provider: entry.provider,
      entityType: 'track' as const,
      externalId: 'x',
      externalUrl: entry.url,
      market: 'FR',
    })),
    externalLinks: [],
    preview: null,
    matchConfidence: 'STRONG',
  };
}

const searchProvider: TrackSearchProvider = {
  name: 'fake_search',
  searchTracks: async () => searchResults,
};

const root = mkdtempSync(join(tmpdir(), 'homespotify-downloads-route-'));
const provider = new FakeProvider();

const config: AppConfig = {
  nodeEnv: 'test',
  host: '127.0.0.1',
  port: 0,
  dbPath: ':memory:',
  logLevel: 'fatal',
  musicDir: join(root, 'music'),
  incomingDir: join(root, 'imports'),
  importRoot: join(root, 'imports'),
  coversDir: join(root, 'covers'),
  maxUploadBytes: 200 * 1024 * 1024,
  authTokenSecret: 'test-secret-at-least-thirty-two-characters',
  accessTokenTtlSeconds: 900,
  refreshTokenTtlSeconds: 86_400,
  acquisitionProviders: {
    legacyEnabled: false,
    order: ['LUCIDA'],
    monochromeManualFallbackEnabled: false,
    monochromeBaseUrl: 'https://monochrome.tf/',
    monochromeManualTimeoutSeconds: 600,
    monochromeDownloadDirectory: '',
    monochromeFileStabilitySeconds: 3,
  },
  antra: {
    dir: join(root, 'antra'),
    pythonPath: join(root, 'antra', 'python.exe'),
    outputDir: join(root, 'imports'),
    source: 'auto',
    format: 'flac',
    allowedExtensions: ['.flac'],
    maxConcurrent: 2,
    jobTimeoutMs: 60_000,
    slskdAutoBootstrap: false,
    verbose: false,
  },
};

let app: FastifyInstance;
let ownerToken: string;
let otherToken: string;

const QOBUZ_URL =
  'https://www.qobuz.com/us-en/album/lifestyles-guala/m7mqu37d7v1ka';

function auth(token: string): Record<string, string> {
  return { authorization: `Bearer ${token}` };
}

beforeAll(async () => {
  app = buildApp(config, {
    importWatcher: false,
    downloadProvider: provider,
    trackSearchProvider: searchProvider,
  });
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
  expect(bootstrap.statusCode).toBe(201);
  ownerToken = bootstrap.json().accessToken as string;

  const created = await app.inject({
    method: 'POST',
    url: '/api/admin/users',
    headers: auth(ownerToken),
    payload: {
      username: 'invite',
      displayName: 'Invité',
      temporaryPassword: 'invite-temporaire-123',
      role: 'USER',
    },
  });
  expect([200, 201]).toContain(created.statusCode);

  const firstLogin = await app.inject({
    method: 'POST',
    url: '/api/auth/login',
    payload: { username: 'invite', password: 'invite-temporaire-123' },
  });
  expect(firstLogin.statusCode).toBe(200);

  // Le compte créé par le OWNER doit changer son mot de passe avant d'accéder
  // aux routes protégées : on sort de cet état pour tester le CLOISONNEMENT,
  // pas le changement de mot de passe.
  const changed = await app.inject({
    method: 'POST',
    url: '/api/auth/change-password',
    headers: auth(firstLogin.json().accessToken as string),
    payload: {
      currentPassword: 'invite-temporaire-123',
      newPassword: 'invite-definitif-456',
      newPasswordConfirmation: 'invite-definitif-456',
    },
  });
  expect(changed.statusCode).toBe(200);

  const login = await app.inject({
    method: 'POST',
    url: '/api/auth/login',
    payload: { username: 'invite', password: 'invite-definitif-456' },
  });
  expect(login.statusCode).toBe(200);
  otherToken = login.json().accessToken as string;
});

afterAll(async () => {
  await app.close();
  rmSync(root, { recursive: true, force: true });
});

describe('POST /api/downloads — authentification', () => {
  it('refuse sans jeton', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/api/downloads',
      payload: { url: QOBUZ_URL },
    });
    expect(response.statusCode).toBe(401);
  });

  it('refuse un jeton invalide', async () => {
    const response = await app.inject({
      method: 'GET',
      url: '/api/downloads',
      headers: { authorization: 'Bearer pas-un-jeton' },
    });
    expect(response.statusCode).toBe(401);
  });
});

describe('POST /api/downloads — validation', () => {
  it('refuse une URL non autorisée avec un code de raison exploitable', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/api/downloads',
      headers: auth(ownerToken),
      payload: { url: 'https://evil.example.com/track/1' },
    });
    expect(response.statusCode).toBe(400);
    expect(response.json().reasonCode).toBe('host_not_allowed');
    expect(response.json().supportedServices).toContain('open.spotify.com');
  });

  it('refuse un chemin local et un schéma dangereux', async () => {
    for (const url of ['file:///C:/musique.flac', 'javascript:alert(1)', '--output']) {
      const response = await app.inject({
        method: 'POST',
        url: '/api/downloads',
        headers: auth(ownerToken),
        payload: { url },
      });
      expect(response.statusCode, url).toBe(400);
    }
  });

  it('refuse un corps sans url', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/api/downloads',
      headers: auth(ownerToken),
      payload: {},
    });
    expect(response.statusCode).toBe(400);
  });
});

describe('cycle de vie complet', () => {
  let jobId: string;

  it('crée un job Qobuz et répond 202', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/api/downloads',
      headers: auth(ownerToken),
      payload: { url: QOBUZ_URL, source: 'auto', format: 'flac' },
    });
    expect(response.statusCode).toBe(202);
    const body = response.json();
    jobId = body.jobId as string;
    expect(body.status).toBe('queued');
    // Aucun chemin serveur, PID ni commande dans la réponse publique.
    const serialized = JSON.stringify(body);
    expect(serialized).not.toContain('processId');
    expect(serialized).not.toContain('outputPath');
    expect(serialized).not.toMatch(/[A-Za-z]:\\/);
  });

  it('refuse un doublon actif de la même URL', async () => {
    const response = await app.inject({
      method: 'POST',
      url: '/api/downloads',
      headers: auth(ownerToken),
      payload: { url: QOBUZ_URL },
    });
    expect(response.statusCode).toBe(409);
    expect(response.json().error).toBe('active_duplicate');
  });

  it('expose le détail du job à son propriétaire', async () => {
    const response = await app.inject({
      method: 'GET',
      url: `/api/downloads/${jobId}`,
      headers: auth(ownerToken),
    });
    expect(response.statusCode).toBe(200);
    expect(response.json().item.id).toBe(jobId);
  });

  it('cloisonne strictement par compte (404 pour un autre utilisateur)', async () => {
    const detail = await app.inject({
      method: 'GET',
      url: `/api/downloads/${jobId}`,
      headers: auth(otherToken),
    });
    expect(detail.statusCode).toBe(404);

    const list = await app.inject({
      method: 'GET',
      url: '/api/downloads',
      headers: auth(otherToken),
    });
    expect(list.statusCode).toBe(200);
    expect(list.json().items).toEqual([]);
  });

  it('annule le job et refuse la seconde annulation d’un job terminal', async () => {
    const cancelled = await app.inject({
      method: 'DELETE',
      url: `/api/downloads/${jobId}`,
      headers: auth(ownerToken),
    });
    expect(cancelled.statusCode).toBe(202);
    expect(cancelled.json().accepted).toBe(true);

    // Attend que le worker ait réellement enregistré l'état terminal : un délai
    // fixe rendrait le test dépendant de la machine.
    const deadline = Date.now() + 5_000;
    let status = '';
    while (Date.now() < deadline) {
      const current = await app.inject({
        method: 'GET',
        url: `/api/downloads/${jobId}`,
        headers: auth(ownerToken),
      });
      status = current.json().item.status as string;
      if (status === 'cancelled') break;
      await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
    }
    expect(status).toBe('cancelled');

    const again = await app.inject({
      method: 'DELETE',
      url: `/api/downloads/${jobId}`,
      headers: auth(ownerToken),
    });
    expect(again.statusCode).toBe(200);
    expect(again.json().accepted).toBe(false);
  });

  it('refuse de relancer un job annulé', async () => {
    const response = await app.inject({
      method: 'POST',
      url: `/api/downloads/${jobId}/retry`,
      headers: auth(ownerToken),
    });
    expect(response.statusCode).toBe(409);
    expect(response.json().error).toBe('not_retryable');
  });
});

describe('GET /api/downloads/:id — identifiants invalides', () => {
  it('refuse un identifiant qui n’est pas un UUID', async () => {
    const response = await app.inject({
      method: 'GET',
      url: '/api/downloads/../../etc/passwd',
      headers: auth(ownerToken),
    });
    expect([400, 404]).toContain(response.statusCode);
  });

  it('répond 404 pour un UUID inconnu', async () => {
    const response = await app.inject({
      method: 'GET',
      url: '/api/downloads/2f3a1c58-9c1b-4f0e-8a2d-7c9f1b2e3d4a',
      headers: auth(ownerToken),
    });
    expect(response.statusCode).toBe(404);
  });
});

describe('POST /api/downloads/search', () => {
  it('résout une recherche texte en job, sans URL fournie', async () => {
    searchResults = [
      catalogTrack({ title: 'Lifestyle', artist: 'Rich Gang' }),
      catalogTrack({
        title: 'Lifestyles',
        artist: 'Guala',
        isrc: 'AAAAA0000001',
        urls: [
          { provider: 'spotify', url: 'https://open.spotify.com/track/search1' },
          { provider: 'deezer', url: 'https://www.deezer.com/track/search1' },
        ],
      }),
    ];

    const response = await app.inject({
      method: 'POST',
      url: '/api/downloads/search',
      headers: auth(ownerToken),
      payload: { query: 'Guala Lifestyles' },
    });

    expect(response.statusCode).toBe(202);
    const body = response.json();
    expect(body.resolution).toBe('queued');
    expect(body.track.title).toBe('Lifestyles');
    expect(body.track.artist).toBe('Guala');
    expect(body.track.isrc).toBe('AAAAA0000001');
    // Spotify en tête : URL la moins contrainte pour le moteur.
    expect(body.track.sources[0]).toBe('spotify');
    expect(typeof body.jobId).toBe('string');

    // Aucun secret ni chemin serveur dans la réponse.
    const serialized = JSON.stringify(body);
    expect(serialized).not.toMatch(/token|secret|api[_-]?key|password/i);
    expect(serialized).not.toMatch(/[A-Za-z]:\\/);

    await app.inject({
      method: 'DELETE',
      url: `/api/downloads/${body.jobId}`,
      headers: auth(ownerToken),
    });
  });

  it('renvoie les candidats sans créer de job quand le choix est ambigu', async () => {
    searchResults = [
      catalogTrack({ title: 'Lifestyles', artist: 'Guala', isrc: 'AAAAA0000002' }),
      catalogTrack({ title: 'Lifestyles', artist: 'Guala', isrc: 'BBBBB0000003' }),
    ];

    const before = await app.inject({
      method: 'GET',
      url: '/api/downloads',
      headers: auth(ownerToken),
    });
    const countBefore = (before.json().items as unknown[]).length;

    const response = await app.inject({
      method: 'POST',
      url: '/api/downloads/search',
      headers: auth(ownerToken),
      payload: { query: 'Guala Lifestyles' },
    });

    expect(response.statusCode).toBe(200);
    expect(response.json().resolution).toBe('ambiguous');
    expect((response.json().candidates as unknown[]).length).toBeGreaterThanOrEqual(2);
    expect(response.json().jobId).toBeUndefined();

    const after = await app.inject({
      method: 'GET',
      url: '/api/downloads',
      headers: auth(ownerToken),
    });
    expect((after.json().items as unknown[]).length).toBe(countBefore);
  });

  it('signale l’absence de correspondance', async () => {
    searchResults = [catalogTrack({ title: 'Symphonie n°9', artist: 'Beethoven' })];
    const response = await app.inject({
      method: 'POST',
      url: '/api/downloads/search',
      headers: auth(ownerToken),
      payload: { query: 'Guala Lifestyles' },
    });
    expect(response.statusCode).toBe(200);
    expect(response.json().resolution).toBe('no_match');
  });

  it('accepte title et artist séparés', async () => {
    searchResults = [
      catalogTrack({
        title: 'Lifestyles',
        artist: 'Guala',
        isrc: 'AAAAA0000004',
        urls: [{ provider: 'spotify', url: 'https://open.spotify.com/track/search4' }],
      }),
    ];
    const response = await app.inject({
      method: 'POST',
      url: '/api/downloads/search',
      headers: auth(ownerToken),
      payload: { title: 'Lifestyles', artist: 'Guala' },
    });
    expect(response.statusCode).toBe(202);
    await app.inject({
      method: 'DELETE',
      url: `/api/downloads/${response.json().jobId}`,
      headers: auth(ownerToken),
    });
  });

  it('refuse une requête vide, trop courte ou non authentifiée', async () => {
    expect(
      (
        await app.inject({
          method: 'POST',
          url: '/api/downloads/search',
          payload: { query: 'Guala Lifestyles' },
        })
      ).statusCode,
    ).toBe(401);

    for (const payload of [{}, { query: 'a' }, { query: '   ' }, { query: 42 }]) {
      const response = await app.inject({
        method: 'POST',
        url: '/api/downloads/search',
        headers: auth(ownerToken),
        payload,
      });
      expect(response.statusCode, JSON.stringify(payload)).toBe(400);
    }
  });

  it('cloisonne les jobs créés par recherche', async () => {
    searchResults = [
      catalogTrack({
        title: 'Lifestyles',
        artist: 'Guala',
        isrc: 'AAAAA0000005',
        urls: [{ provider: 'spotify', url: 'https://open.spotify.com/track/search5' }],
      }),
    ];
    const created = await app.inject({
      method: 'POST',
      url: '/api/downloads/search',
      headers: auth(ownerToken),
      payload: { query: 'Guala Lifestyles' },
    });
    expect(created.statusCode).toBe(202);
    const jobId = created.json().jobId as string;

    const foreign = await app.inject({
      method: 'GET',
      url: `/api/downloads/${jobId}`,
      headers: auth(otherToken),
    });
    expect(foreign.statusCode).toBe(404);

    await app.inject({
      method: 'DELETE',
      url: `/api/downloads/${jobId}`,
      headers: auth(ownerToken),
    });
  });
});

describe('GET /api/downloads/health', () => {
  it('expose des booléens et jamais la clé Premium', async () => {
    const response = await app.inject({
      method: 'GET',
      url: '/api/downloads/health',
      headers: auth(ownerToken),
    });
    expect(response.statusCode).toBe(200);
    const body = response.json();
    expect(body).toMatchObject({
      available: true,
      configured: true,
      pythonFound: true,
      antraImportable: true,
      outputWritable: true,
      premiumKeyConfigured: true,
      soulseekDisabled: true,
    });
    expect(typeof body.premiumKeyConfigured).toBe('boolean');
    // Aucune trace de clé, de chemin ni de commande.
    const serialized = JSON.stringify(body);
    expect(serialized).not.toMatch(/sk_|ANTRA_API_KEY/);
    // Aucun chemin serveur : `pythonFound` est un booléen du contrat, jamais
    // le chemin de l'interpréteur.
    expect(serialized).not.toMatch(/[A-Za-z]:\\/);
    expect(serialized).not.toContain('python.exe');
    expect(serialized).not.toContain('.venv');
  });

  it('exige une authentification', async () => {
    const response = await app.inject({ method: 'GET', url: '/api/downloads/health' });
    expect(response.statusCode).toBe(401);
  });
});

describe('POST /api/downloads/search — sélection épinglée', () => {
  it('installe la piste désignée sans jamais redemander de choix', async () => {
    // Deux homonymes parfaits : en texte libre le résolveur rendrait la main.
    searchResults = [
      catalogTrack({
        title: 'Lifestyles',
        artist: 'Guala',
        isrc: 'QZTBF2599924',
        album: 'Lifestyles',
        durationMs: 127_000,
        urls: [{ provider: 'spotify', url: 'https://open.spotify.com/track/pinned1' }],
      }),
      catalogTrack({
        title: 'Lifestyles',
        artist: 'Guala',
        isrc: 'ZZZZZ0000009',
        album: 'Autre édition',
        durationMs: 240_000,
        urls: [{ provider: 'deezer', url: 'https://www.deezer.com/track/pinned2' }],
      }),
    ];

    const response = await app.inject({
      method: 'POST',
      url: '/api/downloads/search',
      headers: auth(ownerToken),
      payload: {
        query: 'Guala Lifestyles',
        title: 'Lifestyles',
        artist: 'Guala',
        album: 'Lifestyles',
        isrc: 'QZTBF2599924',
        durationSeconds: 127,
      },
    });

    expect(response.statusCode).toBe(202);
    const body = response.json();
    expect(body.resolution).toBe('queued');
    // C'est bien la piste ÉPINGLÉE qui part, pas son homonyme.
    expect(body.track.isrc).toBe('QZTBF2599924');
    expect(body.track.durationSeconds).toBe(127);
    // Aucune URL n'a été fournie par l'appelant : le serveur l'a résolue seul.
    expect(body.track.downloadUrl).toContain('open.spotify.com');

    await app.inject({
      method: 'DELETE',
      url: `/api/downloads/${body.jobId as string}`,
      headers: auth(ownerToken),
    });
  });

  it('tranche même sans ISRC dès que titre et artiste sont fournis', async () => {
    searchResults = [
      catalogTrack({
        title: 'Lifestyles',
        artist: 'Guala',
        isrc: 'AAAAA0000011',
        urls: [{ provider: 'spotify', url: 'https://open.spotify.com/track/pinned3' }],
      }),
      catalogTrack({
        title: 'Lifestyles',
        artist: 'Guala',
        isrc: 'AAAAA0000012',
        urls: [{ provider: 'deezer', url: 'https://www.deezer.com/track/pinned4' }],
      }),
    ];

    const response = await app.inject({
      method: 'POST',
      url: '/api/downloads/search',
      headers: auth(ownerToken),
      payload: { query: 'Guala Lifestyles', title: 'Lifestyles', artist: 'Guala' },
    });

    expect(response.statusCode).toBe(202);
    expect(response.json().resolution).toBe('queued');

    await app.inject({
      method: 'DELETE',
      url: `/api/downloads/${response.json().jobId as string}`,
      headers: auth(ownerToken),
    });
  });

  it('ordonne plusieurs sources pour permettre le repli automatique', async () => {
    searchResults = [
      catalogTrack({
        title: 'Lifestyles',
        artist: 'Guala',
        isrc: 'AAAAA0000013',
        urls: [
          { provider: 'deezer', url: 'https://www.deezer.com/track/order1' },
          { provider: 'spotify', url: 'https://open.spotify.com/track/order1' },
          { provider: 'tidal', url: 'https://tidal.com/browse/track/order1' },
        ],
      }),
    ];

    const response = await app.inject({
      method: 'POST',
      url: '/api/downloads/search',
      headers: auth(ownerToken),
      payload: { query: 'Guala Lifestyles', title: 'Lifestyles', artist: 'Guala' },
    });

    expect(response.statusCode).toBe(202);
    const sources = response.json().track.sources as string[];
    // Chaîne de repli : Spotify d'abord (résolution la plus large côté moteur).
    expect(sources.length).toBeGreaterThanOrEqual(3);
    expect(sources[0]).toBe('spotify');

    await app.inject({
      method: 'DELETE',
      url: `/api/downloads/${response.json().jobId as string}`,
      headers: auth(ownerToken),
    });
  });

  it('refuse une identité malformée plutôt que de télécharger autre chose', async () => {
    searchResults = [catalogTrack({ title: 'Lifestyles', artist: 'Guala' })];
    for (const payload of [
      { query: 'Guala Lifestyles', isrc: 'PAS-UN-ISRC' },
      { query: 'Guala Lifestyles', isrc: 42 },
      { query: 'Guala Lifestyles', durationSeconds: 0 },
      { query: 'Guala Lifestyles', durationSeconds: 99_999 },
      { query: 'Guala Lifestyles', durationSeconds: 'deux minutes' },
      { query: 'Guala Lifestyles', album: 12 },
    ]) {
      const response = await app.inject({
        method: 'POST',
        url: '/api/downloads/search',
        headers: auth(ownerToken),
        payload,
      });
      expect(response.statusCode, JSON.stringify(payload)).toBe(400);
    }
  });

  it('rattache le job au compte du jeton et n’expose ni secret ni chemin', async () => {
    searchResults = [
      catalogTrack({
        title: 'Lifestyles',
        artist: 'Guala',
        isrc: 'AAAAA0000014',
        urls: [{ provider: 'spotify', url: 'https://open.spotify.com/track/scoped' }],
      }),
    ];

    const created = await app.inject({
      method: 'POST',
      url: '/api/downloads/search',
      headers: auth(otherToken),
      // Un userId fourni par le client est ignoré : seul le jeton fait foi.
      payload: {
        query: 'Guala Lifestyles',
        title: 'Lifestyles',
        artist: 'Guala',
        userId: 1,
      },
    });
    expect(created.statusCode).toBe(202);
    const jobId = created.json().jobId as string;

    const serialized = JSON.stringify(created.json());
    expect(serialized).not.toMatch(/token|secret|api[_-]?key|password|premium/i);
    expect(serialized).not.toMatch(/[A-Za-z]:\\/);
    expect(serialized).not.toMatch(/outputPath/);

    // Le OWNER ne voit pas le job de l'autre compte.
    expect(
      (
        await app.inject({
          method: 'GET',
          url: `/api/downloads/${jobId}`,
          headers: auth(ownerToken),
        })
      ).statusCode,
    ).toBe(404);

    await app.inject({
      method: 'DELETE',
      url: `/api/downloads/${jobId}`,
      headers: auth(otherToken),
    });
  });
});

describe('publicDownloadJob', () => {
  const baseJob = {
    id: '11111111-1111-4111-8111-111111111111',
    userId: 1,
    provider: 'antra',
    requestedUrl: 'https://open.spotify.com/track/x',
    normalizedUrl: 'https://open.spotify.com/track/x',
    requestKind: 'search',
    query: 'Guala Lifestyles',
    candidatesJson: null,
    attemptsJson: null,
    selectedProvider: 'spotify',
    selectedUrl: 'https://open.spotify.com/track/x',
    status: 'completed',
    stage: 'completed',
    progress: 100,
    message: 'Piste ajoutée à votre bibliothèque.',
    title: 'Lifestyles',
    artist: 'Guala',
    album: 'Lifestyles',
    source: 'qobuz',
    quality: 'FLAC 24-bit/96kHz',
    outputPath: 'C:\\secret\\chemin.flac',
    localImportJobId: 3,
    trackId: 42,
    errorCode: null,
    errorMessage: null,
    processId: 4321,
    attempt: 1,
    maxAttempts: 3,
    cancelRequested: false,
    createdAt: '2026-08-01T10:00:00.000Z',
    updatedAt: '2026-08-01T10:05:00.000Z',
    startedAt: '2026-08-01T10:00:01.000Z',
    completedAt: '2026-08-01T10:05:00.000Z',
  } as unknown as DownloadJobRow;

  it('signale la réutilisation comme un succès, jamais comme un échec', () => {
    const imported = publicDownloadJob(baseJob);
    expect(imported.status).toBe('completed');
    expect(imported.reused).toBe(false);

    const reused = publicDownloadJob({
      ...baseJob,
      stage: 'reused',
    } as DownloadJobRow);
    expect(reused.status).toBe('completed');
    expect(reused.reused).toBe(true);
    expect(reused.errorCode).toBeNull();
  });

  it('n’expose jamais le chemin serveur ni le PID', () => {
    const view = publicDownloadJob(baseJob);
    expect(view.outputPath).toBeUndefined();
    expect(view.processId).toBeUndefined();
    expect(JSON.stringify(view)).not.toMatch(/[A-Za-z]:\\/);
  });
});
