import { createHash } from 'node:crypto';
import { createServer, type Server } from 'node:http';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';
import type { RemoteStorageConfig } from './remote-config.js';
import {
  StorageAgentClient,
  type StorageAgentWriteError,
} from './storage-agent-client.js';

const secret = 'f'.repeat(64);
const servers: Server[] = [];
const roots: string[] = [];

function config(
  baseUrl: string,
  overrides: Partial<RemoteStorageConfig> = {},
): RemoteStorageConfig {
  return {
    baseUrl,
    sharedSecret: secret,
    connectTimeoutMs: 500,
    headersTimeoutMs: 500,
    bodyIdleTimeoutMs: 500,
    maxConnections: 2,
    ...overrides,
  };
}

async function listen(
  handler: Parameters<typeof createServer>[0],
): Promise<string> {
  const server = createServer(handler);
  servers.push(server);
  await new Promise<void>((resolve) => {
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  if (address === null || typeof address === 'string') {
    throw new Error('adresse inattendue');
  }
  return `http://127.0.0.1:${address.port}`;
}

function audioFile(sizeBytes: number): {
  filePath: string;
  body: Buffer;
  hash: string;
} {
  const root = mkdtempSync(join(tmpdir(), 'hs-client-faults-'));
  roots.push(root);
  const filePath = join(root, 'track.flac');
  const body = Buffer.alloc(sizeBytes, 0x6b);
  writeFileSync(filePath, body);
  return {
    filePath,
    body,
    hash: createHash('sha256').update(body).digest('hex'),
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
          server.closeAllConnections?.();
        }),
    ),
  );
  for (const root of roots.splice(0)) {
    rmSync(root, { recursive: true, force: true });
  }
});

describe('StorageAgentClient — pannes pendant les écritures', () => {
  it('signale une coupure réseau au milieu de l’upload', async () => {
    const input = audioFile(2 * 1024 * 1024);
    const baseUrl = await listen((request) => {
      request.once('data', () => request.socket.destroy());
    });
    const client = new StorageAgentClient(config(baseUrl));

    await expect(
      client.putObject({
        filePath: input.filePath,
        contentHash: input.hash,
        extension: 'flac',
        sizeBytes: input.body.length,
      }),
    ).rejects.toMatchObject({ code: 'NETWORK_ERROR' });
    client.close();
  });

  it('expire si le reçu n’arrive pas après l’envoi complet', async () => {
    const input = audioFile(32 * 1024);
    const baseUrl = await listen((request) => {
      request.resume();
      // Aucun en-tête de réponse : le délai doit commencer après `finish`.
    });
    const client = new StorageAgentClient(
      config(baseUrl, { headersTimeoutMs: 30, bodyIdleTimeoutMs: 200 }),
    );

    await expect(
      client.putObject({
        filePath: input.filePath,
        contentHash: input.hash,
        extension: 'flac',
        sizeBytes: input.body.length,
      }),
    ).rejects.toMatchObject({ code: 'RESPONSE_TIMEOUT' });
    client.close();
  });

  it('arrête le fichier source quand Windows refuse dès les en-têtes', async () => {
    const input = audioFile(16 * 1024 * 1024);
    let bytesObserved = 0;
    const baseUrl = await listen((request, response) => {
      request.on('data', (chunk: Buffer) => {
        bytesObserved += chunk.length;
      });
      response.writeHead(413, {
        'content-type': 'application/json',
        'x-hs-error-code': 'OBJECT_TOO_LARGE',
      });
      response.end('{}');
    });
    const client = new StorageAgentClient(config(baseUrl));

    let observed: StorageAgentWriteError | undefined;
    try {
      await client.putObject({
        filePath: input.filePath,
        contentHash: input.hash,
        extension: 'flac',
        sizeBytes: input.body.length,
      });
    } catch (error) {
      observed = error as StorageAgentWriteError;
    }
    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(observed).toMatchObject({ code: 'AGENT_REJECTED' });
    expect(bytesObserved).toBeLessThan(input.body.length);
    client.close();
  });
});
