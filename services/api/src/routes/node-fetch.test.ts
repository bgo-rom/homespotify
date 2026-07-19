import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import type { FastifyInstance } from 'fastify';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { buildApp } from '../app.js';
import type { AppConfig } from '../config.js';
import { tracks } from '../db/schema.js';

let root: string;
let app: FastifyInstance;
let fetchHandler: (url: string) => Promise<Response>;
let fetchCalls: string[];

function testConfig(): AppConfig {
  return {
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
    refreshTokenTtlSeconds: 86_400,
    nodeFetch: {
      allowedOrigins: ['https://node.example'],
      mediaAllowedOrigins: ['https://cdn.example'],
      remoteSearchPathTemplate: '/search?q={query}',
      remoteResolvePathTemplate: '/api/download?trackId={trackId}',
      metadataTimeoutMs: 5_000,
      maxBytes: 8,
      timeoutMs: 60_000,
      maxConcurrentJobs: 1,
      maxQueuedJobs: 4,
    },
  };
}

beforeEach(async () => {
  root = mkdtempSync(join(tmpdir(), 'homespotify-node-fetch-'));
  fetchCalls = [];
  fetchHandler = async () => new Response(Buffer.from('fLaC'), {
    status: 200,
    headers: {
      'content-type': 'audio/flac',
      'content-length': '4',
    },
  });
  const fetchImpl: typeof globalThis.fetch = async (input) => {
    const url = input instanceof URL
      ? input.toString()
      : typeof input === 'string'
        ? input
        : input.url;
    fetchCalls.push(url);
    return fetchHandler(url);
  };
  app = buildApp(testConfig(), {
    importWatcher: false,
    nodeFetchHttpClient: fetchImpl,
  });
  await app.ready();
});

afterEach(async () => {
  await app.close();
  rmSync(root, { recursive: true, force: true });
});

async function bootstrap(): Promise<{ token: string; userId: number }> {
  const password = 'owner-password-123';
  const response = await app.inject({
    method: 'POST',
    url: '/api/auth/bootstrap',
    payload: {
      username: 'owner',
      displayName: 'Owner',
      password,
      passwordConfirmation: password,
    },
  });
  expect(response.statusCode).toBe(201);
  return {
    token: response.json().accessToken as string,
    userId: response.json().user.id as number,
  };
}

async function waitForTerminalJob(
  token: string,
  jobId: string,
  statusPath = '/api/library/fetch-node',
) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const response = await app.inject({
      method: 'GET',
      url: `${statusPath}/${jobId}`,
      headers: { authorization: `Bearer ${token}` },
    });
    expect(response.statusCode).toBe(200);
    const job = response.json().job as { status: string };
    if (job.status === 'READY_FOR_IMPORT' || job.status === 'FAILED') return response.json().job;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error('La tâche fetch-node n’a pas atteint un état terminal.');
}

describe('routes fetch-node', () => {
  it('répond 202 avant le flux puis dépose atomiquement dans l’inbox', async () => {
    const { token, userId } = await bootstrap();
    let release: (() => void) | undefined;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    fetchHandler = async () => {
      await gate;
      return new Response(Buffer.from('fLaC'), {
        status: 200,
        headers: { 'content-type': 'audio/flac', 'content-length': '4' },
      });
    };

    const accepted = await app.inject({
      method: 'POST',
      url: '/api/library/fetch-node',
      headers: { authorization: `Bearer ${token}` },
      payload: { url: 'https://node.example/audio/Test%20Track.flac', userId },
    });
    expect(accepted.statusCode).toBe(202);
    expect(accepted.json().message).toContain('traitement en arrière-plan');
    const jobId = accepted.json().job.id as string;
    release?.();

    const job = await waitForTerminalJob(token, jobId) as {
      status: string;
      filename: string;
      bytesReceived: number;
    };
    expect(job.status).toBe('READY_FOR_IMPORT');
    expect(job.bytesReceived).toBe(4);
    expect(job.filename).toMatch(/^Test Track-[a-f0-9]{8}\.flac$/);
    const inbox = join(root, 'imports', `${userId}_owner`, 'inbox');
    const files = readdirSync(inbox);
    expect(files).toEqual([job.filename]);
    expect(files.some((name) => name.endsWith('.part'))).toBe(false);
    expect(readFileSync(join(inbox, job.filename))).toEqual(Buffer.from('fLaC'));
    // Cette route ne crée aucune piste : seul le watcher d’import en a le droit.
    expect(app.dbHandle.db.select().from(tracks).all()).toHaveLength(0);
  });

  it('dérive la destination du token et refuse un autre userId', async () => {
    const { token, userId } = await bootstrap();
    const response = await app.inject({
      method: 'POST',
      url: '/api/library/fetch-node',
      headers: { authorization: `Bearer ${token}` },
      payload: { url: 'https://node.example/audio/a.flac', userId: userId + 1 },
    });
    expect(response.statusCode).toBe(403);
    expect(response.json().error).toBe('target_user_forbidden');
    expect(fetchCalls).toHaveLength(0);
  });

  it('refuse une origine absente de l’allowlist avant tout appel réseau', async () => {
    const { token, userId } = await bootstrap();
    const response = await app.inject({
      method: 'POST',
      url: '/api/library/fetch-node',
      headers: { authorization: `Bearer ${token}` },
      payload: { url: 'https://untrusted.example/audio/a.flac', userId },
    });
    expect(response.statusCode).toBe(403);
    expect(response.json().error).toBe('source_origin_not_allowed');
    expect(fetchCalls).toHaveLength(0);
  });

  it('interrompt un flux qui dépasse la limite et supprime le .part', async () => {
    const { token, userId } = await bootstrap();
    fetchHandler = async () => new Response(Buffer.alloc(9, 1), {
      status: 200,
      headers: { 'content-type': 'audio/flac' },
    });
    const accepted = await app.inject({
      method: 'POST',
      url: '/api/library/fetch-node',
      headers: { authorization: `Bearer ${token}` },
      payload: { url: 'https://node.example/audio/large.flac', userId },
    });
    const job = await waitForTerminalJob(token, accepted.json().job.id as string) as {
      status: string;
      errorCode: string;
    };
    expect(job.status).toBe('FAILED');
    expect(job.errorCode).toBe('source_too_large');
    const inbox = join(root, 'imports', `${userId}_owner`, 'inbox');
    expect(existsSync(inbox)).toBe(true);
    expect(readdirSync(inbox)).toEqual([]);
  });

  it('revalide chaque redirection contre l’allowlist', async () => {
    const { token, userId } = await bootstrap();
    fetchHandler = async () => new Response(null, {
      status: 302,
      headers: { location: 'https://untrusted.example/audio/a.flac' },
    });
    const accepted = await app.inject({
      method: 'POST',
      url: '/api/library/fetch-node',
      headers: { authorization: `Bearer ${token}` },
      payload: { url: 'https://node.example/redirect', userId },
    });
    const job = await waitForTerminalJob(token, accepted.json().job.id as string) as {
      status: string;
      errorCode: string;
    };
    expect(job.status).toBe('FAILED');
    expect(job.errorCode).toBe('source_origin_not_allowed');
    expect(fetchCalls).toEqual(['https://node.example/redirect']);
  });
});

describe('routes bibliothèque distante', () => {
  it('recherche sur le premier nœud et normalise les résultats JSON', async () => {
    const { token } = await bootstrap();
    fetchHandler = async () => new Response(JSON.stringify({
      tracks: {
        items: [
          {
            id: 123,
            title: 'Titre distant',
            artists: [{ name: 'Artiste distant' }],
            album: { coverArt: 'cover-uuid-123' },
          },
        ],
      },
    }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });

    const response = await app.inject({
      method: 'GET',
      url: '/api/library/search-remote?q=Titre%20distant',
      headers: { authorization: `Bearer ${token}` },
    });

    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({
      results: [{
        trackId: '123',
        title: 'Titre distant',
        artist: 'Artiste distant',
        coverUrl: 'cover-uuid-123',
      }],
    });
    expect(fetchCalls).toEqual([
      'https://node.example/search?q=Titre%20distant',
    ]);
  });

  it('renvoie 200 avec un tableau vide si la structure distante est inconnue', async () => {
    const { token } = await bootstrap();
    fetchHandler = async () => new Response(JSON.stringify({ data: { values: [] } }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
    const response = await app.inject({
      method: 'GET',
      url: '/api/library/search-remote?q=Inconnue',
      headers: { authorization: `Bearer ${token}` },
    });
    expect(response.statusCode).toBe(200);
    expect(response.json()).toEqual({ results: [] });
  });

  it('résout le trackId puis dépose uniquement un vrai flux FLAC', async () => {
    const { token, userId } = await bootstrap();
    fetchHandler = async (url) => {
      if (url.startsWith('https://node.example/api/download?')) {
        return new Response(JSON.stringify({
          downloadUrl: 'https://cdn.example/media/dynamic.mp4?signature=test',
        }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        });
      }
      return new Response(Buffer.from('fLaCdata'), {
        status: 200,
        headers: { 'content-type': 'application/octet-stream', 'content-length': '8' },
      });
    };

    const accepted = await app.inject({
      method: 'POST',
      url: '/api/library/import-remote-track',
      headers: { authorization: `Bearer ${token}` },
      payload: { trackId: 'track-1' },
    });
    expect(accepted.statusCode).toBe(202);
    const job = await waitForTerminalJob(
      token,
      accepted.json().job.id as string,
      '/api/library/import-remote-track',
    ) as { status: string; filename: string; bytesReceived: number };

    expect(job.status).toBe('READY_FOR_IMPORT');
    expect(job.filename).toMatch(/^dynamic-[a-f0-9]{8}\.flac$/);
    expect(job.bytesReceived).toBe(8);
    const inbox = join(root, 'imports', `${userId}_owner`, 'inbox');
    expect(readFileSync(join(inbox, job.filename))).toEqual(Buffer.from('fLaCdata'));
    expect(app.dbHandle.db.select().from(tracks).all()).toHaveLength(0);
  });

  it('refuse une URL média résolue hors allowlist avant de la télécharger', async () => {
    const { token } = await bootstrap();
    fetchHandler = async () => new Response(JSON.stringify({
      downloadUrl: 'https://untrusted.example/media/file.flac',
    }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
    const accepted = await app.inject({
      method: 'POST',
      url: '/api/library/import-remote-track',
      headers: { authorization: `Bearer ${token}` },
      payload: { trackId: 'track-2' },
    });
    const job = await waitForTerminalJob(
      token,
      accepted.json().job.id as string,
      '/api/library/import-remote-track',
    ) as { status: string; errorCode: string };
    expect(job.status).toBe('FAILED');
    expect(job.errorCode).toBe('remote_media_origin_not_allowed');
    expect(fetchCalls).toEqual([
      'https://node.example/api/download?trackId=track-2',
    ]);
  });

  it('refuse un conteneur MP4 même si le CDN annonce octet-stream', async () => {
    const { token, userId } = await bootstrap();
    fetchHandler = async (url) => url.startsWith('https://node.example/')
      ? new Response(JSON.stringify({
          downloadUrl: 'https://cdn.example/media/not-a-flac.mp4',
        }), {
          status: 200,
          headers: { 'content-type': 'application/json' },
        })
      : new Response(Buffer.from('....ftyp'), {
          status: 200,
          headers: { 'content-type': 'application/octet-stream' },
        });
    const accepted = await app.inject({
      method: 'POST',
      url: '/api/library/import-remote-track',
      headers: { authorization: `Bearer ${token}` },
      payload: { trackId: 'track-3' },
    });
    const job = await waitForTerminalJob(
      token,
      accepted.json().job.id as string,
      '/api/library/import-remote-track',
    ) as { status: string; errorCode: string };
    expect(job.status).toBe('FAILED');
    expect(job.errorCode).toBe('source_audio_type_invalid');
    const inbox = join(root, 'imports', `${userId}_owner`, 'inbox');
    expect(readdirSync(inbox)).toEqual([]);
  });
});
