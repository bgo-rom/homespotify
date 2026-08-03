/**
 * Tests HTTP de bout en bout du Storage Agent.
 *
 * Toujours 127.0.0.1 + port éphémère, jamais 3100, jamais 0.0.0.0. Chaque
 * serveur est fermé en `afterEach` : aucun processus ne reste en écoute.
 */
import { readFileSync, rmSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { request as httpRequest } from 'node:http';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import { Writable } from 'node:stream';
import type { ReadStream } from 'node:fs';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { loadStorageAgentConfig } from './config.js';
import { EMPTY_BODY_SHA256, buildSignedHeaders, generateNonce } from './hmac-auth.js';
import { objectAbsolutePath } from './object-store.js';
import { StorageIndexStore } from './storage-index.js';
import {
  createFixture,
  removeFixture,
  signedFetch,
  startAgent,
  testConfig,
  writeIndex,
  TRACK_CONTENT,
  type AgentFixture,
  type RunningAgent,
} from './test/harness.js';
import type { CreateReadStreamFn, StorageAgentInstance } from './server.js';
import type { FastifyServerOptions } from 'fastify';

const TRACKS = '/internal/storage/tracks';
const OBJECTS = '/internal/storage/objects';
const HEALTH = '/internal/storage/health';
const INDEX = '/internal/storage/index';

function objectRoute(body: Buffer, extension: 'flac' | 'wav' = 'flac'): {
  hash: string;
  path: string;
} {
  const hash = createHash('sha256').update(body).digest('hex');
  return { hash, path: `${OBJECTS}/${hash}.${extension}` };
}

let fixture: AgentFixture;
const running: RunningAgent[] = [];

beforeEach(() => {
  fixture = createFixture();
});

afterEach(async () => {
  // Fermeture systématique : aucun listener résiduel.
  await Promise.all(running.splice(0).map((agent) => agent.close()));
  removeFixture(fixture);
});

async function launch(
  options: {
    configOverrides?: Parameters<typeof testConfig>[1];
    createReadStream?: CreateReadStreamFn;
    indexStore?: StorageIndexStore;
    logger?: FastifyServerOptions['logger'];
  } = {},
): Promise<RunningAgent> {
  const config = testConfig(fixture, options.configOverrides ?? {});
  const indexStore =
    options.indexStore ?? new StorageIndexStore({ indexPath: config.indexPath, pollIntervalMs: 0 });
  indexStore.reloadIfChanged();
  const agent = await startAgent({
    config,
    indexStore,
    ...(options.createReadStream ? { createReadStream: options.createReadStream } : {}),
    ...(options.logger === undefined ? {} : { logger: options.logger }),
  });
  running.push(agent);
  return agent;
}

function agentRuntime(agent: RunningAgent): StorageAgentInstance['storageAgent'] {
  return agent.app.storageAgent;
}

async function waitFor(predicate: () => boolean, timeoutMs = 2_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error('condition non atteinte dans le délai imparti');
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

/** Flux contrôlé : sert à figer un GET ouvert ou à simuler une panne disque. */
function controlledStream(): { stream: ReadStream; push: (chunk: string) => void; fail: () => void } {
  const readable = new Readable({ read() {} });
  return {
    stream: readable as unknown as ReadStream,
    push: (chunk: string) => readable.push(chunk),
    fail: () => readable.destroy(new Error('EIO simulé')),
  };
}

// ---------------------------------------------------------------------------
// Authentification et filtrage IP
// ---------------------------------------------------------------------------
describe('authentification', () => {
  it('accepte une requête signée depuis une IP autorisée', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', HEALTH);
    expect(response.status).toBe(200);
  });

  it('refuse une requête sans en-tête d’authentification (401 AUTH_MISSING)', async () => {
    const agent = await launch();
    const response = await fetch(`${agent.baseUrl}${HEALTH}`);
    expect(response.status).toBe(401);
    expect(await response.json()).toMatchObject({ error: 'AUTH_MISSING' });
  });

  it('refuse une signature invalide (401 AUTH_INVALID)', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', HEALTH, { secret: 'z'.repeat(64) });
    expect(response.status).toBe(401);
    expect(response.headers.get('x-hs-error-code')).toBe('AUTH_INVALID');
    expect(await response.json()).toMatchObject({ error: 'AUTH_INVALID' });
  });

  it('refuse un horodatage hors fenêtre (401 AUTH_EXPIRED)', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', HEALTH, {
      timestamp: Math.floor(Date.now() / 1000) - 3_600,
    });
    expect(response.status).toBe(401);
    expect(await response.json()).toMatchObject({ error: 'AUTH_EXPIRED' });
  });

  it('refuse un nonce rejoué (401 AUTH_REPLAY)', async () => {
    const agent = await launch();
    const nonce = generateNonce();
    const first = await signedFetch(agent, 'GET', HEALTH, { nonce });
    expect(first.status).toBe(200);
    const replay = await signedFetch(agent, 'GET', HEALTH, { nonce });
    expect(replay.status).toBe(401);
    expect(await replay.json()).toMatchObject({ error: 'AUTH_REPLAY' });
  });

  it('refuse une signature portant sur une autre query string', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', `${HEALTH}?a=2`, { signedPath: `${HEALTH}?a=1` });
    expect(response.status).toBe(401);
  });

  it('refuse une IP source non autorisée (403 SOURCE_IP_DENIED)', async () => {
    const agent = await launch({ configOverrides: { allowedRemoteIps: ['10.8.0.1'] } });
    const response = await signedFetch(agent, 'GET', HEALTH);
    expect(response.status).toBe(403);
    expect(await response.json()).toMatchObject({ error: 'SOURCE_IP_DENIED' });
  });

  it('accepte une IP déclarée en forme IPv4-mapped IPv6 sans élargir la plage', async () => {
    // `::ffff:127.0.0.1` est normalisée en `127.0.0.1` au chargement de la
    // configuration : la comparaison reste une égalité stricte.
    const config = loadStorageAgentConfig({
      NODE_ENV: 'test',
      STORAGE_AGENT_MUSIC_ROOT: fixture.musicRoot,
      STORAGE_AGENT_INDEX_PATH: fixture.indexPath,
      STORAGE_AGENT_SHARED_SECRET: 'e'.repeat(64),
      STORAGE_AGENT_ALLOWED_REMOTE_IP: '::ffff:127.0.0.1',
      STORAGE_AGENT_INDEX_POLL_INTERVAL_MS: '0',
    });
    expect(config.allowedRemoteIps).toEqual(['127.0.0.1']);

    const indexStore = new StorageIndexStore({ indexPath: config.indexPath, pollIntervalMs: 0 });
    indexStore.reloadIfChanged();
    const agent = await startAgent({ config, indexStore });
    running.push(agent);
    expect((await signedFetch(agent, 'GET', HEALTH)).status).toBe(200);
  });

  it('refuse une requête portant un corps', async () => {
    const agent = await launch();
    const headers = buildSignedHeaders({
      secret: agent.secret,
      method: 'GET',
      pathWithQuery: HEALTH,
    });
    // `fetch` interdit un corps sur GET : requête HTTP brute.
    const status = await new Promise<number>((resolve, reject) => {
      const request = httpRequest(
        `${agent.baseUrl}${HEALTH}`,
        { method: 'GET', headers: { ...headers, 'content-length': '4' } },
        (response) => {
          response.resume();
          resolve(response.statusCode ?? 0);
        },
      );
      request.on('error', reject);
      request.end('abcd');
    });
    expect(status).toBe(401);
  });

  it('renvoie l’en-tête x-request-id fourni par l’appelant', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', HEALTH, {
      headers: { 'x-request-id': 'vps-42' },
    });
    expect(response.headers.get('x-request-id')).toBe('vps-42');
  });

  it('journalise le requestId fourni sur un événement HEAD réussi', async () => {
    const lines: string[] = [];
    const stream = new Writable({
      write(chunk, _encoding, callback) {
        lines.push(String(chunk));
        callback();
      },
    });
    const agent = await launch({
      logger: { level: 'info', stream },
    });

    const response = await signedFetch(agent, 'HEAD', `${TRACKS}/1`, {
      headers: { 'x-request-id': 'phase45-requestid-contract-42' },
    });
    expect(response.status).toBe(200);
    await waitFor(() =>
      lines.some((line) => {
        const event = JSON.parse(line) as Record<string, unknown>;
        return (
          event.event === 'STORAGE_AGENT_REQUEST_COMPLETED' &&
          event.requestId === 'phase45-requestid-contract-42' &&
          event.method === 'HEAD' &&
          event.trackId === 1 &&
          event.statusCode === 200
        );
      }),
    );
  });
});

// ---------------------------------------------------------------------------
// HEAD
// ---------------------------------------------------------------------------
describe('HEAD /internal/storage/tracks/:trackId', () => {
  it('n’ouvre AUCUN ReadStream', async () => {
    let opened = 0;
    const agent = await launch({
      createReadStream: () => {
        opened += 1;
        return controlledStream().stream;
      },
    });
    const response = await signedFetch(agent, 'HEAD', `${TRACKS}/1`);
    expect(response.status).toBe(200);
    expect(opened).toBe(0);
  });

  it('ne consomme aucun emplacement de flux', async () => {
    const agent = await launch();
    await signedFetch(agent, 'HEAD', `${TRACKS}/1`);
    expect(agentRuntime(agent).limiter.activeStreams).toBe(0);
  });

  it('renvoie les en-têtes exacts et un corps vide', async () => {
    const agent = await launch();
    const expected = statSync(join(fixture.musicRoot, 'Artiste', 'Album', 'Piste.flac'));
    const response = await signedFetch(agent, 'HEAD', `${TRACKS}/1`);

    expect(response.status).toBe(200);
    expect(response.headers.get('accept-ranges')).toBe('bytes');
    expect(response.headers.get('content-type')).toBe('audio/flac');
    expect(response.headers.get('content-length')).toBe(String(TRACK_CONTENT.length));
    expect(response.headers.get('last-modified')).toBe(expected.mtime.toUTCString());
    expect(response.headers.get('content-range')).toBeNull();
    expect(await response.text()).toBe('');
  });

  it('honore un Range valide en 206', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'HEAD', `${TRACKS}/1`, {
      headers: { range: 'bytes=4-7' },
    });
    expect(response.status).toBe(206);
    expect(response.headers.get('content-range')).toBe('bytes 4-7/16');
    expect(response.headers.get('content-length')).toBe('4');
    expect(await response.text()).toBe('');
  });

  it('renvoie 416 sur un Range invalide', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'HEAD', `${TRACKS}/1`, {
      headers: { range: 'bytes=99-' },
    });
    expect(response.status).toBe(416);
    expect(response.headers.get('x-hs-error-code')).toBe('INVALID_RANGE');
    expect(response.headers.get('content-range')).toBe('bytes */16');
    expect(await response.text()).toBe('');
  });

  it('renvoie 404 pour un fichier absent du disque', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'HEAD', `${TRACKS}/3`);
    expect(response.status).toBe(404);
    expect(response.headers.get('x-hs-error-code')).toBe('FILE_NOT_FOUND');
  });

  it('renvoie 404 pour une piste hors index', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'HEAD', `${TRACKS}/999`);
    expect(response.status).toBe(404);
    expect(response.headers.get('x-hs-error-code')).toBe('TRACK_NOT_INDEXED');
  });

  it('renvoie 401 sans authentification', async () => {
    const agent = await launch();
    const response = await fetch(`${agent.baseUrl}${TRACKS}/1`, { method: 'HEAD' });
    expect(response.status).toBe(401);
  });

  it('renvoie 400 pour un trackId invalide', async () => {
    const agent = await launch();
    for (const raw of ['abc', '0', '-1', '1.5', '99999999999999999999']) {
      const response = await signedFetch(agent, 'HEAD', `${TRACKS}/${raw}`);
      expect(response.status).toBe(400);
    }
  });
});

// ---------------------------------------------------------------------------
// GET
// ---------------------------------------------------------------------------
describe('GET /internal/storage/tracks/:trackId', () => {
  it('sert le fichier complet en 200', async () => {
    const agent = await launch();
    const expected = statSync(join(fixture.musicRoot, 'Artiste', 'Album', 'Piste.flac'));
    const response = await signedFetch(agent, 'GET', `${TRACKS}/1`);

    expect(response.status).toBe(200);
    expect(response.headers.get('accept-ranges')).toBe('bytes');
    expect(response.headers.get('content-type')).toBe('audio/flac');
    expect(response.headers.get('content-length')).toBe('16');
    expect(response.headers.get('last-modified')).toBe(expected.mtime.toUTCString());
    expect(response.headers.get('content-range')).toBeNull();
    expect(Buffer.from(await response.arrayBuffer())).toEqual(TRACK_CONTENT);
  });

  it('sert une plage N-M en 206', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', `${TRACKS}/1`, {
      headers: { range: 'bytes=2-5' },
    });
    expect(response.status).toBe(206);
    expect(response.headers.get('content-range')).toBe('bytes 2-5/16');
    expect(response.headers.get('content-length')).toBe('4');
    expect(await response.text()).toBe('2345');
  });

  it('sert une plage N- jusqu’à la fin', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', `${TRACKS}/1`, {
      headers: { range: 'bytes=12-' },
    });
    expect(response.status).toBe(206);
    expect(response.headers.get('content-range')).toBe('bytes 12-15/16');
    expect(await response.text()).toBe('CDEF');
  });

  it('sert une plage suffixe', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', `${TRACKS}/1`, {
      headers: { range: 'bytes=-3' },
    });
    expect(response.status).toBe(206);
    expect(response.headers.get('content-range')).toBe('bytes 13-15/16');
    expect(await response.text()).toBe('DEF');
  });

  it('renvoie 416 pour une plage insatisfaisable', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', `${TRACKS}/1`, {
      headers: { range: 'bytes=20-30' },
    });
    expect(response.status).toBe(416);
    expect(response.headers.get('x-hs-error-code')).toBe('INVALID_RANGE');
    expect(response.headers.get('content-range')).toBe('bytes */16');
    expect(await response.text()).toBe('');
  });

  it('refuse le multi-range en servant la représentation complète', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', `${TRACKS}/1`, {
      headers: { range: 'bytes=0-1,4-5' },
    });
    expect(response.status).toBe(200);
    expect(response.headers.get('content-type')).toBe('audio/flac');
    expect(Buffer.from(await response.arrayBuffer())).toEqual(TRACK_CONTENT);
  });

  it('sert un fichier vide en 200 avec Content-Length 0', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', `${TRACKS}/2`);
    expect(response.status).toBe(200);
    expect(response.headers.get('content-length')).toBe('0');
    expect(await response.text()).toBe('');
  });

  it('renvoie 416 sur un Range appliqué à un fichier vide', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', `${TRACKS}/2`, {
      headers: { range: 'bytes=0-' },
    });
    expect(response.status).toBe(416);
    expect(response.headers.get('content-range')).toBe('bytes */0');
  });

  it('renvoie application/octet-stream pour une extension inconnue', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', `${TRACKS}/4`);
    expect(response.headers.get('content-type')).toBe('application/octet-stream');
  });

  it('renvoie 404 FILE_NOT_FOUND si le fichier a disparu', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', `${TRACKS}/3`);
    expect(response.status).toBe(404);
    expect(response.headers.get('x-hs-error-code')).toBe('FILE_NOT_FOUND');
    expect(await response.json()).toMatchObject({ error: 'FILE_NOT_FOUND' });
  });

  it('renvoie 404 TRACK_NOT_INDEXED pour une piste inconnue', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', `${TRACKS}/999`);
    expect(response.headers.get('x-hs-error-code')).toBe('TRACK_NOT_INDEXED');
    expect(await response.json()).toMatchObject({ error: 'TRACK_NOT_INDEXED' });
  });

  it('renvoie 503 INDEX_NOT_LOADED quand aucun index n’est chargé', async () => {
    rmSync(fixture.indexPath);
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', `${TRACKS}/1`);
    expect(response.status).toBe(503);
    expect(response.headers.get('x-hs-error-code')).toBe('INDEX_NOT_LOADED');
    expect(await response.json()).toMatchObject({ error: 'INDEX_NOT_LOADED' });
  });

  it('renvoie 503 MUSIC_ROOT_UNAVAILABLE si la racine musicale a disparu', async () => {
    const agent = await launch({
      configOverrides: { musicRoot: join(fixture.root, 'disque-absent') },
    });
    const response = await signedFetch(agent, 'GET', `${TRACKS}/1`);
    expect(response.status).toBe(503);
    expect(response.headers.get('x-hs-error-code')).toBe('MUSIC_ROOT_UNAVAILABLE');
    expect(await response.json()).toMatchObject({ error: 'MUSIC_ROOT_UNAVAILABLE' });
  });

  it('ne laisse fuiter aucun chemin dans les réponses d’erreur', async () => {
    const agent = await launch();
    for (const path of [`${TRACKS}/3`, `${TRACKS}/999`, `${TRACKS}/abc`]) {
      const response = await signedFetch(agent, 'GET', path);
      const body = await response.text();
      expect(body).not.toContain(fixture.musicRoot);
      expect(body).not.toContain('Piste.flac');
      expect(body).not.toContain('Artiste');
      expect(body).not.toContain(agent.secret);
    }
  });

  it('ne laisse fuiter aucun chemin dans les en-têtes d’une réponse nominale', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', `${TRACKS}/1`);
    const serialized = JSON.stringify([...response.headers.entries()]);
    expect(serialized).not.toContain('Piste.flac');
    expect(serialized).not.toContain('Artiste');
    expect(serialized.toLowerCase()).not.toContain('music');
    await response.arrayBuffer();
  });

  it('gère une erreur disque en cours de flux sans fuite de compteur', async () => {
    const controlled = controlledStream();
    // Les en-têtes ne partent qu'au premier octet écrit : un octet est poussé
    // dès l'ouverture, le reste du flux est piloté par le test.
    const agent = await launch({
      createReadStream: () => {
        setImmediate(() => controlled.push('0123'));
        return controlled.stream;
      },
    });
    const response = await signedFetch(agent, 'GET', `${TRACKS}/1`);
    expect(response.status).toBe(200);
    await waitFor(() => agentRuntime(agent).limiter.activeStreams === 1);

    controlled.fail();
    // Content-Length annonçait 16 octets : la troncature doit faire échouer la
    // lecture côté client plutôt que produire un fichier silencieusement faux.
    await expect(response.arrayBuffer()).rejects.toThrowError();
    await waitFor(() => agentRuntime(agent).limiter.activeStreams === 0);
  });

  it('gère un abandon client et libère l’emplacement', async () => {
    const controlled = controlledStream();
    const agent = await launch({
      createReadStream: () => {
        setImmediate(() => controlled.push('0123'));
        return controlled.stream;
      },
    });
    const controller = new AbortController();
    const response = await signedFetch(agent, 'GET', `${TRACKS}/1`, {
      signal: controller.signal,
    });
    expect(response.status).toBe(200);
    await waitFor(() => agentRuntime(agent).limiter.activeStreams === 1);

    controller.abort();
    await waitFor(() => agentRuntime(agent).limiter.activeStreams === 0);
  });

  it('libère l’emplacement après un téléchargement complet', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', `${TRACKS}/1`);
    await response.arrayBuffer();
    await waitFor(() => agentRuntime(agent).limiter.activeStreams === 0);
  });
});

// ---------------------------------------------------------------------------
// Concurrence
// ---------------------------------------------------------------------------
describe('concurrence', () => {
  it('autorise 8 flux et refuse le neuvième en 503', async () => {
    const controlled: ReturnType<typeof controlledStream>[] = [];
    const agent = await launch({
      createReadStream: () => {
        const stream = controlledStream();
        controlled.push(stream);
        // Un premier octet force l'envoi des en-têtes sans terminer le flux.
        setImmediate(() => stream.push('0'));
        return stream.stream;
      },
    });

    const controller = new AbortController();
    const opened = await Promise.all(
      Array.from({ length: 8 }, () =>
        signedFetch(agent, 'GET', `${TRACKS}/1`, { signal: controller.signal }),
      ),
    );
    expect(opened.map((response) => response.status)).toEqual(Array(8).fill(200));
    await waitFor(() => agentRuntime(agent).limiter.activeStreams === 8);

    const refused = await signedFetch(agent, 'GET', `${TRACKS}/1`);
    expect(refused.status).toBe(503);
    expect(refused.headers.get('retry-after')).toBe('1');
    expect(refused.headers.get('x-hs-error-code')).toBe('STREAM_LIMIT_REACHED');
    expect(await refused.json()).toMatchObject({ error: 'STREAM_LIMIT_REACHED' });

    controller.abort();
    await waitFor(() => agentRuntime(agent).limiter.activeStreams === 0);

    // La capacité est intégralement rendue après libération.
    const afterRelease = await signedFetch(agent, 'GET', `${TRACKS}/1`, {
      headers: { range: 'bytes=0-0' },
    });
    expect([200, 206]).toContain(afterRelease.status);
    controlled.forEach((stream) => stream.push(null as unknown as string));
  });

  it('HEAD et health restent disponibles à saturation', async () => {
    const agent = await launch({
      configOverrides: { maxConcurrentStreams: 1 },
      createReadStream: () => {
        const stream = controlledStream();
        setImmediate(() => stream.push('0'));
        return stream.stream;
      },
    });
    const controller = new AbortController();
    await signedFetch(agent, 'GET', `${TRACKS}/1`, { signal: controller.signal });
    await waitFor(() => agentRuntime(agent).limiter.activeStreams === 1);

    expect((await signedFetch(agent, 'HEAD', `${TRACKS}/1`)).status).toBe(200);
    expect((await signedFetch(agent, 'GET', HEALTH)).status).toBe(200);
    expect((await signedFetch(agent, 'GET', `${TRACKS}/1`)).status).toBe(503);

    controller.abort();
    await waitFor(() => agentRuntime(agent).limiter.activeStreams === 0);
  });
});

// ---------------------------------------------------------------------------
// Health
// ---------------------------------------------------------------------------
describe('GET /internal/storage/health', () => {
  it('état nominal', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', HEALTH);
    expect(response.status).toBe(200);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body).toMatchObject({
      status: 'healthy',
      indexLoaded: true,
      indexVersion: 1,
      indexEntryCount: 4,
      musicRootAvailable: true,
      activeStreams: 0,
      maxConcurrentStreams: 8,
    });
    expect(typeof body.agentVersion).toBe('string');
    expect(typeof body.indexLoadedAt).toBe('string');
    expect(typeof body.uptimeSeconds).toBe('number');
  });

  it('unhealthy (503) sans index valide', async () => {
    rmSync(fixture.indexPath);
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', HEALTH);
    expect(response.status).toBe(503);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body.status).toBe('unhealthy');
    expect(body.indexLoaded).toBe(false);
    expect(body.indexEntryCount).toBe(0);
  });

  it('degraded (200) si MUSIC_ROOT est inaccessible mais l’index reste valide', async () => {
    const agent = await launch({
      configOverrides: { musicRoot: join(fixture.root, 'disque-absent') },
    });
    const response = await signedFetch(agent, 'GET', HEALTH);
    expect(response.status).toBe(200);
    const body = (await response.json()) as Record<string, unknown>;
    expect(body.status).toBe('degraded');
    expect(body.musicRootAvailable).toBe(false);
    expect(body.indexLoaded).toBe(true);
  });

  it('reflète le nombre de flux actifs', async () => {
    const agent = await launch({
      createReadStream: () => {
        const stream = controlledStream();
        setImmediate(() => stream.push('0'));
        return stream.stream;
      },
    });
    const controller = new AbortController();
    await signedFetch(agent, 'GET', `${TRACKS}/1`, { signal: controller.signal });
    await waitFor(() => agentRuntime(agent).limiter.activeStreams === 1);

    const body = (await (await signedFetch(agent, 'GET', HEALTH)).json()) as Record<string, unknown>;
    expect(body.activeStreams).toBe(1);
    controller.abort();
    await waitFor(() => agentRuntime(agent).limiter.activeStreams === 0);
  });

  it('n’expose ni chemin, ni secret, ni configuration', async () => {
    const agent = await launch();
    const raw = await (await signedFetch(agent, 'GET', HEALTH)).text();
    expect(raw).not.toContain(fixture.musicRoot);
    expect(raw).not.toContain(fixture.indexPath);
    expect(raw).not.toContain(agent.secret);
    expect(raw).not.toContain('Artiste');
    expect(raw.toLowerCase()).not.toContain('secret');
    expect(raw.toLowerCase()).not.toContain('musicroot"');
  });

  it('exige une authentification', async () => {
    const agent = await launch();
    expect((await fetch(`${agent.baseUrl}${HEALTH}`)).status).toBe(401);
  });

  it('signale le rechargement d’index après remplacement du fichier', async () => {
    const agent = await launch();
    writeIndex(fixture.indexPath, { 1: 'Artiste/Album/Piste.flac' });
    agentRuntime(agent).indexStore.reloadIfChanged();
    const body = (await (await signedFetch(agent, 'GET', HEALTH)).json()) as Record<string, unknown>;
    expect(body.indexEntryCount).toBe(1);
  });
});

// ---------------------------------------------------------------------------
// Import durable d'objets
// ---------------------------------------------------------------------------
describe('PUT /internal/storage/objects/:sha256.:extension', () => {
  it('publie un objet vérifié, synchronisé et sans exposer de chemin', async () => {
    const agent = await launch();
    const body = Buffer.from('FLAC durable depuis le VPS');
    const object = objectRoute(body);

    const response = await signedFetch(agent, 'PUT', object.path, {
      body,
      headers: { 'content-type': 'application/octet-stream' },
    });

    expect(response.status).toBe(201);
    const receipt = (await response.json()) as Record<string, unknown>;
    expect(receipt).toEqual({
      status: 'stored',
      contentHash: object.hash,
      extension: 'flac',
      sizeBytes: body.length,
      reused: false,
      durable: true,
    });
    expect(JSON.stringify(receipt).toLowerCase()).not.toContain('path');
    expect(
      readFileSync(objectAbsolutePath(fixture.musicRoot, object.hash, 'flac')),
    ).toEqual(body);
  });

  it('est idempotent : le deuxième PUT réutilise le même objet', async () => {
    const agent = await launch();
    const body = Buffer.from('objet idempotent');
    const object = objectRoute(body, 'wav');
    const init = {
      body,
      headers: { 'content-type': 'application/octet-stream' },
    };

    expect((await signedFetch(agent, 'PUT', object.path, init)).status).toBe(201);
    const second = await signedFetch(agent, 'PUT', object.path, init);
    expect(second.status).toBe(200);
    expect(await second.json()).toMatchObject({
      contentHash: object.hash,
      extension: 'wav',
      sizeBytes: body.length,
      reused: true,
      durable: true,
    });
  });

  it('refuse un corps différent de l’empreinte signée et ne publie rien', async () => {
    const agent = await launch();
    const expected = Buffer.from('expected');
    const actual = Buffer.from('modified');
    expect(expected.length).toBe(actual.length);
    const object = objectRoute(expected);
    const headers = buildSignedHeaders({
      secret: agent.secret,
      method: 'PUT',
      pathWithQuery: object.path,
      body: expected,
    });

    const response = await fetch(`${agent.baseUrl}${object.path}`, {
      method: 'PUT',
      headers: {
        ...headers,
        'content-type': 'application/octet-stream',
        'content-length': String(actual.length),
      },
      body: actual,
    });

    expect(response.status).toBe(422);
    expect(response.headers.get('x-hs-error-code')).toBe(
      'OBJECT_HASH_MISMATCH',
    );
    expect(() =>
      statSync(objectAbsolutePath(fixture.musicRoot, object.hash, 'flac')),
    ).toThrow();
  });

  it('refuse une signature qui ne porte pas sur le SHA de la route', async () => {
    const agent = await launch();
    const body = Buffer.from('route-hash-binding');
    const object = objectRoute(body);
    const response = await signedFetch(agent, 'PUT', object.path, {
      body: Buffer.from('autre-contenu---'),
      headers: { 'content-type': 'application/octet-stream' },
    });
    expect(response.status).toBe(401);
    expect(response.headers.get('x-hs-error-code')).toBe('AUTH_INVALID');
  });

  it('refuse avant écriture un objet au-dessus de la borne', async () => {
    const agent = await launch({
      configOverrides: { maxImportBytes: 8 },
    });
    const body = Buffer.alloc(9, 1);
    const object = objectRoute(body);
    const response = await signedFetch(agent, 'PUT', object.path, {
      body,
      headers: { 'content-type': 'application/octet-stream' },
    });
    expect(response.status).toBe(413);
    expect(response.headers.get('x-hs-error-code')).toBe('OBJECT_TOO_LARGE');
  });

  it('exige application/octet-stream et une taille positive', async () => {
    const agent = await launch();
    const body = Buffer.from('typed');
    const object = objectRoute(body);
    const response = await signedFetch(agent, 'PUT', object.path, { body });
    expect(response.status).toBe(400);
    expect(response.headers.get('x-hs-error-code')).toBe('INVALID_OBJECT');
  });

  it('expose les compteurs d’import sans détail de chemin', async () => {
    const agent = await launch();
    const body = (await (await signedFetch(agent, 'GET', HEALTH)).json()) as Record<
      string,
      unknown
    >;
    expect(body.activeImports).toBe(0);
    expect(body.maxConcurrentImports).toBe(2);
    expect(JSON.stringify(body)).not.toContain(fixture.musicRoot);
  });
});

// ---------------------------------------------------------------------------
// Publication durable de l'index
// ---------------------------------------------------------------------------
describe('PUT /internal/storage/index', () => {
  function indexBody(entries: Record<string, string>, generatedAt = new Date().toISOString()): Buffer {
    return Buffer.from(
      JSON.stringify({
        version: 1,
        generatedAt,
        entries: Object.fromEntries(
          Object.entries(entries).map(([id, relativePath]) => [
            id,
            { relativePath },
          ]),
        ),
      }),
      'utf8',
    );
  }

  it('publie l’index, l’installe immédiatement et ne divulgue aucun chemin', async () => {
    const agent = await launch();
    const body = indexBody({
      1: 'Artiste/Album/Piste.flac',
      77: '.homespotify/objects/aa/objet.flac',
    });
    const response = await signedFetch(agent, 'PUT', INDEX, {
      body,
      headers: { 'content-type': 'application/octet-stream' },
    });

    expect(response.status).toBe(200);
    const receipt = (await response.json()) as Record<string, unknown>;
    expect(receipt).toMatchObject({
      status: 'index_stored',
      contentSha256: createHash('sha256').update(body).digest('hex'),
      entryCount: 2,
      durable: true,
    });
    expect(JSON.stringify(receipt).toLowerCase()).not.toContain('path');
    expect(agentRuntime(agent).indexStore.lookup(77)).toBe(
      '.homespotify/objects/aa/objet.flac',
    );
  });

  it('refuse une empreinte différente et conserve l’index précédent', async () => {
    const agent = await launch();
    const body = indexBody({ 9: 'nouveau.flac' });
    const signed = buildSignedHeaders({
      secret: agent.secret,
      method: 'PUT',
      pathWithQuery: INDEX,
      body: Buffer.from('autre document de même but'),
    });
    const response = await fetch(`${agent.baseUrl}${INDEX}`, {
      method: 'PUT',
      headers: {
        ...signed,
        'content-type': 'application/octet-stream',
        'content-length': String(body.length),
      },
      body,
    });

    expect(response.status).toBe(422);
    expect(response.headers.get('x-hs-error-code')).toBe(
      'INDEX_HASH_MISMATCH',
    );
    expect(agentRuntime(agent).indexStore.lookup(1)).toBe(
      'Artiste/Album/Piste.flac',
    );
    expect(agentRuntime(agent).indexStore.lookup(9)).toBeUndefined();
  });

  it('refuse un document invalide sans remplacer l’index actif', async () => {
    const agent = await launch();
    const body = Buffer.from('{ index cassé', 'utf8');
    const response = await signedFetch(agent, 'PUT', INDEX, {
      body,
      headers: { 'content-type': 'application/octet-stream' },
    });

    expect(response.status).toBe(503);
    expect(response.headers.get('x-hs-error-code')).toBe('INDEX_INVALID');
    expect(agentRuntime(agent).indexStore.lookup(1)).toBe(
      'Artiste/Album/Piste.flac',
    );
  });

  it('refuse avant lecture un index au-dessus de la borne', async () => {
    const agent = await launch({
      configOverrides: { maxIndexBytes: 8 },
    });
    const body = Buffer.alloc(9, 1);
    const response = await signedFetch(agent, 'PUT', INDEX, {
      body,
      headers: { 'content-type': 'application/octet-stream' },
    });

    expect(response.status).toBe(413);
    expect(response.headers.get('x-hs-error-code')).toBe('INDEX_TOO_LARGE');
  });
});

// ---------------------------------------------------------------------------
// Surface exposée
// ---------------------------------------------------------------------------
describe('surface HTTP', () => {
  it('n’expose aucune autre route', async () => {
    const agent = await launch();
    for (const path of [
      '/',
      '/internal/storage',
      '/internal/storage/tracks',
      '/internal/storage/objects',
      '/api/tracks/1',
    ]) {
      const response = await signedFetch(agent, 'GET', path);
      expect(response.status).toBe(404);
    }
  });

  it('refuse toute écriture hors des routes contrôlées', async () => {
    const agent = await launch();
    for (const method of ['POST', 'PUT', 'DELETE', 'PATCH']) {
      const response = await fetch(`${agent.baseUrl}${TRACKS}/1`, {
        method,
        headers: buildSignedHeaders({
          secret: agent.secret,
          method,
          pathWithQuery: `${TRACKS}/1`,
        }),
      });
      expect([404, 405]).toContain(response.status);
    }
  });

  it('l’empreinte de corps attendue est celle du corps vide', async () => {
    const agent = await launch();
    const response = await signedFetch(agent, 'GET', HEALTH, {
      headerOverrides: { 'x-hs-content-sha256': EMPTY_BODY_SHA256 },
    });
    expect(response.status).toBe(200);
  });
});
