import {
  Agent,
  request as httpRequest,
  type ClientRequest,
  type IncomingMessage,
  type RequestOptions,
} from 'node:http';
import { Transform, type TransformCallback } from 'node:stream';
import {
  AudioStorageError,
  type AudioStorageErrorCode,
  type ByteRange,
} from '../audio-storage.js';
import type { RemoteStorageConfig } from './remote-config.js';
import { agentResponseError } from './agent-error-mapping.js';
import { buildSignedHeaders } from './hmac-client.js';

const SAFE_REQUEST_ID = /^[A-Za-z0-9._:-]{1,96}$/;

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
