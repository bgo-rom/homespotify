import { createReadStream } from 'node:fs';
import {
  Agent,
  request as httpRequest,
  type ClientRequest,
  type IncomingMessage,
  type RequestOptions,
} from 'node:http';
import { Readable, Transform, type TransformCallback } from 'node:stream';
import {
  AudioStorageError,
  type AudioStorageErrorCode,
  type ByteRange,
} from '../audio-storage.js';
import type { RemoteStorageConfig } from './remote-config.js';
import { agentResponseError } from './agent-error-mapping.js';
import { buildSignedHeaders } from './hmac-client.js';

const SAFE_REQUEST_ID = /^[A-Za-z0-9._:-]{1,96}$/;
const SHA256 = /^[a-f0-9]{64}$/;
const MAX_RECEIPT_BYTES = 64 * 1024;

export interface RemoteLogger {
  info(fields: Record<string, unknown>, message: string): void;
  warn(fields: Record<string, unknown>, message: string): void;
  error(fields: Record<string, unknown>, message: string): void;
}

export const SILENT_REMOTE_LOGGER: RemoteLogger = {
  info() {},
  warn() {},
  error() {},
};

export interface AgentResponse {
  response: IncomingMessage;
  statusCode: number;
  durationMs: number;
}

export interface DurableObjectReceipt {
  status: 'stored';
  contentHash: string;
  extension: 'flac' | 'wav';
  sizeBytes: number;
  reused: boolean;
  durable: true;
}

export interface DurableIndexReceipt {
  status: 'index_stored';
  contentSha256: string;
  entryCount: number;
  generatedAt: string;
  durable: true;
}

export class StorageAgentWriteError extends Error {
  constructor(
    readonly code:
      | 'INVALID_INPUT'
      | 'AGENT_REJECTED'
      | 'INVALID_RECEIPT'
      | 'RESPONSE_TOO_LARGE'
      | 'RESPONSE_TIMEOUT'
      | 'NETWORK_ERROR',
    message: string,
    override readonly cause?: unknown,
  ) {
    super(message);
    this.name = 'StorageAgentWriteError';
  }
}

function safeRequestId(value: string | undefined): string | undefined {
  return value !== undefined && SAFE_REQUEST_ID.test(value) ? value : undefined;
}

function asHeader(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? undefined : value;
}

function typedNetworkError(error: unknown): AudioStorageError {
  if (error instanceof AudioStorageError) return error;
  return new AudioStorageError(
    'AGENT_UNAVAILABLE',
    'Le Storage Agent est injoignable.',
    error,
  );
}

function validateHash(value: string): string {
  const normalized = value.toLowerCase();
  if (!SHA256.test(normalized)) {
    throw new StorageAgentWriteError(
      'INVALID_INPUT',
      'Empreinte SHA-256 invalide.',
    );
  }
  return normalized;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

async function readReceipt(
  response: IncomingMessage,
  idleTimeoutMs: number,
): Promise<unknown> {
  let timer: NodeJS.Timeout | undefined;
  const arm = () => {
    if (timer !== undefined) clearTimeout(timer);
    timer = setTimeout(() => {
      response.destroy(
        new StorageAgentWriteError(
          'RESPONSE_TIMEOUT',
          'Le reçu du Storage Agent a expiré.',
        ),
      );
    }, idleTimeoutMs);
    timer.unref();
  };

  const chunks: Buffer[] = [];
  let bytes = 0;
  arm();
  try {
    for await (const chunk of response) {
      arm();
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      bytes += buffer.length;
      if (bytes > MAX_RECEIPT_BYTES) {
        throw new StorageAgentWriteError(
          'RESPONSE_TOO_LARGE',
          'Le reçu du Storage Agent est trop volumineux.',
        );
      }
      chunks.push(buffer);
    }
  } catch (error) {
    if (error instanceof StorageAgentWriteError) throw error;
    throw new StorageAgentWriteError(
      'NETWORK_ERROR',
      'Lecture du reçu du Storage Agent interrompue.',
      error,
    );
  } finally {
    if (timer !== undefined) clearTimeout(timer);
  }

  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8')) as unknown;
  } catch (error) {
    throw new StorageAgentWriteError(
      'INVALID_RECEIPT',
      'Le reçu du Storage Agent n’est pas un JSON valide.',
      error,
    );
  }
}

export class StorageAgentClient {
  private readonly baseUrl: URL;
  private readonly agent: Agent;

  constructor(
    private readonly config: RemoteStorageConfig,
    private readonly logger: RemoteLogger = SILENT_REMOTE_LOGGER,
  ) {
    this.baseUrl = new URL(config.baseUrl);
    this.agent = new Agent({
      keepAlive: true,
      maxSockets: config.maxConnections,
      maxFreeSockets: config.maxConnections,
      scheduling: 'lifo',
    });
  }

  close(): void {
    this.agent.destroy();
  }

  async head(pathWithQuery: string, requestId?: string): Promise<AgentResponse> {
    return this.request('HEAD', pathWithQuery, undefined, requestId);
  }

  async get(
    pathWithQuery: string,
    range: ByteRange | undefined,
    requestId?: string,
  ): Promise<AgentResponse> {
    return this.request('GET', pathWithQuery, range, requestId);
  }

  async health(requestId?: string): Promise<AgentResponse> {
    return this.request(
      'GET',
      '/internal/storage/health',
      undefined,
      requestId,
    );
  }

  async putObject(input: {
    filePath: string;
    contentHash: string;
    extension: 'flac' | 'wav';
    sizeBytes: number;
    requestId?: string;
  }): Promise<DurableObjectReceipt> {
    const contentHash = validateHash(input.contentHash);
    if (
      (input.extension !== 'flac' && input.extension !== 'wav') ||
      !Number.isSafeInteger(input.sizeBytes) ||
      input.sizeBytes <= 0
    ) {
      throw new StorageAgentWriteError(
        'INVALID_INPUT',
        'Descripteur d’objet audio invalide.',
      );
    }

    const pathWithQuery =
      `/internal/storage/objects/${contentHash}.${input.extension}`;
    const receipt = await this.upload({
      pathWithQuery,
      contentSha256: contentHash,
      contentLength: input.sizeBytes,
      source: createReadStream(input.filePath, {
        highWaterMark: 256 * 1024,
      }),
      ...(input.requestId === undefined
        ? {}
        : { requestId: input.requestId }),
    });

    if (
      !isPlainObject(receipt) ||
      receipt.status !== 'stored' ||
      receipt.contentHash !== contentHash ||
      receipt.extension !== input.extension ||
      receipt.sizeBytes !== input.sizeBytes ||
      typeof receipt.reused !== 'boolean' ||
      receipt.durable !== true
    ) {
      throw new StorageAgentWriteError(
        'INVALID_RECEIPT',
        'Le reçu durable de l’objet est incohérent.',
      );
    }
    return receipt as unknown as DurableObjectReceipt;
  }

  async putIndex(input: {
    body: Buffer;
    contentSha256: string;
    requestId?: string;
  }): Promise<DurableIndexReceipt> {
    const contentSha256 = validateHash(input.contentSha256);
    if (input.body.length <= 0) {
      throw new StorageAgentWriteError(
        'INVALID_INPUT',
        'Document d’index vide.',
      );
    }

    const receipt = await this.upload({
      pathWithQuery: '/internal/storage/index',
      contentSha256,
      contentLength: input.body.length,
      source: Readable.from(input.body),
      ...(input.requestId === undefined
        ? {}
        : { requestId: input.requestId }),
    });

    if (
      !isPlainObject(receipt) ||
      receipt.status !== 'index_stored' ||
      receipt.contentSha256 !== contentSha256 ||
      !Number.isSafeInteger(receipt.entryCount) ||
      (receipt.entryCount as number) < 0 ||
      typeof receipt.generatedAt !== 'string' ||
      Number.isNaN(Date.parse(receipt.generatedAt as string)) ||
      receipt.durable !== true
    ) {
      throw new StorageAgentWriteError(
        'INVALID_RECEIPT',
        'Le reçu durable de l’index est incohérent.',
      );
    }
    return receipt as unknown as DurableIndexReceipt;
  }

  createGuardedBody(
    response: IncomingMessage,
    expectedBytes: number,
    fields: Record<string, unknown>,
  ): Transform {
    return new GuardedRemoteBody(
      response,
      expectedBytes,
      this.config.bodyIdleTimeoutMs,
      this.logger,
      fields,
    );
  }

  private request(
    method: 'GET' | 'HEAD',
    pathWithQuery: string,
    range: ByteRange | undefined,
    requestId: string | undefined,
  ): Promise<AgentResponse> {
    const startedAt = performance.now();
    const forwardedRequestId = safeRequestId(requestId);
    const signedHeaders = buildSignedHeaders({
      secret: this.config.sharedSecret,
      method,
      pathWithQuery,
      ...(forwardedRequestId === undefined
        ? {}
        : { requestId: forwardedRequestId }),
    });
    const options: RequestOptions = {
      protocol: this.baseUrl.protocol,
      hostname: this.baseUrl.hostname,
      port: this.baseUrl.port,
      method,
      path: pathWithQuery,
      agent: this.agent,
      headers: {
        ...signedHeaders,
        ...(range === undefined
          ? {}
          : { range: `bytes=${range.start}-${range.end}` }),
      },
    };

    return new Promise<AgentResponse>((resolve, reject) => {
      let request: ClientRequest;
      let connectTimer: NodeJS.Timeout | undefined;
      let headersTimer: NodeJS.Timeout | undefined;
      let settled = false;

      const clearTimers = () => {
        if (connectTimer !== undefined) clearTimeout(connectTimer);
        if (headersTimer !== undefined) clearTimeout(headersTimer);
      };
      const fail = (error: unknown) => {
        if (settled) return;
        settled = true;
        clearTimers();
        reject(typedNetworkError(error));
      };
      const startHeadersTimer = () => {
        if (headersTimer !== undefined) return;
        headersTimer = setTimeout(() => {
          request.destroy(
            new AudioStorageError(
              'HEADERS_TIMEOUT',
              'Le Storage Agent n’a pas envoyé ses en-têtes à temps.',
            ),
          );
        }, this.config.headersTimeoutMs);
        headersTimer.unref();
      };

      request = httpRequest(options, (response) => {
        if (settled) {
          response.destroy();
          return;
        }
        settled = true;
        clearTimers();
        const statusCode = response.statusCode ?? 0;
        if (statusCode < 200 || statusCode >= 300) {
          const rawCode = asHeader(response.headers['x-hs-error-code']);
          response.resume();
          reject(agentResponseError(statusCode, rawCode));
          return;
        }
        resolve({
          response,
          statusCode,
          durationMs: performance.now() - startedAt,
        });
      });

      connectTimer = setTimeout(() => {
        request.destroy(
          new AudioStorageError(
            'CONNECT_TIMEOUT',
            'Connexion au Storage Agent expirée.',
          ),
        );
      }, this.config.connectTimeoutMs);
      connectTimer.unref();

      request.once('socket', (socket) => {
        if (socket.connecting) {
          socket.once('connect', () => {
            if (connectTimer !== undefined) clearTimeout(connectTimer);
            startHeadersTimer();
          });
        } else {
          if (connectTimer !== undefined) clearTimeout(connectTimer);
          startHeadersTimer();
        }
      });
      request.once('error', fail);
      request.end();
    });
  }

  private upload(input: {
    pathWithQuery: string;
    contentSha256: string;
    contentLength: number;
    source: Readable;
    requestId?: string;
  }): Promise<unknown> {
    const startedAt = performance.now();
    const forwardedRequestId = safeRequestId(input.requestId);
    const signedHeaders = buildSignedHeaders({
      secret: this.config.sharedSecret,
      method: 'PUT',
      pathWithQuery: input.pathWithQuery,
      contentSha256: input.contentSha256,
      ...(forwardedRequestId === undefined
        ? {}
        : { requestId: forwardedRequestId }),
    });
    const options: RequestOptions = {
      protocol: this.baseUrl.protocol,
      hostname: this.baseUrl.hostname,
      port: this.baseUrl.port,
      method: 'PUT',
      path: input.pathWithQuery,
      agent: this.agent,
      headers: {
        ...signedHeaders,
        'content-type': 'application/octet-stream',
        'content-length': String(input.contentLength),
      },
    };

    return new Promise<unknown>((resolve, reject) => {
      let request: ClientRequest;
      let connectTimer: NodeJS.Timeout | undefined;
      let headersTimer: NodeJS.Timeout | undefined;
      let settled = false;

      const clearTimers = () => {
        if (connectTimer !== undefined) clearTimeout(connectTimer);
        if (headersTimer !== undefined) clearTimeout(headersTimer);
      };
      const fail = (error: unknown) => {
        if (settled) return;
        settled = true;
        clearTimers();
        input.source.destroy();
        reject(
          error instanceof StorageAgentWriteError
            ? error
            : new StorageAgentWriteError(
                'NETWORK_ERROR',
                'Écriture vers le Storage Agent interrompue.',
                error,
              ),
        );
      };
      const startHeadersTimer = () => {
        if (headersTimer !== undefined) return;
        headersTimer = setTimeout(() => {
          request.destroy(
            new StorageAgentWriteError(
              'RESPONSE_TIMEOUT',
              'Le Storage Agent n’a pas répondu à temps.',
            ),
          );
        }, this.config.headersTimeoutMs);
        headersTimer.unref();
      };

      request = httpRequest(options, (response) => {
        if (settled) {
          response.destroy();
          return;
        }
        settled = true;
        clearTimers();
        const statusCode = response.statusCode ?? 0;
        if (statusCode < 200 || statusCode >= 300) {
          const rawCode = asHeader(response.headers['x-hs-error-code']);
          // L'agent peut refuser dès les en-têtes (taille, auth, saturation).
          // Arrêter alors le disque source et la requête évite de continuer à
          // envoyer un FLAC que Windows a déjà refusé.
          input.source.unpipe(request);
          input.source.destroy();
          request.destroy();
          response.resume();
          reject(
            new StorageAgentWriteError(
              'AGENT_REJECTED',
              `Le Storage Agent a refusé l’écriture (${rawCode ?? statusCode}).`,
            ),
          );
          return;
        }
        void readReceipt(response, this.config.bodyIdleTimeoutMs).then(
          (receipt) => {
            this.logger.info(
              {
                event: 'REMOTE_STORAGE_WRITE_CONFIRMED',
                route: input.pathWithQuery === '/internal/storage/index'
                  ? '/internal/storage/index'
                  : '/internal/storage/objects/:sha256.:extension',
                statusCode,
                durationMs: performance.now() - startedAt,
                contentLength: input.contentLength,
              },
              'REMOTE_STORAGE_WRITE_CONFIRMED',
            );
            resolve(receipt);
          },
          reject,
        );
      });

      connectTimer = setTimeout(() => {
        request.destroy(
          new StorageAgentWriteError(
            'NETWORK_ERROR',
            'Connexion au Storage Agent expirée.',
          ),
        );
      }, this.config.connectTimeoutMs);
      connectTimer.unref();

      request.setTimeout(this.config.bodyIdleTimeoutMs, () => {
        request.destroy(
          new StorageAgentWriteError(
            'NETWORK_ERROR',
            'Le transfert vers le Storage Agent est resté inactif.',
          ),
        );
      });

      request.once('socket', (socket) => {
        if (socket.connecting) {
          socket.once('connect', () => {
            if (connectTimer !== undefined) clearTimeout(connectTimer);
          });
        } else if (connectTimer !== undefined) {
          clearTimeout(connectTimer);
        }
      });
      // Le délai d'en-têtes commence APRÈS l'envoi complet du fichier. Un FLAC
      // volumineux peut légitimement prendre plus de cinq secondes à monter.
      request.once('finish', startHeadersTimer);
      request.once('error', fail);
      input.source.once('error', fail);
      input.source.pipe(request);
    });
  }
}

class GuardedRemoteBody extends Transform {
  private bytesReceived = 0;
  private idleTimer: NodeJS.Timeout | undefined;

  constructor(
    private readonly response: IncomingMessage,
    private readonly expectedBytes: number,
    private readonly idleTimeoutMs: number,
    private readonly logger: RemoteLogger,
    private readonly fields: Record<string, unknown>,
  ) {
    super();
    this.armIdleTimeout();
    response.once('aborted', () => {
      this.destroy(
        new AudioStorageError(
          'REMOTE_STREAM_INTERRUPTED',
          'Le flux distant a été interrompu.',
        ),
      );
    });
    response.once('error', (error) => {
      this.destroy(
        new AudioStorageError(
          'REMOTE_STREAM_INTERRUPTED',
          'Le flux distant a échoué.',
          error,
        ),
      );
    });
    response.pipe(this);
  }

  override _transform(
    chunk: Buffer,
    _encoding: BufferEncoding,
    callback: TransformCallback,
  ): void {
    this.bytesReceived += chunk.length;
    this.armIdleTimeout();
    callback(null, chunk);
  }

  override _flush(callback: TransformCallback): void {
    this.clearIdleTimeout();
    if (this.bytesReceived !== this.expectedBytes) {
      callback(
        new AudioStorageError(
          'REMOTE_STREAM_INTERRUPTED',
          'Le flux distant est tronqué.',
        ),
      );
      return;
    }
    callback();
  }

  override _destroy(
    error: Error | null,
    callback: (error?: Error | null) => void,
  ): void {
    this.clearIdleTimeout();
    if (!this.response.destroyed) this.response.destroy();
    if (error !== null) {
      const code =
        error instanceof AudioStorageError
          ? error.code
          : ('REMOTE_STREAM_INTERRUPTED' satisfies AudioStorageErrorCode);
      this.logger.warn(
        {
          event: 'REMOTE_STORAGE_REQUEST_ABORTED',
          ...this.fields,
          errorCode: code,
          bytesReceived: this.bytesReceived,
          aborted: true,
        },
        'REMOTE_STORAGE_REQUEST_ABORTED',
      );
    }
    callback(error);
  }

  private armIdleTimeout(): void {
    this.clearIdleTimeout();
    this.idleTimer = setTimeout(() => {
      this.destroy(
        new AudioStorageError(
          'BODY_TIMEOUT',
          'Le flux distant est resté inactif trop longtemps.',
        ),
      );
    }, this.idleTimeoutMs);
    this.idleTimer.unref();
  }

  private clearIdleTimeout(): void {
    if (this.idleTimer !== undefined) {
      clearTimeout(this.idleTimer);
      this.idleTimer = undefined;
    }
  }
}
