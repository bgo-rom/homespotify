import { createHash } from 'node:crypto';
import { existsSync, readdirSync } from 'node:fs';
import { request as httpRequest } from 'node:http';
import { join } from 'node:path';
import { PassThrough, Readable } from 'node:stream';
import { afterEach, describe, expect, it } from 'vitest';
import { buildSignedHeaders } from './hmac-auth.js';
import {
  DurableObjectStore,
  objectAbsolutePath,
} from './object-store.js';
import {
  createFixture,
  removeFixture,
  signedFetch,
  startAgent,
  testConfig,
  type AgentFixture,
  type RunningAgent,
} from './test/harness.js';

const fixtures: AgentFixture[] = [];
const agents: RunningAgent[] = [];

function sha256(body: Buffer): string {
  return createHash('sha256').update(body).digest('hex');
}

async function waitFor(
  predicate: () => boolean,
  timeoutMs = 2_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) {
      throw new Error('condition de test non atteinte');
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

function incomingParts(fixture: AgentFixture): string[] {
  const incoming = join(fixture.musicRoot, '.homespotify', 'incoming');
  if (!existsSync(incoming)) return [];
  return readdirSync(incoming).filter((name) => name.endsWith('.part'));
}

async function launch(
  overrides: Parameters<typeof testConfig>[1] = {},
): Promise<{ fixture: AgentFixture; agent: RunningAgent }> {
  const fixture = createFixture();
  fixtures.push(fixture);
  const agent = await startAgent({
    config: testConfig(fixture, overrides),
    logger: false,
  });
  agents.push(agent);
  return { fixture, agent };
}

async function abortPartialUpload(
  agent: RunningAgent,
  pathWithQuery: string,
  fullBody: Buffer,
): Promise<void> {
  const target = new URL(agent.baseUrl);
  const headers = {
    ...buildSignedHeaders({
      secret: agent.secret,
      method: 'PUT',
      pathWithQuery,
      body: fullBody,
    }),
    'content-type': 'application/octet-stream',
    'content-length': String(fullBody.length),
  };

  await new Promise<void>((resolve, reject) => {
    let settled = false;
    const finish = (error?: Error) => {
      if (settled) return;
      settled = true;
      if (error) reject(error);
      else resolve();
    };
    const request = httpRequest(
      {
        protocol: target.protocol,
        hostname: target.hostname,
        port: target.port,
        method: 'PUT',
        path: pathWithQuery,
        headers,
      },
      (response) => {
        response.resume();
        finish();
      },
    );
    request.once('error', () => finish());
    request.write(fullBody.subarray(0, Math.floor(fullBody.length / 2)), () => {
      setTimeout(() => request.destroy(), 40);
    });
    setTimeout(() => finish(new Error('abandon HTTP non terminé')), 1_500);
  });
}

async function uploadAndDiscardResponse(
  agent: RunningAgent,
  pathWithQuery: string,
  body: Buffer,
): Promise<void> {
  const target = new URL(agent.baseUrl);
  const headers = {
    ...buildSignedHeaders({
      secret: agent.secret,
      method: 'PUT',
      pathWithQuery,
      body,
    }),
    'content-type': 'application/octet-stream',
    'content-length': String(body.length),
  };

  await new Promise<void>((resolve, reject) => {
    const request = httpRequest(
      {
        protocol: target.protocol,
        hostname: target.hostname,
        port: target.port,
        method: 'PUT',
        path: pathWithQuery,
        headers,
      },
      (response) => {
        // Les en-têtes ne sont disponibles qu'après la publication durable.
        // On détruit alors la réponse avant de lire son JSON : le client a
        // perdu le reçu, mais Windows possède déjà l'objet final.
        response.destroy();
        resolve();
      },
    );
    request.once('error', reject);
    request.end(body);
  });
}

afterEach(async () => {
  await Promise.all(agents.splice(0).map((agent) => agent.close()));
  for (const fixture of fixtures.splice(0)) removeFixture(fixture);
});

describe('Storage Agent — matrice de pannes d’import durable', () => {
  it('nettoie le .part après une coupure au milieu du corps', async () => {
    const { fixture, agent } = await launch({ maxImportBytes: 512 * 1024 });
    const body = Buffer.alloc(128 * 1024, 0x5a);
    const hash = sha256(body);
    const pathWithQuery = `/internal/storage/objects/${hash}.flac`;

    await abortPartialUpload(agent, pathWithQuery, body);
    await waitFor(() => agent.app.storageAgent.nonceCache.size === 1);
    await waitFor(
      () =>
        agent.app.storageAgent.objectStore.activeWrites === 0 &&
        agent.app.storageAgent.importLimiter.activeStreams === 0,
    );

    expect(existsSync(objectAbsolutePath(fixture.musicRoot, hash, 'flac'))).toBe(
      false,
    );
    expect(incomingParts(fixture)).toEqual([]);
  });

  it('réutilise l’objet après perte du reçu HTTP', async () => {
    const { fixture, agent } = await launch();
    const body = Buffer.from('objet durable dont le reçu est perdu');
    const hash = sha256(body);
    const pathWithQuery = `/internal/storage/objects/${hash}.flac`;

    await uploadAndDiscardResponse(agent, pathWithQuery, body);
    expect(existsSync(objectAbsolutePath(fixture.musicRoot, hash, 'flac'))).toBe(
      true,
    );

    const retry = await signedFetch(agent, 'PUT', pathWithQuery, {
      body,
      headers: {
        'content-type': 'application/octet-stream',
        'content-length': String(body.length),
      },
    });
    expect(retry.status).toBe(200);
    await expect(retry.json()).resolves.toMatchObject({
      status: 'stored',
      contentHash: hash,
      reused: true,
      durable: true,
    });
    expect(incomingParts(fixture)).toEqual([]);
  });

  it('marque le suiveur concurrent comme réutilisation', async () => {
    const fixture = createFixture();
    fixtures.push(fixture);
    const store = new DurableObjectStore({
      musicRoot: fixture.musicRoot,
      maxBytes: 1024 * 1024,
    });
    const body = Buffer.alloc(64 * 1024, 0x2a);
    const hash = sha256(body);
    const leaderSource = new PassThrough();

    const leader = store.store({
      contentHash: hash,
      extension: 'flac',
      expectedSizeBytes: body.length,
      source: leaderSource,
    });
    leaderSource.write(body.subarray(0, body.length / 2));
    await waitFor(() => store.activeWrites === 1);

    const follower = store.store({
      contentHash: hash,
      extension: 'flac',
      expectedSizeBytes: body.length,
      source: Readable.from(body),
    });
    leaderSource.end(body.subarray(body.length / 2));

    const [leaderReceipt, followerReceipt] = await Promise.all([
      leader,
      follower,
    ]);
    expect(leaderReceipt.reused).toBe(false);
    expect(followerReceipt.reused).toBe(true);
    expect(followerReceipt.contentHash).toBe(leaderReceipt.contentHash);
    expect(incomingParts(fixture)).toEqual([]);
  });

  it('refuse un index plus ancien et conserve l’index actif', async () => {
    const { agent } = await launch();
    const newer = Buffer.from(
      JSON.stringify({
        version: 1,
        generatedAt: '2099-01-02T00:00:00.000Z',
        entries: {
          1: { relativePath: 'Artiste/Album/Piste.flac' },
        },
      }),
    );
    const older = Buffer.from(
      JSON.stringify({
        version: 1,
        generatedAt: '2099-01-01T00:00:00.000Z',
        entries: {},
      }),
    );

    const first = await signedFetch(agent, 'PUT', '/internal/storage/index', {
      body: newer,
      headers: {
        'content-type': 'application/octet-stream',
        'content-length': String(newer.length),
      },
    });
    expect(first.status).toBe(200);

    const stale = await signedFetch(agent, 'PUT', '/internal/storage/index', {
      body: older,
      headers: {
        'content-type': 'application/octet-stream',
        'content-length': String(older.length),
      },
    });
    expect(stale.status).toBe(409);
    expect(stale.headers.get('x-hs-error-code')).toBe('INDEX_STALE_UPLOAD');

    const health = await signedFetch(agent, 'GET', '/internal/storage/health');
    await expect(health.json()).resolves.toMatchObject({
      indexGeneratedAt: '2099-01-02T00:00:00.000Z',
      indexEntryCount: 1,
    });
    const track = await signedFetch(agent, 'GET', '/internal/storage/tracks/1');
    expect(track.status).toBe(200);
    expect(Buffer.from(await track.arrayBuffer())).toEqual(
      Buffer.from('0123456789ABCDEF'),
    );
  });
});
