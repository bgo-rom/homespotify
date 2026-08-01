import { once } from 'node:events';
import type { IncomingMessage } from 'node:http';
import { performance } from 'node:perf_hooks';
import type { Readable } from 'node:stream';
import {
  AudioStorageError,
  type AudioFileInfo,
  type AudioStorageProvider,
  type ByteRange,
  type StorageHealth,
  type StorageRequestContext,
  type TrackStorageReference,
} from '../audio-storage.js';
import type { RemoteStorageConfig } from './remote-config.js';
import {
  SILENT_REMOTE_LOGGER,
  StorageAgentClient,
  type RemoteLogger,
} from './storage-agent-client.js';

const TRACK_PATH = '/internal/storage/tracks/';

function trackPath(reference: TrackStorageReference): string {
  if (
    !Number.isSafeInteger(reference.trackId) ||
    reference.trackId <= 0
  ) {
    throw new AudioStorageError(
      'INVALID_REFERENCE',
      'Identifiant de piste distant invalide.',
    );
  }
  return `${TRACK_PATH}${reference.trackId}`;
}

function header(
  response: IncomingMessage,
  name: string,
): string | undefined {
  const value = response.headers[name];
  return Array.isArray(value) ? undefined : value;
}

function requiredContentLength(response: IncomingMessage): number {
  const raw = header(response, 'content-length');
  if (raw === undefined || !/^\d+$/.test(raw)) {
    throw new AudioStorageError(
      'REMOTE_INVALID_RESPONSE',
      'Le Storage Agent n’a pas fourni une taille valide.',
    );
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new AudioStorageError(
      'REMOTE_INVALID_RESPONSE',
      'Le Storage Agent a fourni une taille incohérente.',
    );
  }
  return value;
}

function validateCommonHeaders(
  response: IncomingMessage,
): { modifiedAt: Date; contentType: string } {
  if (header(response, 'accept-ranges')?.toLowerCase() !== 'bytes') {
    throw new AudioStorageError(
      'REMOTE_INVALID_RESPONSE',
      'Le Storage Agent n’annonce pas le support Range.',
    );
  }
  const contentType = header(response, 'content-type');
  if (contentType === undefined || !contentType.toLowerCase().startsWith('audio/')) {
    throw new AudioStorageError(
      'REMOTE_INVALID_RESPONSE',
      'Le Storage Agent a fourni un type de contenu incohérent.',
    );
  }
  const lastModifiedRaw = header(response, 'last-modified');
  const lastModifiedMs =
    lastModifiedRaw === undefined ? Number.NaN : Date.parse(lastModifiedRaw);
  if (!Number.isFinite(lastModifiedMs)) {
    throw new AudioStorageError(
      'REMOTE_INVALID_RESPONSE',
      'Le Storage Agent a fourni une date de modification invalide.',
    );
  }
  return {
    modifiedAt: new Date(lastModifiedMs),
    contentType,
  };
}

async function drainHead(response: IncomingMessage): Promise<void> {
  let bodyBytes = 0;
  response.on('data', (chunk: Buffer) => {
    bodyBytes += chunk.length;
  });
  response.resume();
  if (!response.readableEnded) await once(response, 'end');
  if (bodyBytes !== 0) {
    throw new AudioStorageError(
      'REMOTE_INVALID_RESPONSE',
      'Le Storage Agent a envoyé un corps inattendu sur HEAD.',
    );
  }
}

export class RemoteWindowsStorageProvider implements AudioStorageProvider {
  private readonly client: StorageAgentClient;

  constructor(
    config: RemoteStorageConfig,
    private readonly logger: RemoteLogger = SILENT_REMOTE_LOGGER,
  ) {
    this.client = new StorageAgentClient(config, logger);
  }

  close(): void {
    this.client.close();
  }

  async stat(
    reference: TrackStorageReference,
    context?: StorageRequestContext,
  ): Promise<AudioFileInfo> {
    const startedAt = performance.now();
    const fields = {
      requestId: context?.requestId,
      trackId: reference.trackId,
      method: 'HEAD',
      operation: 'stat',
    };
    this.logger.info(
      { event: 'REMOTE_STORAGE_REQUEST_STARTED', ...fields },
      'REMOTE_STORAGE_REQUEST_STARTED',
    );
    try {
      const result = await this.client.head(
        trackPath(reference),
        context?.requestId,
      );
      if (result.statusCode !== 200) {
        result.response.destroy();
        throw new AudioStorageError(
          'REMOTE_INVALID_RESPONSE',
          'Statut HEAD distant inattendu.',
        );
      }
      if (header(result.response, 'content-range') !== undefined) {
        result.response.destroy();
        throw new AudioStorageError(
          'REMOTE_INVALID_RESPONSE',
          'Content-Range inattendu sur HEAD sans plage.',
        );
      }
      const sizeBytes = requiredContentLength(result.response);
      const { modifiedAt, contentType } = validateCommonHeaders(result.response);
      await drainHead(result.response);

      if (
        reference.expectedSizeBytes !== undefined &&
        reference.expectedSizeBytes !== sizeBytes
      ) {
        this.logger.warn(
          {
            event: 'REMOTE_STORAGE_SIZE_MISMATCH',
            ...fields,
            expectedSizeBytes: reference.expectedSizeBytes,
            observedSizeBytes: sizeBytes,
          },
          'REMOTE_STORAGE_SIZE_MISMATCH',
        );
      }
      this.logger.info(
        {
          event: 'REMOTE_STORAGE_REQUEST_COMPLETED',
          ...fields,
          statusCode: 200,
          durationMs: performance.now() - startedAt,
        },
        'REMOTE_STORAGE_REQUEST_COMPLETED',
      );
      return { sizeBytes, modifiedAt, contentType, source: 'remote' };
    } catch (error) {
      this.logFailure(error, fields, startedAt);
      throw error;
    }
  }

  async createReadStream(
    reference: TrackStorageReference,
    range?: ByteRange,
    context?: StorageRequestContext,
  ): Promise<Readable> {
    const startedAt = performance.now();
    const fields = {
      requestId: context?.requestId,
      trackId: reference.trackId,
      method: 'GET',
      operation: 'read',
      rangeStart: range?.start,
      rangeEnd: range?.end,
    };
    this.logger.info(
      { event: 'REMOTE_STORAGE_REQUEST_STARTED', ...fields },
      'REMOTE_STORAGE_REQUEST_STARTED',
    );
    try {
      if (
        range !== undefined &&
        (!Number.isSafeInteger(range.start) ||
          !Number.isSafeInteger(range.end) ||
          range.start < 0 ||
          range.end < range.start)
      ) {
        throw new AudioStorageError(
          'INVALID_REFERENCE',
          'Plage distante invalide.',
        );
      }
      const result = await this.client.get(
        trackPath(reference),
        range,
        context?.requestId,
      );
      const expectedStatus = range === undefined ? 200 : 206;
      if (result.statusCode !== expectedStatus) {
        result.response.destroy();
        throw new AudioStorageError(
          'REMOTE_INVALID_RESPONSE',
          'Statut de flux distant inattendu.',
        );
      }
      validateCommonHeaders(result.response);
      const contentLength = requiredContentLength(result.response);
      if (range === undefined) {
        if (header(result.response, 'content-range') !== undefined) {
          result.response.destroy();
          throw new AudioStorageError(
            'REMOTE_INVALID_RESPONSE',
            'Content-Range inattendu sur un flux complet.',
          );
        }
      } else {
        const expectedLength = range.end - range.start + 1;
        const contentRange = header(result.response, 'content-range');
        const match =
          contentRange === undefined
            ? null
            : /^bytes (\d+)-(\d+)\/(\d+)$/.exec(contentRange);
        if (
          match === null ||
          Number(match[1]) !== range.start ||
          Number(match[2]) !== range.end ||
          Number(match[3]) <= range.end ||
          contentLength !== expectedLength
        ) {
          result.response.destroy();
          throw new AudioStorageError(
            'REMOTE_INVALID_RESPONSE',
            'La plage renvoyée par le Storage Agent est incohérente.',
          );
        }
      }
      const body = this.client.createGuardedBody(
        result.response,
        contentLength,
        fields,
      );
      body.once('end', () => {
        this.logger.info(
          {
            event: 'REMOTE_STORAGE_REQUEST_COMPLETED',
            ...fields,
            statusCode: result.statusCode,
            durationMs: performance.now() - startedAt,
            bytesReceived: contentLength,
          },
          'REMOTE_STORAGE_REQUEST_COMPLETED',
        );
      });
      setImmediate(() => body.emit('open'));
      return body;
    } catch (error) {
      this.logFailure(error, fields, startedAt);
      throw error;
    }
  }

  async healthCheck(): Promise<StorageHealth> {
    const startedAt = performance.now();
    try {
      const result = await this.client.health();
      const chunks: Buffer[] = [];
      let size = 0;
      for await (const chunk of result.response) {
        const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
        size += buffer.length;
        if (size > 64 * 1024) {
          result.response.destroy();
          return { status: 'offline', reason: 'Réponse de santé invalide.' };
        }
        chunks.push(buffer);
      }
      let status: unknown;
      try {
        status = (JSON.parse(Buffer.concat(chunks).toString('utf8')) as {
          status?: unknown;
        }).status;
      } catch {
        return { status: 'offline', reason: 'Réponse de santé invalide.' };
      }
      const latencyMs = performance.now() - startedAt;
      if (status === 'healthy') {
        return { status: 'online', source: 'remote', latencyMs };
      }
      if (status === 'degraded') {
        return { status: 'degraded', reason: 'Stockage distant dégradé.' };
      }
      return { status: 'offline', reason: 'Stockage distant indisponible.' };
    } catch (error) {
      const code =
        error instanceof AudioStorageError ? error.code : 'AGENT_UNAVAILABLE';
      return {
        status: 'offline',
        reason:
          code === 'REMOTE_AUTH_FAILED'
            ? 'Authentification du stockage distant refusée.'
            : 'Storage Agent injoignable.',
      };
    }
  }

  private logFailure(
    error: unknown,
    fields: Record<string, unknown>,
    startedAt: number,
  ): void {
    const errorCode =
      error instanceof AudioStorageError ? error.code : 'REMOTE_INTERNAL';
    const event =
      errorCode === 'INDEX_STALE'
        ? 'REMOTE_STORAGE_INDEX_STALE'
        : errorCode === 'AGENT_UNAVAILABLE' ||
            errorCode === 'CONNECT_TIMEOUT' ||
            errorCode === 'HEADERS_TIMEOUT'
          ? 'REMOTE_STORAGE_AGENT_UNAVAILABLE'
          : 'REMOTE_STORAGE_REQUEST_FAILED';
    this.logger.error(
      {
        event,
        ...fields,
        errorCode,
        durationMs: performance.now() - startedAt,
      },
      event,
    );
  }
}
