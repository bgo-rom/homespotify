/**
 * Banc d'essai HTTP du Storage Agent.
 *
 * Contraintes de test imposées par la Phase 2 :
 * - écoute sur 127.0.0.1 uniquement ;
 * - port ÉPHÉMÈRE (`port: 0`) — jamais 3100, jamais 0.0.0.0 ;
 * - aucun processus laissé en écoute : `close()` est appelé en `afterEach`.
 */
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import type { StorageAgentConfig } from '../config.js';
import { buildSignedHeaders } from '../hmac-auth.js';
import {
  buildStorageAgent,
  type BuildStorageAgentOptions,
  type StorageAgentInstance,
} from '../server.js';

/** 16 octets identifiables, pour vérifier les plages octet par octet. */
export const TRACK_CONTENT = Buffer.from('0123456789ABCDEF');
export const TEST_SECRET = 'a'.repeat(64);

export interface AgentFixture {
  root: string;
  musicRoot: string;
  indexPath: string;
}

/** Crée une arborescence musicale jetable + un index valide. */
export function createFixture(): AgentFixture {
  const root = mkdtempSync(join(tmpdir(), 'hs-storage-agent-'));
  const musicRoot = join(root, 'music');
  mkdirSync(join(musicRoot, 'Artiste', 'Album'), { recursive: true });
  writeFileSync(join(musicRoot, 'Artiste', 'Album', 'Piste.flac'), TRACK_CONTENT);
  writeFileSync(join(musicRoot, 'Artiste', 'Album', 'Vide.flac'), Buffer.alloc(0));
  writeFileSync(join(musicRoot, 'Artiste', 'Album', 'Sans extension'), TRACK_CONTENT);
  // Fichier hors racine : ne doit jamais être atteignable.
  writeFileSync(join(root, 'secret.txt'), 'jamais servi');

  const indexPath = join(root, 'index.json');
  writeIndex(indexPath, {
    1: 'Artiste/Album/Piste.flac',
    2: 'Artiste/Album/Vide.flac',
    3: 'Artiste/Album/Absent.flac',
    4: 'Artiste/Album/Sans extension',
  });
  return { root, musicRoot, indexPath };
}

export function writeIndex(indexPath: string, entries: Record<string, string>): void {
  writeFileSync(
    indexPath,
    JSON.stringify({
      version: 1,
      generatedAt: new Date().toISOString(),
      entries: Object.fromEntries(
        Object.entries(entries).map(([id, relativePath]) => [id, { relativePath }]),
      ),
    }),
    'utf-8',
  );
}

export function removeFixture(fixture: AgentFixture): void {
  rmSync(fixture.root, { recursive: true, force: true });
}

export function testConfig(
  fixture: AgentFixture,
  overrides: Partial<StorageAgentConfig> = {},
): StorageAgentConfig {
  return {
    nodeEnv: 'test',
    host: '127.0.0.1',
    // 0 = port éphémère attribué par l'OS.
    port: 0,
    musicRoot: fixture.musicRoot,
    indexPath: fixture.indexPath,
    sharedSecret: TEST_SECRET,
    // 127.0.0.1 explicitement autorisée pour les tests, jamais par défaut.
    allowedRemoteIps: ['127.0.0.1'],
    maxConcurrentStreams: 8,
    maxConcurrentImports: 2,
    maxImportBytes: 1024 * 1024,
    hmacMaxClockSkewSeconds: 60,
    logLevel: 'fatal',
    indexPollIntervalMs: 0,
    ...overrides,
  };
}

export interface RunningAgent {
  app: StorageAgentInstance;
  baseUrl: string;
  secret: string;
  close: () => Promise<void>;
}

export async function startAgent(
  options: BuildStorageAgentOptions,
): Promise<RunningAgent> {
  const app = buildStorageAgent({
    ...options,
    logger: options.logger ?? false,
  });
  await app.listen({ host: '127.0.0.1', port: 0 });
  const address = app.server.address();
  if (address === null || typeof address === 'string') {
    throw new Error('Adresse d’écoute inattendue.');
  }
  return {
    app,
    baseUrl: `http://127.0.0.1:${address.port}`,
    secret: options.config.sharedSecret,
    close: async () => {
      await app.close();
    },
  };
}

/** Requête signée valide. `headerOverrides` permet de casser un seul élément. */
export async function signedFetch(
  agent: RunningAgent,
  method: 'GET' | 'HEAD' | 'PUT',
  pathWithQuery: string,
  init: {
    headers?: Record<string, string>;
    body?: Buffer;
    headerOverrides?: Record<string, string | null>;
    secret?: string;
    signedPath?: string;
    signedMethod?: string;
    timestamp?: number;
    nonce?: string;
    signal?: AbortSignal;
  } = {},
): Promise<Response> {
  const headers: Record<string, string> = {
    ...buildSignedHeaders({
      secret: init.secret ?? agent.secret,
      method: init.signedMethod ?? method,
      pathWithQuery: init.signedPath ?? pathWithQuery,
      ...(init.timestamp !== undefined ? { timestamp: init.timestamp } : {}),
      ...(init.nonce !== undefined ? { nonce: init.nonce } : {}),
      ...(init.body !== undefined ? { body: init.body } : {}),
    }),
    ...(init.headers ?? {}),
  };
  for (const [name, value] of Object.entries(init.headerOverrides ?? {})) {
    if (value === null) delete headers[name];
    else headers[name] = value;
  }
  return fetch(`${agent.baseUrl}${pathWithQuery}`, {
    method,
    headers,
    ...(init.body === undefined ? {} : { body: init.body }),
    ...(init.signal ? { signal: init.signal } : {}),
  });
}
