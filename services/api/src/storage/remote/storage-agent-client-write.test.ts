import { createHash, createHmac } from 'node:crypto';
import { createServer, type IncomingMessage, type Server } from 'node:http';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import type { RemoteStorageConfig } from './remote-config.js';
import {
  StorageAgentClient,
  StorageAgentWriteError,
} from './storage-agent-client.js';

const secret = 's'.repeat(64);
const servers: Server[] = [];
const roots: string[] = [];

async function readBody(request: IncomingMessage): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of request) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  return Buffer.concat(chunks);
}

function config(baseUrl: string): RemoteStorageConfig {
  return {
    baseUrl,
    sharedSecret: secret,
    connectTimeoutMs: 1_000,
    headersTimeoutMs: 1_000,
    bodyIdleTimeoutMs: 1_000,
    maxConnections: 2,
  };
}

async function listen(
  handler: Parameters<typeof createServer>[0],
): Promise<{ baseUrl: string; close: () => Promise<void> }> {
  const server = createServer(handler);
  servers.push(server);
  await new Promise<void>((resolve) => {
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  if (address === null || typeof address === 'string') {
    throw new Error('adresse inattendue');
  }
  return {
    baseUrl: `http://127.0.0.1:${address.port}`,
    close: () =>
      new Promise<void>((resolve, reject) => {
        server.close((error) => (error ? reject(error) : resolve()));
      }),
  };
}

afterEach(async () => {
  await Promise.all(
    servers.splice(0).map(
      (server) =>
        new Promise<void>((resolve) => {
          if (!server.listening) {
            resolve();
            return;
          }
          server.close(() => resolve());
        }),
    ),
  );
  for (const root of roots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

describe('StorageAgentClient — écritures durables', () => {
  it('envoie un objet en streaming avec SHA, taille et HMAC liés', async () => {
    const root = mkdtempSync(join(tmpdir(), 'hs-client-write-'));
    roots.push(root);
    const filePath = join(root, 'track.flac');
    const body = Buffer.from('objet audio durable');
    writeFileSync(filePath, body);
    const hash = createHash('sha256').update(body).digest('hex');
    let observedBody = Buffer.alloc(0);
    let observedPath = '';
    let observedContentHash = '';

    const running = await listen(async (request, response) => {
      observedPath = request.url ?? '';
      observedContentHash = String(
        request.headers['x-hs-content-sha256'] ?? '',
      );
      observedBody = await readBody(request);
      response.writeHead(201, { 'content-type': 'application/json' });
      response.end(
        JSON.stringify({
          status: 'stored',
          contentHash: hash,
          extension: 'flac',
          sizeBytes: body.length,
          reused: false,
          durable: true,
        }),
      );
    });
    const client = new StorageAgentClient(config(running.baseUrl));
    const receipt = await client.putObject({
      filePath,
      contentHash: hash,
      extension: 'flac',
      sizeBytes: body.length,
      requestId: 'download-test-1',
    });

    expect(receipt.durable).toBe(true);
    expect(observedPath).toBe(
      `/internal/storage/objects/${hash}.flac`,
    );
    expect(observedContentHash).toBe(hash);
    expect(observedBody).toEqual(body);
    client.close();
  });

  it('publie un index borné et valide son reçu', async () => {
    const body = Buffer.from(
      JSON.stringify({
        version: 1,
        generatedAt: '2026-08-03T20:00:00.000Z',
        entries: {},
      }),
    );
    const hash = createHash('sha256').update(body).digest('hex');
    let observed = Buffer.alloc(0);
    const running = await listen(async (request, response) => {
      observed = await readBody(request);
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(
        JSON.stringify({
          status: 'index_stored',
          contentSha256: hash,
          entryCount: 0,
          generatedAt: '2026-08-03T20:00:00.000Z',
          durable: true,
        }),
      );
    });
    const client = new StorageAgentClient(config(running.baseUrl));
    const receipt = await client.putIndex({
      body,
      contentSha256: hash,
    });

    expect(receipt.entryCount).toBe(0);
    expect(observed).toEqual(body);
    client.close();
  });

  it('refuse un reçu qui ne confirme pas la durabilité', async () => {
    const root = mkdtempSync(join(tmpdir(), 'hs-client-bad-receipt-'));
    roots.push(root);
    const filePath = join(root, 'track.flac');
    const body = Buffer.from('objet');
    writeFileSync(filePath, body);
    const hash = createHash('sha256').update(body).digest('hex');

    const running = await listen(async (request, response) => {
      await readBody(request);
      response.writeHead(201, { 'content-type': 'application/json' });
      response.end(
        JSON.stringify({
          status: 'stored',
          contentHash: hash,
          extension: 'flac',
          sizeBytes: body.length,
          reused: false,
          durable: false,
        }),
      );
    });
    const client = new StorageAgentClient(config(running.baseUrl));

    await expect(
      client.putObject({
        filePath,
        contentHash: hash,
        extension: 'flac',
        sizeBytes: body.length,
      }),
    ).rejects.toBeInstanceOf(StorageAgentWriteError);
    client.close();
  });

  it('signale une réponse perdue après réception du corps', async () => {
    const body = Buffer.from(
      JSON.stringify({
        version: 1,
        generatedAt: '2026-08-03T20:00:00.000Z',
        entries: {},
      }),
    );
    const hash = createHash('sha256').update(body).digest('hex');
    const running = await listen(async (request) => {
      await readBody(request);
      request.socket.destroy();
    });
    const client = new StorageAgentClient(config(running.baseUrl));

    await expect(
      client.putIndex({ body, contentSha256: hash }),
    ).rejects.toBeInstanceOf(StorageAgentWriteError);
    client.close();
  });
});
